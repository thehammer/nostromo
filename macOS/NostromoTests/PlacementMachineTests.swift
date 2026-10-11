import XCTest

// PlacementMachine.swift is compiled into this target directly. The machine is
// pure (events in, actions out), so these tests drive it with plain values and
// assert on the returned actions and `phase` — not on log wording, except for
// the two markers the controller keys on ("WARNING" / "giving up").

final class PlacementMachineTests: XCTestCase {

    private let target = "UUID-TARGET"
    private let other = "UUID-OTHER"
    private var machine: PlacementMachine!

    override func setUp() {
        super.setUp()
        machine = PlacementMachine(targetUUID: target)
    }

    // MARK: Helpers

    @discardableResult
    private func send(_ event: PlacementEvent) -> [PlacementAction] {
        machine.handle(event)
    }

    /// Everything except log lines.
    private func commands(_ actions: [PlacementAction]) -> [PlacementAction] {
        actions.filter { if case .log = $0 { return false } else { return true } }
    }

    private func logs(_ actions: [PlacementAction]) -> [String] {
        actions.compactMap { if case let .log(m) = $0 { return m } else { return nil } }
    }

    private func hasWarning(_ actions: [PlacementAction]) -> Bool {
        logs(actions).contains { $0.hasPrefix("WARNING") }
    }

    private func hasGivingUp(_ actions: [PlacementAction]) -> Bool {
        logs(actions).contains { $0.contains("giving up") }
    }

    /// Off-target begin, then the window reports the target: lands in `.enteringFullScreen`.
    private func driveToEnteringFullScreen() {
        send(.begin(currentUUID: other, targetPresent: true))
        send(.screenChanged(currentUUID: target, targetPresent: true))
        XCTAssertEqual(machine.phase, .enteringFullScreen)
    }

    /// Full-screen entered on the target with the default retry budget.
    private func driveToFullScreen() {
        send(.begin(currentUUID: target, targetPresent: true))
        send(.didEnterFullScreen(currentUUID: target))
        XCTAssertEqual(machine.phase, .fullScreen)
    }

    /// Full-screen on the target, reached AFTER spending the single wrong-display retry.
    private func driveToFullScreenWithRetrySpent() {
        driveToEnteringFullScreen()
        let exit = send(.didEnterFullScreen(currentUUID: other))
        XCTAssertTrue(exit.contains(.exitFullScreen))
        send(.didExitFullScreen)
        send(.didEnterFullScreen(currentUUID: target))
        XCTAssertEqual(machine.phase, .fullScreen)
    }

    // MARK: begin

    func test_begin_when_already_on_the_target_goes_straight_to_entering_full_screen() {
        let actions = send(.begin(currentUUID: target, targetPresent: true))

        XCTAssertEqual(commands(actions), [.enterFullScreen])
        XCTAssertEqual(machine.phase, .enteringFullScreen)
    }

    func test_begin_off_target_places_the_window_and_arms_a_verify_timeout() {
        let actions = send(.begin(currentUUID: other, targetPresent: true))

        XCTAssertEqual(commands(actions), [.place, .scheduleVerifyTimeout(attempt: 1)])
        XCTAssertEqual(machine.phase, .placing(attempt: 1))
        XCTAssertFalse(actions.contains(.enterFullScreen), "never toggle before the window is verified on the target")
    }

    func test_begin_with_the_window_on_no_screen_is_treated_as_off_target() {
        let actions = send(.begin(currentUUID: nil, targetPresent: true))

        XCTAssertEqual(commands(actions), [.place, .scheduleVerifyTimeout(attempt: 1)])
        XCTAssertEqual(machine.phase, .placing(attempt: 1))
    }

    func test_begin_with_the_target_display_absent_gives_up_without_placing_or_toggling() {
        let actions = send(.begin(currentUUID: other, targetPresent: false))

        XCTAssertEqual(commands(actions), [])
        XCTAssertEqual(machine.phase, .gaveUp)
    }

    func test_begin_with_the_target_absent_gives_up_even_if_the_window_reports_the_target_uuid() {
        let actions = send(.begin(currentUUID: target, targetPresent: false))

        XCTAssertEqual(commands(actions), [])
        XCTAssertEqual(machine.phase, .gaveUp)
    }

    func test_a_second_begin_is_ignored() {
        send(.begin(currentUUID: other, targetPresent: true))

        let actions = send(.begin(currentUUID: other, targetPresent: true))

        XCTAssertEqual(commands(actions), [])
        XCTAssertEqual(machine.phase, .placing(attempt: 1))
    }

    // MARK: screenChanged while placing

    func test_screen_changing_to_the_target_while_placing_enters_full_screen() {
        send(.begin(currentUUID: other, targetPresent: true))

        let actions = send(.screenChanged(currentUUID: target, targetPresent: true))

        XCTAssertEqual(commands(actions), [.enterFullScreen])
        XCTAssertEqual(machine.phase, .enteringFullScreen)
    }

    func test_screen_changing_to_another_display_keeps_waiting() {
        send(.begin(currentUUID: other, targetPresent: true))

        let actions = send(.screenChanged(currentUUID: "UUID-THIRD", targetPresent: true))

        XCTAssertEqual(commands(actions), [])
        XCTAssertEqual(machine.phase, .placing(attempt: 1))
    }

    func test_screen_changing_to_no_screen_keeps_waiting() {
        send(.begin(currentUUID: other, targetPresent: true))

        let actions = send(.screenChanged(currentUUID: nil, targetPresent: true))

        XCTAssertEqual(commands(actions), [])
        XCTAssertEqual(machine.phase, .placing(attempt: 1))
    }

    func test_screen_changes_before_begin_are_ignored() {
        let actions = send(.screenChanged(currentUUID: target, targetPresent: true))

        XCTAssertEqual(actions, [])
        XCTAssertEqual(machine.phase, .idle)
    }

    // MARK: verify timeouts (bounded re-placement)

    func test_a_verify_timeout_with_the_window_still_off_target_re_places_and_re_arms() {
        send(.begin(currentUUID: other, targetPresent: true))

        let actions = send(.verifyTimeout(attempt: 1, currentUUID: other))

        XCTAssertEqual(commands(actions), [.place, .scheduleVerifyTimeout(attempt: 2)])
        XCTAssertEqual(machine.phase, .placing(attempt: 2))
    }

    func test_a_verify_timeout_that_finds_the_window_on_target_enters_full_screen() {
        send(.begin(currentUUID: other, targetPresent: true))

        let actions = send(.verifyTimeout(attempt: 1, currentUUID: target))

        XCTAssertEqual(commands(actions), [.enterFullScreen])
        XCTAssertEqual(machine.phase, .enteringFullScreen)
    }

    func test_placement_is_attempted_at_most_three_times_then_full_screen_is_entered_anyway_with_a_warning() {
        var placeCount = 0
        var all: [PlacementAction] = []

        var actions = send(.begin(currentUUID: other, targetPresent: true))
        all += actions
        for attempt in 1...PlacementMachine.maxPlacementAttempts {
            actions = send(.verifyTimeout(attempt: attempt, currentUUID: other))
            all += actions
        }
        placeCount = all.filter { $0 == .place }.count

        XCTAssertEqual(PlacementMachine.maxPlacementAttempts, 3)
        XCTAssertEqual(placeCount, 3, "initial placement plus two re-placements, never more")
        XCTAssertEqual(commands(actions), [.enterFullScreen])
        XCTAssertTrue(hasWarning(actions), "entering full-screen off-target must be logged as a WARNING")
        XCTAssertEqual(machine.phase, .enteringFullScreen)
    }

    func test_a_timeout_after_the_budget_is_spent_does_not_place_again() {
        send(.begin(currentUUID: other, targetPresent: true))
        send(.verifyTimeout(attempt: 1, currentUUID: other))
        send(.verifyTimeout(attempt: 2, currentUUID: other))
        send(.verifyTimeout(attempt: 3, currentUUID: other))

        let late = send(.verifyTimeout(attempt: 3, currentUUID: other))

        XCTAssertEqual(commands(late), [])
        XCTAssertEqual(machine.phase, .enteringFullScreen)
    }

    func test_a_stale_timeout_from_an_earlier_attempt_is_ignored() {
        send(.begin(currentUUID: other, targetPresent: true))
        send(.verifyTimeout(attempt: 1, currentUUID: other)) // now on attempt 2

        let stale = send(.verifyTimeout(attempt: 1, currentUUID: other))

        XCTAssertEqual(stale, [])
        XCTAssertEqual(machine.phase, .placing(attempt: 2))
    }

    func test_a_timeout_for_a_future_attempt_is_ignored() {
        send(.begin(currentUUID: other, targetPresent: true))

        let bogus = send(.verifyTimeout(attempt: 2, currentUUID: other))

        XCTAssertEqual(bogus, [])
        XCTAssertEqual(machine.phase, .placing(attempt: 1))
    }

    func test_a_timeout_arriving_after_placement_was_already_verified_is_ignored() {
        driveToEnteringFullScreen()

        let late = send(.verifyTimeout(attempt: 1, currentUUID: other))

        XCTAssertEqual(late, [])
        XCTAssertEqual(machine.phase, .enteringFullScreen)
    }

    func test_a_timeout_before_begin_is_ignored() {
        let actions = send(.verifyTimeout(attempt: 1, currentUUID: other))

        XCTAssertEqual(actions, [])
        XCTAssertEqual(machine.phase, .idle)
    }

    // MARK: didEnterFullScreen

    func test_entering_full_screen_on_the_target_completes_placement() {
        driveToEnteringFullScreen()

        let actions = send(.didEnterFullScreen(currentUUID: target))

        XCTAssertEqual(commands(actions), [])
        XCTAssertFalse(hasWarning(actions))
        XCTAssertEqual(machine.phase, .fullScreen)
    }

    func test_entering_full_screen_on_the_wrong_display_exits_once_to_retry() {
        driveToEnteringFullScreen()

        let actions = send(.didEnterFullScreen(currentUUID: other))

        XCTAssertEqual(commands(actions), [.exitFullScreen])
        XCTAssertEqual(machine.phase, .exitingForRetry)
    }

    func test_after_exiting_for_retry_the_window_is_re_placed_and_the_machine_does_not_re_enter_itself() {
        driveToEnteringFullScreen()
        send(.didEnterFullScreen(currentUUID: other))

        let actions = send(.didExitFullScreen)

        XCTAssertEqual(commands(actions), [.place])
        XCTAssertFalse(actions.contains(.enterFullScreen),
                       "NostromoWindow's own delayed re-entry does the toggle; the machine must not double-toggle")
        XCTAssertEqual(machine.phase, .enteringFullScreen)
    }

    func test_the_retry_succeeds_when_the_re_entry_lands_on_the_target() {
        driveToEnteringFullScreen()
        send(.didEnterFullScreen(currentUUID: other))
        send(.didExitFullScreen)

        let actions = send(.didEnterFullScreen(currentUUID: target))

        XCTAssertEqual(commands(actions), [])
        XCTAssertEqual(machine.phase, .fullScreen)
    }

    func test_a_second_wrong_landing_gives_up_instead_of_looping() {
        driveToEnteringFullScreen()
        send(.didEnterFullScreen(currentUUID: other))
        send(.didExitFullScreen)

        let actions = send(.didEnterFullScreen(currentUUID: other))

        XCTAssertEqual(commands(actions), [], "no further exit, place, or enter")
        XCTAssertTrue(hasGivingUp(actions), "the give-up must be logged with the 'giving up' marker")
        XCTAssertEqual(machine.phase, .gaveUp)
    }

    func test_once_gave_up_nothing_more_happens() {
        driveToEnteringFullScreen()
        send(.didEnterFullScreen(currentUUID: other))
        send(.didExitFullScreen)
        send(.didEnterFullScreen(currentUUID: other))
        XCTAssertEqual(machine.phase, .gaveUp)

        XCTAssertEqual(commands(send(.didEnterFullScreen(currentUUID: other))), [])
        XCTAssertEqual(commands(send(.didExitFullScreen)), [])
        XCTAssertEqual(commands(send(.screenChanged(currentUUID: target, targetPresent: true))), [])
        XCTAssertEqual(commands(send(.verifyTimeout(attempt: 1, currentUUID: other))), [])
        XCTAssertEqual(machine.phase, .gaveUp)
    }

    func test_full_screen_entered_after_the_placement_budget_ran_out_off_target_still_gets_the_one_retry() {
        send(.begin(currentUUID: other, targetPresent: true))
        send(.verifyTimeout(attempt: 1, currentUUID: other))
        send(.verifyTimeout(attempt: 2, currentUUID: other))
        send(.verifyTimeout(attempt: 3, currentUUID: other))

        let actions = send(.didEnterFullScreen(currentUUID: other))

        XCTAssertEqual(commands(actions), [.exitFullScreen])
        XCTAssertEqual(machine.phase, .exitingForRetry)
    }

    func test_full_screen_entering_before_begin_is_ignored() {
        let actions = send(.didEnterFullScreen(currentUUID: other))

        XCTAssertEqual(actions, [])
        XCTAssertEqual(machine.phase, .idle)
    }

    // MARK: didFailToEnterFullScreen / didExitFullScreen

    func test_a_failed_full_screen_entry_stays_in_entering_so_the_windows_own_retry_is_still_verified() {
        driveToEnteringFullScreen()

        let actions = send(.didFailToEnterFullScreen)

        XCTAssertEqual(commands(actions), [], "NostromoWindow owns the retry; the machine must not toggle, place or exit")
        XCTAssertEqual(machine.phase, .enteringFullScreen)

        // The window's retry later succeeds on the target.
        send(.didEnterFullScreen(currentUUID: target))
        XCTAssertEqual(machine.phase, .fullScreen)
    }

    func test_a_system_exit_from_full_screen_waits_for_the_windows_own_re_entry() {
        driveToFullScreen()

        let actions = send(.didExitFullScreen)

        XCTAssertEqual(commands(actions), [])
        XCTAssertEqual(machine.phase, .enteringFullScreen)
    }

    // MARK: display reconfiguration (re-home)

    func test_displays_reconfigured_always_arms_the_re_home_expiry() {
        driveToFullScreen()

        let actions = send(.displaysReconfigured(currentUUID: target, targetPresent: true))

        XCTAssertEqual(commands(actions), [.scheduleRehomeExpiry])
        XCTAssertEqual(machine.phase, .fullScreen)
    }

    func test_a_reconfiguration_that_drifted_the_full_screen_window_triggers_a_re_home_retry() {
        driveToFullScreen()

        let actions = send(.displaysReconfigured(currentUUID: other, targetPresent: true))

        XCTAssertEqual(commands(actions), [.scheduleRehomeExpiry, .exitFullScreen])
        XCTAssertEqual(machine.phase, .exitingForRetry)
    }

    func test_a_reconfiguration_grants_a_fresh_retry_even_after_the_budget_was_spent() {
        driveToFullScreenWithRetrySpent()

        let actions = send(.displaysReconfigured(currentUUID: other, targetPresent: true))

        XCTAssertTrue(actions.contains(.exitFullScreen))
        XCTAssertEqual(machine.phase, .exitingForRetry)
    }

    func test_the_re_home_retry_re_places_after_the_exit_completes() {
        driveToFullScreen()
        send(.displaysReconfigured(currentUUID: other, targetPresent: true))

        let actions = send(.didExitFullScreen)

        XCTAssertEqual(commands(actions), [.place])
        XCTAssertFalse(actions.contains(.enterFullScreen))
    }

    func test_a_drift_with_the_target_display_absent_is_not_re_homed() {
        driveToFullScreen()

        let actions = send(.displaysReconfigured(currentUUID: other, targetPresent: false))

        XCTAssertEqual(commands(actions), [.scheduleRehomeExpiry])
        XCTAssertFalse(actions.contains(.exitFullScreen))
        XCTAssertFalse(actions.contains(.place))
        XCTAssertEqual(machine.phase, .fullScreen)
    }

    func test_a_screen_change_drift_with_the_target_absent_is_not_re_homed() {
        driveToFullScreen()

        let actions = send(.screenChanged(currentUUID: other, targetPresent: false))

        XCTAssertFalse(actions.contains(.exitFullScreen))
        XCTAssertEqual(machine.phase, .fullScreen)
    }

    func test_a_reconfiguration_that_leaves_the_window_on_the_target_does_nothing_more() {
        driveToFullScreenWithRetrySpent()

        let actions = send(.displaysReconfigured(currentUUID: target, targetPresent: true))

        XCTAssertEqual(commands(actions), [.scheduleRehomeExpiry])
        XCTAssertEqual(machine.phase, .fullScreen)
    }

    func test_after_the_re_home_grace_expires_a_later_drift_is_not_fought() {
        driveToFullScreen()
        send(.displaysReconfigured(currentUUID: target, targetPresent: true))
        send(.rehomeWindowExpired)

        let actions = send(.screenChanged(currentUUID: other, targetPresent: true))

        XCTAssertFalse(actions.contains(.exitFullScreen), "a user-driven move after the grace period must be left alone")
        XCTAssertFalse(actions.contains(.place))
        XCTAssertFalse(actions.contains(.enterFullScreen))
        XCTAssertNotEqual(machine.phase, .exitingForRetry)
    }

    func test_a_drift_before_the_grace_expires_is_still_re_homed() {
        driveToFullScreenWithRetrySpent()
        send(.displaysReconfigured(currentUUID: target, targetPresent: true))

        let actions = send(.screenChanged(currentUUID: other, targetPresent: true))

        XCTAssertTrue(actions.contains(.exitFullScreen))
        XCTAssertEqual(machine.phase, .exitingForRetry)
    }

    func test_re_home_expiry_while_idle_is_harmless() {
        let actions = send(.rehomeWindowExpired)

        XCTAssertEqual(actions, [])
        XCTAssertEqual(machine.phase, .idle)
    }

    func test_a_reconfiguration_during_placement_does_not_toggle_anything() {
        send(.begin(currentUUID: other, targetPresent: true))

        let actions = send(.displaysReconfigured(currentUUID: other, targetPresent: true))

        XCTAssertFalse(actions.contains(.enterFullScreen))
        XCTAssertFalse(actions.contains(.exitFullScreen))
        XCTAssertEqual(machine.phase, .placing(attempt: 1))
    }

    // MARK: willExitFullScreen (an exit we did not ask for)

    func test_an_exit_beginning_from_full_screen_starts_no_transition_and_awaits_the_windows_re_entry() {
        driveToFullScreen()

        let actions = send(.willExitFullScreen)

        XCTAssertEqual(commands(actions), [], "never start a second transition on top of the in-flight exit")
        XCTAssertEqual(machine.phase, .enteringFullScreen)
    }

    func test_drift_while_an_exit_is_in_flight_does_not_cause_an_exit_or_placement() {
        driveToFullScreenWithRetrySpent()
        send(.willExitFullScreen)

        let changed = send(.screenChanged(currentUUID: other, targetPresent: true))
        let reconfigured = send(.displaysReconfigured(currentUUID: other, targetPresent: true))
        let exited = send(.didExitFullScreen)

        for actions in [changed, reconfigured, exited] {
            XCTAssertFalse(actions.contains(.exitFullScreen))
            XCTAssertFalse(actions.contains(.enterFullScreen))
            XCTAssertFalse(actions.contains(.place))
        }
        XCTAssertEqual(machine.phase, .enteringFullScreen)
    }

    func test_the_re_entry_after_a_system_exit_is_still_verified() {
        driveToFullScreen()
        send(.willExitFullScreen)
        send(.didExitFullScreen)

        send(.didEnterFullScreen(currentUUID: target))

        XCTAssertEqual(machine.phase, .fullScreen)
    }

    func test_will_exit_outside_full_screen_is_ignored() {
        send(.begin(currentUUID: other, targetPresent: true))

        let actions = send(.willExitFullScreen)

        XCTAssertEqual(actions, [])
        XCTAssertEqual(machine.phase, .placing(attempt: 1))
    }

    // MARK: exitAbandoned

    func test_an_abandoned_exit_gives_up_without_any_toggle() {
        driveToEnteringFullScreen()
        send(.didEnterFullScreen(currentUUID: other))
        XCTAssertEqual(machine.phase, .exitingForRetry)

        let actions = send(.exitAbandoned)

        XCTAssertEqual(commands(actions), [])
        XCTAssertTrue(hasGivingUp(actions))
        XCTAssertEqual(machine.phase, .gaveUp)
    }

    func test_an_abandoned_exit_is_ignored_when_no_exit_is_pending() {
        driveToFullScreen()

        let actions = send(.exitAbandoned)

        XCTAssertEqual(actions, [])
        XCTAssertEqual(machine.phase, .fullScreen)
    }

    func test_nothing_happens_after_an_abandoned_exit() {
        driveToEnteringFullScreen()
        send(.didEnterFullScreen(currentUUID: other))
        send(.exitAbandoned)

        XCTAssertEqual(commands(send(.didEnterFullScreen(currentUUID: other))), [])
        XCTAssertEqual(commands(send(.displaysReconfigured(currentUUID: other, targetPresent: true))), [.scheduleRehomeExpiry])
        XCTAssertEqual(machine.phase, .gaveUp)
    }

    // MARK: Lifetime cap on retries

    func test_repeated_reconfigurations_can_never_produce_more_than_the_lifetime_cap_of_exits() {
        XCTAssertEqual(PlacementMachine.maxLifetimeRetries, 3)
        driveToFullScreen()
        var exits = 0

        for _ in 0..<10 {
            // Each notification re-arms the per-notification retry budget.
            let actions = send(.displaysReconfigured(currentUUID: other, targetPresent: true))
            if actions.contains(.exitFullScreen) {
                exits += 1
                send(.didExitFullScreen)
                send(.didEnterFullScreen(currentUUID: target))
                XCTAssertEqual(machine.phase, .fullScreen)
            } else {
                break
            }
        }

        XCTAssertEqual(exits, 3)
        XCTAssertEqual(machine.phase, .gaveUp)
    }

    func test_wrong_landing_retries_count_toward_the_same_lifetime_cap() {
        driveToEnteringFullScreen()
        var exits = 0
        // Exit #1: wrong landing.
        if send(.didEnterFullScreen(currentUUID: other)).contains(.exitFullScreen) { exits += 1 }
        send(.didExitFullScreen)
        send(.didEnterFullScreen(currentUUID: target))

        for _ in 0..<10 {
            let actions = send(.displaysReconfigured(currentUUID: other, targetPresent: true))
            guard actions.contains(.exitFullScreen) else { break }
            exits += 1
            send(.didExitFullScreen)
            send(.didEnterFullScreen(currentUUID: target))
        }

        XCTAssertEqual(exits, PlacementMachine.maxLifetimeRetries)
        XCTAssertEqual(machine.phase, .gaveUp)
    }
}
