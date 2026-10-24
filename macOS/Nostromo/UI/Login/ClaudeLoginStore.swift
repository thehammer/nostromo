import Foundation
import Combine
import NostromoKit

// CL2: what the app knows about sessions waiting for a Claude sign-in.
//
// AppKit-free on purpose. It is the ONLY place "already acted" lives: a card view is rebuilt on a
// width change or when a pane is re-materialised, and a rebuilt view must never send twice.
// `retry` / `discard` therefore send at most one `claude_login_action` per `hold_id` while that
// action is in flight, whichever views come and go, and nothing at all unless the daemon advertised
// `claude_login_v1` in its last `welcome`.
//
// An action can fail without the daemon saying which hold: it refuses (an `error` frame), or it
// undoes a resend that could not be written and puts the same `hold_id` back to `waiting`. Either
// way the id is RELEASED and the card gets a short notice, so its buttons never go dead:
//   - the daemon's refusal frame releases everything in flight;
//   - the same hold seen in `resending` and then back in `waiting` / `not_resendable` is an undo;
//   - `actionTimeout` seconds with the same hold still shown and not `resending` is a silent failure.
// A hold that is `resending` stays protected until it leaves or goes back to waiting.
//
// Fed by `AppStore` through `claudeLoginEvents` (a `PassthroughSubject`, like decisions and
// approvals). Each frame is the whole picture (REPLACE semantics). Main thread only.

final class ClaudeLoginStore {

    /// Fires with the tags whose card may have changed (those in the old frame or the new one).
    let changes = PassthroughSubject<Set<String>, Never>()

    /// How long an action may sit with no phase change before it counts as failed.
    static let actionTimeout: TimeInterval = 4

    /// `(action, tag, holdID)`.
    private let send: (ClaudeLoginActionKind, String, String) -> Void
    private let featureAdvertised: () -> Bool
    private let canSend: () -> Bool
    /// Runs `work` after `delay` seconds on the main thread. A test supplies its own.
    private let after: (TimeInterval, @escaping () -> Void) -> Void

    /// An action this process sent that the daemon has not visibly settled.
    private struct InFlight {
        let tag: String
        let action: ClaudeLoginActionKind
        /// Which send this is, so an earlier send's timer cannot cut a later one short.
        let token: Int
        /// The hold was shown as `resending` after the send.
        var sawResending = false
    }

    private var sessions: [String: ClaudeLoginSession] = [:]
    private(set) var claudeBin: String?
    private(set) var watch: ClaudeLoginWatch = .keychain
    /// Actions in flight, by `hold_id`.
    private var inFlight: [String: InFlight] = [:]
    /// A short message per tag after an action failed, tied to the hold it failed on.
    private var notices: [String: (holdID: String, text: String)] = [:]
    private var nextToken = 0
    private var subscription: AnyCancellable?

    init(send: @escaping (ClaudeLoginActionKind, String, String) -> Void,
         featureAdvertised: @escaping () -> Bool,
         canSend: @escaping () -> Bool = { true },
         after: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         }) {
        self.send = send
        self.featureAdvertised = featureAdvertised
        self.canSend = canSend
        self.after = after
    }

    func attach(to events: PassthroughSubject<ClaudeLoginStateFrame, Never>) {
        subscription = events.sink { [weak self] in self?.handle($0) }
    }

    func handle(_ frame: ClaudeLoginStateFrame) {
        let before = Set(sessions.keys)
        sessions = Dictionary(frame.sessions.map { ($0.tag, $0) }, uniquingKeysWith: { _, last in last })
        claudeBin = frame.claudeBin
        watch = frame.watch
        var touched = before.union(sessions.keys)
        for (holdID, flight) in inFlight {
            guard let session = sessions[flight.tag], session.holdId == holdID else {
                // The hold is gone (the action worked, or the turn moved on).
                inFlight[holdID] = nil
                continue
            }
            if session.phase == .resending {
                inFlight[holdID]?.sawResending = true
            } else if flight.sawResending, session.phase == .waiting || session.phase == .notResendable {
                fail(holdID: holdID, flight: flight)
            }
        }
        for (tag, notice) in notices where sessions[tag]?.holdId != notice.holdID {
            notices[tag] = nil
            touched.insert(tag)
        }
        changes.send(touched)
    }

    /// The daemon refused an action it was sent: nothing it was asked for happened.
    func actionRefused() {
        for (holdID, flight) in inFlight { fail(holdID: holdID, flight: flight) }
    }

    /// The connection dropped. Nothing is known until the daemon says again.
    func reset() {
        let tags = Set(sessions.keys).union(notices.keys)
        sessions = [:]
        claudeBin = nil
        watch = .keychain
        inFlight = [:]
        notices = [:]
        if !tags.isEmpty { changes.send(tags) }
    }

    func session(tag: String) -> ClaudeLoginSession? { sessions[tag] }

    /// Why the last action on `tag` did nothing, until the next action or the hold goes away.
    func notice(tag: String) -> String? { notices[tag]?.text }

    /// Send the held message again now. False when nothing was sent.
    @discardableResult
    func retry(tag: String) -> Bool { act(.retry, tag: tag) }

    /// Drop the held message. False when nothing was sent.
    @discardableResult
    func discard(tag: String) -> Bool { act(.discard, tag: tag) }

    private func act(_ action: ClaudeLoginActionKind, tag: String) -> Bool {
        guard let holdID = sessions[tag]?.holdId, inFlight[holdID] == nil else { return false }
        guard featureAdvertised(), canSend() else {
            // Nothing was sent, and the hold stays free to act on once the connection is back.
            setNotice(for: tag, holdID: holdID, action: action)
            return false
        }
        nextToken += 1
        let token = nextToken
        inFlight[holdID] = InFlight(tag: tag, action: action, token: token)
        if notices.removeValue(forKey: tag) != nil { changes.send([tag]) }
        send(action, tag, holdID)
        after(Self.actionTimeout) { [weak self] in self?.timedOut(holdID: holdID, token: token) }
        return true
    }

    private func timedOut(holdID: String, token: Int) {
        guard let flight = inFlight[holdID], flight.token == token else { return }
        guard let session = sessions[flight.tag], session.holdId == holdID else {
            inFlight[holdID] = nil
            return
        }
        // Still resending: in flight, the undo (if any) arrives as a frame.
        if session.phase != .resending { fail(holdID: holdID, flight: flight) }
    }

    private func fail(holdID: String, flight: InFlight) {
        inFlight[holdID] = nil
        setNotice(for: flight.tag, holdID: holdID, action: flight.action)
    }

    private func setNotice(for tag: String, holdID: String, action: ClaudeLoginActionKind) {
        let text = action == .retry ? "Couldn't resend; try again." : "Couldn't discard; try again."
        notices[tag] = (holdID, text)
        changes.send([tag])
    }
}
