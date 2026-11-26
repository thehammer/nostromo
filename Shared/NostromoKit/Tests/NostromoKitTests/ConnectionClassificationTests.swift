// NostromoKit — ConnectionClassificationTests.swift
//
// The table that guards PRD-AC22 / W11-6: how a connection ending becomes what the app is told.
// Only the server saying "you are not paired" (an `Unauthorized` frame, or close code 4001) may
// produce `.notPaired`. A timeout, a refused connection, DNS, TLS, a dropped socket, an HTTP error
// at the upgrade, an ordinary close: all `.unreachable`, however long they last, because none of
// them says anything about the pairing. A Local Network denial is its own state.
//
// Pure tests: no socket is opened.

import XCTest
import Network
@testable import NostromoKit

final class ConnectionClassificationTests: XCTestCase {

    // MARK: - ConnectionFailure.state

    func testAnUnauthorizedFrameIsNotPairedWithTheServersReason() {
        XCTAssertEqual(ConnectionFailure.unauthorizedFrame(reason: "revoked").state, .notPaired(reason: "revoked"))
        XCTAssertEqual(ConnectionFailure.unauthorizedFrame(reason: "unknown").state, .notPaired(reason: "unknown"))
        XCTAssertEqual(ConnectionFailure.unauthorizedFrame(reason: "not_paired").state, .notPaired(reason: "not_paired"))
    }

    func testCloseCode4001IsNotPaired() {
        guard case .notPaired = ConnectionFailure.closed(code: 4001).state else {
            return XCTFail("close code 4001 must be notPaired, got \(ConnectionFailure.closed(code: 4001).state)")
        }
    }

    func testOrdinaryCloseCodesAreUnreachable() {
        for code in [1000, 1001, 1006, 1008, 1009] {
            XCTAssertEqual(ConnectionFailure.closed(code: code).state, .unreachable, "close \(code)")
        }
    }

    func testHttpErrorsAtTheUpgradeAreUnreachable() {
        for status in [401, 403, 429, 500, 502, 503] {
            XCTAssertEqual(ConnectionFailure.httpStatus(status).state, .unreachable, "HTTP \(status)")
        }
    }

    func testTransportFailuresAreUnreachable() {
        let codes: [URLError.Code] = [
            .cannotConnectToHost, .timedOut, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet,
            .networkConnectionLost, .secureConnectionFailed, .serverCertificateUntrusted, .cancelled,
        ]
        for code in codes {
            XCTAssertEqual(ConnectionFailure.transport(code).state, .unreachable, "URLError \(code.rawValue)")
        }
    }

    func testAnythingElseIsUnreachable() {
        XCTAssertEqual(ConnectionFailure.other.state, .unreachable)
    }

    func testALocalNetworkDenialIsItsOwnState() {
        XCTAssertEqual(ConnectionFailure.localNetworkDenied.state, .localNetworkDenied)
    }

    func testNothingButTheServerSayingNotPairedEverProducesNotPaired() {
        var failures: [ConnectionFailure] = [.other, .localNetworkDenied]
        failures += (0...5000).filter { $0 != 4001 }.map { ConnectionFailure.closed(code: $0) }
        failures += (100...599).map { ConnectionFailure.httpStatus($0) }
        failures += (-3000...0).map { ConnectionFailure.transport(URLError.Code(rawValue: $0)) }

        for failure in failures {
            if case .notPaired = failure.state { XCTFail("\(failure) must not be notPaired") }
        }
    }

    // MARK: - WebSocketChannel.failure(for:closeCode:httpStatus:)

    func testCloseCode4001WinsOverAnyError() {
        let failure = WebSocketChannel.failure(for: URLError(.cannotConnectToHost), closeCode: 4001, httpStatus: nil)
        XCTAssertEqual(failure, .closed(code: 4001))
        let withTimeout = WebSocketChannel.failure(for: URLError(.timedOut), closeCode: 4001, httpStatus: 101)
        XCTAssertEqual(withTimeout, .closed(code: 4001))
    }

    func testAnHttpStatusOtherThan101IsAnHttpFailure() {
        XCTAssertEqual(WebSocketChannel.failure(for: URLError(.badServerResponse), closeCode: 0, httpStatus: 500),
                       .httpStatus(500))
        XCTAssertEqual(WebSocketChannel.failure(for: URLError(.userAuthenticationRequired), closeCode: 0, httpStatus: 401),
                       .httpStatus(401))
    }

    func testAURLErrorIsATransportFailure() {
        XCTAssertEqual(WebSocketChannel.failure(for: URLError(.cannotConnectToHost), closeCode: 0, httpStatus: nil),
                       .transport(.cannotConnectToHost))
        XCTAssertEqual(WebSocketChannel.failure(for: URLError(.timedOut), closeCode: 0, httpStatus: nil),
                       .transport(.timedOut))
    }

    func testStatus101IsNotAnHttpFailure() {
        XCTAssertEqual(WebSocketChannel.failure(for: URLError(.networkConnectionLost), closeCode: 0, httpStatus: 101),
                       .transport(.networkConnectionLost))
        XCTAssertEqual(WebSocketChannel.failure(for: NSError(domain: NSPOSIXErrorDomain, code: 57),
                                                closeCode: 0, httpStatus: 101),
                       .other)
    }

    func testAnOrdinaryCloseCodeWithANonURLErrorIsAClose() {
        XCTAssertEqual(WebSocketChannel.failure(for: NSError(domain: NSPOSIXErrorDomain, code: 57),
                                                closeCode: 1001, httpStatus: nil),
                       .closed(code: 1001))
    }

    func testAnUnexplainedErrorIsOther() {
        XCTAssertEqual(WebSocketChannel.failure(for: NSError(domain: "x", code: 1), closeCode: 0, httpStatus: nil), .other)
    }

    // MARK: - NWLocalNetworkProbe.isPolicyDenied

    func testOnlyTheDNSPolicyDeniedErrorIsALocalNetworkDenial() {
        XCTAssertTrue(NWLocalNetworkProbe.isPolicyDenied(.dns(-65570)))
        XCTAssertFalse(NWLocalNetworkProbe.isPolicyDenied(.dns(-65554)))
        XCTAssertFalse(NWLocalNetworkProbe.isPolicyDenied(.posix(.ECONNREFUSED)))
        XCTAssertFalse(NWLocalNetworkProbe.isPolicyDenied(.posix(.ETIMEDOUT)))
    }

    // MARK: - When the probe is asked

    func testADeniedProbeConvertsATransportFailureToLocalNetworkDenied() async {
        let probe = FakeLocalNetworkProbe(denied: true)
        let refined = await probe.refine(.transport(.cannotConnectToHost), host: "192.168.1.5", port: 47101)
        XCTAssertEqual(refined, .localNetworkDenied)
        XCTAssertEqual(probe.calls.count, 1)
        XCTAssertEqual(probe.calls.first?.host, "192.168.1.5")
        XCTAssertEqual(probe.calls.first?.port, 47101)
    }

    func testAProbeThatSaysNotDeniedLeavesTheFailureAlone() async {
        let probe = FakeLocalNetworkProbe(denied: false)
        let refined = await probe.refine(.transport(.timedOut), host: "h", port: 1)
        XCTAssertEqual(refined, .transport(.timedOut))
        XCTAssertEqual(probe.calls.count, 1)
    }

    func testAnswersFromTheServerAreNeitherProbedNorConverted() async {
        let answers: [ConnectionFailure] = [
            .closed(code: 4001),
            .unauthorizedFrame(reason: "revoked"),
            .httpStatus(500),
        ]
        for answer in answers {
            let probe = FakeLocalNetworkProbe(denied: true)
            let refined = await probe.refine(answer, host: "h", port: 1)
            XCTAssertEqual(refined, answer, "\(answer) must survive a denied probe")
            XCTAssertEqual(probe.calls.count, 0, "\(answer) means the server answered, so the probe is not asked")
        }
    }
}
