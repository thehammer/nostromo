import Foundation
import Combine

// Message queue S2: what the Mac knows about a session's queue of waiting messages.
//
// The queue is daemon state (`docs/message-queue.md`). The Mac never invents a queued message: a chip
// exists only because a `session_queue` snapshot listed it, so every window and every Mac process shows
// the same thing. This file holds the wire shapes and `SessionQueueModel`, the per-focus view of that
// snapshot plus the take-back and remove requests this process has in flight. AppKit-free; main thread.

/// `welcome.features` entry for the queue wire.
let sessionQueueFeature = "session_queue_v1"

// MARK: - Wire

/// One queued message of a `session_queue` snapshot.
struct SessionQueueEntryWire: Decodable, Equatable {
    let id: String
    /// `typed` (a person typed it) or `app` (the app composed it).
    let kind: String
    let text: String
    let imageCount: Int
    /// A typed slash command.
    let command: Bool
    /// `mother_overview`, `work_item` or `agent_seed` for an app entry.
    let appLabel: String?
    /// The sender's own tag for the message, on typed entries.
    let clientRef: String?
    let canTakeBack: Bool

    enum CodingKeys: String, CodingKey {
        case id, kind, text, command
        case imageCount = "image_count"
        case appLabel = "app_label"
        case clientRef = "client_ref"
        case canTakeBack = "can_take_back"
    }
}

/// The typed message held for a Claude sign-in. It carries no text: the sign-in card owns it.
struct SessionQueueHeldWire: Decodable, Equatable {
    let id: String
    let holdId: String
    let canTakeBack: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case holdId = "hold_id"
        case canTakeBack = "can_take_back"
    }
}

/// Why a snapshot was sent. `ids` are the entries it concerns.
struct SessionQueueChangeWire: Decodable, Equatable {
    let reason: String
    let ids: [String]
}

/// `session_queue`: the whole queue (REPLACE semantics).
struct SessionQueueWire: Decodable, Equatable {
    let tag: String
    let daemonEpoch: String
    let rev: Int
    let entries: [SessionQueueEntryWire]
    let held: SessionQueueHeldWire?
    let change: SessionQueueChangeWire?

    enum CodingKeys: String, CodingKey {
        case tag, rev, entries, held, change
        case daemonEpoch = "daemon_epoch"
    }
}

/// `session_queue_result`: the answer to a take-back or remove of this connection.
struct SessionQueueResultWire: Decodable, Equatable {
    let tag: String
    let requestId: String
    let id: String
    /// `taken_back`, `removed`, `already_delivered`, `not_found` or `not_allowed`.
    let code: String
    /// Only on `taken_back`.
    let text: String?
    /// Absolute paths; only on `taken_back`.
    let images: [String]?

    enum CodingKeys: String, CodingKey {
        case tag, id, code, text, images
        case requestId = "request_id"
    }
}

/// `session_queue_returned`: the typed messages Stop dropped, to the connection that pressed Stop.
struct SessionQueueReturnedWire: Decodable, Equatable {
    struct Entry: Decodable, Equatable {
        let id: String
        let text: String
        let images: [String]?
    }
    let tag: String
    let reason: String
    let entries: [Entry]
}

// MARK: - Model

/// One waiting message as a chip shows it.
struct QueuedMessage: Equatable, Identifiable {
    let id: String
    /// Typed by a person (this app, another window, a phone). Otherwise the app composed it.
    let isTyped: Bool
    let text: String
    let imageCount: Int
    let isCommand: Bool
    let appLabel: String?
    let clientRef: String?
    let canTakeBack: Bool

    init(_ wire: SessionQueueEntryWire) {
        id = wire.id
        isTyped = wire.kind == "typed"
        text = wire.text
        imageCount = wire.imageCount
        isCommand = wire.command
        appLabel = wire.appLabel
        clientRef = wire.clientRef
        canTakeBack = wire.canTakeBack
    }
}

/// What a take-back request came to, for the composer that asked.
enum TakeBackOutcome: Equatable {
    /// The message is gone from the queue; its exact text and image paths.
    case takenBack(text: String, images: [String])
    case alreadyDelivered
    case notFound
    case notAllowed
    /// The daemon did not answer in `SessionQueueModel.requestTimeout`.
    case noAnswer
}

/// Whether a request left this process.
enum QueueRequestStart: Equatable {
    case sent
    /// Another composer or chip of this process already has a request for the entry in flight.
    case busy
    /// Nothing was sent: no connection, no operator nonce, or the daemon has no queue.
    case unavailable
}

/// What a snapshot's arrival means beyond the new queue.
struct SessionQueueApplied: Equatable {
    /// False for a snapshot that is not newer than the last one of its epoch.
    var applied = false
    /// Typed messages this snapshot says were lost with the session or the daemon.
    var lostTyped = 0
}

/// Things worth saying aloud.
enum SessionQueueEvent: Equatable {
    case queued(waiting: Int)
    case delivered
}

/// The typed messages Stop dropped, for the composer that pressed it.
struct SessionQueueReturn: Equatable {
    struct Entry: Equatable {
        let text: String
        let images: [String]
    }
    let requester: ObjectIdentifier
    let entries: [Entry]
}

/// Words for the transcript's "not sent" notice.
enum SessionQueueNotice {
    static func text(count: Int) -> String {
        count == 1 ? "1 queued message was not sent. Press ↑ to recall it."
                   : "\(count) queued messages were not sent. Press ↑ to recall them."
    }
}

final class SessionQueueModel: ObservableObject {

    /// How long a take-back or remove may wait for the daemon's answer.
    static let requestTimeout: TimeInterval = 2
    /// How long after pressing Stop the dropped messages may still be handed back to that composer.
    static let stopWindow: TimeInterval = 5

    let tag: String

    /// The queued messages, oldest first.
    @Published private(set) var entries: [QueuedMessage] = []
    /// The message held for a Claude sign-in, if any (never a chip).
    @Published private(set) var held: SessionQueueHeldWire?

    /// Queued and delivered, for VoiceOver.
    let events = PassthroughSubject<SessionQueueEvent, Never>()
    /// Stop's dropped messages, for the composer that pressed Stop (others ignore it).
    let returned = PassthroughSubject<SessionQueueReturn, Never>()
    /// Text that left the queue after its composer had stopped waiting (a take-back answered after the
    /// timeout, or Stop's frame arriving after the window). Composers keep it in history so it is not lost.
    let recoveredLate = PassthroughSubject<[String], Never>()

    private(set) var epoch: String?
    private(set) var rev = -1

    /// `(entry id, request id)`; true when the frame was written.
    private let sendTakeBack: (String, String) -> Bool
    private let sendRemove: (String, String) -> Bool
    private let after: (TimeInterval, @escaping () -> Void) -> Void
    private let now: () -> Date
    private let newRequestId: () -> String

    private struct Request {
        let entryId: String
        let completion: ((TakeBackOutcome) -> Void)?
    }
    /// Requests awaiting an answer, by request id.
    private var requests: [String: Request] = [:]
    /// Entry ids with a request in flight, so two windows of this process cannot both act on one entry.
    private var inFlight: [String: String] = [:]
    private var returnClaimed = false
    private var stopRequester: (who: ObjectIdentifier, at: Date)?
    /// Request ids that timed out, so a late `taken_back` can still be recovered.
    private var timedOutRequests: Set<String> = []

    init(tag: String,
         sendTakeBack: @escaping (String, String) -> Bool,
         sendRemove: @escaping (String, String) -> Bool,
         after: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         },
         now: @escaping () -> Date = Date.init,
         newRequestId: @escaping () -> String = { UUID().uuidString }) {
        self.tag = tag
        self.sendTakeBack = sendTakeBack
        self.sendRemove = sendRemove
        self.after = after
        self.now = now
        self.newRequestId = newRequestId
    }

    /// The `client_ref`s of the typed entries now queued.
    var clientRefs: Set<String> { Set(entries.compactMap { $0.clientRef }) }

    // MARK: Snapshots

    /// Forget everything the daemon told us: the connection now goes to a daemon with no queue (a downgrade,
    /// another branch), so the last chips describe messages it no longer holds. A take-back in flight is
    /// answered `.noAnswer` now (its composer stops waiting); the old daemon will never reply.
    func reset() {
        let pending = requests.values.compactMap { $0.completion }
        if !entries.isEmpty { entries = [] }
        if held != nil { held = nil }
        epoch = nil
        rev = -1
        requests = [:]
        inFlight = [:]
        timedOutRequests = []
        stopRequester = nil
        pending.forEach { $0(.noAnswer) }
    }

    /// Adopt `wire`. A snapshot whose `rev` is not above the last one of the same epoch is dropped; a
    /// new epoch (the daemon restarted) replaces everything.
    @discardableResult
    func apply(_ wire: SessionQueueWire) -> SessionQueueApplied {
        let sameEpoch = epoch == wire.daemonEpoch
        if sameEpoch, wire.rev <= rev { return SessionQueueApplied() }

        var result = SessionQueueApplied(applied: true)
        let previousTyped = entries.filter { $0.isTyped }
        if let known = epoch, known != wire.daemonEpoch {
            // The daemon restarted and its queue was not kept: what we showed is gone for good.
            let ids = Set(wire.entries.map { $0.id })
            result.lostTyped = previousTyped.filter { !ids.contains($0.id) }.count
        } else if wire.change?.reason == "session_stopped" {
            result.lostTyped = wire.change?.ids.count ?? 0
        }

        epoch = wire.daemonEpoch
        rev = wire.rev
        let new = wire.entries.map(QueuedMessage.init)
        if new != entries { entries = new }
        if wire.held != held { held = wire.held }

        switch wire.change?.reason {
        case "queued": events.send(.queued(waiting: new.count))
        case "delivered": events.send(.delivered)
        default: break
        }
        return result
    }

    // MARK: Taking back

    /// The entry Up takes back: the newest queued message when it is typed and can be taken back; with
    /// nothing queued, the message held for a sign-in. Never digs past an app message.
    func takeBackTarget() -> String? {
        if let newest = entries.last {
            return newest.isTyped && newest.canTakeBack ? newest.id : nil
        }
        if let held, held.canTakeBack { return held.id }
        return nil
    }

    /// Ask the daemon for `id`'s text and images back. `completion` runs exactly once, on the main
    /// thread, unless the request is `.busy` or `.unavailable` (then it never runs and nothing was sent).
    func takeBack(id: String, completion: @escaping (TakeBackOutcome) -> Void) -> QueueRequestStart {
        start(id: id, completion: completion, send: sendTakeBack)
    }

    /// Remove `id` from the queue. The chip goes when the daemon's snapshot says so.
    @discardableResult
    func remove(id: String) -> QueueRequestStart {
        start(id: id, completion: nil, send: sendRemove)
    }

    private func start(id: String, completion: ((TakeBackOutcome) -> Void)?,
                       send: (String, String) -> Bool) -> QueueRequestStart {
        guard inFlight[id] == nil else { return .busy }
        let requestId = newRequestId()
        guard send(id, requestId) else { return .unavailable }
        inFlight[id] = requestId
        requests[requestId] = Request(entryId: id, completion: completion)
        after(Self.requestTimeout) { [weak self] in self?.timedOut(requestId: requestId) }
        return .sent
    }

    func handle(_ result: SessionQueueResultWire) {
        // A late answer (after the timeout) never fills a composer that moved on, but a late `taken_back`
        // carries the only copy of a message the daemon no longer holds: keep it in history.
        guard let request = requests.removeValue(forKey: result.requestId) else {
            if timedOutRequests.remove(result.requestId) != nil, result.code == "taken_back",
               let text = result.text, !text.isEmpty {
                recoveredLate.send([text])
            }
            return
        }
        if inFlight[request.entryId] == result.requestId { inFlight[request.entryId] = nil }
        guard let completion = request.completion else { return }
        switch result.code {
        case "taken_back": completion(.takenBack(text: result.text ?? "", images: result.images ?? []))
        case "already_delivered": completion(.alreadyDelivered)
        case "not_allowed": completion(.notAllowed)
        default: completion(.notFound)
        }
    }

    private func timedOut(requestId: String) {
        guard let request = requests.removeValue(forKey: requestId) else { return }
        if inFlight[request.entryId] == requestId { inFlight[request.entryId] = nil }
        if request.completion != nil { timedOutRequests.insert(requestId) }
        request.completion?(.noAnswer)
    }

    // MARK: Stop

    /// `requester` pressed Stop: the daemon is about to hand it the dropped typed messages.
    func noteStop(requester: ObjectIdentifier) {
        stopRequester = (requester, now())
    }

    func handle(_ wire: SessionQueueReturnedWire) {
        guard let stop = stopRequester else { return }
        stopRequester = nil
        guard !wire.entries.isEmpty else { return }
        guard now().timeIntervalSince(stop.at) <= Self.stopWindow else {
            recoveredLate.send(wire.entries.map { $0.text })
            return
        }
        returnClaimed = false
        returned.send(SessionQueueReturn(
            requester: stop.who,
            entries: wire.entries.map { .init(text: $0.text, images: $0.images ?? []) }))
        // The composer that pressed Stop is gone: nobody took the text, so keep it in history.
        if !returnClaimed { recoveredLate.send(wire.entries.map { $0.text }) }
    }

    /// The requester's composer calls this from its `returned` subscription: the text is its to restore.
    func claimReturn() { returnClaimed = true }
}
