// NostromoKit — FocusMeta.swift
//
// Daemon-served projection of a focus. Mirrors `FocusMeta` in
// `src/ipc/protocol.rs`.

import Foundation

/// Daemon-served projection of a focus.
/// Mirrors `FocusMeta` in `src/ipc/protocol.rs`.
public struct FocusMeta: Decodable, Identifiable, Equatable {
    public var id: String { tag }
    public let tag:            String
    public let displayName:    String
    public let agentName:      String
    public let projectName:    String?
    public let org:            String?
    public let isBuiltIn:      Bool
    public let sessionSummary: String?

    enum CodingKeys: String, CodingKey {
        case tag
        case displayName    = "display_name"
        case agentName      = "agent_name"
        case projectName    = "project_name"
        case org
        case isBuiltIn      = "is_built_in"
        case sessionSummary = "session_summary"
    }

    /// Org bucket for grouping; defaults like the Mac's `effectiveOrg`.
    public var effectiveOrg: String {
        if let org, !org.isEmpty { return org }
        return projectName == nil ? "Personal" : "Carefeed"
    }
}
