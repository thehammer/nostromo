// NostromoKit — SessionListRefresherTests.swift
//
// How often the Mac asks the daemon for a fresh `session_list` so the focus counters stay current:
//   * a session changing state asks soon, but a burst of changes costs ONE request (fixed 0.5 s window);
//   * becoming seen, reconnecting and re-activating the app ask NOW;
//   * while at least one window is visible a 30 s backstop asks regardless; with none visible, no timer
//     exists at all.
//
// The scheduler is a manual clock written below, so nothing here waits on real time.
//
// Mutations caught here:
//   (6) the debounce does not coalesce      -> testABurstOfStateChangesInTheWindowIsOneRequest,
//                                              testCallsInsideTheWindowAreAbsorbedAndDoNotExtendIt
//   (7) the backstop runs while no window   -> testNoTimerExistsUntilAWindowIsVisible,
//       is visible                             testTheBackstopStopsWhenTheLastWindowGoes,
//                                              testNothingIsRequestedAfterTheWindowsGoAway

import XCTest
@testable import NostromoKit

// MARK: - Test doubles

/// A clock you advance by hand. Records every timer asked for.
private final class ManualScheduler {
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

    /// Timers that can still fire.
    var active: [Timer] { timers.filter { $0.isActive } }

    lazy var schedule: SessionListRefresher.Schedule = { [unowned self] after, repeating, fire in
        let timer = Timer(after: after, repeating: repeating, due: self.now + after, fire: fire)
        self.timers.append(timer)
        return { timer.cancelled = true }
    }

    /// Moves the clock forward, firing due timers in order (a repeating one re-arms).
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

private final class FakeRequester: SessionListRequesting {
    private(set) var requests = 0
    func requestSessionList() { requests += 1 }
}

final class SessionListRefresherTests: XCTestCase {

    // MARK: - Rig

    private var scheduler: ManualScheduler!
    private var requester: FakeRequester!
    private var refresher: SessionListRefresher!

    override func setUp() {
        super.setUp()
        scheduler = ManualScheduler()
        requester = FakeRequester()
        refresher = SessionListRefresher(requester: requester, schedule: scheduler.schedule)
    }

    override func tearDown() {
        refresher = nil
        requester = nil
        scheduler = nil
        super.tearDown()
    }

    private var requests: Int { requester.requests }

    // MARK: - The published constants

    func testTheIntervalsAreHalfASecondAndThirtySeconds() {
        XCTAssertEqual(SessionListRefresher.debounceInterval, 0.5)
        XCTAssertEqual(SessionListRefresher.backstopInterval, 30)
    }

    func testAFreshRefresherAsksForNothingAndSchedulesNothing() {
        XCTAssertEqual(requests, 0)
        XCTAssertTrue(scheduler.active.isEmpty)
        scheduler.advance(by: 600)
        XCTAssertEqual(requests, 0)
    }

    // MARK: - State changes (debounced)

    func testAStateChangeAsksOnceHalfASecondLater() {
        refresher.noteSessionState(tag: "a", state: "mid_turn")
        XCTAssertEqual(requests, 0, "not immediately")
        scheduler.advance(by: 0.49)
        XCTAssertEqual(requests, 0, "not before the window closes")
        scheduler.advance(by: 0.02)
        XCTAssertEqual(requests, 1)
        scheduler.advance(by: 60)
        XCTAssertEqual(requests, 1, "and never again by itself")
    }

    func testTheDebounceWindowIsOneOneShotTimerOfTheDebounceInterval() throws {
        refresher.noteSessionState(tag: "a", state: "idle")
        let timer = try XCTUnwrap(scheduler.active.first)
        XCTAssertEqual(scheduler.active.count, 1)
        XCTAssertEqual(timer.after, SessionListRefresher.debounceInterval)
        XCTAssertFalse(timer.repeating)
    }

    func testABurstOfStateChangesInTheWindowIsOneRequest() {
        refresher.noteSessionState(tag: "a", state: "mid_turn")
        scheduler.advance(by: 0.1)
        refresher.noteSessionState(tag: "b", state: "idle")
        scheduler.advance(by: 0.1)
        refresher.noteSessionState(tag: "a", state: "idle")
        scheduler.advance(by: 0.1)
        refresher.noteSessionState(tag: "c", state: "crashed")
        scheduler.advance(by: 0.1)
        refresher.noteSessionState(tag: "b", state: "awaiting_permission")
        XCTAssertEqual(scheduler.active.count, 1, "one pending request however many changes")
        scheduler.advance(by: 0.5)
        XCTAssertEqual(requests, 1)
        scheduler.advance(by: 30)
        XCTAssertEqual(requests, 1)
    }

    func testCallsInsideTheWindowAreAbsorbedAndDoNotExtendIt() {
        refresher.requestSoon()
        scheduler.advance(by: 0.4)
        refresher.requestSoon()
        refresher.requestSoon()
        scheduler.advance(by: 0.1)
        XCTAssertEqual(requests, 1, "the window is fixed: it closed 0.5 s after the FIRST call")
        scheduler.advance(by: 5)
        XCTAssertEqual(requests, 1, "the absorbed calls do not leave a second request behind")
    }

    func testTwoBurstsASecondApartAreTwoRequests() {
        refresher.noteSessionState(tag: "a", state: "mid_turn")
        refresher.noteSessionState(tag: "b", state: "mid_turn")
        scheduler.advance(by: 1)
        XCTAssertEqual(requests, 1)

        refresher.noteSessionState(tag: "a", state: "idle")
        refresher.noteSessionState(tag: "b", state: "idle")
        scheduler.advance(by: 1)
        XCTAssertEqual(requests, 2)
    }

    func testAFreshWindowOpensAfterTheLastOneFired() {
        refresher.requestSoon()
        scheduler.advance(by: 0.5)
        XCTAssertEqual(requests, 1)
        refresher.requestSoon()
        XCTAssertEqual(scheduler.active.count, 1, "a new window")
        scheduler.advance(by: 0.49)
        XCTAssertEqual(requests, 1)
        scheduler.advance(by: 0.02)
        XCTAssertEqual(requests, 2)
    }

    func testTheSameStateAgainAsksForNothing() {
        refresher.noteSessionState(tag: "a", state: "idle")
        scheduler.advance(by: 1)
        XCTAssertEqual(requests, 1, "the first state seen for a tag is a change")

        for _ in 0 ..< 5 { refresher.noteSessionState(tag: "a", state: "idle") }
        XCTAssertTrue(scheduler.active.isEmpty, "the same state again opens no window")
        scheduler.advance(by: 10)
        XCTAssertEqual(requests, 1)
    }

    func testEachTagRemembersItsOwnLastState() {
        refresher.noteSessionState(tag: "a", state: "idle")
        refresher.noteSessionState(tag: "b", state: "idle")
        scheduler.advance(by: 1)
        XCTAssertEqual(requests, 1)

        refresher.noteSessionState(tag: "a", state: "idle")   // same for a
        scheduler.advance(by: 1)
        XCTAssertEqual(requests, 1)

        refresher.noteSessionState(tag: "b", state: "mid_turn")   // b changed
        scheduler.advance(by: 1)
        XCTAssertEqual(requests, 2)

        refresher.noteSessionState(tag: "a", state: "mid_turn")   // a changed to what b is: still a change for a
        scheduler.advance(by: 1)
        XCTAssertEqual(requests, 3)
    }

    func testGoingBackToAnEarlierStateIsAChange() {
        refresher.noteSessionState(tag: "a", state: "idle")
        scheduler.advance(by: 1)
        refresher.noteSessionState(tag: "a", state: "mid_turn")
        scheduler.advance(by: 1)
        refresher.noteSessionState(tag: "a", state: "idle")
        scheduler.advance(by: 1)
        XCTAssertEqual(requests, 3)
    }

    // MARK: - requestNow

    func testRequestNowAsksImmediately() {
        refresher.requestNow()
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(scheduler.active.isEmpty)
    }

    func testRequestNowCancelsAPendingWindowAndNeverAsksASecondTimeLater() {
        refresher.requestSoon()
        XCTAssertEqual(scheduler.active.count, 1)
        refresher.requestNow()
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(scheduler.active.isEmpty, "the pending window was cancelled")
        scheduler.advance(by: 10)
        XCTAssertEqual(requests, 1, "no second request from the cancelled window")
    }

    func testAWindowCanOpenAgainAfterRequestNow() {
        refresher.requestSoon()
        refresher.requestNow()
        refresher.requestSoon()
        scheduler.advance(by: 0.5)
        XCTAssertEqual(requests, 2)
    }

    // MARK: - The backstop

    func testNoTimerExistsUntilAWindowIsVisible() {
        XCTAssertTrue(scheduler.active.isEmpty)
        refresher.setWindowsVisible(false)
        XCTAssertTrue(scheduler.active.isEmpty, "false with nothing running starts nothing")
        scheduler.advance(by: 300)
        XCTAssertEqual(requests, 0, "no backstop while no window is visible")
    }

    func testAVisibleWindowStartsExactlyOneRepeatingThirtySecondTimer() throws {
        refresher.setWindowsVisible(true)
        XCTAssertEqual(scheduler.active.count, 1)
        let timer = try XCTUnwrap(scheduler.active.first)
        XCTAssertEqual(timer.after, SessionListRefresher.backstopInterval)
        XCTAssertTrue(timer.repeating)
        XCTAssertEqual(requests, 0, "starting the backstop does not itself ask")
    }

    func testSettingVisibleTwiceStillLeavesExactlyOneTimer() {
        refresher.setWindowsVisible(true)
        refresher.setWindowsVisible(true)
        XCTAssertEqual(scheduler.active.count, 1)
        scheduler.advance(by: 30)
        XCTAssertEqual(requests, 1, "one tick, not two")
        scheduler.advance(by: 30)
        XCTAssertEqual(requests, 2)
    }

    func testTheBackstopAsksEveryThirtySeconds() {
        refresher.setWindowsVisible(true)
        scheduler.advance(by: 29.9)
        XCTAssertEqual(requests, 0)
        scheduler.advance(by: 0.2)
        XCTAssertEqual(requests, 1)
        scheduler.advance(by: 30)
        XCTAssertEqual(requests, 2)
        scheduler.advance(by: 60)
        XCTAssertEqual(requests, 4)
    }

    func testTheBackstopStopsWhenTheLastWindowGoes() {
        refresher.setWindowsVisible(true)
        scheduler.advance(by: 30)
        XCTAssertEqual(requests, 1)
        refresher.setWindowsVisible(false)
        XCTAssertTrue(scheduler.active.isEmpty, "the timer is cancelled, not just ignored")
        scheduler.advance(by: 300)
        XCTAssertEqual(requests, 1)
    }

    func testNothingIsRequestedAfterTheWindowsGoAway() {
        refresher.setWindowsVisible(true)
        refresher.setWindowsVisible(false)
        scheduler.advance(by: 120)
        XCTAssertEqual(requests, 0)
    }

    func testTheBackstopCanStartAgainAfterBeingStopped() {
        refresher.setWindowsVisible(true)
        refresher.setWindowsVisible(false)
        refresher.setWindowsVisible(true)
        XCTAssertEqual(scheduler.active.count, 1)
        scheduler.advance(by: 30)
        XCTAssertEqual(requests, 1)
    }

    func testSettingNotVisibleTwiceIsHarmless() {
        refresher.setWindowsVisible(true)
        refresher.setWindowsVisible(false)
        refresher.setWindowsVisible(false)
        XCTAssertTrue(scheduler.active.isEmpty)
        scheduler.advance(by: 100)
        XCTAssertEqual(requests, 0)
    }

    func testTheBackstopAndTheDebounceAreIndependent() {
        refresher.setWindowsVisible(true)
        refresher.requestSoon()
        scheduler.advance(by: 0.5)
        XCTAssertEqual(requests, 1, "the debounce fired")
        scheduler.advance(by: 29.5)
        XCTAssertEqual(requests, 2, "and the backstop still ticks at 30 s")
    }

    // MARK: - Connection changes

    func testConnectingAsksImmediately() {
        refresher.connectionChanged(true)
        XCTAssertEqual(requests, 1)
    }

    func testConnectingCancelsAPendingWindowSoItIsOneRequestNotTwo() {
        refresher.requestSoon()
        refresher.connectionChanged(true)
        XCTAssertEqual(requests, 1)
        scheduler.advance(by: 10)
        XCTAssertEqual(requests, 1)
    }

    func testDisconnectingAsksForNothing() {
        refresher.connectionChanged(false)
        XCTAssertEqual(requests, 0)
        scheduler.advance(by: 10)
        XCTAssertEqual(requests, 0)
    }

    func testDisconnectingCancelsAPendingWindow() {
        refresher.requestSoon()
        refresher.connectionChanged(false)
        XCTAssertTrue(scheduler.active.isEmpty)
        scheduler.advance(by: 10)
        XCTAssertEqual(requests, 0, "nothing to ask while disconnected")
    }

    func testDisconnectingForgetsEveryTagsLastStateSoTheNextOneIsAChangeAgain() {
        refresher.noteSessionState(tag: "a", state: "idle")
        refresher.noteSessionState(tag: "b", state: "mid_turn")
        scheduler.advance(by: 1)
        XCTAssertEqual(requests, 1)

        refresher.connectionChanged(false)
        refresher.connectionChanged(true)
        XCTAssertEqual(requests, 2, "reconnecting asks at once")

        refresher.noteSessionState(tag: "a", state: "idle")
        scheduler.advance(by: 1)
        XCTAssertEqual(requests, 3, "a's remembered state was forgotten, so 'idle' is news again")

        refresher.noteSessionState(tag: "b", state: "mid_turn")
        scheduler.advance(by: 1)
        XCTAssertEqual(requests, 4, "and so is b's")
    }

    func testConnectingDoesNotForgetTheStates() {
        refresher.noteSessionState(tag: "a", state: "idle")
        scheduler.advance(by: 1)
        refresher.connectionChanged(true)
        XCTAssertEqual(requests, 2)
        refresher.noteSessionState(tag: "a", state: "idle")
        scheduler.advance(by: 1)
        XCTAssertEqual(requests, 2, "only a disconnect forgets")
    }

    func testDisconnectingDoesNotStopTheBackstopByItself() {
        // The windows are what the backstop follows; a dropped connection only makes its ticks no-ops
        // downstream. Pinning that the refresher does not guess about windows.
        refresher.setWindowsVisible(true)
        refresher.connectionChanged(false)
        XCTAssertEqual(scheduler.active.filter { $0.repeating }.count, 1)
    }

    // MARK: - Ownership

    func testTheRefresherDoesNotRetainItsRequester() {
        var strong: FakeRequester? = FakeRequester()
        weak var weakRequester = strong
        let local = SessionListRefresher(requester: strong!, schedule: scheduler.schedule)
        strong = nil
        XCTAssertNil(weakRequester, "the requester (the daemon client) outlives or dies independently of the refresher")

        // And a pending window or a tick with the requester gone is harmless.
        local.requestSoon()
        local.setWindowsVisible(true)
        scheduler.advance(by: 100)
        local.requestNow()
        local.connectionChanged(true)
        withExtendedLifetime(local) {}
    }
}
