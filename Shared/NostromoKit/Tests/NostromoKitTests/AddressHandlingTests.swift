// NostromoKit — AddressHandlingTests.swift
//
// What the phone does with the address the operator (or a pairing link) typed. Two promises:
//   * an IPv6 literal works (`[::1]`, bare `::1`, `[fe80::1]`), because a VPN or a LAN may be IPv6;
//   * an address with no `ws://` URL (`bad host`, `a/b`, empty) fails as a bad address and NOTHING is
//     opened anywhere else. A socket carries the bearer token, so a fallback address (the old code
//     used `invalid.invalid`) is not an acceptable way to fail.
//
// The URL and classification tests open no socket. The connection tests use the loopback server in
// `TestWebSocketServer`; the IPv6 one assumes the runner has `::1` on its loopback interface.

import XCTest
import Combine
@testable import NostromoKit

private let addressTestOfferFrame =
    #"{"type":"pair_offer","name_hint":"Hammer's Mac","server_id":"srv-1","challenge":"chal-1"}"#
private let addressTestWelcomeFrame = #"{"type":"welcome","protocol_version":4,"daemon_pid":1,"features":["ws"]}"#

@MainActor
final class AddressHandlingTests: XCTestCase {

    private let port: UInt16 = 47101
    private let unusableHosts = ["", "   ", "bad host", "a/b"]

    private var servers: [TestWebSocketServer] = []
    private var clients: [WebSocketClient] = []
    private var pairingClients: [PairingClient] = []
    private var bag: [AnyCancellable] = []

    override func tearDown() async throws {
        for client in clients { client.stop() }
        for client in pairingClients { client.close() }
        for server in servers { server.stop() }
        clients = []
        pairingClients = []
        servers = []
        bag = []
        try await super.tearDown()
    }

    private var credential: DeviceCredential {
        DeviceCredential(token: "tok_QWRkcmVzc1Rlc3RUb2tlbg", deviceId: "dev-1", serverId: "srv-1", name: "Test Phone")
    }

    // MARK: - The URL

    func testAnIPv6LiteralKeepsItsBrackets() {
        XCTAssertEqual(WebSocketChannel.url(host: "[::1]", port: port)?.absoluteString, "ws://[::1]:47101/")
        XCTAssertEqual(WebSocketChannel.url(host: "[fe80::1]", port: port)?.absoluteString, "ws://[fe80::1]:47101/")
    }

    func testABareIPv6LiteralIsBracketed() {
        XCTAssertEqual(WebSocketChannel.url(host: "::1", port: port)?.absoluteString, "ws://[::1]:47101/")
        XCTAssertEqual(WebSocketChannel.url(host: "fd00::1", port: port)?.absoluteString, "ws://[fd00::1]:47101/")
    }

    func testAnIPv4AddressAndANameAreUsedAsTyped() {
        XCTAssertEqual(WebSocketChannel.url(host: "10.0.0.5", port: port)?.absoluteString, "ws://10.0.0.5:47101/")
        XCTAssertEqual(WebSocketChannel.url(host: "mac.local", port: 9000)?.absoluteString, "ws://mac.local:9000/")
    }

    func testAnUnusableHostHasNoURLAndNeverTheInvalidFallback() {
        for host in unusableHosts {
            let url = WebSocketChannel.url(host: host, port: port)
            XCTAssertNil(url, "\"\(host)\" has no ws:// URL")
            XCTAssertFalse(url?.absoluteString.contains("invalid.invalid") ?? false)
        }
    }

    // MARK: - The channel

    func testAChannelForAnUnusableHostThrowsBadAddressInsteadOfOpeningAnotherAddress() {
        for host in unusableHosts {
            XCTAssertThrowsError(try WebSocketChannel(host: host, port: port, bearer: "secret"), "\"\(host)\"") { error in
                XCTAssertEqual(error as? WebSocketChannel.BadAddress, WebSocketChannel.BadAddress(), "\"\(host)\"")
            }
            XCTAssertThrowsError(try WebSocketChannel(host: host, port: port, bearer: nil), "\"\(host)\" (pairing socket)")
        }
    }

    func testAChannelForAUsableHostIsMade() throws {
        for host in ["10.0.0.5", "mac.local", "[::1]", "::1"] {
            let channel = try WebSocketChannel(host: host, port: port, bearer: "secret")
            channel.cancel()
        }
    }

    // MARK: - Classification

    func testABadAddressErrorIsClassifiedAsBadAddress() {
        XCTAssertEqual(WebSocketChannel.failure(for: WebSocketChannel.BadAddress(), closeCode: 0, httpStatus: nil),
                       .badAddress)
    }

    func testABadAddressIsUnreachableNeverNotPairedAndIsNotBlamedOnLocalNetworkPermission() async {
        XCTAssertEqual(ConnectionFailure.badAddress.state, .unreachable)
        XCTAssertFalse(ConnectionFailure.badAddress.mayBeLocalNetworkPolicy)

        let probe = FakeLocalNetworkProbe(denied: true)
        let refined = await probe.refine(.badAddress, host: "bad host", port: port)
        XCTAssertEqual(refined, .badAddress, "A denied probe must not turn a malformed address into a permission problem")
        XCTAssertTrue(probe.calls.isEmpty, "There is nothing to probe: no address was ever tried")
    }

    // MARK: - A client given a malformed host

    func testAClientWithAMalformedHostIsUnreachableAndOpensNothing() async throws {
        let server = try await TestWebSocketServer.start(onReady: { $0.send(addressTestWelcomeFrame) })
        servers.append(server)
        let probe = FakeLocalNetworkProbe(denied: true)
        let client = WebSocketClient(host: "bad host", port: server.port, credential: credential, probe: probe,
                                     initialBackoff: 0.05, maxBackoff: 0.2, pingInterval: 30, handshakeTimeout: 5)
        clients.append(client)
        var states: [ConnectionState] = []
        client.$state.sink { states.append($0) }.store(in: &bag)

        client.start()

        await assertEventually("the client reports unreachable") { client.state == .unreachable }
        await observationWindow(0.3)   // several backoffs: it keeps trying, and keeps failing the same way
        XCTAssertEqual(client.state, .unreachable)
        XCTAssertFalse(client.connected)
        XCTAssertFalse(states.contains(.connected))
        XCTAssertFalse(states.contains(.localNetworkDenied), "A denied probe is never asked about a malformed host")
        XCTAssertTrue(probe.calls.isEmpty)
        XCTAssertEqual(server.acceptedConnectionCount, 0)
    }

    // MARK: - Pairing and unpairing to a malformed host

    func testPairingCheckToAMalformedHostIsABadAddressNotUnreachable() async throws {
        let probe = FakeLocalNetworkProbe(denied: true)
        let client = PairingClient(host: "bad host", port: port, probe: probe, responseTimeout: 1)
        pairingClients.append(client)

        do {
            _ = try await client.check(code: "123456")
            XCTFail("a malformed host cannot be checked")
        } catch let error as PairingError {
            XCTAssertEqual(error, .badAddress)
        } catch {
            XCTFail("expected PairingError.badAddress, got \(error)")
        }
        XCTAssertFalse(client.isOpen)
        XCTAssertTrue(probe.calls.isEmpty)
    }

    func testPairingToAMalformedHostIsABadAddressToo() async throws {
        let client = PairingClient(host: "a/b", port: port, probe: FakeLocalNetworkProbe(), responseTimeout: 1)
        pairingClients.append(client)

        do {
            _ = try await client.pair(code: "123456", name: "Phone", kind: .iphone, replace: false)
            XCTFail("a malformed host cannot be paired with")
        } catch let error as PairingError {
            XCTAssertEqual(error, .badAddress)
        } catch {
            XCTFail("expected PairingError.badAddress, got \(error)")
        }
    }

    func testUnpairingFromAMalformedHostReturnsFalseAtOnce() async {
        let started = Date()

        let unpaired = await DeviceUnpairer.unpair(host: "bad host", port: port, credential: credential, timeout: 5)

        XCTAssertFalse(unpaired)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "It fails on the address, not after the timeout")
    }

    // MARK: - Reaching a server by IPv4 and by IPv6 literal

    func testPairingChecksReachALoopbackServerByIPv4AndByIPv6Literal() async throws {
        let server = try await TestWebSocketServer.start(onText: { connection, text in
            if wireType(text) == "pair_check" { connection.send(addressTestOfferFrame) }
        })
        servers.append(server)

        for host in ["127.0.0.1", "[::1]"] {
            let client = PairingClient(host: host, port: server.port, probe: FakeLocalNetworkProbe(),
                                       responseTimeout: 3)
            pairingClients.append(client)

            let offer = try await client.check(code: "123456")

            XCTAssertEqual(offer.serverId, "srv-1", "check over \(host)")
            XCTAssertEqual(offer.challenge, "chal-1", "check over \(host)")
        }
        XCTAssertEqual(server.acceptedConnectionCount, 2, "one socket per host")
    }
}
