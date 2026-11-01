// NostromoKit — MotherJobAnnotation.swift
//
// Wire types for `MotherJob.nostromo`: what the daemon knows about a job that
// Mother does not (who queued it, how its focus is told). Mirrors `JobAnnotation`
// in `src/mother/origin.rs`.
//
// Additive and tolerant by contract (Mother focus v2, R15): iOS decodes the
// whole `mother_jobs` frame all-or-nothing, so nothing here may throw into the
// job. An origin kind this build has never heard of decodes as `.other`; a
// malformed `nostromo` object is `nil` on the job (see `MotherJob.init(from:)`).

import Foundation

/// What kind of origin a job has (`nostromo.origin.kind`).
public enum MotherOriginKind: Codable, Equatable, Sendable {
    /// A focus queued it and the daemon vouches for that.
    case focus
    /// A record claims a focus the daemon cannot vouch for.
    case unverified
    /// The user queued it in the app.
    case you
    /// The record makes no claim.
    case unknown
    /// A kind a newer daemon sent; the raw string is kept.
    case other(String)

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "focus":      self = .focus
        case "unverified": self = .unverified
        case "you":        self = .you
        case "unknown":    self = .unknown
        default:           self = .other(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public var rawValue: String {
        switch self {
        case .focus:           return "focus"
        case .unverified:      return "unverified"
        case .you:             return "you"
        case .unknown:         return "unknown"
        case .other(let raw):  return raw
        }
    }
}

/// `nostromo.origin`: who queued the job, as the daemon vouches for it.
public struct MotherOriginView: Codable, Equatable, Sendable {
    public let kind: MotherOriginKind
    /// The focus tag: the verified one, or the claimed one for `.unverified`.
    /// Absent for a network peer.
    public let focusTag: String?
    /// The focus's name when the origin was decided.
    public let nameSnapshot: String?
    /// The focus's current name, from the daemon's focus registry.
    public let focusName: String?
    /// `true` once the daemon has seen a registry push that lacks the tag;
    /// absent while no registry has been pushed.
    public let closed: Bool?
    /// The first 8 characters of the originating Claude session id.
    public let sessionPrefix: String?

    enum CodingKeys: String, CodingKey {
        case kind, closed
        case focusTag      = "focus_tag"
        case nameSnapshot  = "name_snapshot"
        case focusName     = "focus_name"
        case sessionPrefix = "session_prefix"
    }

    public init(
        kind: MotherOriginKind,
        focusTag: String? = nil,
        nameSnapshot: String? = nil,
        focusName: String? = nil,
        closed: Bool? = nil,
        sessionPrefix: String? = nil
    ) {
        self.kind = kind
        self.focusTag = focusTag
        self.nameSnapshot = nameSnapshot
        self.focusName = focusName
        self.closed = closed
        self.sessionPrefix = sessionPrefix
    }
}

/// `MotherJob.nostromo`.
public struct MotherJobAnnotation: Codable, Equatable, Sendable {
    public let origin: MotherOriginView?
    /// The job's own notify level (`wake`, `quiet` or `off`), if the enqueue gave one.
    public let notify: String?
    /// How the job's focus is told (`nostromo.notice`), decoded with `try?` so a malformed
    /// one can never cost the annotation.
    public let notice: MotherNoticeAnnotation?

    enum CodingKeys: String, CodingKey { case origin, notify, notice }

    public init(origin: MotherOriginView? = nil, notify: String? = nil, notice: MotherNoticeAnnotation? = nil) {
        self.origin = origin
        self.notify = notify
        self.notice = notice
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A malformed `origin` is a malformed annotation (it throws, and the job
        // reads `nostromo == nil`); a wrong-typed `notify` costs only itself, so
        // it can never drop a valid `origin`.
        origin = try c.decodeIfPresent(MotherOriginView.self, forKey: .origin)
        notify = (try? c.decodeIfPresent(String.self, forKey: .notify)) ?? nil
        notice = (try? c.decodeIfPresent(MotherNoticeAnnotation.self, forKey: .notice)) ?? nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(origin, forKey: .origin)
        try c.encodeIfPresent(notify, forKey: .notify)
        try c.encodeIfPresent(notice, forKey: .notice)
    }
}

/// Any JSON value, kept as it arrived (for wire fields this build does not read yet).
public enum MotherJSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([MotherJSON])
    case object([String: MotherJSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil()                                     { self = .null }
        else if let v = try? c.decode(Bool.self)             { self = .bool(v) }
        else if let v = try? c.decode(Double.self)           { self = .number(v) }
        else if let v = try? c.decode(String.self)           { self = .string(v) }
        else if let v = try? c.decode([MotherJSON].self)     { self = .array(v) }
        else                                                 { self = .object(try c.decode([String: MotherJSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:             try c.encodeNil()
        case .bool(let v):      try c.encode(v)
        case .number(let v):    try c.encode(v)
        case .string(let v):    try c.encode(v)
        case .array(let v):     try c.encode(v)
        case .object(let v):    try c.encode(v)
        }
    }
}

// MARK: - Notice

/// One of the daemon's notice statuses (`nostromo.notice.status`). A word this build does not know
/// reads as `.none`: nothing is shown for it.
public enum MotherNoticeStatus: String, Equatable, Sendable {
    case told, held, dropped
    case notSent = "not_sent"
    case none

    init(wire: String?) { self = wire.flatMap(Self.init(rawValue:)) ?? .none }
}

/// One entry of `nostromo.notice.history`.
public struct MotherNoticeHistoryEntry: Equatable, Sendable {
    /// The job states the notice named (`succeeded`, `pr_opened`, …), as sent.
    public let states: [String]
    public let status: MotherNoticeStatus
    public let reason: String?
    /// The notice woke the session (it was idle); otherwise it queued behind a turn.
    public let wake: Bool
    public let atMs: Int64?
}

/// `MotherJob.nostromo.notice` (Mother focus v2, plan index §W). Decoded tolerantly: a missing or
/// wrong-typed field costs only itself, and a malformed history entry is skipped.
public struct MotherNoticeAnnotation: Codable, Equatable, Sendable {
    public let status: MotherNoticeStatus
    /// Why a held, dropped or unsent notice is that way (a fixed word, kept as sent).
    public let reason: String?
    public let lastState: String?
    public let atMs: Int64?
    /// The newest deliveries, holds and drops, newest last.
    public let history: [MotherNoticeHistoryEntry]

    public init(status: MotherNoticeStatus = .none, reason: String? = nil, lastState: String? = nil,
                atMs: Int64? = nil, history: [MotherNoticeHistoryEntry] = []) {
        self.status = status
        self.reason = reason
        self.lastState = lastState
        self.atMs = atMs
        self.history = history
    }

    enum CodingKeys: String, CodingKey {
        case status, reason, history
        case lastState = "last_state"
        case atMs      = "at_ms"
    }

    private struct EntryWire: Decodable {
        let states: [String]?
        let status: String?
        let reason: String?
        let wake: Bool?
        let at_ms: Int64?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            states = (try? c.decodeIfPresent([String].self, forKey: .states)) ?? nil
            status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? nil
            reason = (try? c.decodeIfPresent(String.self, forKey: .reason)) ?? nil
            wake   = (try? c.decodeIfPresent(Bool.self, forKey: .wake)) ?? nil
            at_ms  = (try? c.decodeIfPresent(Int64.self, forKey: .at_ms)) ?? nil
        }
        enum Keys: String, CodingKey { case states, status, reason, wake, at_ms }
    }

    /// Lets one bad entry fall out of the array instead of failing it.
    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = MotherNoticeStatus(wire: (try? c.decodeIfPresent(String.self, forKey: .status)) ?? nil)
        reason = (try? c.decodeIfPresent(String.self, forKey: .reason)) ?? nil
        lastState = (try? c.decodeIfPresent(String.self, forKey: .lastState)) ?? nil
        atMs = (try? c.decodeIfPresent(Int64.self, forKey: .atMs)) ?? nil
        let entries = (try? c.decodeIfPresent([Lossy<EntryWire>].self, forKey: .history)) ?? nil
        history = (entries ?? []).compactMap { $0.value }.map {
            MotherNoticeHistoryEntry(states: $0.states ?? [], status: MotherNoticeStatus(wire: $0.status),
                                     reason: $0.reason, wake: $0.wake ?? false, atMs: $0.at_ms)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(status.rawValue, forKey: .status)
        try c.encodeIfPresent(reason, forKey: .reason)
        try c.encodeIfPresent(lastState, forKey: .lastState)
        try c.encodeIfPresent(atMs, forKey: .atMs)
    }
}
