// NostromoKit — SharedPushState.swift
//
// What the app leaves in the App Group for the Notification Service Extension (W16): where the
// primary is, which hosts the operator classified `personal`, and which of those the operator
// switched details off for. Nothing else. In particular **no token**: the device token is read from
// the Keychain (shared by access group) and never written to the App Group container.
//
// All of it is fixed-vocabulary or the operator's own configuration (a host name, an address, a
// switch): no notification text is ever cached here. The extension reads it when the device has been
// unlocked once since boot (the UserDefaults file's default protection); before that it has neither
// this nor the Keychain token and delivers the contract notification unchanged.

import Foundation

public struct SharedPushState {
    /// The App Group both targets list in their entitlements: `group.<the app's bundle id>`.
    public static let defaultAppGroup = "group.com.hammer.nostromo.ios"

    /// Hosts and prefs are bounded on read: the extension has a small memory budget and the defaults
    /// file is shared with an app that could, in a bug, write more.
    static let maxHosts = 64
    static let maxHostNameLength = 64

    private let defaults: UserDefaults

    /// `defaults` is `UserDefaults(suiteName: <app group>)`; tests pass a throwaway suite.
    public init(defaults: UserDefaults) { self.defaults = defaults }

    private enum Key {
        static let host = "nostromo.push.primary.host"
        static let port = "nostromo.push.primary.port"
        static let classes = "nostromo.push.host-classes"
        static let prefs = "nostromo.push.enrichment-prefs"
    }

    // MARK: - Where the primary is

    public struct Address: Equatable, Sendable {
        public let host: String
        public let port: UInt16
        public init(host: String, port: UInt16) {
            self.host = host
            self.port = port
        }
    }

    public var address: Address? {
        get {
            guard let host = defaults.string(forKey: Key.host), !host.isEmpty, host.count <= 253 else { return nil }
            let port = defaults.integer(forKey: Key.port)
            guard (1...Int(UInt16.max)).contains(port) else { return nil }
            return Address(host: host, port: UInt16(port))
        }
        nonmutating set {
            if let newValue {
                defaults.set(newValue.host, forKey: Key.host)
                defaults.set(Int(newValue.port), forKey: Key.port)
            } else {
                defaults.removeObject(forKey: Key.host)
                defaults.removeObject(forKey: Key.port)
            }
        }
    }

    // MARK: - Host classes and switches

    /// The classification the primary last reported (`push_status`): host name to class.
    public var hostClasses: [String: HostClassWire] {
        get {
            guard let raw = defaults.dictionary(forKey: Key.classes) as? [String: String] else { return [:] }
            var out: [String: HostClassWire] = [:]
            for (host, word) in raw.prefix(Self.maxHosts) where host.count <= Self.maxHostNameLength {
                out[host] = HostClassWire(rawValue: word) ?? .work
            }
            return out
        }
        nonmutating set {
            defaults.set(newValue.mapValues(\.rawValue), forKey: Key.classes)
        }
    }

    public var enrichment: EnrichmentPrefs {
        get {
            guard let hosts = defaults.stringArray(forKey: Key.prefs) else { return EnrichmentPrefs() }
            return EnrichmentPrefs(disabledHosts: Set(hosts.prefix(Self.maxHosts)
                .filter { $0.count <= Self.maxHostNameLength }))
        }
        nonmutating set {
            defaults.set(newValue.disabledHosts.sorted(), forKey: Key.prefs)
        }
    }

    /// Forget everything: this phone is no longer paired.
    public func clear() {
        for key in [Key.host, Key.port, Key.classes, Key.prefs] { defaults.removeObject(forKey: key) }
    }
}
