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
            watchdog.relievePressure = {}
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

    /// A shed that finishes only via the completion timeout was measured on a stale "after": it
    /// is neither counted as unhelpful nor described as "held outside the transcript".
    func testAShedThatFinishesViaTheTimeoutIsInconclusiveAndDoesNotBackOff() {
        let rig = Rig()
        rig.holdCompletions = true
        rig.watchdog.shedCompletionTimeout = 0.05
        XCTAssertTrue(rig.poll(at: 0))

        let settled = expectation(description: "the timeout finished the shed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
        wait(for: [settled], timeout: 5)

        XCTAssertEqual(rig.shedToasts.count, 1)
        XCTAssertFalse(rig.shedToasts[0].detail.contains(Self.heldOutsidePhrase))
        rig.holdCompletions = false
        XCTAssertTrue(rig.poll(at: 40), "no streak was recorded, so only the 30 s gap applies")
    }
}
