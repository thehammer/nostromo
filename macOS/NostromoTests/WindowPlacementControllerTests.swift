import XCTest
import CoreGraphics

// WindowPlacementController.swift (+ PlacementMachine / DisplayIdentity) are
// compiled into this target directly. The controller is exercised against a fake
// window, fake screens and a manual scheduler: no NSWindow, no NSScreen, no wall
// clock, so the result does not depend on how many displays the machine has.

// MARK: - Fakes

private final class FakeWindow: PlacementWindowing {
    var currentDisplayUUID: String?
    var isFullScreen = false

    /// A sibling (or this window) is mid enter/exit transition.
    var transitionInFlight = false
    /// If set, the first N reads report "in flight" and then the transition drains.
    var inFlightReadsBeforeDraining: Int?
    var isAnyTransitionInFlight: Bool {
        if let n = inFlightReadsBeforeDraining {
            if n > 0 { inFlightReadsBeforeDraining = n - 1; return true }
            return false
        }
        return transitionInFlight
    }

    /// A display-configuration change is in progress on the window (mirrors `NostromoWindow`'s flag).
    var displayChangePending = false
    var isDisplayChangePending: Bool { displayChangePending }

    /// Every phase the controller mirrored onto the window, in order.
    private(set) var phasesSeen: [PlacementPhase] = []
    func placementPhaseChanged(_ phase: PlacementPhase) { phasesSeen.append(phase) }

    var placementSnapshot: String { "fake-window on \(currentDisplayUUID ?? "nil") fullScreen=\(isFullScreen)" }

    private(set) var placedOn: [DisplayInfo] = []
    private(set) var toggleCount = 0

    /// When true, `place(on:)` moves the window to that display (like a successful `setFrame`).
    var movesOnPlace = true

    init(on uuid: String?) { currentDisplayUUID = uuid }

    func place(on display: DisplayInfo) {
        placedOn.append(display)
        if movesOnPlace { currentDisplayUUID = display.uuid }
    }

    func toggleFullScreenNow() { toggleCount += 1 }
}

private final class FakeScreens: ScreenProviding {
    var displays: [DisplayInfo]
    var screensHaveSeparateSpaces = true
    init(_ displays: [DisplayInfo]) { self.displays = displays }
}

/// Records scheduled work; the test decides what fires and when.
private final class FakeScheduler: PlacementScheduler {
    private(set) var pending: [(delay: TimeInterval, work: () -> Void)] = []

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
        pending.append((delay, work))
    }

    /// Run the oldest pending item. Returns false if nothing was pending.
    @discardableResult
    func runNext() -> Bool {
        guard !pending.isEmpty else { return false }
        pending.removeFirst().work()
        return true
    }

    /// Run everything in FIFO order, including work queued while running. Bounded so a
    /// runaway loop fails the test instead of hanging it.
    func runAll(limit: Int = 200, file: StaticString = #filePath, line: UInt = #line) {
        var ran = 0
        while runNext() {
            ran += 1
            if ran >= limit {
                XCTFail("scheduler still has work after \(limit) steps — unbounded loop?", file: file, line: line)
                return
            }
        }
    }

    /// Remove (without running) every pending item armed with `delay`, oldest first.
    func take(delay: TimeInterval) -> [() -> Void] {
        let matching = pending.filter { $0.delay == delay }.map(\.work)
        pending.removeAll { $0.delay == delay }
        return matching
    }
}

private enum Topology {
    static let main = DisplayInfo(
        uuid: "UUID-MAIN", screenNumber: 1,
        frame: CGRect(x: 0, y: 0, width: 1710, height: 1107),
        visibleFrame: CGRect(x: 0, y: 0, width: 1710, height: 1073),
        localizedName: "Built-in", isMain: true)
    /// Stacked above main and to the left.
    static let aboveLeft = DisplayInfo(
        uuid: "UUID-ABOVE-LEFT", screenNumber: 2,
        frame: CGRect(x: -1920, y: 1107, width: 1920, height: 1080),
        visibleFrame: CGRect(x: -1920, y: 1107, width: 1920, height: 1055),
        localizedName: "External L")
    /// Stacked directly above main.
    static let aboveRight = DisplayInfo(
        uuid: "UUID-ABOVE-RIGHT", screenNumber: 3,
        frame: CGRect(x: 0, y: 1107, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 1107, width: 1920, height: 1055),
        localizedName: "External R")
    static var all: [DisplayInfo] { [main, aboveLeft, aboveRight] }
}

// MARK: - Tests

final class WindowPlacementControllerTests: XCTestCase {

    private var window: FakeWindow!
    private var screens: FakeScreens!
    private var scheduler: FakeScheduler!
    private var controller: WindowPlacementController!
    private var emitted: [(message: String, warning: Bool)] = []

    private let target = Topology.aboveLeft

    override func setUp() {
        super.setUp()
        emitted = []
        scheduler = FakeScheduler()
        screens = FakeScreens(Topology.all)
        // `pendingExits` is app-wide static state: never let one test's leftovers skew another's exit delays.
        WindowPlacementController.resetPendingExitsForTesting()
    }

    /// Exits are serialized through app-wide static state that is only balanced when the
    /// scheduled work runs, so every test drains its scheduler.
    override func tearDown() {
        scheduler?.runAll()
        controller = nil
        window = nil
        WindowPlacementController.resetPendingExitsForTesting()
        super.tearDown()
    }

    /// Build the controller bound to `target` with the window starting on `uuid`.
    private func makeController(windowOn uuid: String?, movesOnPlace: Bool = true) {
        window = FakeWindow(on: uuid)
        window.movesOnPlace = movesOnPlace
        controller = WindowPlacementController(
            window: window, targetUUID: target.uuid, screens: screens, scheduler: scheduler,
            emit: { [unowned self] message, warning in self.emitted.append((message, warning)) })
    }

    /// Drives: begin, full-screen entry, landing on `landing`. Leaves the window "in full-screen".
    private func enterFullScreen(landingOn landing: String) {
        controller.begin()
        scheduler.runAll()
        window.isFullScreen = true
        window.currentDisplayUUID = landing
        controller.windowEvent(.didEnterFullScreen)
    }

    /// Full-screen lands on the wrong display; the controller's deferred exit runs; AppKit
    /// reports the exit. Leaves the machine in `.enteringFullScreen` with the retry spent.
    private func landWrongAndExit() {
        enterFullScreen(landingOn: Topology.main.uuid)
        scheduler.runAll()                       // the deferred exit toggle fires
        window.isFullScreen = false
        window.currentDisplayUUID = Topology.main.uuid
        controller.windowEvent(.didExitFullScreen)
        scheduler.runAll()                       // the delayed re-placement (+ re-check) runs
    }

    /// Wrong landing; the deferred exit is armed but has NOT fired. Window is full-screen on main.
    private func landWrongWithExitArmed() {
        makeController(windowOn: target.uuid)
        enterFullScreen(landingOn: Topology.main.uuid)
        XCTAssertEqual(controller.phase, .exitingForRetry)
        XCTAssertEqual(window.toggleCount, 1)
    }

    /// Fire the one armed exit (and nothing else).
    private func fireExit(file: StaticString = #filePath, line: UInt = #line) {
        let works = scheduler.take(delay: WindowPlacementController.exitRunway)
        XCTAssertEqual(works.count, 1, "expected exactly one armed exit", file: file, line: line)
        for work in works { work() }
    }

    /// The exit toggled and AppKit reported it. The delayed re-placement is armed but has NOT fired.
    private func exitReportedByAppKit() {
        landWrongWithExitArmed()
        scheduler.runAll()                       // the deferred exit toggles
        XCTAssertEqual(window.toggleCount, 2)
        window.isFullScreen = false
        window.currentDisplayUUID = Topology.main.uuid
        controller.windowEvent(.didExitFullScreen)
    }

    /// Fire the armed post-exit re-placement (and nothing else).
    private func firePostExitPlace(file: StaticString = #filePath, line: UInt = #line) {
        let works = scheduler.take(delay: WindowPlacementController.postExitPlaceDelay)
        XCTAssertEqual(works.count, 1, "expected exactly one armed post-exit placement", file: file, line: line)
        for work in works { work() }
    }

    /// Run scheduled work one item at a time and report how many items ran; bounded.
    @discardableResult
    private func runCountingSteps() -> Int {
        var steps = 0
        while scheduler.runNext() {
            steps += 1
            if steps > 100 { XCTFail("scheduler never drained: unbounded polling?"); break }
        }
        return steps
    }

    // MARK: Already on the right display

    func test_a_window_already_on_the_target_enters_full_screen_without_being_moved() {
        makeController(windowOn: target.uuid)

        controller.begin()
        scheduler.runAll()

        XCTAssertEqual(window.placedOn, [])
        XCTAssertEqual(window.toggleCount, 1)
    }

    func test_full_screen_is_never_toggled_synchronously_inside_begin() {
        makeController(windowOn: target.uuid)

        controller.begin()

        XCTAssertEqual(window.toggleCount, 0, "the toggle must be deferred to a later turn, not run inline")
        scheduler.runAll()
        XCTAssertEqual(window.toggleCount, 1)
    }

    func test_a_window_that_is_already_full_screen_is_not_toggled_again() {
        makeController(windowOn: target.uuid)
        window.isFullScreen = true

        controller.begin()
        scheduler.runAll()

        XCTAssertEqual(window.toggleCount, 0, "toggling an already-full-screen window would EXIT it")
    }

    // MARK: Wrong display at begin

    func test_a_window_on_the_wrong_display_is_placed_on_the_target_display() {
        makeController(windowOn: Topology.main.uuid)

        controller.begin()

        XCTAssertEqual(window.placedOn, [target], "place must be handed the TARGET display's info")
        XCTAssertEqual(window.placedOn.first?.placementFrame, target.visibleFrame)
    }

    func test_placement_targets_a_display_stacked_above_main_by_uuid() {
        screens.displays = [Topology.main, Topology.aboveRight, Topology.aboveLeft]
        makeController(windowOn: Topology.main.uuid)

        controller.begin()

        XCTAssertEqual(window.placedOn.map(\.uuid), [target.uuid])
        XCTAssertGreaterThanOrEqual(window.placedOn.first?.placementFrame.minY ?? 0, Topology.main.frame.height)
    }

    func test_full_screen_is_not_toggled_until_the_window_reports_the_target_display() {
        makeController(windowOn: Topology.main.uuid, movesOnPlace: false)

        controller.begin()
        XCTAssertEqual(window.placedOn.count, 1)
        XCTAssertEqual(window.toggleCount, 0)

        // The synchronous re-check after placing: window still not there.
        scheduler.runNext()
        XCTAssertEqual(window.toggleCount, 0, "still on the wrong display: no toggle yet")

        // The window finally reports the target screen.
        window.currentDisplayUUID = target.uuid
        controller.windowEvent(.didChangeScreen)
        XCTAssertEqual(window.toggleCount, 0, "toggle is deferred, never inline in the event handler")

        scheduler.runAll()
        XCTAssertEqual(window.toggleCount, 1)
    }

    func test_a_window_that_lands_on_the_target_when_placed_enters_full_screen_after_the_next_turn() {
        makeController(windowOn: Topology.main.uuid, movesOnPlace: true)

        controller.begin()
        XCTAssertEqual(window.toggleCount, 0)

        scheduler.runAll()

        XCTAssertEqual(window.placedOn.count, 1, "no re-placement needed once the window is verified on the target")
        XCTAssertEqual(window.toggleCount, 1)
    }

    func test_a_window_that_never_moves_is_placed_at_most_three_times_then_full_screen_is_entered_anyway() {
        makeController(windowOn: Topology.main.uuid, movesOnPlace: false)

        controller.begin()
        scheduler.runAll()

        XCTAssertEqual(window.placedOn.count, 3)
        XCTAssertEqual(window.toggleCount, 1)
        XCTAssertTrue(emitted.contains { $0.warning && $0.message.hasPrefix("WARNING") },
                      "entering off-target must be surfaced as a warning in the placement log")
    }

    func test_the_bounded_placement_does_not_keep_scheduling_work_forever() {
        makeController(windowOn: Topology.main.uuid, movesOnPlace: false)

        controller.begin()
        scheduler.runAll() // fails the test itself if it can't drain

        XCTAssertTrue(scheduler.pending.isEmpty)
        // Further screen noise with nothing left to do must not toggle again.
        controller.windowEvent(.didChangeScreen)
        scheduler.runAll()
        XCTAssertEqual(window.toggleCount, 1)
    }

    // MARK: Target display absent

    func test_a_target_display_that_is_not_attached_means_no_placement_and_no_toggle() {
        screens.displays = [Topology.main, Topology.aboveRight] // target gone
        makeController(windowOn: Topology.main.uuid)

        controller.begin()
        scheduler.runAll()

        XCTAssertEqual(window.placedOn, [])
        XCTAssertEqual(window.toggleCount, 0)
        XCTAssertEqual(controller.phase, .gaveUp)
    }

    func test_a_target_display_that_is_not_attached_leaves_a_window_on_the_target_uuid_alone_too() {
        screens.displays = []
        makeController(windowOn: target.uuid)

        controller.begin()
        scheduler.runAll()

        XCTAssertEqual(window.placedOn, [])
        XCTAssertEqual(window.toggleCount, 0)
    }

    // MARK: Full-screen landed on the wrong display

    func test_entering_full_screen_on_the_right_display_finishes_without_further_action() {
        makeController(windowOn: target.uuid)

        enterFullScreen(landingOn: target.uuid)
        scheduler.runAll()

        XCTAssertEqual(controller.phase, .fullScreen)
        XCTAssertEqual(window.toggleCount, 1)
        XCTAssertEqual(window.placedOn, [])
    }

    func test_landing_on_the_wrong_display_exits_full_screen_once_by_toggling_but_never_inline() {
        makeController(windowOn: target.uuid)

        enterFullScreen(landingOn: Topology.main.uuid)

        XCTAssertEqual(window.toggleCount, 1, "only the enter toggle so far: the exit must not run inside the event handler")
        XCTAssertEqual(controller.phase, .exitingForRetry)

        scheduler.runAll()

        XCTAssertEqual(window.toggleCount, 2, "one toggle to enter, one deferred toggle to exit for the retry")
    }

    func test_the_exit_is_scheduled_after_at_least_the_exit_runway() {
        makeController(windowOn: target.uuid)
        controller.begin()
        scheduler.runAll()
        let before = scheduler.pending.count
        XCTAssertEqual(before, 0)

        window.isFullScreen = true
        window.currentDisplayUUID = Topology.main.uuid
        controller.windowEvent(.didEnterFullScreen)

        let exitDelays = scheduler.pending.map(\.delay).filter { $0 >= WindowPlacementController.exitRunway }
        XCTAssertEqual(exitDelays.count, 1)
        XCTAssertGreaterThanOrEqual(exitDelays.first ?? 0, WindowPlacementController.exitRunway)
    }

    func test_after_exiting_for_a_retry_the_controller_re_places_but_never_re_enters_itself() {
        makeController(windowOn: target.uuid)
        enterFullScreen(landingOn: Topology.main.uuid)
        scheduler.runAll()
        XCTAssertEqual(window.toggleCount, 2)

        window.isFullScreen = false
        window.currentDisplayUUID = Topology.main.uuid
        controller.windowEvent(.didExitFullScreen)
        scheduler.runAll()

        XCTAssertEqual(window.placedOn.map(\.uuid), [target.uuid], "re-placed on the target display")
        XCTAssertEqual(window.toggleCount, 2,
                       "re-entry belongs to NostromoWindow's own delayed re-entry, not the controller")
    }

    func test_a_successful_retry_ends_in_full_screen_on_the_target() {
        makeController(windowOn: target.uuid)
        landWrongAndExit()

        // NostromoWindow's own re-entry lands correctly this time.
        window.isFullScreen = true
        window.currentDisplayUUID = target.uuid
        controller.windowEvent(.didEnterFullScreen)
        scheduler.runAll()

        XCTAssertEqual(controller.phase, .fullScreen)
        XCTAssertEqual(window.toggleCount, 2)
    }

    func test_a_second_wrong_landing_gives_up_without_another_exit_or_placement() {
        makeController(windowOn: target.uuid)
        landWrongAndExit()
        let toggles = window.toggleCount
        let placements = window.placedOn.count

        // The window's own re-entry lands on the wrong display again.
        window.isFullScreen = true
        window.currentDisplayUUID = Topology.main.uuid
        controller.windowEvent(.didEnterFullScreen)
        scheduler.runAll()

        XCTAssertEqual(controller.phase, .gaveUp)
        XCTAssertEqual(window.toggleCount, toggles, "no loop: no further exit toggle")
        XCTAssertEqual(window.placedOn.count, placements, "no loop: no further placement")
        XCTAssertTrue(emitted.contains { $0.warning && $0.message.contains("giving up") })
    }

    func test_the_deferred_exit_is_skipped_if_the_window_already_left_full_screen_by_itself() {
        makeController(windowOn: target.uuid)
        enterFullScreen(landingOn: Topology.main.uuid)   // exit scheduled, not yet run
        XCTAssertEqual(window.toggleCount, 1)

        // AppKit (user, system) exits before our deferred exit fires.
        window.isFullScreen = false
        controller.windowEvent(.didExitFullScreen)
        scheduler.runAll()

        XCTAssertEqual(window.toggleCount, 1, "toggling now would ENTER full-screen: the stale exit must do nothing")
        XCTAssertEqual(window.placedOn.map(\.uuid), [target.uuid])
    }

    func test_the_deferred_exit_waits_for_in_flight_transitions_to_drain_then_toggles() {
        makeController(windowOn: target.uuid)
        enterFullScreen(landingOn: Topology.main.uuid)
        XCTAssertEqual(window.toggleCount, 1)

        window.inFlightReadsBeforeDraining = 3   // a sibling's transition ends a little later
        scheduler.runAll()

        XCTAssertEqual(window.toggleCount, 2, "exit runs once the transition has drained")
        XCTAssertEqual(controller.phase, .exitingForRetry)
    }

    func test_the_deferred_exit_never_toggles_into_a_transition_that_never_drains_and_gives_up() {
        makeController(windowOn: target.uuid)
        enterFullScreen(landingOn: Topology.main.uuid)
        XCTAssertEqual(window.toggleCount, 1)

        window.transitionInFlight = true
        scheduler.runAll()   // also fails the test if the polling is unbounded

        XCTAssertEqual(window.toggleCount, 1, "must not toggle on top of an in-flight transition")
        XCTAssertEqual(controller.phase, .gaveUp)
        XCTAssertTrue(emitted.contains { $0.warning && $0.message.contains("giving up") })
    }

    func test_when_the_window_is_not_actually_full_screen_the_exit_advances_by_itself() {
        makeController(windowOn: target.uuid)
        controller.begin()
        scheduler.runAll()
        XCTAssertEqual(window.toggleCount, 1)

        // AppKit reports a wrong-display entry but the window is not in full-screen,
        // so there is nothing to exit and no didExitFullScreen will ever arrive.
        window.isFullScreen = false
        window.currentDisplayUUID = Topology.main.uuid
        controller.windowEvent(.didEnterFullScreen)
        scheduler.runAll()

        XCTAssertEqual(window.toggleCount, 1, "must not toggle a non-full-screen window (that would ENTER)")
        XCTAssertEqual(window.placedOn.map(\.uuid), [target.uuid], "re-placement still happens")
        XCTAssertNotEqual(controller.phase, .exitingForRetry, "must not stay stuck waiting for an exit that cannot come")
    }

    func test_a_failed_full_screen_entry_is_left_to_the_window_and_not_retried_by_the_controller() {
        makeController(windowOn: target.uuid)
        controller.begin()
        scheduler.runAll()
        XCTAssertEqual(window.toggleCount, 1)

        controller.windowEvent(.didFailToEnterFullScreen)
        scheduler.runAll()

        XCTAssertEqual(window.toggleCount, 1)
        XCTAssertEqual(controller.phase, .enteringFullScreen)

        // The window's own retry later succeeds on the target and is still verified.
        window.isFullScreen = true
        controller.windowEvent(.didEnterFullScreen)
        XCTAssertEqual(controller.phase, .fullScreen)
    }

    // MARK: Display reconfiguration

    func test_a_reconfiguration_that_pushes_the_full_screen_window_off_the_target_re_homes_it_without_toggling_inline() {
        makeController(windowOn: target.uuid)
        enterFullScreen(landingOn: target.uuid)
        scheduler.runAll()
        XCTAssertEqual(window.toggleCount, 1)

        window.currentDisplayUUID = Topology.main.uuid
        controller.displaysReconfigured()

        XCTAssertEqual(window.toggleCount, 1, "never toggle from inside the screen-parameters handler")
        XCTAssertEqual(controller.phase, .exitingForRetry)

        scheduler.runAll()

        XCTAssertEqual(window.toggleCount, 2, "deferred exit to re-home")
    }

    func test_a_reconfiguration_with_the_target_display_gone_does_not_try_to_re_home() {
        makeController(windowOn: target.uuid)
        enterFullScreen(landingOn: target.uuid)
        scheduler.runAll()

        screens.displays = [Topology.main, Topology.aboveRight] // target unplugged
        window.currentDisplayUUID = Topology.main.uuid
        controller.displaysReconfigured()
        scheduler.runAll()

        XCTAssertEqual(window.toggleCount, 1, "no exit toggle")
        XCTAssertEqual(window.placedOn, [], "no placement onto a display that is not there")
    }

    func test_a_reconfiguration_that_leaves_the_window_on_the_target_changes_nothing() {
        makeController(windowOn: target.uuid)
        enterFullScreen(landingOn: target.uuid)
        scheduler.runAll()

        controller.displaysReconfigured()
        scheduler.runAll()

        XCTAssertEqual(window.toggleCount, 1)
        XCTAssertEqual(controller.phase, .fullScreen)
    }

    // MARK: Re-home grace expiry

    /// Reaches full-screen on the target with the single wrong-display retry already
    /// spent, so only a `displaysReconfigured` grant can authorise another re-home.
    private func reachFullScreenWithRetrySpent() {
        makeController(windowOn: target.uuid)
        landWrongAndExit()                               // wrong display -> exit (retry spent) -> re-place
        window.isFullScreen = true
        window.currentDisplayUUID = target.uuid
        controller.windowEvent(.didEnterFullScreen)      // lands correctly
        scheduler.runAll()
        XCTAssertEqual(controller.phase, .fullScreen)
    }

    func test_drift_without_any_reconfiguration_is_not_fought_once_the_retry_is_spent() {
        reachFullScreenWithRetrySpent()
        let toggles = window.toggleCount

        window.currentDisplayUUID = Topology.main.uuid
        controller.windowEvent(.didChangeScreen)
        scheduler.runAll()

        XCTAssertEqual(window.toggleCount, toggles)
    }

    func test_a_drift_inside_the_grace_period_after_a_reconfiguration_is_re_homed() {
        reachFullScreenWithRetrySpent()
        let toggles = window.toggleCount

        controller.displaysReconfigured() // window still on target: only grants the retry
        window.currentDisplayUUID = Topology.main.uuid
        controller.windowEvent(.didChangeScreen)

        XCTAssertEqual(controller.phase, .exitingForRetry)
        scheduler.runAll()
        XCTAssertEqual(window.toggleCount, toggles + 1)
    }

    func test_a_drift_after_the_grace_period_expired_is_not_fought() {
        reachFullScreenWithRetrySpent()
        let toggles = window.toggleCount

        controller.displaysReconfigured()
        for expire in scheduler.take(delay: WindowPlacementController.rehomeGrace) { expire() }

        window.currentDisplayUUID = Topology.main.uuid
        controller.windowEvent(.didChangeScreen)
        scheduler.runAll()

        XCTAssertEqual(window.toggleCount, toggles, "a user-driven move after the grace must be left alone")
        XCTAssertNotEqual(controller.phase, .exitingForRetry)
    }

    func test_only_the_latest_reconfigurations_expiry_ends_the_grace() {
        reachFullScreenWithRetrySpent()
        let toggles = window.toggleCount

        controller.displaysReconfigured()   // grace #1
        controller.displaysReconfigured()   // grace #2 supersedes #1
        let expiries = scheduler.take(delay: WindowPlacementController.rehomeGrace)
        XCTAssertEqual(expiries.count, 2)

        expiries[0]()                       // the superseded timer fires: must be a no-op

        window.currentDisplayUUID = Topology.main.uuid
        controller.windowEvent(.didChangeScreen)
        XCTAssertEqual(controller.phase, .exitingForRetry, "grace #2 is still open, so the drift is re-homed")
        scheduler.runAll()
        XCTAssertEqual(window.toggleCount, toggles + 1)
    }

    func test_the_latest_reconfigurations_expiry_does_end_the_grace() {
        reachFullScreenWithRetrySpent()
        let toggles = window.toggleCount

        controller.displaysReconfigured()
        controller.displaysReconfigured()
        let expiries = scheduler.take(delay: WindowPlacementController.rehomeGrace)
        expiries[0]()
        expiries[1]()

        window.currentDisplayUUID = Topology.main.uuid
        controller.windowEvent(.didChangeScreen)
        scheduler.runAll()

        XCTAssertEqual(window.toggleCount, toggles)
    }

    // MARK: First enter is gated on in-flight transitions

    func test_the_first_enter_toggle_waits_for_an_in_flight_transition_to_drain() {
        makeController(windowOn: target.uuid)
        window.transitionInFlight = true

        controller.begin()
        scheduler.runNext()
        scheduler.runNext()
        XCTAssertEqual(window.toggleCount, 0, "a sibling is mid-transition: do not toggle on top of it")

        window.transitionInFlight = false
        scheduler.runAll()

        XCTAssertEqual(window.toggleCount, 1)
        XCTAssertFalse(emitted.contains { $0.message.hasPrefix("WARNING") }, "no warning when the wait succeeded")
    }

    func test_the_first_enter_toggle_goes_ahead_with_a_warning_if_transitions_never_drain() {
        makeController(windowOn: target.uuid)
        window.transitionInFlight = true

        controller.begin()
        scheduler.runAll()   // fails the test itself if the polling is unbounded

        XCTAssertEqual(window.toggleCount, 1, "launch must still enter full-screen after the bounded wait")
        XCTAssertTrue(emitted.contains { $0.warning && $0.message.hasPrefix("WARNING") })
    }

    // MARK: Exit initiated by AppKit / the system

    func test_a_system_initiated_exit_is_not_fought_even_if_the_window_drifts_during_it() {
        makeController(windowOn: target.uuid)
        enterFullScreen(landingOn: target.uuid)
        scheduler.runAll()
        XCTAssertEqual(controller.phase, .fullScreen)

        controller.windowEvent(.willExitFullScreen)
        XCTAssertEqual(controller.phase, .enteringFullScreen)

        // The exit animation moves the window and the topology notification fires.
        window.currentDisplayUUID = Topology.main.uuid
        controller.windowEvent(.didChangeScreen)
        controller.displaysReconfigured()
        scheduler.runAll()

        XCTAssertEqual(window.toggleCount, 1, "no exit or enter toggle on top of the in-flight exit")
        XCTAssertEqual(window.placedOn, [])

        // The window's own re-entry then lands on the target and is verified.
        window.isFullScreen = true
        window.currentDisplayUUID = target.uuid
        controller.windowEvent(.didEnterFullScreen)
        XCTAssertEqual(controller.phase, .fullScreen)
    }

    // MARK: Lifetime cap

    func test_repeated_reconfigurations_can_never_cause_more_than_three_exits() {
        makeController(windowOn: target.uuid)
        enterFullScreen(landingOn: target.uuid)
        scheduler.runAll()
        let enterToggles = window.toggleCount
        XCTAssertEqual(enterToggles, 1)

        for _ in 0..<8 {
            let before = window.toggleCount
            window.currentDisplayUUID = Topology.main.uuid
            controller.displaysReconfigured()          // re-arms the retry budget each time
            scheduler.runAll()
            guard window.toggleCount > before else { break }

            // The exit happened: AppKit reports it, the controller re-places, the window re-enters.
            window.isFullScreen = false
            controller.windowEvent(.didExitFullScreen)
            scheduler.runAll()
            window.isFullScreen = true
            window.currentDisplayUUID = target.uuid
            controller.windowEvent(.didEnterFullScreen)
            scheduler.runAll()
        }

        XCTAssertEqual(window.toggleCount - enterToggles, PlacementMachine.maxLifetimeRetries)
        XCTAssertEqual(controller.phase, .gaveUp)
    }

    // MARK: Serialization across windows

    func test_two_windows_that_drift_together_schedule_their_exits_apart_and_neither_toggles_inline() {
        // Window A is the fixture's; window B is a second controller sharing the scheduler and screens.
        makeController(windowOn: target.uuid)
        let windowB = FakeWindow(on: target.uuid)
        let controllerB = WindowPlacementController(
            window: windowB, targetUUID: target.uuid, screens: screens, scheduler: scheduler,
            emit: { _, _ in })

        enterFullScreen(landingOn: target.uuid)
        controllerB.begin()
        scheduler.runAll()
        windowB.isFullScreen = true
        controllerB.windowEvent(.didEnterFullScreen)
        scheduler.runAll()
        XCTAssertEqual(controller.phase, .fullScreen)
        XCTAssertEqual(controllerB.phase, .fullScreen)
        let (togglesA, togglesB) = (window.toggleCount, windowB.toggleCount)
        XCTAssertTrue(scheduler.pending.isEmpty)

        // A display change pushes both windows off the target at once.
        window.currentDisplayUUID = Topology.main.uuid
        windowB.currentDisplayUUID = Topology.main.uuid
        controller.displaysReconfigured()
        controllerB.displaysReconfigured()

        XCTAssertEqual(window.toggleCount, togglesA, "no inline toggle from displaysReconfigured")
        XCTAssertEqual(windowB.toggleCount, togglesB, "no inline toggle from displaysReconfigured")

        let exitDelays = scheduler.pending.map(\.delay)
            .filter { $0 >= WindowPlacementController.exitRunway && $0 < WindowPlacementController.rehomeGrace }
        XCTAssertEqual(exitDelays.count, 2)
        XCTAssertEqual(Set(exitDelays).count, 2, "two exits must never be armed for the same delay")
        let gap = abs((exitDelays.first ?? 0) - (exitDelays.last ?? 0))
        XCTAssertGreaterThanOrEqual(gap, WindowPlacementController.exitSpacing)

        scheduler.runAll()
        XCTAssertEqual(window.toggleCount, togglesA + 1)
        XCTAssertEqual(windowB.toggleCount, togglesB + 1)
    }

    // MARK: B1: the exit is re-verified when it fires

    func test_an_exit_is_dropped_when_the_window_is_back_on_the_target_by_the_time_it_fires() {
        landWrongWithExitArmed()
        window.currentDisplayUUID = target.uuid     // macOS settled it back on its own

        fireExit()
        scheduler.runAll()

        XCTAssertEqual(window.toggleCount, 1, "the stale exit must not toggle")
        XCTAssertEqual(controller.phase, .fullScreen)
        XCTAssertEqual(controller.machine.retryBudget, PlacementMachine.maxFullScreenRetries, "the unused retry is refunded")
        XCTAssertEqual(controller.machine.retriesUsed, 0)
    }

    func test_an_exit_is_dropped_when_the_target_display_was_removed_before_it_fires() {
        landWrongWithExitArmed()
        screens.displays = [Topology.main, Topology.aboveRight]   // target unplugged

        fireExit()
        scheduler.runAll()

        XCTAssertEqual(window.toggleCount, 1)
        XCTAssertEqual(window.placedOn, [])
        XCTAssertEqual(controller.phase, .fullScreen)
    }

    func test_an_exit_never_fires_while_a_display_change_stays_pending_and_the_polling_is_bounded() {
        landWrongWithExitArmed()
        window.displayChangePending = true

        scheduler.runAll()   // also fails the test itself if the polling is unbounded

        XCTAssertEqual(window.toggleCount, 1, "no exit toggle while a display change is in progress")
        XCTAssertEqual(controller.phase, .fullScreen, "after the polls run out the exit is dropped")
        XCTAssertTrue(scheduler.pending.isEmpty)
    }

    func test_an_exit_held_back_by_a_pending_display_change_fires_once_if_the_change_clears_in_time() {
        landWrongWithExitArmed()
        window.displayChangePending = true

        fireExit()
        XCTAssertEqual(window.toggleCount, 1)
        XCTAssertEqual(controller.phase, .exitingForRetry, "re-armed, not dropped, while polls remain")
        XCTAssertTrue(scheduler.pending.map(\.delay).contains(WindowPlacementController.gatePollInterval))

        window.displayChangePending = false
        scheduler.runAll()

        XCTAssertEqual(window.toggleCount, 2, "exactly one exit toggle once the change cleared")
    }

    func test_an_exit_is_re_armed_not_toggled_when_a_screen_change_landed_just_before_it_fires() {
        makeController(windowOn: target.uuid)
        enterFullScreen(landingOn: target.uuid)
        scheduler.runAll()
        let base = window.toggleCount

        window.currentDisplayUUID = Topology.main.uuid
        controller.displaysReconfigured()                      // drift: exit armed, settle window opens
        XCTAssertEqual(controller.phase, .exitingForRetry)
        for clear in scheduler.take(delay: WindowPlacementController.screenChangeSettleInterval) { clear() }

        controller.displaysReconfigured()                      // another change right before the exit fires
        fireExit()

        XCTAssertEqual(window.toggleCount, base, "still settling: the exit must be re-armed, not toggled")
        XCTAssertEqual(controller.phase, .exitingForRetry)

        for clear in scheduler.take(delay: WindowPlacementController.screenChangeSettleInterval) { clear() }
        scheduler.runAll()

        XCTAssertEqual(window.toggleCount, base + 1, "fires exactly once after the settle window cleared")
    }

    func test_only_the_latest_screen_change_settle_clear_ends_the_settling() {
        makeController(windowOn: target.uuid)
        enterFullScreen(landingOn: target.uuid)
        scheduler.runAll()
        let base = window.toggleCount

        window.currentDisplayUUID = Topology.main.uuid
        controller.displaysReconfigured()
        controller.displaysReconfigured()
        let clears = scheduler.take(delay: WindowPlacementController.screenChangeSettleInterval)
        XCTAssertEqual(clears.count, 2)

        clears[0]()                                            // superseded: must not end the settling
        fireExit()
        XCTAssertEqual(window.toggleCount, base, "the superseded clear must not release the exit")

        clears[1]()                                            // the latest one does
        scheduler.runAll()
        XCTAssertEqual(window.toggleCount, base + 1)
    }

    func test_a_still_drifted_window_with_nothing_pending_exits_exactly_once() {
        landWrongWithExitArmed()

        fireExit()
        scheduler.runAll()

        XCTAssertEqual(window.toggleCount, 2)
        XCTAssertEqual(controller.phase, .exitingForRetry)
    }

    func test_a_dropped_exit_does_not_toggle_however_often_it_is_called() {
        landWrongWithExitArmed()
        window.currentDisplayUUID = target.uuid
        let works = scheduler.take(delay: WindowPlacementController.exitRunway)
        XCTAssertEqual(works.count, 1)

        works[0]()
        works[0]()
        window.currentDisplayUUID = Topology.main.uuid          // even if it drifts again afterwards
        works[0]()

        XCTAssertEqual(window.toggleCount, 1)
        XCTAssertEqual(controller.phase, .fullScreen)
    }

    func test_a_window_already_back_on_the_target_drops_the_exit_even_with_a_display_change_pending() {
        landWrongWithExitArmed()
        window.currentDisplayUUID = target.uuid
        window.displayChangePending = true

        fireExit()

        XCTAssertEqual(window.toggleCount, 1)
        XCTAssertEqual(controller.phase, .fullScreen, "dropped at once, not re-armed")
    }

    // MARK: B2: re-placement after an exit is delayed, never inside the didExit callback

    func test_the_re_placement_after_an_exit_does_not_happen_inside_the_did_exit_callback() {
        exitReportedByAppKit()

        XCTAssertEqual(window.placedOn, [], "no frame work synchronously inside windowDidExitFullScreen")
        XCTAssertEqual(window.toggleCount, 2)
        XCTAssertEqual(controller.phase, .enteringFullScreen)
        XCTAssertEqual(scheduler.pending.map(\.delay).filter { $0 == WindowPlacementController.postExitPlaceDelay }.count, 1)

        firePostExitPlace()

        XCTAssertEqual(window.placedOn.map(\.uuid), [target.uuid])
        XCTAssertEqual(window.toggleCount, 2, "the controller never re-enters itself")
    }

    func test_the_delayed_re_placement_is_skipped_if_the_window_is_full_screen_again() {
        exitReportedByAppKit()
        window.isFullScreen = true

        firePostExitPlace()
        scheduler.runAll()

        XCTAssertEqual(window.placedOn, [])
        XCTAssertEqual(window.toggleCount, 2)
    }

    func test_the_delayed_re_placement_is_skipped_if_the_target_display_is_gone() {
        exitReportedByAppKit()
        screens.displays = [Topology.main, Topology.aboveRight]

        firePostExitPlace()
        scheduler.runAll()

        XCTAssertEqual(window.placedOn, [])
        XCTAssertEqual(window.toggleCount, 2)
    }

    func test_the_delayed_re_placement_makes_no_place_call_if_the_window_is_already_on_the_target() {
        exitReportedByAppKit()
        window.currentDisplayUUID = target.uuid

        firePostExitPlace()
        scheduler.runAll()

        XCTAssertEqual(window.placedOn, [], "already there: nothing to place")
        XCTAssertEqual(window.toggleCount, 2)
    }

    func test_the_delayed_re_placement_waits_for_an_in_flight_transition_and_then_places_once() {
        exitReportedByAppKit()
        window.transitionInFlight = true

        firePostExitPlace()
        XCTAssertEqual(window.placedOn, [], "a transition is in flight: do not touch the frame")
        XCTAssertTrue(scheduler.pending.map(\.delay).contains(WindowPlacementController.gatePollInterval))

        window.transitionInFlight = false
        scheduler.runAll()

        XCTAssertEqual(window.placedOn.map(\.uuid), [target.uuid], "placed exactly once")
        XCTAssertEqual(window.toggleCount, 2)
    }

    func test_the_delayed_re_placement_waits_for_a_pending_display_change_and_then_places_once() {
        exitReportedByAppKit()
        window.displayChangePending = true

        firePostExitPlace()
        XCTAssertEqual(window.placedOn, [])

        window.displayChangePending = false
        scheduler.runAll()

        XCTAssertEqual(window.placedOn.map(\.uuid), [target.uuid])
        XCTAssertEqual(window.toggleCount, 2)
    }

    func test_the_delayed_re_placement_waits_for_a_screen_change_to_settle_and_then_places_once() {
        exitReportedByAppKit()
        controller.displaysReconfigured()          // display topology just changed

        firePostExitPlace()
        XCTAssertEqual(window.placedOn, [], "settling: do not place yet")

        for clear in scheduler.take(delay: WindowPlacementController.screenChangeSettleInterval) { clear() }
        scheduler.runAll()

        XCTAssertEqual(window.placedOn.map(\.uuid), [target.uuid])
        XCTAssertEqual(window.toggleCount, 2)
    }

    func test_the_delayed_re_placement_gives_up_after_its_bounded_polls_without_ever_toggling() {
        exitReportedByAppKit()
        window.transitionInFlight = true            // never drains

        firePostExitPlace()
        let repolls = runCountingSteps()

        XCTAssertGreaterThanOrEqual(repolls, 1)
        XCTAssertLessThanOrEqual(repolls, WindowPlacementController.postExitPlaceMaxPolls)
        XCTAssertEqual(window.placedOn, [], "skipped, not forced")
        XCTAssertEqual(window.toggleCount, 2)
    }

    func test_when_the_delayed_re_placement_gave_up_the_windows_own_re_entry_verifies_before_toggling() {
        exitReportedByAppKit()
        window.transitionInFlight = true
        firePostExitPlace()
        runCountingSteps()
        XCTAssertEqual(window.placedOn, [])

        // NostromoWindow is about to re-enter on its own.
        window.transitionInFlight = false
        controller.windowEvent(.willReenterFullScreen)

        XCTAssertEqual(window.placedOn.map(\.uuid), [target.uuid])
        XCTAssertEqual(window.toggleCount, 2, "the controller places; the window toggles")
    }

    func test_the_post_exit_placement_window_closes_before_the_windows_own_re_entry() {
        XCTAssertLessThan(
            WindowPlacementController.postExitPlaceDelay
                + WindowPlacementController.gatePollInterval * Double(WindowPlacementController.postExitPlaceMaxPolls),
            NostromoWindow.reentryDelay,
            "all post-exit placement work must be over before NostromoWindow re-enters")
    }

    // MARK: B2: willReenterFullScreen verify-before-toggle

    /// Retry path finished its placement; NostromoWindow's own re-entry is about to run.
    private func awaitingOwnReentry() {
        exitReportedByAppKit()
        scheduler.runAll()                          // delayed re-placement runs
        XCTAssertEqual(window.placedOn.count, 1)
        XCTAssertEqual(window.currentDisplayUUID, target.uuid)
    }

    func test_before_the_windows_own_re_entry_a_window_that_slipped_off_the_target_is_placed_again() {
        awaitingOwnReentry()
        window.currentDisplayUUID = Topology.main.uuid     // slipped off after the placement

        controller.windowEvent(.willReenterFullScreen)

        XCTAssertEqual(window.placedOn.count, 2)
        XCTAssertEqual(window.placedOn.last?.uuid, target.uuid, "placed synchronously, before the toggle")
        XCTAssertEqual(window.toggleCount, 2, "the controller never toggles from this event")
    }

    func test_before_the_windows_own_re_entry_a_window_already_on_the_target_is_left_alone() {
        awaitingOwnReentry()

        controller.windowEvent(.willReenterFullScreen)

        XCTAssertEqual(window.placedOn.count, 1)
        XCTAssertEqual(window.toggleCount, 2)
    }

    func test_before_the_windows_own_re_entry_nothing_is_placed_if_the_target_display_is_gone() {
        awaitingOwnReentry()
        window.currentDisplayUUID = Topology.main.uuid
        screens.displays = [Topology.main, Topology.aboveRight]

        controller.windowEvent(.willReenterFullScreen)

        XCTAssertEqual(window.placedOn.count, 1)
        XCTAssertEqual(window.toggleCount, 2)
    }

    func test_before_the_windows_own_re_entry_nothing_is_placed_if_the_window_is_already_full_screen() {
        awaitingOwnReentry()
        window.currentDisplayUUID = Topology.main.uuid
        window.isFullScreen = true

        controller.windowEvent(.willReenterFullScreen)

        XCTAssertEqual(window.placedOn.count, 1)
        XCTAssertEqual(window.toggleCount, 2)
    }

    func test_before_the_windows_own_re_entry_nothing_is_placed_while_a_transition_is_in_flight() {
        awaitingOwnReentry()
        window.currentDisplayUUID = Topology.main.uuid
        window.transitionInFlight = true

        controller.windowEvent(.willReenterFullScreen)

        XCTAssertEqual(window.placedOn.count, 1, "no setFrame on top of a transition")
        XCTAssertEqual(window.toggleCount, 2)
    }

    func test_before_the_windows_own_re_entry_nothing_is_placed_while_a_display_change_is_pending() {
        awaitingOwnReentry()
        window.currentDisplayUUID = Topology.main.uuid
        window.displayChangePending = true

        controller.windowEvent(.willReenterFullScreen)

        XCTAssertEqual(window.placedOn.count, 1)
        XCTAssertEqual(window.toggleCount, 2)
    }

    func test_before_the_windows_own_re_entry_nothing_is_placed_while_a_screen_change_is_settling() {
        awaitingOwnReentry()
        window.currentDisplayUUID = Topology.main.uuid
        controller.displaysReconfigured()                  // arms the settle window
        let placements = window.placedOn.count

        controller.windowEvent(.willReenterFullScreen)

        XCTAssertEqual(window.placedOn.count, placements, "settling: no setFrame")
        XCTAssertEqual(window.toggleCount, 2)
    }

    func test_before_the_windows_own_re_entry_the_place_resumes_once_nothing_is_in_progress() {
        awaitingOwnReentry()
        window.currentDisplayUUID = Topology.main.uuid
        window.transitionInFlight = true
        controller.windowEvent(.willReenterFullScreen)
        XCTAssertEqual(window.placedOn.count, 1)

        window.transitionInFlight = false
        controller.windowEvent(.willReenterFullScreen)

        XCTAssertEqual(window.placedOn.count, 2)
        XCTAssertEqual(window.toggleCount, 2, "never toggles")
    }

    // MARK: A real exit that is still mid-transition is not double-handled

    func test_the_deferred_exit_does_not_synthesise_a_did_exit_while_the_real_exit_is_still_in_flight() {
        makeController(windowOn: target.uuid)
        enterFullScreen(landingOn: Topology.main.uuid)     // exit armed
        // AppKit's own exit has begun: the style mask is already clear, the transition not over.
        window.isFullScreen = false
        window.transitionInFlight = true
        scheduler.runAll()                                 // polling is bounded

        XCTAssertEqual(window.toggleCount, 1)
        XCTAssertEqual(window.placedOn.count, 0, "no post-exit placement was scheduled by a synthetic didExit")
        XCTAssertNotEqual(controller.phase, .enteringFullScreen)
    }

    func test_a_real_exit_that_finishes_while_the_deferred_exit_is_waiting_is_handled_exactly_once() {
        makeController(windowOn: target.uuid)
        enterFullScreen(landingOn: Topology.main.uuid)
        window.isFullScreen = false
        window.transitionInFlight = true
        fireExit()                                         // sees the transition in flight: re-polls
        XCTAssertEqual(controller.phase, .exitingForRetry, "waiting for the real didExitFullScreen")

        window.transitionInFlight = false
        window.currentDisplayUUID = Topology.main.uuid
        controller.windowEvent(.didExitFullScreen)         // the real one
        scheduler.runAll()                                 // the re-poll fires, then the post-exit place

        XCTAssertEqual(window.placedOn.map(\.uuid), [target.uuid], "one post-exit placement, not two")
        XCTAssertEqual(window.toggleCount, 1)
    }

    // MARK: Launch-time drift is not fought

    func test_a_drag_of_the_space_after_a_normal_launch_is_left_alone() {
        makeController(windowOn: target.uuid)
        enterFullScreen(landingOn: target.uuid)
        scheduler.runAll()
        let toggles = window.toggleCount

        window.currentDisplayUUID = Topology.main.uuid      // Mission Control drag
        controller.windowEvent(.didChangeScreen)
        scheduler.runAll()

        XCTAssertEqual(controller.phase, .fullScreen)
        XCTAssertEqual(window.toggleCount, toggles)
        XCTAssertEqual(window.placedOn, [])
    }

    // MARK: Phase mirrored onto the window

    /// Consecutive duplicates removed, so it does not matter whether the initial phase is mirrored once or twice.
    private func distinctPhasesSeen() -> [PlacementPhase] {
        var out: [PlacementPhase] = []
        for phase in window.phasesSeen where out.last != phase { out.append(phase) }
        return out
    }

    func test_every_phase_change_is_mirrored_onto_the_window_starting_with_the_initial_phase() {
        makeController(windowOn: Topology.main.uuid)

        controller.begin()
        scheduler.runAll()
        window.isFullScreen = true
        window.currentDisplayUUID = target.uuid
        controller.windowEvent(.didEnterFullScreen)

        XCTAssertEqual(distinctPhasesSeen(), [.idle, .placing(attempt: 1), .enteringFullScreen, .fullScreen])
        XCTAssertEqual(window.phasesSeen.last, controller.phase)
    }

    func test_the_retry_phases_are_mirrored_onto_the_window_too() {
        makeController(windowOn: target.uuid)
        landWrongAndExit()
        XCTAssertEqual(window.phasesSeen.last, controller.phase)

        window.isFullScreen = true
        window.currentDisplayUUID = target.uuid
        controller.windowEvent(.didEnterFullScreen)
        scheduler.runAll()

        XCTAssertEqual(distinctPhasesSeen(),
                       [.idle, .enteringFullScreen, .exitingForRetry, .enteringFullScreen, .fullScreen])
        XCTAssertEqual(window.phasesSeen.last, controller.phase)
    }

    func test_giving_up_is_mirrored_onto_the_window() {
        screens.displays = [Topology.main]               // target absent
        makeController(windowOn: Topology.main.uuid)

        controller.begin()

        XCTAssertEqual(distinctPhasesSeen(), [.idle, .gaveUp])
    }
}
