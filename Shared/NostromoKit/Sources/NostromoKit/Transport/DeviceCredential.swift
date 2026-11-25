// NostromoKit — DeviceCredential.swift
//
// The phone's pairing: the token the server gave it and what it needs to show and use it. The token
// lives only in the Keychain (`…ThisDeviceOnly`, so it never reaches a backup or another device) and
// is never written to UserDefaults, the content cache, a log or a view (W11-5). The item is NOT keyed
// by address, so changing the server address keeps the pairing (PRD-AC33).

import Foundation
import Security

public struct DeviceCredential: Codable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
                                CustomReflectable {
    public let token: String
    public let deviceId: String
    public let serverId: String
    public let name: String

    public init(token: String, deviceId: String, serverId: String, name: String) {
        self.token = token
        self.deviceId = deviceId
        self.serverId = serverId
        self.name = name
    }

    // Never prints the token.
    public var description: String { "DeviceCredential(device: \(deviceId), name: \(name), token: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["deviceId": deviceId, "serverId": serverId, "name": name])
    }
}

/// Where the credential lives. The app uses the Keychain; tests inject the in-memory store.
public protocol DeviceCredentialStore: AnyObject {
    func load() -> DeviceCredential?
    func save(_ credential: DeviceCredential) throws
    func clear() throws
}

public struct DeviceCredentialError: Error, Equatable {
    public let status: OSStatus
}

/// The Keychain store: one generic-password item, a fixed service and account.
public final class KeychainDeviceCredentialStore: DeviceCredentialStore {
    public static let service = "com.hammer.nostromo.device"
    public static let account = "device-credential"

    private let service: String
    private let account: String
    private let accessGroup: String?

    /// `service` and `account` are overridable only so a test can use a throwaway item.
    public init(service: String = KeychainDeviceCredentialStore.service,
                account: String = KeychainDeviceCredentialStore.account,
                accessGroup: String? = nil) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public func load() -> DeviceCredential? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(DeviceCredential.self, from: data)
    }

    public func save(_ credential: DeviceCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(baseQuery() as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery()
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw DeviceCredentialError(status: status) }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeviceCredentialError(status: status)
        }
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}

/// An in-memory store for tests and previews.
public final class InMemoryDeviceCredentialStore: DeviceCredentialStore {
    private var credential: DeviceCredential?

    public init(_ credential: DeviceCredential? = nil) { self.credential = credential }

    public func load() -> DeviceCredential? { credential }
    public func save(_ credential: DeviceCredential) throws { self.credential = credential }
    public func clear() throws { credential = nil }
}
