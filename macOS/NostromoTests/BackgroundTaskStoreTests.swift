import XCTest
import Combine
import NostromoKit

// `BackgroundTaskStore` (BA3): the one place every window's Background activity chip and popover
// read a focus's tasks from.
//
// What it promises (PRD "Multiple windows, restarts, relaunch", design contract §2.3 and §2.7):
// the daemon's snapshot is the truth for a focus, replaced whole each time; Clear Context shows what
// still ran as stopped before the list clears; a lost daemon connection never leaves a task
// "running" (it shows stopped, restart), and a daemon restart keeps those entries in Ended until the
// next Clear Context; every subscriber reads the same list at every delivery; deliveries are
// coalesced to at most 4 a second per tag with the final state always delivered; "seen"
// (what hides a done / failed chip) survives a relaunch, is capped at 200 tags and goes with a
// removed focus.
//
// Time is a clock the test moves and a scheduler the test flushes; the seen marks go to a private
// UserDefaults suite that is removed afterwards. Nothing here touches the real defaults domain.

final class BackgroundTaskStoreTests: XCTestCase {

    // MARK: - Rig

    /// "Now" at the start of every test: 2025-10-09 08:53:20 UTC.
    fileprivate static let start = Date(timeIntervalSince1970: 1_760_000_000)
    private let startMs: UInt64 = 1_760_000_000_000

    fileprivate final class StoreClock {
        var date: Date
        init(_ date: Date) { self.date = date }
        func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
    }

    /// Collects `schedule(delay, work)` calls and runs them on `flush()`.
    fileprivate final class Scheduler {
        private(set) var scheduled: [(delay: TimeInterval, work: () -> Void)] = []
        func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) { scheduled.append((delay, work)) }
        var delays: [TimeInterval] { scheduled.map(\.delay) }
        func flush() {
            while !scheduled.isEmpty {
                let batch = scheduled
                scheduled = []
                batch.forEach { $0.work() }
            }
        }
    }

    /// What one subscriber heard: the tag, the list it read at that moment and the (fake) time.
    fileprivate final class Recorder {
        struct Delivery {
            let tag: String
            let list: BackgroundTaskList
            let at: Date
        }
        private(set) var deliveries: [Delivery] = []
        var tags: [String] { deliveries.map(\.tag) }
        func append(_ delivery: Delivery) { deliveries.append(delivery) }
    }

    fileprivate final class Rig {
        let clock = StoreClock(BackgroundTaskStoreTests.start)
        let scheduler = Scheduler()
        let suite: String
        let defaults: UserDefaults
        private(set) var store: BackgroundTaskStore!
        var bag = Set<AnyCancellable>()

        init(defaults: UserDefaults, suite: String) {
            self.defaults = defaults
            self.suite = suite
            store = makeStore()
        }

        /// A store on this rig's clock, scheduler and defaults (a second one is "the app, relaunched").
        func makeStore() -> BackgroundTaskStore {
            BackgroundTaskStore(now: { [clock] in clock.date },
                                schedule: { [scheduler] delay, work in scheduler.schedule(delay, work) },
                                defaults: defaults)
        }

        func record(_ target: BackgroundTaskStore? = nil) -> Recorder {
            let source = target ?? store!
            let recorder = Recorder()
            source.changes.sink { [weak source, clock] tag in
                guard let source else { return }
                recorder.append(Recorder.Delivery(tag: tag, list: source.list(for: tag), at: clock.date))
            }.store(in: &bag)
            return recorder
        }

        /// Move a second on, then ingest: far enough from the last delivery that it goes out at once.
        func send(_ message: ServerMsg, to target: BackgroundTaskStore? = nil) {
            clock.advance(1)
            (target ?? store!).ingest(message)
        }

        /// The tags the seen map holds in the defaults.
        var persistedSeenTags: Set<String> {
            Set((defaults.dictionary(forKey: "nostromo.background.seen") ?? [:]).keys)
        }
    }

    private func makeRig() throws -> Rig {
        let suite = "BackgroundTaskStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return Rig(defaults: defaults, suite: suite)
    }

    // MARK: - Builders

    private func task(_ id: String,
                      _ kind: TaskKindWire = .shell,
                      status: TaskStatusWire = .running,
                      description: String = "",
                      subagentType: String? = nil,
                      parent: String? = nil,
                      background: Bool? = true,
                      endReason: TaskEndReasonWire? = nil,
                      started: UInt64? = nil,
                      ended: UInt64? = nil,
                      tokens: UInt64? = nil) -> TaskMetaWire {
        TaskMetaWire(id: id, kind: kind, description: description, subagentType: subagentType,
                     parentTaskId: parent, isBackgrounded: background, status: status, endReason: endReason,
                     startedAtMs: started, endedAtMs: ended, totalTokens: tokens)
    }

    /// A running background shell that started `secondsBefore` before the start of the test.
    private func running(_ id: String, _ description: String = "npm run dev", startedSecondsBefore seconds: UInt64 = 60) -> TaskMetaWire {
        task(id, .shell, description: description, started: startMs - seconds * 1000)
    }

    /// A completed (or failed) background shell that ended `endedSecondsBefore` before the start of the test.
    private func ended(_ id: String, _ status: TaskStatusWire = .completed, endedSecondsBefore seconds: UInt64 = 30) -> TaskMetaWire {
        task(id, .shell, status: status, description: "npm run build", started: startMs - (seconds + 60) * 1000,
             ended: startMs - seconds * 1000)
    }

    private func snapshot(_ tag: String, session: String? = "s1", epoch: String = "e1", stop: Bool? = nil,
                          _ tasks: [TaskMetaWire]) -> ServerMsg {
        .sessionTasks(SessionTasksWire(tag: tag, sessionId: session, daemonEpoch: epoch, stopSupported: stop, tasks: tasks))
    }

    /// The same, for the focus `kate`.
    private func snapshot(session: String? = "s1", epoch: String = "e1", stop: Bool? = nil,
                          _ tasks: [TaskMetaWire]) -> ServerMsg {
        snapshot("kate", session: session, epoch: epoch, stop: stop, tasks)
    }

    private func detail(_ tag: String, _ taskId: String, preview: String? = nil, progress: String? = nil) -> ServerMsg {
        .sessionTaskDetail(SessionTaskDetailWire(tag: tag, taskId: taskId, preview: preview, progressSummary: progress))
    }

    /// The same, for the focus `kate`.
    private func detail(_ taskId: String, preview: String? = nil, progress: String? = nil) -> ServerMsg {
        detail("kate", taskId, preview: preview, progress: progress)
    }

    private func ids(_ rows: [BackgroundTaskRow]) -> [String] { rows.map(\.id) }

    private func isRunningChip(_ chip: BackgroundChipState) -> Bool {
        if case .running = chip { return true }
        return false
    }

    // MARK: - Routing and replace semantics

    func testASnapshotIsAnnouncedForItsOwnTagAndListed() throws {
        let rig = try makeRig()
        let recorder = rig.record()
        rig.send(snapshot("kate", [running("b1")]))

        XCTAssertEqual(recorder.tags, ["kate"])
        let list = rig.store.list(for: "kate")
        XCTAssertEqual(ids(list.running), ["b1"])
        XCTAssertEqual(list.chip, .running(1))
        XCTAssertTrue(rig.store.hasSnapshot(tag: "kate"))
        XCTAssertEqual(rig.store.list(for: "bob"), .empty, "another focus has nothing")
        XCTAssertFalse(rig.store.hasSnapshot(tag: "bob"))
    }

    func testAFocusWithNoSnapshotIsEmptyAndHasNoState() throws {
        let rig = try makeRig()
        XCTAssertEqual(rig.store.list(for: "kate"), BackgroundTaskList.empty)
        XCTAssertNil(rig.store.state(for: "kate"))
        XCTAssertFalse(rig.store.hasSnapshot(tag: "kate"))
        XCTAssertNil(rig.store.seenMark(tag: "kate"))
    }

    func testTwoFocusesKeepTheirOwnTasks() throws {
        let rig = try makeRig()
        rig.send(snapshot("kate", [running("k1")]))
        rig.send(snapshot("bob", [running("b1"), running("b2")]))
        XCTAssertEqual(ids(rig.store.list(for: "kate").running), ["k1"])
        XCTAssertEqual(Set(ids(rig.store.list(for: "bob").running)), ["b1", "b2"])
    }

    func testEachSnapshotReplacesThePreviousOneSoNoTaskIsRunningOnceTheDaemonOmitsIt() throws {
        let rig = try makeRig()
        rig.send(snapshot([running("a"), running("b")]))
        XCTAssertEqual(rig.store.list(for: "kate").chip, .running(2))

        rig.send(snapshot([running("b")]))
        let list = rig.store.list(for: "kate")
        XCTAssertEqual(ids(list.running), ["b"])
        XCTAssertFalse(ids(list.allRows).contains("a"), "the daemon no longer reports it: it is not shown as anything")
        XCTAssertEqual(list.chip, .running(1))
    }

    func testATaskThatEndsInALaterSnapshotMovesToEnded() throws {
        let rig = try makeRig()
        rig.send(snapshot([running("a")]))
        rig.send(snapshot([task("a", .shell, status: .completed, description: "npm run dev",
                                started: startMs - 60_000, ended: startMs)]))
        let list = rig.store.list(for: "kate")
        XCTAssertTrue(list.running.isEmpty)
        XCTAssertEqual(ids(list.ended), ["a"])
        XCTAssertEqual(list.chip, .done(1))
    }

    func testAnIdenticalSnapshotIsNotAChange() throws {
        let rig = try makeRig()
        let recorder = rig.record()
        rig.send(snapshot([running("a")]))
        rig.send(snapshot([running("a")]))
        XCTAssertEqual(recorder.deliveries.count, 1)
    }

    func testFramesThatAreNotTaskFramesAreIgnored() throws {
        let rig = try makeRig()
        let recorder = rig.record()
        rig.send(ServerMsg.decode(from: Data(#"{"type":"a_frame_from_the_future","tag":"kate"}"#.utf8)))
        XCTAssertTrue(recorder.deliveries.isEmpty)
        XCTAssertNil(rig.store.state(for: "kate"))
    }

    func testTheListReadsElapsedTimeFromTheClockWithoutAnyNewFrame() throws {
        let rig = try makeRig()
        rig.send(snapshot([task("a", .shell, description: "sleep 600", started: startMs)]))
        let before = try XCTUnwrap(rig.store.list(for: "kate").running.first?.elapsedMs)
        rig.clock.advance(30)
        let after = try XCTUnwrap(rig.store.list(for: "kate").running.first?.elapsedMs)
        XCTAssertEqual(after, before + 30_000)
    }

    func testTheStopCapabilityOfTheLatestSnapshotReachesTheRows() throws {
        let rig = try makeRig()
        rig.send(snapshot(stop: false, [running("a")]))
        XCTAssertEqual(rig.store.list(for: "kate").running.first?.stopOffered, false)
        rig.send(snapshot(stop: true, [running("a")]))
        XCTAssertEqual(rig.store.list(for: "kate").running.first?.stopOffered, true)
    }

    // MARK: - Clear Context and new sessions

    func testANewSessionShowsTheOldRunningTasksStoppedFirstThenAnEmptyList() throws {
        let rig = try makeRig()
        let recorder = rig.record()
        rig.send(snapshot(session: "s1", [running("b1"), ended("old"), running("a1")]))
        XCTAssertEqual(recorder.deliveries.count, 1)

        rig.send(snapshot(session: "s2", []))   // Clear Context: same daemon, a new session id

        XCTAssertEqual(recorder.deliveries.count, 2, "the stopped state goes out at once")
        let stopped = recorder.deliveries[1].list
        XCTAssertTrue(stopped.running.isEmpty, "nothing still shows running")
        XCTAssertEqual(Set(ids(stopped.ended)), ["b1", "a1", "old"])
        for id in ["b1", "a1"] {
            XCTAssertEqual(stopped.ended.first { $0.id == id }?.statusLabel, "stopped", id)
        }
        XCTAssertEqual(stopped.ended.first { $0.id == "old" }?.statusLabel, "completed", "an ended task is left as it was")

        rig.clock.advance(0.25)
        rig.scheduler.flush()
        XCTAssertEqual(recorder.deliveries.count, 3, "then the empty list of the new session")
        XCTAssertTrue(recorder.deliveries[2].list.isEmpty)
        XCTAssertTrue(rig.store.list(for: "kate").isEmpty)
        XCTAssertEqual(rig.store.list(for: "kate").chip, .hidden)
    }

    func testANewSessionWithNothingRunningJustClearsTheList() throws {
        let rig = try makeRig()
        let recorder = rig.record()
        rig.send(snapshot(session: "s1", [ended("old")]))
        rig.send(snapshot(session: "s2", []))
        XCTAssertTrue(rig.store.list(for: "kate").isEmpty)
        XCTAssertEqual(recorder.deliveries.last?.list.isEmpty, true)
    }

    func testTheSameSessionIdIsNotANewSession() throws {
        let rig = try makeRig()
        rig.send(snapshot(session: "s1", [running("b1")]))
        rig.send(snapshot(session: "s1", [running("b1"), running("b2")]))
        XCTAssertEqual(rig.store.list(for: "kate").chip, .running(2))
        XCTAssertTrue(rig.store.list(for: "kate").ended.isEmpty)
    }

    func testANewSessionOfOneFocusDoesNotTouchAnother() throws {
        let rig = try makeRig()
        rig.send(snapshot("kate", session: "s1", [running("k1")]))
        rig.send(snapshot("bob", session: "t1", [running("b1")]))
        rig.send(snapshot("kate", session: "s2", []))
        XCTAssertEqual(ids(rig.store.list(for: "bob").running), ["b1"])
    }

    // MARK: - Daemon connection lost

    func testALostDaemonConnectionStopsEveryTaskThatWasNotOverAtOnceWithRestartAsTheReason() throws {
        let rig = try makeRig()
        let recorder = rig.record()
        rig.send(snapshot([running("b1"), task("a1", .agent, description: "Write tests", subagentType: "redd",
                                              started: startMs - 120_000), ended("done")]))
        rig.clock.advance(1)
        rig.store.daemonDisconnected()

        let list = rig.store.list(for: "kate")
        XCTAssertTrue(list.running.isEmpty, "no task is running while there is no daemon to say so")
        XCTAssertFalse(isRunningChip(list.chip))
        XCTAssertEqual(Set(ids(list.ended)), ["b1", "a1", "done"])
        for id in ["b1", "a1"] {
            let row = list.ended.first { $0.id == id }
            XCTAssertEqual(row?.statusLabel, "stopped", id)
            XCTAssertEqual(row?.endReason, .restart, id)
        }
        let finished = list.ended.first { $0.id == "done" }
        XCTAssertEqual(finished?.statusLabel, "completed", "an ended task is untouched")
        XCTAssertNil(finished?.endReason)
        XCTAssertEqual(recorder.tags, ["kate", "kate"], "and the focus hears about it")
        XCTAssertEqual(recorder.deliveries.last?.list, list)
    }

    func testALostConnectionWithNothingRunningChangesNothing() throws {
        let rig = try makeRig()
        let recorder = rig.record()
        rig.send(snapshot([ended("done")]))
        rig.clock.advance(1)
        let before = rig.store.list(for: "kate")
        rig.store.daemonDisconnected()
        XCTAssertEqual(rig.store.list(for: "kate"), before)
        XCTAssertEqual(recorder.deliveries.count, 1)
    }

    func testALostConnectionBeforeAnySnapshotDoesNothing() throws {
        let rig = try makeRig()
        let recorder = rig.record()
        rig.store.daemonDisconnected()
        XCTAssertTrue(recorder.deliveries.isEmpty)
    }

    func testLosingTheConnectionTwiceDoesNotDoubleTheStoppedEntries() throws {
        let rig = try makeRig()
        rig.send(snapshot([running("b1")]))
        rig.clock.advance(1)
        rig.store.daemonDisconnected()
        rig.clock.advance(1)
        rig.store.daemonDisconnected()
        XCTAssertEqual(ids(rig.store.list(for: "kate").ended), ["b1"])
    }

    func testAReconnectToANewDaemonKeepsTheRestartStoppedEntriesInEndedAlongsideTheNewDaemonsTasks() throws {
        let rig = try makeRig()
        rig.send(snapshot(epoch: "e1", [running("b1"), running("a1"), ended("done")]))
        rig.clock.advance(1)
        rig.store.daemonDisconnected()

        rig.send(snapshot(epoch: "e2", [running("n1", "new daemon's job")]))

        let list = rig.store.list(for: "kate")
        XCTAssertEqual(ids(list.running), ["n1"])
        XCTAssertEqual(list.chip, .running(1))
        for id in ["b1", "a1"] {
            let row = list.ended.first { $0.id == id }
            XCTAssertNotNil(row, "\(id) is kept in Ended")
            XCTAssertEqual(row?.statusLabel, "stopped", id)
            XCTAssertEqual(row?.endReason, .restart, id)
        }
        XCTAssertEqual(list.allRows.count, Set(ids(list.allRows)).count, "no task twice")
    }

    func testAReconnectToTheSameDaemonTakesItsSnapshotAsTheTruth() throws {
        let rig = try makeRig()
        rig.send(snapshot(epoch: "e1", [running("b1"), running("a1")]))
        rig.clock.advance(1)
        rig.store.daemonDisconnected()
        XCTAssertTrue(rig.store.list(for: "kate").running.isEmpty)

        rig.send(snapshot(epoch: "e1", [running("b1")]))   // the connection blipped; the daemon still runs b1

        let list = rig.store.list(for: "kate")
        XCTAssertEqual(ids(list.running), ["b1"], "running again, not stopped")
        XCTAssertEqual(list.running.first?.statusLabel, "running")
        XCTAssertEqual(ids(list.allRows), ["b1"], "not duplicated, and the task it no longer reports is not shown as stopped")
        XCTAssertFalse(list.allRows.contains { $0.endReason == .restart })
    }

    func testAClearContextAfterANewDaemonDropsTheRestartStoppedEntries() throws {
        let rig = try makeRig()
        rig.send(snapshot(epoch: "e1", session: "s1", [running("b1")]))
        rig.clock.advance(1)
        rig.store.daemonDisconnected()
        rig.send(snapshot(epoch: "e2", session: "s1", [running("n1")]))
        XCTAssertTrue(ids(rig.store.list(for: "kate").ended).contains("b1"))

        rig.send(snapshot(epoch: "e2", session: "s2", []))   // Clear Context

        let list = rig.store.list(for: "kate")
        XCTAssertFalse(ids(list.allRows).contains("b1"), "the restart-stopped entry is gone")
        XCTAssertTrue(list.isEmpty)
    }

    func testARestartStoppedEntryTheNewDaemonAlsoReportsIsShownOnceAsTheDaemonSaysIt() throws {
        let rig = try makeRig()
        rig.send(snapshot(epoch: "e1", [running("b1")]))
        rig.clock.advance(1)
        rig.store.daemonDisconnected()
        rig.send(snapshot(epoch: "e2", [running("b1")]))
        let list = rig.store.list(for: "kate")
        XCTAssertEqual(ids(list.allRows), ["b1"])
        XCTAssertEqual(list.running.first?.statusLabel, "running")
    }

    // MARK: - Every window reads the same thing

    func testTwoSubscribersReadTheSameListAndChipAtEveryDelivery() throws {
        let rig = try makeRig()
        let first = rig.record()
        let second = rig.record()

        rig.send(snapshot(epoch: "e1", session: "s1", [running("b1"), task("a1", .agent, subagentType: "redd",
                                                                              started: startMs - 30_000, tokens: 950)]))
        rig.send(detail("b1", preview: "ready on :3000"))
        rig.send(snapshot(epoch: "e1", session: "s1", [ended("b1", .failed), running("a1")]))
        rig.clock.advance(1)
        rig.store.daemonDisconnected()
        rig.send(snapshot(epoch: "e2", session: "s1", []))
        rig.send(snapshot(epoch: "e2", session: "s2", []))

        XCTAssertGreaterThanOrEqual(first.deliveries.count, 5)
        XCTAssertEqual(first.deliveries.count, second.deliveries.count)
        for (a, b) in zip(first.deliveries, second.deliveries) {
            XCTAssertEqual(a.tag, b.tag)
            XCTAssertEqual(a.list, b.list)
            XCTAssertEqual(a.list.chip, b.list.chip)
        }
        XCTAssertEqual(first.deliveries.last?.list, rig.store.list(for: "kate"))
    }

    // MARK: - Coalescing: at most 4 Hz per tag, the final state always delivered

    func testTheFirstChangeIsDeliveredAtOnceAndLaterOnesWithinTheWindowFoldIntoOneDeliveryOfTheLatest() throws {
        let rig = try makeRig()
        let recorder = rig.record()

        rig.store.ingest(snapshot([running("a")]))
        XCTAssertEqual(recorder.deliveries.count, 1, "the first change goes out at once")
        XCTAssertTrue(rig.scheduler.scheduled.isEmpty)

        rig.clock.advance(0.02)
        rig.store.ingest(snapshot([running("a"), running("b")]))
        rig.clock.advance(0.03)
        rig.store.ingest(snapshot([running("a"), running("b"), running("c")]))
        XCTAssertEqual(recorder.deliveries.count, 1, "changes inside the window wait")
        XCTAssertEqual(rig.scheduler.scheduled.count, 1, "and share one scheduled delivery")
        XCTAssertTrue(rig.scheduler.delays.allSatisfy { $0 > 0 && $0 <= BackgroundTaskStore.minimumInterval },
                      "due within the window: \(rig.scheduler.delays)")
        XCTAssertEqual(BackgroundTaskStore.minimumInterval, 0.25, "four a second")

        rig.clock.advance(0.2)   // 0.25 s after the first delivery
        rig.scheduler.flush()
        XCTAssertEqual(recorder.deliveries.count, 2, "exactly one later delivery")
        XCTAssertEqual(recorder.deliveries.last?.list.running.count, 3, "and it reads the latest state, not the first change")
        XCTAssertEqual(recorder.deliveries.last?.list, rig.store.list(for: "kate"))
        XCTAssertTrue(rig.scheduler.scheduled.isEmpty)
    }

    func testNeverMoreThanFourDeliveriesASecondForATagAndTheFinalStateIsDelivered() throws {
        let rig = try makeRig()
        let recorder = rig.record()

        // A burst: a change every 10 ms for a second, firing what is due as time passes.
        for i in 1...100 {
            rig.store.ingest(snapshot([running("a", "job \(i)")]))
            rig.clock.advance(0.01)
            if let last = recorder.deliveries.last, rig.clock.date.timeIntervalSince(last.at) >= 0.25 {
                rig.scheduler.flush()
            }
        }
        rig.clock.advance(0.25)
        rig.scheduler.flush()

        XCTAssertGreaterThanOrEqual(recorder.deliveries.count, 2)
        XCTAssertLessThanOrEqual(recorder.deliveries.count, 6, "100 changes in one second, at most about four deliveries")
        for (earlier, later) in zip(recorder.deliveries, recorder.deliveries.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later.at.timeIntervalSince(earlier.at), 0.25 - 0.001)
        }
        XCTAssertEqual(recorder.deliveries.last?.list.running.first?.description, "job 100",
                       "the last change is never swallowed")
        XCTAssertEqual(recorder.deliveries.last?.list, rig.store.list(for: "kate"))
    }

    func testCoalescingIsPerTag() throws {
        let rig = try makeRig()
        let recorder = rig.record()
        rig.store.ingest(snapshot("kate", [running("k1")]))
        rig.store.ingest(snapshot("bob", [running("b1")]))
        XCTAssertEqual(recorder.tags, ["kate", "bob"], "bob's first change is not held back by kate's window")
    }

    func testAForgottenFocusDoesNotAnnounceItselfFromABeforehandScheduledDelivery() throws {
        let rig = try makeRig()
        let recorder = rig.record()
        rig.store.ingest(snapshot([running("a")]))
        rig.clock.advance(0.05)
        rig.store.ingest(snapshot([running("a"), running("b")]))
        XCTAssertEqual(rig.scheduler.scheduled.count, 1)

        rig.store.forget(tag: "kate")
        rig.clock.advance(0.25)
        rig.scheduler.flush()

        XCTAssertEqual(recorder.deliveries.count, 1)
        XCTAssertEqual(rig.store.list(for: "kate"), .empty)
    }

    // MARK: - Details

    func testADetailUpdatesTheSignOfLifeAndAnIdenticalOneIsNotAChange() throws {
        let rig = try makeRig()
        let recorder = rig.record()
        rig.send(snapshot([task("a1", .agent, description: "Write tests", subagentType: "redd",
                                started: startMs - 30_000, tokens: 950),
                           running("b1")]))
        XCTAssertEqual(rig.store.list(for: "kate").running.first { $0.id == "a1" }?.signOfLife, "950 tokens")
        XCTAssertNil(rig.store.list(for: "kate").running.first { $0.id == "b1" }?.signOfLife)
        XCTAssertEqual(recorder.deliveries.count, 1)

        rig.send(detail("a1", progress: "Reading the wire types"))
        XCTAssertEqual(recorder.deliveries.count, 2)
        XCTAssertEqual(rig.store.list(for: "kate").running.first { $0.id == "a1" }?.signOfLife, "Reading the wire types")

        rig.send(detail("a1", progress: "Reading the wire types"))
        XCTAssertEqual(recorder.deliveries.count, 2, "the same detail twice is one change")

        rig.send(detail("b1", preview: "ready on :3000"))
        XCTAssertEqual(recorder.deliveries.count, 3)
        XCTAssertEqual(rig.store.list(for: "kate").running.first { $0.id == "b1" }?.signOfLife, "last: ready on :3000")

        rig.send(detail("b1", preview: "compiled in 412 ms"))
        XCTAssertEqual(recorder.deliveries.count, 4)
        XCTAssertEqual(rig.store.list(for: "kate").running.first { $0.id == "b1" }?.signOfLife, "last: compiled in 412 ms")
    }

    func testADetailThatArrivesBeforeItsSnapshotIsStillShown() throws {
        let rig = try makeRig()
        rig.send(detail("b1", preview: "ready on :3000"))
        rig.send(snapshot([running("b1")]))
        XCTAssertEqual(rig.store.list(for: "kate").running.first?.signOfLife, "last: ready on :3000")
    }

    func testADetailOfOneFocusIsNotShownInAnother() throws {
        let rig = try makeRig()
        rig.send(snapshot("kate", [running("b1")]))
        rig.send(snapshot("bob", [running("b1")]))
        rig.send(detail("kate", "b1", preview: "kate's output"))
        XCTAssertEqual(rig.store.list(for: "kate").running.first?.signOfLife, "last: kate's output")
        XCTAssertNil(rig.store.list(for: "bob").running.first?.signOfLife)
    }

    // MARK: - Seen: what hides a done / failed chip

    func testOpeningThePopoverHidesADoneChipAndPersistsTheMark() throws {
        let rig = try makeRig()
        let recorder = rig.record()
        let finished = ended("a", .completed, endedSecondsBefore: 30)
        rig.send(snapshot([finished]))
        XCTAssertEqual(rig.store.list(for: "kate").chip, .done(1))
        XCTAssertNil(rig.store.seenMark(tag: "kate"))

        let before = recorder.deliveries.count
        rig.clock.advance(1)
        rig.store.markSeen(tag: "kate")

        XCTAssertEqual(rig.store.list(for: "kate").chip, .hidden)
        XCTAssertEqual(rig.store.seenMark(tag: "kate"), finished.endedAtMs)
        XCTAssertEqual(rig.persistedSeenTags, ["kate"], "written to the defaults under nostromo.background.seen")
        XCTAssertGreaterThan(recorder.deliveries.count, before, "the chip is told to go")
        XCTAssertEqual(recorder.deliveries.last?.tag, "kate")
        XCTAssertEqual(recorder.deliveries.last?.list.chip, .hidden)
        XCTAssertEqual(rig.store.list(for: "kate").ended.count, 1, "the Ended list itself stays")
    }

    func testOpeningThePopoverOnceHidesAFailedChip() throws {
        let rig = try makeRig()
        rig.send(snapshot([ended("bad", .failed)]))
        XCTAssertEqual(rig.store.list(for: "kate").chip, .failed(1))
        rig.store.markSeen(tag: "kate")
        XCTAssertEqual(rig.store.list(for: "kate").chip, .hidden)
    }

    func testTheSeenMarkSurvivesARelaunch() throws {
        let rig = try makeRig()
        let finished = ended("bad", .failed)
        rig.send(snapshot([finished]))
        rig.store.markSeen(tag: "kate")

        let relaunched = rig.makeStore()
        XCTAssertEqual(relaunched.seenMark(tag: "kate"), finished.endedAtMs, "read back from the same defaults")
        rig.send(snapshot([finished]), to: relaunched)
        XCTAssertEqual(relaunched.list(for: "kate").chip, .hidden, "what the user already saw does not come back")

        let stranger = try makeRig()   // another defaults suite: nothing seen
        let fresh = stranger.makeStore()
        stranger.send(snapshot([finished]), to: fresh)
        XCTAssertEqual(fresh.list(for: "kate").chip, .failed(1))
    }

    func testSomethingThatEndsAfterThePopoverWasOpenedIsNewsAgain() throws {
        let rig = try makeRig()
        rig.send(snapshot([ended("first", .completed, endedSecondsBefore: 100), running("second")]))
        rig.store.markSeen(tag: "kate")

        rig.send(snapshot([ended("first", .completed, endedSecondsBefore: 100),
                           task("second", .shell, status: .failed, description: "npm test",
                                started: startMs - 60_000, ended: startMs - 5_000)]))
        XCTAssertEqual(rig.store.list(for: "kate").chip, .failed(1), "the earlier one stays seen; the new failure is not")
    }

    func testOpeningThePopoverWhileTasksRunAndNothingHasEndedStillLeavesTheLaterEndingUnseen() throws {
        let rig = try makeRig()
        rig.send(snapshot([running("a")]))
        rig.store.markSeen(tag: "kate")
        XCTAssertEqual(rig.store.list(for: "kate").chip, .running(1), "running shows regardless")

        rig.send(snapshot([task("a", .shell, status: .completed, description: "npm run dev",
                                started: startMs - 60_000, ended: startMs)]))
        XCTAssertEqual(rig.store.list(for: "kate").chip, .done(1))
    }

    func testOpeningThePopoverForAFocusWithNoSnapshotChangesNothing() throws {
        let rig = try makeRig()
        let recorder = rig.record()
        rig.store.markSeen(tag: "kate")
        XCTAssertTrue(recorder.deliveries.isEmpty)
        XCTAssertNil(rig.store.seenMark(tag: "kate"))
        XCTAssertTrue(rig.persistedSeenTags.isEmpty)
    }

    func testOpeningThePopoverTwiceIsHarmless() throws {
        let rig = try makeRig()
        let recorder = rig.record()
        rig.send(snapshot([ended("a")]))
        rig.clock.advance(1)
        rig.store.markSeen(tag: "kate")
        let count = recorder.deliveries.count
        rig.clock.advance(1)
        rig.store.markSeen(tag: "kate")
        XCTAssertEqual(rig.store.list(for: "kate").chip, .hidden)
        XCTAssertEqual(recorder.deliveries.count, count, "nothing visible changed, so nothing is announced")
    }

    func testSeenIsPerFocus() throws {
        let rig = try makeRig()
        rig.send(snapshot("kate", [ended("a")]))
        rig.send(snapshot("bob", [ended("b")]))
        rig.store.markSeen(tag: "kate")
        XCTAssertEqual(rig.store.list(for: "kate").chip, .hidden)
        XCTAssertEqual(rig.store.list(for: "bob").chip, .done(1))
    }

    func testRemovingAFocusDropsItsTasksAndItsSeenEntryButNotAnothersFocus() throws {
        let rig = try makeRig()
        rig.send(snapshot("kate", [ended("a")]))
        rig.send(snapshot("bob", [ended("b")]))
        rig.store.markSeen(tag: "kate")
        rig.store.markSeen(tag: "bob")
        XCTAssertEqual(rig.persistedSeenTags, ["kate", "bob"])

        rig.store.forget(tag: "kate")

        XCTAssertEqual(rig.store.list(for: "kate"), .empty)
        XCTAssertNil(rig.store.state(for: "kate"))
        XCTAssertFalse(rig.store.hasSnapshot(tag: "kate"))
        XCTAssertNil(rig.store.seenMark(tag: "kate"))
        XCTAssertEqual(rig.persistedSeenTags, ["bob"], "the entry goes from the defaults too")
        XCTAssertEqual(rig.store.list(for: "bob").chip, .hidden, "bob keeps what he had")
        XCTAssertNotNil(rig.store.seenMark(tag: "bob"))

        rig.send(snapshot("kate", [ended("a")]))
        XCTAssertEqual(rig.store.list(for: "kate").chip, .done(1), "a new focus under that tag starts unseen")
    }

    func testTheSeenMapKeepsAtMostTwoHundredTagsDroppingTheLeastRecentlyUsedFirst() throws {
        let rig = try makeRig()
        XCTAssertEqual(BackgroundTaskStore.seenCapacity, 200)
        func open(_ tag: String) {
            rig.send(snapshot(tag, [ended("a")]))
            rig.store.markSeen(tag: tag)   // the clock moved a second since the last open
        }
        for i in 0..<200 { open("tag-\(i)") }
        XCTAssertEqual(rig.persistedSeenTags.count, 200)

        rig.clock.advance(1)
        rig.store.markSeen(tag: "tag-0")   // used again: tag-1 is now the least recently used
        open("tag-200")

        XCTAssertEqual(rig.persistedSeenTags.count, 200, "still 200")
        XCTAssertTrue(rig.persistedSeenTags.contains("tag-0"), "recently used, kept")
        XCTAssertFalse(rig.persistedSeenTags.contains("tag-1"), "the least recently used went")
        XCTAssertTrue(rig.persistedSeenTags.contains("tag-200"))
        XCTAssertNil(rig.store.seenMark(tag: "tag-1"))
        XCTAssertNotNil(rig.store.seenMark(tag: "tag-0"))

        open("tag-201")
        XCTAssertEqual(rig.persistedSeenTags.count, 200)
        XCTAssertFalse(rig.persistedSeenTags.contains("tag-2"))
        XCTAssertTrue(rig.persistedSeenTags.contains("tag-0"))

        let relaunched = rig.makeStore()
        XCTAssertNil(relaunched.seenMark(tag: "tag-1"), "and a relaunch reads the trimmed map")
        XCTAssertNotNil(relaunched.seenMark(tag: "tag-201"))
    }
}
