import Foundation
import NostromoKit

/// What the MCP requests ask of the daemon connection. `NostromodClient` is the real one; tests pass a recorder.
protocol McpRequestSending: AnyObject {
    /// Whether the daemon's last `welcome` advertised `session_mcp_v1`.
    var daemonAdvertisesSessionMcp: Bool { get }
    func sendSessionMcp(requestId: String, tag: String, action: String, server: String?, enabled: Bool?)
}

extension NostromodClient: McpRequestSending {}

/// Request/response for `session_mcp`: every request gets an id, one completion that runs exactly once, and
/// a timeout. A late or duplicate answer is ignored. The pattern of `TaskRequests`.
///
/// The timeout sits above the daemon's own waits (30 s for a reconnect plus 10 s for the list that follows),
/// so the daemon's `timeout` outcome wins when it has one. Main thread only.
final class McpRequests {
    static let shared = McpRequests()

    static let timeout: TimeInterval = 45

    /// The daemon connection; nil until `AppStore.start()` sets it.
    var sender: McpRequestSending?

    private struct Pending {
        let token: Int
        let finish: (TaskReply<SessionMcpResultWire>) -> Void
    }

    private var pending: [String: Pending] = [:]
    private var nextToken = 0
    private let makeRequestId: () -> String
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void

    init(makeRequestId: @escaping () -> String = { UUID().uuidString },
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         }) {
        self.makeRequestId = makeRequestId
        self.schedule = schedule
    }

    /// Whether the connected daemon takes `session_mcp`. Without it `/mcp` goes to the CLI and the
    /// "Tools offline" badge is not clickable.
    var isAvailable: Bool { sender?.daemonAdvertisesSessionMcp == true }

    /// How many requests wait for an answer.
    var pendingCount: Int { pending.count }

    /// Ask the daemon. `completion` runs once. Returns the request id (nil when there is no connection;
    /// the completion has then already run with `.failed`).
    @discardableResult
    func request(tag: String, action: String, server: String? = nil, enabled: Bool? = nil,
                 completion: @escaping (TaskReply<SessionMcpResultWire>) -> Void) -> String? {
        guard let sender, sender.daemonAdvertisesSessionMcp else {
            completion(.failed("The daemon connection is not available"))
            return nil
        }
        let id = makeRequestId()
        nextToken += 1
        let token = nextToken
        pending[id] = Pending(token: token, finish: completion)
        schedule(Self.timeout) { [weak self] in
            guard let self, self.pending[id]?.token == token else { return }
            self.pending.removeValue(forKey: id)?.finish(.timedOut)
        }
        sender.sendSessionMcp(requestId: id, tag: tag, action: action, server: server, enabled: enabled)
        return id
    }

    /// Route a decoded daemon frame: a `session_mcp_result` resolves its request; anything else is ignored.
    func ingest(_ msg: ServerMsg) {
        guard case .sessionMcpResult(let wire) = msg else { return }
        pending.removeValue(forKey: wire.requestId)?.finish(.answered(wire))
    }

    /// The daemon connection went away: nothing will answer, so fail every waiter now.
    func failPendingRequests(reason: String) {
        let waiting = pending
        pending.removeAll()
        for (_, request) in waiting { request.finish(.failed(reason)) }
    }
}
