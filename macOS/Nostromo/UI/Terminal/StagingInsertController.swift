import AppKit
import Combine

/// What the insert flow needs from the terminal view (`NostromoTerminalView`; fakes in tests), so the
/// flow can be driven without SwiftTerm.
protocol StagingInsertTarget: AnyObject {
    var isAlternateScreen: Bool { get }
    var bracketedPasteMode: Bool { get }
    /// Sends `bytes` to the shell as the user's own input (`autoReply: false`: the daemon counts it as activity).
    /// False when nothing went out (refused, or the terminal could not take it): nothing was placed.
    func sendStagedBytes(_ bytes: [UInt8]) -> Bool
    /// The terminal view takes the keyboard, so the next Enter goes to the shell.
    func focusTerminal()
}

/// What `StagingInsertController` did with a request.
enum StagingInsertResult: Equatable {
    /// The text is at the prompt (`bytes`: the UTF-8 count of the text).
    case inserted(bytes: Int)
    /// Nothing was sent; the drawer shows this reason.
    case refused(StagingDisabledReason)
    /// The click was not a person's (synthetic, stale, another window, not the left single click). Reported.
    case notAPerson
    /// Remove, Archive or Clear all went to the daemon.
    case done
    /// The entry was removed or the list is gone, or there is no terminal. Nothing happens.
    case gone
    /// The row matches a destructive pattern in a production-treated pane: the confirm sheet is up (or
    /// already was). Nothing was sent.
    case confirming
}

/// The terminal and this window, as the host knows them.
struct StagingContext: Equatable {
    var terminalId: String
    var kind: TerminalKind?
    var status: TerminalStatus?
    var isMirror: Bool
    var target: TerminalTarget? = nil
}

/// The insert flow, with every decision in one place:
///
/// 1. A person's gesture (`TerminalInputGuard.allowsControl`); otherwise nothing is sent and the refusal is
///    reported (`stage_insert`).
/// 2. The disabled reasons decided at the mouse-down or key-down (`StagingSnapshot`), then a re-check of
///    what may have changed since: the entry still exists, staging is still on, the shell is running, this
///    window still drives it, no full-screen program, no paste still going out, nothing may be on the line
///    (production-treated panes), the text insertable and the paste policy says `.send`.
/// 3. A row that matches a destructive pattern in a pane that is production-treated at the snapshot **or** now
///    asks first on a sheet (`StagingConfirmSheet`); with no window to hang the sheet on, it is refused.
/// 4. The bytes are built from the **snapshot's** text, sent exactly once, then (only if the terminal took
///    them) the terminal takes the keyboard and the daemon is told how many bytes were placed (and whether
///    a sheet confirmed it). A line break is never added: only the user's Enter runs it.
///
/// Remove, Archive, Clear all, the switches and Copy are gated here too. Holds its target weakly.
final class StagingInsertController {

    typealias Gate = (_ event: NSEvent?, _ control: NSView, _ fromMenu: Bool) -> Bool

    private let staging: TerminalStagingStore
    private let sessions: TerminalSessionStore
    private weak var target: StagingInsertTarget?
    private let context: () -> StagingContext?
    private let gate: Gate
    private let pasteboard: NSPasteboard

    /// The confirmation on screen, if any (one per controller; one per window).
    private(set) var confirmSheet: StagingConfirmSheet?
    private var confirmTerminalId: String?
    private var confirmObservation: TerminalStagingStore.Observation?
    private var sessionSubscription: AnyCancellable?
    private var windowClosed: NSObjectProtocol?
    /// What a confirmed Insert did (the drawer shows a refusal).
    var onConfirmedResult: ((StagingInsertResult) -> Void)?

    init(staging: TerminalStagingStore = .shared, sessions: TerminalSessionStore = .shared,
         target: StagingInsertTarget?, pasteboard: NSPasteboard = .general,
         context: @escaping () -> StagingContext?,
         gate: @escaping Gate = { TerminalInputGuard.allowsControl(event: $0, control: $1, fromMenu: $2) }) {
        self.staging = staging
        self.sessions = sessions
        self.target = target
        self.pasteboard = pasteboard
        self.context = context
        self.gate = gate
    }

    deinit {
        if let windowClosed { NotificationCenter.default.removeObserver(windowClosed) }
    }

    // MARK: - State for the drawer

    /// The terminal id, when the host knows it.
    var terminalId: String? { context()?.terminalId }

    func environment() -> StagingEnvironment? {
        guard let ctx = context() else { return nil }
        return StagingEnvironment(isMirror: ctx.isMirror,
                                  daemonConnected: !sessions.isDaemonUnavailable(terminalId: ctx.terminalId),
                                  status: ctx.status, kind: ctx.kind,
                                  isAlternateScreen: target?.isAlternateScreen ?? false,
                                  isSendingInput: sessions.isSendingInput(terminalId: ctx.terminalId),
                                  target: ctx.target,
                                  foreground: staging.list(for: ctx.terminalId)?.foreground,
                                  lineMayHaveText: sessions.lineMayHaveText(terminalId: ctx.terminalId))
    }

    // MARK: - Insert

    /// Taken at mouse-down (or key-down): what the row says right now. Nil when there is nothing to insert.
    func snapshot(entryId: String) -> StagingSnapshot? {
        guard let ctx = context(), let env = environment(),
              let entry = staging.entry(terminalId: ctx.terminalId, entryId: entryId) else { return nil }
        var snapshot = StagingDrawerModel.snapshot(terminalId: ctx.terminalId, entry: entry, env: env,
                                                   shownSince: staging.shownSince(terminalId: ctx.terminalId, entryId: entryId),
                                                   now: staging.now)
        snapshot.generation = staging.readingGeneration(for: ctx.terminalId)
        return snapshot
    }

    /// A click that can never insert (a right or control click, the second click of a double-click):
    /// nothing is sent, and it is reported like any other refusal to insert.
    func refuseClick() {
        guard let id = terminalId else { return }
        sessions.reportRefusal(terminalId: id, op: .stageInsert)
    }

    /// The one door to the shell. `confirmed` is true only for the Insert button of the confirm sheet (the
    /// sheet itself asked the guard first; it is asked again here with the same event).
    @discardableResult
    func insert(_ snapshot: StagingSnapshot, event: NSEvent?, control: NSView, confirmed: Bool = false) -> StagingInsertResult {
        guard gate(event, control, false) else {
            sessions.reportRefusal(terminalId: snapshot.terminalId, op: confirmed ? .stagingConfirm : .stageInsert)
            return .notAPerson
        }
        if let reason = snapshot.reason {
            if reason == .justChanged { staging.reportUIEvent(.justChanged, terminalId: snapshot.terminalId) }
            return .refused(reason)
        }
        guard let ctx = context(), ctx.terminalId == snapshot.terminalId,
              staging.entry(terminalId: ctx.terminalId, entryId: snapshot.entryId) != nil,
              staging.isStagingOn(terminalId: ctx.terminalId),
              let env = environment() else { return .gone }
        // The drawer moved (or the pane's foreground changed) since the click began: nothing is where it was.
        // The confirm sheet's own Insert is exempt: the person has been reading the sheet, not the row.
        if !confirmed && snapshot.generation != staging.readingGeneration(for: ctx.terminalId) {
            staging.reportUIEvent(.justChanged, terminalId: ctx.terminalId)
            return .refused(.justChanged)
        }
        if let reason = StagingDrawerModel.sharedReason(env) { return .refused(reason) }
        let production = snapshot.safety.isProduction || env.safety.isProduction
        if production && StagingHazards.usesHistoryExpansion(snapshot.command) { return .refused(.historyExpansion) }
        guard AgentDisplayText.isInsertable(snapshot.command),
              PastePolicy.decide(kind: ctx.kind, text: snapshot.command) == .send,
              let target else { return .refused(.notInsertable) }
        let matches = StagingDestructivePatterns.matches(snapshot.command)
        if production && !matches.isEmpty && !confirmed {
            return presentConfirmation(snapshot, env: env, matches: matches, control: control)
        }
        let bytes = StagingDrawerModel.bytes(for: snapshot.command, bracketedPaste: target.bracketedPasteMode)
        guard target.sendStagedBytes(bytes) else { return .refused(.notSent) }
        target.focusTerminal()
        let count = snapshot.command.utf8.count
        staging.reportInserted(terminalId: ctx.terminalId, entryId: snapshot.entryId, bytes: count, confirmed: confirmed)
        staging.notePlaced(terminalId: ctx.terminalId, entryId: snapshot.entryId, command: snapshot.command)
        return .inserted(bytes: count)
    }

    // MARK: - The confirm sheet

    private func presentConfirmation(_ snapshot: StagingSnapshot, env: StagingEnvironment, matches: [String],
                                     control: NSView) -> StagingInsertResult {
        // Without a window to hang the question on: refuse. Nothing falls through to an unconfirmed insert.
        guard let window = control.window else { return .refused(.notSent) }
        // One sheet per window: activating rows while one is up does nothing.
        guard confirmSheet == nil, window.attachedSheet == nil else { return .confirming }
        let safety = env.safety.isProduction ? env.safety : snapshot.safety
        let terminalId = snapshot.terminalId
        let production = true
        let sheet = StagingConfirmSheet(
            title: StagingDrawerModel.confirmTitle(safety),
            targetLine: StagingDrawerModel.confirmTargetLine(safety, target: env.target),
            command: snapshot.command, matches: matches,
            hazardLabels: StagingDrawerModel.hazardLabels(for: snapshot.command, production: production),
            gate: { [weak self] event, button in self?.gate(event, button, false) ?? false },
            onInsert: { [weak self] button in
                guard let self else { return }
                self.clearConfirmation()
                let result = self.insert(snapshot, event: NSApp.currentEvent, control: button, confirmed: true)
                self.onConfirmedResult?(result)
            },
            onCancel: { [weak self] in
                self?.clearConfirmation()
                self?.staging.reportUIEvent(.confirmCancelled, terminalId: terminalId)
            },
            onRefused: { [weak self] in self?.sessions.reportRefusal(terminalId: terminalId, op: .stagingConfirm) })
        guard let sheetWindow = sheet.window else { return .refused(.notSent) }
        confirmSheet = sheet
        confirmTerminalId = terminalId
        watchConfirmation(terminalId: terminalId, window: window)
        // The completion keeps the sheet's controller alive while it is up: its buttons' targets are weak.
        window.beginSheet(sheetWindow) { [weak self, sheet] _ in
            withExtendedLifetime(sheet) { if self?.confirmSheet === sheet { self?.clearConfirmation() } }
        }
        return .confirming
    }

    /// The sheet closes, sending nothing, when the terminal ends or closes, the list goes, staging is turned
    /// off or the parent window closes.
    private func watchConfirmation(terminalId: String, window: NSWindow) {
        confirmObservation = staging.observe(terminalId: terminalId) { [weak self] in
            guard let self else { return }
            if self.staging.list(for: terminalId) == nil || !self.staging.isStagingOn(terminalId: terminalId) {
                self.dismissConfirmation()
            }
        }
        sessionSubscription = sessions.changes.sink { [weak self] change in
            switch change {
            case .info(let info) where info.terminalId == terminalId && info.status == .ended: self?.dismissConfirmation()
            case .closed(let closed) where closed.terminalId == terminalId: self?.dismissConfirmation()
            case .availability(daemonReachable: false): self?.dismissConfirmation()
            default: break
            }
        }
        windowClosed = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            self?.dismissConfirmation()
        }
    }

    /// Closes the sheet on screen (if any) without sending anything.
    func dismissConfirmation() {
        let sheet = confirmSheet
        clearConfirmation()
        sheet?.dismiss()
    }

    private func clearConfirmation() {
        confirmSheet = nil
        confirmTerminalId = nil
        confirmObservation = nil
        sessionSubscription = nil
        if let windowClosed { NotificationCenter.default.removeObserver(windowClosed) }
        windowClosed = nil
    }

    // MARK: - Copy, Remove, Archive, Clear, switches (menus)

    /// Whether the entry's current text has been on screen long enough to be read (the 1.5 s rule).
    /// Copy asks it too: a command that just changed is not put on the pasteboard unread.
    func isReadable(entryId: String) -> Bool {
        guard let id = terminalId else { return false }
        return StagingDrawerModel.hasBeenReadable(shownSince: staging.shownSince(terminalId: id, entryId: entryId),
                                                  now: staging.now)
    }

    /// Copy: exactly the command, as a string. Works in a mirror and on a row that cannot be placed, but
    /// not within the reading delay of a change.
    @discardableResult
    func copy(entryId: String, event: NSEvent?, control: NSView) -> Bool {
        guard let id = terminalId else { return false }
        guard gate(event, control, true) else {
            sessions.reportRefusal(terminalId: id, op: .stagingCopy)
            return false
        }
        guard let entry = staging.entry(terminalId: id, entryId: entryId), isReadable(entryId: entryId) else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(entry.command, forType: .string)
    }

    /// Remove one entry. The driver window only.
    @discardableResult
    func remove(entryId: String, event: NSEvent?, control: NSView) -> StagingInsertResult {
        guard let ctx = context() else { return .gone }
        guard gate(event, control, true) else {
            sessions.reportRefusal(terminalId: ctx.terminalId, op: .stagingRemove)
            return .notAPerson
        }
        if ctx.isMirror { return .refused(.mirror) }
        guard staging.entry(terminalId: ctx.terminalId, entryId: entryId) != nil else { return .gone }
        staging.remove(terminalId: ctx.terminalId, entryId: entryId)
        return .done
    }

    /// Archive placed entries (the row's Archive, its context menu and VoiceOver action, and Archive Placed
    /// Commands): each moves to the drawer's footer and leaves the daemon's list. Only an entry that was placed
    /// is archived. The driver window only.
    @discardableResult
    func archive(entryIds: [String], event: NSEvent?, control: NSView, fromMenu: Bool) -> StagingInsertResult {
        guard let ctx = context() else { return .gone }
        guard gate(event, control, fromMenu) else {
            sessions.reportRefusal(terminalId: ctx.terminalId, op: .stagingArchive)
            return .notAPerson
        }
        if ctx.isMirror { return .refused(.mirror) }
        var archived = false
        for id in entryIds {
            guard let entry = staging.entry(terminalId: ctx.terminalId, entryId: id), entry.insertedCount > 0 else { continue }
            staging.archive(terminalId: ctx.terminalId, entryId: id, auto: false)
            archived = true
        }
        return archived ? .done : .gone
    }

    /// Archive Placed Commands: one archive for every placed (✓) entry.
    @discardableResult
    func archivePlaced(event: NSEvent?, control: NSView, fromMenu: Bool) -> StagingInsertResult {
        let ids = terminalId.flatMap { staging.list(for: $0) }?.entries.filter { $0.insertedCount > 0 }.map(\.id) ?? []
        return archive(entryIds: ids, event: event, control: control, fromMenu: fromMenu)
    }

    /// Clear every entry. The driver window only.
    @discardableResult
    func clearAll(event: NSEvent?, control: NSView) -> StagingInsertResult {
        guard let ctx = context() else { return .gone }
        guard gate(event, control, true) else {
            sessions.reportRefusal(terminalId: ctx.terminalId, op: .stagingClear)
            return .notAPerson
        }
        if ctx.isMirror { return .refused(.mirror) }
        guard staging.list(for: ctx.terminalId) != nil else { return .gone }
        staging.clear(terminalId: ctx.terminalId)
        return .done
    }

    /// Archive Commands After I Run Them (memory only; off at every launch). A person's menu choice only.
    @discardableResult
    func setAutoArchive(_ on: Bool, event: NSEvent?, control: NSView) -> Bool {
        guard gate(event, control, true) else {
            sessions.reportRefusal(terminalId: terminalId, op: .stagingSwitch)
            return false
        }
        TerminalStagingStore.setAutoArchive(on)
        return true
    }

    /// Let Agents Stage Commands Here: the daemon answers with a fresh frame (the checkmark follows it).
    @discardableResult
    func setStagingEnabledHere(_ on: Bool, event: NSEvent?, control: NSView, fromMenu: Bool) -> Bool {
        guard let id = terminalId else { return false }
        guard gate(event, control, fromMenu) else {
            sessions.reportRefusal(terminalId: id, op: .stagingSwitch)
            return false
        }
        staging.setEnabled(terminalId: id, enabled: on)
        return true
    }

    /// The drawer's close and reopen controls, and the header chip: a person's act only.
    func allowsHideControl(event: NSEvent?, control: NSView, fromMenu: Bool) -> Bool {
        guard gate(event, control, fromMenu) else {
            sessions.reportRefusal(terminalId: terminalId, op: .stagingHide)
            return false
        }
        return true
    }

    /// Let Agents Stage Commands in Terminals (the Terminal menu): saved for the next launch, hides every
    /// drawer now, and tells the daemon. A person's menu choice only.
    @discardableResult
    static func setGlobalStaging(_ on: Bool, event: NSEvent?, control: NSView, staging: TerminalStagingStore = .shared,
                                 sessions: TerminalSessionStore = .shared,
                                 gate: Gate = { TerminalInputGuard.allowsControl(event: $0, control: $1, fromMenu: $2) }) -> Bool {
        guard gate(event, control, true) else {
            sessions.reportRefusal(terminalId: nil, op: .stagingSwitch)
            return false
        }
        staging.setGlobalEnabled(on)
        return true
    }
}
