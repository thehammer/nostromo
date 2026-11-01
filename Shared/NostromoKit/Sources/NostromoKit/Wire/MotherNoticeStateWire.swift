// NostromoKit — MotherNoticeStateWire.swift
//
// The daemon's `mother_notice_state` frame (Mother focus v2, plan index §W): the global notice
// switch and, per focus, its mode, what is held and how many notice turns it had each day. Local
// peers only. Decoded tolerantly: an unknown reason or mode is kept as sent, and a focus entry
// that does not parse is skipped without costing the others.

import Foundation

/// A focus's notice mode.
public enum MotherNoticeMode: Equatable, Sendable {
    case wake, quiet, off
    /// A mode a newer daemon sent.
    case other(String)

    init(wire: String) {
        switch wire {
        case "wake":  self = .wake
        case "quiet": self = .quiet
        case "off":   self = .off
        default:      self = .other(wire)
        }
    }

    /// The wire word.
    public var rawValue: String {
        switch self {
        case .wake:           return "wake"
        case .quiet:          return "quiet"
        case .off:            return "off"
        case .other(let raw): return raw
        }
    }
}

/// `focuses[].held`.
public struct MotherNoticeHeld: Equatable, Sendable {
    public let count: Int
    public let reason: String
}

/// One day's notice turns for a focus: `day` is `YYYY-MM-DD`, local.
public struct MotherNoticeDayCount: Equatable, Sendable {
    public let day: String
    public let count: Int
}

/// `focuses[]`.
public struct MotherFocusNoticeState: Equatable, Sendable {
    public let tag: String
    public let mode: MotherNoticeMode
    public let held: MotherNoticeHeld?
    /// The loop guard is holding this focus's notices.
    public let chainHeld: Bool
    public let wakesByDay: [MotherNoticeDayCount]

    /// The focus is held by the loop guard or the cap, so its transcript shows the held bar.
    public var heldBarReason: MotherHeldBarReason? {
        if chainHeld { return .loopGuard }
        if held?.reason == "cap" { return .cap }
        return nil
    }
}

/// Why a focus shows the held bar.
public enum MotherHeldBarReason: Equatable, Sendable { case loopGuard, cap }

public struct MotherNoticeStateWire: Equatable, Sendable {
    /// The global switch: `false` means no session is told about its jobs.
    public let enabled: Bool
    public let focuses: [MotherFocusNoticeState]

    public init(enabled: Bool, focuses: [MotherFocusNoticeState]) {
        self.enabled = enabled
        self.focuses = focuses
    }

    /// The state for `tag`, nil when the daemon has none (the focus is on its default, Wake).
    public func focus(tag: String) -> MotherFocusNoticeState? { focuses.first { $0.tag == tag } }

    /// The mode shown for `tag`: Wake when the daemon has no entry.
    public func mode(forTag tag: String) -> MotherNoticeMode { focus(tag: tag)?.mode ?? .wake }

    /// Reads the frame's JSON object. Nil only when it is not an object with an `enabled` flag.
    public static func decode(from json: [String: Any]) -> MotherNoticeStateWire? {
        guard let enabled = json["enabled"] as? Bool else { return nil }
        var focuses: [MotherFocusNoticeState] = []
        for case let raw as [String: Any] in json["focuses"] as? [Any] ?? [] {
            guard let tag = raw["tag"] as? String, !tag.isEmpty else { continue }
            var held: MotherNoticeHeld?
            if let h = raw["held"] as? [String: Any], let reason = h["reason"] as? String {
                held = MotherNoticeHeld(count: (h["count"] as? Int) ?? 0, reason: reason)
            }
            var days: [MotherNoticeDayCount] = []
            for case let d as [String: Any] in raw["wakes_by_day"] as? [Any] ?? [] {
                if let day = d["day"] as? String, let count = d["count"] as? Int {
                    days.append(MotherNoticeDayCount(day: day, count: count))
                }
            }
            focuses.append(MotherFocusNoticeState(
                tag: tag,
                mode: MotherNoticeMode(wire: (raw["mode"] as? String) ?? "wake"),
                held: held,
                chainHeld: (raw["chain_held"] as? Bool) ?? false,
                wakesByDay: days))
        }
        return MotherNoticeStateWire(enabled: enabled, focuses: focuses)
    }
}

/// `mother_notice_settings_set` (operator app only): a focus's mode or the global switch.
public struct ClientMotherNoticeSettingsSet: Encodable, Equatable {
    public enum Scope: String, Encodable { case focus, global }
    let type_ = "mother_notice_settings_set"
    public let scope: Scope
    public let tag: String?
    public let mode: String?
    public let enabled: Bool?

    public init(scope: Scope, tag: String? = nil, mode: String? = nil, enabled: Bool? = nil) {
        self.scope = scope
        self.tag = tag
        self.mode = mode
        self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey {
        case type_ = "type", scope, tag, mode, enabled
    }
}

public extension MotherNoticeStateWire {
    /// The same state without `tag`'s entry.
    func removing(tag: String) -> MotherNoticeStateWire {
        MotherNoticeStateWire(enabled: enabled, focuses: focuses.filter { $0.tag != tag })
    }
}
