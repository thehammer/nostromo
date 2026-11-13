// NostromoKit — FocusActivityWireTests.swift
//
// The focus-activity counters as the Kit sees them (slice B of the focus unread indicator).
//
// The daemon adds, per session in `session_list_resp`, optional fields: `agent_turns`,
// `agent_messages`, `agent_problems` (u64 counters), `activity_epoch` (string) and `last_problem`
// (snake_case kind). The Kit's job:
//   * decode them into `SessionInfo`, tolerating every way they can be absent or wrong (an older
//     daemon, a newer one with a kind we do not know): a bad value is `nil` and NEVER costs the entry
//     or the list;
//   * expose them as one value (`SessionInfo.activity`) only when the epoch and all three counters
//     are there;
//   * keep them on `DaemonStore.sessions[tag]` across EVERY message that rebuilds a `SessionInfo`
//     (`sessionState`, `sessionDown`, `sessionExited`, `sessionBridge`, `sessionSpawned`).
//
// Mutation 5 (the store drops the counters on `sessionState`) is caught by
// `testCountersSurviveASessionStateChange` and, for the other four, by the sibling tests below.
//
// The store tests push `ServerMsg` values through a never-started `NetworkClient`, the same
// technique as `SessionBridgeWireTests`.

import XCTest
@testable import NostromoKit

final class FocusActivityWireTests: XCTestCase {

    // MARK: - Helpers

    /// One `session_list_resp` entry. `extra` is raw JSON appended inside the object, e.g.
    /// `"agent_turns":12`; a comma is added for you.
    private func entry(_ tag: String, state: String = "idle", extra: [String] = []) -> String {
        let more = extra.isEmpty ? "" : "," + extra.joined(separator: ",")
        return #"{"tag":"\#(tag)","agent_name":"cody","view_name":"v-\#(tag)","session_id":"sid-\#(tag)","alive":true,"remote_control":false,"state":"\#(state)"\#(more)}"#
    }

    private static let fullFields = [
        #""agent_turns":12"#, #""agent_messages":7"#, #""agent_problems":3"#,
        #""activity_epoch":"epoch-1""#, #""last_problem":"no_text""#,
    ]

    private func decodeList(_ entries: [String], file: StaticString = #filePath, line: UInt = #line) -> [SessionInfo] {
        let json = #"{"type":"session_list_resp","sessions":[\#(entries.joined(separator: ","))]}"#
        guard case let .sessionListResp(list) = ServerMsg.decode(from: Data(json.utf8)) else {
            XCTFail("expected .sessionListResp for \(json)", file: file, line: line)
            return []
        }
        return list
    }

    private func deliver(_ msg: ServerMsg, via client: NetworkClient) async {
        await client.messages.send(msg)
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    // MARK: - ProblemKind

    private struct KindBox: Decodable { let kind: ProblemKind }

    private func decodeKind(_ literal: String) throws -> ProblemKind {
        try JSONDecoder().decode(KindBox.self, from: Data(#"{"kind":\#(literal)}"#.utf8)).kind
    }

    func testEveryKnownProblemKindDecodesFromItsSnakeCaseName() throws {
        let table: [(String, ProblemKind)] = [
            ("crashed", .crashed), ("stopped", .stopped), ("crash_loop_guard", .crashLoopGuard),
            ("turn_error", .turnError), ("api_error", .apiError), ("rate_limited", .rateLimited),
            ("login_hold", .loginHold), ("send_refused", .sendRefused), ("no_text", .noText),
        ]
        for (name, kind) in table {
            XCTAssertEqual(try decodeKind("\"\(name)\""), kind, name)
        }
    }

    func testAnUnknownProblemKindIsToleratedAsUnknownNeverAnError() throws {
        XCTAssertEqual(try decodeKind(#""brand_new_kind""#), .unknown)
        XCTAssertEqual(try decodeKind(#""""#), .unknown)
        XCTAssertEqual(try decodeKind(#""CRASHED""#), .unknown, "kinds are case-sensitive snake_case; anything else is unknown")
        XCTAssertEqual(try decodeKind("42"), .unknown, "a non-string value never throws")
        XCTAssertEqual(try decodeKind("true"), .unknown)
        XCTAssertEqual(try decodeKind(#"{"a":1}"#), .unknown)
        XCTAssertEqual(try decodeKind("[1,2]"), .unknown)
    }

    // MARK: - SessionInfo decoding

    func testAFullEntryDecodesEveryActivityField() {
        let list = decodeList([entry("cody-a", extra: Self.fullFields)])
        XCTAssertEqual(list.count, 1)
        let info = list[0]
        XCTAssertEqual(info.agentTurns, 12)
        XCTAssertEqual(info.agentMessages, 7)
        XCTAssertEqual(info.agentProblems, 3)
        XCTAssertEqual(info.activityEpoch, "epoch-1")
        XCTAssertEqual(info.lastProblem, .noText)
        XCTAssertEqual(info.activity,
                       FocusActivityCounters(epoch: "epoch-1", turns: 12, messages: 7, problems: 3, lastProblem: .noText))
        // The rest of the entry is untouched.
        XCTAssertEqual(info.tag, "cody-a")
        XCTAssertEqual(info.agentName, "cody")
        XCTAssertEqual(info.state, .idle)
        XCTAssertTrue(info.alive)
    }

    func testAnOlderDaemonsEntryWithNoActivityFieldsDecodesAsAllNil() {
        let list = decodeList([entry("cody-a")])
        XCTAssertEqual(list.count, 1, "a frame from a daemon that predates the counters must still decode")
        let info = list[0]
        XCTAssertNil(info.agentTurns)
        XCTAssertNil(info.agentMessages)
        XCTAssertNil(info.agentProblems)
        XCTAssertNil(info.activityEpoch)
        XCTAssertNil(info.lastProblem)
        XCTAssertNil(info.activity)
    }

    func testCountersAboveInt32AndBeyondDoublePrecisionDecodeExactly() {
        let list = decodeList([entry("cody-a", extra: [
            #""agent_turns":5000000000"#, #""agent_messages":9007199254740993"#, #""agent_problems":4294967296"#,
            #""activity_epoch":"e""#,
        ])])
        XCTAssertEqual(list.first?.agentTurns, 5_000_000_000)
        XCTAssertEqual(list.first?.agentMessages, 9_007_199_254_740_993, "a u64 must not pass through a Double")
        XCTAssertEqual(list.first?.agentProblems, 4_294_967_296)
    }

    func testZeroCountersAreRealValuesNotAbsence() {
        let list = decodeList([entry("cody-a", extra: [
            #""agent_turns":0"#, #""agent_messages":0"#, #""agent_problems":0"#, #""activity_epoch":"e""#,
        ])])
        XCTAssertEqual(list.first?.activity, FocusActivityCounters(epoch: "e", turns: 0, messages: 0, problems: 0))
    }

    /// Each way one counter can be wrong costs only that counter: the entry, its neighbours and the list survive.
    func testABadCounterIsNilWithoutFailingTheEntryOrTheList() {
        let badValues = ["null", #""5""#, "true", "false", "-1", "1.5", "[1]", #"{"n":1}"#, #""""#]
        for bad in badValues {
            for key in ["agent_turns", "agent_messages", "agent_problems"] {
                var fields = Self.fullFields.filter { !$0.hasPrefix("\"\(key)\"") }
                fields.append("\"\(key)\":\(bad)")
                let list = decodeList([
                    entry("cody-a", extra: fields),
                    entry("cody-b", extra: Self.fullFields),
                ])
                XCTAssertEqual(list.count, 2, "\(key)=\(bad) must not drop the list")
                let a = list.first { $0.tag == "cody-a" }
                XCTAssertNotNil(a, "\(key)=\(bad) must not drop the entry")
                XCTAssertNil(a?.activity, "\(key)=\(bad): a counter that is not usable means no counters")
                let readings: [String: UInt64?] = ["agent_turns": a?.agentTurns, "agent_messages": a?.agentMessages,
                                                   "agent_problems": a?.agentProblems]
                let value: UInt64? = readings[key] ?? nil
                XCTAssertNil(value, "\(key)=\(bad) decodes as nil")
                // Its neighbours keep their values.
                if key != "agent_turns" { XCTAssertEqual(a?.agentTurns, 12, "\(key)=\(bad)") }
                if key != "agent_messages" { XCTAssertEqual(a?.agentMessages, 7, "\(key)=\(bad)") }
                if key != "agent_problems" { XCTAssertEqual(a?.agentProblems, 3, "\(key)=\(bad)") }
                XCTAssertEqual(a?.activityEpoch, "epoch-1")
                XCTAssertEqual(a?.state, .idle)
                // The other entry is entirely untouched.
                XCTAssertNotNil(list.first { $0.tag == "cody-b" }?.activity)
            }
        }
    }

    func testABadEpochIsNilWithoutFailingTheEntryOrTheList() {
        for bad in ["null", "5", "true", "[\"e\"]", #"{"e":1}"#] {
            let fields = Self.fullFields.filter { !$0.hasPrefix("\"activity_epoch\"") } + ["\"activity_epoch\":\(bad)"]
            let list = decodeList([entry("cody-a", extra: fields), entry("cody-b", extra: Self.fullFields)])
            XCTAssertEqual(list.count, 2, "epoch=\(bad)")
            XCTAssertNil(list.first { $0.tag == "cody-a" }?.activityEpoch, "epoch=\(bad)")
            XCTAssertNil(list.first { $0.tag == "cody-a" }?.activity, "no epoch means no counters: \(bad)")
            XCTAssertEqual(list.first { $0.tag == "cody-a" }?.agentTurns, 12)
            XCTAssertNotNil(list.first { $0.tag == "cody-b" }?.activity)
        }
    }

    func testAnUnknownLastProblemStringDecodesAsUnknownAndKeepsTheCounters() {
        let fields = Self.fullFields.filter { !$0.hasPrefix("\"last_problem\"") } + [#""last_problem":"something_new""#]
        let list = decodeList([entry("cody-a", extra: fields)])
        XCTAssertEqual(list.first?.lastProblem, .unknown)
        XCTAssertEqual(list.first?.activity?.lastProblem, .unknown)
        XCTAssertEqual(list.first?.agentProblems, 3)
    }

    func testANonStringLastProblemNeverFailsTheEntryAndNeverInventsAKnownKind() {
        // The spec allows either nil or .unknown for a wrong-typed value; it must not throw or guess.
        for bad in ["5", "true", "[]", #"{"k":1}"#, "null"] {
            let fields = Self.fullFields.filter { !$0.hasPrefix("\"last_problem\"") } + ["\"last_problem\":\(bad)"]
            let list = decodeList([entry("cody-a", extra: fields), entry("cody-b", extra: Self.fullFields)])
            XCTAssertEqual(list.count, 2, "last_problem=\(bad)")
            let last = list.first { $0.tag == "cody-a" }?.lastProblem
            XCTAssertTrue(last == nil || last == .unknown, "last_problem=\(bad) decoded as \(String(describing: last))")
            XCTAssertEqual(list.first { $0.tag == "cody-a" }?.agentTurns, 12, "counters survive last_problem=\(bad)")
            XCTAssertNotNil(list.first { $0.tag == "cody-a" }?.activity)
        }
    }

    func testLastProblemAbsentGivesNilAndStillAFullActivityValue() {
        let fields = Self.fullFields.filter { !$0.hasPrefix("\"last_problem\"") }
        let info = decodeList([entry("cody-a", extra: fields)]).first
        XCTAssertNil(info?.lastProblem)
        XCTAssertEqual(info?.activity, FocusActivityCounters(epoch: "epoch-1", turns: 12, messages: 7, problems: 3))
    }

    func testActivityIsNilUnlessTheEpochAndAllThreeCountersArePresent() {
        let keys = ["agent_turns", "agent_messages", "agent_problems", "activity_epoch"]
        for missing in keys {
            let fields = Self.fullFields.filter { !$0.hasPrefix("\"\(missing)\"") }
            let info = decodeList([entry("cody-a", extra: fields)]).first
            XCTAssertNotNil(info, "missing \(missing)")
            XCTAssertNil(info?.activity, "\(missing) absent: not enough to compare anything")
        }
    }

    func testEachEntryInAListKeepsItsOwnCounters() {
        let list = decodeList([
            entry("cody-a", extra: [#""agent_turns":1"#, #""agent_messages":2"#, #""agent_problems":3"#, #""activity_epoch":"ea""#]),
            entry("cody-b", extra: [#""agent_turns":10"#, #""agent_messages":20"#, #""agent_problems":30"#, #""activity_epoch":"eb""#]),
            entry("cody-c"),
        ])
        XCTAssertEqual(list.first { $0.tag == "cody-a" }?.activity, FocusActivityCounters(epoch: "ea", turns: 1, messages: 2, problems: 3))
        XCTAssertEqual(list.first { $0.tag == "cody-b" }?.activity, FocusActivityCounters(epoch: "eb", turns: 10, messages: 20, problems: 30))
        XCTAssertNil(list.first { $0.tag == "cody-c" }?.activity)
    }

    func testTheSharedFixtureFrameDecodes() throws {
        // …/Shared/NostromoKit/Tests/NostromoKitTests/<this file> -> repo root is five levels up.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 5 { url.deleteLastPathComponent() }
        url.appendPathComponent("tests/fixtures/focus_activity/frame-session-list-with-activity.json")
        let data = try Data(contentsOf: url)
        guard case let .sessionListResp(list) = ServerMsg.decode(from: data) else {
            return XCTFail("the daemon's own fixture frame must decode as .sessionListResp")
        }
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].tag, "cody-fixture")
        XCTAssertEqual(list[0].activity,
                       FocusActivityCounters(epoch: "0b6c1c1e-3f0a-4d7e-8f21-6a1b2c3d4e5f", turns: 12, messages: 7, problems: 3,
                                             lastProblem: .noText))
    }

    func testTheInternalInitDefaultsTheFiveNewFieldsToNil() {
        let info = SessionInfo(tag: "t", agentName: "cody", viewName: "v", sessionId: nil, alive: true,
                               remoteControl: false, state: .idle, stopReason: nil, mcpBridgeConnected: nil)
        XCTAssertNil(info.agentTurns)
        XCTAssertNil(info.agentMessages)
        XCTAssertNil(info.agentProblems)
        XCTAssertNil(info.activityEpoch)
        XCTAssertNil(info.lastProblem)
        XCTAssertNil(info.activity)
    }

    // MARK: - The value types

    func testSeenMarksFromCountersCopiesTheEpochAndCountersAndNotTheProblemKind() {
        let c = FocusActivityCounters(epoch: "e", turns: 5, messages: 4, problems: 3, lastProblem: .crashed)
        XCTAssertEqual(FocusSeenMarks(c), FocusSeenMarks(epoch: "e", turns: 5, messages: 4, problems: 3))
        XCTAssertNotEqual(FocusSeenMarks(c), FocusSeenMarks(epoch: "other", turns: 5, messages: 4, problems: 3))
        XCTAssertNotEqual(FocusSeenMarks(c), FocusSeenMarks(epoch: "e", turns: 6, messages: 4, problems: 3))
        XCTAssertNotEqual(FocusSeenMarks(c), FocusSeenMarks(epoch: "e", turns: 5, messages: 5, problems: 3))
        XCTAssertNotEqual(FocusSeenMarks(c), FocusSeenMarks(epoch: "e", turns: 5, messages: 4, problems: 4))
    }

    // MARK: - SessionActivityEntry (what the Mac reads from each entry)

    private func decodeEntry(_ json: String) throws -> SessionActivityEntry {
        try JSONDecoder().decode(SessionActivityEntry.self, from: Data(json.utf8))
    }

    func testAnActivityEntryReadsTheTagAndCounters() throws {
        let e = try decodeEntry(entry("cody-a", extra: Self.fullFields))
        XCTAssertEqual(e, SessionActivityEntry(
            tag: "cody-a",
            activity: FocusActivityCounters(epoch: "epoch-1", turns: 12, messages: 7, problems: 3, lastProblem: .noText)))
    }

    func testAnActivityEntryIgnoresEveryOtherKeyEvenAnUnknownStateAndAKindWeDoNotKnow() throws {
        let e = try decodeEntry(entry("cody-a", state: "a_state_from_the_future", extra: [
            #""agent_turns":1"#, #""agent_messages":0"#, #""agent_problems":0"#, #""activity_epoch":"e""#,
            #""last_problem":"never_heard_of_it""#, #""some_new_key":{"x":[1,2,3]}"#,
        ]))
        XCTAssertEqual(e.tag, "cody-a")
        XCTAssertEqual(e.activity, FocusActivityCounters(epoch: "e", turns: 1, messages: 0, problems: 0, lastProblem: .unknown))
    }

    func testAnActivityEntryWithMissingOrNullOrBadCountersHasNoActivityButKeepsItsTag() throws {
        let cases: [[String]] = [
            [],
            [#""activity_epoch":"e""#],
            [#""agent_turns":1"#, #""agent_messages":1"#, #""agent_problems":1"#],
            [#""agent_turns":null"#, #""agent_messages":1"#, #""agent_problems":1"#, #""activity_epoch":"e""#],
            [#""agent_turns":1"#, #""agent_messages":"1""#, #""agent_problems":1"#, #""activity_epoch":"e""#],
            [#""agent_turns":1"#, #""agent_messages":1"#, #""agent_problems":-4"#, #""activity_epoch":"e""#],
            [#""agent_turns":1"#, #""agent_messages":1"#, #""agent_problems":1"#, #""activity_epoch":7"#],
        ]
        for fields in cases {
            let e = try decodeEntry(entry("cody-a", extra: fields))
            XCTAssertEqual(e.tag, "cody-a", "\(fields)")
            XCTAssertNil(e.activity, "\(fields)")
        }
    }

    // MARK: - DaemonStore keeps the counters

    private let counters = [
        #""agent_turns":12"#, #""agent_messages":7"#, #""agent_problems":3"#,
        #""activity_epoch":"epoch-1""#, #""last_problem":"rate_limited""#,
    ]
    private let expected = FocusActivityCounters(epoch: "epoch-1", turns: 12, messages: 7, problems: 3, lastProblem: .rateLimited)

    /// A store holding `cody-a` with counters and `cody-b` without (an older daemon's entry).
    private func makeStore() async -> (NetworkClient, DaemonStore) {
        let client = await NetworkClient()
        let store  = await DaemonStore(client: client)
        let list   = decodeList([entry("cody-a", extra: counters), entry("cody-b")])
        await deliver(.sessionListResp(list), via: client)
        return (client, store)
    }

    func testStoreHoldsTheCountersFromTheSessionList() async {
        let (_, store) = await makeStore()
        let a = await store.sessions["cody-a"]
        XCTAssertEqual(a?.activity, expected)
        let b = await store.sessions["cody-b"]
        XCTAssertNil(b?.activity)
    }

    func testCountersSurviveASessionStateChange() async {
        let (client, store) = await makeStore()
        for state in [SessionState.midTurn, .awaitingPermission, .crashed, .idle] {
            await deliver(.sessionState(tag: "cody-a", state: state), via: client)
            let a = await store.sessions["cody-a"]
            XCTAssertEqual(a?.state, state)
            XCTAssertEqual(a?.activity, expected, "counters lost on sessionState(\(state))")
            XCTAssertEqual(a?.agentTurns, 12)
            XCTAssertEqual(a?.agentMessages, 7)
            XCTAssertEqual(a?.agentProblems, 3)
            XCTAssertEqual(a?.activityEpoch, "epoch-1")
            XCTAssertEqual(a?.lastProblem, .rateLimited)
        }
    }

    func testCountersSurviveASessionGoingDown() async {
        let (client, store) = await makeStore()
        await deliver(.sessionDown(tag: "cody-a", reason: .user), via: client)
        let a = await store.sessions["cody-a"]
        XCTAssertEqual(a?.alive, false)
        XCTAssertEqual(a?.activity, expected, "counters lost on sessionDown")
        XCTAssertEqual(a?.lastProblem, .rateLimited)
    }

    func testCountersSurviveASessionExiting() async {
        let (client, store) = await makeStore()
        await deliver(.sessionExited(tag: "cody-a", exitCode: 1), via: client)
        let a = await store.sessions["cody-a"]
        XCTAssertEqual(a?.alive, false)
        XCTAssertEqual(a?.activity, expected, "counters lost on sessionExited")
        XCTAssertEqual(a?.lastProblem, .rateLimited)
    }

    func testCountersSurviveABridgeChange() async {
        let (client, store) = await makeStore()
        await deliver(.sessionBridge(tag: "cody-a", connected: false), via: client)
        let a = await store.sessions["cody-a"]
        XCTAssertEqual(a?.mcpBridgeConnected, false)
        XCTAssertEqual(a?.activity, expected, "counters lost on sessionBridge")
        XCTAssertEqual(a?.lastProblem, .rateLimited)
    }

    func testCountersSurviveASessionBeingSpawnedAgain() async {
        let (client, store) = await makeStore()
        await deliver(.sessionSpawned(tag: "cody-a", sessionId: "sid-new"), via: client)
        let a = await store.sessions["cody-a"]
        XCTAssertEqual(a?.sessionId, "sid-new")
        XCTAssertEqual(a?.activity, expected, "counters lost on sessionSpawned")
        XCTAssertEqual(a?.lastProblem, .rateLimited)
    }

    func testAMessageForOneSessionNeverTouchesAnothersCounters() async {
        let (client, store) = await makeStore()
        await deliver(.sessionState(tag: "cody-b", state: .midTurn), via: client)
        let a = await store.sessions["cody-a"]
        XCTAssertEqual(a?.activity, expected)
        let b = await store.sessions["cody-b"]
        XCTAssertNil(b?.activity, "a session that never had counters does not gain any")
    }

    func testAFreshSessionListReplacesTheCountersTheDaemonIsTheTruth() async {
        let (client, store) = await makeStore()
        let list = decodeList([entry("cody-a", extra: [
            #""agent_turns":20"#, #""agent_messages":9"#, #""agent_problems":3"#, #""activity_epoch":"epoch-2""#,
        ])])
        await deliver(.sessionListResp(list), via: client)
        let a = await store.sessions["cody-a"]
        XCTAssertEqual(a?.activity, FocusActivityCounters(epoch: "epoch-2", turns: 20, messages: 9, problems: 3))
        XCTAssertNil(a?.lastProblem)

        // And a list from a daemon that stopped sending them clears them: unknown, not stale.
        await deliver(.sessionListResp(decodeList([entry("cody-a")])), via: client)
        let cleared = await store.sessions["cody-a"]
        XCTAssertNil(cleared?.activity)
    }
}
