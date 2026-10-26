import XCTest

// MemoryWatchdog is compiled into this target directly (logic test, no host app), together with
// `MemorySummary`. Every test here drives the watchdog through its seams only (`footprint`,
// `relievePressure`, `onShed` / `onShedScoped`, `shedCompletionTimeout`, `now`, `summarize`) and
// calls `poll()` / `shed(reason:critical:)` directly. `start()` is never called: it installs a real
// memory-pressure `DispatchSource` and a 30 s repeating timer, neither of which belongs in a logic
// test. Time is driven by `now`, never by sleeping.

/// Behavioural tests for the watchdog's "shedding that frees nothing is not a strategy" contract.
///
/// The incident: the app's footprint sat permanently above the 1.6 GB shed line because of a leak
/// that has nothing to do with transcript views. So `poll()` called `shed` every 30 s, forever.
/// Each shed released every materialized transcript view (the visible pane blanked and redrew) and
/// freed nothing. The watchdog's remedy must (a) notice that a shed did not help, (b) stop doing it
/// at the same cadence, and (c) say, once, where the memory actually is.
///
/// What these tests pin down, all from the outside:
///
///  1. A shed is "helpful" iff it freed at least 100 MB AND at least 10% of what the app held
///     before it. Both thresholds, both edges.
///  2. After the k-th consecutive unhelpful shed the next non-critical shed is refused until
///     120 s, then 600 s, then 3600 s (forever) have passed on `now()` since the previous shed
///     started. A helpful shed resets that. Dropping below the shed line ends the episode.
///  3. Critical OS pressure ignores the back-off (but not the in-flight guard or the 30 s gap)
///     and asks for everything; a poll-triggered shed asks only for off-screen content.
///  4. The toast keeps its title; an unhelpful shed adds the "held outside the transcript" sentence
///     and the largest memory category, and only the first unhelpful shed of an episode toasts.
///
///  5. A shed that finishes only because its completion timed out is inconclusive: it does not count
///     as unhelpful, but it has its own, smaller back-off (`timeoutBackoffSchedule`: 60 s, 300 s,
///     900 s), the gap used is the longer of the two streaks', and the operator hears about it once
///     per episode (or until a shed completes normally), not every 30 s.
///
/// Nothing here inspects `isShedding`, `lastShed`, `hasWarned` or any failure counter: back-off is
/// observed as "did `onShed` / `onShedScoped` get called", and reporting as "what reached `onWarn`".
final class MemoryWatchdogBackoffTests: XCTestCase {

    // MARK: - Fixtures

    private static let mb = 1_048_576
    private static let shedLine = MemoryWatchdog.shedBytes            // 1.6 GB
    private static let toastTitle = "Shed retained content"
    private static let heldOutsidePhrase = "memory is held outside the transcript"

    /// The summary every `summarize` call returns: the shape of the real incident (a Malloc Small
    /// region holding most of the footprint), with the categories already largest-first as the
    /// `MemorySummary` contract promises.
    private static let incidentSummary = MemorySummary(
        physicalFootprintBytes: 1_797 * mb,
        mallocBlocksInUse: 16_046_602,
        mallocBytesInUse: 1_585 * mb,
        categories: [
            MemorySummary.Category(name: "Malloc Small", dirtyBytes: 1_678 * mb),
            MemorySummary.Category(name: "Malloc Large", dirtyBytes: 39 * mb),
        ])

    /// A watchdog on a fake clock, a fake footprint and a fake pane fan-out.
    ///
    /// `level` is what the process "holds". A shed that is handed `freedByNextShed` subtracts it
    /// from `level` before calling its completion, which is how a real shed's effect shows up in
    /// the "after" read. The completion is called synchronously inside `onShedScoped` unless
    /// `holdCompletions` is set, so a whole shed runs inside one `poll()` call.
    private final class Rig {
        let watchdog = MemoryWatchdog()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        /// Seconds since `base`.
        var clockSeconds: TimeInterval = 0
        var level: Int
        var freedByNextShed = 0
        var holdCompletions = false

        private(set) var scopes: [MemoryWatchdog.ShedScope] = []
        private(set) var toasts: [(title: String, detail: String)] = []
        private(set) var heldCompletions: [() -> Void] = []

        var shedToasts: [(title: String, detail: String)] {
            toasts.filter { $0.title == MemoryWatchdogBackoffTests.toastTitle }
        }

        init(level: Int = 2_000 * MemoryWatchdogBackoffTests.mb, useScopedCallback: Bool = true) {
            self.level = level
            watchdog.now = { [unowned self] in self.base.addingTimeInterval(self.clockSeconds) }
            watchdog.footprint = { [unowned self] in self.level }
            // Called exactly once per finished shed, whether it completed or timed out: the tests
            // use it to know, without sleeping, that a shed has run to its end.
            watchdog.relievePressure = { [unowned self] in self.finishedSheds += 1 }
            watchdog.summarize = { MemoryWatchdogBackoffTests.incidentSummary }
            watchdog.onWarn = { [unowned self] title, detail in self.toasts.append((title, detail)) }
            // Long enough that a stray timeout never finishes anything inside a test.
            watchdog.shedCompletionTimeout = 60
            if useScopedCallback {
                watchdog.onShedScoped = { [unowned self] scope, completion in
                    self.scopes.append(scope)
                    self.fanOut(completion)
                }
            } else {
                watchdog.onShed = { [unowned self] completion in
                    self.legacyShedCount += 1
                    self.fanOut(completion)
                }
            }
        }

        private(set) var legacyShedCount = 0
        private(set) var finishedSheds = 0

        /// How many times the app was asked to shed, by either callback.
        var shedCount: Int { scopes.count + legacyShedCount }

        private func fanOut(_ completion: @escaping () -> Void) {
            if holdCompletions {
                heldCompletions.append(completion)
                return
            }
            level = max(0, level - freedByNextShed)
            completion()
        }

        /// Releases the oldest held completion, applying the shed's effect first.
        func completeHeldShed() {
            guard !heldCompletions.isEmpty else { return }
            level = max(0, level - freedByNextShed)
            heldCompletions.removeFirst()()
        }

        /// Moves the clock to `seconds` since the start of the scenario (never backwards) and polls.
        /// Returns whether that poll started a shed.
        @discardableResult
        func poll(at seconds: TimeInterval) -> Bool {
            precondition(seconds >= clockSeconds, "the fake clock must not run backwards")
            clockSeconds = seconds
            let before = shedCount
            watchdog.poll()
            return shedCount > before
        }

        /// Runs `start` (which may start a shed) and, if it did, lets the real run loop turn until that
        /// shed has finished. With `holdCompletions` set and a short `shedCompletionTimeout` that is the
        /// timeout finishing it; otherwise the shed has already finished and this returns at once.
        @discardableResult
        func settled(file: StaticString = #filePath, line: UInt = #line, _ start: () -> Bool) -> Bool {
            let finishedBefore = finishedSheds
            guard start() else { return false }
            let deadline = Date().addingTimeInterval(5)
            while finishedSheds == finishedBefore, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            XCTAssertGreaterThan(finishedSheds, finishedBefore, "the shed never finished", file: file, line: line)
            return true
        }

        /// `poll(at:)`, then wait for the shed it started (if any) to finish.
        @discardableResult
        func pollSettled(at seconds: TimeInterval, file: StaticString = #filePath, line: UInt = #line) -> Bool {
            settled(file: file, line: line) { poll(at: seconds) }
        }

        @discardableResult
        func criticalShed(at seconds: TimeInterval) -> Bool {
            precondition(seconds >= clockSeconds, "the fake clock must not run backwards")
            clockSeconds = seconds
            let before = shedCount
            watchdog.shed(reason: "the system reported critical memory pressure", critical: true)
            return shedCount > before
        }

        @discardableResult
        func shed(at seconds: TimeInterval) -> Bool {
            precondition(seconds >= clockSeconds, "the fake clock must not run backwards")
            clockSeconds = seconds
            let before = shedCount
            watchdog.shed(reason: "the test asked for a shed")
            return shedCount > before
        }
    }

    // MARK: - (a) Unhelpful sheds back off: 120 s, 600 s, then hourly forever

    /// The load-bearing test. The footprint stays at 2000 MB whatever the shed does, as it did in
    /// the incident. The schedule is measured from when the previous shed STARTED, on `now()`.
    /// Boundaries are probed a second either side, not exactly on the line: whether "exactly 120 s"
    /// counts is not part of the contract.
    func testAShedThatFreesNothingIsRetriedAfterTwoMinutesThenTenMinutesThenHourlyForever() {
        let rig = Rig()
        rig.freedByNextShed = 0

        // The first shed behaves exactly as it always did.
        XCTAssertTrue(rig.poll(at: 0), "the first poll over the line sheds")
        XCTAssertEqual(rig.shedCount, 1)

        // k = 1: 120 s.
        XCTAssertFalse(rig.poll(at: 30), "the old 30 s cadence is exactly what must stop")
        XCTAssertFalse(rig.poll(at: 31))
        XCTAssertFalse(rig.poll(at: 119), "one second short of 120 s")
        XCTAssertEqual(rig.shedCount, 1, "no shed fan-out while backed off")
        XCTAssertTrue(rig.poll(at: 121), "120 s have passed since the first shed started")
        XCTAssertEqual(rig.shedCount, 2)

        // k = 2: 600 s from the shed that started at 121.
        XCTAssertFalse(rig.poll(at: 121 + 31))
        XCTAssertFalse(rig.poll(at: 121 + 121), "the 120 s step no longer applies")
        XCTAssertFalse(rig.poll(at: 121 + 599))
        XCTAssertEqual(rig.shedCount, 2)
        XCTAssertTrue(rig.poll(at: 121 + 601))
        XCTAssertEqual(rig.shedCount, 3)

        // k = 3: 3600 s from the shed that started at 722.
        let third = 121.0 + 601
        XCTAssertFalse(rig.poll(at: third + 601), "the 600 s step no longer applies")
        XCTAssertFalse(rig.poll(at: third + 3_599))
        XCTAssertEqual(rig.shedCount, 3)
        XCTAssertTrue(rig.poll(at: third + 3_601))
        XCTAssertEqual(rig.shedCount, 4)

        // k = 4, 5, ...: still an hour, never longer and never shorter.
        var last = third + 3_601
        for round in 5 ... 7 {
            XCTAssertFalse(rig.poll(at: last + 601), "round \(round): still an hour, not ten minutes")
            XCTAssertFalse(rig.poll(at: last + 3_599), "round \(round)")
            XCTAssertTrue(rig.poll(at: last + 3_601), "round \(round): an hour on, it sheds again")
            XCTAssertEqual(rig.shedCount, round)
            last += 3_601
        }
    }

    /// The pre-existing `onShed(completion)` hook has to get the same protection: it is the only
    /// hook older wiring knows about, and "keeps working as before" must not mean "keeps blanking
    /// the pane every 30 s".
    func testTheSameBackOffAppliesWhenOnlyTheUnscopedOnShedIsWired() {
        let rig = Rig(useScopedCallback: false)

        XCTAssertTrue(rig.poll(at: 0))
        XCTAssertFalse(rig.poll(at: 31), "backed off after one unhelpful shed")
        XCTAssertFalse(rig.poll(at: 119))
        XCTAssertTrue(rig.poll(at: 121))
        XCTAssertFalse(rig.poll(at: 121 + 31))
        XCTAssertEqual(rig.legacyShedCount, 2)
    }

    /// When both are set the scoped hook wins, and the unscoped one is not called as well.
    func testTheScopedHookIsPreferredOverOnShedWhenBothAreSet() {
        let rig = Rig()
        var unscopedCalls = 0
        rig.watchdog.onShed = { completion in
            unscopedCalls += 1
            completion()
        }

        XCTAssertTrue(rig.poll(at: 0))

        XCTAssertEqual(rig.scopes.count, 1)
        XCTAssertEqual(unscopedCalls, 0, "onShedScoped is preferred over onShed when it is set")
    }

    /// While the watchdog is backed off, polls still read the footprint and must stay quiet: no
    /// shed, and no "Shed retained content" toast for a shed that did not happen.
    func testPollsDuringBackOffRaiseNoShedToast() {
        let rig = Rig()
        XCTAssertTrue(rig.poll(at: 0))
        let toastsAfterFirstShed = rig.shedToasts.count

        for t in stride(from: 30.0, through: 110.0, by: 10) { rig.poll(at: t) }

        XCTAssertEqual(rig.shedToasts.count, toastsAfterFirstShed,
                       "a refused shed must not announce a shed")
        XCTAssertEqual(rig.shedCount, 1)
    }

    // MARK: - (b) A shed that frees memory behaves exactly as before

    func testAShedThatFreesMemoryDoesNotBackOffAndTheNextPollOverTheLineShedsAfterThirtySeconds() {
        let rig = Rig(level: 2_000 * Self.mb)
        rig.freedByNextShed = 1_200 * Self.mb      // 2000 -> 800 MB

        XCTAssertTrue(rig.poll(at: 0))
        XCTAssertEqual(rig.level, 800 * Self.mb, "precondition: this shed freed 1200 MB")

        // The app grows back over the line, as a busy session does.
        rig.level = 2_000 * Self.mb
        XCTAssertFalse(rig.poll(at: 10), "the 30 s minimum gap still applies after a helpful shed")
        XCTAssertTrue(rig.poll(at: 31), "a helpful shed leaves no back-off: 31 s later it may shed again")
        XCTAssertEqual(rig.shedCount, 2)

        // And again, and again: k stays 0, so the cadence stays 30 s however many times it helps.
        rig.level = 2_000 * Self.mb
        XCTAssertFalse(rig.poll(at: 31 + 29))
        XCTAssertTrue(rig.poll(at: 31 + 31))
        rig.level = 2_000 * Self.mb
        XCTAssertTrue(rig.poll(at: 31 + 31 + 31))
        XCTAssertEqual(rig.shedCount, 4)
    }

    /// A helpful shed in the middle of a back-off resets it: the cadence after it is 30 s, not the
    /// hour the earlier failures had earned.
    func testAHelpfulShedResetsTheBackOff() {
        let rig = Rig()
        // Three unhelpful sheds: 0, 121, 722. The next would not be allowed for an hour.
        XCTAssertTrue(rig.poll(at: 0))
        XCTAssertTrue(rig.poll(at: 121))
        XCTAssertTrue(rig.poll(at: 722))
        XCTAssertFalse(rig.poll(at: 722 + 1_000), "precondition: backed off for an hour")

        // After the hour the poll sheds again, and this time the shed frees something.
        rig.freedByNextShed = 1_200 * Self.mb
        XCTAssertTrue(rig.poll(at: 722 + 3_601), "the hour has passed, so this shed runs")
        XCTAssertEqual(rig.level, 800 * Self.mb)

        rig.level = 2_000 * Self.mb
        rig.freedByNextShed = 0
        XCTAssertTrue(rig.poll(at: 722 + 3_601 + 31), "a helpful shed resets k to 0: back to the 30 s gap")
        // That one was unhelpful, so the schedule starts again from two minutes.
        XCTAssertFalse(rig.poll(at: 722 + 3_601 + 31 + 31))
        XCTAssertFalse(rig.poll(at: 722 + 3_601 + 31 + 119))
        XCTAssertTrue(rig.poll(at: 722 + 3_601 + 31 + 121))
    }

    // MARK: - (c) Dropping below the shed line ends the episode

    func testFallingBelowTheShedLineAndComingBackResetsTheBackOff() {
        let rig = Rig()
        XCTAssertTrue(rig.poll(at: 0))
        XCTAssertTrue(rig.poll(at: 121))
        XCTAssertTrue(rig.poll(at: 121 + 601))
        let lastShed = 121.0 + 601
        XCTAssertFalse(rig.poll(at: lastShed + 40), "precondition: an hour's back-off is in force")

        // The footprint falls back under the warning line: the episode is over.
        rig.level = 900 * Self.mb
        XCTAssertFalse(rig.poll(at: lastShed + 50), "below the line there is nothing to shed")
        XCTAssertEqual(rig.shedCount, 3)

        // And it climbs again. Past the 30 s gap, the first shed of the new episode is allowed.
        rig.level = 2_000 * Self.mb
        XCTAssertTrue(rig.poll(at: lastShed + 90),
                      "a new episode is a clean slate: only the 30 s gap applies")
        XCTAssertEqual(rig.shedCount, 4)

        // The back-off schedule starts over from two minutes, not from where the old one left off.
        XCTAssertFalse(rig.poll(at: lastShed + 90 + 31))
        XCTAssertTrue(rig.poll(at: lastShed + 90 + 121))
    }

    /// "Below the shed line" is what ends the episode, not "below the warning line": a dip into the
    /// warning band (1.2 to 1.6 GB) is still not over the shed line.
    func testDippingIntoTheWarningBandAlsoEndsTheEpisode() {
        let rig = Rig()
        XCTAssertTrue(rig.poll(at: 0))
        XCTAssertFalse(rig.poll(at: 40), "precondition: backed off")

        rig.level = 1_300 * Self.mb
        XCTAssertFalse(rig.poll(at: 50), "1.3 GB is below the shed line: warn territory, not shed")
        XCTAssertEqual(rig.shedCount, 1)

        rig.level = 2_000 * Self.mb
        XCTAssertTrue(rig.poll(at: 70), "the episode ended at 1.3 GB, so 70 s on only the 30 s gap applies")
    }

    func testAPollBelowTheShedLineNeverSheds() {
        let rig = Rig(level: Self.shedLine - 1)
        for t in stride(from: 0.0, through: 300, by: 30) {
            XCTAssertFalse(rig.poll(at: t))
        }
        XCTAssertEqual(rig.shedCount, 0)
        XCTAssertTrue(rig.shedToasts.isEmpty)
    }

    func testAPollExactlyAtTheShedLineSheds() {
        let rig = Rig(level: Self.shedLine)
        XCTAssertTrue(rig.poll(at: 0), "the line is inclusive: >= shedBytes sheds")
    }

    // MARK: - (d) Scope, critical pressure, the in-flight guard

    func testAPollTriggeredShedAsksForOffscreenContentOnly() {
        let rig = Rig()
        XCTAssertTrue(rig.poll(at: 0))
        XCTAssertEqual(rig.scopes, [.offscreenOnly],
                       "a poll that sees a high footprint must never ask to blank what is on screen")
    }

    func testANonCriticalDirectShedAlsoAsksForOffscreenContentOnly() {
        let rig = Rig()
        XCTAssertTrue(rig.shed(at: 0))
        XCTAssertEqual(rig.scopes, [.offscreenOnly])
    }

    func testACriticalShedAsksForEverything() {
        let rig = Rig()
        XCTAssertTrue(rig.criticalShed(at: 0))
        XCTAssertEqual(rig.scopes, [.everything],
                       "the OS says the machine is out of memory: the visible pane is not exempt")
    }

    func testACriticalShedRunsWhileBackedOffButNotInsideTheThirtySecondGap() {
        let rig = Rig()
        XCTAssertTrue(rig.poll(at: 0))
        XCTAssertFalse(rig.poll(at: 40), "precondition: the poll path is backed off for two minutes")

        XCTAssertTrue(rig.criticalShed(at: 40), "critical pressure ignores the back-off")
        XCTAssertEqual(rig.scopes, [.offscreenOnly, .everything])

        // Even critical pressure keeps the minimum gap, measured on `now`: 10 s after a shed
        // started is too soon for another.
        XCTAssertFalse(rig.criticalShed(at: 50), "the 30 s minimum gap still applies to a critical shed")
        XCTAssertEqual(rig.scopes.count, 2)
    }

    func testACriticalShedStillHonoursTheThirtySecondGapAfterAPollShed() {
        let rig = Rig()
        XCTAssertTrue(rig.poll(at: 0))
        XCTAssertFalse(rig.criticalShed(at: 10))
        XCTAssertTrue(rig.criticalShed(at: 31))
    }

    func testACriticalShedDoesNotReenterAShedThatIsStillInFlight() {
        let rig = Rig()
        rig.holdCompletions = true

        XCTAssertTrue(rig.poll(at: 0), "the poll shed starts and its completion is held")
        XCTAssertFalse(rig.criticalShed(at: 100),
                       "a shed spanning several run-loop turns must not be started a second time, "
                       + "critical or not, however much time has passed")
        XCTAssertEqual(rig.shedCount, 1)

        rig.completeHeldShed()
        XCTAssertTrue(rig.criticalShed(at: 101), "once the first shed has finished, critical may run")
        XCTAssertEqual(rig.scopes, [.offscreenOnly, .everything])
        rig.completeHeldShed()
    }

    // MARK: - (e) Reporting

    func testAnUnhelpfulShedsToastKeepsItsTitleAndNamesTheLargestMemoryCategory() throws {
        let rig = Rig()
        XCTAssertTrue(rig.poll(at: 0))

        XCTAssertEqual(rig.shedToasts.count, 1)
        let toast = try XCTUnwrap(rig.shedToasts.first)
        XCTAssertEqual(toast.title, Self.toastTitle, "the title never changes")
        XCTAssertTrue(toast.detail.contains("Footprint 2000 → 2000 MB."),
                      "the existing footprint sentence stays: \(toast.detail)")
        XCTAssertTrue(toast.detail.contains(Self.heldOutsidePhrase),
                      "an unhelpful shed says where the memory is not: \(toast.detail)")
        XCTAssertTrue(toast.detail.contains("Malloc Small 1678 MB"),
                      "and where it is, by the largest category: \(toast.detail)")
        XCTAssertFalse(toast.detail.contains("Malloc Large 39 MB"),
                       "only the largest category is named: \(toast.detail)")
    }

    func testAHelpfulShedsToastHasNeitherTheOutsideSentenceNorACategory() throws {
        let rig = Rig()
        rig.freedByNextShed = 1_200 * Self.mb

        XCTAssertTrue(rig.poll(at: 0))

        let toast = try XCTUnwrap(rig.shedToasts.first)
        XCTAssertEqual(toast.title, Self.toastTitle)
        XCTAssertTrue(toast.detail.contains("Footprint 2000 → 800 MB."), toast.detail)
        XCTAssertFalse(toast.detail.contains(Self.heldOutsidePhrase), toast.detail)
        XCTAssertFalse(toast.detail.contains("Malloc Small"), toast.detail)
        XCTAssertFalse(toast.detail.contains("1678 MB"), toast.detail)
    }

    func testOnlyTheFirstUnhelpfulShedOfAnEpisodeRaisesAToast() {
        let rig = Rig()

        XCTAssertTrue(rig.poll(at: 0))
        XCTAssertEqual(rig.shedToasts.count, 1, "the first unhelpful shed tells the operator")

        XCTAssertTrue(rig.poll(at: 121))
        XCTAssertTrue(rig.poll(at: 121 + 601))
        XCTAssertTrue(rig.poll(at: 121 + 601 + 3_601))
        XCTAssertEqual(rig.shedCount, 4, "precondition: three more unhelpful sheds ran")
        XCTAssertEqual(rig.shedToasts.count, 1,
                       "later unhelpful sheds in the same episode are silent: the operator has been told")
    }

    func testAHelpfulShedAlwaysToastsEvenAfterSilentUnhelpfulOnes() throws {
        let rig = Rig()
        XCTAssertTrue(rig.poll(at: 0))
        XCTAssertTrue(rig.poll(at: 121))
        XCTAssertEqual(rig.shedToasts.count, 1, "precondition: the second unhelpful shed was silent")

        rig.freedByNextShed = 1_200 * Self.mb
        XCTAssertTrue(rig.poll(at: 121 + 601))

        XCTAssertEqual(rig.shedToasts.count, 2, "a shed that freed memory is always worth saying")
        let detail = try XCTUnwrap(rig.shedToasts.last).detail
        XCTAssertTrue(detail.contains("Footprint 2000 → 800 MB."), detail)
        XCTAssertFalse(detail.contains(Self.heldOutsidePhrase), detail)
    }

    func testANewEpisodeToastsAgainOnItsFirstUnhelpfulShed() throws {
        let rig = Rig()
        XCTAssertTrue(rig.poll(at: 0))
        XCTAssertTrue(rig.poll(at: 121))
        XCTAssertEqual(rig.shedToasts.count, 1, "precondition: one toast for the first episode")

        rig.level = 900 * Self.mb
        rig.poll(at: 130)                  // the episode ends here
        rig.level = 2_000 * Self.mb
        XCTAssertTrue(rig.poll(at: 170))

        XCTAssertEqual(rig.shedToasts.count, 2,
                       "a new episode tells the operator again, once")
        let detail = try XCTUnwrap(rig.shedToasts.last).detail
        XCTAssertTrue(detail.contains(Self.heldOutsidePhrase), detail)
    }

    /// The category in the toast is read when the shed finishes, from the live summary, not a value
    /// captured at some earlier time: here the largest category changes between two episodes.
    func testTheCategoryNamedIsTheOneInTheSummaryAtThatMoment() throws {
        let rig = Rig()
        rig.watchdog.summarize = {
            MemorySummary(physicalFootprintBytes: 1_900 * Self.mb, mallocBlocksInUse: 10,
                          mallocBytesInUse: 100 * Self.mb,
                          categories: [MemorySummary.Category(name: "Malloc Large", dirtyBytes: 1_500 * Self.mb),
                                       MemorySummary.Category(name: "Malloc Small", dirtyBytes: 200 * Self.mb)])
        }
        XCTAssertTrue(rig.poll(at: 0))

        let detail = try XCTUnwrap(rig.shedToasts.first).detail
        XCTAssertTrue(detail.contains("Malloc Large 1500 MB"), detail)
        XCTAssertFalse(detail.contains("Malloc Small"), detail)
    }

    /// An unhelpful shed with nothing to say about categories must still tell the operator that the
    /// memory is held outside the transcript: the sentence is the point, the category is a bonus.
    func testAnUnhelpfulShedWithAnEmptySummaryStillSaysTheMemoryIsHeldOutsideTheTranscript() throws {
        let rig = Rig()
        rig.watchdog.summarize = {
            MemorySummary(physicalFootprintBytes: 0, mallocBlocksInUse: 0, mallocBytesInUse: 0, categories: [])
        }
        XCTAssertTrue(rig.poll(at: 0))

        let toast = try XCTUnwrap(rig.shedToasts.first)
        XCTAssertEqual(toast.title, Self.toastTitle)
        XCTAssertTrue(toast.detail.contains(Self.heldOutsidePhrase), toast.detail)
    }

    // MARK: - (f) The helpful / unhelpful thresholds

    /// A shed is helpful iff freed >= 100 MB AND freed >= 10% of before. Observed through the
    /// toast, which names the outside-the-transcript sentence for an unhelpful shed only.
    /// `shed(reason:)` is called directly because the 600 MB cases are below the poll's shed line.
    private func assertShed(before: Int, freed: Int, isHelpful: Bool,
                            _ note: String, file: StaticString = #filePath, line: UInt = #line) {
        let rig = Rig(level: before)
        rig.freedByNextShed = freed
        XCTAssertTrue(rig.shed(at: 0), "\(note): the shed must run", file: file, line: line)
        guard let toast = rig.shedToasts.first else {
            return XCTFail("\(note): a first shed always toasts", file: file, line: line)
        }
        XCTAssertEqual(toast.title, Self.toastTitle, note, file: file, line: line)
        XCTAssertEqual(toast.detail.contains(Self.heldOutsidePhrase), !isHelpful,
                       "\(note): expected \(isHelpful ? "helpful" : "unhelpful"), detail was: \(toast.detail)",
                       file: file, line: line)

        // And the schedule agrees with the toast: an unhelpful shed backs the next one off.
        rig.level = max(rig.level, Self.shedLine)
        rig.freedByNextShed = 0
        let secondAllowedAfter31s = rig.shed(at: 31)
        XCTAssertEqual(secondAllowedAfter31s, isHelpful,
                       "\(note): a second shed 31 s later is allowed only after a helpful shed",
                       file: file, line: line)
    }

    func testAShedThatFreesLessThan100MBIsUnhelpfulEvenWhenItIsALargeFractionOfASmallFootprint() {
        let mb = Self.mb
        assertShed(before: 600 * mb, freed: 90 * mb, isHelpful: false, "600 MB, freed 90 MB (15%)")
        assertShed(before: 600 * mb, freed: 100 * mb - 1, isHelpful: false, "600 MB, freed one byte under 100 MB")
        assertShed(before: 2_000 * mb, freed: 99 * mb, isHelpful: false, "2000 MB, freed 99 MB")
    }

    func testAShedThatFreesAtLeast100MBAndTenPercentIsHelpful() {
        let mb = Self.mb
        assertShed(before: 600 * mb, freed: 110 * mb, isHelpful: true, "600 MB, freed 110 MB (18%)")
        assertShed(before: 600 * mb, freed: 100 * mb, isHelpful: true, "600 MB, freed exactly 100 MB")
        assertShed(before: 2_000 * mb, freed: 250 * mb, isHelpful: true, "2000 MB, freed 250 MB (12.5%)")
        assertShed(before: 2_000 * mb, freed: 200 * mb, isHelpful: true, "2000 MB, freed exactly 10%")
    }

    func testAShedThatFreesAtLeast100MBButUnderTenPercentIsUnhelpful() {
        let mb = Self.mb
        assertShed(before: 2_000 * mb, freed: 150 * mb, isHelpful: false, "2000 MB, freed 150 MB (7.5%)")
        assertShed(before: 2_000 * mb, freed: 100 * mb, isHelpful: false, "2000 MB, freed exactly 100 MB (5%)")
        assertShed(before: 2_000 * mb, freed: 200 * mb - 1, isHelpful: false, "2000 MB, freed one byte under 10%")
        assertShed(before: 4_000 * mb, freed: 399 * mb, isHelpful: false, "4000 MB, freed 399 MB (9.98%)")
    }

    func testAShedThatGrowsTheFootprintIsUnhelpful() {
        let rig = Rig(level: 2_000 * Self.mb)
        // `freed` is `before - after`, so a shed that left the app larger (the compaction itself
        // allocates) freed a negative amount.
        rig.freedByNextShed = -50 * Self.mb
        XCTAssertTrue(rig.shed(at: 0))
        XCTAssertEqual(rig.shedToasts.first?.detail.contains(Self.heldOutsidePhrase), true)
    }

    // MARK: - Hysteresis and timeouts (review follow-ups)

    /// A footprint hovering just under the line (1.5 GB, above 90% of it) is the same episode: the
    /// back-off must survive it.
    func testDippingJustUnderTheShedLineKeepsTheEpisodeAndItsBackOff() {
        let rig = Rig()
        XCTAssertTrue(rig.poll(at: 0))
        rig.level = 1_500 * Self.mb
        XCTAssertFalse(rig.poll(at: 40), "under the line there is nothing to shed")
        rig.level = 2_000 * Self.mb
        XCTAssertFalse(rig.poll(at: 70), "still the same episode, so the two-minute back-off holds")
        XCTAssertFalse(rig.poll(at: 119))
        XCTAssertTrue(rig.poll(at: 121))
    }

    // MARK: - Timed-out sheds: inconclusive, but not free

    private static let timeoutGaps = MemoryWatchdog.timeoutBackoffSchedule
    private static let inconclusivePhrase = "still running when it was measured"

    /// A rig whose sheds hang until their (short) completion timeout finishes them.
    private func hangingRig() -> Rig {
        let rig = Rig()
        rig.holdCompletions = true
        rig.watchdog.shedCompletionTimeout = 0.05
        return rig
    }

    /// A shed that finishes only via the completion timeout was measured on a stale "after": it
    /// is not counted as unhelpful and not described as "held outside the transcript". It is not
    /// free either: the next shed needs the first step of the timeout schedule, not just 30 s.
    func testAShedThatFinishesViaTheTimeoutIsInconclusiveAndOnlyBacksOffOnTheTimeoutSchedule() {
        let rig = hangingRig()
        XCTAssertEqual(Self.timeoutGaps.first, 60, "precondition: the first timeout step is a minute")
        XCTAssertTrue(rig.pollSettled(at: 0))

        XCTAssertEqual(rig.shedToasts.count, 1)
        XCTAssertFalse(rig.shedToasts[0].detail.contains(Self.heldOutsidePhrase))
        XCTAssertTrue(rig.shedToasts[0].detail.contains(Self.inconclusivePhrase), rig.shedToasts[0].detail)

        XCTAssertFalse(rig.pollSettled(at: 30), "30 s is no longer enough after a timed-out shed")
        XCTAssertFalse(rig.pollSettled(at: 40))
        XCTAssertFalse(rig.pollSettled(at: Self.timeoutGaps[0] - 1), "one second short of the first timeout step")
        XCTAssertEqual(rig.shedCount, 1)
        XCTAssertTrue(rig.pollSettled(at: Self.timeoutGaps[0] + 1), "the timeout step has passed")
        XCTAssertEqual(rig.shedCount, 2)
    }

    /// The incident shape for timeouts: a pane that never finishes compacting keeps the footprint
    /// over the line, and every 30 s poll used to start a shed and toast again. Over an hour of 30 s
    /// polls the operator is told once, and sheds are spaced by at least the timeout schedule.
    func testAShedThatKeepsTimingOutIsNeitherRepeatedNorAnnouncedEveryThirtySeconds() {
        let rig = hangingRig()
        var starts: [TimeInterval] = []

        for t in stride(from: 0.0, through: 3_600, by: 30) {
            if rig.pollSettled(at: t) { starts.append(t) }
        }

        XCTAssertEqual(rig.shedToasts.count, 1,
                       "a repeated timeout must not repeat the toast: \(rig.shedToasts.map { $0.detail })")
        XCTAssertGreaterThanOrEqual(starts.count, 4, "the watchdog still tries again, it is not wedged: \(starts)")
        XCTAssertLessThanOrEqual(starts.count, 8, "an hour of polls produced \(starts.count) sheds: \(starts)")
        for (index, pair) in zip(starts, starts.dropFirst()).enumerated() {
            let step = Self.timeoutGaps[min(index, Self.timeoutGaps.count - 1)]
            XCTAssertGreaterThan(pair.1 - pair.0, step,
                                 "shed \(index + 2) started \(pair.1 - pair.0) s after the previous one; "
                                 + "the schedule asks for more than \(step) s. Starts: \(starts)")
        }
    }

    /// 60 s, 300 s, then 900 s for the third and every later consecutive timeout, measured from when
    /// the previous shed started. Probed a second either side of each step.
    func testConsecutiveTimedOutShedsBackOffOnTheTimeoutSchedule() {
        let rig = hangingRig()
        XCTAssertEqual(Self.timeoutGaps, [60, 300, 900], "precondition: the documented schedule")

        XCTAssertTrue(rig.pollSettled(at: 0))

        // 1st timeout: 60 s.
        XCTAssertFalse(rig.pollSettled(at: 59))
        XCTAssertTrue(rig.pollSettled(at: 61))

        // 2nd consecutive timeout: 300 s from the shed that started at 61.
        XCTAssertFalse(rig.pollSettled(at: 61 + 61), "the 60 s step no longer applies")
        XCTAssertFalse(rig.pollSettled(at: 61 + 299))
        XCTAssertTrue(rig.pollSettled(at: 61 + 301))
        XCTAssertEqual(rig.shedCount, 3)

        // 3rd consecutive timeout: 900 s from the shed that started at 362.
        let third = 61.0 + 301
        XCTAssertFalse(rig.pollSettled(at: third + 301), "the 300 s step no longer applies")
        XCTAssertFalse(rig.pollSettled(at: third + 899))
        XCTAssertTrue(rig.pollSettled(at: third + 901))
        XCTAssertEqual(rig.shedCount, 4)

        // 4th and later: still 900 s, never longer.
        let fourth = third + 901
        XCTAssertFalse(rig.pollSettled(at: fourth + 899))
        XCTAssertTrue(rig.pollSettled(at: fourth + 901))
        XCTAssertEqual(rig.shedCount, 5)
    }

    /// A timed-out shed says nothing about whether shedding helps, so it must not push the
    /// unhelpful-shed back-off up its 120 s / 600 s / 3600 s ladder: after three timeouts, one shed
    /// that completes and frees nothing is the FIRST unhelpful one and earns 120 s.
    func testTimedOutShedsDoNotCountTowardTheUnhelpfulStreak() {
        let rig = hangingRig()
        XCTAssertTrue(rig.pollSettled(at: 0))
        XCTAssertTrue(rig.pollSettled(at: 61))
        XCTAssertTrue(rig.pollSettled(at: 61 + 301))
        let lastTimeout = 61.0 + 301

        rig.holdCompletions = false
        rig.freedByNextShed = 0
        XCTAssertTrue(rig.pollSettled(at: lastTimeout + 901), "the 900 s timeout step has passed")
        let unhelpful = lastTimeout + 901

        XCTAssertFalse(rig.pollSettled(at: unhelpful + 119))
        XCTAssertTrue(rig.pollSettled(at: unhelpful + 121),
                      "one unhelpful shed earns 120 s, not the ten minutes or hour that three timeouts would")
        XCTAssertEqual(rig.shedCount, 5)
    }

    /// Both streaks can be live at once. The gap is the longer of the two, so a short timeout step
    /// never shortens an unhelpful-shed back-off, and a long one is not cut short by it.
    func testTheLongerOfTheUnhelpfulAndTimeoutGapsApplies() {
        let rig = hangingRig()
        rig.holdCompletions = false
        XCTAssertTrue(rig.pollSettled(at: 0), "a normal shed that frees nothing: 120 s")

        rig.holdCompletions = true
        XCTAssertFalse(rig.pollSettled(at: 119))
        XCTAssertTrue(rig.pollSettled(at: 121), "shed 2 times out")
        // Timeout step 1 is 60 s but the unhelpful streak still asks for 120 s: the longer wins.
        XCTAssertFalse(rig.pollSettled(at: 121 + 61), "60 s is not enough while 120 s is owed")
        XCTAssertFalse(rig.pollSettled(at: 121 + 119))
        XCTAssertTrue(rig.pollSettled(at: 121 + 121), "shed 3 times out")
        // Timeout step 2 is 300 s, longer than the unhelpful 120 s: now the timeout streak wins.
        XCTAssertFalse(rig.pollSettled(at: 242 + 121), "120 s is not enough once the timeout step is 300 s")
        XCTAssertFalse(rig.pollSettled(at: 242 + 299))
        XCTAssertTrue(rig.pollSettled(at: 242 + 301), "shed 4 times out")
        // Timeout step 3 is 900 s.
        XCTAssertFalse(rig.pollSettled(at: 543 + 899))
        XCTAssertTrue(rig.pollSettled(at: 543 + 901))
        XCTAssertEqual(rig.shedCount, 5)
    }

    /// A shed that completes normally ends the timeout streak and re-arms the toast: the next
    /// timeout is told again, and the gap that follows is the short, first-step one.
    func testAShedThatCompletesNormallyResetsTheTimeoutBackOffAndTheToast() throws {
        let rig = hangingRig()
        XCTAssertTrue(rig.pollSettled(at: 0))
        XCTAssertTrue(rig.pollSettled(at: 61))
        XCTAssertEqual(rig.shedToasts.count, 1, "precondition: two timeouts, one toast")

        // 300 s have passed; this shed completes normally and frees nothing (first unhelpful one).
        rig.holdCompletions = false
        rig.freedByNextShed = 0
        XCTAssertTrue(rig.pollSettled(at: 61 + 301))
        XCTAssertEqual(rig.shedToasts.count, 2, "a normal completion reports as it always did")
        XCTAssertTrue(rig.shedToasts[1].detail.contains(Self.heldOutsidePhrase), rig.shedToasts[1].detail)
        let normal = 61.0 + 301

        // The timeout streak is gone: only the unhelpful 120 s is owed (300 s would mean it survived).
        XCTAssertFalse(rig.pollSettled(at: normal + 119))
        rig.holdCompletions = true
        XCTAssertTrue(rig.pollSettled(at: normal + 121), "only the 120 s unhelpful gap applies")
        XCTAssertEqual(rig.shedToasts.count, 3, "the first timeout after a normal shed is told again")
        let detail = try XCTUnwrap(rig.shedToasts.last).detail
        XCTAssertTrue(detail.contains(Self.inconclusivePhrase), detail)
        XCTAssertFalse(detail.contains(Self.heldOutsidePhrase), detail)
        let timedOut = normal + 121

        // And that timeout is the 1st of a new streak: the gap is the larger of 120 s (unhelpful) and 60 s.
        XCTAssertFalse(rig.pollSettled(at: timedOut + 119))
        XCTAssertTrue(rig.pollSettled(at: timedOut + 121))
    }

    /// A shed that completes normally AND helps ends both streaks: the next one is a plain 30 s away.
    func testAHelpfulShedAfterTimeoutsLeavesOnlyTheThirtySecondGap() {
        let rig = hangingRig()
        XCTAssertTrue(rig.pollSettled(at: 0))
        XCTAssertTrue(rig.pollSettled(at: 61))
        XCTAssertFalse(rig.pollSettled(at: 61 + 200), "precondition: 300 s are owed after two timeouts")

        rig.holdCompletions = false
        rig.freedByNextShed = 1_200 * Self.mb
        XCTAssertTrue(rig.pollSettled(at: 61 + 301))
        XCTAssertEqual(rig.level, 800 * Self.mb, "precondition: that shed freed 1200 MB")

        rig.level = 2_000 * Self.mb
        rig.freedByNextShed = 0
        XCTAssertFalse(rig.pollSettled(at: 61 + 301 + 20))
        XCTAssertTrue(rig.pollSettled(at: 61 + 301 + 31), "no streak is left: 30 s is enough")
    }

    /// Falling clearly below the line ends the episode: the timeout back-off and the toast start over.
    func testEndingTheEpisodeResetsTheTimeoutBackOffAndTheToast() throws {
        let rig = hangingRig()
        XCTAssertTrue(rig.pollSettled(at: 0))
        XCTAssertTrue(rig.pollSettled(at: 61))
        XCTAssertEqual(rig.shedToasts.count, 1, "precondition: two timeouts, one toast")

        rig.level = 900 * Self.mb
        XCTAssertFalse(rig.pollSettled(at: 70), "the episode ends here: nothing to shed")
        rig.level = 2_000 * Self.mb

        // Only 39 s after the last shed: a 300 s back-off would refuse, a clean slate allows it.
        XCTAssertTrue(rig.pollSettled(at: 100), "a new episode has only the 30 s gap")
        XCTAssertEqual(rig.shedToasts.count, 2, "a new episode is told again")
        let detail = try XCTUnwrap(rig.shedToasts.last).detail
        XCTAssertTrue(detail.contains(Self.inconclusivePhrase), detail)

        // And the schedule starts over from its first step.
        XCTAssertFalse(rig.pollSettled(at: 100 + 59))
        XCTAssertTrue(rig.pollSettled(at: 100 + 61))
    }

    /// A footprint that merely hovers under the line (1.5 GB, above the episode-end mark) is still
    /// one episode: the timeout back-off and the "already told" state survive it.
    func testDippingJustUnderTheLineKeepsTheTimeoutBackOffAndThePriorToast() {
        let rig = hangingRig()
        XCTAssertTrue(rig.pollSettled(at: 0))
        XCTAssertTrue(rig.pollSettled(at: 61))

        rig.level = 1_500 * Self.mb
        XCTAssertFalse(rig.pollSettled(at: 70))
        rig.level = 2_000 * Self.mb
        XCTAssertFalse(rig.pollSettled(at: 100), "same episode: 300 s are still owed")
        XCTAssertTrue(rig.pollSettled(at: 61 + 301))
        XCTAssertEqual(rig.shedToasts.count, 1, "and the operator is not told a second time")
    }

    /// Critical OS pressure ignores the timeout back-off (it keeps only the 30 s minimum gap).
    func testACriticalShedIgnoresTheTimeoutBackOff() {
        let rig = hangingRig()
        XCTAssertTrue(rig.pollSettled(at: 0))
        XCTAssertFalse(rig.pollSettled(at: 40), "precondition: the poll path owes 60 s")

        XCTAssertTrue(rig.settled { rig.criticalShed(at: 40) }, "critical pressure is not held back by the back-off")
        XCTAssertEqual(rig.scopes, [.offscreenOnly, .everything])
        XCTAssertFalse(rig.settled { rig.criticalShed(at: 50) }, "the 30 s minimum gap still applies")
        XCTAssertTrue(rig.settled { rig.criticalShed(at: 71) })
    }
}
