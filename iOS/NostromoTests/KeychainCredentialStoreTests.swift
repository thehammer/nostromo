// L5: needs the iOS Keychain in the app process: the device credential's item attributes
// (accessible only after first unlock, this device only), its round trip through SecItem, and that
// clearing it (what a revoke does) removes it; the token must never be found in UserDefaults.

import XCTest
import Security
import NostromoKit
@testable import Nostromo

final class KeychainCredentialStoreTests: XCTestCase {

    private let service = "com.hammer.nostromo.device.l5-test"
    private let account = "device-credential-l5-test"
    private var store: KeychainDeviceCredentialStore!

    override func setUp() {
        super.setUp()
        store = KeychainDeviceCredentialStore(service: service, account: account)
        try? store.clear()
    }

    override func tearDown() {
        try? store.clear()
        super.tearDown()
    }

    private let credential = DeviceCredential(token: "tok-l5-secret-value", deviceId: "dev-1",
                                              serverId: "srv-1", name: "iPhone")

    func testCredentialRoundTripsThroughTheKeychain() throws {
        XCTAssertNil(store.load())
        try store.save(credential)
        XCTAssertEqual(store.load(), credential)
        let replacement = DeviceCredential(token: "tok-2", deviceId: "dev-2", serverId: "srv-1", name: "iPhone 2")
        try store.save(replacement)
        XCTAssertEqual(store.load(), replacement, "saving again replaces the one item")
    }

    func testTheItemIsThisDeviceOnlyAndAvailableAfterFirstUnlock() throws {
        try store.save(credential)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &out), errSecSuccess)
        let attributes = try XCTUnwrap(out as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    /// The item lands in the app's own keychain access group (the one in `Nostromo.entitlements`,
    /// `$(AppIdentifierPrefix)com.hammer.nostromo.ios`), not in a shared group another app could read.
    /// The team prefix is whatever the signing identity provides (empty for ad hoc), so the check is
    /// on the suffix.
    func testTheItemIsInTheAppsOwnAccessGroup() throws {
        try store.save(credential)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &out), errSecSuccess)
        let attributes = try XCTUnwrap(out as? [String: Any])
        let group = try XCTUnwrap(attributes[kSecAttrAccessGroup as String] as? String, "the item has no access group")
        XCTAssertTrue(group.hasSuffix("com.hammer.nostromo.ios"), "unexpected access group: \(group)")
        XCTAssertFalse(group.contains("apple"), "the item must not be in an Apple shared group: \(group)")
    }

    func testClearRemovesTheItemAsARevokeDoes() throws {
        try store.save(credential)
        try store.clear()
        XCTAssertNil(store.load())
        XCTAssertNoThrow(try store.clear(), "clearing an absent item is not an error")
    }

    func testTheTokenIsNeverInUserDefaults() throws {
        try store.save(credential)
        for (key, value) in UserDefaults.standard.dictionaryRepresentation() {
            XCTAssertFalse("\(key)=\(value)".contains(credential.token), "token found in UserDefaults under \(key)")
        }
    }
}
