import XCTest
// MotherJobReconciler, MotherRecentlyArchived, MotherResyncScheduler, MotherJobRefresher,
// MotherBrokerClient and MotherJob are compiled into this test target directly (logic test).

// MARK: - Builders

private func shJob(id: String, state: String = "running", title: String = "A job",
                   progressPct: Int? = nil, progressAt: String = "2026-10-17T12:00:00.000Z") -> MotherJob {
    var crew = MotherCrewState()
    if let pct = progressPct {
        crew.progress = MotherProgress(
            v: 1, pct: pct, label: "Implementing", stage: "implement",
            signals: MotherProgressSignals(stage: "implement", elapsedActiveS: 420, cost: 1.12),
            eta: MotherProgressEta(loS: 300, hiS: 900, label: "5-15 min", basis: "fleet"),
            paused: false, flags: [], updatedAt: progressAt)
    }
    return MotherJob(id: id, state: state, repo: "Carefeed/payments", isolation: "worktree", title: title,
                     createdAt: nil, startedAt: nil, finishedAt: nil, planPath: nil, question: nil,
                     pausedReason: nil, adherenceStatus: nil, currentTier: nil, crew: crew)
}

private func shMap(_ jobs: [MotherJob]) -> [String: MotherJob] {
    Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })
}

// MARK: - SH-2 reconciler

final class MotherJobReconcilerTests: XCTestCase {

    private func reconcile(current: [MotherJob], listed: [MotherJob], missingOnce: Set<String> = [],
                           archived: Set<String> = []) -> MotherJobReconciler.Result {
        MotherJobReconciler.reconcile(current: shMap(current), listed: listed,
                                      missingOnce: missingOnce, recentlyArchived: archived)
    }

    func testAListedJobTheAppNeverHeardOfIsAdded() {
        let r = reconcile(current: [shJob(id: "a")], listed: [shJob(id: "a"), shJob(id: "b")])
        XCTAssertEqual(Set(r.jobs.keys), ["a", "b"])
        XCTAssertEqual(r.added, ["b"])
        XCTAssertTrue(r.removed.isEmpty)
    }

    func testAnExistingJobTakesTheListedStateButKeepsANewerProgressOverlay() {
        let mine = shJob(id: "a", state: "running", progressPct: 80, progressAt: "2026-10-17T12:10:00.000Z")
        let listed = shJob(id: "a", state: "awaiting", progressPct: 40, progressAt: "2026-10-17T12:00:00.000Z")
        let r = reconcile(current: [mine], listed: [listed])
        XCTAssertEqual(r.jobs["a"]?.state, "awaiting")
        XCTAssertEqual(r.jobs["a"]?.crew.progress?.pct, 80)
        XCTAssertTrue(r.added.isEmpty)
    }

    func testAnExistingJobTakesANewerListedProgressOverlay() {
        let mine = shJob(id: "a", progressPct: 40, progressAt: "2026-10-17T12:00:00.000Z")
        let listed = shJob(id: "a", progressPct: 90, progressAt: "2026-10-17T12:10:00.000Z")
        let r = reconcile(current: [mine], listed: [listed])
        XCTAssertEqual(r.jobs["a"]?.crew.progress?.pct, 90)
    }

    func testAJobAbsentFromOneListIsKeptAndRemembered() {
        let r = reconcile(current: [shJob(id: "a"), shJob(id: "b")], listed: [shJob(id: "a")])
        XCTAssertNotNil(r.jobs["b"])
        XCTAssertEqual(r.missingOnce, ["b"])
        XCTAssertTrue(r.removed.isEmpty)
    }

    func testAJobAbsentFromTwoConsecutiveListsIsRemoved() {
        let current = [shJob(id: "a"), shJob(id: "b")]
        let first = reconcile(current: current, listed: [shJob(id: "a")])
        let second = MotherJobReconciler.reconcile(current: first.jobs, listed: [shJob(id: "a")],
                                                   missingOnce: first.missingOnce, recentlyArchived: [])
        XCTAssertNil(second.jobs["b"])
        XCTAssertEqual(second.removed, ["b"])
        XCTAssertNotNil(second.jobs["a"])
        XCTAssertFalse(second.missingOnce.contains("b"))
    }

    func testAJobThatReappearsResetsItsMissingMark() {
        let current = [shJob(id: "a"), shJob(id: "b")]
        let first = reconcile(current: current, listed: [shJob(id: "a")])
        XCTAssertEqual(first.missingOnce, ["b"])
        let second = MotherJobReconciler.reconcile(current: first.jobs, listed: [shJob(id: "a"), shJob(id: "b")],
                                                   missingOnce: first.missingOnce, recentlyArchived: [])
        XCTAssertTrue(second.missingOnce.isEmpty)
        XCTAssertTrue(second.removed.isEmpty)
        // A later single absence must not remove it.
        let third = MotherJobReconciler.reconcile(current: second.jobs, listed: [shJob(id: "a")],
                                                  missingOnce: second.missingOnce, recentlyArchived: [])
        XCTAssertNotNil(third.jobs["b"])
        XCTAssertTrue(third.removed.isEmpty)
    }

    func testARecentlyArchivedJobIsNeverReAdded() {
        let r = reconcile(current: [shJob(id: "a")], listed: [shJob(id: "a"), shJob(id: "gone")], archived: ["gone"])
        XCTAssertNil(r.jobs["gone"])
        XCTAssertFalse(r.added.contains("gone"))
    }

    func testAnIdenticalListChangesNothing() {
        let current = [shJob(id: "a"), shJob(id: "b", progressPct: 30)]
        let r = reconcile(current: current, listed: current)
        XCTAssertEqual(r.jobs, shMap(current))
        XCTAssertTrue(r.added.isEmpty)
        XCTAssertTrue(r.removed.isEmpty)
        XCTAssertTrue(r.missingOnce.isEmpty)
    }
}

// MARK: - SH-1 discovery refresher and recently-archived expiry

final class MotherSelfHealRefresherTests: XCTestCase {

    private final class Probe {
        var fetched: [String] = []
        var applied: [String] = []
    }

    private func settle(_ seconds: TimeInterval) {
        let exp = expectation(description: "settle \(seconds)")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exp.fulfill() }
        wait(for: [exp], timeout: seconds + 10)
    }

    func testABurstOfEventsForAnUnknownJobIsOneDiscoveryFetch() {
        let probe = Probe()
        let refresher = MotherJobRefresher(
            debounce: 0.1,
            fetch: { id, done in probe.fetched.append(id); done(.success(shJob(id: id))) },
            apply: { probe.applied.append($0.id) })
        for _ in 0..<6 { refresher.request(job: "new-job") }
        settle(0.5)
        XCTAssertEqual(probe.fetched, ["new-job"])
        XCTAssertEqual(probe.applied, ["new-job"])
    }

    func testAFailedDiscoveryFetchAppliesNothing() {
        let probe = Probe()
        let refresher = MotherJobRefresher(
            debounce: 0.05,
            fetch: { id, done in probe.fetched.append(id); done(.failure(.timeout)) },
            apply: { probe.applied.append($0.id) })
        refresher.request(job: "new-job")
        settle(0.4)
        XCTAssertEqual(probe.fetched, ["new-job"])
        XCTAssertTrue(probe.applied.isEmpty)
    }

    func testRecentlyArchivedIdsExpireAfterTheTTL() {
        var archived = MotherRecentlyArchived(ttl: 120)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        archived.insert("a", now: t0)
        XCTAssertEqual(archived.ids(now: t0.addingTimeInterval(119)), ["a"])
        XCTAssertTrue(archived.ids(now: t0.addingTimeInterval(121)).isEmpty)
        // Once expired it stays gone.
        XCTAssertTrue(archived.ids(now: t0.addingTimeInterval(122)).isEmpty)
    }

    func testOnlyTheExpiredRecentlyArchivedIdsDrop() {
        var archived = MotherRecentlyArchived(ttl: 60)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        archived.insert("old", now: t0)
        archived.insert("fresh", now: t0.addingTimeInterval(50))
        XCTAssertEqual(archived.ids(now: t0.addingTimeInterval(70)), ["fresh"])
    }
}

// MARK: - SH-3 tolerant list decoding

final class MotherBrokerListDecodeTests: XCTestCase {

    private func raw(id: String) -> [String: Any] {
        ["id": id, "state": "running", "repo": "carefeed", "isolation": "none", "title": "Job \(id)",
         "created_at": "2026-06-01T12:00:00.000Z", "started_at": NSNull(), "finished_at": NSNull()]
    }

    func testOneUnreadableJobDoesNotCostTheGoodOnes() {
        let client = MotherBrokerClient(socketPath: "/nonexistent")
        let bad: [String: Any] = ["id": "bad", "title": "no state, repo or isolation"]
        let jobs = client.decodeJobList([raw(id: "a"), bad, raw(id: "b")])
        XCTAssertEqual(jobs.map(\.id), ["a", "b"])
    }

    func testAnEmptyListDecodesToNoJobs() {
        XCTAssertTrue(MotherBrokerClient(socketPath: "/nonexistent").decodeJobList([]).isEmpty)
    }

    func testAListOfOnlyUnreadableJobsDecodesToNoJobs() {
        let client = MotherBrokerClient(socketPath: "/nonexistent")
        XCTAssertTrue(client.decodeJobList([["id": 5], [:]]).isEmpty)
    }
}

// MARK: - SH-4 resync scheduler

final class MotherResyncSchedulerTests: XCTestCase {

    private final class Fake {
        struct Call: Equatable { let after: TimeInterval; let repeating: TimeInterval? }
        var calls: [Call] = []
        var fires: [() -> Void] = []
        var cancelled: [Int] = []
        var ticks = 0

        func schedule(_ after: TimeInterval, _ repeating: TimeInterval?, _ fire: @escaping () -> Void) -> () -> Void {
            let index = calls.count
            calls.append(Call(after: after, repeating: repeating))
            fires.append(fire)
            return { [weak self] in self?.cancelled.append(index) }
        }
    }

    private func make(_ fake: Fake) -> MotherResyncScheduler {
        MotherResyncScheduler(schedule: { fake.schedule($0, $1, $2) }, tick: { fake.ticks += 1 })
    }

    func testNothingIsScheduledWhileDisconnected() {
        let fake = Fake()
        let s = make(fake)
        s.setActive(true)
        s.setActive(false)
        s.setActive(true)
        XCTAssertTrue(fake.calls.isEmpty)
        XCTAssertFalse(s.isRunning)
    }

    func testConnectedAndActiveSchedulesASixtySecondRepeatingTick() {
        let fake = Fake()
        let s = make(fake)
        s.setConnected(true)
        XCTAssertEqual(fake.calls, [Fake.Call(after: 60, repeating: 60)])
        XCTAssertTrue(s.isRunning)
    }

    func testDisconnectingCancelsTheSchedule() {
        let fake = Fake()
        let s = make(fake)
        s.setConnected(true)
        s.setConnected(false)
        XCTAssertEqual(fake.cancelled, [0])
        XCTAssertFalse(s.isRunning)
    }

    func testGoingInactiveCancelsAndBecomingActiveSchedulesAgain() {
        let fake = Fake()
        let s = make(fake)
        s.setConnected(true)
        s.setActive(false)
        XCTAssertEqual(fake.cancelled, [0])
        XCTAssertFalse(s.isRunning)
        s.setActive(true)
        XCTAssertEqual(fake.calls.count, 2)
        XCTAssertTrue(s.isRunning)
    }

    func testSnapshotWhileConnectedSchedulesATwoSecondOneShot() {
        let fake = Fake()
        let s = make(fake)
        s.setConnected(true)
        s.snapshotReceived()
        XCTAssertEqual(fake.calls.last, Fake.Call(after: 2, repeating: nil))
    }

    func testSnapshotWhileDisconnectedSchedulesNothing() {
        let fake = Fake()
        let s = make(fake)
        s.snapshotReceived()
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testFiringTheScheduledWorkTicks() {
        let fake = Fake()
        let s = make(fake)
        s.setConnected(true)
        s.snapshotReceived()
        fake.fires[0]()
        XCTAssertEqual(fake.ticks, 1)
        fake.fires[1]()
        XCTAssertEqual(fake.ticks, 2)
    }

    func testConnectingTwiceDoesNotScheduleTwice() {
        let fake = Fake()
        let s = make(fake)
        s.setConnected(true)
        s.setConnected(true)
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertTrue(fake.cancelled.isEmpty)
    }
}
