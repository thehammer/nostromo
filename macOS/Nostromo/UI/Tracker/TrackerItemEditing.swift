import AppKit
import Combine
import NostromoKit

/// Which text of an item an inline editor changes.
enum TrackerEditKind: String {
    case title
    case details
}

/// The tracker pane's edit controller (one per pane): builds the `tracker_edit` ops for what the user
/// does in the pane, sends them, takes the daemon's answers, tells the pane why an edit did not
/// happen, and registers the inverse of every undoable edit with the pane's own `UndoManager`.
///
/// There is no optimistic display: nothing here changes a row. The row changes when the daemon's board
/// arrives, so the pane always shows the file's truth (the strip and the sidebar pill follow the same
/// board). Rows stay dumb: they call the pane, the pane calls this.
final class TrackerItemEditing {
    /// `(tag, request id, base version, ops)`; false when the frame was not written.
    typealias Sender = (String, String, UInt64, [TrackerPaneOpWire]) -> Bool

    /// What became of one send.
    enum Outcome: Equatable {
        /// The daemon applied it: the board it produced has `version` (it may already be here).
        case saved(version: UInt64, created: [String])
        case failed(String)
    }

    /// No answer within this long is a failure.
    static let answerTimeout: TimeInterval = 5
    /// A notice goes away after this long, or at the next successful edit.
    static let noticeLifetime: TimeInterval = 6

    /// Undo and redo of pane edits. Never the window's: the composer's typing undo is not touched.
    let undoManager: UndoManager = {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }()

    /// The quiet one-line notice above the board, or nil.
    private(set) var notice: String?
    var onNotice: ((String?) -> Void)?
    /// An edit touching these items was confirmed (ids, board version): the pane does not flash them.
    var onConfirmed: (([String], UInt64) -> Void)?

    private let tag: String
    private let send: Sender
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let currentVersion: () -> UInt64
    private let itemExists: (String) -> Bool
    private var pending: [String: (ids: [String], completion: (Outcome) -> Void)] = [:]
    private var sequence = 0
    private var noticeGeneration = 0
    /// The status an item had before this pane ticked it (what an untick goes back to).
    private var statusBeforeTick: [String: String] = [:]
    private var subscription: AnyCancellable?

    init(tag: String,
         results: AnyPublisher<TrackerEditResultWire, Never>,
         send: @escaping Sender,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void,
         currentVersion: @escaping () -> UInt64,
         itemExists: @escaping (String) -> Bool) {
        self.tag = tag
        self.send = send
        self.schedule = schedule
        self.currentVersion = currentVersion
        self.itemExists = itemExists
        subscription = results
            .filter { $0.tag == tag }
            .sink { [weak self] in self?.receive($0) }
    }

    /// The items an edit still waiting for its answer touches.
    var inFlightItemIds: Set<String> { Set(pending.values.flatMap(\.ids)) }

    // MARK: - Actions

    /// The tick: done, or (on a done item) the status it had before this pane ticked it, else todo.
    func tick(_ item: TrackerItemRow, baseVersion: UInt64) {
        guard item.isTickable else { return }
        if item.isDone {
            setStatus(item, to: statusBeforeTick[item.id] ?? "todo", baseVersion: baseVersion, name: "Tick")
        } else {
            statusBeforeTick[item.id] = item.status.wireName
            setStatus(item, to: "done", baseVersion: baseVersion, name: "Tick")
        }
    }

    func setStatus(_ item: TrackerItemRow, to status: String, baseVersion: UInt64, name: String = "Status") {
        guard item.isStatusEditable, status != item.status.wireName else { return }
        perform([.status(id: item.id, status: status)], inverse: [.status(id: item.id, status: item.status.wireName)],
                name: name, baseVersion: baseVersion)
    }

    /// The title typed into the editor. Returns false (nothing sent) when it is empty after cleaning.
    @discardableResult
    func saveTitle(_ item: TrackerItemRow, typed: String, baseVersion: UInt64,
                   completion: @escaping (Outcome) -> Void) -> Bool {
        let title = TrackerTitle.normalizedTitle(typed)
        guard !title.isEmpty else { return false }
        let legacy = TrackerTitle.split(item.editText).rule != .whole
        let op: TrackerPaneOpWire
        var restoresBody = true
        if legacy || title.count > TrackerTitle.maxChars {
            let restructured = TrackerTitle.restructure(text: item.editText, note: item.editNote, newTitle: title)
            op = .edit(id: item.id, title: restructured.title, text: nil, body: restructured.body)
        } else {
            op = .edit(id: item.id, title: title, text: nil, body: nil)
            restoresBody = false
        }
        perform([op], inverse: [Self.restoreText(item, includingNote: restoresBody)], name: "Title Edit",
                baseVersion: baseVersion, completion: completion)
        return true
    }

    /// The details typed into the editor (the note; for a legacy item the text after the title too).
    func saveDetails(_ item: TrackerItemRow, typed: String, baseVersion: UInt64,
                     completion: @escaping (Outcome) -> Void) {
        let body = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let legacy = TrackerTitle.split(item.editText).rule != .whole
        let op: TrackerPaneOpWire = legacy
            ? .edit(id: item.id, title: TrackerTitle.editableTitle(text: item.editText), text: nil, body: body)
            : .edit(id: item.id, title: nil, text: nil, body: body)
        perform([op], inverse: [Self.restoreText(item, includingNote: true, textToo: legacy)], name: "Details Edit",
                baseVersion: baseVersion, completion: completion)
    }

    /// Keep or use a conflict's losing value. `keep: losing` is undoable (an edit back to the kept value);
    /// `keep: current` is not.
    func resolve(_ entry: TrackerConflictEntry, keep: TrackerConflictKeepWire, baseVersion: UInt64) {
        let op = TrackerPaneOpWire.resolveConflict(id: entry.itemId, field: entry.field, keep: keep,
                                                   conflictId: entry.conflictId)
        guard keep == .losing, let inverse = entry.inverse else {
            submit([op], baseVersion: baseVersion, completion: { _ in })
            return
        }
        perform([op], inverse: [inverse], name: "Conflict Choice", baseVersion: baseVersion)
    }

    /// "It's fine, share it". Not undoable. Never combined with an edit of the same item in one batch.
    func clearBadge(itemId: String, baseVersion: UInt64) {
        submit([.clearBadge(id: itemId)], baseVersion: baseVersion, completion: { _ in })
    }

    // MARK: - Sending

    /// Send `ops` and register `inverse` for ⌘Z (and, from inside the undo, the redo).
    private func perform(_ ops: [TrackerPaneOpWire], inverse: [TrackerPaneOpWire], name: String,
                         baseVersion: UInt64, completion: ((Outcome) -> Void)? = nil) {
        let ids = Set(ops.compactMap(Self.itemId)).union(inverse.compactMap(Self.itemId))
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { me in
            guard ids.allSatisfy(me.itemExists) else {
                me.showNotice("Couldn't undo: the item was removed.")
                return
            }
            me.perform(inverse, inverse: ops, name: name, baseVersion: me.currentVersion())
        }
        undoManager.setActionName(name)
        undoManager.endUndoGrouping()
        submit(ops, baseVersion: baseVersion) { [weak self] outcome in
            if case .failed = outcome, let me = self { me.undoManager.removeAllActions(withTarget: me) }
            completion?(outcome)
        }
    }

    func submit(_ ops: [TrackerPaneOpWire], baseVersion: UInt64, completion: @escaping (Outcome) -> Void) {
        sequence += 1
        let requestId = "pane-\(tag)-\(sequence)"
        pending[requestId] = (ops.compactMap(Self.itemId), completion)
        guard send(tag, requestId, baseVersion, ops) else {
            fail(requestId, "Not saved: Nostromo isn't connected to its daemon.")
            return
        }
        schedule(Self.answerTimeout) { [weak self] in
            self?.fail(requestId, "Not saved: the daemon didn't answer in time.")
        }
    }

    private func receive(_ result: TrackerEditResultWire) {
        guard let entry = pending.removeValue(forKey: result.requestId) else { return }
        if result.ok {
            showNotice(nil)
            onConfirmed?(entry.ids, result.version)
            entry.completion(.saved(version: result.version, created: result.created))
        } else {
            let message = Self.message(for: result.error)
            showNotice(message)
            entry.completion(.failed(message))
        }
    }

    private func fail(_ requestId: String, _ message: String) {
        guard let entry = pending.removeValue(forKey: requestId) else { return }
        showNotice(message)
        entry.completion(.failed(message))
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

    /// One plain sentence for each reason the daemon refuses an edit.
    static func message(for error: TrackerEditErrorWire?) -> String {
        let reason = error?.reason ?? ""
        switch error?.code ?? "" {
        case "board_unreadable": return "Not saved: the board file can't be read" + (reason.isEmpty ? "." : " (\(reason)).")
        case "board_missing": return "Not saved: the board file is gone."
        case "unknown_item": return "Not saved: that item is no longer on the board."
        case "not_operator_app": return "Not saved: only the Nostromo app can change the board."
        case "board_too_large": return "Not saved: the board is too large to edit."
        case "invalid_args":
            if reason.contains("no longer kept") { return "That conflict is no longer there: look again." }
            if reason.contains("look again") { return "Not saved: that changed since you looked. Look again." }
            return "Not saved: " + (reason.isEmpty ? "the change isn't valid." : reason)
        case let code: return "Not saved" + (code.isEmpty ? "." : " (\(code)).")
        }
    }

    // MARK: - Inverses

    /// An edit that puts the item's old text (and note) back exactly.
    private static func restoreText(_ item: TrackerItemRow, includingNote: Bool, textToo: Bool = true) -> TrackerPaneOpWire {
        .edit(id: item.id, title: nil, text: textToo ? item.editText : nil, body: includingNote ? (item.editNote ?? "") : nil)
    }

    private static func itemId(of op: TrackerPaneOpWire) -> String? {
        switch op {
        case .status(let id, _), .edit(let id, _, _, _), .clearBadge(let id), .resolveConflict(let id, _, _, _): return id
        default: return nil
        }
    }
}

// MARK: - Row controls

/// A control inside an item row that keyboard focus returns to after the row is rebuilt.
enum TrackerControlRole: String, CaseIterable {
    case tick, disclosure, conflict, sensitive, editTitle, editDetails, status
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
    /// Focus events before the editor is set up (arming) are not the user's: they save and cancel nothing.
    private var isArmed = false
    let original: String

    func arm() { isArmed = true }

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
        commit()
    }
}

/// The body as plain multi-line text (no rich text, no link detection) at the body's x and width; it
/// grows with its content. ⌘Return saves, Esc cancels, losing focus saves (the pane drops an unchanged one).
final class TrackerDetailsEditor: NSTextView {
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onResize: (() -> Void)?
    private(set) var isFinished = false
    private(set) var original = ""

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
        let resigned = super.resignFirstResponder()
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
    let baseVersion: UInt64
    /// What the editor opened with: a change is a difference from this.
    let original: String
    let row: TrackerItemRow
    weak var priorResponder: NSResponder?
    let priorRole: TrackerControlRole?
    var phase: Phase = .editing

    init(kind: TrackerEditKind, baseVersion: UInt64, original: String, row: TrackerItemRow,
         priorResponder: NSResponder?, priorRole: TrackerControlRole?) {
        self.kind = kind
        self.baseVersion = baseVersion
        self.original = original
        self.row = row
        self.priorResponder = priorResponder
        self.priorRole = priorRole
    }
}

/// The quiet one-line notice about an edit that did not happen. Fixed height while shown, nothing otherwise.
final class TrackerNoticeView: NSView {
    override var isFlipped: Bool { true }

    static let height: CGFloat = 28

    let label = NSTextField(labelWithString: "")
    private(set) var text: String?

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

    func update(_ text: String?) {
        guard text != self.text else { return }
        self.text = text
        label.stringValue = text ?? ""
        isHidden = text == nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: TrackerRowView.hPad, y: 6, width: max(bounds.width - TrackerRowView.hPad * 2, 1), height: 16)
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
