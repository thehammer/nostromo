// NostromoKit — HostScope.swift
//
// Which Macs' content the phone shows (W11 slice 2). One selection serves the Focuses, Perri and
// merged-queue views: All, Work, Personal, or one host by name. Pure value types, no UI.
//
//   - `HostScope.matches(host:egress:)` is the ONE place the filter is applied.
//   - The set of hosts is the primary (this server, `personal`: it is the operator's own) plus every
//     satellite the `Hosts` frame listed or that left last-known content behind. A host that has gone
//     keeps its entry: `connected` is false and `lastSeen` is what the primary last said.
//   - A persisted selection that names a host that is gone, or a kind with no host, is `.all`.

import Foundation

public enum HostScope: Equatable, Hashable, Sendable {
    case all
    case work
    case personal
    case host(String)

    /// Whether a row from `host` (whose egress is `egress`) is in this scope.
    public func matches(host: String, egress: HostEgress) -> Bool {
        switch self {
        case .all:               return true
        case .work:              return egress == .work
        case .personal:          return egress == .personal
        case .host(let name):    return host == name
        }
    }

    /// A single Mac is selected. The badge rule: a scope that is not this one always badges rows.
    public var isSingleHost: Bool {
        if case .host = self { return true }
        return false
    }

    // MARK: - Persistence

    /// `all`, `work`, `personal` or `host:<name>`: the one string kept in UserDefaults.
    public var storageValue: String {
        switch self {
        case .all:               return "all"
        case .work:              return "work"
        case .personal:          return "personal"
        case .host(let name):    return "host:\(name)"
        }
    }

    /// The scope a stored string names; anything unrecognised (or an empty host name) is `.all`.
    public init(storageValue: String?) {
        switch storageValue {
        case "work":        self = .work
        case "personal":    self = .personal
        case .some(let s) where s.hasPrefix("host:") && s.count > "host:".count:
            self = .host(String(s.dropFirst("host:".count)))
        default:            self = .all
        }
    }

    /// This scope if the hosts still support it, else `.all`: a named host that is gone, or a
    /// kind (`work` / `personal`) no host has, would show an empty screen with no way to see why.
    public func resolved(against hosts: [HostEntry]) -> HostScope {
        switch self {
        case .all:               return .all
        case .work:              return hosts.contains { $0.egress == .work } ? self : .all
        case .personal:          return hosts.contains { $0.egress == .personal } ? self : .all
        case .host(let name):    return hosts.contains { $0.name == name } ? self : .all
        }
    }
}

/// One Mac the phone knows of: the primary or a satellite.
public struct HostEntry: Equatable, Identifiable, Sendable {
    public let name: String
    public let egress: HostEgress
    public let isPrimary: Bool
    /// Listed by the latest `Hosts` frame while the phone's own link is live. Always true for the
    /// primary while the phone is connected to it.
    public let connected: Bool
    /// When the primary last heard from a satellite, as the last `Hosts` frame that listed it said.
    public let lastSeen: Date?

    public var id: String { isPrimary ? "" : name }

    public init(name: String, egress: HostEgress, isPrimary: Bool, connected: Bool, lastSeen: Date? = nil) {
        self.name = name
        self.egress = egress
        self.isPrimary = isPrimary
        self.connected = connected
        self.lastSeen = lastSeen
    }
}

/// What the scope picker offers, and what its choices are called.
public enum HostScopeOptions {

    /// All, then Work and Personal (each only when a host of that kind exists), then each host by
    /// name with the primary first.
    public static func options(for hosts: [HostEntry]) -> [HostScope] {
        var options: [HostScope] = [.all]
        if hosts.contains(where: { $0.egress == .work }) { options.append(.work) }
        if hosts.contains(where: { $0.egress == .personal }) { options.append(.personal) }
        options += ordered(hosts).map { .host($0.name) }
        return options
    }

    public static func label(for scope: HostScope) -> String {
        switch scope {
        case .all:               return "All"
        case .work:              return "Work"
        case .personal:          return "Personal"
        case .host(let name):    return name
        }
    }

    /// The spoken label for the picker option.
    public static func accessibilityLabel(for scope: HostScope) -> String {
        switch scope {
        case .all:               return "Show all Macs"
        case .work:              return "Show work Macs"
        case .personal:          return "Show personal Macs"
        case .host(let name):    return "Show \(name) only"
        }
    }

    /// The primary first, then the satellites by name.
    public static func ordered(_ hosts: [HostEntry]) -> [HostEntry] {
        hosts.sorted { a, b in
            if a.isPrimary != b.isPrimary { return a.isPrimary }
            return a.name < b.name
        }
    }

    /// The line under a host that is not connected: when it was last heard from.
    public static func lastKnownLabel(_ entry: HostEntry, now: Date = Date()) -> String? {
        guard !entry.connected else { return nil }
        guard let seen = entry.lastSeen else { return "Last known" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last seen \(formatter.localizedString(for: seen, relativeTo: now))"
    }
}

/// The satellites the phone has heard of, kept across a disconnect.
public struct HostRoster: Equatable, Sendable {
    public struct Record: Equatable, Sendable {
        public var egress: HostEgress
        public var connected: Bool
        public var lastSeen: Date?
    }

    public private(set) var records: [String: Record] = [:]

    public init() {}

    /// A `Hosts` frame lists the satellites connected NOW: those are connected, and any satellite
    /// known before and absent from it is not (it keeps its egress and its last `lastSeen`).
    public mutating func apply(_ list: [HostInfoWire]) {
        let listed = Set(list.map(\.name))
        for name in records.keys where !listed.contains(name) { records[name]?.connected = false }
        for host in list {
            records[host.name] = Record(egress: host.egress, connected: true,
                                        lastSeen: host.lastSeen ?? records[host.name]?.lastSeen)
        }
    }

    public mutating func removeAll() { records = [:] }

    /// Every Mac the phone can show rows for: the primary, each satellite on record, and any host
    /// that left content behind without ever being listed (treated as `work`, the strict reading).
    /// `linkLive` is false while the phone itself is not connected: nothing is "connected" then.
    public func entries(primaryName: String, hostsWithContent: Set<String>, linkLive: Bool) -> [HostEntry] {
        var entries = [HostEntry(name: primaryName, egress: .personal, isPrimary: true, connected: linkLive)]
        let names = Set(records.keys).union(hostsWithContent).subtracting([primaryName])
        for name in names.sorted() {
            let record = records[name]
            entries.append(HostEntry(name: name, egress: record?.egress ?? .work, isPrimary: false,
                                     connected: linkLive && (record?.connected ?? false),
                                     lastSeen: record?.lastSeen))
        }
        return entries
    }
}
