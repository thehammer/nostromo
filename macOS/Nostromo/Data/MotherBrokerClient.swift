import Foundation
import Combine
import NostromoKit
import os

private let log = Logger(subsystem: "com.hammer.nostromo", category: "broker")

// MARK: - Protocol constants

let BROKER_PROTOCOL_VERSION = 1
private let MAX_LINE_BYTES: Int = 8 * 1024 * 1024  // 8 MiB per line cap
let BROKER_ACK_TIMEOUT: TimeInterval = 10.0

// MARK: - Error vocabulary (switch on code, never the message string)

enum BrokerErrorCode: String {
    case noSuchJob       = "no_such_job"
    case invalidState    = "invalid_state"
    case malformed       = "malformed"
    case unavailable     = "unavailable"
    case versionMismatch = "version_mismatch"
    case unauthorized    = "unauthorized"
    case `internal`      = "internal"
}

enum BrokerError: Error {
    case code(BrokerErrorCode, message: String)
    case timeout
    case disconnected

    /// Human-readable message safe to surface in the UI.
    var userFacingMessage: String {
        switch self {
        case .timeout:
            return "Mother is busy, try again."
        case .disconnected:
            return "Mother broker is offline."
        case .code(let code, let message):
            switch code {
            case .noSuchJob:
                return "Job no longer exists."
            case .invalidState:
                return "Can't perform that action — job is no longer in a valid state for it."
            case .malformed:
                return "Internal error: malformed command."
            case .unavailable:
                return "Mother is busy, try again."
            case .versionMismatch:
                return "Mother broker version incompatible — update Nostromo or the broker."
            case .unauthorized:
                return "Unauthorized."
            case .internal:
                return "Mother failed to apply the action: \(message)."
            }
        }
    }
}

extension BrokerError {
    /// The failure in the store's terms (never the broker's message text).
    var kind: BrokerErrorKind {
        switch self {
        case .timeout: return .timeout
        case .disconnected: return .disconnected
        case .code(let code, _):
            switch code {
            case .noSuchJob: return .noSuchJob
            case .invalidState: return .invalidState
            case .unauthorized: return .unauthorized
            case .unavailable: return .unavailable
            default: return .other
            }
        }
    }

    /// What to tell the operator about a failed decision answer. Mother's own message text
    /// is never shown: for `unauthorized` and `internal` only the class is.
    var decisionMessage: String {
        switch self {
        case .code(.invalidState, _):
            return "This hold was already answered or changed. Refreshed."
        case .code(.unauthorized, _):
            return "Mother refused the answer: unauthorized."
        case .code(.internal, _):
            return "Mother failed to apply the answer."
        default:
            return userFacingMessage
        }
    }
}

extension BrokerErrorKind {
    /// The class of the failure, for logs.
    var logName: String {
        switch self {
        case .noSuchJob: return "no_such_job"
        case .invalidState: return "invalid_state"
        case .unauthorized: return "unauthorized"
        case .unavailable: return "unavailable"
        case .timeout: return "timeout"
        case .disconnected: return "disconnected"
        case .other: return "other"
        }
    }
}

/// A decoded `query.list` reply. `partial` is true when any entry could not be read.
struct MotherJobListing: Equatable {
    var jobs: [MotherJob]
    var partial: Bool
    var unreadableIds: Set<String>
}

// MARK: - BrokerEvent (published on the main queue to AppStore)

enum BrokerEvent {
    /// Initial hello — broker link is live, capabilities captured.
    case hello(protocolVersion: Int, capabilities: [String])
    /// Atomic full-queue snapshot after subscribe.
    case snapshot([MotherJob])
    /// A new job that arrived after the initial snapshot. The broker embeds
    /// the full job payload in the "queued" event detail so subscribers
    /// connected before this job existed can construct a MotherJob without
    /// a reconnect or round-trip.
    case newJob(MotherJob)
    /// A state or detail change on one job (state fold applied by AppStore).
    case stateChange(
        jobId:        String,
        eventKind:    String,
        question:     String?,
        pausedReason: String?,
        toState:      String?
    )
    /// Mother's `progress_updated` overlay for one job (the broker's newest `updated_at` wins).
    case progress(jobId: String, MotherProgress)
    /// A crew event (gate, wave, decision or attention change) for one job: the broker's
    /// record is authoritative, so AppStore re-reads the job with `query.get` instead of
    /// folding the event itself.
    case crewChanged(jobId: String)
    /// Liveness ping — ignore.
    case ping
    /// Client reconnected after disconnect — AppStore must clear jobMap and await next snapshot.
    case reconnected
}

// MARK: - Internal pending-command record

private struct PendingCommand {
    /// Gets the ack's `data` on success.
    let completion: (Result<[String: Any], BrokerError>) -> Void
    let timer:      DispatchWorkItem
}

// MARK: - MotherBrokerClient

/// Unix-socket IPC client for the Mother broker.
///
/// Wire protocol: NDJSON, one JSON object per `\n`-terminated line (max 8 MiB).
/// Connection lifecycle: exponential-backoff reconnect (1 s → 30 s).
/// Handshake: reads hello event, sends subscribe, then streams events.
/// Commands: `answer`/`cancel`/`retry` are correlated by client-assigned UUID `id`.
class MotherBrokerClient {

    // MARK: - Socket path

    /// Resolves: $MOTHER_BROKER_SOCK → $MOTHER_ROOT/broker.sock → ~/.mother/broker.sock
    static let defaultSocketPath: String = {
        let env = ProcessInfo.processInfo.environment
        if let v = env["MOTHER_BROKER_SOCK"] { return v }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let root = env["MOTHER_ROOT"] ?? "\(home)/.mother"
        return "\(root)/broker.sock"
    }()

    // MARK: - Public API

    /// Decoded broker events, published on the main queue.
    let events    = PassthroughSubject<BrokerEvent, Never>()
    /// True after hello is received + subscribe is sent. False while reconnecting.
    let connected = CurrentValueSubject<Bool, Never>(false)

    // MARK: - Private state

    private var fd:           Int32 = -1
    private let sendLock    = NSLock()
    private let pendingLock = NSLock()
    private var pending:     [String: PendingCommand] = [:]
    private let socketPath:  String
    private let q = DispatchQueue(label: "com.hammer.nostromo.broker", qos: .utility)
    private var reconnectDelay: TimeInterval = 1.0
    private let capsLock = NSLock()
    private var _advertisedCaps: [String] = []
    /// What the broker's hello advertised (empty until connected, and for an unknown broker).
    private var advertisedCaps: [String] {
        get { capsLock.lock(); defer { capsLock.unlock() }; return _advertisedCaps }
        set { capsLock.lock(); _advertisedCaps = newValue; capsLock.unlock() }
    }

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        // Broker emits millisecond-precision ISO8601 (e.g. "…000Z").
        // Reuse the same frac+basic custom strategy that NostromodClient uses.
        let fmtFrac  = ISO8601DateFormatter()
        fmtFrac.formatOptions  = [.withInternetDateTime, .withFractionalSeconds]
        let fmtBasic = ISO8601DateFormatter()
        fmtBasic.formatOptions = [.withInternetDateTime]
        d.dateDecodingStrategy = .custom { dec in
            let c   = try dec.singleValueContainer()
            let str = try c.decode(String.self)
            if let date = fmtFrac.date(from: str)  { return date }
            if let date = fmtBasic.date(from: str) { return date }
            throw DecodingError.dataCorruptedError(in: c,
                debugDescription: "Cannot parse broker date: \(str)")
        }
        return d
    }()

    // MARK: - Init

    init(socketPath: String = MotherBrokerClient.defaultSocketPath) {
        self.socketPath = socketPath
    }

    // MARK: - Capabilities (B4: a feature is used only when the broker advertises it)

    /// `progress_updated` events and the `progress` subscription.
    var supportsProgress: Bool { advertisedCaps.contains("progress") }
    /// `answer` with an option id (MC3).
    var supportsAnswerOption: Bool { advertisedCaps.contains("answer.option") }
    /// The `ack` command (MC3).
    var supportsAck: Bool { advertisedCaps.contains("ack") }

    /// The `source` this app's answers carry: a person's gesture in the Mac app.
    static let appSource = "nostromo_app"

    // MARK: - Lifecycle

    func start() {
        log.info("Broker client starting — \(self.socketPath, privacy: .public)")
        connect()
    }

    // MARK: - Outbound command API

    /// A free-text answer. Mother records who answered: `nostromo_app` is sent only where the
    /// broker understands it, and only ever from a control that checked for a human gesture.
    func answer(job: String, text: String,
                completion: @escaping (Result<Void, BrokerError>) -> Void) {
        var extra: [String: Any] = ["text": text]
        if supportsAnswerOption { extra["source"] = MotherBrokerClient.appSource }
        sendCommand(type: "answer", jobId: job, extra: extra, completion: completion)
    }

    /// Answer a hold by option id. A broker that does not advertise `answer.option` only knows
    /// free text: guidance goes as that, and any other option is refused here, sending nothing.
    func answer(job: String, option: MotherDecisionOptionID, text: String?,
                source: String = MotherBrokerClient.appSource,
                completion: @escaping (Result<Void, BrokerError>) -> Void) {
        guard supportsAnswerOption else {
            if option == .resumeWithGuidance, let text, !text.isEmpty {
                sendCommand(type: "answer", jobId: job, extra: ["text": text], completion: completion)
            } else {
                completion(.failure(.code(.invalidState, message: "this Mother cannot answer by option")))
            }
            return
        }
        var extra: [String: Any] = ["option": option.raw, "source": source]
        if let text { extra["text"] = text }
        sendCommand(type: "answer", jobId: job, extra: extra, completion: completion)
    }

    /// Acknowledge a raised attention flag (`ack`), where the broker has the command.
    func ack(job: String, reason: String,
             completion: @escaping (Result<Void, BrokerError>) -> Void) {
        guard supportsAck else {
            completion(.failure(.code(.invalidState, message: "this Mother cannot acknowledge flags")))
            return
        }
        sendCommand(type: "ack", jobId: job, extra: ["reason": reason], completion: completion)
    }

    func cancel(job: String,
                completion: @escaping (Result<Void, BrokerError>) -> Void) {
        sendCommand(type: "cancel", jobId: job, extra: [:], completion: completion)
    }

    func retry(job: String,
               completion: @escaping (Result<Void, BrokerError>) -> Void) {
        sendCommand(type: "retry", jobId: job, extra: [:], completion: completion)
    }

    func forceStart(job: String,
                    completion: @escaping (Result<Void, BrokerError>) -> Void) {
        sendCommand(type: "force-start", jobId: job, extra: [:], completion: completion)
    }

    /// Re-read one job. The broker's record is authoritative; the ack's `data.job` is the raw job.
    func queryGet(job: String,
                  completion: @escaping (Result<MotherJob, BrokerError>) -> Void) {
        sendRaw(type: "query.get", jobId: job, extra: [:]) { [weak self] result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let data):
                if let raw = data["job"] as? [String: Any], let decoded = self?.decodeJob(raw) {
                    completion(.success(decoded))
                } else {
                    completion(.failure(.code(.internal, message: "query.get returned no readable job")))
                }
            }
        }
    }

    /// Read the whole queue (`query.list`, no filter). Tolerant like the snapshot: one unreadable
    /// job never loses the others.
    func queryList(completion: @escaping (Result<MotherJobListing, BrokerError>) -> Void) {
        sendRaw(type: "query.list", jobId: "", extra: [:]) { [weak self] result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let data):
                guard let self, let raw = data["jobs"] as? [[String: Any]] else {
                    completion(.failure(.code(.internal, message: "query.list returned no job list")))
                    return
                }
                completion(.success(self.decodeJobListing(raw)))
            }
        }
    }

    /// Like `decodeJobList`, but reports partial reads and the ids of unreadable entries
    /// (when the id itself is readable) so a resync never treats them as gone.
    func decodeJobListing(_ raw: [[String: Any]]) -> MotherJobListing {
        var jobs: [MotherJob] = []
        var unreadable = Set<String>()
        var partial = false
        for entry in raw {
            if let job = decodeJob(entry) {
                jobs.append(job)
            } else {
                partial = true
                if let id = entry["id"] as? String, !id.isEmpty { unreadable.insert(id) }
            }
        }
        if partial {
            log.info("broker job list: \(raw.count - jobs.count, privacy: .public) of \(raw.count, privacy: .public) jobs unreadable")
        }
        return MotherJobListing(jobs: jobs, partial: partial, unreadableIds: unreadable)
    }

    /// Decode each job on its own; unreadable ones are skipped and counted (content-free log).
    func decodeJobList(_ raw: [[String: Any]]) -> [MotherJob] {
        let jobs = raw.compactMap { decodeJob($0) }
        if jobs.count != raw.count {
            log.info("broker job list: \(raw.count - jobs.count, privacy: .public) of \(raw.count, privacy: .public) jobs unreadable")
        }
        return jobs
    }

    // MARK: - Crew events

    /// The event kinds that change a job's gates, review wave, decision or attention
    /// (index bet B3). `progress_updated` is not one: it is applied directly.
    static func isCrewEventKind(_ t: String) -> Bool {
        t.hasPrefix("gates_") || t.hasPrefix("pr_marked_") || t.hasPrefix("review_cycle_")
            || t.hasPrefix("decision_") || t.hasPrefix("attention_")
            || ["gate_result", "gate_fix_started", "lens_skipped", "reviewed", "claims_verified",
                "review_wave_completed", "criterion_checked"].contains(t)
    }

    // MARK: - Connection lifecycle (private)

    private func connect() {
        q.async { [weak self] in self?.doConnect() }
    }

    private func doConnect() {
        let sock = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            log.warning("socket() errno=\(errno, privacy: .public)")
            scheduleReconnect(); return
        }

        // Build sockaddr_un
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= cap else {
            log.error("broker socket path too long")
            Darwin.close(sock); return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
                pathBytes.withUnsafeBufferPointer { src in
                    dst.update(from: src.baseAddress!, count: src.count)
                }
            }
        }
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard r == 0 else {
            log.warning("broker connect errno=\(errno, privacy: .public) — retry in \(self.reconnectDelay, privacy: .public)s")
            Darwin.close(sock); scheduleReconnect(); return
        }

        log.info("Connected to broker at \(self.socketPath, privacy: .public)")
        fd = sock
        reconnectDelay = 1.0

        // Step 1: Read the hello event (first line the broker pushes)
        guard let helloLine = readOneLine(sock) else {
            log.error("broker: EOF before hello")
            Darwin.close(sock); fd = -1; scheduleReconnect(); return
        }
        guard let hello = parseHello(helloLine) else {
            log.error("broker: first line was not a valid hello")
            Darwin.close(sock); fd = -1; scheduleReconnect(); return
        }

        // Forward-compat version check
        if hello.protocolVersion > BROKER_PROTOCOL_VERSION {
            log.warning("broker protocol v\(hello.protocolVersion) > client v\(BROKER_PROTOCOL_VERSION) — forward-compat; proceeding")
        }
        advertisedCaps = hello.capabilities

        // Step 2: Send subscribe command
        sendSubscribe(on: sock)

        // Step 3: Flip connected — link is live
        connected.send(true)
        DispatchQueue.main.async { [weak self] in
            self?.events.send(.hello(
                protocolVersion: hello.protocolVersion,
                capabilities:    hello.capabilities
            ))
        }

        // Step 4: Main buffered read loop (blocks until disconnect)
        readLoop(sock)

        // Cleanup
        Darwin.close(sock)
        if fd == sock { fd = -1 }
        connected.send(false)
        failAllPending(with: .disconnected)
        DispatchQueue.main.async { [weak self] in
            self?.events.send(.reconnected)
        }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30.0)
        q.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect()
        }
    }

    // MARK: - Handshake

    private struct HelloPayload {
        let protocolVersion: Int
        let capabilities:    [String]
    }

    private func parseHello(_ data: Data) -> HelloPayload? {
        guard
            let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let dir   = json["dir"] as? String, dir == "event",
            let t     = json["t"]   as? String, t  == "hello",
            let body  = json["data"] as? [String: Any]
        else { return nil }
        return HelloPayload(
            protocolVersion: body["protocol_version"] as? Int    ?? 1,
            capabilities:    body["capabilities"]     as? [String] ?? []
        )
    }

    private func sendSubscribe(on sock: Int32) {
        let desired: Set<String> = ["state", "activity", "await", "current_activity", "quota"]
        let caps    = Set(advertisedCaps)
        // Intersect with advertised to avoid malformed rejection; if caps is empty (unknown broker)
        // send the full desired set — the broker should accept known categories.
        var filtered = caps.isEmpty ? Array(desired) : Array(desired.intersection(caps))
        // `progress` is newer than the rest: only ever asked for when advertised.
        if caps.contains("progress") { filtered.append("progress") }

        let envelope: [String: Any] = [
            "v":   1,
            "dir": "cmd",
            "t":   "subscribe",
            "id":  UUID().uuidString,
            "ts":  isoTimestamp(),
            "data": [
                "sub":        "queue",
                "jobs":       ["all"],
                "categories": filtered,
            ] as [String: Any],
        ]
        writeJSON(envelope, to: sock)
    }

    // MARK: - Command sending

    private func sendCommand(type: String, jobId: String, extra: [String: Any],
                             completion: @escaping (Result<Void, BrokerError>) -> Void) {
        sendRaw(type: type, jobId: jobId, extra: extra) { completion($0.map { _ in () }) }
    }

    /// Send a command and hand its ack's `data` to `completion` (main queue).
    private func sendRaw(type: String, jobId: String, extra: [String: Any],
                         completion: @escaping (Result<[String: Any], BrokerError>) -> Void) {
        let id = UUID().uuidString
        var data: [String: Any] = jobId.isEmpty ? [:] : ["job": jobId]
        extra.forEach { data[$0.key] = $0.value }

        let envelope: [String: Any] = [
            "v":    1,
            "dir":  "cmd",
            "t":    type,
            "id":   id,
            "ts":   isoTimestamp(),
            "data": data,
        ]

        // 10-second ack timeout — fires on q to avoid main-thread contention
        let timer = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingLock.lock()
            let removed = self.pending.removeValue(forKey: id) != nil
            self.pendingLock.unlock()
            if removed {
                log.warning("broker ack timeout for id=\(id, privacy: .public)")
                DispatchQueue.main.async { completion(.failure(.timeout)) }
            }
        }
        q.asyncAfter(deadline: .now() + BROKER_ACK_TIMEOUT, execute: timer)

        pendingLock.lock()
        pending[id] = PendingCommand(completion: completion, timer: timer)
        pendingLock.unlock()

        // Read fd under sendLock to race-safely capture the current value
        sendLock.lock()
        let curFd = fd
        sendLock.unlock()

        guard curFd >= 0 else {
            timer.cancel()
            pendingLock.lock(); pending.removeValue(forKey: id); pendingLock.unlock()
            DispatchQueue.main.async { completion(.failure(.disconnected)) }
            return
        }
        writeJSON(envelope, to: curFd)
    }

    /// Serialize `dict` to JSON + `\n` and write to `sock` under `sendLock`.
    private func writeJSON(_ dict: [String: Any], to sock: Int32) {
        guard let body = try? JSONSerialization.data(withJSONObject: dict) else {
            log.error("broker: failed to serialize outbound JSON")
            return
        }
        var frame = body
        frame.append(0x0A)  // '\n'

        sendLock.lock(); defer { sendLock.unlock() }
        guard sock >= 0 else { return }
        frame.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var off = 0
            while off < raw.count {
                let n = Darwin.write(sock, base.advanced(by: off), raw.count - off)
                if n <= 0 { log.warning("broker write errno=\(errno, privacy: .public)"); break }
                off += n
            }
        }
    }

    // MARK: - Line reading

    /// Read one `\n`-terminated line from `sock`, byte-by-byte.
    /// Returns the line data WITHOUT the trailing `\n`, or nil on EOF/error/oversize.
    /// Used for the hello handshake; the main loop uses the buffered `readLoop`.
    func readOneLine(_ sock: Int32) -> Data? {
        var buf  = Data()
        var byte = [UInt8](repeating: 0, count: 1)
        while true {
            let n = Darwin.read(sock, &byte, 1)
            if n <= 0 { return nil }
            if byte[0] == 0x0A { return buf }       // found \n
            buf.append(byte[0])
            if buf.count > MAX_LINE_BYTES { return nil }  // safety cap
        }
    }

    /// Buffered NDJSON line reader. Blocks until the socket closes or errors.
    /// Splits incoming bytes on `\n` and dispatches each complete line.
    private func readLoop(_ sock: Int32) {
        var buf     = Data()
        let readSz  = 65_536
        var tmp     = Data(count: readSz)

        while true {
            let n = tmp.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(sock, base, readSz)
            }
            if n <= 0 { break }
            buf.append(tmp.prefix(n))

            // Extract all complete \n-terminated lines
            while let nlPos = buf.firstIndex(of: 0x0A) {
                let lineData = Data(buf[buf.startIndex ..< nlPos])
                buf = Data(buf[buf.index(after: nlPos)...])
                guard lineData.count <= MAX_LINE_BYTES else {
                    log.error("broker: line \(lineData.count) bytes > \(MAX_LINE_BYTES) cap — dropping")
                    continue
                }
                dispatch(lineData)
            }
        }
        log.info("broker read loop ended (fd=\(sock, privacy: .public))")
    }

    // MARK: - Dispatch

    private func dispatch(_ data: Data) {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let dir  = json["dir"] as? String,
            let t    = json["t"]   as? String
        else {
            log.warning("broker: malformed envelope (\(data.count, privacy: .public) bytes) — ignoring")
            return
        }
        let id = json["id"] as? String ?? ""
        log.debug("← broker \(dir, privacy: .public)/\(t, privacy: .public) id=\(id.prefix(8), privacy: .public)")

        switch dir {
        case "ack":   handleAck(id: id, json: json)
        case "event": handleEvent(t: t, json: json, raw: data)
        default:
            log.debug("broker: unknown dir '\(dir, privacy: .public)' — ignoring")
        }
    }

    // MARK: - Ack handling

    private func handleAck(id: String, json: [String: Any]) {
        pendingLock.lock()
        let cmd = pending.removeValue(forKey: id)
        pendingLock.unlock()

        guard let cmd else {
            log.debug("broker: orphan ack id=\(id.prefix(8), privacy: .public) — ignoring")
            return
        }
        cmd.timer.cancel()

        let dataDict = json["data"] as? [String: Any] ?? [:]
        if (dataDict["ok"] as? Bool) == true {
            DispatchQueue.main.async { cmd.completion(.success(dataDict)) }
        } else {
            let errDict = dataDict["error"]   as? [String: Any] ?? [:]
            let codeStr = errDict["code"]     as? String        ?? "internal"
            let message = errDict["message"]  as? String        ?? "unknown error"
            let code    = BrokerErrorCode(rawValue: codeStr)    ?? .internal
            // version_mismatch is terminal for this connection — log loudly
            if code == .versionMismatch {
                log.error("broker version_mismatch — mutations disabled until reconnect+update")
            }
            DispatchQueue.main.async { cmd.completion(.failure(.code(code, message: message))) }
        }
    }

    // MARK: - Event handling

    private func handleEvent(t: String, json: [String: Any], raw: Data) {
        let dataDict = json["data"] as? [String: Any] ?? [:]

        switch t {
        case "ping":
            // Liveness only — no action
            break

        case "snapshot":
            let jobsRaw = dataDict["jobs"] as? [[String: Any]] ?? []
            let jobs = decodeJobList(jobsRaw)
            log.debug("broker snapshot: \(jobs.count, privacy: .public) jobs")
            DispatchQueue.main.async { [weak self] in
                self?.events.send(.snapshot(jobs))
            }

        default:
            // State/activity/await/current_activity/quota events
            guard let jobId = dataDict["job"] as? String, !jobId.isEmpty else { return }

            // "queued" events carry the full job snapshot in their detail (the
            // broker embeds it so subscribers connected before this job existed
            // can construct a MotherJob without reconnecting). Try to decode it;
            // if that fails fall through to the normal stateChange path.
            if t == "queued", let job = decodeJob(dataDict) {
                log.debug("broker queued event decoded as new job \(jobId.prefix(8), privacy: .public)")
                DispatchQueue.main.async { [weak self] in
                    self?.events.send(.newJob(job))
                }
                return
            }

            if t == "progress_updated" {
                if let progress = decodeProgress(dataDict) {
                    DispatchQueue.main.async { [weak self] in
                        self?.events.send(.progress(jobId: jobId, progress))
                    }
                }
                return
            }
            if Self.isCrewEventKind(t) {
                DispatchQueue.main.async { [weak self] in
                    self?.events.send(.crewChanged(jobId: jobId))
                }
                return
            }

            let question     = dataDict["question"]      as? String
            let pausedReason = dataDict["paused_reason"] as? String
            let toState      = dataDict["to_state"]      as? String
            DispatchQueue.main.async { [weak self] in
                self?.events.send(.stateChange(
                    jobId:        jobId,
                    eventKind:    t,
                    question:     question,
                    pausedReason: pausedReason,
                    toState:      toState
                ))
            }
        }
    }

    // MARK: - Job decoding (snapshot jobs)

    private func decodeJob(_ dict: [String: Any]) -> MotherJob? {
        guard
            let data = try? JSONSerialization.data(withJSONObject: dict),
            let slim = try? decoder.decode(MotherJobSlim.self, from: data)
        else { return nil }
        return slim.toMotherJob()
    }

    /// A `progress_updated` event's `data` is the overlay itself plus `job` and `category`.
    private func decodeProgress(_ dict: [String: Any]) -> MotherProgress? {
        var overlay = dict
        overlay.removeValue(forKey: "job")
        overlay.removeValue(forKey: "category")
        guard let data = try? JSONSerialization.data(withJSONObject: overlay) else { return nil }
        return try? JSONDecoder().decode(MotherProgress.self, from: data)
    }

    // MARK: - Pending command cleanup

    private func failAllPending(with error: BrokerError) {
        pendingLock.lock()
        let all = pending
        pending.removeAll()
        pendingLock.unlock()
        for cmd in all.values {
            cmd.timer.cancel()
            DispatchQueue.main.async { cmd.completion(.failure(error)) }
        }
    }

    // MARK: - Utilities

    private func isoTimestamp() -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt.string(from: Date())
    }
}

// MARK: - MotherJobRefresher

/// Turns a burst of crew events into one `query.get` per job.
///
/// The first request for a job starts a debounce window; further requests inside it
/// add nothing. When the window closes the job is fetched (at most one fetch per job in
/// flight). A request that arrives while a fetch is in flight is remembered, and one
/// more fetch follows it. A failed fetch keeps the job as it was. Main queue only.
final class MotherJobRefresher {
    typealias Fetch = (_ job: String, _ done: @escaping (Result<MotherJob, BrokerError>) -> Void) -> Void

    private let debounce: TimeInterval
    private let fetch: Fetch
    private let apply: (MotherJob) -> Void
    private var pendingWindows: [String: DispatchWorkItem] = [:]
    private var inFlight = Set<String>()
    private var dirty = Set<String>()

    init(debounce: TimeInterval = 0.3, fetch: @escaping Fetch, apply: @escaping (MotherJob) -> Void) {
        self.debounce = debounce
        self.fetch = fetch
        self.apply = apply
    }

    func request(job: String) {
        if inFlight.contains(job) { dirty.insert(job); return }
        guard pendingWindows[job] == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.fire(job) }
        pendingWindows[job] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    /// Forget everything pending (the connection dropped; the next snapshot is the truth).
    func cancelAll() {
        pendingWindows.values.forEach { $0.cancel() }
        pendingWindows.removeAll()
        dirty.removeAll()
    }

    private func fire(_ job: String) {
        pendingWindows.removeValue(forKey: job)
        inFlight.insert(job)
        fetch(job) { [weak self] result in
            guard let self else { return }
            self.inFlight.remove(job)
            if case .success(let refreshed) = result { self.apply(refreshed) }
            if self.dirty.remove(job) != nil { self.request(job: job) }
        }
    }
}
