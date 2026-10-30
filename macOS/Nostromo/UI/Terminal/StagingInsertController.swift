import AppKit

/// What the insert flow needs from the terminal view (`NostromoTerminalView`; fakes in tests), so the
/// flow can be driven without SwiftTerm.
protocol StagingInsertTarget: AnyObject {
    var isAlternateScreen: Bool { get }
    var bracketedPasteMode: Bool { get }
    /// Sends `bytes` to the shell as the user's own input (`autoReply: false`: the daemon counts it as activity).
    func sendStagedBytes(_ bytes: [UInt8])
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
    /// Remove or Clear all went to the daemon.
    case done
    /// The entry was removed or the list is gone, or there is no terminal. Nothing happens.
    case gone
}

/// The terminal and this window, as the host knows them.
struct StagingContext: Equatable {
    var terminalId: String
    var kind: TerminalKind?
    var status: TerminalStatus?
    var isMirror: Bool
}

/// The insert flow, with every decision in one place:
///
/// 1. A person's gesture (`TerminalInputGuard.allowsControl`); otherwise nothing is sent and the refusal is
///    reported (`stage_insert`).
/// 2. The disabled reasons decided at the mouse-down or key-down (`StagingSnapshot`), then a re-check of
///    what may have changed since: the entry still exists, the shell is running, this window still
///    drives it, no full-screen program, no paste still going out, the text insertable and the paste
///    policy says `.send`.
/// 3. The bytes are built from the **snapshot's** text, sent exactly once, then the terminal takes the
///    keyboard and the daemon is told how many bytes were placed. A line break is never added: only the
///    user's Enter runs it.
///
/// Remove, Clear all and Copy are gated here too. Holds its target weakly.
final class StagingInsertController {

    typealias Gate = (_ event: NSEvent?, _ control: NSView, _ fromMenu: Bool) -> Bool

    private let staging: TerminalStagingStore
    private let sessions: TerminalSessionStore
    private weak var target: StagingInsertTarget?
    private let context: () -> StagingContext?
    private let gate: Gate
    private let pasteboard: NSPasteboard

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

    // MARK: - State for the drawer

    /// The terminal id, when the host knows it.
    var terminalId: String? { context()?.terminalId }

    func environment() -> StagingEnvironment? {
        guard let ctx = context() else { return nil }
        return StagingEnvironment(isMirror: ctx.isMirror,
                                  daemonConnected: !sessions.isDaemonUnavailable(terminalId: ctx.terminalId),
                                  status: ctx.status, kind: ctx.kind,
                                  isAlternateScreen: target?.isAlternateScreen ?? false,
                                  isSendingInput: sessions.isSendingInput(terminalId: ctx.terminalId))
    }

    // MARK: - Insert

    /// Taken at mouse-down (or key-down): what the row says right now. Nil when there is nothing to insert.
    func snapshot(entryId: String) -> StagingSnapshot? {
        guard let ctx = context(), let env = environment(),
              let entry = staging.entry(terminalId: ctx.terminalId, entryId: entryId) else { return nil }
        return StagingDrawerModel.snapshot(terminalId: ctx.terminalId, entry: entry, env: env,
                                           shownSince: staging.shownSince(terminalId: ctx.terminalId, entryId: entryId),
                                           now: staging.now)
    }

    /// A click that can never insert (a right or control click, the second click of a double-click):
    /// nothing is sent, and it is reported like any other refusal to insert.
    func refuseClick() {
        guard let id = terminalId else { return }
        sessions.reportRefusal(terminalId: id, op: .stageInsert)
    }

    @discardableResult
    func insert(_ snapshot: StagingSnapshot, event: NSEvent?, control: NSView) -> StagingInsertResult {
        guard gate(event, control, false) else {
            sessions.reportRefusal(terminalId: snapshot.terminalId, op: .stageInsert)
            return .notAPerson
        }
        if let reason = snapshot.reason { return .refused(reason) }
        guard let ctx = context(), ctx.terminalId == snapshot.terminalId,
              staging.entry(terminalId: ctx.terminalId, entryId: snapshot.entryId) != nil,
              let env = environment() else { return .gone }
        if let reason = StagingDrawerModel.sharedReason(env) { return .refused(reason) }
        guard AgentDisplayText.isInsertable(snapshot.command),
              PastePolicy.decide(kind: ctx.kind, text: snapshot.command) == .send,
              let target else { return .refused(.notInsertable) }
        let bytes = StagingDrawerModel.bytes(for: snapshot.command, bracketedPaste: target.bracketedPasteMode)
        target.sendStagedBytes(bytes)
        target.focusTerminal()
        let count = snapshot.command.utf8.count
        staging.reportInserted(terminalId: ctx.terminalId, entryId: snapshot.entryId, bytes: count)
        return .inserted(bytes: count)
    }

    // MARK: - Copy, Remove, Clear (menus)

    /// Copy: exactly the command, as a string. Works in a mirror too.
    @discardableResult
    func copy(entryId: String, event: NSEvent?, control: NSView) -> Bool {
        guard let id = terminalId else { return false }
        guard gate(event, control, true) else {
            sessions.reportRefusal(terminalId: id, op: .stagingCopy)
            return false
        }
        guard let entry = staging.entry(terminalId: id, entryId: entryId) else { return false }
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
}
