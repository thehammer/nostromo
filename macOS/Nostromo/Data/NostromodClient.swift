import Foundation
import Network
import Combine
import os

private let log = Logger(subsystem: "com.hammer.nostromo", category: "ipc")

// MARK: - Wire types (ClientMsg outbound)

private struct ClientHello: Encodable {
    let type_            = "hello"
    let clientId:         String
    let protocolVersion:  Int
    enum CodingKeys: String, CodingKey {
        case type_           = "type"
        case clientId        = "client_id"
        case protocolVersion = "protocol_version"
    }
}

private struct ClientSubscribe: Encodable {
    let type_  = "subscribe"
    let topics: [String]
    enum CodingKeys: String, CodingKey {
        case type_  = "type"
        case topics
    }
}

// MARK: - ServerMsg (inbound)

enum ServerMsg {
    case welcome(protocolVersion: Int, daemonPid: Int)
    case activity(ActivityEvent)
    case motherJobs([MotherJob])
    case motherStatusline(MotherStatus)
    case pong
    case error(String)
    case unknown
}

// MARK: - NostromodClient

/// Unix-socket IPC client for nostromd.
///
/// Frames: 4-byte big-endian length prefix + UTF-8 JSON body (max 4 MiB).
/// Auto-reconnects with exponential backoff (1 s → 30 s).
class NostromodClient {

    // Socket path honours NOSTROMD_SOCKET env var, matching the Rust daemon.
    static let defaultSocketPath: String = {
        if let v = ProcessInfo.processInfo.environment["NOSTROMD_SOCKET"] { return v }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.nostromo/nostromd.sock"
    }()

    /// Publishes decoded server messages on the main queue.
    let messages = PassthroughSubject<ServerMsg, Never>()

    private var connection: NWConnection?
    private let socketPath: String
    private let q = DispatchQueue(label: "com.hammer.nostromo.ipc", qos: .utility)
    private var reconnectDelay: TimeInterval = 1.0
    private let encoder = JSONEncoder()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(socketPath: String = NostromodClient.defaultSocketPath) {
        self.socketPath = socketPath
    }

    func start() {
        log.info("Starting — socket: \(self.socketPath, privacy: .public)")
        connect()
    }

    // MARK: - Connection lifecycle

    private func connect() {
        let endpoint = NWEndpoint.unix(path: socketPath)
        let conn = NWConnection(to: endpoint, using: NWParameters())
        connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                log.info("Connected to nostromd at \(self.socketPath, privacy: .public)")
                self.reconnectDelay = 1.0
                self.sendHello()
                self.readLength()
            case .failed(let err):
                log.warning("Connection failed: \(err, privacy: .public) — retrying in \(self.reconnectDelay, privacy: .public)s")
                self.scheduleReconnect()
            case .cancelled:
                break
            default:
                break
            }
        }

        conn.start(queue: q)
    }

    private func scheduleReconnect() {
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30.0)
        q.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect()
        }
    }

    // MARK: - Handshake

    private func sendHello() {
        send(ClientHello(clientId: UUID().uuidString, protocolVersion: 2))
        send(ClientSubscribe(topics: ["activity", "mother_jobs", "mother_statusline"]))
    }

    private func send(_ msg: some Encodable) {
        guard let conn = connection,
              let body = try? encoder.encode(msg)
        else { return }

        var bigEndianLen = UInt32(body.count).bigEndian
        let frame = Data(bytes: &bigEndianLen, count: 4) + body
        conn.send(content: frame, completion: .idempotent)
    }

    // MARK: - Frame reading

    private func readLength() {
        connection?.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            guard let self else { return }
            guard error == nil, let data, data.count == 4 else {
                if error != nil { self.scheduleReconnect() }
                return
            }
            let length = data.withUnsafeBytes { ptr in
                UInt32(bigEndian: ptr.loadUnaligned(as: UInt32.self))
            }
            guard length > 0, length <= 4 * 1024 * 1024 else {
                self.readLength()
                return
            }
            self.readBody(length: Int(length))
        }
    }

    private func readBody(length: Int) {
        connection?.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, _ in
            guard let self else { return }
            if let data { self.dispatch(data) }
            self.readLength()
        }
    }

    // MARK: - Decoding

    private func dispatch(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type_ = json["type"] as? String
        else { return }

        let msg = decode(type_: type_, json: json, raw: data)
        log.debug("← \(type_, privacy: .public) (\(data.count, privacy: .public) bytes)")
        DispatchQueue.main.async { [weak self] in
            self?.messages.send(msg)
        }
    }

    private func decode(type_: String, json: [String: Any], raw: Data) -> ServerMsg {
        switch type_ {

        case "welcome":
            return .welcome(
                protocolVersion: json["protocol_version"] as? Int ?? 0,
                daemonPid:       json["daemon_pid"]       as? Int ?? 0
            )

        case "activity":
            // ActivityEvent fields are flattened into the top-level object.
            if let ev = try? decoder.decode(ActivityEvent.self, from: raw) {
                return .activity(ev)
            }

        case "mother_jobs":
            if let jobsRaw = json["jobs"],
               let jobsData = try? JSONSerialization.data(withJSONObject: jobsRaw),
               let jobs = try? decoder.decode([MotherJob].self, from: jobsData) {
                return .motherJobs(jobs)
            }

        case "mother_statusline":
            return .motherStatusline(MotherStatus(
                running:  json["running"]  as? Int ?? 0,
                queued:   json["queued"]   as? Int ?? 0,
                failed:   json["failed"]   as? Int ?? 0,
                awaiting: json["awaiting"] as? Int ?? 0
            ))

        case "pong":
            return .pong

        case "error":
            return .error(json["message"] as? String ?? "unknown error")

        default:
            break
        }

        return .unknown
    }
}
