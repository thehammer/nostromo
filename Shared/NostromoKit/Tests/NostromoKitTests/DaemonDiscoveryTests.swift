// NostromoKit — DaemonDiscoveryTests.swift
//
// Unit tests for DaemonDiscovery helpers and NetworkClient.isIPLiteral.
// These cover pure-logic functions that are testable without a running daemon
// or an active NWBrowser session.

import XCTest
import Network
@testable import NostromoKit

final class DaemonDiscoveryTests: XCTestCase {

    // MARK: - isIPLiteral

    func testIPv4LiteralIsDetected() async {
        let client = await NetworkClient(host: "192.168.1.5", port: 47100)
        let result = await client.isIPLiteral("192.168.1.5")
        XCTAssertTrue(result, "192.168.1.5 should be classified as an IP literal")
    }

    func testLoopbackIPv4IsDetected() async {
        let client = await NetworkClient(host: "127.0.0.1", port: 47100)
        let result = await client.isIPLiteral("127.0.0.1")
        XCTAssertTrue(result, "127.0.0.1 should be classified as an IP literal")
    }

    func testIPv6LoopbackIsDetected() async {
        let client = await NetworkClient(host: "::1", port: 47100)
        let result = await client.isIPLiteral("::1")
        XCTAssertTrue(result, "::1 should be classified as an IPv6 literal")
    }

    func testLocalHostnameIsNotIPLiteral() async {
        let client = await NetworkClient(host: "hammers-macbook-pro.local", port: 47100)
        let result = await client.isIPLiteral("hammers-macbook-pro.local")
        XCTAssertFalse(result, "hammers-macbook-pro.local is a .local name, not an IP literal")
    }

    func testArbitraryHostnameIsNotIPLiteral() async {
        let client = await NetworkClient(host: "mymac.local", port: 47100)
        let result = await client.isIPLiteral("mymac")
        XCTAssertFalse(result, "A bare hostname with no dots is not an IP literal")
    }

    func testDotLocalSuffixIsNotIPLiteral() async {
        let client = await NetworkClient(host: "nostromd.local", port: 47100)
        let result = await client.isIPLiteral("nostromd.local")
        XCTAssertFalse(result, ".local suffix should be fast-pathed as non-IP")
    }

    // MARK: - DiscoveredDaemon host-name derivation

    func testDeriveHostNameFromPlainServiceName() {
        let hostName = DiscoveredDaemon.deriveHostName(from: "hammers-macbook-pro")
        XCTAssertEqual(hostName, "hammers-macbook-pro.local")
    }

    func testDeriveHostNameStripsExistingLocalSuffix() {
        // Should not produce double .local
        let hostName = DiscoveredDaemon.deriveHostName(from: "hammers-macbook-pro.local")
        XCTAssertEqual(hostName, "hammers-macbook-pro.local")
    }

    func testDeriveHostNameWithHyphens() {
        let hostName = DiscoveredDaemon.deriveHostName(from: "my-work-laptop")
        XCTAssertEqual(hostName, "my-work-laptop.local")
    }

    // MARK: - DiscoveredDaemon deduplication via from(endpoint:)

    func testFromEndpointReturnsNilForHostPort() {
        // .hostPort endpoints are not service results
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("192.168.1.1"),
            port: NWEndpoint.Port(rawValue: 47100)!
        )
        let result = DiscoveredDaemon.from(endpoint: endpoint)
        XCTAssertNil(result, ".hostPort endpoint should not produce a DiscoveredDaemon")
    }

    func testFromEndpointExtractsServiceName() {
        let endpoint = NWEndpoint.service(
            name:      "hammers-macbook-pro",
            type:      "_nostromo._tcp",
            domain:    "local.",
            interface: nil
        )
        let daemon = DiscoveredDaemon.from(endpoint: endpoint)
        XCTAssertNotNil(daemon)
        XCTAssertEqual(daemon?.name, "hammers-macbook-pro")
        XCTAssertEqual(daemon?.hostName, "hammers-macbook-pro.local")
        XCTAssertEqual(daemon?.id, "hammers-macbook-pro")
    }

    func testDeduplicationByID() {
        // Simulate two endpoints with the same service name — only one should survive.
        let ep1 = NWEndpoint.service(name: "my-mac", type: "_nostromo._tcp", domain: "local.", interface: nil)
        let ep2 = NWEndpoint.service(name: "my-mac", type: "_nostromo._tcp", domain: "local.", interface: nil)

        let d1 = DiscoveredDaemon.from(endpoint: ep1)!
        let d2 = DiscoveredDaemon.from(endpoint: ep2)!

        // Same name → same id → should be considered duplicates.
        XCTAssertEqual(d1.id, d2.id)
        XCTAssertEqual(d1, d2)
    }

    func testTwoDifferentServiceNamesAreDistinct() {
        let ep1 = NWEndpoint.service(name: "mac-a", type: "_nostromo._tcp", domain: "local.", interface: nil)
        let ep2 = NWEndpoint.service(name: "mac-b", type: "_nostromo._tcp", domain: "local.", interface: nil)

        let d1 = DiscoveredDaemon.from(endpoint: ep1)!
        let d2 = DiscoveredDaemon.from(endpoint: ep2)!

        XCTAssertNotEqual(d1.id, d2.id)
        XCTAssertNotEqual(d1, d2)
    }
}
