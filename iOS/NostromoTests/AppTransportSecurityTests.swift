// L5: App Transport Security applies only inside an app bundle. SwiftPM test binaries have no
// Info.plist, so Kit's L1 tests open sockets that ATS never sees. On iOS 17 and later ATS refuses a
// plain `ws://` connection to an IP address unless the app's Info.plist sets
// `NSAllowsLocalNetworking`; without it every connection fails with error -1022 and the phone says
// "can't reach" forever. These tests run in the hosted app, where ATS applies: an in-process
// listener on loopback (127.0.0.1 and [::1]) and on this machine's own LAN address is reached by a
// raw `URLSessionWebSocketTask`, Kit's `WebSocketClient` and `PairingClient`. They fail if ATS blocks
// the connection. Measured limit: on the Simulator these connections also succeed with
// `NSAllowsLocalNetworking` set to false, so only `testTheBuiltInfoPlistAllowsLocalNetworking...`
// guards the key itself; whether a device is blocked is a manual check.

import XCTest
import NostromoKit

private struct NeverDenied: LocalNetworkProbing {
    func isDenied(host: String, port: UInt16) async -> Bool { false }
}

@MainActor
final class AppTransportSecurityTests: XCTestCase {

    private let hosts = ["127.0.0.1", "[::1]"]
    private let credential = DeviceCredential(token: "tok-ats-l5", deviceId: "dev-ats", serverId: "srv-ats", name: "iPhone")

    func testTheBuiltInfoPlistAllowsLocalNetworkingAndNeverArbitraryLoads() throws {
        let ats = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any],
                                "the app's Info.plist has no NSAppTransportSecurity")
        XCTAssertEqual(ats["NSAllowsLocalNetworking"] as? Bool, true)
        XCTAssertNotEqual(ats["NSAllowsArbitraryLoads"] as? Bool, true)
        XCTAssertNil(ats["NSExceptionDomains"])
    }

    func testAURLSessionWebSocketReachesLoopbackOverPlainWSOnIPv4AndIPv6() async throws {
        let server = try await LoopbackWebSocketServer.start()
        defer { server.stop() }
        for host in hosts { await assertPlainWSEchoes(host: host, port: server.port) }
    }

    /// Loopback may be exempt from ATS; a LAN address (an IP literal that is not loopback, as a WireGuard
    /// address is) is what the phone really connects to, so this is the case that can fail.
    func testAURLSessionWebSocketReachesThisMachinesLANAddressOverPlainWS() async throws {
        let host = try XCTUnwrap(firstNonLoopbackIPv4(), "this machine has no non-loopback IPv4 address to connect to")
        let server = try await LoopbackWebSocketServer.start(loopbackOnly: false)
        defer { server.stop() }
        await assertPlainWSEchoes(host: host, port: server.port)
    }

    private func assertPlainWSEchoes(host: String, port: UInt16, file: StaticString = #filePath, line: UInt = #line) async {
        guard let url = URL(string: "ws://\(host):\(port)/") else { return XCTFail("bad URL for \(host)", file: file, line: line) }
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        task.resume()
        do {
            try await task.send(.string("ats-probe"))
            let message = try await task.receive()
            guard case .string(let text) = message else { return XCTFail("\(host): expected a text frame", file: file, line: line) }
            XCTAssertEqual(text, "ats-probe", host, file: file, line: line)
        } catch {
            let code = (error as? URLError)?.code.rawValue ?? (error as NSError).code
            XCTFail("ws:// to \(host) failed (\((error as NSError).domain) \(code)); -1022 means App Transport Security blocked it: \(error)",
                    file: file, line: line)
        }
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    func testTheAppsWebSocketClientConnectsToLoopbackOnIPv4AndIPv6() async throws {
        let server = try await LoopbackWebSocketServer.start(
            greeting: #"{"type":"welcome","protocol_version":4,"daemon_pid":1}"#, reply: { _ in nil })
        defer { server.stop() }
        for host in hosts {
            let client = WebSocketClient(host: host, port: server.port, credential: credential, probe: NeverDenied(),
                                         initialBackoff: 0.2, maxBackoff: 0.5, handshakeTimeout: 5)
            client.start()
            let connected = await waitUntil { client.state == .connected }
            XCTAssertTrue(connected, "WebSocketClient to \(host) ended in \(client.state); unreachable here means ATS blocked it")
            client.stop()
        }
        XCTAssertGreaterThanOrEqual(server.acceptedCount, hosts.count)
    }

    func testTheAppsWebSocketClientConnectsToThisMachinesLANAddress() async throws {
        let host = try XCTUnwrap(firstNonLoopbackIPv4(), "this machine has no non-loopback IPv4 address to connect to")
        let server = try await LoopbackWebSocketServer.start(
            greeting: #"{"type":"welcome","protocol_version":4,"daemon_pid":1}"#, loopbackOnly: false, reply: { _ in nil })
        defer { server.stop() }
        let client = WebSocketClient(host: host, port: server.port, credential: credential, probe: NeverDenied(),
                                     initialBackoff: 0.2, maxBackoff: 0.5, handshakeTimeout: 5)
        client.start()
        let connected = await waitUntil { client.state == .connected }
        XCTAssertTrue(connected, "WebSocketClient to \(host) ended in \(client.state); unreachable here means ATS blocked it")
        client.stop()
    }

    func testAPairingSocketReachesLoopbackOnIPv4AndIPv6() async throws {
        let offer = #"{"type":"pair_offer","name_hint":"Loopback","server_id":"srv-ats","challenge":"c"}"#
        let server = try await LoopbackWebSocketServer.start(reply: { _ in offer })
        defer { server.stop() }
        for host in hosts {
            let pairing = PairingClient(host: host, port: server.port, probe: NeverDenied(), responseTimeout: 5)
            let answer = try await pairing.check(code: "123456")
            XCTAssertEqual(answer.serverId, "srv-ats", host)
            pairing.close()
        }
    }
}
