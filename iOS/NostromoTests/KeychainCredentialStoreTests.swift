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
