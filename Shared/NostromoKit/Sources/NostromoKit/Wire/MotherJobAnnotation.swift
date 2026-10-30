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
    /// The notice state (a later slice gives it a shape); kept as opaque JSON and
    /// decoded with `try?` so it can never cost the annotation.
    public let notice: MotherJSON?

    enum CodingKeys: String, CodingKey { case origin, notify, notice }

    public init(origin: MotherOriginView? = nil, notify: String? = nil, notice: MotherJSON? = nil) {
        self.origin = origin
        self.notify = notify
        self.notice = notice
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Each key on its own: a wrong-typed `notify` must not cost a valid
        // `origin` (nor the other way round).
        origin = (try? c.decodeIfPresent(MotherOriginView.self, forKey: .origin)) ?? nil
        notify = (try? c.decodeIfPresent(String.self, forKey: .notify)) ?? nil
        notice = (try? c.decodeIfPresent(MotherJSON.self, forKey: .notice)) ?? nil
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
