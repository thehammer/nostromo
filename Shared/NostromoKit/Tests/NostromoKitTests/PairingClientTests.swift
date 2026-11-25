// NostromoKit — PairingClientTests.swift
//
// The device half of pairing against an in-process loopback server that plays the daemon's
// token-less pairing socket: it answers `pair_check` with an offer and `pair` with the token, then
// closes (1000). What the daemon sees (the exact frame keys, one socket, no Authorization, no
// Origin) and what the caller gets (offers, results, typed errors, a redacted token).

import XCTest
@testable import NostromoKit

private let fixedToken = "dG9rZW4tZm9yLXRoZS1maXhlZC12ZWN0b3ItMDAwMDAwMDA"
private let fixedChallenge = "Y2hhbGxlbmdlLWZvci10aGUtZml4ZWQtdmVjdG9yLTAwMDA"
private let fixedProof = "ONMjmbNsnby-4Laxp33owC99gferbRJQsDdW6Ofz4cA"

/// What the server hands out; the secret must never appear in any printed form.
private let issuedToken = "aXNzdWVkLXRva2VuLVNFQ1JFVC1WQUxVRS0xMjM0NTY"

private let offerFrame = #"{"type":"pair_offer","name_hint":"Hammer's Mac","server_id":"srv-1","challenge":"\#(fixedChallenge)"}"#
private let offerKnowingDeviceFrame =
    #"{"type":"pair_offer","name_hint":"Hammer's Mac","server_id":"srv-1","challenge":"\#(fixedChallenge)","knows_device":true}"#
private let pairedFrame =
    #"{"type":"paired","device_id":"dev-9","token":"\#(issuedToken)","name":"Hammer's iPhone","server_id":"srv-1","replaced":true}"#
private let welcomeFrame = #"{"type":"welcome","protocol_version":4,"daemon_pid":1}"#

@MainActor
final class PairingClientTests: XCTestCase {

    private var servers: [TestWebSocketServer] = []
    private var clients: [PairingClient] = []

    override func tearDown() async throws {
        for client in clients { client.close() }
        for server in servers { server.stop() }
        clients = []
        servers = []
        try await super.tearDown()
    }

    // MARK: Helpers

    /// A pairing server: `pair_check` is answered with `offer`, `pair` with `paired` and a 1000 close.
    private func startPairingServer(offer: String = offerFrame,
                                    greet: Bool = false) async throws -> TestWebSocketServer {
        let server = try await TestWebSocketServer.start(
            onReady: { connection in if greet { connection.send(welcomeFrame) } },
            onText: { connection, text in
                switch wireType(text) {
                case "pair_check":
                    connection.send(offer)
                case "pair":
                    connection.send(pairedFrame)
                    connection.close(code: .protocolCode(.normalClosure))
                default:
                    break
                }
            })
        servers.append(server)
        return server
    }

    /// A server that accepts and never answers.
    private func startSilentServer() async throws -> TestWebSocketServer {
        let server = try await TestWebSocketServer.start()
        servers.append(server)
        return server
    }

    private func makeClient(port: UInt16, probe: FakeLocalNetworkProbe = FakeLocalNetworkProbe(),
                            responseTimeout: TimeInterval = 3) -> PairingClient {
        let client = PairingClient(host: "127.0.0.1", port: port, probe: probe, responseTimeout: responseTimeout)
        clients.append(client)
        return client
    }

    private func assertThrows(_ expected: PairingError, file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected), but nothing was thrown", file: file, line: line)
        } catch let error as PairingError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }

    private func texts(of server: TestWebSocketServer, connection index: Int = 0) -> [String] {
        server.connection(at: index)?.receivedTexts ?? []
    }

    // MARK: - The proof

    func testTheProofMatchesThePinnedVector() {
        XCTAssertEqual(PairingClient.proof(token: fixedToken, challenge: fixedChallenge, code: "123456"), fixedProof)
    }

    func testTheProofIgnoresSpacesAndDashesInTheCode() {
        XCTAssertEqual(PairingClient.proof(token: fixedToken, challenge: fixedChallenge, code: "123 456"), fixedProof)
        XCTAssertEqual(PairingClient.proof(token: fixedToken, challenge: fixedChallenge, code: "123-456"), fixedProof)
    }

    // MARK: - check

    func testCheckReturnsTheServersOffer() async throws {
        let server = try await startPairingServer()
        let client = makeClient(port: server.port)

        let offer = try await client.check(code: "123456")

        XCTAssertEqual(offer.nameHint, "Hammer's Mac")
        XCTAssertEqual(offer.serverId, "srv-1")
        XCTAssertEqual(offer.challenge, fixedChallenge)
        XCTAssertNil(offer.knowsDevice, "Without a proof the server says nothing about knowing the device")
    }

    func testCheckSurfacesWhetherTheServerKnowsTheDeviceWhenAProofIsSent() async throws {
        let server = try await startPairingServer(offer: offerKnowingDeviceFrame)
        let client = makeClient(port: server.port)

        let offer = try await client.check(code: "123456", proof: fixedProof)

        XCTAssertEqual(offer.knowsDevice, true)
        let frame = parseWireJSON(try XCTUnwrap(texts(of: server).first))
        XCTAssertEqual(frame["proof"] as? String, fixedProof)
    }

    func testCheckSendsExactlyTheWireKeysWithAProof() async throws {
        let server = try await startPairingServer()
        let client = makeClient(port: server.port)

        _ = try await client.check(code: "123456", proof: fixedProof)

        let frame = parseWireJSON(try XCTUnwrap(texts(of: server).first))
        XCTAssertEqual(Set(frame.keys), ["type", "code", "proof"])
        XCTAssertEqual(frame["type"] as? String, "pair_check")
        XCTAssertEqual(frame["code"] as? String, "123456")
    }

    func testCheckOmitsTheProofKeyWithoutAProof() async throws {
        let server = try await startPairingServer()
        let client = makeClient(port: server.port)

        _ = try await client.check(code: "123456")

        let frame = parseWireJSON(try XCTUnwrap(texts(of: server).first))
        XCTAssertEqual(Set(frame.keys), ["type", "code"], "An absent proof is omitted, not null")
    }

    func testCheckMapsAnExpiredRefusalToExpired() async throws {
        let server = try await startPairingServer(offer: #"{"type":"pair_refused","reason":"expired"}"#)
        let client = makeClient(port: server.port)
        await assertThrows(.expired) { _ = try await client.check(code: "123456") }
    }

    func testCheckMapsAnInvalidRefusalToInvalid() async throws {
        let server = try await startPairingServer(offer: #"{"type":"pair_refused","reason":"invalid"}"#)
        let client = makeClient(port: server.port)
        await assertThrows(.invalid) { _ = try await client.check(code: "123456") }
    }

    func testAGreetingBeforeTheAnswerIsSkipped() async throws {
        let server = try await startPairingServer(greet: true)
        let client = makeClient(port: server.port)

        let offer = try await client.check(code: "123456")

        XCTAssertEqual(offer.serverId, "srv-1")
    }

    func testTheCodeIsSentAsDigitsOnly() async throws {
        let server = try await startPairingServer()
        let client = makeClient(port: server.port)

        _ = try await client.check(code: "12 34-56")
        _ = try await client.check(code: "abc123456")

        let codes = texts(of: server).map { parseWireJSON($0)["code"] as? String }
        XCTAssertEqual(codes, ["123456", "123456"])
    }

    // MARK: - pair

    func testPairReturnsTheIssuedCredentialAndSendsExactlyTheWireKeys() async throws {
        let server = try await startPairingServer()
        let client = makeClient(port: server.port)

        let result = try await client.pair(code: "123456", name: "Hammer's iPhone", kind: .iphone, replace: false)

        XCTAssertEqual(result.deviceId, "dev-9")
        XCTAssertEqual(result.token.value, issuedToken)
        XCTAssertEqual(result.name, "Hammer's iPhone")
        XCTAssertEqual(result.serverId, "srv-1")
        XCTAssertTrue(result.replaced)

        let frame = parseWireJSON(try XCTUnwrap(texts(of: server).first))
        XCTAssertEqual(Set(frame.keys), ["type", "code", "name", "kind", "replace"])
        XCTAssertEqual(frame["type"] as? String, "pair")
        XCTAssertEqual(frame["code"] as? String, "123456")
        XCTAssertEqual(frame["name"] as? String, "Hammer's iPhone")
        XCTAssertEqual(frame["kind"] as? String, "iphone")
        XCTAssertEqual(frame["replace"] as? Bool, false)
    }

    func testPairSendsReplaceTrueWhenAsked() async throws {
        let server = try await startPairingServer()
        let client = makeClient(port: server.port)

        _ = try await client.pair(code: "123456", name: "iPad", kind: .ipad, replace: true)

        let frame = parseWireJSON(try XCTUnwrap(texts(of: server).first))
        XCTAssertEqual(frame["replace"] as? Bool, true)
        XCTAssertEqual(frame["kind"] as? String, "ipad")
    }

    func testPairMapsARefusalToATypedError() async throws {
        let server = try await TestWebSocketServer.start(onText: { connection, text in
            if wireType(text) == "pair" { connection.send(#"{"type":"pair_refused","reason":"expired"}"#) }
        })
        servers.append(server)
        let client = makeClient(port: server.port)

        await assertThrows(.expired) {
            _ = try await client.pair(code: "123456", name: "Phone", kind: .iphone, replace: false)
        }
        XCTAssertFalse(client.isOpen, "A refused pair leaves nothing open")
    }

    func testTheIssuedTokenNeverAppearsInAnyPrintedForm() async throws {
        let server = try await startPairingServer()
        let client = makeClient(port: server.port)

        let result = try await client.pair(code: "123456", name: "Phone", kind: .iphone, replace: false)

        var dumped = ""
        dump(result, to: &dumped)
        var dumpedToken = ""
        dump(result.token, to: &dumpedToken)
        let printed = [
            "\(result.token)", String(describing: result.token), String(reflecting: result.token), dumpedToken,
            String(describing: result), String(reflecting: result), dumped,
        ]
        for text in printed {
            XCTAssertFalse(text.contains(issuedToken), "The token leaked into: \(text.prefix(120))")
        }
        XCTAssertEqual(result.token.value, issuedToken, "The value itself is still usable")
    }

    // MARK: - One socket

    func testCheckWithAProofThenPairReplaceUseTheSameSocket() async throws {
        let server = try await startPairingServer(offer: offerKnowingDeviceFrame)
        let client = makeClient(port: server.port)

        let offer = try await client.check(code: "123456")
        let proof = PairingClient.proof(token: fixedToken, challenge: offer.challenge, code: "123456")
        let known = try await client.check(code: "123456", proof: proof)
        XCTAssertEqual(known.knowsDevice, true)
        XCTAssertTrue(client.isOpen, "The socket stays open between the check and the pair")

        _ = try await client.pair(code: "123456", name: "Hammer's iPhone", kind: .iphone, replace: true)

        XCTAssertEqual(server.acceptedConnectionCount, 1,
                       "The proof binds to the socket that sent it, so the pair must use the same one")
        XCTAssertEqual(texts(of: server).map { wireType($0) }, ["pair_check", "pair_check", "pair"])
        XCTAssertEqual(parseWireJSON(texts(of: server)[1])["proof"] as? String, fixedProof)
        XCTAssertEqual(parseWireJSON(texts(of: server)[2])["replace"] as? Bool, true)
    }

    func testTheClientIsClosedAfterPair() async throws {
        let server = try await startPairingServer()
        let client = makeClient(port: server.port)

        _ = try await client.check(code: "123456")
        XCTAssertTrue(client.isOpen)
        _ = try await client.pair(code: "123456", name: "Phone", kind: .iphone, replace: false)

        XCTAssertFalse(client.isOpen)
    }

    // MARK: - Headers

    func testAPairingSocketCarriesNoAuthorizationAndNoOriginHeader() async throws {
        let server = try await startPairingServer()
        let client = makeClient(port: server.port)

        _ = try await client.check(code: "123456")

        let handshake = try XCTUnwrap(server.handshakes.first)
        XCTAssertNil(handshake.authorization, "A pairing socket is token-less")
        XCTAssertNil(handshake.origin, "The daemon refuses an upgrade that carries an Origin header")
    }

    // MARK: - Failures

    func testARefusedConnectionIsUnreachable() async throws {
        let port = try await TestWebSocketServer.unusedPort()
        let client = makeClient(port: port)

        await assertThrows(.unreachable) { _ = try await client.check(code: "123456") }
        XCTAssertFalse(client.isOpen)
    }

    func testARefusedConnectionIsLocalNetworkDeniedWhenTheProbeSaysSo() async throws {
        let port = try await TestWebSocketServer.unusedPort()
        let probe = FakeLocalNetworkProbe(denied: true)
        let client = makeClient(port: port, probe: probe)

        await assertThrows(.localNetworkDenied) { _ = try await client.check(code: "123456") }
        XCTAssertEqual(probe.calls.first?.port, port)
    }

    func testAServerThatNeverAnswersIsUnreachableAfterTheResponseTimeout() async throws {
        let server = try await startSilentServer()
        let client = makeClient(port: server.port, responseTimeout: 0.3)

        await assertThrows(.unreachable) { _ = try await client.check(code: "123456") }
        XCTAssertFalse(client.isOpen, "A timed-out socket is dropped")
    }

    func testAServerThatClosesBeforeAnsweringIsUnreachable() async throws {
        let server = try await TestWebSocketServer.start(onReady: { $0.close(code: .protocolCode(.normalClosure)) })
        servers.append(server)
        let client = makeClient(port: server.port)

        await assertThrows(.unreachable) { _ = try await client.check(code: "123456") }
    }
}
