import Foundation

// Codable mirrors of the terminal wire (`src/ipc/protocol.rs`, "terminal wire types" and the
// `terminal_*` frames). Byte fields are base64 on the wire and `[UInt8]` here. Nothing in this file
// imports SwiftTerm: it compiles into the test target too.
//
// Decoding is tolerant of values a newer daemon may add (an unknown `kind` or `status` decodes as
// `.unknown`) so one new word never drops a whole frame.

// MARK: - Shared records

enum TerminalKind: String, Codable, Equatable {
    case local, ecs, unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TerminalKind(rawValue: raw) ?? .unknown
    }
}

enum TerminalStatus: String, Codable, Equatable {
    case connecting, running, ended, unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TerminalStatus(rawValue: raw) ?? .unknown
    }
}

/// The remote shell a terminal is connected to (`ecs` only).
struct TerminalTarget: Codable, Equatable {
    let project: String
    let environment: String
    let service: String
    let shellType: String

    enum CodingKeys: String, CodingKey {
        case project, environment, service
        case shellType = "shell_type"
    }
}

/// Who asked for a terminal: `user` (the operator app) or `focus` (an agent) with the focus `tag`.
struct TerminalRequester: Codable, Equatable {
    let kind: String
    let tag: String?
}

/// The focus following a terminal (`TerminalInfo.follower`).
struct TerminalFollower: Codable, Equatable {
    let tag: String
    let paused: Bool
    let pauseReason: String?

    enum CodingKeys: String, CodingKey {
        case tag, paused
        case pauseReason = "pause_reason"
    }
}

/// A terminal's metadata. Never its bytes.
struct TerminalInfo: Codable, Equatable {
    let terminalId: String
    let tag: String
    let paneId: String
    let kind: TerminalKind
    let label: String
    let cwd: String?
    let target: TerminalTarget?
    let status: TerminalStatus
    let exitCode: Int?
    let endedReason: String?
    let cols: Int
    let rows: Int
    let requestedBy: TerminalRequester
    /// The `client_request_id` of the `terminal_open_local` that opened it.
    let openedByRequest: String?
    let follower: TerminalFollower?
    /// RFC 3339, set from the idle warning until a keystroke or keep-alive (a remote shell).
    let idleClosesAt: String?

    enum CodingKeys: String, CodingKey {
        case terminalId = "terminal_id", tag, paneId = "pane_id", kind, label, cwd, target, status
        case exitCode = "exit_code", endedReason = "ended_reason", cols, rows
        case requestedBy = "requested_by", openedByRequest = "opened_by_request", follower
        case idleClosesAt = "idle_closes_at"
    }
}

/// A terminal and its pane are gone. Flat on the wire (`terminal_closed`).
struct TerminalClosedInfo: Codable, Equatable {
    let terminalId: String
    let tag: String
    let paneId: String
    let label: String
    let kind: TerminalKind
    /// `exited`, `user_closed`, `daemon_stopped`, or a remote shell's reason code.
    let reason: String
    let exitCode: Int?
    let target: TerminalTarget?

    enum CodingKeys: String, CodingKey {
        case terminalId = "terminal_id", tag, paneId = "pane_id", label, kind, reason
        case exitCode = "exit_code", target
    }
}

// MARK: - Daemon -> client frames

/// `terminal_list`: every terminal the daemon knows, plus remote ones that closed while it was stopped.
struct TerminalListFrame: Decodable, Equatable {
    let terminals: [TerminalInfo]
    let closed: [TerminalClosedInfo]

    enum CodingKeys: String, CodingKey { case terminals, closed }

    init(terminals: [TerminalInfo], closed: [TerminalClosedInfo] = []) {
        self.terminals = terminals
        self.closed = closed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        terminals = try c.decode([TerminalInfo].self, forKey: .terminals)
        closed = try c.decodeIfPresent([TerminalClosedInfo].self, forKey: .closed) ?? []
    }
}

/// `terminal_state`: one terminal's metadata changed.
struct TerminalStateFrame: Decodable, Equatable {
    let terminal: TerminalInfo
}

/// `terminal_replay`: reset the view to `cols` x `rows` and feed `bytes`.
struct TerminalReplayFrame: Decodable, Equatable {
    let terminalId: String
    let cols: Int
    let rows: Int
    let bytes: [UInt8]

    enum CodingKeys: String, CodingKey { case terminalId = "terminal_id", cols, rows, bytes }

    init(terminalId: String, cols: Int, rows: Int, bytes: [UInt8]) {
        self.terminalId = terminalId
        self.cols = cols
        self.rows = rows
        self.bytes = bytes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        terminalId = try c.decode(String.self, forKey: .terminalId)
        cols = try c.decode(Int.self, forKey: .cols)
        rows = try c.decode(Int.self, forKey: .rows)
        bytes = try TerminalBase64.decode(c, forKey: .bytes)
    }
}

/// `terminal_output`: bytes from an attached terminal.
struct TerminalOutputFrame: Decodable, Equatable {
    let terminalId: String
    let bytes: [UInt8]

    enum CodingKeys: String, CodingKey { case terminalId = "terminal_id", bytes }

    init(terminalId: String, bytes: [UInt8]) {
        self.terminalId = terminalId
        self.bytes = bytes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        terminalId = try c.decode(String.self, forKey: .terminalId)
        bytes = try TerminalBase64.decode(c, forKey: .bytes)
    }
}

/// `terminal_refused`: a request was refused or failed; nothing changed. Never carries input bytes.
struct TerminalRefusedFrame: Decodable, Equatable {
    let op: String
    let terminalId: String?
    let code: String

    enum CodingKeys: String, CodingKey { case op, terminalId = "terminal_id", code }
}

enum TerminalBase64 {
    static func decode<K: CodingKey>(_ container: KeyedDecodingContainer<K>, forKey key: K) throws -> [UInt8] {
        let text = try container.decode(String.self, forKey: key)
        guard let data = Data(base64Encoded: text) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container,
                                                   debugDescription: "not valid base64")
        }
        return [UInt8](data)
    }
}

// MARK: - Client -> daemon frames

/// What a refused attempt was trying to do (`terminal_refusal_report.op`).
enum TerminalRefusedOp: String, Equatable {
    case input, close, restart, paste, resize, open
    /// The Connect button on a remote shell's confirm sheet.
    case connect
}

/// Every terminal frame this app sends. `encoded()` is the JSON body the daemon reads; the optional
/// fields the daemon marks `skip_serializing_if` are left out when nil.
enum TerminalClientMessage: Equatable {
    case openLocal(tag: String, relativeTo: String?, position: String?, cwd: String?, clientRequestId: String)
    case attach(terminalId: String)
    case detach(terminalId: String)
    /// `autoReply`: the terminal emulator's own answer (a cursor-position or device-attributes
    /// reply, a focus report), not a person's typing or paste. The daemon writes it to the shell but
    /// does not count it as activity for the remote idle rule. Omitted from the frame when false, so
    /// an older daemon sees what it always saw (and counts every input as a keystroke).
    case input(terminalId: String, bytes: [UInt8], autoReply: Bool = false)
    case resize(terminalId: String, cols: Int, rows: Int)
    case close(terminalId: String)
    case restart(terminalId: String)
    case refusalReport(terminalId: String?, op: TerminalRefusedOp, channel: String)

    var wireType: String {
        switch self {
        case .openLocal:     return "terminal_open_local"
        case .attach:        return "terminal_attach"
        case .detach:        return "terminal_detach"
        case .input:         return "terminal_input"
        case .resize:        return "terminal_resize"
        case .close:         return "terminal_close"
        case .restart:       return "terminal_restart"
        case .refusalReport: return "terminal_refusal_report"
        }
    }

    /// The frame body as a JSON object (what is encoded to the socket).
    var jsonObject: [String: Any] {
        var o: [String: Any] = ["type": wireType]
        switch self {
        case .openLocal(let tag, let relativeTo, let position, let cwd, let requestId):
            o["tag"] = tag
            o["client_request_id"] = requestId
            if let relativeTo { o["relative_to"] = relativeTo }
            if let position { o["position"] = position }
            if let cwd { o["cwd"] = cwd }
        case .attach(let id), .detach(let id), .close(let id), .restart(let id):
            o["terminal_id"] = id
        case .input(let id, let bytes, let autoReply):
            o["terminal_id"] = id
            o["bytes"] = Data(bytes).base64EncodedString()
            if autoReply { o["auto_reply"] = true }
        case .resize(let id, let cols, let rows):
            o["terminal_id"] = id
            o["cols"] = cols
            o["rows"] = rows
        case .refusalReport(let id, let op, let channel):
            if let id { o["terminal_id"] = id }
            o["op"] = op.rawValue
            o["channel"] = channel
        }
        return o
    }

    func encoded() -> Data? {
        try? JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys])
    }
}
