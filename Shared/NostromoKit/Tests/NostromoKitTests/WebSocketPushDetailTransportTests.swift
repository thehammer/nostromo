// WebSocketPushDetailTransportTests.swift
//
// The Notification Service Extension's one-shot connection to the primary (W16), against the same
// in-process loopback server the WebSocket client tests use (`TestWebSocketServer`): hello first, then
// `push_detail`, the reply's bytes handed back; an `unauthorized` frame is an error; the token goes
// only in the Authorization header; and cancelling the request (which is how the fetcher's deadline
// ends it) closes the socket.
//
// Each request runs under a generous real-time safety cap (`withDeadline(10)`), so a regression that
// hangs fails this test instead of stalling the run. A passing test never waits on it.

import XCTest
import Network
@testable import NostromoKit

private let detailToken = "tok_Zm9vYmFyLXRlc3QtdG9rZW4"
private let detailWelcome = #"{"type":"welcome","protocol_version":4,"daemon_pid":4242,"features":["ws","pair","hosts"]}"#
private let detailUnauthorized = #"{"type":"unauthorized","reason":"revoked"}"#
private let detailReply = #"{"type":"push_detail","item_ref":"item-1","waiting":true,"text":"Which database?","host":"sendai"}"#

@MainActor
final class WebSocketPushDetailTransportTests: XCTestCase {

    private var servers: [TestWebSocketServer] = []

    override func tearDown() async throws {
        for server in servers { server.stop() }
        servers = []
        try await super.tearDown()
    }

    private func startServer(
        onReady: (@Sendable (TestWebSocketServer.Connection) -> Void)? = { $0.send(detailWelcome) },
        onText: (@Sendable (TestWebSocketServer.Connection, String) -> Void)? = nil
    ) async throws -> TestWebSocketServer {
        let server = try await TestWebSocketServer.start(onReady: onReady, onText: onText)
        servers.append(server)
        return server
    }

    private func request(_ transport: WebSocketPushDetailTransport, itemRef: String = "item-1") async throws -> Data {
        try await withDeadline(10) { try await transport.request(itemRef: itemRef) }
    }

    // MARK: - The round trip

    func testItReturnsThePushDetailFrameTheServerAnswersAfterAWelcome() async throws {
        let server = try await startServer(onText: { connection, text in
            if wireType(text) == "push_detail" { connection.send(detailReply) }
        })
        let transport = WebSocketPushDetailTransport(host: "127.0.0.1", port: server.port, token: detailToken)

        let data = try await request(transport)

        let detail = try XCTUnwrap(PushDetailWire.parse(data))
        XCTAssertEqual(detail.itemRef, "item-1")
        XCTAssertTrue(detail.waiting)
        XCTAssertEqual(detail.text, "Which database?")

        let frames = (server.connection(at: 0)?.receivedTexts ?? []).map(parseWireJSON)
        XCTAssertEqual(frames.map { $0["type"] as? String }, ["hello", "push_detail"], "hello first, then the question")
        XCTAssertEqual(frames.last?["item_ref"] as? String, "item-1")
    }

    func testAnUnauthorizedFrameIsAnError() async throws {
        let server = try await startServer(onReady: { $0.send(detailUnauthorized) })
        let transport = WebSocketPushDetailTransport(host: "127.0.0.1", port: server.port, token: detailToken)

        do {
            _ = try await request(transport)
            XCTFail("an unpaired phone gets no detail")
        } catch let failure as WebSocketPushDetailTransport.Failure {
            XCTAssertEqual(failure.reason, "unauthorized")
        } catch {
            XCTFail("expected an unauthorized failure, got \(error)")
        }
    }

    // MARK: - The token

    func testTheTokenGoesOnlyInTheAuthorizationHeaderAndNoOriginIsSent() async throws {
        let capture = try await RawUpgradeCapture.start()
        defer { capture.stop() }
        let transport = WebSocketPushDetailTransport(host: "127.0.0.1", port: capture.port, token: detailToken)

        _ = try? await request(transport)   // the capture hangs up after reading the upgrade request

        XCTAssertEqual(capture.header("Authorization"), "Bearer \(detailToken)")
        XCTAssertNil(capture.header("Origin"), "the daemon refuses an upgrade that has an Origin")
        XCTAssertFalse(capture.requestLine?.contains(detailToken) ?? true, "the token is never in the URL")
    }

    // MARK: - Cancelling

    func testCancellingARequestClosesTheSocket() async throws {
        let server = try await startServer()   // welcomes, never answers the question
        let transport = WebSocketPushDetailTransport(host: "127.0.0.1", port: server.port, token: detailToken)
        let task = Task { try await transport.request(itemRef: "item-1") }

        await assertEventually("hello and push_detail reach the server") {
            (server.connection(at: 0)?.receivedTexts.count ?? 0) >= 2
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("a cancelled request does not return an answer")
        } catch {
            // Any error: the request was abandoned.
        }
        await assertEventually("the server sees the socket close") {
            server.connection(at: 0)?.isClosed == true
        }
    }
}
