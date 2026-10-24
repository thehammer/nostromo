import Foundation
import Combine
import NostromoKit

// CL2: what the app knows about sessions waiting for a Claude sign-in.
//
// AppKit-free on purpose. It is the ONLY place "already acted" lives: a card view is rebuilt on a
// width change or when a pane is re-materialised, and a rebuilt view must never send twice.
// `retry` / `discard` therefore send at most one `claude_login_action` per `hold_id` for the life
// of the process, whichever views come and go, and nothing at all unless the daemon advertised
// `claude_login_v1` in its last `welcome`.
//
// Fed by `AppStore` through `claudeLoginEvents` (a `PassthroughSubject`, like decisions and
// approvals). Each frame is the whole picture (REPLACE semantics). Main thread only.

final class ClaudeLoginStore {

    /// Fires with the tags whose card may have changed (those in the old frame or the new one).
    let changes = PassthroughSubject<Set<String>, Never>()

    /// `(action, tag, holdID)`.
    private let send: (ClaudeLoginActionKind, String, String) -> Void
    private let featureAdvertised: () -> Bool
    private let canSend: () -> Bool

    private var sessions: [String: ClaudeLoginSession] = [:]
    private(set) var claudeBin: String?
    /// Every `hold_id` this process has sent an action for. Never shrinks.
    private var acted = Set<String>()
    private var subscription: AnyCancellable?

    init(send: @escaping (ClaudeLoginActionKind, String, String) -> Void,
         featureAdvertised: @escaping () -> Bool,
         canSend: @escaping () -> Bool = { true }) {
        self.send = send
        self.featureAdvertised = featureAdvertised
        self.canSend = canSend
    }

    func attach(to events: PassthroughSubject<ClaudeLoginStateFrame, Never>) {
        subscription = events.sink { [weak self] in self?.handle($0) }
    }

    func handle(_ frame: ClaudeLoginStateFrame) {
        let before = Set(sessions.keys)
        sessions = Dictionary(frame.sessions.map { ($0.tag, $0) }, uniquingKeysWith: { _, last in last })
        claudeBin = frame.claudeBin
        changes.send(before.union(sessions.keys))
    }

    func session(tag: String) -> ClaudeLoginSession? { sessions[tag] }

    /// Send the held message again now. False when nothing was sent.
    @discardableResult
    func retry(tag: String) -> Bool { act(.retry, tag: tag) }

    /// Drop the held message. False when nothing was sent.
    @discardableResult
    func discard(tag: String) -> Bool { act(.discard, tag: tag) }

    private func act(_ action: ClaudeLoginActionKind, tag: String) -> Bool {
        guard featureAdvertised(), canSend(),
              let holdID = sessions[tag]?.holdId,
              acted.insert(holdID).inserted else { return false }
        send(action, tag, holdID)
        return true
    }
}
