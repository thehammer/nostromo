import Foundation
import NostromoKit

/// What the requests ask of the daemon connection. `NostromodClient` is the real one; tests pass a recorder.
protocol TaskRequestSending: AnyObject {
    func sendTaskOutput(requestId: String, tag: String, taskId: String, offset: UInt64?, maxBytes: UInt32)
    func sendTaskStop(requestId: String, tag: String, taskId: String)
}

extension NostromodClient: TaskRequestSending {}

/// How a request ended: the daemon's answer, nothing in time, or no connection (or it dropped).
enum TaskReply<Answer> {
    case answered(Answer)
    case timedOut
    case failed(String)
}

/// Request/response for the two task verbs (`session_task_output`, `session_task_stop`), the pattern of
/// `WorkStore.expect/resolve/failPendingRequests`: every request gets an id, one completion that runs
/// exactly once, and a timeout. A late or duplicate answer is ignored.
///
/// Both timeouts sit above the daemon's own 10 s so the daemon's answer (`timeout`, `unavailable`) wins
/// when it has one. Main thread only.
final class TaskRequests {
    static let shared = TaskRequests()

    static let outputTimeout: TimeInterval = 12
    static let stopTimeout: TimeInterval = 12
    /// The most the daemon sends for one read (it clamps anything above).
    static let maxReadBytes: UInt32 = 1_048_576

    /// The daemon connection; nil until `AppStore.start()` sets it.
    var sender: TaskRequestSending?

    private struct Pending {
        let token: Int
        /// Runs the caller's completion with whatever ended the request.
        let finish: (Ended) -> Void
    }

    private enum Ended {
        case output(SessionTaskOutputResultWire)
        case stop(SessionTaskStopResultWire)
        case timedOut
        case failed(String)
    }

    private var pending: [String: Pending] = [:]
    private var nextToken = 0
    private let makeRequestId: () -> String
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void

    /// `schedule` runs work after a delay on the main thread (tests pass a manual scheduler).
    init(makeRequestId: @escaping () -> String = { UUID().uuidString },
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         }) {
        self.makeRequestId = makeRequestId
        self.schedule = schedule
    }

    /// How many requests wait for an answer.
    var pendingCount: Int { pending.count }

    // MARK: - Requests

    /// Read output (`offset` nil: the tail). `completion` runs once. Returns the request id.
    @discardableResult
    func requestOutput(tag: String, taskId: String, offset: UInt64?,
                       maxBytes: UInt32 = TaskRequests.maxReadBytes,
                       completion: @escaping (TaskReply<SessionTaskOutputResultWire>) -> Void) -> String? {
        expect(timeout: Self.outputTimeout, finish: { ended in
            switch ended {
            case .output(let wire): completion(.answered(wire))
            case .timedOut: completion(.timedOut)
            case .failed(let reason): completion(.failed(reason))
            case .stop: completion(.failed("unexpected answer"))
            }
        }, send: { sender, id in
            sender.sendTaskOutput(requestId: id, tag: tag, taskId: taskId, offset: offset, maxBytes: maxBytes)
        }, failed: { completion(.failed($0)) })
    }

    /// Ask the daemon to stop a task. `completion` runs once. Returns the request id.
    @discardableResult
    func requestStop(tag: String, taskId: String,
                     completion: @escaping (TaskReply<SessionTaskStopResultWire>) -> Void) -> String? {
        expect(timeout: Self.stopTimeout, finish: { ended in
            switch ended {
            case .stop(let wire): completion(.answered(wire))
            case .timedOut: completion(.timedOut)
            case .failed(let reason): completion(.failed(reason))
            case .output: completion(.failed("unexpected answer"))
            }
        }, send: { sender, id in
            sender.sendTaskStop(requestId: id, tag: tag, taskId: taskId)
        }, failed: { completion(.failed($0)) })
    }

    // MARK: - Answers

    /// Route a decoded daemon frame: the two answers resolve their request, anything else is ignored.
    func ingest(_ msg: ServerMsg) {
        switch msg {
        case .sessionTaskOutputResult(let wire):
            pending.removeValue(forKey: wire.requestId)?.finish(.output(wire))
        case .sessionTaskStopResult(let wire):
            pending.removeValue(forKey: wire.requestId)?.finish(.stop(wire))
        default:
            break
        }
    }

    /// The daemon connection went away: nothing will answer, so fail every waiter now. A late answer
    /// is ignored.
    func failPendingRequests(reason: String) {
        let waiting = pending
        pending.removeAll()
        for (_, request) in waiting { request.finish(.failed(reason)) }
    }

    // MARK: - Private

    private func expect(timeout: TimeInterval,
                        finish: @escaping (Ended) -> Void,
                        send: (TaskRequestSending, String) -> Void,
                        failed: (String) -> Void) -> String? {
        guard let sender else {
            failed("The daemon connection is not available")
            return nil
        }
        let id = makeRequestId()
        nextToken += 1
        let token = nextToken
        pending[id] = Pending(token: token, finish: finish)
        schedule(timeout) { [weak self] in
            guard let self, self.pending[id]?.token == token else { return }
            self.pending.removeValue(forKey: id)?.finish(.timedOut)
        }
        send(sender, id)
        return id
    }
}
