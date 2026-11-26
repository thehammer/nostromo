// NostromoKit — DeviceCredentialTests.swift
//
// The phone's pairing record and the in-memory store the tests and previews use. The real Keychain
// store is deliberately not exercised here: it needs an iOS-hosted test (L5).
//
// Guarded: the token never prints (W11-5), and the credential is not tied to a server address, so
// changing the address keeps the pairing (PRD-AC33).

import XCTest
@testable import NostromoKit

final class DeviceCredentialTests: XCTestCase {

    private let secret = "s3cr3t-Zm9vYmFy-TOKEN-value"

    private func credential(token: String? = nil, name: String = "Hammer's iPhone") -> DeviceCredential {
        DeviceCredential(token: token ?? secret, deviceId: "dev-1", serverId: "srv-1", name: name)
    }

    // MARK: - InMemoryDeviceCredentialStore

    func testAnEmptyStoreLoadsNothing() {
        XCTAssertNil(InMemoryDeviceCredentialStore().load())
    }

    func testASavedCredentialIsLoadedBack() throws {
        let store = InMemoryDeviceCredentialStore()
        try store.save(credential())
        XCTAssertEqual(store.load(), credential())
    }

    func testSavingAgainOverwritesTheCredential() throws {
        let store = InMemoryDeviceCredentialStore()
        try store.save(credential(token: "first-token"))
        try store.save(credential(token: "second-token", name: "Renamed"))
        XCTAssertEqual(store.load()?.token, "second-token")
        XCTAssertEqual(store.load()?.name, "Renamed")
    }

    func testClearingRemovesTheCredentialAndClearingAnEmptyStoreIsFine() throws {
        let store = InMemoryDeviceCredentialStore(credential())
        XCTAssertNotNil(store.load())
        try store.clear()
        XCTAssertNil(store.load())
        XCTAssertNoThrow(try store.clear())
    }

    // MARK: - The token never prints

    func testTheTokenNeverAppearsInAnyPrintedForm() {
        let value = credential()
        var dumped = ""
        dump(value, to: &dumped)
        let printed = ["\(value)", String(describing: value), String(reflecting: value), value.description,
                       value.debugDescription, dumped]
        for text in printed {
            XCTAssertFalse(text.contains(secret), "The token leaked into: \(text)")
        }
    }

    func testThePrintedFormStillIdentifiesTheDevice() {
        XCTAssertTrue(credential().description.contains("dev-1"))
    }

    // MARK: - Codable

    func testACredentialSurvivesAJSONRoundTrip() throws {
        let original = credential()
        let decoded = try JSONDecoder().decode(DeviceCredential.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.token, secret)
    }

    // MARK: - Not keyed by address

    func testTheCredentialCarriesNoServerAddress() throws {
        let data = try JSONEncoder().encode(credential())
        let keys = Set(try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys.map { $0.lowercased() })
        XCTAssertTrue(keys.isDisjoint(with: ["host", "port", "address", "url", "hostname"]),
                      "A credential tied to an address would not survive an address change: \(keys)")
    }

    // MARK: - Resuming at launch (an orphaned credential is discarded)

    func testACredentialWithNoSavedAddressIsAnOrphanAndIsDeletedFromTheStore() throws {
        let store = InMemoryDeviceCredentialStore(credential())

        XCTAssertNil(store.resumeOrDiscardOrphan(address: nil))
        XCTAssertNil(store.load(), "An orphan must not stay in the Keychain for a pairing link to ask for")
    }

    func testACredentialWithAnEmptySavedAddressIsAnOrphanAndIsDeletedFromTheStore() throws {
        let store = InMemoryDeviceCredentialStore(credential())

        XCTAssertNil(store.resumeOrDiscardOrphan(address: ""))
        XCTAssertNil(store.load())
    }

    func testACredentialWithASavedAddressResumesWithBothAndIsKept() throws {
        let store = InMemoryDeviceCredentialStore(credential())

        let resumed = try XCTUnwrap(store.resumeOrDiscardOrphan(address: "10.0.0.5"))

        XCTAssertEqual(resumed.credential, credential())
        XCTAssertEqual(resumed.address, "10.0.0.5")
        XCTAssertEqual(store.load(), credential(), "A real pairing is left alone")
    }

    func testResumingWithNoCredentialIsNilWhateverTheAddress() throws {
        let store = InMemoryDeviceCredentialStore()

        XCTAssertNil(store.resumeOrDiscardOrphan(address: "10.0.0.5"))
        XCTAssertNil(store.resumeOrDiscardOrphan(address: nil))
        XCTAssertNil(store.load())
    }
}
