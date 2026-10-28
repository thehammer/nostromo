// NostromoKit — SessionBridgeWireTests.swift
//
// The "tools offline" health signal as the Kit sees it.
//
// A session whose `nostromo-mcp-bridge` lost its connection to the daemon keeps
// running but cannot call any `mcp__nostromo__*` tool. The daemon says so two
// ways, both additive so an older daemon or app is unaffected:
//
//   * `session_list_resp` entries carry `mcp_bridge_connected` once a bridge has
//     identified as that tag, and omit it otherwise;
//   * `session_bridge {tag, connected}` is sent on every change.
//
// The Kit's job: decode both, keep the flag on `DaemonStore.sessions[tag]`, and
// never read "no information" as "offline".
//
// The store tests push `ServerMsg` values through a never-started
// `NetworkClient`, the same technique as `DaemonStoreTests`.

import XCTest
@testable import NostromoKit

final class SessionBridgeWireTests: XCTestCase {

    // MARK: - Helpers

    /// One `session_list_resp` entry. `bridge` is a raw JSON literal for
    /// `mcp_bridge_connected`; `nil` leaves the key out entirely.
    private func entry(_ tag: String, bridge: String?) -> String {
        let key = bridge.map { #","mcp_bridge_connected":\#($0)"# } ?? ""
        return #"{"tag":"\#(tag)","agent_name":"cody","view_name":"v-\#(tag)","session_id":"sid-\#(tag)","alive":true,"remote_control":false,"state":"idle"\#(key)}"#
    }

    private func decodeList(_ entries: [String]) -> [SessionInfo] {
        let json = #"{"type":"session_list_resp","sessions":[\#(entries.joined(separator: ","))]}"#
        guard case let .sessionListResp(list) = ServerMsg.decode(from: Data(json.utf8)) else {
            XCTFail("expected .sessionListResp for \(json)")
            return []
        }
        return list
    }

    private func deliver(_ msg: ServerMsg, via client: NetworkClient) async {
        await client.messages.send(msg)
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    /// A store holding `cody-a` (bridge unknown) and `cody-b` (bridge connected).
    private func makeStore() async -> (NetworkClient, DaemonStore) {
        let client = await NetworkClient()
        let store  = await DaemonStore(client: client)
        let list   = decodeList([
            entry("cody-a", bridge: nil),
            entry("cody-b", bridge: "true"),
        ])
        await deliver(.sessionListResp(list), via: client)
        return (client, store)
    }

    // MARK: - Wire: SessionInfo

    func testSessionInfoDecodesABridgeThatIsConnected() {
        let list = decodeList([entry("cody-a", bridge: "true")])
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.mcpBridgeConnected, true)
    }

    func testSessionInfoDecodesABridgeThatIsLost() {
        let list = decodeList([entry("cody-a", bridge: "false")])
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.mcpBridgeConnected, false)
    }

    func testSessionInfoWithoutTheKeyDecodesAsUnknownNotOffline() {
        let list = decodeList([entry("cody-a", bridge: nil)])
        XCTAssertEqual(list.count, 1, "a frame from a daemon that predates the signal must still decode")
        XCTAssertNil(list.first?.mcpBridgeConnected)
    }

    func testSessionInfoWithAnExplicitNullDecodesAsUnknown() {
        let list = decodeList([entry("cody-a", bridge: "null")])
        XCTAssertEqual(list.count, 1)
        XCTAssertNil(list.first?.mcpBridgeConnected)
    }

    func testEachSessionInAListKeepsItsOwnBridgeState() {
        let list = decodeList([
            entry("cody-a", bridge: nil),
            entry("cody-b", bridge: "true"),
            entry("cody-c", bridge: "false"),
        ])
        XCTAssertEqual(list.count, 3)
        XCTAssertNil(list.first(where: { $0.tag == "cody-a" })?.mcpBridgeConnected)
        XCTAssertEqual(list.first(where: { $0.tag == "cody-b" })?.mcpBridgeConnected, true)
        XCTAssertEqual(list.first(where: { $0.tag == "cody-c" })?.mcpBridgeConnected, false)
    }

    // MARK: - Wire: session_bridge

    func testSessionBridgeFrameDecodesConnected() {
        let msg = ServerMsg.decode(from: Data(#"{"type":"session_bridge","tag":"cody-a","connected":true}"#.utf8))
        guard case let .sessionBridge(tag, connected) = msg else { return XCTFail("expected .sessionBridge, got \(msg)") }
        XCTAssertEqual(tag, "cody-a")
        XCTAssertTrue(connected)
    }

    func testSessionBridgeFrameDecodesLost() {
        let msg = ServerMsg.decode(from: Data(#"{"type":"session_bridge","tag":"cody-a","connected":false}"#.utf8))
        guard case let .sessionBridge(tag, connected) = msg else { return XCTFail("expected .sessionBridge, got \(msg)") }
        XCTAssertEqual(tag, "cody-a")
        XCTAssertFalse(connected)
    }

    func testSessionBridgeFrameMissingItsFieldsIsNotMistakenForAnyState() {
        // Malformed: no `connected`. It must not decode as "connected" or "lost".
        let msg = ServerMsg.decode(from: Data(#"{"type":"session_bridge","tag":"cody-a"}"#.utf8))
        if case .sessionBridge = msg { XCTFail("a session_bridge without `connected` must not decode as a bridge state") }
    }

    // MARK: - DaemonStore

    func testStoreHoldsTheBridgeStateFromTheSessionList() async {
        let (_, store) = await makeStore()
        let a = await store.sessions["cody-a"]?.mcpBridgeConnected
        let b = await store.sessions["cody-b"]?.mcpBridgeConnected
        XCTAssertNil(a, "no bridge ever reported: unknown")
        XCTAssertEqual(b, true)
    }

    func testStoreMarksAKnownSessionsBridgeLostThenBackOnline() async {
        let (client, store) = await makeStore()

        await deliver(.sessionBridge(tag: "cody-b", connected: false), via: client)
        let lost = await store.sessions["cody-b"]?.mcpBridgeConnected
        XCTAssertEqual(lost, false)

        await deliver(.sessionBridge(tag: "cody-b", connected: true), via: client)
        let back = await store.sessions["cody-b"]?.mcpBridgeConnected
        XCTAssertEqual(back, true)
    }

    func testStoreRecordsABridgeForASessionThatHadNoStateYet() async {
        let (client, store) = await makeStore()
        await deliver(.sessionBridge(tag: "cody-a", connected: true), via: client)
        let a = await store.sessions["cody-a"]?.mcpBridgeConnected
        XCTAssertEqual(a, true)
    }

    func testStoreChangesOnlyTheNamedSessionsBridge() async {
        let (client, store) = await makeStore()
        await deliver(.sessionBridge(tag: "cody-b", connected: false), via: client)

        let a = await store.sessions["cody-a"]?.mcpBridgeConnected
        XCTAssertNil(a, "another session's bridge must not change")
        let other = await store.sessions["cody-b"]
        XCTAssertEqual(other?.tag, "cody-b")
        XCTAssertEqual(other?.agentName, "cody", "only the bridge flag changes")
        XCTAssertEqual(other?.alive, true)
        XCTAssertEqual(other?.state, .idle)
    }

    func testStoreIgnoresABridgeForATagItHoldsNoSessionFor() async {
        let (client, store) = await makeStore()
        await deliver(.sessionBridge(tag: "ghost", connected: false), via: client)

        let ghost = await store.sessions["ghost"]
        XCTAssertNil(ghost, "a bridge frame must not invent a session")
        let count = await store.sessions.count
        XCTAssertEqual(count, 2)
    }

    func testBridgeStateSurvivesSessionStateChanges() async {
        let (client, store) = await makeStore()
        await deliver(.sessionBridge(tag: "cody-b", connected: false), via: client)

        await deliver(.sessionState(tag: "cody-b", state: .midTurn), via: client)
        let midTurn = await store.sessions["cody-b"]
        XCTAssertEqual(midTurn?.state, .midTurn)
        XCTAssertEqual(midTurn?.mcpBridgeConnected, false)

        await deliver(.sessionState(tag: "cody-b", state: .crashed), via: client)
        let crashed = await store.sessions["cody-b"]
        XCTAssertEqual(crashed?.state, .crashed)
        XCTAssertEqual(crashed?.mcpBridgeConnected, false)
    }

    func testBridgeStateSurvivesASessionGoingDownOrExiting() async {
        let (client, store) = await makeStore()

        await deliver(.sessionDown(tag: "cody-b", reason: .user), via: client)
        let down = await store.sessions["cody-b"]
        XCTAssertEqual(down?.alive, false)
        XCTAssertEqual(down?.mcpBridgeConnected, true)

        await deliver(.sessionBridge(tag: "cody-a", connected: false), via: client)
        await deliver(.sessionExited(tag: "cody-a", exitCode: 0), via: client)
        let exited = await store.sessions["cody-a"]
        XCTAssertEqual(exited?.alive, false)
        XCTAssertEqual(exited?.mcpBridgeConnected, false)
    }

    func testBridgeStateSurvivesASessionBeingSpawnedAgain() async {
        let (client, store) = await makeStore()
        await deliver(.sessionBridge(tag: "cody-b", connected: false), via: client)

        await deliver(.sessionSpawned(tag: "cody-b", sessionId: "sid-new"), via: client)
        let spawned = await store.sessions["cody-b"]
        XCTAssertEqual(spawned?.sessionId, "sid-new")
        XCTAssertEqual(spawned?.alive, true)
        XCTAssertEqual(spawned?.mcpBridgeConnected, false)
    }

    func testAFreshSessionListReplacesTheBridgeState() async {
        let (client, store) = await makeStore()
        await deliver(.sessionBridge(tag: "cody-b", connected: false), via: client)

        // The daemon's list is the truth: it now says cody-b's bridge is back.
        let list = decodeList([entry("cody-b", bridge: "true")])
        await deliver(.sessionListResp(list), via: client)
        let b = await store.sessions["cody-b"]?.mcpBridgeConnected
        XCTAssertEqual(b, true)
    }
}
