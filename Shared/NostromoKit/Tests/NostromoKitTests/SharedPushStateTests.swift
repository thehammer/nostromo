// SharedPushStateTests.swift
//
// What the app leaves in the App Group for the Notification Service Extension (W16): where the primary
// is, which hosts are `personal`, which of those the operator switched details off for. Nothing else.
// In particular there is NO token in it: the device token stays in the Keychain. The extension reads
// it with a small memory budget and the file is written by another process, so reads are bounded.
//
// Each test uses a throwaway `UserDefaults` suite, removed in `tearDown`.

import XCTest
@testable import NostromoKit

final class SharedPushStateTests: XCTestCase {

    private var suiteName = ""
    private var defaults = UserDefaults.standard
    private var state: SharedPushState!

    override func setUp() {
        super.setUp()
        suiteName = UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
        state = SharedPushState(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// The keys this suite holds, and only this suite (not the global domain).
    private var storedKeys: [String] { Array((defaults.persistentDomain(forName: suiteName) ?? [:]).keys) }

    // MARK: - The App Group

    func testTheAppGroupIsTheAppsBundleIdPrefixedWithGroup() {
        XCTAssertEqual(SharedPushState.defaultAppGroup, "group.com.hammer.nostromo.ios")
    }

    // MARK: - Where the primary is

    func testTheAddressRoundTrips() {
        XCTAssertNil(state.address, "nothing is stored yet")
        state.address = SharedPushState.Address(host: "100.64.0.1", port: 7777)
        XCTAssertEqual(state.address, SharedPushState.Address(host: "100.64.0.1", port: 7777))
        XCTAssertEqual(SharedPushState(defaults: defaults).address?.port, 7777, "another reader sees it")
    }

    func testSettingTheAddressToNilForgetsIt() {
        state.address = SharedPushState.Address(host: "100.64.0.1", port: 7777)
        state.address = nil
        XCTAssertNil(state.address)
    }

    func testAnAddressWithPortZeroIsNotAnAddress() {
        state.address = SharedPushState.Address(host: "100.64.0.1", port: 0)
        XCTAssertNil(state.address)
    }

    func testAnAddressWithAnEmptyHostIsNotAnAddress() {
        state.address = SharedPushState.Address(host: "", port: 7777)
        XCTAssertNil(state.address)
    }

    func testAnImplausiblyLongHostIsNotAnAddress() {
        state.address = SharedPushState.Address(host: String(repeating: "a", count: 300), port: 7777)
        XCTAssertNil(state.address)
    }

    // MARK: - Host classes

    func testHostClassesRoundTrip() {
        state.hostClasses = ["sendai": .personal, "kobe": .work]
        XCTAssertEqual(state.hostClasses, ["sendai": .personal, "kobe": .work])
        state.hostClasses = [:]
        XCTAssertEqual(state.hostClasses, [:])
    }

    func testMoreThanSixtyFourHostsAreTruncatedOnRead() {
        var many: [String: HostClassWire] = [:]
        for index in 0..<100 { many["host-\(index)"] = .personal }
        state.hostClasses = many
        let read = state.hostClasses
        XCTAssertEqual(read.count, 64)
        for (host, hostClass) in read {
            XCTAssertEqual(many[host], hostClass, "what is kept is what was written")
        }
    }

    func testOverLongHostNamesAreDroppedOnRead() {
        let long = String(repeating: "h", count: 200)
        state.hostClasses = ["sendai": .personal, long: .personal]
        XCTAssertEqual(state.hostClasses, ["sendai": .personal])
    }

    // MARK: - The switches

    func testTheEnrichmentSwitchesRoundTrip() {
        XCTAssertEqual(state.enrichment, EnrichmentPrefs(), "nothing switched off by default")
        state.enrichment = EnrichmentPrefs(disabledHosts: ["sendai", "tokyo"])
        XCTAssertEqual(state.enrichment.disabledHosts, ["sendai", "tokyo"])
        XCTAssertFalse(state.enrichment.isEnabled(host: "sendai"))
        XCTAssertTrue(state.enrichment.isEnabled(host: "kobe"))
    }

    func testMoreThanSixtyFourSwitchedOffHostsAreTruncatedOnRead() {
        let many = Set((0..<100).map { "host-\($0)" })
        state.enrichment = EnrichmentPrefs(disabledHosts: many)
        let read = state.enrichment.disabledHosts
        XCTAssertEqual(read.count, 64)
        XCTAssertTrue(read.isSubset(of: many))
    }

    func testOverLongSwitchedOffHostNamesAreDroppedOnRead() {
        let long = String(repeating: "h", count: 200)
        state.enrichment = EnrichmentPrefs(disabledHosts: ["sendai", long])
        XCTAssertEqual(state.enrichment.disabledHosts, ["sendai"])
    }

    // MARK: - Forgetting, and never a token

    func testClearRemovesEverything() {
        state.address = SharedPushState.Address(host: "100.64.0.1", port: 7777)
        state.hostClasses = ["sendai": .personal]
        state.enrichment = EnrichmentPrefs(disabledHosts: ["sendai"])
        XCTAssertFalse(storedKeys.isEmpty, "the test has something to clear")

        state.clear()

        XCTAssertNil(state.address)
        XCTAssertEqual(state.hostClasses, [:])
        XCTAssertEqual(state.enrichment, EnrichmentPrefs())
        XCTAssertEqual(storedKeys, [], "nothing at all is left in the group's defaults")
    }

    func testNoKeyInTheDefaultsEverMentionsAToken() {
        state.address = SharedPushState.Address(host: "100.64.0.1", port: 7777)
        state.hostClasses = ["sendai": .personal, "kobe": .work]
        state.enrichment = EnrichmentPrefs(disabledHosts: ["kobe"])
        XCTAssertFalse(storedKeys.isEmpty, "the check must look at something")
        for key in storedKeys {
            XCTAssertFalse(key.lowercased().contains("token"), "\(key) must not exist")
        }
    }
}
