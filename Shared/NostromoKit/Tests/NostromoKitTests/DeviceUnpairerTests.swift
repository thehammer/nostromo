// DeviceUnpairerTests.swift
//
// Un-pairing from the phone (D6) against the loopback server, which follows the daemon's rule for a
// connection's second frame (`TestWebSocketServer.daemonRule`): it must be a `subscribe`, or the
// connection is dropped and nothing is answered. So `hello` then `device_unpair_self` is never
// answered, and the sequence the unpairer sends is `hello`, the Welcome, `subscribe`,
// `device_unpair_self`.

import XCTest
@testable import NostromoKit

private let unpairWelcome = #"{"type":"welcome","protocol_version":4,"daemon_pid":1,"features":["ws"]}"#
private let unpairAnswer = #"{"type":"device_unpaired"}"#

@MainActor
final class DeviceUnpairerTests: XCTestCase {

    private var servers: [TestWebSocketServer] = []
    private let credential = DeviceCredential(token: "tok_Zm9vYmFyLXRlc3QtdG9rZW4", deviceId: "dev-1", serverId: "srv-1", name: "Phone")

    override func tearDown() async throws {
        for server in servers { server.stop() }
        servers = []
        try await super.tearDown()
    }

    private func startServer(
        onText: (@Sendable (TestWebSocketServer.Connection, String) -> Void)?
    ) async throws -> TestWebSocketServer {
        let server = try await TestWebSocketServer.start(onReady: { $0.send(unpairWelcome) }, onText: onText)
        servers.append(server)
        return server
    }

    func testTheServerAnswersAfterTheSubscribeAndTheUnpairIsConfirmed() async throws {
        let server = try await startServer(
            onText: TestWebSocketServer.daemonRule(answering: "device_unpair_self", with: [unpairAnswer]))

        let unpaired = await DeviceUnpairer.unpair(host: "127.0.0.1", port: server.port,
                                                   credential: credential, timeout: 5)

        XCTAssertTrue(unpaired)
        let types = (server.connection(at: 0)?.receivedTexts ?? []).map { wireType($0) }
        XCTAssertEqual(types, ["hello", "subscribe", "device_unpair_self"])
        let subscribe = parseWireJSON(server.connection(at: 0)?.receivedTexts[1] ?? "")
        XCTAssertEqual(subscribe["topics"] as? [String], ["terminal"], "never the empty everything list")
    }

    func testAnUnauthorizedServerIsNotConfirmation() async throws {
        let server = try await TestWebSocketServer.start(
            onReady: { $0.send(#"{"type":"unauthorized","reason":"revoked"}"#) })
        servers.append(server)

        let unpaired = await DeviceUnpairer.unpair(host: "127.0.0.1", port: server.port,
                                                   credential: credential, timeout: 5)

        XCTAssertFalse(unpaired)
    }
}
