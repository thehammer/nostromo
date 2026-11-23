import Foundation

// The MCP panel's wire (`session_mcp_v1`): the request, the answer and what the panel makes of it.
// Mirrors `ClientMsg::SessionMcp` / `ServerMsg::SessionMcpResult` in `src/ipc/protocol.rs`.
// Nothing here ever holds a server's configuration: the daemon sends names, states and counts only.

// MARK: - Request

/// Read or change a session's MCP servers. Answered with `ServerMsg.sessionMcpResult`; operator app
/// only; sent only to a daemon that advertised `session_mcp_v1`.
public struct ClientSessionMcp: Encodable, Equatable {
    let type_: String = "session_mcp"
    public let requestId: String
    public let tag: String
    /// `status`, `reconnect` or `toggle`.
    public let action: String
    public let server: String?
    public let enabled: Bool?

    public init(requestId: String, tag: String, action: String, server: String? = nil, enabled: Bool? = nil) {
        self.requestId = requestId
        self.tag = tag
        self.action = action
        self.server = server
        self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey {
        case type_ = "type", tag, action, server, enabled
        case requestId = "request_id"
    }
}

// MARK: - Answer

/// How an MCP request ended (`McpOutcome`). A newer daemon's word decodes as `.unknown`.
public enum McpOutcomeWire: Equatable {
    case ok
    case refused
    case timeout
    case unsupported
    case notRunning
    case rateLimited
    case invalid
    case unknown(String)

    public init(wire raw: String) {
        switch raw {
        case "ok": self = .ok
        case "refused": self = .refused
        case "timeout": self = .timeout
        case "unsupported": self = .unsupported
        case "not_running": self = .notRunning
        case "rate_limited": self = .rateLimited
        case "invalid": self = .invalid
        default: self = .unknown(raw)
        }
    }
}

extension McpOutcomeWire: Decodable {
    public init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self.init(wire: raw)
    }
}

/// What the CLI says about one server's state. Anything new is `.unknown` with its own word.
public enum McpStatusKind: Equatable {
    case connected
    case needsAuth
    case failed
    case disabled
    case pending
    case unknown(String)

    public init(raw: String) {
        switch raw {
        case "connected": self = .connected
        case "needs-auth": self = .needsAuth
        case "failed": self = .failed
        case "disabled": self = .disabled
        case "pending": self = .pending
        default: self = .unknown(raw)
        }
    }
}

/// One server in a result. Every field but `name` is optional; unknown fields are ignored.
public struct McpServerViewWire: Decodable, Equatable {
    public let name: String
    public let status: McpStatusKind
    public let scope: String?
    public let source: String?
    public let transport: String?
    public let toolCount: Int?
    public let error: String?
    /// `nostromo` only: whether the daemon's own bridge is up.
    public let nostromoBridge: Bool?

    public init(name: String, status: McpStatusKind = .unknown(""), scope: String? = nil, source: String? = nil,
                transport: String? = nil, toolCount: Int? = nil, error: String? = nil, nostromoBridge: Bool? = nil) {
        self.name = name
        self.status = status
        self.scope = scope
        self.source = source
        self.transport = transport
        self.toolCount = toolCount
        self.error = error
        self.nostromoBridge = nostromoBridge
    }

    enum CodingKeys: String, CodingKey {
        case name, status, scope, source, transport, error
        case toolCount = "tool_count"
        case nostromoBridge = "nostromo_bridge"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        status = McpStatusKind(raw: (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "")
        scope = try? c.decodeIfPresent(String.self, forKey: .scope)
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        transport = try? c.decodeIfPresent(String.self, forKey: .transport)
        toolCount = try? c.decodeIfPresent(Int.self, forKey: .toolCount)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        nostromoBridge = try? c.decodeIfPresent(Bool.self, forKey: .nostromoBridge)
    }
}

/// `session_mcp_result`: the answer to a `session_mcp` of this connection. Local clients only.
public struct SessionMcpResultWire: Decodable, Equatable {
    public let requestId: String
    public let tag: String
    public let action: String
    public let outcome: McpOutcomeWire
    public let message: String?
    /// The list after the action; nil when the answer carries none.
    public let servers: [McpServerViewWire]?

    public init(requestId: String, tag: String, action: String, outcome: McpOutcomeWire,
                message: String? = nil, servers: [McpServerViewWire]? = nil) {
        self.requestId = requestId
        self.tag = tag
        self.action = action
        self.outcome = outcome
        self.message = message
        self.servers = servers
    }

    enum CodingKeys: String, CodingKey {
        case tag, action, outcome, message, servers
        case requestId = "request_id"
    }

    private struct Lossy: Decodable {
        let value: McpServerViewWire?
        init(from decoder: Decoder) throws { value = try? McpServerViewWire(from: decoder) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try c.decode(String.self, forKey: .requestId)
        tag = try c.decode(String.self, forKey: .tag)
        action = (try? c.decodeIfPresent(String.self, forKey: .action)) ?? ""
        outcome = (try? c.decode(McpOutcomeWire.self, forKey: .outcome)) ?? .unknown("")
        message = try? c.decodeIfPresent(String.self, forKey: .message)
        // An entry without a name is skipped, not fatal.
        servers = (try? c.decodeIfPresent([Lossy].self, forKey: .servers))?.compactMap(\.value)
    }
}

// MARK: - What the panel makes of an answer

/// One server as a table row: the words, and which buttons it may have.
public struct McpRow: Equatable {
    public let name: String
    public let status: McpStatusKind
    public let statusWord: String
    public let scope: String
    public let transport: String
    /// "—" when the daemon had no count.
    public let toolCountText: String
    public let error: String?
    /// "Claude says connected · Nostromo bridge offline" for `nostromo` with its bridge down.
    public let bridgeNote: String?
    public let canReconnect: Bool
    public let canToggle: Bool
    /// "Disable" or "Enable".
    public let toggleTitle: String
    public let reconnectLabel: String
    public let toggleLabel: String
    /// What VoiceOver reads for the row.
    public let rowLabel: String

    public var isDisabled: Bool { status == .disabled }
}

/// What the panel shows.
public enum McpPanelPhase: Equatable {
    case loading
    case list([McpRow])
    /// "This session isn't running…": no table, no buttons.
    case notRunning
    /// The CLI is too old: the message, and no actions.
    case unsupported(String)
    /// A timeout, a refusal or anything unknown for a status read: the message, and Refresh.
    case failed(String)
}

public enum McpPanelModel {
    public static let nostromoServer = "nostromo"
    public static let footnote = "A local server that crashed can still read Connected until it is next used."
    public static let header = "MCP servers as Claude Code reports them"
    public static let notRunningMessage = "This session isn't running. Send it a message or restart it, then open /mcp again."

    public static func statusWord(_ status: McpStatusKind) -> String {
        switch status {
        case .connected: return "Connected"
        case .needsAuth: return "Needs sign-in"
        case .failed: return "Failed"
        case .disabled: return "Disabled"
        case .pending: return "Starting"
        case .unknown(let raw): return raw.isEmpty ? "Unknown" : raw
        }
    }

    public static func row(_ s: McpServerViewWire) -> McpRow {
        let word = statusWord(s.status)
        let disabled = s.status == .disabled
        let isNostromo = s.name == nostromoServer
        let bridgeNote = (isNostromo && s.nostromoBridge == false && s.status == .connected)
            ? "Claude says connected · Nostromo bridge offline" : nil
        let toggleTitle = disabled ? "Enable" : "Disable"
        let count = s.toolCount.map(String.init) ?? "—"
        var label = "\(s.name), \(bridgeNote ?? word)"
        if let t = s.transport { label += ", \(t)" }
        label += s.toolCount.map { ", \($0) tools" } ?? ""
        if let e = s.error { label += ", \(e)" }
        return McpRow(
            name: s.name, status: s.status, statusWord: word,
            scope: s.scope ?? "—", transport: s.transport ?? "—", toolCountText: count,
            error: s.error, bridgeNote: bridgeNote,
            canReconnect: !disabled,
            canToggle: !(isNostromo && !disabled),
            toggleTitle: toggleTitle,
            reconnectLabel: "Reconnect \(s.name)",
            toggleLabel: "\(toggleTitle) \(s.name)",
            rowLabel: label)
    }

    public static func rows(_ servers: [McpServerViewWire]) -> [McpRow] { servers.map(row) }

    /// The phase a result puts a panel in, or nil when the result only changes a row's message
    /// (an action that failed leaves the list as it was).
    public static func phase(for result: SessionMcpResultWire) -> McpPanelPhase? {
        switch result.outcome {
        case .notRunning: return .notRunning
        case .unsupported: return .unsupported(result.message ?? "this Claude Code is too old for MCP control")
        case .ok: return result.servers.map { .list(rows($0)) }
        default:
            // A failed status read has no list to keep: it is a panel state. A failed action is a row message.
            return result.action == "status" ? .failed(failureText(result)) : nil
        }
    }

    /// The message a row or the panel shows for a result that was not `ok` (or `ok` with a note).
    public static func failureText(_ result: SessionMcpResultWire) -> String {
        let detail = result.message.flatMap { $0.isEmpty ? nil : $0 }
        switch result.outcome {
        case .timeout: return detail ?? "Claude Code did not answer in time."
        case .refused: return detail ?? "Claude Code refused the request."
        case .rateLimited: return detail ?? "Too soon: try again in a few seconds."
        case .invalid: return detail ?? "That request is not allowed."
        case .unsupported: return detail ?? "this Claude Code is too old for MCP control"
        case .notRunning: return notRunningMessage
        case .unknown(let raw): return "The daemon answered something this app does not understand\(raw.isEmpty ? "" : " (\(raw))")."
        case .ok: return detail ?? ""
        }
    }

    /// The confirmation before a disable. `folder` is the focus's project path, or nil.
    public static func disableConfirmation(server: String, folder: String?) -> String {
        let place = folder.flatMap { $0.isEmpty ? nil : $0 } ?? "this session's folder"
        return "Disable \(server) for \(place)? Claude Code remembers this in ~/.claude.json for every session in that folder, including terminal sessions, until you enable it again."
    }
}
