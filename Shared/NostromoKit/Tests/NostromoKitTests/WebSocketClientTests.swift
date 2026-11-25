// NostromoKit — WebSocketClientTests.swift
//
// The phone's WebSocket transport against an in-process loopback server (`TestWebSocketServer`).
// What the daemon sees (handshake order, the bearer header, no Origin, which verbs arrive) and what
// the app is told (`state`, `connected`, `messages`, `hostedMessages`).
//
// The rule these tests guard above all (PRD-AC22 / W11-6): only the server saying "you are not
// paired" (an `Unauthorized` frame or close code 4001) moves the client to `.notPaired`, and it then
// stops. Every other way a connection can end is `.unreachable` (or `.localNetworkDenied`) and keeps
// retrying.
//
// The request path ("/") cannot be asserted: the loopback server API does not expose it.

import XCTest
import Combine
import Network
@testable import NostromoKit

private let secretToken = "tok_Zm9vYmFyLXRlc3QtdG9rZW4"
private let welcomeFrame = #"{"type":"welcome","protocol_version":4,"daemon_pid":4242,"features":["ws","pair","hosts"]}"#
private let unauthorizedFrame = #"{"type":"unauthorized","reason":"revoked"}"#

/// A hand-made `Encodable` with a chosen wire `type`, for verbs that have no Kit type on iOS.
private struct WireStandIn: Encodable { let type: String }

/// Collects what a client publishes, in order.
@MainActor
private final class ClientRecorder {
    private(set) var states: [ConnectionState] = []
    private(set) var messages: [ServerMsg] = []
    private(set) var hosted: [HostedServerMsg] = []
    private var bag: [AnyCancellable] = []

    init(_ client: WebSocketClient) {
        client.$state.sink { [weak self] in self?.states.append($0) }.store(in: &bag)
        client.messages.sink { [weak self] in self?.messages.append($0) }.store(in: &bag)
        client.hostedMessages.sink { [weak self] in self?.hosted.append($0) }.store(in: &bag)
    }
}

@MainActor
final class WebSocketClientTests: XCTestCase {

    private var servers: [TestWebSocketServer] = []
    private var clients: [WebSocketClient] = []

    override func tearDown() async throws {
        for client in clients { client.stop() }
        for server in servers { server.stop() }
        clients = []
        servers = []
        try await super.tearDown()
    }

    // MARK: Helpers

    /// A server that greets every client with a welcome frame unless told otherwise.
    private func startServer(
        onReady: (@Sendable (TestWebSocketServer.Connection) -> Void)? = { $0.send(welcomeFrame) },
        onText: (@Sendable (TestWebSocketServer.Connection, String) -> Void)? = nil
    ) async throws -> TestWebSocketServer {
        let server = try await TestWebSocketServer.start(onReady: onReady, onText: onText)
        servers.append(server)
        return server
    }

    private func makeClient(port: UInt16, host: String = "127.0.0.1",
                            probe: FakeLocalNetworkProbe = FakeLocalNetworkProbe(),
                            handshakeTimeout: TimeInterval = 5) -> WebSocketClient {
        let credential = DeviceCredential(token: secretToken, deviceId: "dev-1", serverId: "srv-1", name: "Test Phone")
        let client = WebSocketClient(host: host, port: port, credential: credential, probe: probe,
                                     initialBackoff: 0.05, maxBackoff: 0.2,
                                     pingInterval: 30, handshakeTimeout: handshakeTimeout)
        clients.append(client)
        return client
    }

    private func texts(of server: TestWebSocketServer, connection index: Int = 0) -> [String] {
        server.connection(at: index)?.receivedTexts ?? []
    }

    private func notPairedReason(_ state: ConnectionState) -> String? {
        if case .notPaired(let reason) = state { return reason }
        return nil
    }

    private func encodedType(_ data: Data?) -> String? {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["type"] as? String
    }

    // MARK: - Handshake

    func testTheClientSendsHelloThenSubscribeOnConnect() async throws {
        let server = try await startServer()
        let client = makeClient(port: server.port)
        client.start()

        await assertEventually("hello and subscribe reach the server") { self.texts(of: server).count >= 2 }
        let frames = texts(of: server).map(parseWireJSON)
        XCTAssertEqual(frames[0]["type"] as? String, "hello", "Hello must be the first frame")
        XCTAssertEqual(frames[1]["type"] as? String, "subscribe", "Subscribe must follow Hello")

        // W11-15: protocol 4, and the one capability this client can render.
        XCTAssertEqual(frames[0]["protocol_version"] as? Int, 4)
        XCTAssertEqual(frames[0]["capabilities"] as? [String], ["merged_turns_v1"])
        XCTAssertFalse((frames[0]["client_id"] as? String ?? "").isEmpty)

        // Every topic, decisions rendered, and never a claim to render approvals.
        XCTAssertEqual(frames[1]["topics"] as? [String], [])
        XCTAssertEqual(frames[1]["renders_decisions"] as? Bool, true)
        XCTAssertEqual(frames[1]["renders_approvals"] as? Bool, false)
    }

    func testTheTokenGoesOnlyInAnExactBearerAuthorizationHeaderAndNoOriginIsSent() async throws {
        let capture = try await RawUpgradeCapture.start()
        defer { capture.stop() }
        let client = makeClient(port: capture.port)
        client.start()
        defer { client.stop() }

        await assertEventually("the upgrade arrives") { capture.request != nil }
        XCTAssertEqual(capture.header("Authorization"), "Bearer \(secretToken)")
        XCTAssertNil(capture.header("Origin"), "The daemon refuses an upgrade that carries an Origin header")
        XCTAssertEqual(capture.requestLine?.hasPrefix("GET / HTTP/1.1"), true)
        XCTAssertFalse(capture.requestLine?.contains(secretToken) ?? true, "the token is never in the URL")
    }

    // MARK: - State

    func testTheClientIsConnectingUntilTheServersFirstFrameThenConnected() async throws {
        let server = try await startServer(onReady: nil)
        let client = makeClient(port: server.port)
        let recorder = ClientRecorder(client)
        client.start()

        // The server has accepted the upgrade and heard Hello, but has said nothing yet.
        await assertEventually("hello reaches the server") { self.texts(of: server).count >= 1 }
        await observationWindow(0.2)
        XCTAssertEqual(client.state, .connecting)
        XCTAssertFalse(client.connected)

        server.connection(at: 0)?.send(welcomeFrame)
        await assertEventually("the client connects after the first frame") { client.state == .connected }
        XCTAssertTrue(client.connected)
        XCTAssertEqual(client.serverFeatures, ["ws", "pair", "hosts"])
        XCTAssertEqual(recorder.states, [.connecting, .connected])
    }

    func testFramesArePublishedOnMessagesAndOnHostedMessagesWithTheirHost() async throws {
        let primaryJobs = #"{"type":"mother_jobs","jobs":[{"id":"j1","state":"running","title":"Primary job"}]}"#
        let kobeJobs = #"{"type":"mother_jobs","host":"kobe","jobs":[{"id":"j2","state":"queued","title":"Kobe job"}]}"#
        let server = try await startServer(onReady: { connection in
            connection.send(welcomeFrame)
            connection.send(primaryJobs)
            connection.send(kobeJobs)
        })
        let client = makeClient(port: server.port)
        let recorder = ClientRecorder(client)
        client.start()

        await assertEventually("three frames are published") {
            recorder.messages.count >= 3 && recorder.hosted.count >= 3
        }
        XCTAssertEqual(recorder.hosted.map(\.host), [nil, nil, "kobe"])

        let jobIds: [[String]] = recorder.messages.compactMap {
            if case .motherJobs(let jobs) = $0 { return jobs.map(\.id) }
            return nil
        }
        XCTAssertEqual(jobIds, [["j1"], ["j2"]])

        let hostedJobIds: [[String]] = recorder.hosted.compactMap {
            if case .motherJobs(let jobs) = $0.msg { return jobs.map(\.id) }
            return nil
        }
        XCTAssertEqual(hostedJobIds, [["j1"], ["j2"]])
    }

    // MARK: - W11-6 / AC22: only the server can say "not paired"

    func testAnUnauthorizedFrameMeansNotPairedAndTheClientDoesNotReconnect() async throws {
        let server = try await startServer(onReady: { connection in
            connection.send(unauthorizedFrame)
            connection.close(code: .applicationCode(4001))
        })
        let client = makeClient(port: server.port)
        let recorder = ClientRecorder(client)
        client.start()

        await assertEventually("the client reports notPaired") { self.notPairedReason(client.state) != nil }
        XCTAssertEqual(client.state, .notPaired(reason: "revoked"))
        XCTAssertFalse(client.connected)
        XCTAssertFalse(recorder.states.contains(.connected), "An unauthorized first frame is never a connection")

        // Three initial backoffs (0.05 s each) would have produced a retry if it were going to.
        await observationWindow(0.6)
        XCTAssertEqual(server.acceptedConnectionCount, 1, "A revoked token must not be retried")
        XCTAssertEqual(client.state, .notPaired(reason: "revoked"))
    }

    func testCloseCode4001WithoutAFrameMeansNotPairedAndTheClientDoesNotReconnect() async throws {
        let server = try await startServer(onReady: { $0.close(code: .applicationCode(4001)) })
        let client = makeClient(port: server.port)
        client.start()

        await assertEventually("the client reports notPaired") { self.notPairedReason(client.state) != nil }
        XCTAssertFalse(client.connected)

        await observationWindow(0.6)
        XCTAssertEqual(server.acceptedConnectionCount, 1, "Close code 4001 must not be retried")
        XCTAssertNotNil(notPairedReason(client.state))
    }

    func testAnUnreachableServerIsUnreachableNeverNotPairedAndTheClientKeepsRetrying() async throws {
        let port = try await TestWebSocketServer.unusedPort()
        let probe = FakeLocalNetworkProbe(denied: false)
        let client = makeClient(port: port, probe: probe)
        let recorder = ClientRecorder(client)
        client.start()

        await assertEventually("the client reports unreachable") { client.state == .unreachable }
        // Each failed attempt asks the probe once, so several calls mean several attempts.
        await assertEventually("the client retries") { probe.calls.count >= 3 }
        XCTAssertEqual(client.state, .unreachable)
        XCTAssertFalse(client.connected)
        XCTAssertNil(recorder.states.compactMap(notPairedReason).first, "A refused connection is never notPaired")
    }

    func testTheClientConnectsOnceAServerAppearsAtTheAddressItWasRetrying() async throws {
        let port = try await TestWebSocketServer.unusedPort()
        let client = makeClient(port: port)
        client.start()
        await assertEventually("the client reports unreachable") { client.state == .unreachable }

        let server = try await TestWebSocketServer.start(port: port, onReady: { $0.send(welcomeFrame) })
        servers.append(server)

        await assertEventually("the client connects to the server that appeared") { client.state == .connected }
        XCTAssertTrue(client.connected)
    }

    func testAServerThatClosesWith1001IsUnreachableAndTheClientReconnects() async throws {
        let server = try await startServer(onReady: { connection in
            connection.send(welcomeFrame)
            if connection.index == 0 { connection.close(code: .protocolCode(.goingAway)) }
        })
        let client = makeClient(port: server.port)
        let recorder = ClientRecorder(client)
        client.start()

        await assertEventually("the client reconnects after the close") {
            server.acceptedConnectionCount >= 2 && client.state == .connected
        }
        let states = recorder.states
        let unreachableAt = try XCTUnwrap(states.firstIndex(of: .unreachable), "1001 must read as unreachable: \(states)")
        let firstConnectedAt = try XCTUnwrap(states.firstIndex(of: .connected))
        XCTAssertLessThan(firstConnectedAt, unreachableAt)
        XCTAssertNil(states.compactMap(notPairedReason).first, "A 1001 close is never notPaired")
        XCTAssertEqual(states.last, .connected)
    }

    // MARK: - Local Network permission

    func testWhenTheProbeSaysTheLocalNetworkIsDeniedTheStateIsLocalNetworkDenied() async throws {
        let port = try await TestWebSocketServer.unusedPort()
        let probe = FakeLocalNetworkProbe(denied: true)
        let client = makeClient(port: port, probe: probe)
        let recorder = ClientRecorder(client)
        client.start()

        await assertEventually("the client reports localNetworkDenied") { client.state == .localNetworkDenied }
        await assertEventually("the client keeps retrying") { probe.calls.count >= 2 }
        XCTAssertEqual(client.state, .localNetworkDenied)
        XCTAssertFalse(recorder.states.contains(.unreachable), "A denial is never reported as unreachable")
        XCTAssertNil(recorder.states.compactMap(notPairedReason).first, "A denial is never notPaired")
    }

    func testWhenTheProbeSaysTheLocalNetworkIsNotDeniedAFailureIsUnreachable() async throws {
        let port = try await TestWebSocketServer.unusedPort()
        let probe = FakeLocalNetworkProbe(denied: false)
        let client = makeClient(port: port, probe: probe)
        client.start()

        await assertEventually("the client reports unreachable") { client.state == .unreachable }
        XCTAssertNotEqual(client.state, .localNetworkDenied)
        let call = try XCTUnwrap(probe.calls.first, "The probe is asked about the address that failed")
        XCTAssertEqual(call.host, "127.0.0.1")
        XCTAssertEqual(call.port, port)
    }

    // MARK: - Handshake timeout

    func testAServerThatAcceptsTheUpgradeButNeverSpeaksIsUnreachableAfterTheHandshakeTimeoutAndRetried() async throws {
        let server = try await startServer(onReady: nil)
        let client = makeClient(port: server.port, handshakeTimeout: 0.3)
        client.start()

        XCTAssertEqual(client.state, .connecting)
        await assertEventually("the client gives up on the silent socket") { client.state == .unreachable }
        XCTAssertFalse(client.connected)
        await assertEventually("the client retries with a fresh socket") { server.acceptedConnectionCount >= 2 }
    }

    // MARK: - W11-2: what the phone never sends

    func testTheRefusedVerbsAreNeverEncodedForSending() throws {
        let client = makeClient(port: 1)
        XCTAssertNil(client.encodeForSend(ClientDecisionAnswer(requestId: "r1", choiceId: "yes")))
        XCTAssertNil(client.encodeForSend(ClientMotherResume(jobId: "j1", answer: "go")))
        XCTAssertNil(client.encodeForSend(ClientMotherAction(jobId: "j1", action: "cancel")))
        for type in ["approval_answer", "session_queue_watch", "session_queue_take_back", "session_queue_remove"] {
            XCTAssertNil(client.encodeForSend(WireStandIn(type: type)), "\(type) must be refused")
        }
    }

    func testTheReadOnlyVerbsAreEncodedForSending() throws {
        let client = makeClient(port: 1)
        XCTAssertEqual(encodedType(client.encodeForSend(ClientSessionList())), "session_list")
        XCTAssertEqual(encodedType(client.encodeForSend(ClientFocusList())), "focus_list")
        XCTAssertEqual(encodedType(client.encodeForSend(ClientSessionAttach(tag: "cody-1"))), "session_attach")
        XCTAssertEqual(encodedType(client.encodeForSend(ClientActivitySnapshotRequest(tag: "cody-1"))),
                       "activity_snapshot_request")
    }

    func testTheOutboundPolicyRefusesTheMessageQueueVerbs() {
        for type in ["session_queue_watch", "session_queue_take_back", "session_queue_remove"] {
            XCTAssertTrue(OutboundPolicy.refusedTypes.contains(type), "\(type) must be refused (W11-16)")
            XCTAssertFalse(OutboundPolicy.allows(type: type))
        }
    }

    func testAHostIsEncodedWhenGivenAndTheKeyIsAbsentWhenNot() throws {
        func object<T: Encodable>(_ value: T) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        }
        XCTAssertEqual(try object(ClientSessionList(host: "kobe"))["host"] as? String, "kobe")
        XCTAssertFalse(try object(ClientSessionList()).keys.contains("host"), "A nil host is omitted, not null")
        XCTAssertFalse(try object(ClientSessionList(host: nil)).keys.contains("host"))
    }

    func testSendingARefusedVerbPutsNothingOnTheWireAndAnAllowedVerbFollowsTheHandshake() async throws {
        let server = try await startServer()
        let client = makeClient(port: server.port)
        client.start()
        await assertEventually("the client is connected and has sent its handshake") {
            client.connected && self.texts(of: server).count >= 2
        }

        client.send(ClientDecisionAnswer(requestId: "r1", choiceId: "yes"))
        client.send(ClientMotherResume(jobId: "j1", answer: "go"))
        client.send(ClientMotherAction(jobId: "j1", action: "cancel"))
        client.send(WireStandIn(type: "approval_answer"))
        client.send(WireStandIn(type: "session_queue_watch"))
        client.send(WireStandIn(type: "session_queue_take_back"))
        client.send(WireStandIn(type: "session_queue_remove"))
        client.send(ClientSessionList())

        await assertEventually("the allowed frame arrives") { self.texts(of: server).count >= 3 }
        await observationWindow(0.2)
        let types = texts(of: server).map { wireType($0) }
        XCTAssertEqual(types, ["hello", "subscribe", "session_list"],
                       "Only the allowed verb may reach the server after the handshake")
    }

    // MARK: - Reconfiguration

    func testChangingThePortWhileRunningReconnectsToTheNewAddress() async throws {
        let first = try await startServer()
        let second = try await startServer()
        let client = makeClient(port: first.port)
        client.start()
        await assertEventually("connected to the first server") { client.connected && first.acceptedConnectionCount == 1 }

        client.port = second.port

        await assertEventually("connected to the second server") {
            client.state == .connected && second.acceptedConnectionCount >= 1
        }
        await assertEventually("the second server hears the handshake") { self.texts(of: second).count >= 2 }
        XCTAssertEqual(first.acceptedConnectionCount, 1, "The old address is not retried")
    }

    func testChangingTheHostWhileRunningReconnects() async throws {
        let server = try await startServer()
        let client = makeClient(port: server.port, host: "127.0.0.1")
        client.start()
        await assertEventually("connected") { client.connected && server.acceptedConnectionCount == 1 }

        client.host = "localhost"

        await assertEventually("reconnected through the new host name") {
            server.acceptedConnectionCount >= 2 && client.state == .connected
        }
    }
}
