import XCTest
import AppKit
import Combine
import NostromoKit

// MotherLimiterStrip, MotherJobListViewModel, MotherJobDetail, MotherBrokerClient and AppStore are compiled
// into this target directly.
//
// Mother's backpressure limiter, from outside (display only; nothing here changes the limiter). The contract is
// Mother's golden fixture, `tests/fixtures/mother-contract/limiter_block.json`:
//
//   - The strip is one line: `Limiter (observe) · would allow 3 of 5 · 4 running · backoff: <detail> · last 429 6m ago`.
//     Observe values are labelled "would"; enforce says "3 of 5 allowed". A stale or faulted limiter says
//     "limiter not running — fixed concurrency". Mode `off` or no block: hidden, empty text.
//   - The popover rows carry the on-demand values (burn, reserve, interactive, overage, gate, last distress).
//   - A ready or queued job the limiter lists shows `Waiting: <reason>` (plus `(would: ...)` when it differs).
//   - The client asks for the `limiter` category only when advertised, and reports `.limiter(block)` (nil when
//     the snapshot has none). The store folds `paused_for_limiter` to awaiting and holds the block.

// MARK: - Fixtures

private enum LimiterFixture {
    static let url: URL = URL(fileURLWithPath: #filePath)   // .../macOS/NostromoTests/<this file>
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("tests/fixtures/mother-contract/limiter_block.json")

    /// The fixture's `limiter_block`.
    static func raw() throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["limiter_block"] as? [String: Any])
    }

    static func raw(_ edit: (inout [String: Any]) -> Void) throws -> [String: Any] {
        var block = try raw()
        edit(&block)
        return block
    }

    static func block(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> MotherLimiter {
        try XCTUnwrap(MotherLimiter.decode(try raw(edit)))
    }
}

private func lmWaiting(reason: String = "next to start", would: String? = "reserve held for interactive work")
    throws -> MotherLimiter.Waiting {
    var wait: [String: Any] = ["code": "next", "reason": reason, "source": "dispatch", "advisory": false]
    if let would { wait["would"] = ["code": "reserve", "reason": would] }
    return try XCTUnwrap(MotherLimiter.decodeWait(wait))
}

private func lmJob(_ id: String = "j1", state: String, wait: MotherLimiter.Waiting? = nil) -> MotherJob {
    MotherJob(id: id, state: state, repo: "nostromo", isolation: "worktree", title: "title-\(id)",
              createdAt: Date(timeIntervalSince1970: 1_000), startedAt: nil, finishedAt: nil,
              planPath: nil, question: nil, pausedReason: nil, adherenceStatus: nil, currentTier: nil,
              limiterWait: wait)
}

private func allSubviews(_ view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap(allSubviews)
}

// MARK: - Strip line and popover

final class MotherLimiterStripTests: XCTestCase {

    private func strip(_ limiter: MotherLimiter?) -> MotherLimiterStrip {
        let s = MotherLimiterStrip(observeStore: false)
        s.apply(limiter: limiter)
        return s
    }

    func testObserveFixtureLabelsValuesAsWouldAndShowsAllowedEffectiveStateAndLastDistress() throws {
        let s = strip(try LimiterFixture.block())
        XCTAssertTrue(s.isShown)
        XCTAssertEqual(s.labelText,
                       "Limiter (observe) · would allow 3 of 5 · 4 running · backoff: cut 6m ago after 429; +1 in 9m · last 429 6m ago")
    }

    func testObserveDetailLinesCarryEveryOnDemandValue() throws {
        let lines = strip(try LimiterFixture.block()).detailLines
        let text = lines.joined(separator: "\n")
        XCTAssertTrue(lines.contains { $0.hasPrefix("Mode: observe") && $0.contains("would do") }, text)
        let burn = try XCTUnwrap(lines.first { $0.hasPrefix("Burn:") }, text)
        XCTAssertTrue(burn.contains("$0.84/min vs $0.61/min sustainable"), burn)
        XCTAssertTrue(burn.contains("pace 1.38"), burn)
        let reserve = try XCTUnwrap(lines.first { $0.hasPrefix("Reserve:") }, text)
        XCTAssertTrue(reserve.contains("15%"), reserve)
        XCTAssertTrue(reserve.contains("not holding"), reserve)
        let interactive = try XCTUnwrap(lines.first { $0.hasPrefix("Interactive:") }, text)
        XCTAssertTrue(interactive.contains("ok") && interactive.contains("4.2%/h"), interactive)
        XCTAssertTrue(lines.contains("Overage: not in use"), text)
        XCTAssertTrue(lines.contains("Gate: on"), text)
        let distress = try XCTUnwrap(lines.first { $0.hasPrefix("Last distress:") }, text)
        XCTAssertTrue(distress.contains("429") && distress.contains("6m ago") && distress.contains("api retry")
                      && distress.contains("20261106-221000-example"), distress)
        XCTAssertTrue(lines.contains("Distress, 24h: 1"), text)
    }

    func testReserveHoldingAndOverageInUseAreSaid() throws {
        let lines = strip(try LimiterFixture.block {
            $0["reserve"] = ["pct": 15, "holding": true, "enforceable": true]
            $0["overage_in_use"] = true
        }).detailLines
        XCTAssertTrue(lines.contains { $0.hasPrefix("Reserve:") && $0.contains("holding") && !$0.contains("not holding") },
                      "\(lines)")
        XCTAssertTrue(lines.contains("Overage: in use"), "\(lines)")
    }

    func testEnforceDropsTheWouldWordingAndTheObserveNote() throws {
        let s = strip(try LimiterFixture.block { $0["mode"] = "enforce" })
        XCTAssertEqual(s.labelText,
                       "Limiter · 3 of 5 allowed · 4 running · backoff: cut 6m ago after 429; +1 in 9m · last 429 6m ago")
        XCTAssertFalse(s.labelText.contains("would"))
        XCTAssertFalse(s.detailLines.contains { $0.hasPrefix("Mode:") }, "\(s.detailLines)")
    }

    func testBackoffShowsTheBrokersDetailText() throws {
        let s = strip(try LimiterFixture.block {
            $0["concurrency"] = ["ceiling": 5, "allowed": 2, "effective": 2, "state": "backoff", "detail": "cut 1m ago; +1 in 4m"]
        })
        XCTAssertTrue(s.labelText.contains("backoff: cut 1m ago; +1 in 4m"), s.labelText)
    }

    func testRampShowsItsStateWithoutDetail() throws {
        let s = strip(try LimiterFixture.block {
            $0["concurrency"] = ["ceiling": 5, "allowed": 4, "effective": 3, "state": "ramp", "detail": ""]
        })
        XCTAssertTrue(s.labelText.contains("· ramp"), s.labelText)
        XCTAssertFalse(s.labelText.contains("ramp:"), s.labelText)
    }

    func testSteadyStateIsNotSpelledOut() throws {
        let s = strip(try LimiterFixture.block {
            $0["concurrency"] = ["ceiling": 5, "allowed": 5, "effective": 1, "state": "steady", "detail": ""]
            $0["last_distress"] = NSNull()
        })
        XCTAssertEqual(s.labelText, "Limiter (observe) · would allow 5 of 5 · 1 running")
    }

    func testAStaleLimiterSaysItIsNotRunning() throws {
        let s = strip(try LimiterFixture.block { $0["stale"] = true })
        XCTAssertEqual(s.labelText, "Limiter (observe) · limiter not running — fixed concurrency")
        XCTAssertTrue(s.detailLines.contains { $0.hasPrefix("Status:") && $0.contains("limiter not running — fixed concurrency") },
                      "\(s.detailLines)")
    }

    func testAFaultedLimiterSaysItIsNotRunningAndKeepsTheWhy() throws {
        let s = strip(try LimiterFixture.block { $0["fault"] = ["at": "2026-11-06T22:00:00Z", "why": "state.json unreadable"] })
        XCTAssertEqual(s.labelText, "Limiter (observe) · limiter not running — fixed concurrency")
        XCTAssertTrue(s.detailLines.contains { $0.hasPrefix("Status:") && $0.contains("state.json unreadable") },
                      "\(s.detailLines)")
    }

    func testModeOffAndNoBlockAreHiddenWithEmptyText() throws {
        for limiter in [MotherLimiter.decode(["v": 1, "mode": "off"]), nil] {
            let s = strip(limiter)
            XCTAssertFalse(s.isShown)
            XCTAssertEqual(s.labelText, "")
        }
        let off = strip(MotherLimiter.decode(["v": 1, "mode": "off"]))
        XCTAssertTrue(off.detailLines.isEmpty || !off.isShown)
    }

    func testAnUnknownModeIsShownWithItsName() throws {
        // A newer Mother's mode must not vanish: it shows as `Limiter (<mode>)`.
        let s = strip(try LimiterFixture.block { $0["mode"] = "turbo" })
        XCTAssertTrue(s.isShown)
        XCTAssertTrue(s.labelText.hasPrefix("Limiter (turbo)"), s.labelText)
    }

    func testAnEmptyModeIsHidden() throws {
        let s = strip(try LimiterFixture.block { $0["mode"] = "" })
        XCTAssertFalse(s.isShown)
        XCTAssertEqual(s.labelText, "")
    }

    func testTheStripHidesAgainWhenTheBlockGoesAway() throws {
        let s = strip(try LimiterFixture.block())
        XCTAssertTrue(s.isShown)
        s.apply(limiter: nil)
        XCTAssertFalse(s.isShown)
        XCTAssertEqual(s.labelText, "")
    }

    func testTheStripExposesNoControls() throws {
        let s = strip(try LimiterFixture.block())
        let subviews = allSubviews(s)
        XCTAssertFalse(subviews.contains { $0 is NSButton }, "\(subviews)")
        // The label is an NSTextField (an NSControl); it must be the only one and not editable.
        let controls = subviews.compactMap { $0 as? NSControl }
        XCTAssertEqual(controls.count, 1, "\(controls)")
        XCTAssertTrue(controls.first === s.label)
        XCTAssertFalse(s.label.isEditable)
        XCTAssertNil(s.label.action)
        XCTAssertNil(s.label.target)
    }

    func testWireDecodingIgnoresUnknownKeysAndKeepsUnknownModeAndState() throws {
        let limiter = try LimiterFixture.block {
            $0["future_key"] = ["x": 1]
            $0["concurrency"] = ["ceiling": 5, "allowed": 3, "effective": 4, "state": "wobble"]
        }
        XCTAssertEqual(limiter.concurrency?.state, .unknown("wobble"))
        XCTAssertEqual(limiter.waiting.count, 1)
    }
}

// MARK: - Job wait lines

final class MotherLimiterWaitTests: XCTestCase {

    private func makeVM() throws -> MotherJobListViewModel {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mother-limiter-wait-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return MotherJobListViewModel(focusStore: FocusStore(storageURL: dir.appendingPathComponent("focuses.json")))
    }

    func testAReadyJobShowsWaitingWithTheLimitersWouldWhenItDiffers() throws {
        let job = lmJob(state: "ready", wait: try lmWaiting())
        XCTAssertEqual(MotherJobListViewModel.waitText(for: job),
                       "Waiting: next to start (would: reserve held for interactive work)")
        XCTAssertEqual(try makeVM().rowModel(for: job).waitText,
                       "Waiting: next to start (would: reserve held for interactive work)")
        XCTAssertEqual(MotherJobDetail.waitingLine(for: job),
                       "next to start (would: reserve held for interactive work)")
    }

    func testAQueuedJobWithoutAWouldShowsJustTheReason() throws {
        let job = lmJob(state: "queued", wait: try lmWaiting(reason: "waiting on dependency", would: nil))
        XCTAssertEqual(MotherJobListViewModel.waitText(for: job), "Waiting: waiting on dependency")
        XCTAssertEqual(try makeVM().rowModel(for: job).waitText, "Waiting: waiting on dependency")
        XCTAssertEqual(MotherJobDetail.waitingLine(for: job), "waiting on dependency")
    }

    func testAWouldWithTheSameReasonIsNotRepeated() throws {
        let job = lmJob(state: "ready", wait: try lmWaiting(reason: "same", would: "same"))
        XCTAssertEqual(MotherJobListViewModel.waitText(for: job), "Waiting: same")
    }

    func testARunningJobHasNoWaitEvenWithOneAttached() throws {
        let job = lmJob(state: "running", wait: try lmWaiting())
        XCTAssertNil(MotherJobListViewModel.waitText(for: job))
        XCTAssertNil(try makeVM().rowModel(for: job).waitText)
        XCTAssertNil(MotherJobDetail.waitingLine(for: job))
    }

    func testAJobWithoutAWaitHasNone() throws {
        for state in ["ready", "queued"] {
            let job = lmJob(state: state)
            XCTAssertNil(MotherJobListViewModel.waitText(for: job))
            XCTAssertNil(try makeVM().rowModel(for: job).waitText)
            XCTAssertNil(MotherJobDetail.waitingLine(for: job))
        }
    }

    func testTheSlimJobDecodesLimiterWait() throws {
        let json = """
        {"id":"j9","state":"ready","repo":"r","isolation":"worktree","title":"t",
         "limiter":{"wait":{"code":"next","reason":"next to start","source":"dispatch","advisory":false,
                            "would":{"code":"reserve","reason":"reserve held for interactive work"},
                            "since":"2026-11-06T22:12:00Z"}}}
        """
        let slim = try JSONDecoder().decode(MotherJobSlim.self, from: Data(json.utf8))
        let wait = try XCTUnwrap(slim.toMotherJob().limiterWait)
        XCTAssertEqual(wait.reason, "next to start")
        XCTAssertEqual(wait.code, "next")
        XCTAssertEqual(wait.would?.reason, "reserve held for interactive work")
        XCTAssertEqual(wait.would?.code, "reserve")
    }

    func testTheSlimJobWithoutOrWithAMalformedLimiterStillDecodes() throws {
        for extra in ["", ",\"limiter\":null", ",\"limiter\":\"nope\"", ",\"limiter\":{\"wait\":{}}"] {
            let json = #"{"id":"j9","state":"ready","repo":"r","isolation":"worktree","title":"t"\#(extra)}"#
            let slim = try JSONDecoder().decode(MotherJobSlim.self, from: Data(json.utf8))
            XCTAssertEqual(slim.toMotherJob().id, "j9", extra)
            XCTAssertNil(slim.toMotherJob().limiterWait, extra)
        }
    }
}

// MARK: - Store

final class MotherLimiterStoreTests: XCTestCase {
    private var store: AppStore { AppStore.shared }

    override func setUp() {
        super.setUp()
        store.applyBrokerEventForTesting(.reconnected)
        addTeardownBlock {
            AppStore.shared.applyBrokerEventForTesting(.snapshot([]))
            AppStore.shared.applyBrokerEventForTesting(.reconnected)
        }
    }

    func testALimiterEventSetsTheBlockAndAbsentClearsIt() throws {
        XCTAssertNil(store.motherLimiter)
        let block = try LimiterFixture.block()
        store.applyBrokerEventForTesting(.limiter(block))
        XCTAssertEqual(store.motherLimiter, block)
        store.applyBrokerEventForTesting(.limiter(nil))
        XCTAssertNil(store.motherLimiter)
    }

    func testAReconnectClearsTheBlock() throws {
        store.applyBrokerEventForTesting(.limiter(try LimiterFixture.block()))
        store.applyBrokerEventForTesting(.reconnected)
        XCTAssertNil(store.motherLimiter)
    }

    func testPausedForLimiterFoldsARunningJobToAwaitingLikePausedForQuota() {
        for kind in ["paused_for_quota", "paused_for_limiter"] {
            let id = "fold-\(kind)"
            store.applyBrokerEventForTesting(.snapshot([lmJob(id, state: "running")]))
            store.applyBrokerEventForTesting(.stateChange(jobId: id, eventKind: kind, question: nil,
                                                          pausedReason: "limiter backoff", toState: nil))
            let job = store.motherJobs.first { $0.id == id }
            XCTAssertEqual(job?.state, "awaiting", kind)
            XCTAssertEqual(job?.pausedReason, "limiter backoff", kind)
            XCTAssertNil(job?.question, kind)
        }
    }

    func testAJobThatStartsDropsItsWait() throws {
        let id = "wait-start"
        store.applyBrokerEventForTesting(.snapshot([lmJob(id, state: "ready", wait: try lmWaiting())]))
        XCTAssertNotNil(store.motherJobs.first { $0.id == id }?.limiterWait)
        store.applyBrokerEventForTesting(.stateChange(jobId: id, eventKind: "running", question: nil,
                                                      pausedReason: nil, toState: nil))
        XCTAssertNil(store.motherJobs.first { $0.id == id }?.limiterWait)
    }
}

// MARK: - Broker client

private final class LMRecorder {
    private(set) var events: [BrokerEvent] = []
    /// Every `.limiter(...)` payload, nil where the broker sent no block.
    var limiters: [MotherLimiter?] {
        events.compactMap { if case .limiter(let l) = $0 { return .some(l) } else { return nil } }
    }
    func record(_ event: BrokerEvent) { events.append(event) }
}

extension MotherBrokerClientTests {

    private static let lmClassic = ["state", "activity", "await", "current_activity", "quota"]

    fileprivate func lmHello(_ capabilities: [String]) -> String {
        let caps = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"v":1,"dir":"event","t":"hello","id":"0","ts":"2026-11-06T22:00:00.000Z","data":{"protocol_version":1,"capabilities":[\#(caps)]}}"#
    }

    fileprivate func lmLine(t: String, id: String, data: [String: Any]) throws -> String {
        let envelope: [String: Any] = ["v": 1, "dir": "event", "t": t, "id": id, "ts": "2026-11-06T22:16:04.000Z", "data": data]
        return String(decoding: try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]), as: UTF8.self)
    }

    /// One line from the client (EINTR retried; a 5 s receive timeout ends it).
    fileprivate func lmReadLine() -> String? {
        var buf = Data()
        var byte: UInt8 = 0
        while true {
            let n = Darwin.read(serverFd, &byte, 1)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return nil }
            if byte == 0x0A { break }
            buf.append(byte)
        }
        return String(data: buf, encoding: .utf8)
    }

    /// Connect, send a hello advertising `capabilities`, and return the subscribe command's categories.
    fileprivate func lmSubscribedCategories(_ capabilities: [String]) throws -> [String] {
        try lmConnect(capabilities)
    }

    @discardableResult
    fileprivate func lmConnect(_ capabilities: [String]) throws -> [String] {
        client.start()
        try waitForServerAccept()
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = Darwin.setsockopt(serverFd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        serverWrite(lmHello(capabilities))
        let line = try XCTUnwrap(lmReadLine(), "the client wrote nothing")
        let cmd = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(cmd["t"] as? String, "subscribe")
        let data = try XCTUnwrap(cmd["data"] as? [String: Any])
        let live = XCTestExpectation(description: "connected")
        client.connected.filter { $0 }.first().sink { _ in live.fulfill() }.store(in: &cancellables)
        wait(for: [live], timeout: 10)
        return try XCTUnwrap(data["categories"] as? [String])
    }

    fileprivate func lmWait(_ what: String, _ condition: () -> Bool) {
        let end = Date().addingTimeInterval(10)
        while Date() < end && !condition() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }

    // MARK: Subscribe

    func testSubscribeWithoutLimiterAdvertisedIsUnchanged() throws {
        let categories = try lmSubscribedCategories(Self.lmClassic)
        XCTAssertEqual(Set(categories), Set(Self.lmClassic))
        XCTAssertFalse(categories.contains("limiter"))
    }

    func testSubscribeIncludesLimiterWhenAdvertised() throws {
        let categories = try lmSubscribedCategories(Self.lmClassic + ["limiter"])
        XCTAssertTrue(categories.contains("limiter"), "\(categories)")
        for classic in Self.lmClassic { XCTAssertTrue(categories.contains(classic), "\(classic) missing from \(categories)") }
    }

    // MARK: Snapshot and event

    func testASnapshotWithALimiterBlockDeliversIt() throws {
        let recorder = LMRecorder()
        client.events.sink { recorder.record($0) }.store(in: &cancellables)
        try lmConnect(Self.lmClassic + ["limiter"])
        let block = try LimiterFixture.block()

        serverWrite(try lmLine(t: "snapshot", id: "2",
                               data: ["sub": "main", "jobs": [], "limiter": try LimiterFixture.raw()]))

        lmWait("the limiter event") { recorder.limiters.count == 1 }
        XCTAssertEqual(recorder.limiters[0], block)
    }

    func testASnapshotWithoutALimiterBlockDeliversNil() throws {
        let recorder = LMRecorder()
        client.events.sink { recorder.record($0) }.store(in: &cancellables)
        try lmConnect(Self.lmClassic)

        serverWrite(try lmLine(t: "snapshot", id: "2", data: ["sub": "main", "jobs": []]))

        lmWait("the limiter event") { recorder.limiters.count == 1 }
        XCTAssertNil(recorder.limiters[0] as MotherLimiter?)
    }

    func testALimiterEventDeliversTheBlock() throws {
        let recorder = LMRecorder()
        client.events.sink { recorder.record($0) }.store(in: &cancellables)
        try lmConnect(Self.lmClassic + ["limiter"])
        let block = try LimiterFixture.block()

        serverWrite(try lmLine(t: "limiter", id: "9",
                               data: ["limiter": try LimiterFixture.raw(), "job": "", "category": "limiter"]))

        lmWait("the limiter event") { recorder.limiters.count == 1 }
        XCTAssertEqual(recorder.limiters[0], block)
    }
}
