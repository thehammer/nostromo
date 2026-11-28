// NostromoKit — DaemonStoreHostedTests.swift
//
// `DaemonStore` and a satellite host's Focuses, Perri, held decisions and approvals, under a host
// scope (W11 slice 2). The store is driven through a fake `DaemonTransport` with the REAL frames a
// paired phone receives (`tests/fixtures/hosts/*.json`, captured from the Rust daemon's redaction
// output) plus a few hand-built ones. What these guard:
//   * a hosted frame lands under (host, tag) / (host, request id) and never touches the primary's own
//     queue, focuses, pending decisions or approval counts, even when the tag or id is the same;
//   * two hosts holding the same tag or request id stay separate;
//   * a second `perri_state` replaces that host's queue but keeps other tags' PRs; a focus registry
//     prunes a PR whose focus is gone; decisions dedupe, resolve, and a late request stays resolved;
//   * connecting clears held decisions (the primary does not retain them) but keeps last-known
//     Perri and focuses;
//   * the roster remembers a host that dropped out of a `Hosts` frame, and nothing is "connected"
//     while the phone's own link is down or the content is from a relaunch;
//   * the scope is persisted in the injected defaults, read back by a new store, resolves to All when
//     it names a host that is gone (without losing the stored value), and drives the Focuses, Perri
//     and queue views end to end;
//   * the content cache round-trips hosted content and a relaunch starts last-known; a resolved
//     decision is gone after a relaunch;
//   * `wipeAll()` leaves nothing (memory, scope, disk), and a frame in flight afterwards does not
//     bring any of it back.
//
// The store's sinks hop to the main run loop, so each helper lets the main loop turn before the
// test reads the store.

import XCTest
import Combine
@testable import NostromoKit

// MARK: - Fake transport

@MainActor
private final class FakeDaemonTransport: DaemonTransport {
    let connectedSubject = CurrentValueSubject<Bool, Never>(false)
    let stateSubject = CurrentValueSubject<ConnectionState, Never>(.connecting)
    let frames = PassthroughSubject<HostedServerMsg, Never>()

    var connected: Bool { connectedSubject.value }
    var connectedPublisher: AnyPublisher<Bool, Never> { connectedSubject.eraseToAnyPublisher() }
    var framePublisher: AnyPublisher<HostedServerMsg, Never> { frames.eraseToAnyPublisher() }
    var connectionStatePublisher: AnyPublisher<ConnectionState, Never> { stateSubject.eraseToAnyPublisher() }

    func start() {}
    func stop() {}
    func send(_ msg: some Encodable) {}
}

/// Lets everything already scheduled on the main run loop (the store's `receive(on:)` hops) run.
@MainActor
private func letMainLoopTurn() async {
    for _ in 0..<3 {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            RunLoop.main.perform { continuation.resume() }
        }
    }
}

@MainActor
final class DaemonStoreHostedTests: XCTestCase {

    private let primaryName = "Sendai"
    private let savedAt = Date(timeIntervalSince1970: 1_800_000_000)       // 2027-01-15T08:00:00Z
    private let kobeSeenText = "2027-01-15T07:55:00Z"
    private let kobeSeen = Date(timeIntervalSince1970: 1_799_999_700)
    private let studioSeenText = "2027-01-15T07:59:00Z"
    private let studioSeen = Date(timeIntervalSince1970: 1_799_999_940)

    private var directory: URL!
    private var cacheURL: URL { directory.appendingPathComponent("content-cache.json") }
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DaemonStoreHostedTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "DaemonStoreHostedTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let dir = directory!
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
    }

    // MARK: - Helpers

    private func makeCache() -> ContentCache {
        ContentCache(url: cacheURL, debounce: 60, now: { [savedAt] in savedAt })
    }

    /// A store on a fresh fake transport and the test's defaults suite. `connect: false` leaves the
    /// link down, as a relaunch has it before the first connection.
    private func makeStore(cache: ContentCache? = nil, connect: Bool = true) async
        -> (store: DaemonStore, transport: FakeDaemonTransport) {
        let transport = FakeDaemonTransport()
        let store = DaemonStore(client: transport, cache: cache, scopeDefaults: defaults)
        await letMainLoopTurn()   // the transport's initial "disconnected" is delivered first
        if connect {
            transport.connectedSubject.send(true)
            await letMainLoopTurn()
        }
        return (store, transport)
    }

    private func setLink(_ up: Bool, _ transport: FakeDaemonTransport) async {
        transport.connectedSubject.send(up)
        await letMainLoopTurn()
    }

    private func deliver(_ json: String, via transport: FakeDaemonTransport) async {
        transport.frames.send(ServerMsg.decodeHosted(from: Data(json.utf8)))
        await letMainLoopTurn()
    }

    private func fixtureData(_ name: String, _ kind: String) throws -> Data {
        var url = URL(fileURLWithPath: "\(#filePath)")
        for _ in 0..<5 { url.deleteLastPathComponent() }
        url.appendPathComponent("tests/fixtures/hosts/\(name).\(kind).json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("fixture not found at \(url.path)")
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    private func deliverFixture(_ name: String, _ kind: String, via transport: FakeDaemonTransport) async throws {
        transport.frames.send(ServerMsg.decodeHosted(from: try fixtureData(name, kind)))
        await letMainLoopTurn()
    }

    private let fixtureNames = ["perri_state", "focus_registry_updated", "decision_request", "approval_pending"]

    /// `Hosts` (kobe work, studio personal) and the four real frames of each host.
    private func populateHosts(via transport: FakeDaemonTransport) async throws {
        await deliver(hostsFrame([("kobe", "work", kobeSeenText), ("studio", "personal", studioSeenText)]), via: transport)
        for kind in ["work", "personal"] {
            for name in fixtureNames { try await deliverFixture(name, kind, via: transport) }
        }
    }

    // MARK: Hand-built frames

    private func hostsFrame(_ entries: [(name: String, egress: String, lastSeen: String?)]) -> String {
        let list = entries.map { entry -> String in
            let seen = entry.lastSeen.map { #","last_seen":"\#($0)""# } ?? ""
            return #"{"name":"\#(entry.name)","egress":"\#(entry.egress)"\#(seen)}"#
        }.joined(separator: ",")
        return #"{"type":"hosts","hosts":[\#(list)]}"#
    }

    private func hostKey(_ host: String?) -> String { host.map { #","host":"\#($0)""# } ?? "" }

    private func queueItem(_ repo: String, _ number: Int) -> String {
        #"{"repo":"\#(repo)","number":\#(number),"title":"T\#(number)","author":"a","bucket":"requested","url":""}"#
    }

    private func currentPR(_ repo: String, _ number: Int) -> String {
        #"{"pr_number":\#(number),"repo":"\#(repo)","title":"t","author":"a","url":"https://github.com/\#(repo)/pull/\#(number)","diff":"","stale":false,"ci_checks":[],"additions":1,"deletions":1,"changed_files":1,"head_sha":"abc","diff_too_large":false}"#
    }

    private func perriFrame(host: String?, tag: String, queue: [String] = [], current: String? = nil) -> String {
        #"{"type":"perri_state"\#(hostKey(host)),"tag":"\#(tag)","queue":[\#(queue.joined(separator: ","))],"current":\#(current ?? "null")}"#
    }

    private func focusFrame(host: String?, tags: [String], type: String = "focus_registry_updated") -> String {
        let list = tags.map { #"{"tag":"\#($0)","display_name":"\#($0)","agent_name":"cody","is_built_in":false}"# }
            .joined(separator: ",")
        return #"{"type":"\#(type)"\#(hostKey(host)),"focuses":[\#(list)]}"#
    }

    private func decisionFrame(host: String?, tag: String = "f-1", id: String, prompt: String = "") -> String {
        #"{"type":"decision_request"\#(hostKey(host)),"tag":"\#(tag)","request_id":"\#(id)","prompt":"\#(prompt)","choices":[]}"#
    }

    private func resolvedFrame(host: String?, tag: String = "f-1", id: String) -> String {
        #"{"type":"decision_resolved"\#(hostKey(host)),"tag":"\#(tag)","request_id":"\#(id)","resolution":"answered"}"#
    }

    private func approvalFrame(host: String?, tag: String, count: Int) -> String {
        #"{"type":"approval_pending"\#(hostKey(host)),"tag":"\#(tag)","count":\#(count)}"#
    }

    private let primaryFocusList = #"{"type":"focus_list_resp","focuses":[{"tag":"f-33acb7de","display_name":"Primary A","agent_name":"claudia","is_built_in":false},{"tag":"f-48a0007a","display_name":"Primary B","agent_name":"claudia","is_built_in":false}]}"#
    private let primaryDecision = #"{"type":"decision_request","tag":"f-48a0007a","request_id":"req-0a1b2c3d","prompt":"Deploy?","choices":[{"id":"yes","label":"Yes"}]}"#
    private let primaryJobs = #"{"type":"mother_jobs","jobs":[{"id":"p-run","state":"running","title":"Primary job"}]}"#

    private func entry(_ store: DaemonStore, _ name: String) -> HostEntry? {
        store.hostEntries(primaryName: primaryName).first { $0.name == name }
    }

    // MARK: - Hosted frames never touch the primary's state

    func testHostedWorkFramesLandUnderTheirHostAndNeverTouchThePrimarysSameTaggedState() async throws {
        let (store, transport) = await makeStore(cache: makeCache())
        // The primary holds state under the very tags and request id the work host will use.
        await deliver(primaryFocusList, via: transport)
        await deliver(perriFrame(host: nil, tag: "f-33acb7de", queue: [queueItem("acme/web", 42)],
                                 current: currentPR("acme/web", 42)), via: transport)
        await deliver(primaryDecision, via: transport)
        await deliver(approvalFrame(host: nil, tag: "f-48a0007a", count: 5), via: transport)

        for name in fixtureNames { try await deliverFixture(name, "work", via: transport) }
        await deliver(decisionFrame(host: "kobe", tag: "f-48a0007a", id: "req-kobe-2"), via: transport)
        try await deliverFixture("decision_resolved", "work", via: transport)

        // The primary's own, untouched.
        XCTAssertEqual(store.perriQueue.map(\.number), [42])
        XCTAssertEqual(store.perriCurrentPr["f-33acb7de"]?.prNumber, 42,
                       "Kobe's frame for the same tag (current: null) must not clear the primary's PR")
        XCTAssertEqual(store.focuses.keys.sorted(), ["f-33acb7de", "f-48a0007a"])
        XCTAssertEqual(store.focuses["f-48a0007a"]?.displayName, "Primary B")
        XCTAssertEqual(store.pendingDecisions.map(\.requestId), ["req-0a1b2c3d"],
                       "Kobe's request neither joins the primary's queue nor resolves its same-id decision")
        XCTAssertEqual(store.pendingDecisions.first?.prompt, "Deploy?")
        XCTAssertNil(store.decisionStore.resolution(for: "req-0a1b2c3d"))
        XCTAssertEqual(store.approvalCounts[""], ["f-48a0007a": 5])

        // Kobe's, under kobe.
        XCTAssertEqual(store.hostedPerri["kobe"]?.queue.map(\.number), [4821, 77, 5])
        XCTAssertEqual(store.hostedPerri["kobe"]?.currents.isEmpty, true)
        XCTAssertEqual(store.hostedFocuses["kobe"]?.map(\.tag), ["f-33acb7de", "f-48a0007a", "f-70e15afe"])
        XCTAssertEqual(store.hostedDecisions["kobe"],
                       [HostedDecision(host: "kobe", tag: "f-48a0007a", requestId: "req-kobe-2", prompt: "")],
                       "The fixture's request was resolved; the second is still held")
        XCTAssertEqual(store.approvalCounts["kobe"], ["f-48a0007a": 2])
        XCTAssertEqual(store.needsYouCount["kobe"], 2)
        XCTAssertEqual(store.needsYouCount[""], 5)
    }

    func testHostedPersonalFramesLandUnderTheirHostWithTheirRealContent() async throws {
        let (store, transport) = await makeStore(cache: makeCache())
        for name in fixtureNames { try await deliverFixture(name, "personal", via: transport) }

        XCTAssertTrue(store.perriQueue.isEmpty)
        XCTAssertTrue(store.focuses.isEmpty)
        XCTAssertTrue(store.pendingDecisions.isEmpty)
        XCTAssertNil(store.approvalCounts[""])
        XCTAssertEqual(store.hostedPerri["studio"]?.queue.map(\.title),
                       ["Add referral export", "Fix refund rounding", "Bump axios"])
        XCTAssertEqual(store.hostedFocuses["studio"]?.map(\.tag), ["perri", "cody-1a2b3c4d", "claudia-9e8d7c6b"])
        XCTAssertEqual(store.hostedDecisions["studio"],
                       [HostedDecision(host: "studio", tag: "cody-1a2b3c4d", requestId: "req-0a1b2c3d",
                                       prompt: "Ship the export behind a flag?")])
        XCTAssertEqual(store.approvalCounts["studio"], ["cody-1a2b3c4d": 2])
    }

    func testTwoHostsWithTheSameTagAndRequestIdStaySeparate() async throws {
        let (store, transport) = await makeStore(cache: makeCache())
        await deliver(perriFrame(host: "kobe", tag: "shared", queue: [queueItem("r-a9c56c1a", 1)]), via: transport)
        await deliver(perriFrame(host: "studio", tag: "shared", queue: [queueItem("carefeed/web", 2)],
                                 current: currentPR("carefeed/web", 2)), via: transport)
        try await deliverFixture("decision_request", "work", via: transport)       // req-0a1b2c3d on kobe
        try await deliverFixture("decision_request", "personal", via: transport)   // req-0a1b2c3d on studio
        await deliver(approvalFrame(host: "kobe", tag: "shared", count: 1), via: transport)
        await deliver(approvalFrame(host: "studio", tag: "shared", count: 3), via: transport)

        XCTAssertEqual(store.hostedPerri["kobe"]?.queue.map(\.number), [1])
        XCTAssertEqual(store.hostedPerri["studio"]?.queue.map(\.number), [2])
        XCTAssertNil(store.hostedPerri["kobe"]?.currents["shared"])
        XCTAssertEqual(store.hostedPerri["studio"]?.currents["shared"]?.prNumber, 2)
        XCTAssertEqual(store.hostedDecisions["kobe"]?.map(\.requestId), ["req-0a1b2c3d"])
        XCTAssertEqual(store.hostedDecisions["studio"]?.map(\.requestId), ["req-0a1b2c3d"])
        XCTAssertEqual(store.hostedDecisions["kobe"]?.first?.prompt, "")
        XCTAssertEqual(store.hostedDecisions["studio"]?.first?.prompt, "Ship the export behind a flag?")
        XCTAssertEqual(store.approvalCounts["kobe"], ["shared": 1])
        XCTAssertEqual(store.approvalCounts["studio"], ["shared": 3])

        // Resolving it on one host leaves the other host's same-id decision held.
        try await deliverFixture("decision_resolved", "personal", via: transport)
        XCTAssertNil(store.hostedDecisions["studio"])
        XCTAssertEqual(store.hostedDecisions["kobe"]?.map(\.requestId), ["req-0a1b2c3d"])
    }

    // MARK: - Perri state

    func testASecondPerriStateReplacesThatHostsQueueButKeepsOtherTagsCurrentPRs() async throws {
        let (store, transport) = await makeStore(cache: makeCache())
        await deliver(perriFrame(host: "studio", tag: "t1", queue: [queueItem("acme/other", 99)]), via: transport)
        await deliver(perriFrame(host: "kobe", tag: "t1", queue: [queueItem("acme/api", 1)],
                                 current: currentPR("acme/api", 7)), via: transport)
        await deliver(perriFrame(host: "kobe", tag: "t2", queue: [queueItem("acme/api", 2)],
                                 current: currentPR("acme/api", 8)), via: transport)

        XCTAssertEqual(store.hostedPerri["kobe"]?.queue.map(\.number), [2], "The newest queue replaces the old")
        XCTAssertEqual(store.hostedPerri["kobe"]?.currents.keys.sorted(), ["t1", "t2"])
        XCTAssertEqual(store.hostedPerri["kobe"]?.currents["t1"]?.prNumber, 7)
        XCTAssertEqual(store.hostedPerri["kobe"]?.currents["t2"]?.prNumber, 8)

        await deliver(perriFrame(host: "kobe", tag: "t1", queue: [queueItem("acme/api", 3)]), via: transport)

        XCTAssertEqual(store.hostedPerri["kobe"]?.queue.map(\.number), [3])
        XCTAssertEqual(store.hostedPerri["kobe"]?.currents.keys.sorted(), ["t2"], "current: null clears that tag only")
        XCTAssertEqual(store.hostedPerri["studio"]?.queue.map(\.number), [99], "Another host is untouched")
    }

    func testAFocusRegistryPrunesThePRsOfFocusesItNoLongerListsForThatHostOnly() async throws {
        let (store, transport) = await makeStore(cache: makeCache())
        await deliver(perriFrame(host: "kobe", tag: "f-48a0007a", current: currentPR("acme/api", 1)), via: transport)
        await deliver(perriFrame(host: "kobe", tag: "gone-tag", current: currentPR("acme/api", 2)), via: transport)
        await deliver(perriFrame(host: "studio", tag: "gone-tag", current: currentPR("acme/api", 3)), via: transport)
        XCTAssertEqual(store.hostedPerri["kobe"]?.currents.keys.sorted(), ["f-48a0007a", "gone-tag"])

        try await deliverFixture("focus_registry_updated", "work", via: transport)   // lists f-48a0007a, not gone-tag

        XCTAssertEqual(store.hostedPerri["kobe"]?.currents.keys.sorted(), ["f-48a0007a"])
        XCTAssertEqual(store.hostedPerri["studio"]?.currents.keys.sorted(), ["gone-tag"],
                       "Kobe's registry says nothing about studio's focuses")

        await deliver(focusFrame(host: "kobe", tags: ["only-this"], type: "focus_list_resp"), via: transport)
        XCTAssertEqual(store.hostedPerri["kobe"]?.currents.count, 0, "A focus list prunes the same way")
        XCTAssertEqual(store.hostedFocuses["kobe"]?.map(\.tag), ["only-this"])
    }

    func testAFocusRegistryForAHostWithNoPerriStateCreatesNoPerriEntry() async throws {
        let (store, transport) = await makeStore(cache: makeCache())

        await deliver(focusFrame(host: "amber", tags: ["a-1"]), via: transport)

        XCTAssertEqual(store.hostedFocuses["amber"]?.map(\.tag), ["a-1"])
        XCTAssertNil(store.hostedPerri["amber"])
    }

    // MARK: - Decisions

    func testADecisionRequestDedupesByIdIsRemovedWhenResolvedAndALateRequestDoesNotComeBack() async throws {
        let (store, transport) = await makeStore(cache: makeCache())

        try await deliverFixture("decision_request", "work", via: transport)
        try await deliverFixture("decision_request", "work", via: transport)
        XCTAssertEqual(store.hostedDecisions["kobe"]?.count, 1, "One request id is one decision")

        await deliver(decisionFrame(host: "kobe", id: "req-2", prompt: "Second?"), via: transport)
        XCTAssertEqual(store.hostedDecisions["kobe"]?.map(\.requestId), ["req-0a1b2c3d", "req-2"])

        try await deliverFixture("decision_resolved", "work", via: transport)
        XCTAssertEqual(store.hostedDecisions["kobe"]?.map(\.requestId), ["req-2"])

        try await deliverFixture("decision_request", "work", via: transport)   // a late replay
        XCTAssertEqual(store.hostedDecisions["kobe"]?.map(\.requestId), ["req-2"],
                       "A resolved request must not be reconstructed by a late frame")

        await deliver(resolvedFrame(host: "kobe", id: "req-2"), via: transport)
        XCTAssertTrue(store.hostedDecisions.isEmpty, "A host with nothing held has no entry")
    }

    func testAResolutionForADecisionNothingHoldsIsHarmless() async throws {
        let (store, transport) = await makeStore(cache: makeCache())
        await deliver(decisionFrame(host: "kobe", id: "req-1"), via: transport)

        await deliver(resolvedFrame(host: "kobe", id: "never-seen"), via: transport)
        await deliver(resolvedFrame(host: "studio", id: "req-1"), via: transport)

        XCTAssertEqual(store.hostedDecisions["kobe"]?.map(\.requestId), ["req-1"])
    }

    func testConnectingClearsHeldDecisionsButKeepsLastKnownPerriAndFocuses() async throws {
        let (store, transport) = await makeStore(cache: makeCache())
        try await populateHosts(via: transport)
        XCTAssertEqual(store.hostedDecisions.keys.sorted(), ["kobe", "studio"])

        await setLink(false, transport)
        await setLink(true, transport)

        XCTAssertTrue(store.hostedDecisions.isEmpty,
                      "The primary does not retain a satellite's requests, so none can be vouched for")
        XCTAssertEqual(store.hostedPerri["kobe"]?.queue.count, 3, "Last-known Perri stays")
        XCTAssertEqual(store.hostedPerri["studio"]?.queue.count, 3)
        XCTAssertEqual(store.hostedFocuses["kobe"]?.count, 3, "Last-known focuses stay")
        XCTAssertEqual(store.hostedFocuses["studio"]?.count, 3)

        try await deliverFixture("decision_request", "work", via: transport)
        XCTAssertEqual(store.hostedDecisions["kobe"]?.map(\.requestId), ["req-0a1b2c3d"],
                       "A live frame that says it is still there brings it back")
    }

    // MARK: - Hosts and the roster

    func testAHostsFrameFillsTheRosterAndTheEntriesAndTheOptions() async throws {
        let (store, transport) = await makeStore(cache: makeCache())

        await deliver(hostsFrame([("kobe", "work", kobeSeenText), ("studio", "personal", nil)]), via: transport)

        let entries = store.hostEntries(primaryName: primaryName)
        XCTAssertEqual(entries.map(\.name), ["Sendai", "kobe", "studio"])
        XCTAssertEqual(entries.map(\.isPrimary), [true, false, false])
        XCTAssertEqual(entries.map(\.egress), [.personal, .work, .personal])
        XCTAssertEqual(entries.map(\.connected), [true, true, true])
        XCTAssertEqual(entries.map(\.lastSeen), [nil, kobeSeen, nil])
        XCTAssertEqual(store.scopeOptions(primaryName: primaryName),
                       [.all, .work, .personal, .host("Sendai"), .host("kobe"), .host("studio")])
    }

    func testAHostThatDropsOutOfALaterHostsFrameKeepsItsEntryEgressAndLastSeenButIsNotConnected() async throws {
        let (store, transport) = await makeStore(cache: makeCache())
        await deliver(hostsFrame([("kobe", "work", kobeSeenText), ("studio", "personal", studioSeenText)]), via: transport)

        await deliver(hostsFrame([("studio", "personal", studioSeenText)]), via: transport)

        let kobe = try XCTUnwrap(entry(store, "kobe"), "A host that dropped is not forgotten")
        XCTAssertFalse(kobe.connected)
        XCTAssertEqual(kobe.egress, .work)
        XCTAssertEqual(kobe.lastSeen, kobeSeen)
        XCTAssertEqual(entry(store, "studio")?.connected, true)
        XCTAssertEqual(entry(store, "Sendai")?.connected, true)
        XCTAssertEqual(store.hostInfos.map(\.name), ["studio"], "The connected list follows the frame")
    }

    func testNothingIsConnectedWhileThePhonesOwnLinkIsDownButTheRosterIsKept() async throws {
        let (store, transport) = await makeStore(cache: makeCache())
        await deliver(hostsFrame([("kobe", "work", kobeSeenText), ("studio", "personal", studioSeenText)]), via: transport)
        XCTAssertEqual(store.hostEntries(primaryName: primaryName).map(\.connected), [true, true, true])

        await setLink(false, transport)

        let entries = store.hostEntries(primaryName: primaryName)
        XCTAssertEqual(entries.map(\.name), ["Sendai", "kobe", "studio"])
        XCTAssertEqual(entries.map(\.connected), [false, false, false])
        XCTAssertEqual(entry(store, "kobe")?.lastSeen, kobeSeen)
        XCTAssertEqual(entry(store, "kobe")?.egress, .work)

        await setLink(true, transport)
        XCTAssertEqual(entry(store, "Sendai")?.connected, true, "The primary is connected again with the link")
    }

    func testARelaunchStartsWithEveryHostLastKnownWithItsEgressAndLastSeenFromTheCache() async throws {
        let cacheA = makeCache()
        let (storeA, transportA) = await makeStore(cache: cacheA)
        try await populateHosts(via: transportA)
        XCTAssertEqual(storeA.hostEntries(primaryName: primaryName).map(\.connected), [true, true, true])
        cacheA.flush()

        let (relaunched, _) = await makeStore(cache: makeCache(), connect: false)

        XCTAssertTrue(relaunched.isStale)
        let entries = relaunched.hostEntries(primaryName: primaryName)
        XCTAssertEqual(entries.map(\.name), ["Sendai", "kobe", "studio"])
        XCTAssertEqual(entries.map(\.connected), [false, false, false], "Cached content is not a live connection")
        XCTAssertEqual(entries.map(\.egress), [.personal, .work, .personal])
        XCTAssertEqual(entries.map(\.lastSeen), [nil, kobeSeen, studioSeen])
    }

    // MARK: - The scope

    func testANewStoreStartsOnAllAndWritesNothingToTheDefaults() async throws {
        let (store, _) = await makeStore()

        XCTAssertEqual(store.scopeSelection, .all)
        XCTAssertNil(defaults.object(forKey: DaemonStore.scopeDefaultsKey))
    }

    func testSelectScopePersistsInTheInjectedDefaultsAndANewStoreReadsItBack() async throws {
        let scopes: [HostScope] = [.work, .personal, .host("kobe"), .host("studio: upstairs"), .all]
        for scope in scopes {
            let (store, _) = await makeStore()
            store.selectScope(scope)

            XCTAssertEqual(store.scopeSelection, scope)
            XCTAssertEqual(defaults.string(forKey: DaemonStore.scopeDefaultsKey), scope.storageValue, "\(scope)")

            let (relaunched, _) = await makeStore()
            XCTAssertEqual(relaunched.scopeSelection, scope, "A new store on the same defaults reads \(scope) back")
        }
    }

    func testAStoredScopeNamingAHostThatIsGoneReadsAsAllButTheStoredValueIsKept() async throws {
        defaults.set("host:ghost", forKey: DaemonStore.scopeDefaultsKey)
        let (store, transport) = await makeStore()

        XCTAssertEqual(store.scopeSelection, .host("ghost"), "The selection is what was stored")
        XCTAssertEqual(store.effectiveScope(primaryName: primaryName), .all, "A host that is not there shows everything")
        XCTAssertEqual(defaults.string(forKey: DaemonStore.scopeDefaultsKey), "host:ghost",
                       "Reading the effective scope does not rewrite the stored one")

        await deliver(hostsFrame([("ghost", "work", nil)]), via: transport)
        XCTAssertEqual(store.effectiveScope(primaryName: primaryName), .host("ghost"),
                       "When the host is back, so is the scope")
    }

    func testAStoredKindWithNoHostOfThatKindReadsAsAllUntilOneAppears() async throws {
        defaults.set("work", forKey: DaemonStore.scopeDefaultsKey)
        let (store, transport) = await makeStore()
        XCTAssertEqual(store.effectiveScope(primaryName: primaryName), .all, "No work host yet")

        await deliver(hostsFrame([("kobe", "work", nil)]), via: transport)

        XCTAssertEqual(store.effectiveScope(primaryName: primaryName), .work)
    }

    func testAStoredValueThatIsNotAScopeReadsAsAll() async throws {
        defaults.set("banana", forKey: DaemonStore.scopeDefaultsKey)
        let (store, _) = await makeStore()
        XCTAssertEqual(store.scopeSelection, .all)
        XCTAssertEqual(store.effectiveScope(primaryName: primaryName), .all)
    }

    func testAHostThatDroppedOutOfTheHostsFrameStillSupportsItsScopeAndShowsLastKnown() async throws {
        let (store, transport) = await makeStore(cache: makeCache())
        await deliver(hostsFrame([("kobe", "work", kobeSeenText), ("studio", "personal", nil)]), via: transport)
        try await deliverFixture("focus_registry_updated", "work", via: transport)
        store.selectScope(.host("kobe"))

        await deliver(hostsFrame([("studio", "personal", nil)]), via: transport)

        XCTAssertEqual(store.effectiveScope(primaryName: primaryName), .host("kobe"),
                       "Its last-known content keeps it a host the phone knows of")
        let sections = store.focusSections(primaryName: primaryName, now: savedAt)
        XCTAssertEqual(sections.map(\.host.name), ["kobe"])
        XCTAssertTrue(sections[0].isLastKnown)
        XCTAssertTrue(try XCTUnwrap(sections[0].lastKnownLabel).hasPrefix("Last seen "))
    }

    // MARK: - The scope drives the views

    func testTheScopeDrivesFocusesPerriAndTheMergedQueueEndToEnd() async throws {
        let (store, transport) = await makeStore(cache: makeCache())
        await deliver(#"{"type":"focus_list_resp","focuses":[{"tag":"perri","display_name":"Perri","agent_name":"perri","is_built_in":true}]}"#,
                      via: transport)
        await deliver(perriFrame(host: nil, tag: "perri", queue: [queueItem("acme/web", 42)]), via: transport)
        await deliver(primaryJobs, via: transport)
        try await populateHosts(via: transport)
        XCTAssertEqual(store.scopeSelection, .all)

        let table: [(scope: HostScope, focus: [String], perri: [String], primary: Bool, queueRows: Int,
                     queueHosts: Set<String?>)] = [
            (.all,            ["Sendai", "kobe", "studio"], ["kobe", "studio"], true,  5, [nil, "kobe", "studio"]),
            (.work,           ["kobe"],                     ["kobe"],           false, 2, ["kobe"]),
            (.personal,       ["Sendai", "studio"],         ["studio"],         true,  3, [nil, "studio"]),
            (.host("studio"), ["studio"],                   ["studio"],         false, 2, ["studio"]),
            (.host("kobe"),   ["kobe"],                     ["kobe"],           false, 2, ["kobe"]),
            (.host("Sendai"), ["Sendai"],                   [],                 true,  1, [nil]),
        ]
        for row in table {
            store.selectScope(row.scope)
            XCTAssertEqual(store.effectiveScope(primaryName: primaryName), row.scope, "\(row.scope)")
            XCTAssertEqual(store.focusSections(primaryName: primaryName).map(\.host.name), row.focus,
                           "focus sections under \(row.scope)")
            XCTAssertEqual(store.perriSections(primaryName: primaryName).map(\.host.name), row.perri,
                           "perri sections under \(row.scope)")
            XCTAssertEqual(store.showsPrimary(primaryName: primaryName), row.primary, "showsPrimary under \(row.scope)")
            let queue = store.mergedQueue(primaryName: primaryName)
            XCTAssertEqual(queue.count, row.queueRows, "queue rows under \(row.scope)")
            XCTAssertEqual(Set(queue.map(\.host)), row.queueHosts, "queue Macs under \(row.scope)")
            XCTAssertTrue(queue.allSatisfy { ($0.hostBadge == nil) == row.scope.isSingleHost },
                          "badges under \(row.scope): \(queue.map(\.hostBadge))")
        }
    }

    func testTheQueueShowsEachHostsDecisionAndApprovalRowsWithTheirOwnWords() async throws {
        let (store, transport) = await makeStore(cache: makeCache())
        try await populateHosts(via: transport)

        let rows = store.mergedQueue(primaryName: primaryName)

        XCTAssertEqual(rows.count, 4)
        XCTAssertTrue(rows.allSatisfy { $0.needsYou })
        XCTAssertTrue(rows.allSatisfy { $0.footnote == ReasonPhrases.answerOnYourMac })
        let decisions = rows.filter { $0.kind == .decision }
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: decisions.map { ($0.host ?? "", $0.text) }),
                       ["kobe": ReasonPhrases.decisionLine, "studio": "Ship the export behind a flag?"])
        let approvals = rows.filter { $0.kind == .approval }
        XCTAssertEqual(approvals.map(\.text), [ReasonPhrases.approvalLine(count: 2), ReasonPhrases.approvalLine(count: 2)])
        XCTAssertEqual(Set(approvals.compactMap(\.host)), ["kobe", "studio"])
        XCTAssertFalse(rows.first { $0.kind == .approval && $0.host == "kobe" }!.id.contains("f-48a0007a"),
                       "A work host's tag is not used raw in a row id")
    }

    func testTheWorkHostsFocusesAndPerriRenderWithoutInventedOrgsOrLinks() async throws {
        let (store, transport) = await makeStore(cache: makeCache())
        try await populateHosts(via: transport)
        store.selectScope(.work)

        let focus = try XCTUnwrap(store.focusSections(primaryName: primaryName).first)
        XCTAssertFalse(focus.rows.contains { if case .orgHeader = $0 { return true } else { return false } })
        XCTAssertEqual(focus.rows.count, 3)

        let perri = try XCTUnwrap(store.perriSections(primaryName: primaryName).first)
        XCTAssertEqual(perri.rows.map(\.text),
                       ["PR #77 · small change · 3 waiting", "PR #4821 · medium change · 3 waiting",
                        "PR #5 · large change · 3 waiting"])
        XCTAssertTrue(perri.rows.allSatisfy { $0.url == nil && $0.isPseudonymous })
        XCTAssertFalse(perri.isLastKnown)
    }

    // MARK: - hasLastKnownContent

    func testHostedFocusesAloneCountAsLastKnownContent() async throws {
        let (store, transport) = await makeStore(cache: makeCache())
        XCTAssertFalse(store.hasLastKnownContent)

        try await deliverFixture("focus_registry_updated", "work", via: transport)

        XCTAssertTrue(store.hasLastKnownContent)
    }

    func testAHostedPerriQueueAloneCountsAsLastKnownContent() async throws {
        let (store, transport) = await makeStore(cache: makeCache())
        XCTAssertFalse(store.hasLastKnownContent)

        try await deliverFixture("perri_state", "work", via: transport)

        XCTAssertTrue(store.hasLastKnownContent)
    }

    // MARK: - wipeAll

    func testWipeAllEmptiesHostedStateResetsTheScopeAndDeletesTheCacheFile() async throws {
        let cache = makeCache()
        let (store, transport) = await makeStore(cache: cache)
        try await populateHosts(via: transport)
        store.selectScope(.host("kobe"))
        cache.flush()
        XCTAssertFalse(store.hostedPerri.isEmpty)
        XCTAssertFalse(store.hostedFocuses.isEmpty)
        XCTAssertFalse(store.hostedDecisions.isEmpty)
        XCTAssertFalse(store.approvalCounts.isEmpty)
        XCTAssertNotEqual(store.hostRoster, HostRoster())
        XCTAssertNotNil(defaults.string(forKey: DaemonStore.scopeDefaultsKey))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))

        store.wipeAll()

        XCTAssertTrue(store.hostedPerri.isEmpty)
        XCTAssertTrue(store.hostedFocuses.isEmpty)
        XCTAssertTrue(store.hostedDecisions.isEmpty)
        XCTAssertTrue(store.approvalCounts.isEmpty)
        XCTAssertTrue(store.needsYouCount.isEmpty)
        XCTAssertTrue(store.hostInfos.isEmpty)
        XCTAssertEqual(store.hostRoster, HostRoster())
        XCTAssertEqual(store.hostEntries(primaryName: primaryName).map(\.name), ["Sendai"])
        XCTAssertEqual(store.scopeSelection, .all)
        XCTAssertEqual(store.effectiveScope(primaryName: primaryName), .all)
        XCTAssertNil(defaults.object(forKey: DaemonStore.scopeDefaultsKey), "The stored scope goes with the pairing")
        XCTAssertFalse(store.hasLastKnownContent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    func testAFrameInFlightAfterWipeAllRefillsNeitherTheStoreNorTheCache() async throws {
        let cache = makeCache()
        let (store, transport) = await makeStore(cache: cache)
        try await populateHosts(via: transport)
        cache.flush()
        store.wipeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))

        // The socket was not yet closed: more frames arrive, with no new connected event in between.
        try await populateHosts(via: transport)
        await deliver(approvalFrame(host: "kobe", tag: "f-1", count: 1), via: transport)

        XCTAssertTrue(store.hostedPerri.isEmpty, "A wiped store stays wiped")
        XCTAssertTrue(store.hostedFocuses.isEmpty)
        XCTAssertTrue(store.hostedDecisions.isEmpty)
        XCTAssertTrue(store.approvalCounts.isEmpty)
        XCTAssertEqual(store.hostRoster, HostRoster())
        XCTAssertFalse(store.hasLastKnownContent)
        cache.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path),
                       "A late hosted frame must not put the revoked server's content back on disk")
    }

    // MARK: - The cache round trip

    func testARelaunchIsHydratedWithTheSameHostedContentAndMarkedLastKnown() async throws {
        let cacheA = makeCache()
        let (storeA, transportA) = await makeStore(cache: cacheA)
        try await populateHosts(via: transportA)
        try await deliverFixture("decision_resolved", "personal", via: transportA)   // studio's is resolved
        XCTAssertNil(storeA.hostedDecisions["studio"])
        XCTAssertEqual(storeA.hostedDecisions["kobe"]?.map(\.requestId), ["req-0a1b2c3d"])
        cacheA.flush()

        let (storeB, _) = await makeStore(cache: makeCache(), connect: false)

        XCTAssertTrue(storeB.isStale)
        XCTAssertEqual(storeB.lastKnownAt, savedAt)
        XCTAssertFalse(storeB.hostedPerri.isEmpty)
        XCTAssertEqual(storeB.hostedPerri, storeA.hostedPerri)
        XCTAssertEqual(storeB.hostedFocuses, storeA.hostedFocuses)
        XCTAssertEqual(storeB.hostedDecisions, storeA.hostedDecisions)
        XCTAssertEqual(storeB.approvalCounts, storeA.approvalCounts)
        XCTAssertEqual(storeB.approvalCounts["kobe"], ["f-48a0007a": 2])
        XCTAssertEqual(storeB.approvalCounts["studio"], ["cody-1a2b3c4d": 2])
        XCTAssertNil(storeB.hostedDecisions["studio"], "A decision resolved before the relaunch is absent after it")
        XCTAssertEqual(storeB.hostedDecisions["kobe"]?.map(\.requestId), ["req-0a1b2c3d"])
        XCTAssertTrue(storeB.hasLastKnownContent)

        let perri = storeB.perriSections(primaryName: primaryName)
        XCTAssertEqual(perri.map(\.host.name), ["kobe", "studio"])
        XCTAssertTrue(perri.allSatisfy { $0.isLastKnown }, "Relaunched content is last-known")
        XCTAssertEqual(storeB.mergedQueue(primaryName: primaryName).filter { $0.kind == .decision }.compactMap(\.host),
                       ["kobe"])
        XCTAssertTrue(storeB.mergedQueue(primaryName: primaryName).allSatisfy { $0.isLastKnown })
    }

    func testARelaunchedPhoneDropsHeldDecisionsOnceItIsConnectedButKeepsLastKnownPerri() async throws {
        let cacheA = makeCache()
        let (storeA, transportA) = await makeStore(cache: cacheA)
        try await populateHosts(via: transportA)
        // The store must outlive its frames: it is what writes them to the cache (its sinks are weak).
        withExtendedLifetime(storeA) { cacheA.flush() }
        let (storeB, transportB) = await makeStore(cache: makeCache(), connect: false)
        XCTAssertEqual(storeB.hostedDecisions.keys.sorted(), ["kobe", "studio"])

        await setLink(true, transportB)

        XCTAssertFalse(storeB.isStale)
        XCTAssertTrue(storeB.hostedDecisions.isEmpty)
        XCTAssertEqual(storeB.hostedPerri["kobe"]?.queue.count, 3)
        XCTAssertEqual(storeB.hostedFocuses["studio"]?.count, 3)
    }

    func testAHostedCurrentPRSurvivesARelaunchAndLabelsItsFocus() async throws {
        let cacheA = makeCache()
        let (storeA, transportA) = await makeStore(cache: cacheA)
        await deliver(focusFrame(host: "kobe", tags: ["t1", "t2"]), via: transportA)
        await deliver(perriFrame(host: "kobe", tag: "t1", current: currentPR("acme/api", 7)), via: transportA)
        withExtendedLifetime(storeA) { cacheA.flush() }

        let (storeB, _) = await makeStore(cache: makeCache(), connect: false)

        XCTAssertEqual(storeB.hostedPerri["kobe"]?.currents["t1"]?.prNumber, 7)
        let section = try XCTUnwrap(storeB.focusSections(primaryName: primaryName).first)
        XCTAssertEqual(section.host.name, "kobe", "A host known only from its last-known content is still a Mac")
        XCTAssertFalse(section.host.connected)
        var secondaries: [String: String] = [:]
        for row in section.rows {
            if case let .focus(meta, _, secondary, _) = row { secondaries[meta.tag] = secondary ?? "" }
        }
        XCTAssertEqual(secondaries["t1"], "#7 · api")
        XCTAssertEqual(secondaries["t2"], FocusPRLabel.noPR)
    }
}
