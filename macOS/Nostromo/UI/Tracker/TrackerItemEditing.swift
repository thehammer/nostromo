import AppKit
import Combine
import NostromoKit

/// Which text of an item an inline editor changes.
enum TrackerEditKind: String {
    case title
    case details
}

/// The board a row's content came from: what `base_version` (and `base_epoch`) name for an edit of that row.
struct TrackerBase: Equatable {
    let version: UInt64
    /// The board's run (nil from a daemon that sends none): sent as `base_epoch` only when the board had one.
    let epoch: String?
}

/// What putting a removed item back needs, taken from the board on screen when the item goes: its exact
/// markdown and the place it was in (as neighbours: the undo works the place out again against the board it
/// finds, since those neighbours may have moved or gone by then).
struct TrackerItemSnapshot: Equatable {
    /// The item's title as the banner names it.
    let title: String
    let source: String
    let place: TrackerPlaceHint
}

/// The tracker pane's edit controller (one per pane): builds the `tracker_edit` ops for what the user
/// does in the pane, sends them, takes the daemon's answers, tells the pane why an edit did not
/// happen, and registers the inverse of every undoable edit with the pane's own `UndoManager`.
///
/// There is no optimistic display: nothing here changes a row. The row changes when the daemon's board
/// arrives, so the pane always shows the file's truth (the strip and the sidebar pill follow the same
/// board). Rows stay dumb: they call the pane, the pane calls this.
final class TrackerItemEditing {
    /// `(tag, request id, base version, base epoch, ops)`; false when the frame was not written.
    typealias Sender = (String, String, UInt64, String?, [TrackerPaneOpWire]) -> Bool

    /// What became of one send.
    enum Outcome: Equatable {
        /// The daemon applied it: the board it produced has `version` (it may already be here).
        case saved(version: UInt64, created: [String])
        /// The daemon refused it (or the frame was never written): nothing changed.
        case failed(String)
        /// No answer in time. The edit may still have been applied: a late answer follows as `saved` or `failed`.
        case timedOut(String)
    }

    /// No answer within this long is a failure.
    static let answerTimeout: TimeInterval = 5
    /// A notice goes away after this long, or at the next successful edit.
    static let noticeLifetime: TimeInterval = 6
    /// How many timed-out sends are remembered so a late answer still finds its edit.
    private static let rememberedTimeouts = 32

    /// Undo and redo of pane edits. Never the window's: the composer's typing undo is not touched.
    var undoManager: UndoManager {
        dropVoidEntries()
        return manager
    }
    private let manager: UndoManager = {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }()

    /// The quiet one-line notice above the board, or nil.
    private(set) var notice: String?
    var onNotice: ((String?) -> Void)?
    /// An edit touching these items was confirmed (ids, board version): the pane does not flash them.
    var onConfirmed: (([String], UInt64) -> Void)?
    /// The daemon says the pane's view is out of date: the pane shows the board as it is now.
    var onLookAgain: (() -> Void)?

    /// The item's removal has just happened (its title), or the removal was taken back or refused (nil).
    var onRemoved: ((String?) -> Void)?
    /// The exact source and place of an item on the board on screen (nil when it is not there).
    var itemSnapshot: (String) -> TrackerItemSnapshot? = { _ in nil }
    /// Where the view has an item now (its section and neighbours), as a place to put it back to.
    var itemPlace: (String) -> TrackerPlaceHint? = { _ in nil }
    /// The place a hint means on the board as it is now (neighbour still there, else the other, else the
    /// section's end).
    var resolvePlace: (TrackerPlaceHint) -> TrackerMoveDestination = { hint in
        TrackerMoveDestination(section: hint.section, after: hint.above)
    }
    /// The version of the newest board the pane has applied.
    var boardVersion: () -> UInt64 = { 0 }

    private let tag: String
    private let send: Sender
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    /// The board version the pane shows for these items (what an undo is made against, not the newest board).
    private let shownBase: ([String]) -> TrackerBase
    private let itemExists: (String) -> Bool
    private typealias Entry = (ids: [String], places: Bool, completion: (Outcome) -> Void)
    private var pending: [String: Entry] = [:]
    /// Sends that timed out, oldest first: an answer that comes after all is still theirs.
    private var timedOut: [(requestId: String, entry: Entry)] = []
    private var sequence = 0
    private var noticeGeneration = 0
    /// The status an item had before this pane ticked it (what an untick goes back to).
    private var statusBeforeTick: [String: String] = [:]
    private var subscription: AnyCancellable?

    /// One registered undo (or redo), so a refused edit takes back only its own.
    private final class UndoToken {
        var isVoid = false
        /// The manager has run (and dropped) it.
        var isConsumed = false
    }
    private var undoStack: [UndoToken] = []
    private var redoStack: [UndoToken] = []

    /// The id of an item that a removal and its undo and redo keep naming: a restore may bring the item back
    /// under a new id (the answer's `created`).
    private final class ItemRef {
        var id: String
        init(_ id: String) { self.id = id }
    }
    /// The newest removal the user made (the banner's Undo).
    private var latestRemoval: (token: UndoToken, snapshot: TrackerItemSnapshot, ref: ItemRef)?

    /// Items whose next change is this pane's own move or removal (sent, or confirmed and waiting for its
    /// board): the deferral applies them even on screen.
    private var exemptPending: [String: Int] = [:]
    private var exemptConfirmed: [String: UInt64] = [:]
    var exemptItemIds: Set<String> { Set(exemptPending.keys).union(exemptConfirmed.keys) }

    /// A board with this version is on screen: the confirmed edits it shows are no longer exempt.
    func boardApplied(version: UInt64) {
        exemptConfirmed = exemptConfirmed.filter { $0.value > version }
    }

    init(tag: String,
         results: AnyPublisher<TrackerEditResultWire, Never>,
         send: @escaping Sender,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void,
         shownBase: @escaping ([String]) -> TrackerBase,
         itemExists: @escaping (String) -> Bool) {
        self.tag = tag
        self.send = send
        self.schedule = schedule
        self.shownBase = shownBase
        self.itemExists = itemExists
        subscription = results
            .filter { $0.tag == tag }
            .sink { [weak self] in self?.receive($0) }
    }

    /// The items an edit still waiting for its answer touches.
    var inFlightItemIds: Set<String> { Set(pending.values.flatMap(\.ids)) }

    // MARK: - Actions

    /// The tick: done, or (on a done item) the status it had before this pane ticked it, else todo.
    func tick(_ item: TrackerItemRow, base: TrackerBase) {
        guard item.isTickable else { return }
        if item.isDone {
            setStatus(item, to: statusBeforeTick[item.id] ?? "todo", base: base, name: "Tick")
        } else {
            statusBeforeTick[item.id] = item.status.wireName
            setStatus(item, to: "done", base: base, name: "Tick")
        }
    }

    func setStatus(_ item: TrackerItemRow, to status: String, base: TrackerBase, name: String = "Status") {
        guard item.isStatusEditable, status != item.status.wireName else { return }
        perform([.status(id: item.id, status: status)], inverse: [.status(id: item.id, status: item.status.wireName)],
                name: name, base: base)
    }

    /// The title typed into the editor. Returns false (nothing sent) when it is empty after cleaning.
    @discardableResult
    func saveTitle(_ item: TrackerItemRow, typed: String, base: TrackerBase,
                   completion: @escaping (Outcome) -> Void) -> Bool {
        let title = TrackerTitle.normalizedTitle(typed)
        guard !title.isEmpty else { return false }
        let legacy = TrackerTitle.split(item.editText).rule != .whole
        let op: TrackerPaneOpWire
        var restoresBody = true
        // The daemon counts scalars: a title that is 80 characters but more scalars is restructured too.
        if legacy || !TrackerTitle.fitsTitle(title) {
            let restructured = TrackerTitle.restructure(text: item.editText, note: item.editNote, newTitle: title)
            op = .edit(id: item.id, title: restructured.title, text: nil, body: restructured.body)
        } else {
            op = .edit(id: item.id, title: title, text: nil, body: nil)
            restoresBody = false
        }
        perform([op], inverse: Self.restoreOps(item, includingNote: restoresBody), name: "Title Edit",
                base: base, completion: completion)
        return true
    }

    /// The details typed into the editor (the note; for a legacy item the text after the title too).
    func saveDetails(_ item: TrackerItemRow, typed: String, base: TrackerBase,
                     completion: @escaping (Outcome) -> Void) {
        var body = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let legacy = TrackerTitle.split(item.editText).rule != .whole
        let op: TrackerPaneOpWire
        if legacy {
            // The title goes as the daemon wants it: no hidden characters, at most 80 scalars.
            let fitted = TrackerTitle.fitScalars(TrackerTitle.normalizedTitle(TrackerTitle.editableTitle(text: item.editText)))
            if let overflow = fitted.overflow { body = [overflow, body].filter { !$0.isEmpty }.joined(separator: "\n\n") }
            op = .edit(id: item.id, title: fitted.title, text: nil, body: body)
        } else {
            op = .edit(id: item.id, title: nil, text: nil, body: body)
        }
        perform([op], inverse: Self.restoreOps(item, includingNote: true, textToo: legacy), name: "Details Edit",
                base: base, completion: completion)
    }

    /// Keep or use a conflict's losing value. `keep: losing` is undoable (an edit back to the kept value);
    /// `keep: current` is not. `completion` hears the outcome (a restored item's new id arrives in `created`).
    func resolve(_ entry: TrackerConflictEntry, keep: TrackerConflictKeepWire, base: TrackerBase,
                 completion: ((Outcome) -> Void)? = nil) {
        let op = TrackerPaneOpWire.resolveConflict(id: entry.itemId, field: entry.field, keep: keep,
                                                   conflictId: entry.conflictId)
        guard keep == .losing, !entry.inverse.isEmpty else {
            submit([op], base: base, completion: { completion?($0) })
            return
        }
        perform([op], inverse: entry.inverse, name: "Conflict Choice", base: base, completion: completion)
    }

    /// "It's fine, share it". Not undoable. Never combined with an edit of the same item in one batch.
    func clearBadge(itemId: String, base: TrackerBase) {
        submit([.clearBadge(id: itemId)], base: base, completion: { _ in })
    }

    // MARK: - Structure: add, move, remove

    /// A new item at the end of `after`'s place in `section` (the section's end without it). Undo removes it.
    func add(section: String, title: String, body: String?, after: String?, base: TrackerBase,
             completion: @escaping (Outcome) -> Void) {
        let op = TrackerPaneOpWire.add(section: section, title: title, body: body, before: nil, after: after)
        submit([op], base: base) { [weak self] outcome in
            if case .saved(_, let created) = outcome, let id = created.first {
                self?.registerUndo(name: "Add Item", ids: [id]) { me in
                    me.removeItem(ItemRef(id), base: me.shownBase([id]), announce: false)
                }
            }
            completion(outcome)
        }
    }

    /// Move an item to `destination`; undo moves it back to where the view has it now (worked out again when
    /// the undo runs, so a neighbour that moved or went away in between does not strand it).
    func move(_ id: String, to destination: TrackerMoveDestination, base: TrackerBase) {
        guard let place = itemPlace(id) else { return }
        let current = place.above != nil ? TrackerMoveDestination(section: place.section, after: place.above)
            : place.below != nil ? TrackerMoveDestination(section: place.section, before: place.below)
            : TrackerMoveDestination(section: place.section)
        guard current != destination else { return }
        sendMove(id, to: destination, undoHint: place, base: base)
    }

    /// `onRefused` puts back the entry this send came from when it is the undo (or redo) of an earlier one:
    /// a refusal leaves the history as it was, so the user can try again.
    private func sendMove(_ id: String, to destination: TrackerMoveDestination, undoHint: TrackerPlaceHint,
                          base: TrackerBase, onRefused: (() -> Void)? = nil) {
        let token = registerMoveUndo(id, destination: destination, undoHint: undoHint)
        submitExempt([id], [destination.moveOp(id)], base: base, places: true) { [weak self] outcome in
            guard case .failed = outcome else { return }
            self?.retract(token)
            onRefused?()
        }
    }

    @discardableResult
    private func registerMoveUndo(_ id: String, destination: TrackerMoveDestination, undoHint: TrackerPlaceHint) -> UndoToken {
        registerUndo(name: "Move Item", ids: [id]) { me in
            // Where the item is when the undo runs is where its redo goes (and what that redo then undoes to).
            let hereNow = me.itemPlace(id) ?? TrackerPlaceHint(destination)
            me.sendMove(id, to: me.resolvePlace(undoHint), undoHint: hereNow, base: me.shownBase([id]),
                        onRefused: { me.registerMoveUndo(id, destination: destination, undoHint: undoHint) })
        }
    }

    /// Remove an item (the user's own: the banner offers Undo).
    func remove(_ id: String, base: TrackerBase) {
        removeItem(ItemRef(id), base: base, announce: true)
    }

    /// The banner's Undo: put the newest removal back. When it is also the newest undo, that is ⌘Z itself
    /// (so Redo removes it again); otherwise it restores exactly this removal and nothing else: its own ⌘Z
    /// entry is spent, every other undo and redo stays.
    func undoLatestRemoval() {
        guard let latest = latestRemoval else { return }
        if undoStack.last === latest.token, manager.canUndo {
            manager.undo()
            return
        }
        latest.token.isVoid = true
        restoreItem(latest.snapshot, ref: latest.ref, base: shownBase([]), registering: false, spent: latest.token)
    }

    private func removeItem(_ ref: ItemRef, base: TrackerBase, announce: Bool) {
        guard let snapshot = itemSnapshot(ref.id) else {
            showNotice("Not removed: that item is no longer on the board.")
            return
        }
        let token = registerRemovalUndo(snapshot, ref: ref)
        if announce {
            latestRemoval = (token, snapshot, ref)
            onRemoved?(snapshot.title)
        }
        submitExempt([ref.id], [.remove(id: ref.id)], base: base) { [weak self] outcome in
            guard case .failed = outcome else { return }
            self?.retract(token)
            if self?.latestRemoval?.token === token {
                self?.latestRemoval = nil
                self?.onRemoved?(nil)
            }
        }
    }

    @discardableResult
    private func registerRemovalUndo(_ snapshot: TrackerItemSnapshot, ref: ItemRef) -> UndoToken {
        registerUndo(name: "Remove Item", ids: []) { me in
            me.restoreItem(snapshot, ref: ref, base: me.shownBase([]), registering: true, spent: nil)
        }
    }

    /// Put a removed item back at its place worked out against the board as it is now. A refusal keeps the
    /// way to try again (the undo entry and the banner) and says why. `registering` is false for the banner's
    /// direct Undo, which adds nothing to the history; `spent` is the removal's own entry it voided.
    private func restoreItem(_ snapshot: TrackerItemSnapshot, ref: ItemRef, base: TrackerBase,
                             registering: Bool, spent: UndoToken?) {
        let wasLatest = latestRemoval?.ref === ref
        if wasLatest {
            latestRemoval = nil
            onRemoved?(nil)
        }
        let redo = registering ? registerUndo(name: "Remove Item", ids: []) { me in
            me.removeItem(ref, base: me.shownBase([ref.id]), announce: false)
        } : nil
        let destination = resolvePlace(snapshot.place)
        submitExempt([], [destination.restoreOp(source: snapshot.source)], base: base, places: true) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .saved(_, let created):
                if let id = created.first { ref.id = id }
            case .failed:
                if let redo { self.retract(redo) }
                // The removal can still be undone: its entry comes back (a direct Undo only un-voids it).
                var token = spent
                if let spent, !spent.isConsumed { spent.isVoid = false } else { token = self.registerRemovalUndo(snapshot, ref: ref) }
                if wasLatest, let token {
                    self.latestRemoval = (token, snapshot, ref)
                    self.onRemoved?(snapshot.title)
                }
            case .timedOut: break
            }
        }
    }

    // MARK: - Sending

    /// Send `ops` and register `inverse` for ⌘Z (and, from inside the undo, the redo). A refusal takes back
    /// this edit's registration only: the history before it stays.
    private func perform(_ ops: [TrackerPaneOpWire], inverse: [TrackerPaneOpWire], name: String,
                         base: TrackerBase, exempt: Bool = false, completion: ((Outcome) -> Void)? = nil) {
        let ids = Set(ops.compactMap(Self.itemId)).union(inverse.compactMap(Self.itemId))
        let token = registerUndo(name: name, ids: Array(ids)) { me in
            me.perform(inverse, inverse: ops, name: name, base: me.shownBase(Array(ids)), exempt: exempt)
        }
        submitExempt(exempt ? Array(ids) : [], ops, base: base) { [weak self] outcome in
            if case .failed = outcome { self?.retract(token) }
            completion?(outcome)
        }
    }

    /// Register what ⌘Z runs (`run`, when every item in `ids` is still on the board). Registered while undoing
    /// it is a redo; a fresh edit also clears the redo stack.
    @discardableResult
    private func registerUndo(name: String, ids: [String], run: @escaping (TrackerItemEditing) -> Void) -> UndoToken {
        let token = UndoToken()
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: self) { me in
            // This entry is being run: it is no longer on the stack it was on.
            if me.manager.isUndoing { me.undoStack.removeAll { $0 === token } } else { me.redoStack.removeAll { $0 === token } }
            token.isConsumed = true
            guard !token.isVoid else { return }
            guard ids.allSatisfy(me.itemExists) else {
                me.showNotice("Couldn't undo: the item was removed.")
                return
            }
            run(me)
        }
        manager.setActionName(name)
        manager.endUndoGrouping()
        if manager.isUndoing {
            redoStack.append(token)
        } else {
            if !manager.isRedoing { redoStack.removeAll() }
            undoStack.append(token)
        }
        return token
    }

    /// `submit`, with `ids` exempt from the deferral until the board with the change is on screen.
    private func submitExempt(_ ids: [String], _ ops: [TrackerPaneOpWire], base: TrackerBase, places: Bool = false,
                              completion: @escaping (Outcome) -> Void) {
        guard !ids.isEmpty else {
            submit(ops, base: base, places: places, completion: completion)
            return
        }
        for id in ids { exemptPending[id, default: 0] += 1 }
        var released = false
        submit(ops, base: base, places: places) { [weak self] outcome in
            if let self {
                if !released {
                    released = true
                    for id in ids {
                        let left = (self.exemptPending[id] ?? 1) - 1
                        if left > 0 { self.exemptPending[id] = left } else { self.exemptPending.removeValue(forKey: id) }
                    }
                }
                // The answer came before its board: the board that follows is still the user's own change.
                if case .saved(let version, _) = outcome, self.boardVersion() < version {
                    for id in ids { self.exemptConfirmed[id] = version }
                }
            }
            completion(outcome)
        }
    }

    /// Take one registered undo (or redo) back, leaving every other as it is. It is voided; when it is not
    /// the newest of its stack it stays until it surfaces, and `dropVoidEntries` then removes it, so no
    /// menu item ever offers an undo that does nothing.
    private func retract(_ token: UndoToken) {
        token.isVoid = true
        dropVoidEntries()
    }

    /// Run (without registering anything) every voided entry on top of the undo and redo stacks.
    private func dropVoidEntries() {
        guard !manager.isUndoing, !manager.isRedoing else { return }
        manager.disableUndoRegistration()
        defer { manager.enableUndoRegistration() }
        while let last = undoStack.last, last.isVoid, manager.canUndo { manager.undo() }
        while let last = redoStack.last, last.isVoid, manager.canRedo { manager.redo() }
    }

    func submit(_ ops: [TrackerPaneOpWire], base: TrackerBase, places: Bool = false,
                completion: @escaping (Outcome) -> Void) {
        sequence += 1
        let requestId = "pane-\(tag)-\(sequence)"
        pending[requestId] = (ops.compactMap(Self.itemId), places, completion)
        guard send(tag, requestId, base.version, base.epoch, ops) else {
            fail(requestId, "Not saved: Nostromo isn't connected to its daemon.")
            return
        }
        schedule(Self.answerTimeout) { [weak self] in
            self?.timeOut(requestId)
        }
    }

    private func receive(_ result: TrackerEditResultWire) {
        var entry = pending.removeValue(forKey: result.requestId)
        if entry == nil, let index = timedOut.firstIndex(where: { $0.requestId == result.requestId }) {
            entry = timedOut.remove(at: index).entry
        }
        guard let entry else { return }
        if result.ok {
            showNotice(nil)
            onConfirmed?(entry.ids, result.version)
            entry.completion(.saved(version: result.version, created: result.created))
        } else {
            let message = Self.message(for: result.error, placing: entry.places)
            showNotice(message)
            if Self.isStale(result.error) { onLookAgain?() }
            entry.completion(.failed(message))
        }
    }

    private func fail(_ requestId: String, _ message: String) {
        guard let entry = pending.removeValue(forKey: requestId) else { return }
        showNotice(message)
        entry.completion(.failed(message))
    }

    /// No answer in time: the edit may still have been applied, so it is remembered for a late answer.
    private func timeOut(_ requestId: String) {
        guard let entry = pending.removeValue(forKey: requestId) else { return }
        timedOut.append((requestId, entry))
        if timedOut.count > Self.rememberedTimeouts { timedOut.removeFirst() }
        let message = "Not saved yet: the daemon didn't answer in time."
        showNotice(message)
        entry.completion(.timedOut(message))
    }

    // MARK: - Notice

    func showNotice(_ text: String?) {
        noticeGeneration += 1
        notice = text
        onNotice?(text)
        guard text != nil else { return }
        let generation = noticeGeneration
        schedule(Self.noticeLifetime) { [weak self] in
            guard let self, self.noticeGeneration == generation else { return }
            self.notice = nil
            self.onNotice?(nil)
        }
    }

    /// The daemon says the pane's view is out of date (`stale`, or `invalid_args` for the older daemon's
    /// stale-base and stale-conflict reasons): the user is told to look again, and the pane shows the board as it is.
    static func isStale(_ error: TrackerEditErrorWire?) -> Bool {
        guard let error else { return false }
        if error.stale { return true }
        let reason = error.reason ?? ""
        return error.code == "invalid_args" && (reason.contains("no longer kept") || reason.contains("look again"))
    }

    /// One plain sentence for each reason the daemon refuses an edit.
    /// `placing`: the edit put an item next to another (a move or a restore), so "unknown item" or "not in
    /// section" is about that neighbour or section, not about the item the user acted on.
    static func message(for error: TrackerEditErrorWire?, placing: Bool = false) -> String {
        let reason = error?.reason ?? ""
        if placing, !isStale(error), error?.code == "unknown_item" || (error?.code == "invalid_args" && reason.contains("is not in section")) {
            return "Not saved: the place for it changed (the item next to it moved or is gone). Try again."
        }
        if isStale(error) {
            return reason.contains("no longer kept") ? "That conflict is no longer there: look again."
                : "Not saved: that changed since you looked. Look again."
        }
        switch error?.code ?? "" {
        case "board_unreadable": return "Not saved: the board file can't be read" + (reason.isEmpty ? "." : " (\(reason)).")
        case "board_missing": return "Not saved: the board file is gone."
        case "unknown_item": return "Not saved: that item is no longer on the board."
        case "not_operator_app": return "Not saved: only the Nostromo app can change the board."
        case "board_too_large": return "Not saved: the board is too large to edit."
        case "invalid_args": return "Not saved: " + (reason.isEmpty ? "the change isn't valid." : reason)
        case let code: return "Not saved" + (code.isEmpty ? "." : " (\(code)).")
        }
    }

    // MARK: - Inverses

    /// The ops that put the item's old text (and note) back exactly. `restore_text` is not cut at 500
    /// characters, so a long item comes back whole.
    static func restoreOps(_ item: TrackerItemRow, includingNote: Bool, textToo: Bool = true) -> [TrackerPaneOpWire] {
        var ops: [TrackerPaneOpWire] = []
        if textToo { ops.append(.restoreText(id: item.id, text: item.editText)) }
        if includingNote { ops.append(.edit(id: item.id, title: nil, text: nil, body: item.editNote ?? "")) }
        return ops
    }

    private static func itemId(of op: TrackerPaneOpWire) -> String? {
        switch op {
        case .status(let id, _), .edit(let id, _, _, _), .restoreText(let id, _), .clearBadge(let id),
             .resolveConflict(let id, _, _, _), .move(let id, _, _, _):
            return id
        default: return nil
        }
    }
}

// MARK: - Row controls

/// Where an item can go from the Move menu, VoiceOver or the keyboard.
struct TrackerMoveOptions {
    var canUp: Bool
    var canDown: Bool
    /// The other sections, in board order.
    var sections: [(id: String, title: String)]
}

/// One choice of the Move menu.
enum TrackerMoveRequest: Equatable {
    case up
    case down
    case toSection(String)
}

/// A control inside an item row that keyboard focus returns to after the row is rebuilt.
enum TrackerControlRole: String, CaseIterable {
    case tick, disclosure, conflict, sensitive, editTitle, editDetails, status, move, remove
}

/// The status mark as a button: the same glyph, colour and place as the label it replaces, so a row
/// looks unchanged at rest. Drawn by hand so the glyph sits exactly where the label drew it.
final class TrackerTickButton: NSButton {
    override var isFlipped: Bool { true }

    /// Where the glyph is drawn, in the button's own (flipped) coordinates.
    static let glyphOrigin = NSPoint(x: TrackerRowView.hPad - TrackerRowView.tickRect.minX, y: TrackerRowView.vPad)

    private var glyphRect: NSRect {
        NSRect(x: Self.glyphOrigin.x, y: Self.glyphOrigin.y, width: TrackerRowView.markWidth, height: 17)
    }

    /// VoiceOver's actions, asked for when VoiceOver looks (the Move choices follow the neighbours the board has now).
    var liveCustomActions: (() -> [NSAccessibilityCustomAction])?
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? { liveCustomActions?() }

    /// The press began, moved or ended: the row tells a click from a drag (more than 3 pt of movement).
    var onPress: ((NSEvent) -> Void)?
    var onMove: ((NSEvent) -> Bool)?
    private var pressed = false
    private var dragged = false

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
        dragged = false
        onPress?(event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressed, !dragged else { return }
        if onMove?(event) == true { dragged = true }
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        guard pressed, !dragged, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        sendAction(action, to: target)
    }

    init(glyph: String, color: NSColor) {
        super.init(frame: .zero)
        title = glyph
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .default
        refusesFirstResponder = false
        contentTintColor = color
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        (title as NSString).draw(in: glyphRect, withAttributes: [
            .font: TrackerTheme.textFont, .foregroundColor: contentTintColor ?? TrackerTheme.text,
            .paragraphStyle: paragraph])
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: glyphRect.insetBy(dx: -1, dy: 0), xRadius: 3, yRadius: 3).fill()
    }

    override var focusRingMaskBounds: NSRect { glyphRect.insetBy(dx: -1, dy: 0) }
}

/// A small text button: a chip with a fill (the conflict mark, the sensitive badge) or plain muted text
/// (the actions line). Drawn by hand, so the text is centred and never clipped by a cell's own insets.
final class TrackerChipButton: NSButton {
    override var isFlipped: Bool { true }

    private let text: String
    private let color: NSColor
    private let fill: NSColor?
    private let chipFont: NSFont
    private let padding: CGFloat

    init(text: String, color: NSColor, fill: NSColor?, font: NSFont = TrackerTheme.metaFont, padding: CGFloat = 6) {
        self.text = text
        self.color = color
        self.fill = fill
        self.chipFont = font
        self.padding = padding
        super.init(frame: .zero)
        title = text
        isBordered = false
        setButtonType(.momentaryChange)
        refusesFirstResponder = false
        focusRingType = .default
    }

    required init?(coder: NSCoder) { fatalError() }

    private var attributes: [NSAttributedString.Key: Any] { [.font: chipFont, .foregroundColor: color] }

    var fittingWidth: CGFloat { ceil((text as NSString).size(withAttributes: attributes).width) + padding * 2 }

    override var intrinsicContentSize: NSSize { NSSize(width: fittingWidth, height: TrackerRowView.chipHeight) }

    override func draw(_ dirtyRect: NSRect) {
        if let fill {
            fill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        }
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = NSPoint(x: floor((bounds.width - size.width) / 2), y: floor((bounds.height - size.height) / 2))
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }
}

/// The title as an editable single line, in exactly the title's frame. Return saves, Esc cancels, losing
/// focus saves (the pane drops an unchanged one).
final class TrackerTitleEditor: NSTextField, NSTextFieldDelegate {
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    private(set) var isFinished = false
    /// The last commit was Return (not losing focus).
    private(set) var committedByReturn = false
    /// Focus events before the editor is set up (arming) are not the user's: they save and cancel nothing.
    private var isArmed = false
    let original: String

    func arm() { isArmed = true }

    /// Focus was asked for on this editor while its save was pending (read-only; the field may refuse): a click or an explicit
    /// focus request. Merely being asked `acceptsFirstResponder` or `canBecomeKeyView` (key-view loop,
    /// accessibility) is not focus and does not count.
    var onFocusWhilePending: (() -> Void)?
    /// Focus left this editor while its save was pending: the user no longer wants it there.
    var onFocusLeftWhilePending: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        // Asked to take focus (a click, an explicit request), whether or not a read-only field accepts it.
        if !isEditable { onFocusWhilePending?() }
        return super.becomeFirstResponder()
    }

    init(text: String) {
        original = text
        super.init(frame: .zero)
        stringValue = text
        font = TrackerTheme.textFont
        textColor = TrackerTheme.text
        isBordered = false
        drawsBackground = true
        backgroundColor = TrackerTheme.badgeFill
        focusRingType = .none
        isEditable = true
        isSelectable = true
        usesSingleLineMode = true
        lineBreakMode = .byClipping
        cell?.isScrollable = true
        cell?.wraps = false
        delegate = self
        setAccessibilityLabel("Title")
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The user's own text, wherever the editor is in its life.
    var typed: String { currentEditor()?.string ?? stringValue }

    func commit() {
        guard !isFinished, isArmed else { return }
        isFinished = true
        onCommit?(typed)
    }

    func cancel() {
        guard !isFinished, isArmed else { return }
        isFinished = true
        onCancel?()
    }

    /// The editor is done (or going away): focus loss no longer saves.
    func finish() { isFinished = true }

    /// A save is pending (read-only, dimmed, showing the saved text) or failed (editable again, text intact).
    func setPending(_ pending: Bool) {
        if pending { isFinished = true }
        isEditable = !pending
        alphaValue = pending ? 0.5 : 1
    }

    /// Focus loss saves again (call after the editor has taken focus back: the focus change that gets it
    /// there must not count as the user's).
    func reopen() { isFinished = false }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            committedByReturn = true
            commit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if !isEditable { onFocusLeftWhilePending?() }
        if !isFinished { committedByReturn = false }
        commit()
    }
}

/// The body as plain multi-line text (no rich text, no link detection) at the body's x and width; it
/// grows with its content. ⌘Return saves, Esc cancels, losing focus saves (the pane drops an unchanged one).
final class TrackerDetailsEditor: NSTextView {
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onResize: (() -> Void)?
    /// Focus actually went into this editor while its save was pending (read-only); being asked does not count.
    var onFocusWhilePending: (() -> Void)?
    /// Focus left this editor while its save was pending.
    var onFocusLeftWhilePending: (() -> Void)?
    private(set) var isFinished = false
    private(set) var original = ""

    override func becomeFirstResponder() -> Bool {
        // Asked to take focus (a click, an explicit request), whether or not a read-only field accepts it.
        if !isEditable { onFocusWhilePending?() }
        return super.becomeFirstResponder()
    }

    static func make(text: String) -> TrackerDetailsEditor {
        let view = TrackerDetailsEditor(usingTextLayoutManager: false)
        view.original = text
        view.string = text
        view.font = TrackerTheme.textFont
        view.textColor = TrackerTheme.text
        view.isRichText = false
        view.importsGraphics = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isEditable = true
        view.isSelectable = true
        view.drawsBackground = true
        view.backgroundColor = TrackerTheme.badgeFill
        view.insertionPointColor = TrackerTheme.text
        view.selectedTextAttributes = Theme.selectionAttributes
        view.textContainerInset = .zero
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.heightTracksTextView = false
        view.allowsUndo = true
        view.setAccessibilityLabel("Details")
        return view
    }

    var typed: String { string }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard let container = textContainer, let layout = layoutManager else { return 17 }
        container.size = NSSize(width: max(width, 1), height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return max(ceil(layout.usedRect(for: container).height), ceil(TrackerTheme.textFont.boundingRectForFont.height))
    }

    func commit() {
        guard !isFinished else { return }
        isFinished = true
        onCommit?(typed)
    }

    func cancel() {
        guard !isFinished else { return }
        isFinished = true
        onCancel?()
    }

    func finish() { isFinished = true }

    func setPending(_ pending: Bool) {
        if pending { isFinished = true }
        isEditable = !pending
        alphaValue = pending ? 0.5 : 1
    }

    /// Focus loss saves again (call after the editor has taken focus back: the focus change that gets it
    /// there must not count as the user's).
    func reopen() { isFinished = false }

    private func isCommandReturn(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.command) && (event.keyCode == 36 || event.keyCode == 76)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, isCommandReturn(event), isEditable else { return super.performKeyEquivalent(with: event) }
        commit()
        return true
    }

    override func keyDown(with event: NSEvent) {
        if isCommandReturn(event), isEditable {
            commit()
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        cancel()
    }

    override func didChangeText() {
        super.didChangeText()
        onResize?()
    }

    override func resignFirstResponder() -> Bool {
        let pending = !isEditable
        let resigned = super.resignFirstResponder()
        if resigned, pending { onFocusLeftWhilePending?() }
        if resigned { commit() }
        return resigned
    }
}

// MARK: - Pane support types

/// One inline editor in the pane: what it edits, the board version it was opened against, the row as it
/// was then, and where focus goes when it closes.
struct TrackerEditSession {
    enum Phase: Equatable {
        case editing
        /// Sent; the editor is read-only and dimmed, showing the saved text.
        case saving
        /// Saved; waiting for a board with at least this version before the editor closes.
        case awaiting(UInt64)
    }

    let kind: TrackerEditKind
    /// The board the row was drawn from when the editor opened.
    var base: TrackerBase
    /// What the editor opened with: a change is a difference from this.
    var original: String
    var row: TrackerItemRow
    weak var priorResponder: NSResponder?
    let priorRole: TrackerControlRole?
    var phase: Phase = .editing
    /// The text last sent: a late answer to it must not close an editor the user has typed in since.
    var sentText: String?
    /// Why the last save was refused (or timed out): shown while the editor stays open.
    var refusal: String?
    /// The pending editor holds focus, or the user tried to focus it while it was pending: only then may a
    /// late refusal put focus back in it.
    var editorWantsFocus = false
    /// A late ok arrived before the board that shows its save: the row refreshes from that board.
    var rowRefreshVersion: UInt64?

    init(kind: TrackerEditKind, base: TrackerBase, original: String, row: TrackerItemRow,
         priorResponder: NSResponder?, priorRole: TrackerControlRole?) {
        self.kind = kind
        self.base = base
        self.original = original
        self.row = row
        self.priorResponder = priorResponder
        self.priorRole = priorRole
    }
}

/// The quiet one-line notice above the board: an edit that did not happen, or "Removed … Undo". Fixed
/// height while shown, nothing otherwise. The text truncates before it reaches the action button.
final class TrackerNoticeView: NSView {
    override var isFlipped: Bool { true }

    static let height: CGFloat = 28
    /// Clear space between the end of the text's frame and the action button.
    static let actionGap: CGFloat = 8

    let label = NSTextField(labelWithString: "")
    private(set) var text: String?
    private(set) var actionButton: TrackerChipButton?
    private(set) var actionTitle: String?
    private var onAction: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = TrackerTheme.bannerFill.cgColor
        label.font = TrackerTheme.metaFont
        label.textColor = TrackerTheme.text
        label.lineBreakMode = .byTruncatingTail
        label.refusesFirstResponder = true
        label.setAccessibilityRole(.staticText)
        addSubview(label)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }

    var preferredHeight: CGFloat { text == nil ? 0 : Self.height }

    /// Everything the notice says, as the probe reports it ("Removed “Ship it”. Undo").
    var spokenText: String? {
        guard let text else { return nil }
        return [text, actionTitle].compactMap { $0 }.joined(separator: " ")
    }

    func update(_ text: String?, actionTitle: String? = nil, onAction: (() -> Void)? = nil) {
        self.onAction = onAction
        guard text != self.text || actionTitle != self.actionTitle else { return }
        self.text = text
        self.actionTitle = text == nil ? nil : actionTitle
        label.stringValue = text ?? ""
        actionButton?.removeFromSuperview()
        actionButton = nil
        if let title = self.actionTitle {
            let button = TrackerChipButton(text: title, color: TrackerTheme.text, fill: TrackerTheme.badgeFill)
            button.target = self
            button.action = #selector(actionPressed(_:))
            button.setAccessibilityLabel(title)
            addSubview(button)
            actionButton = button
        }
        isHidden = text == nil
        needsLayout = true
    }

    @objc private func actionPressed(_ sender: Any?) {
        onAction?()
    }

    override func layout() {
        super.layout()
        let h = TrackerRowView.hPad
        var right = bounds.width - h
        if let button = actionButton {
            let w = button.fittingWidth
            button.frame = NSRect(x: max(right - w, h), y: floor((Self.height - TrackerRowView.chipHeight) / 2),
                                  width: w, height: TrackerRowView.chipHeight)
            right = button.frame.minX - Self.actionGap
        }
        label.frame = NSRect(x: h, y: 6, width: max(right - h, 1), height: 16)
    }
}

/// An invisible view in the pane that takes first responder only through `TrackerPaneView.focusSink()`,
/// so a mouse edit leaves ⌘Z / ⇧⌘Z addressed to the pane's own undo. No focus ring, no drawing.
final class TrackerFocusSink: NSView, NSMenuItemValidation {
    var allowsFocus = false
    weak var pane: TrackerPaneView?

    override var acceptsFirstResponder: Bool { allowsFocus }
    override var focusRingType: NSFocusRingType {
        get { .none }
        set {}
    }
    override func draw(_ dirtyRect: NSRect) {}

    @objc func undo(_ sender: Any?) { pane?.performUndo() }
    @objc func redo(_ sender: Any?) { pane?.performRedo() }

    override var undoManager: UndoManager? { pane?.editing.undoManager }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let manager = pane?.editing.undoManager else { return false }
        switch menuItem.action {
        case #selector(undo(_:)):
            menuItem.title = manager.undoMenuItemTitle
            return manager.canUndo
        case #selector(redo(_:)):
            menuItem.title = manager.redoMenuItemTitle
            return manager.canRedo
        default:
            return false
        }
    }
}

/// The disclosure triangle, with VoiceOver's actions asked for when VoiceOver looks (see `TrackerTickButton`).
final class TrackerDisclosureButton: NSButton {
    var liveCustomActions: (() -> [NSAccessibilityCustomAction])?
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? { liveCustomActions?() }
}
