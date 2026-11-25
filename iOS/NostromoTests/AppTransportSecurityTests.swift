// L5: App Transport Security applies only inside an app bundle. SwiftPM test binaries have no
// Info.plist, so Kit's L1 tests open sockets that ATS never sees. On iOS 17 and later ATS refuses a
// plain `ws://` connection to an IP address unless the app's Info.plist sets
// `NSAllowsLocalNetworking`; without it every connection fails with error -1022 and the phone says
// "can't reach" forever. These tests run in the hosted app, where ATS applies: an in-process
// listener on loopback (127.0.0.1 and [::1]) is reached by a raw `URLSessionWebSocketTask` and by
// Kit's `WebSocketClient`. They fail if ATS blocks the connection, and this is the only place CI
// can notice.

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
        for host in hosts {
            let url = try XCTUnwrap(URL(string: "ws://\(host):\(server.port)/"))
            let session = URLSession(configuration: .ephemeral)
            let task = session.webSocketTask(with: url)
            task.resume()
            do {
                try await task.send(.string("ats-probe"))
                let message = try await task.receive()
                guard case .string(let text) = message else { return XCTFail("\(host): expected a text frame") }
                XCTAssertEqual(text, "ats-probe", host)
            } catch {
                let code = (error as? URLError)?.code.rawValue ?? (error as NSError).code
                XCTFail("ws:// to \(host) failed (\((error as NSError).domain) \(code)); -1022 means App Transport Security blocked it: \(error)")
            }
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }
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
