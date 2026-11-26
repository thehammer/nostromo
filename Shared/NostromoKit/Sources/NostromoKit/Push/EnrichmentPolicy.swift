// NostromoKit — EnrichmentPolicy.swift
//
// Whether the Notification Service Extension may ask the primary for a notification's detail line
// (W16). The daemon enforces the real rule (it returns no text for a work host, PHI, a sensitive tag
// or a work owner); this is the phone's own first gate, so a notification that can never be enriched
// never costs a connection. The classes are the operator's own, from `push_status` (the same ones
// the settings screen shows), kept in the App Group for the extension.
//
//   - a replacement (`resolved`, W13's "no longer needs you") and a Summary: never;
//   - a host that is not known to be `personal` (work, or not in the last `push_status`): never,
//     an unknown host counts as work;
//   - a `personal` host: on by default, a per-host switch turns it off.
//
// Decisions are enriched like the other kinds: read-only, ending " · answer on your Mac" (S8).

import Foundation

/// The operator's per-host "Show full details" switches. Only a host switched off is stored.
public struct EnrichmentPrefs: Codable, Equatable, Sendable {
    public var disabledHosts: Set<String>

    public init(disabledHosts: Set<String> = []) { self.disabledHosts = disabledHosts }

    public func isEnabled(host: String) -> Bool { !disabledHosts.contains(host) }

    public mutating func set(host: String, enabled: Bool) {
        if enabled { disabledHosts.remove(host) } else { disabledHosts.insert(host) }
    }
}

public enum EnrichmentPolicy {
    /// Should the extension fetch detail for the push described by `payload`?
    /// `hostClasses` is the last classification the primary reported, by host name.
    public static func shouldEnrich(payload: PushPayload,
                                    hostClasses: [String: HostClassWire],
                                    prefs: EnrichmentPrefs) -> Bool {
        if payload.resolved { return false }
        switch payload.kind {
        case .summary: return false
        case .mother, .decision, .review: break
        }
        guard hostClasses[payload.host] == .personal else { return false }
        return prefs.isEnabled(host: payload.host)
    }
}
