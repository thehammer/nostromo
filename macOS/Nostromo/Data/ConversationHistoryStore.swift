import AppKit
import Combine
import Foundation

/// What the store asks the daemon through; `NostromodClient` is the real one, tests pass a recorder.
protocol ConversationHistorySending: AnyObject {
    var daemonAdvertisesConversationHistory: Bool { get }
    func conversationHistoryGet(requestId: String)
    func conversationResume(requestId: String, id: String, newTag: String)
    func conversationHistoryRemove(requestId: String, id: String)
    func conversationHistoryRestore(requestId: String, id: String)
    func conversationHistoryPurgeRemoved(requestId: String)
    func conversationHistorySettingsSet(requestId: String, firstPromptsEnabled: Bool)
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
    private var pending: [String: (sid: String, focusId: String, tag: String, startedAt: Date)] = [:]
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

    var isSupported: Bool { sender?.daemonAdvertisesConversationHistory == true }

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

    func entry(_ id: String) -> ConversationEntryWire? { history?.entries.first { $0.id == id } }

    // MARK: Resume

    /// Resume conversation `sid`. A second gesture on the same row before the reply is ignored.
    func resume(_ sid: String) {
        guard let sender, sender.daemonAdvertisesConversationHistory, !inFlight.contains(sid) else { return }
        inFlight.insert(sid)
        send(sid: sid, startedAt: now())
    }

    private func send(sid: String, startedAt: Date) {
        let focusId = makeFocusId()
        // Exactly as `Focus.sessionTag` derives it for a focus this app mints.
        let tag = "\(entry(sid)?.agent ?? "")-\(focusId.prefix(8))"
        let requestId = makeRequestId()
        pending[requestId] = (sid, focusId, tag, startedAt)
        sender?.conversationResume(requestId: requestId, id: sid, newTag: tag)
    }

    // MARK: Frames

    func ingest(_ msg: ServerMsg) {
        switch msg {
        case .conversationHistory(let wire):
            history = wire
            changes.send()
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
            let focus = Focus(id: p.focusId, agentTag: wire.agent ?? entry(p.sid)?.agent ?? "",
                              projectPath: wire.projectPath, isBuiltIn: false, label: wire.label,
                              resumedAt: now())
            // The daemon reserved `p.tag`; the focus must derive the same one.
            if focus.sessionTag == (wire.tag ?? p.tag) {
                resumedSids[focus.sessionTag] = p.sid
                commitFocus?(focus)
                resumeResults.send((p.sid, .opened))
            } else {
                resumeResults.send((p.sid, .refused("unavailable")))
            }
        case .refused:
            if wire.reason == "starting" {
                if now().timeIntervalSince(p.startedAt) >= Self.startRetryWindow {
                    inFlight.remove(p.sid)
                    resumeResults.send((p.sid, .gaveUp))
                } else {
                    resumeResults.send((p.sid, .waitingToStart))
                    schedule(Self.startRetryInterval) { [weak self] in
                        guard let self, self.inFlight.contains(p.sid) else { return }
                        self.send(sid: p.sid, startedAt: p.startedAt)
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
    /// What the app shows when a resumed focus could not open its conversation here.
    static let resumeFailureText = "Claude couldn\u{2019}t open this conversation here."

    /// The default `onResumeFailed`: an alert on the key window, with Show Transcript in Finder when the
    /// transcript file is known and still there. The path is never shown as text.
    static func presentResumeFailure(transcriptPath: String?) {
        let alert = NSAlert()
        alert.messageText = resumeFailureText
        alert.alertStyle = .warning
        let canShow = transcriptPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
        if canShow { alert.addButton(withTitle: "Show Transcript in Finder") }
        alert.addButton(withTitle: "OK")
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if canShow, response == .alertFirstButtonReturn, let transcriptPath {
                ActivationAudit.note("resume:show-transcript-in-finder")
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: transcriptPath)])
            }
        }
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}
