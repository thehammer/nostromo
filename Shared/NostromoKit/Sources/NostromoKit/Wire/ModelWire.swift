// NostromoKit — ModelWire.swift
//
// Model-switching frames (`ModelCatalog`, `SessionModelState`, `ModelDefaults`,
// `ModelRequestResult`) and the client requests that drive them. Mirrors the
// Rust types in `src/ipc/protocol.rs` ("model switching") as M1 shipped them.
//
// Every decoder here is lenient on purpose: a newer daemon may add keys or
// enum values, and a NETWORK peer is sent frames with `posture`,
// `last_request` and `ModelDefaults.declared` left out. Unknown keys are
// ignored, unknown enum strings decode to an `.unknown` case, and every field
// that can be absent is optional.

import Foundation

// MARK: - Catalogue

/// One model family the installed Claude CLI offers (`ModelFamilyWire`).
public struct ModelFamilyWire: Decodable, Equatable {
    /// What to ask for (`"opus"`).
    public let alias: String
    public let displayName: String
    /// The full model name the alias currently resolves to.
    public let resolved: String?
    /// Effort levels the model accepts (empty: no effort support).
    public let efforts: [String]
    /// Cost rank, cheapest lowest.
    public let rank: Int

    public init(alias: String, displayName: String, resolved: String?, efforts: [String], rank: Int) {
        self.alias = alias
        self.displayName = displayName
        self.resolved = resolved
        self.efforts = efforts
        self.rank = rank
    }

    enum CodingKeys: String, CodingKey {
        case alias, resolved, efforts, rank
        case displayName = "display_name"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alias = try c.decode(String.self, forKey: .alias)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? alias
        resolved = try c.decodeIfPresent(String.self, forKey: .resolved)
        efforts = try c.decodeIfPresent([String].self, forKey: .efforts) ?? []
        rank = try c.decodeIfPresent(Int.self, forKey: .rank) ?? Int.max
    }
}

// MARK: - Session model state

/// Where a recorded model came from (`ModelSource`). `focus` and
/// `agentDefault` were chosen by somebody; `agentDeclared` and `cliDefault`
/// merely observe what a session ran.
public enum ModelSourceWire: Equatable {
    case focus
    case agentDefault
    case agentDeclared
    case cliDefault
    case unknown(String)

    /// Was this model chosen (rather than merely observed)? An unknown source
    /// counts as observed, the conservative reading.
    public var isChosen: Bool {
        switch self {
        case .focus, .agentDefault: return true
        case .agentDeclared, .cliDefault, .unknown: return false
        }
    }

    public init(wire raw: String) {
        switch raw {
        case "focus": self = .focus
        case "agent_default": self = .agentDefault
        case "agent_declared": self = .agentDeclared
        case "cli_default": self = .cliDefault
        default: self = .unknown(raw)
        }
    }
}

extension ModelSourceWire: Decodable {
    public init(from decoder: Decoder) throws {
        self.init(wire: try decoder.singleValueContainer().decode(String.self))
    }
}

/// What a focus is recorded to run on (`RecordedModel`).
public struct RecordedModelWire: Decodable, Equatable {
    public let model: String
    /// Explicit effort level; `nil` is the model's default.
    public let effort: String?
    public let source: ModelSourceWire

    public init(model: String, effort: String? = nil, source: ModelSourceWire) {
        self.model = model
        self.effort = effort
        self.source = source
    }

    enum CodingKeys: String, CodingKey { case model, effort, source }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decode(String.self, forKey: .model)
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
        // Rust's serde default for a record with no `source` is `Focus`: somebody chose it.
        source = try c.decodeIfPresent(ModelSourceWire.self, forKey: .source) ?? .focus
    }
}

/// What a running session says it runs (`ReportedModel`).
public struct ReportedModelWire: Decodable, Equatable {
    /// Full model name, e.g. `claude-sonnet-5-5`.
    public let model: String
    /// The family alias it belongs to, when the daemon knows it.
    public let family: String?

    public init(model: String, family: String? = nil) {
        self.model = model
        self.family = family
    }
}

/// A switch not yet applied (`PendingModel`).
public struct PendingModelWire: Decodable, Equatable {
    public let model: String
    public let effort: String?

    public init(model: String, effort: String? = nil) {
        self.model = model
        self.effort = effort
    }
}

/// Where a focus's switch stands (`SwitchPhase`).
public enum SwitchPhaseWire: Equatable {
    case steady
    case waiting
    case applying

    public init(wire raw: String) {
        switch raw {
        case "waiting": self = .waiting
        case "applying": self = .applying
        default: self = .steady
        }
    }
}

extension SwitchPhaseWire: Decodable {
    public init(from decoder: Decoder) throws {
        self.init(wire: try decoder.singleValueContainer().decode(String.self))
    }
}

/// A warning attached to a candidate (`ModelWarning`): `target` is a family
/// alias (`"opus"`) or `"effort:<level>"`.
public struct ModelWarningWire: Decodable, Equatable {
    public let target: String
    public let text: String

    public init(target: String, text: String) {
        self.target = target
        self.text = text
    }
}

/// How a model request ended or stands (`ModelRequestStatus`).
///
/// `denied` and `expired` are agent upgrade requests the user refused or
/// nobody answered; they are plain declined states. A status this build does
/// not know decodes to `.unknown`, never throws.
public enum ModelRequestStatusWire: Equatable {
    case applied
    case pendingTurnEnd
    case unchanged
    case refused
    case failed
    case awaitingUser
    case denied
    case expired
    case unknown(String)

    public init(wire raw: String) {
        switch raw {
        case "applied": self = .applied
        case "pending_turn_end": self = .pendingTurnEnd
        case "unchanged": self = .unchanged
        case "refused": self = .refused
        case "failed": self = .failed
        case "awaiting_user": self = .awaitingUser
        case "denied": self = .denied
        case "expired": self = .expired
        default: self = .unknown(raw)
        }
    }
}

extension ModelRequestStatusWire: Decodable {
    public init(from decoder: Decoder) throws {
        self.init(wire: try decoder.singleValueContainer().decode(String.self))
    }
}

/// The most recent request to change a focus's model (`LastModelRequest`).
public struct LastModelRequestWire: Decodable, Equatable {
    /// `user`, `script` or `agent:<name>`.
    public let actor: String
    /// What was asked for, e.g. `opus` or `opus · effort high`.
    public let to: String
    public let status: ModelRequestStatusWire
    public let requestId: String?
    /// When the daemon recorded it (RFC 3339); tells two requests with no id apart.
    public let ts: String?

    public init(actor: String, to: String, status: ModelRequestStatusWire, requestId: String? = nil,
                ts: String? = nil) {
        self.actor = actor
        self.to = to
        self.status = status
        self.requestId = requestId
        self.ts = ts
    }

    enum CodingKeys: String, CodingKey {
        case actor, to, status, ts
        case requestId = "request_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        actor = try c.decodeIfPresent(String.self, forKey: .actor) ?? ""
        to = try c.decodeIfPresent(String.self, forKey: .to) ?? ""
        status = try c.decode(ModelRequestStatusWire.self, forKey: .status)
        requestId = try c.decodeIfPresent(String.self, forKey: .requestId)
        ts = try? c.decodeIfPresent(String.self, forKey: .ts)
    }
}

/// One focus's model state (`ServerMsg::SessionModelState`).
public struct SessionModelStateWire: Decodable, Equatable {
    public let tag: String
    /// What the focus is recorded to run on; `nil` when nothing was ever
    /// chosen and the session has not reported yet.
    public let recorded: RecordedModelWire?
    /// What the running session last reported.
    public let reported: ReportedModelWire?
    /// The effort the session last confirmed, else the recorded one.
    public let effectiveEffort: String?
    public let pending: PendingModelWire?
    public let phase: SwitchPhaseWire
    public let running: Bool
    public let warnings: [ModelWarningWire]
    /// Absent for network peers.
    public let lastRequest: LastModelRequestWire?
    /// Bishop's budget posture; absent for network peers.
    public let posture: String?

    public init(tag: String,
                recorded: RecordedModelWire? = nil,
                reported: ReportedModelWire? = nil,
                effectiveEffort: String? = nil,
                pending: PendingModelWire? = nil,
                phase: SwitchPhaseWire = .steady,
                running: Bool = false,
                warnings: [ModelWarningWire] = [],
                lastRequest: LastModelRequestWire? = nil,
                posture: String? = nil) {
        self.tag = tag
        self.recorded = recorded
        self.reported = reported
        self.effectiveEffort = effectiveEffort
        self.pending = pending
        self.phase = phase
        self.running = running
        self.warnings = warnings
        self.lastRequest = lastRequest
        self.posture = posture
    }

    enum CodingKeys: String, CodingKey {
        case tag, recorded, reported, pending, phase, running, warnings, posture
        case effectiveEffort = "effective_effort"
        case lastRequest = "last_request"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tag = try c.decode(String.self, forKey: .tag)
        recorded = try c.decodeIfPresent(RecordedModelWire.self, forKey: .recorded)
        reported = try c.decodeIfPresent(ReportedModelWire.self, forKey: .reported)
        effectiveEffort = try c.decodeIfPresent(String.self, forKey: .effectiveEffort)
        pending = try c.decodeIfPresent(PendingModelWire.self, forKey: .pending)
        phase = try c.decodeIfPresent(SwitchPhaseWire.self, forKey: .phase) ?? .steady
        running = try c.decodeIfPresent(Bool.self, forKey: .running) ?? false
        warnings = try c.decodeIfPresent([ModelWarningWire].self, forKey: .warnings) ?? []
        // A request record this build cannot read must not cost the whole state.
        lastRequest = try? c.decodeIfPresent(LastModelRequestWire.self, forKey: .lastRequest)
        posture = try c.decodeIfPresent(String.self, forKey: .posture)
    }
}

// MARK: - Defaults

/// A per-agent default model (`AgentModelDefault`).
public struct AgentModelDefaultWire: Decodable, Equatable {
    public let model: String
    public let effort: String?

    public init(model: String, effort: String? = nil) {
        self.model = model
        self.effort = effort
    }
}

// MARK: - Frame bodies

/// An element that decodes to `nil` instead of failing the collection around it.
private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// The body of `model_catalog`. A missing `stale` is false, and a family entry this build
/// cannot read is skipped: one bad entry must not cost the whole catalogue.
public struct ModelCatalogFrame: Decodable, Equatable {
    public let families: [ModelFamilyWire]
    public let stale: Bool
    public let fetchedAt: String?

    enum CodingKeys: String, CodingKey {
        case families, stale
        case fetchedAt = "fetched_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        families = (try c.decodeIfPresent([Lossy<ModelFamilyWire>].self, forKey: .families) ?? []).compactMap(\.value)
        stale = (try? c.decodeIfPresent(Bool.self, forKey: .stale)) ?? false
        fetchedAt = try? c.decodeIfPresent(String.self, forKey: .fetchedAt)
    }
}

/// The body of `model_defaults`. Entries this build cannot read are skipped; `declared` is
/// absent for network peers.
public struct ModelDefaultsFrame: Decodable, Equatable {
    public let defaults: [String: AgentModelDefaultWire]
    public let declared: [String: String]

    enum CodingKeys: String, CodingKey { case defaults, declared }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawDefaults = try c.decodeIfPresent([String: Lossy<AgentModelDefaultWire>].self, forKey: .defaults) ?? [:]
        defaults = rawDefaults.compactMapValues(\.value)
        let rawDeclared = try? c.decodeIfPresent([String: Lossy<String>].self, forKey: .declared)
        declared = (rawDeclared ?? [:]).compactMapValues(\.value)
    }
}

// MARK: - Client requests

/// An effort choice on the wire: `"default"` or an explicit level.
public enum ModelEffortChoice {
    public static let `default` = "default"
}

/// `ClientMsg::ModelCatalogRequest`.
public struct ClientModelCatalogRequest: Encodable {
    let type_ = "model_catalog_request"
    public init() {}
    enum CodingKeys: String, CodingKey { case type_ = "type" }
}

/// `ClientMsg::ModelCatalogRefresh` (refused over TCP).
public struct ClientModelCatalogRefresh: Encodable {
    let type_ = "model_catalog_refresh"
    public init() {}
    enum CodingKeys: String, CodingKey { case type_ = "type" }
}

/// `ClientMsg::ModelDefaultsRequest`.
public struct ClientModelDefaultsRequest: Encodable {
    let type_ = "model_defaults_request"
    public init() {}
    enum CodingKeys: String, CodingKey { case type_ = "type" }
}

/// `ClientMsg::SessionModelGet`.
public struct ClientSessionModelGet: Encodable {
    let type_ = "session_model_get"
    public let tag: String
    public init(tag: String) { self.tag = tag }
    enum CodingKeys: String, CodingKey { case type_ = "type", tag }
}

/// `ClientMsg::SessionModelSet` (refused over TCP). `nil` model or effort
/// means "keep the current value"; an effort of `"default"` resets it.
public struct ClientSessionModelSet: Encodable {
    let type_ = "session_model_set"
    public let tag: String
    public let model: String?
    public let effort: String?
    public let setAsAgentDefault: Bool
    public let requestId: String
    /// `"script"` for the app-control client; absent means the user.
    public let actor: String?

    public init(tag: String, model: String?, effort: String?, setAsAgentDefault: Bool = false,
                requestId: String, actor: String? = nil) {
        self.tag = tag
        self.model = model
        self.effort = effort
        self.setAsAgentDefault = setAsAgentDefault
        self.requestId = requestId
        self.actor = actor
    }

    enum CodingKeys: String, CodingKey {
        case type_ = "type", tag, model, effort, actor
        case setAsAgentDefault = "set_as_agent_default"
        case requestId = "request_id"
    }
}

/// `ClientMsg::ModelDefaultSet` (refused over TCP). `clear` removes the
/// agent's default.
public struct ClientModelDefaultSet: Encodable {
    let type_ = "model_default_set"
    public let agent: String
    public let model: String?
    public let effort: String?
    public let clear: Bool
    public let requestId: String

    public init(agent: String, model: String?, effort: String?, clear: Bool = false, requestId: String) {
        self.agent = agent
        self.model = model
        self.effort = effort
        self.clear = clear
        self.requestId = requestId
    }

    enum CodingKeys: String, CodingKey {
        case type_ = "type", agent, model, effort, clear
        case requestId = "request_id"
    }
}
