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
    /// The production-shell guard blocked a tool call (no request, no card).
    case guardBlocked(ApprovalGuardBlockedFrame)
}

/// A guard block the bar is showing for a focus (AP2b).
struct ApprovalGuardNotice: Equatable {
    let frame: ApprovalGuardBlockedFrame
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

    /// How long the guard bar stays before it hides itself.
    static let guardBarVisibleSeconds: TimeInterval = 60

    /// Fires with the focus tag whenever what that focus shows may have changed.
    let changes = PassthroughSubject<String, Never>()

    /// Fires after every daemon snapshot has been applied, EVEN WHEN IT TOUCHED NOTHING (an empty first
    /// snapshot sends no `changes` event). `ApprovalBadges` uses it to take the notifier's baseline.
    let snapshotHandled = PassthroughSubject<Void, Never>()

    /// True from the first daemon snapshot on: only then is the pending list the daemon's truth.
    private(set) var hasHandledSnapshot = false

    /// Fires with a tool call's `tool_use_id` whenever the status its row shows may have changed (AP2b).
    let statusChanges = PassthroughSubject<String, Never>()

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
    /// What each tool call's row says about its request, for the session's lifetime (bounded per focus).
    private var statusBook = ApprovalStatusBook()
    /// Which request last made each tool call await: only it may end that wait. A reused
    /// `tool_use_id` must not let a late frame for the old request overwrite the new request's wait.
    private var waitOwner: [String: String] = [:]
    /// Requests whose card the person collapsed to a one-line bar (AP3). Held here, not in a view: a
    /// rebuilt card or a second window shows the same state. Never an answer: the request stays pending.
    private var collapsed = Set<String>()
    /// The request the person last pressed Esc on inside its card, and when: a second Esc soon after
    /// (now in the composer) collapses it.
    private var escapeFromCard: (id: String, at: Date)?
    /// The guard block each focus's bar shows.
    private var notices: [String: ApprovalGuardNotice] = [:]
    /// The `entry_id` of the last block each focus was told of: a repeat of it (a replayed frame) says
    /// nothing new, even after the person closed the bar or it hid itself.
    private var lastGuardEntry: [String: String] = [:]
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
            // The first ending stands: a second frame for a request that already ended says nothing new.
            if let entry = entries[frame.requestId] { endWait(of: entry.request, outcome: frame.outcome, atMs: frame.atMs) }
            end(frame.requestId, text: Self.outcomeText(frame.outcome))
        case .answerRefused(let frame):
            refused(frame)
        case .guardBlocked(let frame):
            guardBlocked(frame)
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

    /// Every request still waiting, oldest first, across focuses (what the sidebar pill, the Dock badge
    /// and the notifications are made from).
    func pendingRequests() -> [ApprovalRequestWire] {
        entries.values.filter { !$0.isEnded }.map(\.request).sorted {
            ($0.createdAtMs, $0.requestId) < ($1.createdAtMs, $1.requestId)
        }
    }

    /// The number shown as `+N more`: every other entry the focus holds.
    func moreCount(tag: String) -> Int { max(0, visible(tag: tag).count - 1) }

    /// True the first time it is asked for `id`: the card announces itself to VoiceOver once.
    func claimAnnouncement(_ id: String) -> Bool {
        announced.insert(id).inserted
    }

    // MARK: Collapse (AP3)

    /// The card for `id` is collapsed to its one-line bar.
    func isCollapsed(_ id: String) -> Bool { collapsed.contains(id) }

    /// Collapse or expand the card of a request that is still waiting. Answers nothing.
    func setCollapsed(_ id: String, _ value: Bool) {
        guard let entry = entries[id], !entry.isEnded, collapsed.contains(id) != value else { return }
        if value { collapsed.insert(id) } else { collapsed.remove(id) }
        changes.send(entry.request.tag)
    }

    /// Esc pressed with keyboard focus inside the card of `id`: focus goes back to the composer, and
    /// the next Esc within `escapeWindow` collapses this card (`collapseAfterEscape`).
    func noteEscapeFromCard(_ id: String, now: Date = Date()) {
        escapeFromCard = (id, now)
    }

    /// How long after leaving a card with Esc a second Esc still collapses it.
    static let escapeWindow: TimeInterval = 2

    /// A second Esc, in the composer. True when it collapsed the card the first one left.
    @discardableResult
    func collapseAfterEscape(now: Date = Date()) -> Bool {
        guard let last = escapeFromCard else { return false }
        escapeFromCard = nil
        guard now.timeIntervalSince(last.at) <= Self.escapeWindow, let entry = entries[last.id], !entry.isEnded,
              !collapsed.contains(last.id) else { return false }
        setCollapsed(last.id, true)
        return true
    }

    // MARK: Row status (AP2b)

    /// What the row of the calls `toolUseIds` says: waiting if any waits, else the latest. Nil for nothing.
    func rowStatus(toolUseIds: [String]) -> ApprovalRowStatus? {
        statusBook.headline(toolUseIds: toolUseIds)
    }

    /// How many calls' statuses are kept for a focus.
    func statusCount(tag: String) -> Int { statusBook.count(tag: tag) }

    // MARK: Guard bar (AP2b)

    /// The guard block the bar shows for a focus, if any.
    func guardNotice(tag: String) -> ApprovalGuardNotice? { notices[tag] }

    /// The person closed the bar (in every window showing the focus).
    func dismissGuardNotice(tag: String) {
        guard notices.removeValue(forKey: tag) != nil else { return }
        changes.send(tag)
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
        case "answered": return "Answered"
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

    private func setStatus(_ status: ApprovalRowStatus, for request: ApprovalRequestWire) {
        setStatus(status, toolUseId: request.toolUseId, tag: request.tag)
    }

    private func setStatus(_ status: ApprovalRowStatus, toolUseId: String, tag: String) {
        statusBook.set(status, toolUseId: toolUseId, tag: tag)
        statusChanges.send(toolUseId)
    }

    /// A request that vanished without an outcome (the daemon no longer holds it) stops saying `awaiting`.
    private func forgetAwaiting(_ request: ApprovalRequestWire) {
        guard waitOwner[request.toolUseId] == request.id,
              statusBook.status(toolUseId: request.toolUseId) == .awaiting else { return }
        setStatus(.withdrawn, for: request)
    }

    /// The request ended with `outcome`: its call says so, if the call is still awaiting this request.
    /// An outcome this build has no words for (or none) says nothing, never "awaiting" for ever.
    private func endWait(of request: ApprovalRequestWire, outcome: String?, atMs: UInt64) {
        guard waitOwner[request.toolUseId] == request.id,
              statusBook.status(toolUseId: request.toolUseId) == .awaiting else { return }
        setStatus(outcome.map { ApprovalRowStatus.forOutcome($0, atMs: atMs) } ?? .withdrawn, for: request)
    }

    /// The guard blocked a call: no request, no card. The call's row says so, and the bar shows for a minute.
    private func guardBlocked(_ frame: ApprovalGuardBlockedFrame) {
        guard lastGuardEntry[frame.tag] != frame.entryId else { return }
        lastGuardEntry[frame.tag] = frame.entryId
        setStatus(.blockedByGuard, toolUseId: frame.toolUseId, tag: frame.tag)
        notices[frame.tag] = ApprovalGuardNotice(frame: frame)
        changes.send(frame.tag)
        schedule(Self.guardBarVisibleSeconds) { [weak self] in
            // A newer block (or the person's close) replaced this one: its own timer decides.
            guard let self, self.notices[frame.tag]?.frame.entryId == frame.entryId else { return }
            self.notices.removeValue(forKey: frame.tag)
            self.changes.send(frame.tag)
        }
    }

    private func add(_ request: ApprovalRequestWire) {
        guard entries[request.id] == nil else { return }
        // A request this process already answered never comes back as waiting.
        var state: ApprovalAnswerState = .pending
        if answered.contains(request.id) {
            if let text = refusalTexts[request.id] { state = .notSent(text) } else { state = .inFlight(.deny) }
        }
        entries[request.id] = ApprovalEntry(request: request, state: state)
        order[request.tag, default: []].append(request.id)
        waitOwner[request.toolUseId] = request.id
        setStatus(.awaiting, for: request)
    }

    /// The daemon's list is the truth: add what it holds that we don't, and drop what we
    /// show that it no longer holds.
    private func replaceAll(with requests: [ApprovalRequestWire]) {
        // Set before any `changes` event goes out, so the first publish that follows is the baseline.
        hasHandledSnapshot = true
        let held = Set(requests.map(\.id))
        var touched = Set<String>()
        for (id, entry) in entries where !held.contains(id) && !entry.isEnded {
            forgetAwaiting(entry.request)   // before `remove`: it forgets who owned the wait
            remove(id)
            touched.insert(entry.request.tag)
        }
        for request in requests where entries[request.id] == nil {
            add(request)
            touched.insert(request.tag)
        }
        touched.forEach { changes.send($0) }
        snapshotHandled.send()
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
            // The resolved frame may have been lost: the refusal says how it ended. The first ending
            // stands, so a resolved frame that did arrive first is never overwritten.
            endWait(of: entry.request, outcome: frame.outcome, atMs: UInt64(Date().timeIntervalSince1970 * 1000))
            end(frame.requestId, text: Self.alreadyResolvedText(outcome: frame.outcome))
        case .unknownRequest:
            forgetAwaiting(entry.request)
            end(frame.requestId, text: "Already resolved")
        case .notOperatorApp:
            hold(frame.requestId, text: "Not sent: Nostromo isn't verified as the operator (run make mac-install)")
        case .requiresSecureConnection:
            hold(frame.requestId, text: "Not sent: this connection can't answer approvals")
        case .invalidAnswer:
            hold(frame.requestId, text: "Not sent: the daemon refused these answers")
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
        collapsed.remove(id)
        if waitOwner[entry.request.toolUseId] == id { waitOwner.removeValue(forKey: entry.request.toolUseId) }
        order[entry.request.tag]?.removeAll { $0 == id }
        if order[entry.request.tag]?.isEmpty == true { order.removeValue(forKey: entry.request.tag) }
    }
}
