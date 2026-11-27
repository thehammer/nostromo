// WebSocketPushDetailTransportTests.swift
//
// The Notification Service Extension's one-shot connection to the primary (W16), against the same
// in-process loopback server the WebSocket client tests use (`TestWebSocketServer`): hello first, then
// (after the Welcome) a `subscribe` on one narrow topic, then `push_detail`, the reply's bytes handed
// back. The server follows the daemon's rule (`daemonRule`): a connection whose second frame is not a
// `subscribe` is dropped and never answered, which is what the daemon does and what the first cut of
// the extension ran into. Frames the extension does not care about are skipped, up to a bound on
// frames and on bytes; an `unauthorized` frame is an error; the token goes only in the Authorization
// header; and cancelling the request (which is how the fetcher's deadline ends it) closes the socket.
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
private let detailWithheld = #"{"type":"withheld","topics":["work"]}"#

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

    /// A server that follows the daemon's rule for the second frame and answers `push_detail` with
    /// `replies`, in order.
    private func startDaemonLikeServer(replies: [String] = [detailReply]) async throws -> TestWebSocketServer {
        try await startServer(onText: TestWebSocketServer.daemonRule(answering: "push_detail", with: replies))
    }

    private func request(_ transport: WebSocketPushDetailTransport, itemRef: String = "item-1") async throws -> Data {
        try await withDeadline(10) { try await transport.request(itemRef: itemRef) }
    }

    // MARK: - The round trip

    func testItReturnsThePushDetailFrameTheServerAnswersAfterAWelcome() async throws {
        let server = try await startDaemonLikeServer()
        let transport = WebSocketPushDetailTransport(host: "127.0.0.1", port: server.port, token: detailToken)

        let data = try await request(transport)

        let detail = try XCTUnwrap(PushDetailWire.parse(data))
        XCTAssertEqual(detail.itemRef, "item-1")
        XCTAssertTrue(detail.waiting)
        XCTAssertEqual(detail.text, "Which database?")

        let frames = (server.connection(at: 0)?.receivedTexts ?? []).map(parseWireJSON)
        XCTAssertEqual(frames.map { $0["type"] as? String }, ["hello", "subscribe", "push_detail"],
                       "hello, then the subscribe the daemon insists on, then the question")
        XCTAssertEqual(frames.last?["item_ref"] as? String, "item-1")
    }

    func testTheSubscribeNamesOneNarrowTopicNeverTheEmptyEverythingList() async throws {
        let server = try await startDaemonLikeServer()
        let transport = WebSocketPushDetailTransport(host: "127.0.0.1", port: server.port, token: detailToken)

        _ = try await request(transport)

        let subscribe = parseWireJSON(server.connection(at: 0)?.receivedTexts[1] ?? "")
        XCTAssertEqual(subscribe["topics"] as? [String], ["terminal"],
                       "[] means every topic and the attach-time replay of each")
        XCTAssertEqual(subscribe["renders_decisions"] as? Bool, false)
    }

    func testNothingIsSentUntilTheWelcomeHasArrived() async throws {
        // A server that does not welcome: the client has said hello and waits.
        let server = try await startServer(onReady: nil)
        let transport = WebSocketPushDetailTransport(host: "127.0.0.1", port: server.port, token: detailToken)
        let task = Task { try await transport.request(itemRef: "item-1") }

        await assertEventually("hello reaches the server") {
            (server.connection(at: 0)?.receivedTexts.count ?? 0) >= 1
        }
        await observationWindow(0.3)
        let types = (server.connection(at: 0)?.receivedTexts ?? []).map { wireType($0) }
        XCTAssertEqual(types, ["hello"], "no subscribe or question before the Welcome")
        task.cancel()
        _ = try? await task.value
    }

    // MARK: - Frames it does not care about

    func testFramesBeforeTheReplyThatAreNotItAreSkipped() async throws {
        let junk = [detailWithheld, #"{"type":"hosts","hosts":[]}"#, "not json at all", #"{"no_type":true}"#,
                    #"{"type":"push_detail_ack"}"#]
        let server = try await startDaemonLikeServer(replies: junk + [detailReply])
        let transport = WebSocketPushDetailTransport(host: "127.0.0.1", port: server.port, token: detailToken)

        let data = try await request(transport)

        XCTAssertEqual(try XCTUnwrap(PushDetailWire.parse(data)).text, "Which database?")
    }

    func testTooManyFramesBeforeTheReplyAreNoReply() async throws {
        // The Welcome is frame 1; the reply would be frame `maxFramesRead + 2`.
        let junk = Array(repeating: detailWithheld, count: WebSocketPushDetailTransport.maxFramesRead)
        let server = try await startDaemonLikeServer(replies: junk + [detailReply])
        let transport = WebSocketPushDetailTransport(host: "127.0.0.1", port: server.port, token: detailToken)

        do {
            _ = try await request(transport)
            XCTFail("a reply past the frame bound is not read")
        } catch let failure as WebSocketPushDetailTransport.Failure {
            XCTAssertEqual(failure.reason, "no reply")
        } catch {
            XCTFail("expected a no-reply failure, got \(error)")
        }
    }

    func testTooManyBytesBeforeTheReplyAreNoReply() async throws {
        // Ten frames of 15 000 bytes (each under the per-frame limit) are more than the byte bound,
        // and far fewer than the frame bound.
        let big = #"{"type":"hosts","pad":""# + String(repeating: "x", count: 15_000) + #""}"#
        let junk = Array(repeating: big, count: 10)
        XCTAssertLessThan(10 + 2, WebSocketPushDetailTransport.maxFramesRead)
        XCTAssertGreaterThan(10 * 15_000, WebSocketPushDetailTransport.maxBytesRead)
        let server = try await startDaemonLikeServer(replies: junk + [detailReply])
        let transport = WebSocketPushDetailTransport(host: "127.0.0.1", port: server.port, token: detailToken)

        do {
            _ = try await request(transport)
            XCTFail("a reply past the byte bound is not read")
        } catch let failure as WebSocketPushDetailTransport.Failure {
            XCTAssertEqual(failure.reason, "no reply")
        } catch {
            XCTFail("expected a no-reply failure, got \(error)")
        }
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

        await assertEventually("hello, subscribe and push_detail reach the server") {
            (server.connection(at: 0)?.receivedTexts.count ?? 0) >= 3
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
