import XCTest

// MemoryWatchdog is compiled into this target directly (logic test — no host
// app). Its one outside dependency, `TranscriptDiagnostics.physicalFootprint()`,
// cannot be: see the note at the bottom of this file.

/// Behavioural tests for `MemoryWatchdog.shed(reason:)`.
///
/// One contract, and it is entirely about ordering. Shedding is asynchronous —
/// `onShed` fans out to every pane, which reaches `ChatSession`, which reaches
/// `TurnPayloadStore.compactBatch`, which dispatches LZFSE to a `.utility` queue
/// and applies the resulting skeletons in a main-queue callback. `shed` used to
/// run pressure relief and re-read the footprint immediately after invoking
/// `onShed`, so both happened before a single byte had been freed: relief handed
/// back nothing because the allocations still existed, and the "after" figure was
/// the "before" figure with extra steps. The operator's toast and the log line
/// both reported a shed that had not happened yet.
///
/// So every test here is a statement about *when* something ran relative to the
/// completion, not about what the numbers are:
///
///  1. The "after" footprint is read only once the completion has fired.
///  2. `relievePressure` runs after the completion, and before the "after" read.
///  3. A completion that never arrives still finishes, via the timeout.
///  4. The completion and the timeout racing finishes exactly once.
///
/// Nothing here inspects `isShedding`, `finished`, `hasWarned` or `lastShed`.
/// Ordering is observed through the injected `footprint` / `relievePressure`
/// seams and through what reaches `onWarn` — which is what the operator sees.
///
/// `start()` is never called: it installs a real memory-pressure `DispatchSource`
/// and a 30 s repeating timer, neither of which belongs in a logic test.
/// `shed(reason:)` is internal precisely so it can be driven directly.
final class MemoryWatchdogTests: XCTestCase {

    // MARK: - Fixtures

    private static let mb = 1_048_576

    /// Deliberately readable round numbers: the detail string reports whole
    /// megabytes, so `2000 → 800` is assertable as text and a shed that measured
    /// too early is visible as `2000 → 2000`.
    private static let beforeBytes = 2_000 * mb
    private static let afterBytes  =   800 * mb

    private let reason = "the test asked for a shed"

    // MARK: - 1. The "after" figure is post-completion

    /// The load-bearing test. `footprint` reports the high figure until the
    /// asynchronous chain says it has finished releasing, and the low figure
    /// afterwards — which is how the real allocator behaves. A `shed` that reads
    /// the footprint immediately after `onShed` returns therefore reports the
    /// *before* figure twice and tells the operator nothing.
    func testTheAfterFootprintIsSampledOnlyOnceTheShedCompletionHasFired() {
        let watchdog = MemoryWatchdog()

        // "Has the compaction actually released anything yet?" — false until the
        // completion runs, exactly as it is in the app: nothing is freed until
        // the LZFSE pass's skeletons have been applied on main.
        var bytesHaveBeenFreed = false
        watchdog.footprint = { bytesHaveBeenFreed ? Self.afterBytes : Self.beforeBytes }
        // Generous, so the shed below is ended by the completion and not by the
        // timeout — the timeout path is tested separately.
        watchdog.shedCompletionTimeout = 5

        var heldCompletion: (() -> Void)?
        watchdog.onShed = { completion in heldCompletion = completion }

        var details: [String] = []
        let reported = expectation(description: "the shed reported its result")
        watchdog.onWarn = { _, detail in
            details.append(detail)
            reported.fulfill()
        }

        watchdog.shed(reason: reason)

        XCTAssertNotNil(heldCompletion,
                        "onShed must be handed a completion, or the shed cannot know when it ended")
        XCTAssertTrue(details.isEmpty,
                      "nothing has been freed yet, so there is no honest figure to report: \(details)")

        // A later run-loop turn — the compaction has now genuinely released the
        // bytes, and only now does it report completion.
        DispatchQueue.main.async {
            bytesHaveBeenFreed = true
            heldCompletion?()
        }
        wait(for: [reported], timeout: 5)

        XCTAssertEqual(details.count, 1)
        let detail = details.first ?? ""
        XCTAssertTrue(detail.contains("Footprint 2000 → 800 MB"),
                      "the operator must be told the post-completion figure; got: \(detail)")
        XCTAssertFalse(detail.contains("2000 → 2000"),
                       "measuring before the completion reports the before figure twice, which is "
                       + "the meaningless delta this ordering exists to prevent; got: \(detail)")
    }

    // MARK: - 2. Relief runs after the completion, before the "after" read

    /// Same window, observed as a call order rather than as a number. Pressure
    /// relief hands back the pages the LZFSE pass has just stopped needing, so it
    /// is worthless before compaction has finished — and the "after" read is
    /// worthless before relief.
    func testPressureReliefRunsAfterTheCompletionAndBeforeTheAfterFootprintRead() {
        let watchdog = MemoryWatchdog()
        var order: [String] = []

        watchdog.footprint = {
            order.append("footprint")
            return Self.beforeBytes
        }
        watchdog.relievePressure = { order.append("relieve") }
        watchdog.shedCompletionTimeout = 5

        var heldCompletion: (() -> Void)?
        var orderAtOnShedEntry: [String] = []
        watchdog.onShed = { completion in
            orderAtOnShedEntry = order
            order.append("onShed")
            heldCompletion = completion
        }

        let reported = expectation(description: "the shed reported its result")
        watchdog.onWarn = { _, _ in
            order.append("warn")
            reported.fulfill()
        }

        watchdog.shed(reason: reason)

        XCTAssertFalse(orderAtOnShedEntry.contains("relieve"),
                       "relief cannot precede the compaction whose freed pages it hands back")
        // The assertion the reverted ordering fails on: control is back in the
        // test, `onShed` has returned, and the completion is still outstanding —
        // so nothing downstream of it may have run.
        XCTAssertEqual(order, ["footprint", "onShed"],
                       "with the completion still outstanding, neither relief nor the after read "
                       + "may have happened; got \(order)")

        DispatchQueue.main.async {
            order.append("completion")
            heldCompletion?()
        }
        wait(for: [reported], timeout: 5)

        XCTAssertEqual(order,
                       ["footprint", "onShed", "completion", "relieve", "footprint", "warn"],
                       "the whole point of this path is that order")
    }

    // MARK: - 3. A completion that never arrives

    /// A pane that never calls back is a bug, but a permanently wedged watchdog is
    /// the incident this class exists to prevent — so the timeout measures anyway
    /// and, critically, releases the shed.
    ///
    /// What this cannot assert: that a *second* `shed` proceeds. `shed` also guards
    /// on `Date().timeIntervalSince(lastShed) > pollInterval` (30 s), so a second
    /// call inside this test would be refused by the clock whether or not
    /// `isShedding` had been cleared — the assertion would pass for the wrong
    /// reason and could never fail. What is observable is that the timeout ran
    /// `finish`, which is the only thing that clears `isShedding`: relief happened,
    /// the footprint was re-read, and the operator was told. That is asserted
    /// below. `testASecondShedIsRefusedWhileTheFirstIsStillInFlight` covers the
    /// other half — that the guard is real while a shed is genuinely in flight.
    func testAShedWhoseCompletionNeverArrivesStillMeasuresAndFinishesViaTheTimeout() {
        let watchdog = MemoryWatchdog()
        watchdog.shedCompletionTimeout = 0.05

        var footprintReads = 0
        watchdog.footprint = {
            footprintReads += 1
            return Self.beforeBytes
        }
        var reliefCount = 0
        watchdog.relievePressure = { reliefCount += 1 }

        var onShedCalls = 0
        var abandonedCompletion: (() -> Void)?
        watchdog.onShed = { completion in
            onShedCalls += 1
            // Dropped on the floor: the pane that should have called this is gone,
            // deadlocked, or forgot.
            abandonedCompletion = completion
        }

        var warnCount = 0
        let reported = expectation(description: "the timeout measured anyway")
        watchdog.onWarn = { _, _ in
            warnCount += 1
            reported.fulfill()
        }

        watchdog.shed(reason: reason)

        XCTAssertEqual(onShedCalls, 1)
        XCTAssertEqual(warnCount, 0,
                       "nothing may be reported while the completion is still outstanding and the "
                       + "timeout has not yet elapsed")
        XCTAssertEqual(reliefCount, 0, "relief waits for the completion too")

        wait(for: [reported], timeout: 5)

        XCTAssertNotNil(abandonedCompletion, "the completion was never called, by construction")
        XCTAssertEqual(warnCount, 1, "the timeout path must still tell the operator")
        XCTAssertEqual(reliefCount, 1,
                       "`finish` ran to completion via the timeout — which is what releases the "
                       + "watchdog for the next episode")
        XCTAssertEqual(footprintReads, 2,
                       "before and after: a timeout that skipped the after read would leave the "
                       + "operator with half a number")
    }

    /// The other half of the guard: while a shed is genuinely in flight, a second
    /// one must not start. Observable as the count of `onShed` invocations.
    func testASecondShedIsRefusedWhileTheFirstIsStillInFlight() {
        let watchdog = MemoryWatchdog()
        watchdog.shedCompletionTimeout = 5
        watchdog.footprint = { Self.beforeBytes }
        watchdog.relievePressure = {}

        var onShedCalls = 0
        var heldCompletion: (() -> Void)?
        watchdog.onShed = { completion in
            onShedCalls += 1
            heldCompletion = completion
        }
        let reported = expectation(description: "the first shed eventually reports")
        watchdog.onWarn = { _, _ in reported.fulfill() }

        watchdog.shed(reason: "the first shed")
        XCTAssertEqual(onShedCalls, 1)

        watchdog.shed(reason: "a second shed, while the first is still outstanding")
        XCTAssertEqual(onShedCalls, 1,
                       "shedding is not free; a second fan-out while the first is still compacting "
                       + "would double the work and measure the wrong episode")

        // Let the first one finish, so the test leaves nothing half-run behind.
        heldCompletion?()
        wait(for: [reported], timeout: 5)
    }

    // MARK: - 4. The completion and the timeout racing

    /// `finish` is idempotent, so a real completion and its timeout both firing is
    /// harmless. "Harmless" is observable: the operator is told once, and pressure
    /// relief — which stalls the allocator — runs once.
    func testTheShedFinishesExactlyOnceWhenTheCompletionAndTheTimeoutBothFire() {
        let watchdog = MemoryWatchdog()
        // Short enough that the timeout genuinely fires inside this test, so the
        // race is real rather than hypothetical.
        watchdog.shedCompletionTimeout = 0.05
        watchdog.footprint = { Self.beforeBytes }

        var reliefCount = 0
        watchdog.relievePressure = { reliefCount += 1 }

        var warnCount = 0
        let noSecondReport = expectation(description: "the timeout must not report a second time")
        noSecondReport.isInverted = true
        watchdog.onWarn = { _, _ in
            warnCount += 1
            if warnCount > 1 { noSecondReport.fulfill() }
        }

        // A well-behaved pane: it calls back promptly. The timeout is still armed.
        watchdog.onShed = { completion in completion() }

        watchdog.shed(reason: reason)
        XCTAssertEqual(warnCount, 1, "a completion that arrives reports straight away")
        XCTAssertEqual(reliefCount, 1)

        // Waits past shedCompletionTimeout, so the timeout has fired by the time
        // the assertions below run.
        wait(for: [noSecondReport], timeout: 0.5)

        XCTAssertEqual(warnCount, 1,
                       "the operator must be told once per shed, not once per code path that ended it")
        XCTAssertEqual(reliefCount, 1,
                       "a second malloc_zone_pressure_relief frees nothing and costs a stall")
    }

    // MARK: - 5. No listener attached

    /// `onShed` is wired up by `AppStore` as panes appear. Before that — or in a
    /// window with no transcript — a shed has nothing to ask for, but it must still
    /// hand pages back and still say what it saw. Silence here would be the app's
    /// last-resort defence quietly doing nothing.
    func testAShedWithNoListenerStillRelievesPressureAndReports() {
        let watchdog = MemoryWatchdog()
        watchdog.footprint = { Self.beforeBytes }

        var reliefCount = 0
        watchdog.relievePressure = { reliefCount += 1 }

        var titles: [String] = []
        watchdog.onWarn = { title, _ in titles.append(title) }

        // onShed deliberately left nil.
        watchdog.shed(reason: reason)

        XCTAssertEqual(reliefCount, 1)
        XCTAssertEqual(titles, ["Shed retained content"],
                       "a shed with nobody listening still reports what it measured")
    }
}

// MARK: - Logic-target seam

/// The logic test bundle cannot compile `TranscriptDiagnostics.swift`: its
/// `snapshot()` reaches `TranscriptLoadHarness.shared`, which reaches
/// `AppStore.shared` and the entire view layer behind it — the same reason
/// `LoadHarnessTargeting` exists as a separate, dependency-free file. But
/// `MemoryWatchdog`'s default `footprint` seam names
/// `TranscriptDiagnostics.physicalFootprint()`, so the bundle needs that symbol
/// to link. This supplies it, and nothing else.
///
/// It traps rather than returning a number. Every test above injects `footprint`,
/// and a watchdog test that forgot to must fail loudly here rather than quietly
/// grading the test runner's own resident memory — a shed measured against a real
/// process that nothing in the test freed would report before == after and pass
/// or fail for reasons unrelated to the code under test.
enum TranscriptDiagnostics {
    static func physicalFootprint() -> Int {
        preconditionFailure(
            "the logic test bundle has no real footprint source — inject MemoryWatchdog.footprint")
    }
}
