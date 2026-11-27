import AppKit
import Combine
import Foundation

/// What the store asks the daemon through; `NostromodClient` is the real one, tests pass a recorder.
protocol ConversationHistorySending: AnyObject {
    var daemonAdvertisesConversationHistory: Bool { get }
    func conversationHistoryGet(requestId: String)
    func conversationResume(requestId: String, id: String, newTag: String, place: String?,
                            noCodebaseFolder: String?, confirmActiveElsewhere: Bool, agent: String?)
    func conversationHistoryRename(requestId: String, id: String, title: String?)
    func conversationResumeRelease(tag: String)
    func conversationHistoryRemove(requestId: String, id: String)
    func conversationHistoryRestore(requestId: String, id: String)
    func conversationHistoryPurgeRemoved(requestId: String)
    func conversationHistorySettingsSet(requestId: String, firstPromptsEnabled: Bool)
    func conversationHistoryIncludeOutsideSet(requestId: String, includeOutside: Bool)
}
extension NostromodClient: ConversationHistorySending {}

/// The daemon's conversation history as the Resume tab sees it, and the resume rules' Mac side.
/// App-wide (`shared`); main thread. Nothing here is persisted: the history lives in the daemon.
final class ConversationHistoryStore {
    static let shared = ConversationHistoryStore()

    /// How a resume ended, for the sheet.
    enum ResumeResult: Equatable {
        case opened            // a new focus was created
        case switched          // an existing focus was selected
        case refused(String)   // fixed words: not_found / unavailable / folder_gone / starting
        case waitingToStart    // the daemon is starting; retrying
        case gaveUp            // still starting after the retry window
    }

    var sender: ConversationHistorySending?
    /// The latest listing (nil before the first answer).
    private(set) var history: ConversationHistoryWire?
    /// Something changed: a listing arrived, or the daemon said the history changed.
    let changes = PassthroughSubject<Void, Never>()
    /// Fires when `sensitivityKnown` becomes true.
    let knownChanges = PassthroughSubject<Void, Never>()
    /// A resume's outcome (row id, result).
    let resumeResults = PassthroughSubject<(String, ResumeResult), Never>()

    /// Create the focus and switch to it. Set by whoever owns the window (`MainLayout`).
    var commitFocus: ((Focus) -> Void)?
    /// Select the focus with this session tag, in whichever window shows it. Returns false when none does.
    var switchToTag: ((String) -> Bool)?
    /// A resumed focus could not open its conversation here; the transcript path (if known) is for Finder.
    var onResumeFailed: ((String?) -> Void)?

    private let focusStore: () -> FocusStore
    private let makeRequestId: () -> String
    private let makeFocusId: () -> String
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let now: () -> Date

    /// request id → what it was for.
    private var pending: [String: (sid: String, focusId: String, tag: String, startedAt: Date, place: String?,
                                  noCodebaseFolder: String?, confirm: Bool, agent: String?)] = [:]
    /// Rows with a resume awaiting its reply: further gestures on them are ignored.
    private var inFlight: Set<String> = []
    /// Tags a `ready` reply reserved → the conversation they hold (for a later failure).
    private var resumedSids: [String: String] = [:]

    static let startRetryInterval: TimeInterval = 1
    static let startRetryWindow: TimeInterval = 30

    init(sender: ConversationHistorySending? = nil,
         focusStore: @escaping () -> FocusStore = { FocusStore.shared },
         makeRequestId: @escaping () -> String = { UUID().uuidString },
         makeFocusId: @escaping () -> String = { UUID().uuidString },
         now: @escaping () -> Date = Date.init,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         }) {
        self.sender = sender
        self.focusStore = focusStore
        self.makeRequestId = makeRequestId
        self.makeFocusId = makeFocusId
        self.now = now
        self.schedule = schedule
    }

    /// The app is quitting: the in-memory listing, first prompts included, is dropped when prompts are off.
    func appWillTerminate() {
        if history?.firstPromptsEnabled == false { history = nil }
    }

    var isSupported: Bool { sender?.daemonAdvertisesConversationHistory == true }

    /// Whether what the daemon knows about which focuses are sensitive has been heard: a listing has been
    /// answered, or a connection came up whose daemon has no listing. False until then, and for good if
    /// the daemon never answers. (Not derived from `history`, which `appWillTerminate` may drop.)
    private(set) var sensitivityKnown = false

    /// The daemon connection came up or went away. On a (re)connect ask for the listing at once, so the
    /// composer history knows which focuses are sensitive before the user can type into one.
    func connectionChanged(_ connected: Bool) {
        guard connected else { return }
        if isSupported {
            refresh()
        } else {
            markSensitivityKnown()
        }
    }

    private func markSensitivityKnown() {
        guard !sensitivityKnown else { return }
        sensitivityKnown = true
        knownChanges.send()
    }

    // MARK: Requests

    func refresh() {
        guard let sender, sender.daemonAdvertisesConversationHistory else { return }
        sender.conversationHistoryGet(requestId: makeRequestId())
    }

    func remove(_ id: String) { sender?.conversationHistoryRemove(requestId: makeRequestId(), id: id) }
    func restore(_ id: String) { sender?.conversationHistoryRestore(requestId: makeRequestId(), id: id) }
    func purgeRemoved() { sender?.conversationHistoryPurgeRemoved(requestId: makeRequestId()) }
    func setFirstPrompts(enabled: Bool) {
        sender?.conversationHistorySettingsSet(requestId: makeRequestId(), firstPromptsEnabled: enabled)
    }
    /// Turn "Include conversations started outside Nostromo" on or off (the daemon keeps it; off deletes its index).
    func setIncludeOutside(_ on: Bool) {
        sender?.conversationHistoryIncludeOutsideSet(requestId: makeRequestId(), includeOutside: on)
    }

    /// Give a conversation a name of the user's own (the same 60-character rule as a focus label); nil or
    /// blank clears it. The row shows it when the daemon's next listing arrives.
    func rename(_ id: String, to title: String?) {
        sender?.conversationHistoryRename(requestId: makeRequestId(), id: id, title: Focus.normalizedLabel(title))
    }

    func entry(_ id: String) -> ConversationEntryWire? { history?.entries.first { $0.id == id } }

    // MARK: Resume

    /// Resume conversation `sid`. A second gesture on the same row before the reply is ignored.
    /// `place` is the main checkout to resume in when the worktree is gone; `confirmActiveElsewhere` is
    /// the user's "Resume anyway".
    /// `noCodebaseFolder` is a new empty folder to resume in with no codebase (the original is gone).
    /// `agent` is the one to continue a terminal conversation with when Claude's recorded one is not an agent here.
    func resume(_ sid: String, place: String? = nil, noCodebaseFolder: String? = nil,
                confirmActiveElsewhere: Bool = false, agent: String? = nil) {
        guard let sender, sender.daemonAdvertisesConversationHistory, !inFlight.contains(sid) else { return }
        inFlight.insert(sid)
        send(sid: sid, startedAt: now(), place: place, noCodebaseFolder: noCodebaseFolder,
             confirm: confirmActiveElsewhere, agent: agent)
    }

    /// The sheet closed (Cancel, or any way out): stop retrying and forget every request in flight, and
    /// give each one's tag back to the daemon (sent after the resume on the same connection, so it lands
    /// after any reservation). A reply that arrives later matches nothing and is ignored; the daemon
    /// ignores a release for a tag that already has a focus. Its reservation window
    /// (`RESERVATION_WINDOW`) is only the backstop if this frame is lost.
    func cancelResumes() {
        for p in pending.values { sender?.conversationResumeRelease(tag: p.tag) }
        pending.removeAll()
        inFlight.removeAll()
    }

    /// Give back the tag of a resume whose focus was never made.
    func releaseResumedTag(_ tag: String) {
        resumedSids.removeValue(forKey: tag)
        sender?.conversationResumeRelease(tag: tag)
    }

    /// The no-codebase clean-up, after each good listing (the first one after launch, and the one a purge brings).
    var noCodebaseSweeper: (ConversationHistoryWire, Set<String>) -> Void = { wire, protected in
        let open = Set(FocusStore.shared.focuses.compactMap { $0.noCodebase ? $0.workingDirectory : nil })
        NoCodebaseCleanup.run(reply: wire, openWorkingDirectories: open, protectedFolders: protected)
    }

    private func sweepNoCodebaseFolders(_ wire: ConversationHistoryWire) {
        // A folder a resume is about to use is not yet named by anything the daemon lists.
        noCodebaseSweeper(wire, Set(pending.values.compactMap(\.noCodebaseFolder)))
    }

    private func send(sid: String, startedAt: Date, place: String?, noCodebaseFolder: String?, confirm: Bool,
                      agent: String?) {
        let focusId = makeFocusId()
        // Exactly as `Focus.sessionTag` derives it for a focus this app mints.
        let recorded = entry(sid)?.agent ?? ""
        let tag = "\(recorded.isEmpty ? (agent ?? "") : recorded)-\(focusId.prefix(8))"
        let requestId = makeRequestId()
        pending[requestId] = (sid, focusId, tag, startedAt, place, noCodebaseFolder, confirm, agent)
        sender?.conversationResume(requestId: requestId, id: sid, newTag: tag, place: place,
                                   noCodebaseFolder: noCodebaseFolder, confirmActiveElsewhere: confirm, agent: agent)
    }

    // MARK: Frames

    func ingest(_ msg: ServerMsg) {
        switch msg {
        case .conversationHistory(let wire):
            history = wire
            changes.send()
            markSensitivityKnown()
            sweepNoCodebaseFolders(wire)
        case .conversationHistoryChanged:
            refresh()
        case .conversationResumeResult(let wire):
            handle(wire)
        case .conversationResumeFailed(let tag, _):
            let transcript = resumedSids.removeValue(forKey: tag).flatMap { entry($0)?.transcriptPath }
            if let f = focusStore().focuses.first(where: { $0.sessionTag == tag }) { focusStore().remove(f) }
            for (rid, p) in pending where p.tag == tag { pending[rid] = nil }
            onResumeFailed?(transcript)
        default:
            break
        }
    }

    private func handle(_ wire: ConversationResumeResultWire) {
        guard let p = pending.removeValue(forKey: wire.requestId) else { return }
        switch wire.outcome {
        case .switch:
            inFlight.remove(p.sid)
            _ = wire.tag.map { switchToTag?($0) }
            resumeResults.send((p.sid, .switched))
        case .ready:
            inFlight.remove(p.sid)
            guard let commitFocus else {
                resumeResults.send((p.sid, .refused("unavailable")))
                return
            }
            // A conversation that runs with no codebase (its own folder, or a new one chosen because the
            // original is gone) comes back the same way: the folder is its working directory, never a repo.
            let noCodebase = p.noCodebaseFolder != nil || entry(p.sid)?.noCodebase == true
            var focus = Focus(id: p.focusId, agentTag: wire.agent ?? entry(p.sid)?.agent ?? "",
                              projectPath: noCodebase ? nil : wire.projectPath, isBuiltIn: false,
                              label: Focus.normalizedLabel(wire.label), resumedAt: now())
            if noCodebase {
                focus.noCodebase = true
                focus.workingDirectory = wire.projectPath ?? p.noCodebaseFolder
                focus.org = "Personal"
            }
            // The daemon reserved a tag. When this focus would derive another (the agent differs from
            // the one the request guessed), it adopts the daemon's, so the reservation is never orphaned.
            let reserved = wire.tag ?? p.tag
            if focus.sessionTag != reserved { focus.daemonTag = reserved }
            resumedSids[focus.sessionTag] = p.sid
            commitFocus(focus)
            resumeResults.send((p.sid, .opened))
        case .refused:
            if wire.reason == "starting" {
                if now().timeIntervalSince(p.startedAt) >= Self.startRetryWindow {
                    inFlight.remove(p.sid)
                    resumeResults.send((p.sid, .gaveUp))
                } else {
                    resumeResults.send((p.sid, .waitingToStart))
                    schedule(Self.startRetryInterval) { [weak self] in
                        guard let self, self.inFlight.contains(p.sid) else { return }
                        self.send(sid: p.sid, startedAt: p.startedAt, place: p.place,
                                  noCodebaseFolder: p.noCodebaseFolder, confirm: p.confirm, agent: p.agent)
                    }
                }
            } else {
                inFlight.remove(p.sid)
                resumeResults.send((p.sid, .refused(wire.reason ?? "unavailable")))
            }
        }
    }
}

extension ConversationHistoryStore {
    /// A regular `.jsonl` file that really lives under `~/.claude/projects` (symlinks resolved): the
    /// only thing Show Transcript in Finder will reveal.
    static func isShowableTranscript(_ path: String, home: URL = NostromoHome.userHome) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension == "jsonl" else { return false }
        let projects = home.appendingPathComponent(".claude/projects").resolvingSymlinksInPath().path + "/"
        let real = url.resolvingSymlinksInPath()
        guard real.path.hasPrefix(projects), real.pathExtension == "jsonl" else { return false }
        guard let values = try? real.resourceValues(forKeys: [.isRegularFileKey]) else { return false }
        return values.isRegularFile == true
    }

    /// What the app shows when a resumed focus could not open its conversation here.
    static let resumeFailureText = "Claude couldn\u{2019}t open this conversation here."

    /// The default `onResumeFailed`: an alert on the key window, with Show Transcript in Finder when the
    /// transcript file is known and still there. The path is never shown as text.
    static func presentResumeFailure(transcriptPath: String?) {
        let alert = NSAlert()
        alert.messageText = resumeFailureText
        alert.alertStyle = .warning
        let canShow = transcriptPath.map { isShowableTranscript($0) } ?? false
        if canShow { alert.addButton(withTitle: "Show Transcript in Finder") }
        alert.addButton(withTitle: "OK")
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if canShow, response == .alertFirstButtonReturn, let transcriptPath {
                ActivationAudit.note("resume:show-transcript-in-finder")
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: transcriptPath)])
            }
        }
        // Always a sheet on a window: a free-floating modal can strand the app.
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) else { return }
        alert.beginSheetModal(for: window, completionHandler: finish)
    }
}
