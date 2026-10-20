import Foundation
import Combine
import NostromoKit

// AP2a: the approval store. Holds every permission request the daemon is waiting
// on a human for, and what this app has done about each one.
//
// AppKit-free on purpose. It is the ONLY place answered state lives: a card view
// is rebuilt on a width change or when a pane is re-materialised, and a rebuilt
// view must never be able to answer twice (the same lesson as
// `TurnInteractionStore`, where a re-materialised card once sent a second
// message). `answer` therefore sends `approval_answer` at most once per request
// id for the life of the process, whatever views come and go.
//
// Fed by `AppStore` through `approvalEvents` (a `PassthroughSubject`, deliberately
// not `@Published`, like decisions: a request is an event, not state to diff).
// Main thread only.

/// What `AppStore` forwards from the daemon.
enum ApprovalEvent {
    case request(ApprovalRequestWire)
    /// Every request still held, sent on (re)subscribe: the daemon's view replaces ours.
    case snapshot([ApprovalRequestWire])
    case resolved(ApprovalResolvedFrame)
    case answerRefused(ApprovalAnswerRefusedFrame)
}

/// Where one request is in its life, as far as this app knows.
enum ApprovalAnswerState: Equatable {
    /// Waiting for a human.
    case pending
    /// This app sent the answer (the associated value is what it said); the daemon has not confirmed.
    case inFlight(ApprovalDecisionKind)
    /// The daemon refused the answer for a reason that leaves the request pending.
    /// The text says why. An Allow is never re-sent (the request times out, which denies), but
    /// a Deny may be tried again by a person (`ApprovalStore.answer`): the agent must not be
    /// left waiting out the 15 minutes with the only safe answer disabled.
    case notSent(String)
    /// The request ended. The text (`Allowed once`, `Denied: no answer in 15 min`) is shown
    /// for `ApprovalStore.outcomeVisibleSeconds`, then the entry is dropped.
    case ended(String)
}

struct ApprovalEntry: Equatable {
    let request: ApprovalRequestWire
    var state: ApprovalAnswerState

    var isEnded: Bool {
        if case .ended = state { return true }
        return false
    }
}

final class ApprovalStore {

    /// How long an outcome stays on the card before it fades.
    static let outcomeVisibleSeconds: TimeInterval = 2

    /// Fires with the focus tag whenever what that focus shows may have changed.
    let changes = PassthroughSubject<String, Never>()

    /// `answer` sends this, once per id. `(requestId, decision, windowID)`.
    private let send: (String, ApprovalDecisionWire, String) -> Void
    /// A refused gesture, reported so the daemon can log it. `(requestId, control, channel)`.
    private let report: (String?, String, ApprovalRefusalChannel) -> Void
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    /// False while there is no daemon connection to write to: an answer is then not sent and
    /// not counted, so the person can press again once the connection is back.
    private let canSend: () -> Bool

    private var entries: [String: ApprovalEntry] = [:]
    /// Arrival order per focus (oldest first).
    private var order: [String: [String]] = [:]
    /// Every id this process has sent an answer for. Never shrinks.
    private var answered = Set<String>()
    /// What the card says for an id whose answer the daemon refused and that has not been answered since:
    /// if the daemon's snapshot drops it and then lists it again, it comes back refused (Deny still
    /// possible), not as "sent".
    private var refusalTexts: [String: String] = [:]
    /// Ids whose arrival has been announced to VoiceOver.
    private var announced = Set<String>()
    private var subscription: AnyCancellable?

    init(send: @escaping (String, ApprovalDecisionWire, String) -> Void,
         report: @escaping (String?, String, ApprovalRefusalChannel) -> Void,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         },
         canSend: @escaping () -> Bool = { true }) {
        self.send = send
        self.report = report
        self.schedule = schedule
        self.canSend = canSend
    }

    // MARK: Feeding

    func attach(to events: PassthroughSubject<ApprovalEvent, Never>) {
        subscription = events.sink { [weak self] in self?.handle($0) }
    }

    func handle(_ event: ApprovalEvent) {
        switch event {
        case .request(let request):
            add(request)
            changes.send(request.tag)
        case .snapshot(let requests):
            replaceAll(with: requests)
        case .resolved(let frame):
            end(frame.requestId, text: Self.outcomeText(frame.outcome))
        case .answerRefused(let frame):
            refused(frame)
        }
    }

    // MARK: Reading

    func entry(id: String) -> ApprovalEntry? { entries[id] }

    /// Everything a focus shows, oldest first: waiting requests and ones whose outcome is still on screen.
    func visible(tag: String) -> [ApprovalEntry] {
        (order[tag] ?? []).compactMap { entries[$0] }
    }

    /// The one request a focus's card shows: the oldest.
    func current(tag: String) -> ApprovalEntry? { visible(tag: tag).first }

    /// How many requests are still waiting (not ended) for a focus.
    func pendingCount(tag: String) -> Int {
        visible(tag: tag).filter { !$0.isEnded }.count
    }

    /// The number shown as `+N more`: every other entry the focus holds.
    func moreCount(tag: String) -> Int { max(0, visible(tag: tag).count - 1) }

    /// True the first time it is asked for `id`: the card announces itself to VoiceOver once.
    func claimAnnouncement(_ id: String) -> Bool {
        announced.insert(id).inserted
    }

    // MARK: Answering

    /// Send the human's answer for `id`. Returns false, and sends nothing, if the
    /// request is unknown, not waiting, this process has already answered it, or there is no connection.
    ///
    /// One attempt at a time: while an answer is in flight a second one is ignored. The one
    /// exception is a Deny after the daemon refused an answer (`.notSent`): that is sent again,
    /// and only a Deny (never an Allow, whatever was refused).
    @discardableResult
    func answer(_ id: String, _ decision: ApprovalDecisionWire, windowID: String) -> Bool {
        guard var entry = entries[id], canSend() else { return false }
        switch entry.state {
        case .pending:
            guard !answered.contains(id) else { return false }
        case .notSent:
            guard decision.kind == .deny else { return false }
        case .inFlight, .ended:
            return false
        }
        answered.insert(id)
        refusalTexts[id] = nil
        entry.state = .inFlight(decision.kind)
        entries[id] = entry
        send(id, decision, windowID)
        changes.send(entry.request.tag)
        return true
    }

    /// A gesture that was not a person's was refused at a control of `id`.
    func reportRefusal(requestId: String?, control: String, channel: ApprovalRefusalChannel) {
        report(requestId, control, channel)
    }

    // MARK: Text

    /// What the card says when a request ends. `outcome` is the daemon's name for it.
    static func outcomeText(_ outcome: String) -> String {
        switch outcome {
        case "allowed_once": return "Allowed once"
        case "denied": return "Denied"
        case "denied_and_stopped": return "Denied and stopped"
        case "timed_out": return "Denied: no answer in 15 min"
        case "no_app": return "Denied: Nostromo closed"
        case "restart", "restart_crash": return "Denied: Nostromo restarted"
        case "guard_blocked": return "Blocked: production-shell guard"
        case "withdrawn": return "Withdrawn by Claude Code"
        case "cancelled": return "Cancelled"
        case "approval_unavailable": return "Denied: approvals unavailable"
        case "invalid_request": return "Denied: unreadable request"
        default: return "Ended: \(outcome.replacingOccurrences(of: "_", with: " "))"
        }
    }

    /// What the card says when an answer arrives after the request ended.
    static func alreadyResolvedText(outcome: String?) -> String {
        switch outcome {
        case "timed_out": return "Already denied (timed out)"
        case "denied", "denied_and_stopped": return "Already denied"
        case "allowed_once": return "Already allowed once"
        case .some(let other): return "Already resolved: \(other.replacingOccurrences(of: "_", with: " "))"
        case nil: return "Already resolved"
        }
    }

    // MARK: Private

    private func add(_ request: ApprovalRequestWire) {
        guard entries[request.id] == nil else { return }
        // A request this process already answered never comes back as waiting.
        var state: ApprovalAnswerState = .pending
        if answered.contains(request.id) {
            if let text = refusalTexts[request.id] { state = .notSent(text) } else { state = .inFlight(.deny) }
        }
        entries[request.id] = ApprovalEntry(request: request, state: state)
        order[request.tag, default: []].append(request.id)
    }

    /// The daemon's list is the truth: add what it holds that we don't, and drop what we
    /// show that it no longer holds.
    private func replaceAll(with requests: [ApprovalRequestWire]) {
        let held = Set(requests.map(\.id))
        var touched = Set<String>()
        for (id, entry) in entries where !held.contains(id) && !entry.isEnded {
            remove(id)
            touched.insert(entry.request.tag)
        }
        for request in requests where entries[request.id] == nil {
            add(request)
            touched.insert(request.tag)
        }
        touched.forEach { changes.send($0) }
    }

    private func end(_ id: String, text: String) {
        guard var entry = entries[id], !entry.isEnded else { return }
        refusalTexts[id] = nil
        entry.state = .ended(text)
        entries[id] = entry
        changes.send(entry.request.tag)
        schedule(Self.outcomeVisibleSeconds) { [weak self] in
            guard let self, let gone = self.entries[id], gone.isEnded else { return }
            self.remove(id)
            self.changes.send(gone.request.tag)
        }
    }

    private func refused(_ frame: ApprovalAnswerRefusedFrame) {
        guard let entry = entries[frame.requestId], !entry.isEnded else { return }
        switch frame.code {
        case .alreadyResolved:
            end(frame.requestId, text: Self.alreadyResolvedText(outcome: frame.outcome))
        case .unknownRequest:
            end(frame.requestId, text: "Already resolved")
        case .notOperatorApp:
            hold(frame.requestId, text: "Not sent: Nostromo isn't verified as the operator (run make mac-install)")
        case .requiresSecureConnection:
            hold(frame.requestId, text: "Not sent: this connection can't answer approvals")
        case .unknown:
            hold(frame.requestId, text: "Not sent: the daemon refused the answer")
        }
    }

    private func hold(_ id: String, text: String) {
        guard var entry = entries[id] else { return }
        if answered.contains(id) { refusalTexts[id] = text }
        entry.state = .notSent(text)
        entries[id] = entry
        changes.send(entry.request.tag)
    }

    private func remove(_ id: String) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        order[entry.request.tag]?.removeAll { $0 == id }
        if order[entry.request.tag]?.isEmpty == true { order.removeValue(forKey: entry.request.tag) }
    }
}
