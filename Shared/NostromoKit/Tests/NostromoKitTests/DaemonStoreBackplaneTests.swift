// NostromoKit — DaemonStoreBackplaneTests.swift
//
// `DaemonStore` over the backplane transport (W11): last-known content that survives a drop and a
// relaunch (W11-7/9, PRD-AC22), mail/calendar/todos that never arrive (W11-8, Q2), per-host
// collections that never collide with the primary's (W10), the display-only "needs you" count, and
// `wipeAll()` (W11-3) which must leave nothing in memory or on disk.
//
// The store is driven through a fake `DaemonTransport`, so no socket is opened. Its sinks hop to the
// main run loop, so each helper lets the main loop turn before the test reads the store.

import XCTest
import Combine
@testable import NostromoKit

// MARK: - Fake transport

@MainActor
private final class FakeDaemonTransport: DaemonTransport {
    let connectedSubject = CurrentValueSubject<Bool, Never>(false)
    let stateSubject = CurrentValueSubject<ConnectionState, Never>(.connecting)
    let frames = PassthroughSubject<HostedServerMsg, Never>()
    private(set) var sentTypes: [String] = []

    var connected: Bool { connectedSubject.value }
    var connectedPublisher: AnyPublisher<Bool, Never> { connectedSubject.eraseToAnyPublisher() }
    var framePublisher: AnyPublisher<HostedServerMsg, Never> { frames.eraseToAnyPublisher() }
    var connectionStatePublisher: AnyPublisher<ConnectionState, Never> { stateSubject.eraseToAnyPublisher() }

    func start() {}
    func stop() {}
    func send(_ msg: some Encodable) {
        if let data = try? JSONEncoder().encode(msg),
           let type = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["type"] as? String {
            sentTypes.append(type)
        }
    }
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

// MARK: - Frames

private enum Sample {
    static let motherJobs = #"{"type":"mother_jobs","jobs":[{"id":"j1","state":"running","title":"Primary job"}]}"#
    static let sessionList = #"{"type":"session_list_resp","sessions":[{"tag":"cody-1","agent_name":"cody","view_name":"v","session_id":"s1","alive":true,"remote_control":false,"state":"idle"}]}"#
    static let focusList = #"{"type":"focus_list_resp","focuses":[{"tag":"perri","display_name":"Perri","agent_name":"perri","is_built_in":true}]}"#
    static let perriState = #"{"type":"perri_state","tag":"perri","queue":[{"repo":"acme/web","number":42,"title":"feat","author":"alice","bucket":"requested","new_activity":true,"url":"https://github.com/acme/web/pull/42","ci_state":"success","head_sha":"abc123"}],"current":{"pr_number":42,"repo":"acme/web","title":"feat","author":"alice","url":"https://github.com/acme/web/pull/42","diff":"","stale":false,"ci_checks":[],"additions":1,"deletions":1,"changed_files":1,"head_sha":"abc123","diff_too_large":false}}"#
    static let fredState = #"{"type":"fred_state","mailbox":{"unread_count":0,"items":[],"stale":false},"calendar":{"events":[],"sweater":"sage","stale":false}}"#
    static let teriState = #"{"type":"teri_state","todos":{"items":[],"stale":false}}"#
    static let decision = #"{"type":"decision_request","tag":"fred","request_id":"req-1","prompt":"Deploy?","choices":[{"id":"yes","label":"Yes"}]}"#
    static let activity = #"{"type":"activity","ts":"2026-01-01T00:00:00Z","agent":"perri","kind":"tool_use","summary":"reading a file","focus_tag":"perri","seq":7}"#

    static func awaitingJob(_ id: String) -> String {
        #"{"id":"\#(id)","state":"awaiting","title":"Needs an answer"}"#
    }
    static func jobs(_ jobs: [String], host: String? = nil) -> String {
        let hostKey = host.map { #","host":"\#($0)""# } ?? ""
        return #"{"type":"mother_jobs"\#(hostKey),"jobs":[\#(jobs.joined(separator: ","))]}"#
    }
    static func job(_ id: String, state: String = "running") -> String {
        #"{"id":"\#(id)","state":"\#(state)","title":"T-\#(id)"}"#
    }
    static func hosts(_ entries: [(String, String)]) -> String {
        let list = entries.map { #"{"name":"\#($0.0)","egress":"\#($0.1)"}"# }.joined(separator: ",")
        return #"{"type":"hosts","hosts":[\#(list)]}"#
    }
}

@MainActor
final class DaemonStoreBackplaneTests: XCTestCase {

    private let savedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private var directory: URL!
    private var cacheURL: URL { directory.appendingPathComponent("content-cache.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DaemonStoreBackplaneTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dir = directory!
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: Helpers

    private func makeCache() -> ContentCache {
        ContentCache(url: cacheURL, debounce: 60, now: { [savedAt] in savedAt })
    }

    private func makeStore(cache: ContentCache? = nil,
                           transport suppliedTransport: FakeDaemonTransport? = nil) async
        -> (store: DaemonStore, transport: FakeDaemonTransport) {
        let (store, transport) = await MainActor.run { () -> (DaemonStore, FakeDaemonTransport) in
            let transport = suppliedTransport ?? FakeDaemonTransport()
            return (DaemonStore(client: transport, cache: cache), transport)
        }
        await letMainLoopTurn()   // the transport's initial "disconnected" is delivered first
        return (store, transport)
    }

    private func deliver(_ json: String, via transport: FakeDaemonTransport) async {
        transport.frames.send(ServerMsg.decodeHosted(from: Data(json.utf8)))
        await letMainLoopTurn()
    }

    /// A cache file written by an earlier run of the app.
    private func seedCache(_ frames: [(host: String?, json: String)]) {
        let earlier = makeCache()
        for frame in frames { earlier.record(host: frame.host, raw: Data(frame.json.utf8)) }
        earlier.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path), "the seed must reach disk")
    }

    // MARK: - Hydrating from the cache

    func testHydratingFromACacheMarksTheContentStaleWithTheSavedTime() async throws {
        seedCache([(nil, Sample.motherJobs), (nil, Sample.sessionList), (nil, Sample.focusList)])

        let (store, _) = await makeStore(cache: makeCache())

        XCTAssertTrue(store.isStale)
        XCTAssertEqual(store.lastKnownAt, savedAt)
        XCTAssertEqual(store.motherJobs.map(\.id), ["j1"])
        XCTAssertEqual(Array(store.sessions.keys), ["cody-1"])
        XCTAssertEqual(Array(store.focuses.keys), ["perri"])
        XCTAssertTrue(store.hasLastKnownContent)
    }

    func testMotherJobsReceivedStaysFalseUntilALiveFrameArrives() async throws {
        seedCache([(nil, Sample.motherJobs)])
        let (store, transport) = await makeStore(cache: makeCache())
        XCTAssertFalse(store.motherJobsReceived, "Cached content is not a live answer")

        transport.connectedSubject.send(true)
        await letMainLoopTurn()
        XCTAssertFalse(store.motherJobsReceived, "Connecting alone is not a live mother_jobs frame")

        await deliver(Sample.jobs([Sample.job("j2")]), via: transport)
        XCTAssertTrue(store.motherJobsReceived)
        XCTAssertEqual(store.motherJobs.map(\.id), ["j2"])
    }

    func testAnEmptyCacheLeavesTheStoreEmpty() async throws {
        let (store, _) = await makeStore(cache: makeCache())
        XCTAssertFalse(store.hasLastKnownContent)
        XCTAssertNil(store.lastKnownAt)
        XCTAssertFalse(store.motherJobsReceived)
    }

    // MARK: - Dropping and reconnecting

    func testADisconnectWithACacheKeepsLastKnownContentAndAReconnectClearsStale() async throws {
        let (store, transport) = await makeStore(cache: makeCache())
        transport.connectedSubject.send(true)
        await letMainLoopTurn()
        for frame in [Sample.motherJobs, Sample.sessionList, Sample.focusList, Sample.perriState] {
            await deliver(frame, via: transport)
        }
        XCTAssertFalse(store.isStale)
        XCTAssertFalse(store.motherJobs.isEmpty)

        transport.connectedSubject.send(false)
        await letMainLoopTurn()

        XCTAssertFalse(store.connected)
        XCTAssertTrue(store.isStale, "What is on screen is now last-known")
        XCTAssertEqual(store.motherJobs.map(\.id), ["j1"])
        XCTAssertEqual(Array(store.sessions.keys), ["cody-1"])
        XCTAssertEqual(Array(store.focuses.keys), ["perri"])
        XCTAssertEqual(store.perriQueue.count, 1)
        XCTAssertTrue(store.hasLastKnownContent)

        transport.connectedSubject.send(true)
        await letMainLoopTurn()
        XCTAssertFalse(store.isStale, "A reconnect clears stale")
        XCTAssertNil(store.lastKnownAt)
    }

    func testADisconnectWithoutACacheStillClearsTheContent() async throws {
        let (store, transport) = await makeStore(cache: nil)
        transport.connectedSubject.send(true)
        await letMainLoopTurn()
        for frame in [Sample.motherJobs, Sample.sessionList, Sample.focusList, Sample.perriState] {
            await deliver(frame, via: transport)
        }
        XCTAssertTrue(store.hasLastKnownContent)

        transport.connectedSubject.send(false)
        await letMainLoopTurn()

        XCTAssertTrue(store.motherJobs.isEmpty)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(store.focuses.isEmpty)
        XCTAssertTrue(store.perriQueue.isEmpty)
        XCTAssertFalse(store.hasLastKnownContent)
        XCTAssertFalse(store.isStale, "The legacy transport shows nothing rather than something stale")
    }

    // MARK: - Fred and Teri (Q2)

    func testWithheldNotSharedMarksFredAndTeriAsNotShared() async throws {
        let (store, transport) = await makeStore(cache: makeCache())
        transport.connectedSubject.send(true)
        await letMainLoopTurn()

        await deliver(#"{"type":"withheld","topics":["fred","teri"],"reason":"not_shared"}"#, via: transport)

        XCTAssertTrue(store.isNotShared("fred"))
        XCTAssertTrue(store.isNotShared("teri"))
        XCTAssertFalse(store.isNotShared("work"), "Only the topics named are not shared")
        XCTAssertNil(store.fredMailbox)
        XCTAssertNil(store.teriTodos)
    }

    func testAWithholdForAnotherReasonIsNotReportedAsNotShared() async throws {
        let (store, transport) = await makeStore(cache: makeCache())
        transport.connectedSubject.send(true)
        await letMainLoopTurn()

        await deliver(#"{"type":"withheld","topics":["fred"],"reason":"requires_secure_connection"}"#, via: transport)

        XCTAssertFalse(store.isNotShared("fred"))
    }

    func testFredAndTeriFramesAreNeverStoredOverTheBackplane() async throws {
        // The fixtures must be real frames, or this test would pass for the wrong reason.
        guard case .fredState = ServerMsg.decode(from: Data(Sample.fredState.utf8)) else {
            return XCTFail("fred_state fixture does not decode")
        }
        guard case .teriState = ServerMsg.decode(from: Data(Sample.teriState.utf8)) else {
            return XCTFail("teri_state fixture does not decode")
        }
        let cache = makeCache()
        let (store, transport) = await makeStore(cache: cache)
        transport.connectedSubject.send(true)
        await letMainLoopTurn()

        await deliver(Sample.fredState, via: transport)
        await deliver(Sample.teriState, via: transport)
        await deliver(Sample.motherJobs, via: transport)   // proves the frames before it were processed

        XCTAssertEqual(store.motherJobs.map(\.id), ["j1"])
        XCTAssertNil(store.fredMailbox)
        XCTAssertNil(store.fredCalendar)
        XCTAssertNil(store.teriTodos)

        cache.flush()
        let text = (try? String(contentsOf: cacheURL, encoding: .utf8)) ?? ""
        XCTAssertFalse(text.contains("fred_state"))
        XCTAssertFalse(text.contains("teri_state"))
    }

    // MARK: - wipeAll (W11-3)

    func testWipeAllEmptiesEveryCollectionAndDeletesTheCacheFile() async throws {
        let cache = makeCache()
        let (store, transport) = await makeStore(cache: cache)
        transport.connectedSubject.send(true)
        await letMainLoopTurn()
        let frames = [
            Sample.focusList, Sample.sessionList, Sample.motherJobs, Sample.perriState,
            Sample.jobs([Sample.job("k1")], host: "kobe"),
            #"{"type":"session_list_resp","host":"kobe","sessions":[{"tag":"kobe-1","agent_name":"cody","view_name":"v","session_id":"s","alive":true,"remote_control":false,"state":"idle"}]}"#,
            #"{"type":"focus_list_resp","host":"kobe","focuses":[{"tag":"kobe-f","display_name":"F","agent_name":"cody","is_built_in":false}]}"#,
            Sample.hosts([("kobe", "work")]),
            Sample.jobs([Sample.awaitingJob("a1")]),
            #"{"type":"approval_pending","tag":"cody-1","count":2}"#,
            Sample.decision,
            Sample.activity,
        ]
        for frame in frames { await deliver(frame, via: transport) }

        // Everything is populated first, so the emptiness below is the wipe's doing.
        XCTAssertFalse(store.sessions.isEmpty)
        XCTAssertFalse(store.focuses.isEmpty)
        XCTAssertFalse(store.motherJobs.isEmpty)
        XCTAssertFalse(store.perriQueue.isEmpty)
        XCTAssertFalse(store.perriCurrentPr.isEmpty)
        XCTAssertFalse(store.hostedMotherJobs.isEmpty)
        XCTAssertFalse(store.hostedSessions.isEmpty)
        XCTAssertFalse(store.hostedFocuses.isEmpty)
        XCTAssertFalse(store.hostInfos.isEmpty)
        XCTAssertFalse(store.hostEgress.isEmpty)
        XCTAssertFalse(store.needsYouCount.isEmpty)
        XCTAssertFalse(store.pendingDecisions.isEmpty)
        XCTAssertFalse(store.activityModels.isEmpty)
        cache.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))

        store.wipeAll()

        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(store.focuses.isEmpty)
        XCTAssertTrue(store.motherJobs.isEmpty)
        XCTAssertTrue(store.perriQueue.isEmpty)
        XCTAssertTrue(store.perriCurrentPr.isEmpty)
        XCTAssertTrue(store.hostedMotherJobs.isEmpty)
        XCTAssertTrue(store.hostedSessions.isEmpty)
        XCTAssertTrue(store.hostedFocuses.isEmpty)
        XCTAssertTrue(store.hostInfos.isEmpty)
        XCTAssertTrue(store.hostEgress.isEmpty)
        XCTAssertTrue(store.needsYouCount.isEmpty)
        XCTAssertTrue(store.pendingDecisions.isEmpty)
        XCTAssertTrue(store.activityModels.isEmpty)
        XCTAssertFalse(store.hasLastKnownContent)
        XCTAssertFalse(store.isStale)
        XCTAssertNil(store.lastKnownAt)
        XCTAssertFalse(store.motherJobsReceived)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path), "The cache file is deleted")
    }

    func testARelaunchAfterWipeAllStartsEmpty() async throws {
        let cache = makeCache()
        let (store, transport) = await makeStore(cache: cache)
        transport.connectedSubject.send(true)
        await letMainLoopTurn()
        await deliver(Sample.motherJobs, via: transport)
        await deliver(Sample.sessionList, via: transport)
        cache.flush()

        store.wipeAll()

        let (relaunched, _) = await makeStore(cache: makeCache())
        XCTAssertTrue(relaunched.motherJobs.isEmpty)
        XCTAssertTrue(relaunched.sessions.isEmpty)
        XCTAssertFalse(relaunched.hasLastKnownContent)
        XCTAssertFalse(relaunched.isStale)
        XCTAssertNil(relaunched.lastKnownAt)
    }

    func testNothingRecordedBeforeWipeAllComesBackOnAFlush() async throws {
        let cache = makeCache()
        let (store, transport) = await makeStore(cache: cache)
        transport.connectedSubject.send(true)
        await letMainLoopTurn()
        await deliver(Sample.motherJobs, via: transport)
        store.wipeAll()

        cache.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path),
                       "Nothing recorded before the wipe may come back")
    }

    // MARK: - Hosts (W10)

    func testFramesNamingAHostLandInThatHostsCollectionsAndNeverInThePrimarys() async throws {
        let (store, transport) = await makeStore(cache: makeCache())
        transport.connectedSubject.send(true)
        await letMainLoopTurn()

        await deliver(Sample.jobs([Sample.job("shared-id", state: "running")], host: "kobe"), via: transport)

        XCTAssertEqual(store.hostedMotherJobs["kobe"]?.map(\.id), ["shared-id"])
        XCTAssertTrue(store.motherJobs.isEmpty, "A satellite's job is not the primary's")
        XCTAssertFalse(store.motherJobsReceived, "Only the primary's own frame counts as the live answer")
    }

    func testTwoHostsAndThePrimaryCanHoldTheSameJobIdWithoutColliding() async throws {
        let (store, transport) = await makeStore(cache: makeCache())
        transport.connectedSubject.send(true)
        await letMainLoopTurn()

        await deliver(Sample.jobs([Sample.job("same", state: "running")]), via: transport)
        await deliver(Sample.jobs([Sample.job("same", state: "queued")], host: "kobe"), via: transport)
        await deliver(Sample.jobs([Sample.job("same", state: "paused")], host: "studio"), via: transport)

        XCTAssertEqual(store.motherJobs.map(\.state), ["running"])
        XCTAssertEqual(store.hostedMotherJobs["kobe"]?.map(\.state), ["queued"])
        XCTAssertEqual(store.hostedMotherJobs["studio"]?.map(\.state), ["paused"])
    }

    func testAHostsSessionsAndFocusesAreKeptPerHost() async throws {
        let (store, transport) = await makeStore(cache: makeCache())
        transport.connectedSubject.send(true)
        await letMainLoopTurn()

        await deliver(#"{"type":"session_list_resp","host":"kobe","sessions":[{"tag":"kobe-1","agent_name":"cody","view_name":"v","session_id":"s","alive":true,"remote_control":false,"state":"idle"}]}"#, via: transport)
        await deliver(#"{"type":"focus_list_resp","host":"kobe","focuses":[{"tag":"kobe-f","display_name":"F","agent_name":"cody","is_built_in":false}]}"#, via: transport)

        XCTAssertEqual(store.hostedSessions["kobe"]?.map(\.tag), ["kobe-1"])
        XCTAssertEqual(store.hostedFocuses["kobe"]?.map(\.tag), ["kobe-f"])
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(store.focuses.isEmpty)
    }

    func testHostedFramesFromACacheAreRestoredToTheirHost() async throws {
        seedCache([(nil, Sample.motherJobs), ("kobe", Sample.jobs([Sample.job("k1")], host: "kobe"))])

        let (store, _) = await makeStore(cache: makeCache())

        XCTAssertEqual(store.motherJobs.map(\.id), ["j1"])
        XCTAssertEqual(store.hostedMotherJobs["kobe"]?.map(\.id), ["k1"])
    }

    func testHostsFramesFillEgressAndTheEgressOutlivesTheHost() async throws {
        let (store, transport) = await makeStore(cache: makeCache())
        transport.connectedSubject.send(true)
        await letMainLoopTurn()

        await deliver(Sample.hosts([("kobe", "work"), ("studio", "personal")]), via: transport)
        XCTAssertEqual(store.hostEgress, ["kobe": .work, "studio": .personal])
        XCTAssertEqual(store.hostInfos.map(\.name), ["kobe", "studio"])

        await deliver(Sample.hosts([("studio", "personal")]), via: transport)
        XCTAssertEqual(store.hostInfos.map(\.name), ["studio"], "The connected list follows the frame")
        XCTAssertEqual(store.hostEgress["kobe"], .work, "Kobe's last-known rows keep their shape")
        XCTAssertEqual(store.hostEgress["studio"], .personal)
    }

    func testAHostsLaterEgressReplacesTheEarlierOne() async throws {
        let (store, transport) = await makeStore(cache: makeCache())
        transport.connectedSubject.send(true)
        await letMainLoopTurn()

        await deliver(Sample.hosts([("studio", "work")]), via: transport)
        await deliver(Sample.hosts([("studio", "personal")]), via: transport)

        XCTAssertEqual(store.hostEgress["studio"], .personal)
    }

    // MARK: - Needs you (display only)

    func testNeedsYouCountsAwaitingJobsAndHeldApprovalsPerHost() async throws {
        let (store, transport) = await makeStore(cache: makeCache())
        transport.connectedSubject.send(true)
        await letMainLoopTurn()

        await deliver(Sample.jobs([Sample.awaitingJob("p1"), Sample.job("p2")]), via: transport)
        await deliver(Sample.jobs([Sample.awaitingJob("k1"), Sample.awaitingJob("k2"), Sample.job("k3")], host: "kobe"),
                      via: transport)
        await deliver(#"{"type":"approval_pending","tag":"cody-1","count":3,"host":"kobe"}"#, via: transport)

        XCTAssertEqual(store.needsYouCount[""], 1, "The primary: one awaiting job")
        XCTAssertEqual(store.needsYouCount["kobe"], 5, "Kobe: two awaiting jobs and three held approvals")
    }

    func testApprovalPendingCountsAreReplacedPerFocusAndCanReturnToZero() async throws {
        let (store, transport) = await makeStore(cache: makeCache())
        transport.connectedSubject.send(true)
        await letMainLoopTurn()

        await deliver(#"{"type":"approval_pending","tag":"cody-1","count":2}"#, via: transport)
        await deliver(#"{"type":"approval_pending","tag":"cody-2","count":1}"#, via: transport)
        XCTAssertEqual(store.needsYouCount[""], 3)

        await deliver(#"{"type":"approval_pending","tag":"cody-1","count":0}"#, via: transport)
        XCTAssertEqual(store.needsYouCount[""], 1)
    }

    // MARK: - Transport

    func testAWebSocketStyleTransportCannotMutateButTheLegacyClientCan() async throws {
        let (store, _) = await makeStore()
        XCTAssertFalse(store.canMutate)

        let legacy = DaemonStore(client: NetworkClient())
        XCTAssertTrue(legacy.canMutate)
    }

    func testATransportThatDoesNotSayItCanMutateCannotMutate() async throws {
        XCTAssertFalse(FakeDaemonTransport().canMutate, "The protocol default fails safe")
    }

    func testTheWebSocketTransportBehindADaemonStoreCannotMutate() async throws {
        let credential = DeviceCredential(token: "t", deviceId: "d", serverId: "s", name: "n")
        let webSocket = WebSocketClient(host: "127.0.0.1", port: 1, credential: credential,
                                        probe: FakeLocalNetworkProbe())

        XCTAssertFalse(DaemonStore(client: webSocket).canMutate)
    }

    func testATranscriptStoreCanMutateOnlyOverTheLegacyTransport() async throws {
        let credential = DeviceCredential(token: "t", deviceId: "d", serverId: "s", name: "n")
        let webSocket = WebSocketClient(host: "127.0.0.1", port: 1, credential: credential,
                                        probe: FakeLocalNetworkProbe())

        XCTAssertFalse(TranscriptStore(client: webSocket).canMutate, "No composer, answers or Stop over the WebSocket")
        XCTAssertFalse(TranscriptStore(client: FakeDaemonTransport()).canMutate)
        XCTAssertTrue(TranscriptStore(client: NetworkClient()).canMutate)
    }

    func testConnectionStateFollowsTheTransportsStatePublisher() async throws {
        let (store, transport) = await makeStore(cache: makeCache())

        for state in [ConnectionState.unreachable, .localNetworkDenied, .notPaired(reason: "revoked"), .connected] {
            transport.stateSubject.send(state)
            await letMainLoopTurn()
            XCTAssertEqual(store.connectionState, state)
        }
    }

    // MARK: - hasLastKnownContent

    func testHasLastKnownContentIsFalseUntilSomethingArrivesThenTrueForHostedContentToo() async throws {
        let (store, transport) = await makeStore(cache: makeCache())
        transport.connectedSubject.send(true)
        await letMainLoopTurn()
        XCTAssertFalse(store.hasLastKnownContent)

        await deliver(Sample.jobs([Sample.job("k1")], host: "kobe"), via: transport)

        XCTAssertTrue(store.hasLastKnownContent, "A satellite's last-known rows are content too")
    }

    // MARK: - A frame in flight after wipeAll

    func testAFrameThatArrivesAfterWipeAllNeitherRefillsTheStoreNorTheCache() async throws {
        let cache = makeCache()
        let (store, transport) = await makeStore(cache: cache)
        transport.connectedSubject.send(true)
        await letMainLoopTurn()
        for frame in [Sample.motherJobs, Sample.sessionList, Sample.focusList] {
            await deliver(frame, via: transport)
        }
        cache.flush()
        XCTAssertFalse(store.motherJobs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))

        store.wipeAll()
        XCTAssertTrue(store.motherJobs.isEmpty)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(store.focuses.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))

        // The socket was not yet closed: more frames arrive, with no new connected event in between.
        await deliver(Sample.motherJobs, via: transport)
        await deliver(Sample.sessionList, via: transport)
        await deliver(Sample.focusList, via: transport)
        await deliver(Sample.jobs([Sample.job("k1")], host: "kobe"), via: transport)

        XCTAssertTrue(store.motherJobs.isEmpty, "A wiped store stays wiped")
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(store.focuses.isEmpty)
        XCTAssertTrue(store.hostedMotherJobs.isEmpty)
        XCTAssertFalse(store.motherJobsReceived)
        XCTAssertFalse(store.hasLastKnownContent)
        cache.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path),
                       "A late frame must not put the revoked server's content back on disk")
    }

    func testANewConnectionAfterWipeAllAcceptsFramesAgain() async throws {
        let cache = makeCache()
        let (store, transport) = await makeStore(cache: cache)
        transport.connectedSubject.send(true)
        await letMainLoopTurn()
        await deliver(Sample.motherJobs, via: transport)
        store.wipeAll()
        await deliver(Sample.motherJobs, via: transport)
        XCTAssertTrue(store.motherJobs.isEmpty)

        // Pairing again: the new client connects, which lifts the guard.
        transport.connectedSubject.send(false)
        await letMainLoopTurn()
        transport.connectedSubject.send(true)
        await letMainLoopTurn()
        await deliver(Sample.jobs([Sample.job("fresh")]), via: transport)

        XCTAssertEqual(store.motherJobs.map(\.id), ["fresh"])
        XCTAssertTrue(store.hasLastKnownContent)
        cache.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path), "The new pairing's content is cached again")
    }

    // MARK: - Duplicate keys in a frame must not trap

    func testDuplicateTopicsInAWithheldFrameAreCollapsed() async throws {
        let (store, transport) = await makeStore(cache: makeCache())
        transport.connectedSubject.send(true)
        await letMainLoopTurn()

        await deliver(#"{"type":"withheld","topics":["fred","fred","teri"],"reason":"not_shared"}"#, via: transport)

        XCTAssertEqual(store.withheldReasons, ["fred": "not_shared", "teri": "not_shared"])
        XCTAssertEqual(store.withheldTopics, ["fred", "teri"])
        XCTAssertTrue(store.isNotShared("fred"))
    }

    func testDuplicateTagsInASessionListKeepTheLastEntry() async throws {
        let (store, transport) = await makeStore(cache: makeCache())
        transport.connectedSubject.send(true)
        await letMainLoopTurn()
        func session(_ tag: String, agent: String) -> String {
            #"{"tag":"\#(tag)","agent_name":"\#(agent)","view_name":"v","session_id":"s","alive":true,"remote_control":false,"state":"idle"}"#
        }

        let entries = [session("cody-1", agent: "first"), session("perri-1", agent: "other"),
                       session("cody-1", agent: "last")].joined(separator: ",")
        await deliver(#"{"type":"session_list_resp","sessions":[\#(entries)]}"#, via: transport)

        XCTAssertEqual(Set(store.sessions.keys), ["cody-1", "perri-1"])
        XCTAssertEqual(store.sessions["cody-1"]?.agentName, "last")
        XCTAssertEqual(store.sessions["perri-1"]?.agentName, "other")
    }

    func testDuplicateTagsInAFocusListKeepTheLastEntryForBothListFrames() async throws {
        let (store, transport) = await makeStore(cache: makeCache())
        transport.connectedSubject.send(true)
        await letMainLoopTurn()
        func focus(_ tag: String, name: String) -> String {
            #"{"tag":"\#(tag)","display_name":"\#(name)","agent_name":"cody","is_built_in":false}"#
        }

        let listed = [focus("f1", name: "First"), focus("f2", name: "Other"),
                      focus("f1", name: "Last")].joined(separator: ",")
        await deliver(#"{"type":"focus_list_resp","focuses":[\#(listed)]}"#, via: transport)
        XCTAssertEqual(Set(store.focuses.keys), ["f1", "f2"])
        XCTAssertEqual(store.focuses["f1"]?.displayName, "Last")

        let updated = [focus("g1", name: "A"), focus("g1", name: "B")].joined(separator: ",")
        await deliver(#"{"type":"focus_registry_updated","focuses":[\#(updated)]}"#, via: transport)
        XCTAssertEqual(Set(store.focuses.keys), ["g1"])
        XCTAssertEqual(store.focuses["g1"]?.displayName, "B")
    }
}
