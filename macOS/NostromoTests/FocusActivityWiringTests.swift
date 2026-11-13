import XCTest
import AppKit
import Combine
import Foundation
import NostromoKit

// How the focus-activity pieces are joined inside the Mac app, and what must NOT be reachable.
//
//   * the wire: `session_list_resp` decodes to `ServerMsg.sessionListResp([SessionActivityEntry])`,
//     tolerating an unknown `state`, an unknown `last_problem`, null / wrong-typed / absent counters;
//   * `AppStore` (driven through `applyForTesting`, never `start()`): a session list feeds the
//     coordinator; a session changing state asks the daemon for a fresh list soon (debounced); becoming
//     seen, and the app becoming active, ask now; a visible window starts the 30 s backstop and the last
//     one going away stops it; a removed focus is forgotten;
//   * surface: the operator's seen-marks are never on the app-control surface or the MCP/agent surface.
//
// Logic test (no host app, no `@testable import`). The shared `AppStore`'s coordinator saves into the real
// defaults under the real key, so every test uses a unique tag and removes it again (`forget`); windows it
// reports are closed and the refresher it replaced is restored in tearDown.
//
// Mutation (7), the backstop running with no window visible, is caught here as well:
// testALastWindowGoingAwayStopsTheBackstop and the wiring half of testAVisibleWindowStartsTheBackstop.

// MARK: - Test doubles (private to this file)

private final class WiringScheduler {
    final class Timer {
        let after: TimeInterval
        let repeating: Bool
        let fire: () -> Void
        var due: TimeInterval
        var cancelled = false
        var fired = false
        init(after: TimeInterval, repeating: Bool, due: TimeInterval, fire: @escaping () -> Void) {
            self.after = after; self.repeating = repeating; self.due = due; self.fire = fire
        }
        var isActive: Bool { !cancelled && (repeating || !fired) }
    }

    private(set) var now: TimeInterval = 0
    private(set) var timers: [Timer] = []
    var active: [Timer] { timers.filter { $0.isActive } }

    lazy var schedule: SessionListRefresher.Schedule = { [unowned self] after, repeating, fire in
        let timer = Timer(after: after, repeating: repeating, due: self.now + after, fire: fire)
        self.timers.append(timer)
        return { timer.cancelled = true }
    }

    func advance(by seconds: TimeInterval) {
        let target = now + seconds
        while let next = active.filter({ $0.due <= target + 1e-9 }).min(by: { $0.due < $1.due }) {
            now = max(now, next.due)
            if next.repeating { next.due += next.after } else { next.fired = true }
            next.fire()
        }
        now = target
    }
}

private final class WiringRequester: SessionListRequesting {
    private(set) var requests = 0
    func requestSessionList() { requests += 1 }
}

// MARK: - The wire

final class FocusActivityWireDecodeTests: XCTestCase {

    private var client: NostromodClient!

    override func setUp() {
        super.setUp()
        client = NostromodClient(socketPath: "/dev/null")
    }

    private func decode(_ text: String) throws -> ServerMsg {
        let raw = text.data(using: .utf8)!
        let json = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        return client.decode(type_: "session_list_resp", json: json, raw: raw)
    }

    private func entries(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> [SessionActivityEntry] {
        let msg = try decode(text)
        guard case .sessionListResp(let list) = msg else {
            XCTFail("expected .sessionListResp, got \(msg)", file: file, line: line)
            return []
        }
        return list
    }

    private func session(_ tag: String, state: String = "idle", _ extra: String = "") -> String {
        #"{"tag":"\#(tag)","agent_name":"cody","view_name":"Cody","session_id":"sid-\#(tag)","alive":true,"remote_control":false,"state":"\#(state)"\#(extra)}"#
    }

    private func frame(_ sessions: [String]) -> String {
        #"{"type":"session_list_resp","sessions":[\#(sessions.joined(separator: ","))]}"#
    }

    func testTheDaemonsOwnFixtureFrameDecodesWithItsCounters() throws {
        let text = """
        {"type":"session_list_resp","sessions":[{"tag":"cody-fixture","agent_name":"cody","view_name":"Cody",
        "session_id":"5f0a8f7e-2d4c-4a4e-9a55-0f1f3a9d7c11","alive":true,"remote_control":false,"state":"idle",
        "agent_turns":12,"agent_messages":7,"agent_problems":3,
        "activity_epoch":"0b6c1c1e-3f0a-4d7e-8f21-6a1b2c3d4e5f","last_problem":"no_text"}]}
        """
        XCTAssertEqual(try entries(text), [
            SessionActivityEntry(tag: "cody-fixture", activity: FocusActivityCounters(
                epoch: "0b6c1c1e-3f0a-4d7e-8f21-6a1b2c3d4e5f", turns: 12, messages: 7, problems: 3, lastProblem: .noText)),
        ])
    }

    func testEntriesWithAndWithoutCountersDecodeSideBySideInOrder() throws {
        let list = try entries(frame([
            session("a", #","agent_turns":1,"agent_messages":2,"agent_problems":3,"activity_epoch":"ea""#),
            session("b"),
            session("c", #","agent_turns":10,"agent_messages":20,"agent_problems":30,"activity_epoch":"ec","last_problem":"crashed""#),
        ]))
        XCTAssertEqual(list.map(\.tag), ["a", "b", "c"])
        XCTAssertEqual(list[0].activity, FocusActivityCounters(epoch: "ea", turns: 1, messages: 2, problems: 3))
        XCTAssertNil(list[1].activity, "an older daemon's entry carries no counters")
        XCTAssertEqual(list[2].activity, FocusActivityCounters(epoch: "ec", turns: 10, messages: 20, problems: 30, lastProblem: .crashed))
    }

    func testAnUnknownStateAndAnUnknownLastProblemStillDecode() throws {
        let list = try entries(frame([
            session("a", state: "a_state_this_build_has_never_heard_of",
                    #","agent_turns":4,"agent_messages":3,"agent_problems":2,"activity_epoch":"e","last_problem":"brand_new","future_key":[1,2]"#),
            session("b"),
        ]))
        XCTAssertEqual(list.count, 2, "one entry from the future must not cost the list")
        XCTAssertEqual(list[0].activity, FocusActivityCounters(epoch: "e", turns: 4, messages: 3, problems: 2, lastProblem: .unknown))
    }

    func testNullAndWrongTypedCountersDecodeAsNoActivityWithoutCostingTheEntry() throws {
        let bad = [
            #","agent_turns":null,"agent_messages":1,"agent_problems":1,"activity_epoch":"e""#,
            #","agent_turns":"3","agent_messages":1,"agent_problems":1,"activity_epoch":"e""#,
            #","agent_turns":-3,"agent_messages":1,"agent_problems":1,"activity_epoch":"e""#,
            #","agent_turns":1,"agent_messages":1,"agent_problems":1,"activity_epoch":null"#,
            #","agent_turns":1,"agent_messages":1,"agent_problems":1,"activity_epoch":12"#,
            #","agent_turns":1,"agent_messages":1,"agent_problems":1"#,
            #","activity_epoch":"e""#,
        ]
        for extra in bad {
            let list = try entries(frame([session("a", extra), session("b", #","agent_turns":1,"agent_messages":1,"agent_problems":1,"activity_epoch":"e""#)]))
            XCTAssertEqual(list.map(\.tag), ["a", "b"], extra)
            XCTAssertNil(list[0].activity, extra)
            XCTAssertNotNil(list[1].activity, "its neighbour is unaffected: \(extra)")
        }
    }

    func testCountersAboveInt32DecodeExactly() throws {
        let list = try entries(frame([session("a", #","agent_turns":5000000000,"agent_messages":4294967296,"agent_problems":9007199254740993,"activity_epoch":"e""#)]))
        XCTAssertEqual(list.first?.activity?.turns, 5_000_000_000)
        XCTAssertEqual(list.first?.activity?.messages, 4_294_967_296)
        XCTAssertEqual(list.first?.activity?.problems, 9_007_199_254_740_993)
    }

    func testAnEmptyListDecodesAsAnEmptyList() throws {
        XCTAssertEqual(try entries(frame([])), [])
    }

    func testTheMacClientCanRequestASessionListWithoutAConnectionAndWithoutCrashing() {
        // `NostromodClient` is the `SessionListRequesting` the refresher asks (compile-time conformance);
        // with no socket the frame is dropped quietly.
        let requester: SessionListRequesting = client
        requester.requestSessionList()
    }
}

// MARK: - AppStore wiring

final class FocusActivityWiringTests: XCTestCase {

    private static let windowA = 9_000_001
    private static let windowB = 9_000_002

    private var store: AppStore { AppStore.shared }
    private var originalRefresher: SessionListRefresher!
    private var scheduler: WiringScheduler!
    private var requester: WiringRequester!
    private var tag: String!
    private var otherTag: String!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        scheduler = WiringScheduler()
        requester = WiringRequester()
        tag = "fa-wire-\(UUID().uuidString.prefix(8))"
        otherTag = "fa-wire-\(UUID().uuidString.prefix(8))"
        originalRefresher = store.sessionListRefresher
        store.sessionListRefresher = SessionListRefresher(requester: requester, schedule: scheduler.schedule)
    }

    override func tearDown() {
        // Windows first, while the test refresher is still installed, then the tags, then put it back.
        store.focusActivity.reportWindow(id: Self.windowA, sighting: nil)
        store.focusActivity.reportWindow(id: Self.windowB, sighting: nil)
        store.focusActivity.forget(tag: tag)
        store.focusActivity.forget(tag: otherTag)
        store.sessionListRefresher = originalRefresher
        originalRefresher = nil
        scheduler = nil
        requester = nil
        super.tearDown()
    }

    private func counters(_ t: UInt64, _ m: UInt64, _ p: UInt64, epoch: String = "wire-epoch",
                          last: ProblemKind? = nil) -> FocusActivityCounters {
        FocusActivityCounters(epoch: epoch, turns: t, messages: m, problems: p, lastProblem: last)
    }

    private func list(_ tag: String, _ counters: FocusActivityCounters?) {
        store.applyForTesting(.sessionListResp([SessionActivityEntry(tag: tag, activity: counters)]))
    }

    private func state(_ tag: String) -> FocusActivityState { store.focusActivity.state(for: tag) }

    private func report(_ id: Int, _ tag: String?, key: Bool = true, visible: Bool = true) {
        store.focusActivity.reportWindow(id: id, sighting: FocusWindowSighting(tag: tag, isKey: key, isVisible: visible))
    }

    private func spin(_ seconds: TimeInterval = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    @discardableResult
    private func waitUntil(timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { XCTFail("condition not met within \(timeout)s", file: file, line: line); return false }
            spin(0.01)
        }
        return true
    }

    // MARK: A session list feeds the coordinator

    func testASessionListFrameReachesTheCoordinator() {
        list(tag, counters(5, 3, 1))
        XCTAssertEqual(state(tag), .none, "first sight baselines")
        list(tag, counters(6, 4, 1))
        XCTAssertEqual(state(tag), .unread(count: 1))
        list(tag, counters(6, 4, 2, last: .apiError))
        XCTAssertEqual(state(tag), .problem(.apiError))
    }

    func testAnEntryWithoutCountersShowsNothing() {
        list(tag, nil)
        XCTAssertEqual(state(tag), .none)
    }

    func testTwoTagsInOneFrameAreEvaluatedIndependently() {
        store.applyForTesting(.sessionListResp([SessionActivityEntry(tag: tag, activity: counters(1, 1, 0)),
                                                SessionActivityEntry(tag: otherTag, activity: counters(1, 1, 0))]))
        store.applyForTesting(.sessionListResp([SessionActivityEntry(tag: tag, activity: counters(2, 1, 0)),
                                                SessionActivityEntry(tag: otherTag, activity: counters(2, 2, 0))]))
        XCTAssertEqual(state(tag), .activity)
        XCTAssertEqual(state(otherTag), .unread(count: 1))
    }

    // MARK: A session changing state asks soon, once per burst

    func testASessionStateChangeAsksTheDaemonForAFreshListHalfASecondLater() {
        store.applyForTesting(.sessionState(tag: tag, state: .midTurn))
        XCTAssertEqual(requester.requests, 0, "debounced, not immediate")
        scheduler.advance(by: 0.49)
        XCTAssertEqual(requester.requests, 0)
        scheduler.advance(by: 0.02)
        XCTAssertEqual(requester.requests, 1)
    }

    func testABurstOfStateChangesIsOneRequestAndARepeatedStateIsNone() {
        store.applyForTesting(.sessionState(tag: tag, state: .midTurn))
        store.applyForTesting(.sessionState(tag: otherTag, state: .idle))
        store.applyForTesting(.sessionState(tag: tag, state: .awaitingPermission))
        store.applyForTesting(.sessionState(tag: tag, state: .idle))
        scheduler.advance(by: 1)
        XCTAssertEqual(requester.requests, 1, "four changes inside one window, one request")

        store.applyForTesting(.sessionState(tag: tag, state: .idle))
        store.applyForTesting(.sessionState(tag: otherTag, state: .idle))
        scheduler.advance(by: 1)
        XCTAssertEqual(requester.requests, 1, "the same states again are not news")

        store.applyForTesting(.sessionState(tag: tag, state: .crashed))
        scheduler.advance(by: 1)
        XCTAssertEqual(requester.requests, 2, "a different state is")
    }

    // MARK: Becoming seen asks now

    func testAFocusBecomingSeenAsksForAFreshListAtOnce() {
        report(Self.windowA, tag, key: true, visible: true)
        XCTAssertEqual(requester.requests, 1, "no waiting for a window")
        XCTAssertEqual(scheduler.active.filter { !$0.repeating }.count, 0)
    }

    func testAWindowThatDoesNotSeeTheFocusAsksForNothingNow() {
        report(Self.windowA, tag, key: false, visible: true)
        report(Self.windowB, tag, key: true, visible: false)
        XCTAssertEqual(requester.requests, 0)
    }

    func testBecomingSeenAlsoClearsTheMarkThroughTheStore() {
        list(tag, counters(5, 3, 1))
        list(tag, counters(6, 4, 1))
        XCTAssertEqual(state(tag), .unread(count: 1))
        report(Self.windowA, tag)
        XCTAssertEqual(state(tag), .none)
    }

    // MARK: The backstop follows the windows

    func testAVisibleWindowStartsTheBackstop() throws {
        XCTAssertFalse(store.focusActivity.anyWindowVisible, "precondition: no window is reported visible")
        XCTAssertTrue(scheduler.active.isEmpty, "no timer while no window is visible")

        report(Self.windowA, tag, key: false, visible: true)
        let repeating = scheduler.active.filter { $0.repeating }
        XCTAssertEqual(repeating.count, 1)
        XCTAssertEqual(repeating.first?.after, 30)
        XCTAssertEqual(requester.requests, 0, "starting it asks for nothing")

        scheduler.advance(by: 30)
        XCTAssertEqual(requester.requests, 1)
        scheduler.advance(by: 30)
        XCTAssertEqual(requester.requests, 2)
    }

    func testASecondVisibleWindowDoesNotStartASecondTimer() {
        report(Self.windowA, tag, key: false, visible: true)
        report(Self.windowB, otherTag, key: false, visible: true)
        XCTAssertEqual(scheduler.active.filter { $0.repeating }.count, 1)
    }

    func testALastWindowGoingAwayStopsTheBackstop() {
        report(Self.windowA, tag, key: false, visible: true)
        report(Self.windowB, otherTag, key: false, visible: true)
        store.focusActivity.reportWindow(id: Self.windowA, sighting: nil)
        XCTAssertEqual(scheduler.active.filter { $0.repeating }.count, 1, "window B is still visible")

        report(Self.windowB, otherTag, key: false, visible: false)    // minimised: not visible
        XCTAssertTrue(scheduler.active.isEmpty, "the last visible window went: no backstop")
        scheduler.advance(by: 300)
        XCTAssertEqual(requester.requests, 0)
    }

    // MARK: The app becoming active asks now

    func testTheAppBecomingActiveAsksForAFreshListAtOnce() {
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
        waitUntil { self.requester.requests >= 1 }
        spin()
        XCTAssertEqual(requester.requests, 1, "exactly one request")
    }

    // MARK: A removed focus is forgotten (textual: the removal subscription lives in start())

    func testEvictingAFocusForgetsItsActivity() throws {
        let source = try Self.sourceFile("Nostromo/Data/AppStore.swift")
        guard let sig = source.range(of: "func evictPerFocusState") else {
            return XCTFail("evictPerFocusState not found in AppStore.swift")
        }
        guard let open = source[sig.upperBound...].firstIndex(of: "{") else { return XCTFail("no body") }
        var depth = 0
        var end = open
        for index in source[open...].indices {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" { depth -= 1; if depth == 0 { end = index; break } }
        }
        let body = String(source[open ... end])
        XCTAssertTrue(body.contains("focusActivity.forget(tag:"),
                      "evictPerFocusState must forget the removed focus's activity counters and saved marks, "
                      + "or a deleted focus's entry stays in the defaults until the cap pushes it out")
    }

    // MARK: Surface: nothing the agents or app-control can reach

    private static let forbidden = [
        "FocusSeenStore", "focusActivity", "FocusActivityCoordinator", "FocusSeenMarks", "nostromo.focus.activity.seen",
    ]

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)          // …/macOS/NostromoTests/FocusActivityWiringTests.swift
            .deletingLastPathComponent()          // …/macOS/NostromoTests
            .deletingLastPathComponent()          // …/macOS
            .deletingLastPathComponent()          // repo root
    }

    private static func sourceFile(_ relativePath: String) throws -> String {
        let url = repoRoot().appendingPathComponent("macOS").appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func files(under directory: URL, withExtension ext: String) throws -> [URL] {
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir) && isDir.boolValue,
                      "\(directory.path) must exist for this scan to mean anything")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == ext }
    }

    func testTheAppControlSurfaceNeverMentionsTheSeenMarksOrTheActivityCoordinator() throws {
        let dir = Self.repoRoot().appendingPathComponent("macOS/Nostromo/AppControl")
        let swiftFiles = try files(under: dir, withExtension: "swift")
        XCTAssertGreaterThan(swiftFiles.count, 3, "the scan found the AppControl sources")
        for url in swiftFiles {
            let text = try String(contentsOf: url, encoding: .utf8)
            for word in Self.forbidden {
                XCTAssertFalse(text.contains(word),
                               "\(url.lastPathComponent) mentions \(word): an agent driving app-control must not be able to "
                               + "read what the operator has seen or mark a focus seen")
            }
        }
    }

    func testTheRustSourcesNeverMentionTheDefaultsKey() throws {
        let src = Self.repoRoot().appendingPathComponent("src")
        let rustFiles = try files(under: src, withExtension: "rs")
        XCTAssertGreaterThan(rustFiles.count, 20, "the scan found the daemon's sources")
        for url in rustFiles {
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains(FocusSeenStore.defaultsKey),
                           "\(url.lastPathComponent) names the Mac's seen-marks defaults key: an agent or MCP tool must not "
                           + "be able to read or set it")
        }
    }
}
