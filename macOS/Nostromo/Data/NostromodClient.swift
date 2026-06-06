import Foundation
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
    // ── persistent session responses (protocol v3) ──────────────────────────
    case sessionSpawned(tag: String, sessionId: String?)
    case sessionTurns(tag: String, turns: [DaemonTurn])
    case sessionTurnDelta(tag: String, delta: DaemonTurnDelta)
    case sessionState(tag: String, state: DaemonSessionState)
    case sessionPermissionRequest(tag: String, requestId: String, tool: String)
    case sessionExited(tag: String, exitCode: Int?)
    /// The session has been permanently stopped and will not auto-restart.
    /// `reason: .user` → benign user stop (clear indicator); `reason: .crashLoopGuard` → alarm.
    case sessionDown(tag: String, reason: DaemonStopReason)
    /// Auto-generated one-line summary derived from the first user message.
    /// Sent once per session lifetime by the daemon.
    case sessionSummaryUpdate(tag: String, summary: String)
    case unknown
}

// MARK: - Session wire types (mirror src/ipc/stream_json.rs; snake_case/tagged)

enum DaemonSessionState: String, Decodable {
    case idle
    case midTurn            = "mid_turn"
    case awaitingPermission = "awaiting_permission"
    case crashed
}

/// Mirrors `StopReason` in `session_manager.rs`. Unknown strings decode safely
/// to `.user` (benign) so future variants never cause an alarm false-positive.
enum DaemonStopReason: String, Decodable {
    case user             = "user"
    case crashLoopGuard   = "crash_loop_guard"
    case staleId          = "stale_id"

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DaemonStopReason(rawValue: raw) ?? .user
    }
}

struct DaemonAskOption: Decodable {
    let label: String
    let description: String
}

/// Mirrors `stream_json::TurnBlock` — tagged by `kind`.
enum DaemonTurnBlock: Decodable {
    case text(String)
    case toolCall(toolName: String, inputSummary: String, inputFull: String)
    case toolResult(content: String, isError: Bool)
    case resultSummary(durationMs: Int, costUsd: Double, isError: Bool)
    case errorMessage(String)
    case askQuestion(question: String, header: String, options: [DaemonAskOption], multiSelect: Bool)

    private enum K: String, CodingKey {
        case kind, text
        case toolName = "tool_name", inputSummary = "input_summary", inputFull = "input_full"
        case content, isError = "is_error"
        case durationMs = "duration_ms", costUsd = "cost_usd"
        case message, question, header, options, multiSelect = "multi_select"
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "text":
            self = .text(try c.decode(String.self, forKey: .text))
        case "tool_call":
            self = .toolCall(toolName: try c.decode(String.self, forKey: .toolName),
                             inputSummary: try c.decode(String.self, forKey: .inputSummary),
                             inputFull: try c.decode(String.self, forKey: .inputFull))
        case "tool_result":
            self = .toolResult(content: try c.decode(String.self, forKey: .content),
                               isError: try c.decode(Bool.self, forKey: .isError))
        case "result_summary":
            self = .resultSummary(durationMs: try c.decode(Int.self, forKey: .durationMs),
                                  costUsd: try c.decode(Double.self, forKey: .costUsd),
                                  isError: try c.decode(Bool.self, forKey: .isError))
        case "error_message":
            self = .errorMessage(try c.decode(String.self, forKey: .message))
        case "ask_question":
            self = .askQuestion(question: try c.decode(String.self, forKey: .question),
                                header: try c.decode(String.self, forKey: .header),
                                options: try c.decode([DaemonAskOption].self, forKey: .options),
                                multiSelect: try c.decode(Bool.self, forKey: .multiSelect))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                debugDescription: "unknown TurnBlock kind: \(other)")
        }
    }
}

struct DaemonResultSummary: Decodable {
    let durationMs: Int
    let costUsd: Double
    let isError: Bool
    enum CodingKeys: String, CodingKey {
        case durationMs = "duration_ms", costUsd = "cost_usd", isError = "is_error"
    }
}

struct DaemonTurn: Decodable {
    let id: String
    let userInput: String
    let timestamp: String?
    let blocks: [DaemonTurnBlock]
    let isComplete: Bool
    enum CodingKeys: String, CodingKey {
        case id, userInput = "user_input", timestamp, blocks, isComplete = "is_complete"
    }
}

/// Mirrors `stream_json::TurnDelta` — tagged by `delta`.
enum DaemonTurnDelta: Decodable {
    case turnStarted(DaemonTurn)
    case blockAppended(turnId: String, block: DaemonTurnBlock)
    case turnCompleted(turnId: String, summary: DaemonResultSummary)
    case turnErrored(turnId: String, message: String)

    private enum K: String, CodingKey {
        case delta, turn, turnId = "turn_id", block, summary, message
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .delta) {
        case "turn_started":
            self = .turnStarted(try c.decode(DaemonTurn.self, forKey: .turn))
        case "block_appended":
            self = .blockAppended(turnId: try c.decode(String.self, forKey: .turnId),
                                  block: try c.decode(DaemonTurnBlock.self, forKey: .block))
        case "turn_completed":
            self = .turnCompleted(turnId: try c.decode(String.self, forKey: .turnId),
                                  summary: try c.decode(DaemonResultSummary.self, forKey: .summary))
        case "turn_errored":
            self = .turnErrored(turnId: try c.decode(String.self, forKey: .turnId),
                                message: try c.decode(String.self, forKey: .message))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .delta, in: c,
                debugDescription: "unknown TurnDelta: \(other)")
        }
    }
}

// MARK: - Outbound session commands (ClientMsg, protocol v3)

private struct SessionSpawnMsg: Encodable {
    let type_ = "session_spawn"
    let tag: String
    let agentName: String
    let viewName: String
    let cwd: String?
    let sessionId: String?
    let remoteControl: Bool
    enum CodingKeys: String, CodingKey {
        case type_ = "type", tag, agentName = "agent_name", viewName = "view_name"
        case cwd, sessionId = "session_id", remoteControl = "remote_control"
    }
}

private struct SessionAttachMsg: Encodable {
    let type_ = "session_attach"
    let tag: String
    enum CodingKeys: String, CodingKey { case type_ = "type", tag }
}

private struct SessionDetachMsg: Encodable {
    let type_ = "session_detach"
    let tag: String
    enum CodingKeys: String, CodingKey { case type_ = "type", tag }
}

private struct SessionSendMsg: Encodable {
    let type_ = "session_send"
    let tag: String
    let text: String
    let images: [String]
    enum CodingKeys: String, CodingKey { case type_ = "type", tag, text, images }
}

private struct SessionControlMsg: Encodable {
    let type_ = "session_control"
    let tag: String
    let action: String
    enum CodingKeys: String, CodingKey { case type_ = "type", tag, action }
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

    /// Current connection state. CurrentValueSubject replays the latest value to
    /// new subscribers, so a ChatSession created while already connected spawns
    /// exactly once, and a reconnect (false→true) re-triggers spawn/attach —
    /// without the init+welcome double that caused duplicate-rendered turns.
    let connected = CurrentValueSubject<Bool, Never>(false)

    private var fd: Int32 = -1            // POSIX AF_UNIX socket (NWConnection's
                                         // .unix endpoint fails with ENETDOWN).
    private let sendLock = NSLock()
    private let socketPath: String
    private let q = DispatchQueue(label: "com.hammer.nostromo.ipc", qos: .utility)
    private var reconnectDelay: TimeInterval = 1.0
    private let encoder = JSONEncoder()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        // nostromd timestamps include microseconds ("2026-05-30T09:30:56.510874Z").
        // Swift's built-in .iso8601 strategy rejects fractional seconds, so the
        // entire MotherJob silently fails to decode. Use a custom strategy that
        // handles both formats.
        let fmtFrac = ISO8601DateFormatter()
        fmtFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fmtBasic = ISO8601DateFormatter()
        fmtBasic.formatOptions = [.withInternetDateTime]
        d.dateDecodingStrategy = .custom { decoder in
            let c   = try decoder.singleValueContainer()
            let str = try c.decode(String.self)
            if let date = fmtFrac.date(from: str)  { return date }
            if let date = fmtBasic.date(from: str) { return date }
            throw DecodingError.dataCorruptedError(in: c,
                debugDescription: "Cannot parse date: \(str)")
        }
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
        // Run the blocking connect off any caller thread.
        q.async { [weak self] in self?.doConnect() }
    }

    private func doConnect() {
        let sock = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            log.warning("socket() failed errno=\(errno, privacy: .public)")
            scheduleReconnect(); return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)   // 104 on Darwin
        let pathBytes = socketPath.utf8CString                 // includes NUL
        guard pathBytes.count <= cap else {
            log.error("socket path too long: \(self.socketPath, privacy: .public)")
            Darwin.close(sock); return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
                pathBytes.withUnsafeBufferPointer { src in
                    dst.update(from: src.baseAddress!, count: src.count)
                }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, len)
            }
        }
        guard r == 0 else {
            log.warning("connect failed errno=\(errno, privacy: .public) — retrying in \(self.reconnectDelay, privacy: .public)s")
            Darwin.close(sock); scheduleReconnect(); return
        }

        log.info("Connected to nostromd at \(self.socketPath, privacy: .public)")
        fd = sock
        reconnectDelay = 1.0
        sendHello()
        connected.send(true)
        // Blocking frame reader on a dedicated background queue.
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.readLoop(sock) }
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
        // protocol v3 adds the persistent Session* family. The daemon holds
        // MIN_CLIENT_VERSION at 2, so this is safe either way, but we speak v3.
        send(ClientHello(clientId: UUID().uuidString, protocolVersion: 3))
        send(ClientSubscribe(topics: ["activity", "mother_jobs", "mother_statusline"]))
    }

    // MARK: - Session commands (protocol v3)

    /// Spawn (or resume) a focus's persistent daemon-hosted session. Idempotent.
    func sessionSpawn(tag: String, agentName: String, viewName: String,
                      cwd: String?, sessionId: String?, remoteControl: Bool) {
        send(SessionSpawnMsg(tag: tag, agentName: agentName, viewName: viewName,
                             cwd: cwd, sessionId: sessionId, remoteControl: remoteControl))
    }

    /// Attach to a session — daemon replies with a `SessionTurns` snapshot then
    /// streams `SessionTurnDelta`/`SessionState`.
    func sessionAttach(tag: String) { send(SessionAttachMsg(tag: tag)) }

    /// Stop receiving deltas for a session without stopping the child.
    func sessionDetach(tag: String) { send(SessionDetachMsg(tag: tag)) }

    /// Enqueue a user message; the daemon writes it to the child's stdin.
    func sessionSend(tag: String, text: String, imagePaths: [String] = []) {
        send(SessionSendMsg(tag: tag, text: text, images: imagePaths))
    }

    /// Lifecycle control: "stop" | "restart" | "new_session".
    func sessionControl(tag: String, action: String) {
        send(SessionControlMsg(tag: tag, action: action))
    }

    private func send(_ msg: some Encodable) {
        guard fd >= 0, let body = try? encoder.encode(msg)
        else { log.debug("send dropped — not connected (fd=\(self.fd, privacy: .public))"); return }

        var bigEndianLen = UInt32(body.count).bigEndian
        var frame = Data(bytes: &bigEndianLen, count: 4)
        frame.append(body)

        sendLock.lock(); defer { sendLock.unlock() }
        let curFd = fd
        guard curFd >= 0 else { return }
        frame.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var off = 0
            while off < raw.count {
                let n = Darwin.write(curFd, base.advanced(by: off), raw.count - off)
                if n <= 0 { log.warning("write failed errno=\(errno, privacy: .public)"); break }
                off += n
            }
        }
    }

    // MARK: - Frame reading

    /// Blocking frame reader: 4-byte big-endian length prefix + JSON body.
    /// Runs on a background queue; on EOF/error it closes the fd and reconnects.
    private func readLoop(_ sock: Int32) {
        while true {
            guard let header = readN(sock, 4) else { break }
            let length = header.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) }
            guard length > 0, length <= 4 * 1024 * 1024 else { break }
            guard let body = readN(sock, Int(length)) else { break }
            dispatch(body)   // hops to main internally
        }
        log.info("read loop ended (fd=\(sock, privacy: .public)) — reconnecting")
        Darwin.close(sock)
        if fd == sock { fd = -1 }
        connected.send(false)
        scheduleReconnect()
    }

    /// Read exactly `count` bytes, or nil on EOF/error.
    private func readN(_ sock: Int32, _ count: Int) -> Data? {
        var buf = Data(count: count)
        let ok = buf.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return false }
            var got = 0
            while got < count {
                let n = Darwin.read(sock, base.advanced(by: got), count - got)
                if n <= 0 { return false }
                got += n
            }
            return true
        }
        return ok ? buf : nil
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
            // Jobs are now sourced via `mother list --format json` polling in AppStore.
            // IPC mother_jobs is ignored to avoid the fractional-seconds date decode issue.
            break

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

        // ── persistent session responses (protocol v3) ──────────────────────
        case "session_spawned":
            if let m = try? decoder.decode(SessionSpawnedResp.self, from: raw) {
                return .sessionSpawned(tag: m.tag, sessionId: m.session_id)
            }

        case "session_turns":
            if let m = try? decoder.decode(SessionTurnsResp.self, from: raw) {
                return .sessionTurns(tag: m.tag, turns: m.turns)
            }

        case "session_turn_delta":
            if let m = try? decoder.decode(SessionTurnDeltaResp.self, from: raw) {
                return .sessionTurnDelta(tag: m.tag, delta: m.delta)
            } else {
                log.error("failed to decode session_turn_delta")
            }

        case "session_state":
            if let m = try? decoder.decode(SessionStateResp.self, from: raw) {
                return .sessionState(tag: m.tag, state: m.state)
            }

        case "session_permission_request":
            if let m = try? decoder.decode(SessionPermResp.self, from: raw) {
                return .sessionPermissionRequest(tag: m.tag, requestId: m.request_id, tool: m.tool)
            }

        case "session_exited":
            if let m = try? decoder.decode(SessionExitedResp.self, from: raw) {
                return .sessionExited(tag: m.tag, exitCode: m.exit_code)
            }

        case "session_down":
            if let m = try? decoder.decode(SessionDownResp.self, from: raw) {
                return .sessionDown(tag: m.tag, reason: m.reason)
            }

        case "session_summary_update":
            if let m = try? decoder.decode(SessionSummaryUpdateResp.self, from: raw) {
                return .sessionSummaryUpdate(tag: m.tag, summary: m.summary)
            }

        default:
            break
        }

        return .unknown
    }
}

// MARK: - Inbound session response wrappers (decoded from the raw frame)

private struct SessionSpawnedResp: Decodable { let tag: String; let session_id: String? }
private struct SessionTurnsResp:   Decodable { let tag: String; let turns: [DaemonTurn] }
private struct SessionTurnDeltaResp: Decodable { let tag: String; let delta: DaemonTurnDelta }
private struct SessionStateResp:   Decodable { let tag: String; let state: DaemonSessionState }
private struct SessionPermResp:    Decodable { let tag: String; let request_id: String; let tool: String }
private struct SessionExitedResp:  Decodable { let tag: String; let exit_code: Int? }
private struct SessionDownResp:          Decodable { let tag: String; let reason: DaemonStopReason }
private struct SessionSummaryUpdateResp: Decodable { let tag: String; let summary: String }
