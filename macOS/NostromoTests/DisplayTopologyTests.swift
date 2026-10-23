import XCTest
import CoreGraphics

// DisplayTopology.swift and DisplayIdentity.swift are compiled into this target
// directly. No NSScreen, no real displays, no wall clock: displays are fake
// `DisplayInfo` values, time is a virtual clock, and the window side is a fake
// host that models which display keys have a window.
//
// Bug under test: macOS posts didChangeScreenParameters in bursts and with no
// real change (an AirPlay display flapping, 69 events in 3 h). Acting on every
// event re-homed every full-screen window and closed/reopened windows for
// displays that came right back, blanking the panes; the same display was also
// logged "removed" repeatedly.

// MARK: - Fakes

private enum Fake {
    static let builtIn = DisplayInfo(
        uuid: "BUILT-IN", screenNumber: 1,
        frame: CGRect(x: 0, y: 0, width: 1710, height: 1107),
        visibleFrame: CGRect(x: 0, y: 0, width: 1710, height: 1073),
        backingScaleFactor: 2, localizedName: "Built-in", isMain: true)
    static let lg = DisplayInfo(
        uuid: "LG-ULTRAFINE", screenNumber: 2,
        frame: CGRect(x: -2560, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: -2560, y: 0, width: 2560, height: 1415),
        backingScaleFactor: 2, localizedName: "LG UltraFine")
    static let dell = DisplayInfo(
        uuid: "DELL-U2720", screenNumber: 3,
        frame: CGRect(x: 1710, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1710, y: 0, width: 2560, height: 1415),
        backingScaleFactor: 2, localizedName: "DELL U2720Q")
    static let airPlayUUID = "24E59D51-7F70-4694-AD35-8834D0D5C429"
    static let airPlay = DisplayInfo(
        uuid: airPlayUUID, screenNumber: 4,
        frame: CGRect(x: 4270, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 4270, y: 0, width: 1920, height: 1055),
        backingScaleFactor: 1, localizedName: "Flex Room")

    static let three = [builtIn, lg, dell]
    static let four = [builtIn, lg, dell, airPlay]

    static func moved(_ d: DisplayInfo, by dx: CGFloat) -> DisplayInfo {
        DisplayInfo(uuid: d.uuid, screenNumber: d.screenNumber,
                    frame: d.frame.offsetBy(dx: dx, dy: 0),
                    visibleFrame: d.visibleFrame.offsetBy(dx: dx, dy: 0),
                    backingScaleFactor: d.backingScaleFactor,
                    localizedName: d.localizedName, isMain: d.isMain)
    }
}

/// A virtual clock: `advance(by:)` fires every closure that falls due, in time
/// order (ties in scheduling order), including closures scheduled while firing.
private final class VirtualClock: PlacementScheduler {
    private(set) var now: TimeInterval = 0
    private var queue: [(due: TimeInterval, seq: Int, work: () -> Void)] = []
    private var seq = 0

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
        seq += 1
        queue.append((now + max(delay, 0), seq, work))
    }

    func advance(by interval: TimeInterval) {
        let target = now + interval
        while let index = nextDueIndex(upTo: target) {
            let item = queue.remove(at: index)
            now = max(now, item.due)
            item.work()
        }
        now = target
    }

    private func nextDueIndex(upTo target: TimeInterval) -> Int? {
        var best: Int?
        for (i, item) in queue.enumerated() where item.due <= target {
            if let b = best {
                if (item.due, item.seq) < (queue[b].due, queue[b].seq) { best = i }
            } else {
                best = i
            }
        }
        return best
    }
}

/// Models the window side: which display keys have a window, and what was asked of them.
private final class FakeHost {
    var attached: [DisplayInfo]
    /// display key -> window identity (so tests can tell a kept window from a recreated one).
    private(set) var windows: [String: Int] = [:]
    private var nextWindowID = 1

    private(set) var rehomed: [String] = []
    private(set) var openBatches: [[String]] = []
    private(set) var closed: [String] = []
    private(set) var topologyChangedCount = 0
    private(set) var passFinishedCount = 0
    private(set) var logs: [String] = []

    /// Runs inside `closeWindow`, BEFORE the window is unbound (AppKit calls that can
    /// synchronously post didChangeScreenParameters).
    var duringClose: ((String) -> Void)?
    /// False models a stale binding: the window is never unbound.
    var unbindsOnClose = true

    /// Keys whose window macOS has moved off its own display (what `driftedUUIDs` reports).
    var drifted: Set<String> = []
    /// Keys whose window is mid enter/exit transition (what `isWindowTransitioning` reports).
    var transitioning: Set<String> = []

    struct PendingRemovalCall: Equatable {
        let uuid: String
        let pending: Bool
    }
    /// Every `setPendingRemoval` call, in order.
    private(set) var pendingRemovalCalls: [PendingRemovalCall] = []
    /// The keys currently flagged doomed (the net effect of the calls).
    private(set) var pendingRemoval: Set<String> = []

    /// The window for `uuid` disappears by some route other than `closeWindow`.
    func dropWindow(_ uuid: String) { windows.removeValue(forKey: uuid) }
    /// A window for `uuid` appears by some route other than `openWindows`.
    func addWindow(_ uuid: String) { bind(uuid) }

    init(attached: [DisplayInfo]) {
        self.attached = attached
        for d in attached { bind(d.uuid) }
    }

    var boundUUIDs: Set<String> { Set(windows.keys) }
    var opened: [String] { openBatches.flatMap { $0 } }
    func closeCount(of uuid: String) -> Int { closed.filter { $0 == uuid }.count }
    func openCount(of uuid: String) -> Int { opened.filter { $0 == uuid }.count }

    private func bind(_ uuid: String) {
        windows[uuid] = nextWindowID
        nextWindowID += 1
    }

    func makeHost() -> DisplayTopologyCoordinator.Host {
        DisplayTopologyCoordinator.Host(
            attachedDisplays: { [unowned self] in self.attached },
            boundUUIDs: { [unowned self] in self.boundUUIDs },
            topologyChanged: { [unowned self] in self.topologyChangedCount += 1 },
            rehome: { [unowned self] uuid in self.rehomed.append(uuid) },
            openWindows: { [unowned self] displays in
                self.openBatches.append(displays.map(\.uuid))
                for d in displays { self.bind(d.uuid) }
            },
            closeWindow: { [unowned self] uuid in
                self.closed.append(uuid)
                self.duringClose?(uuid)
                if self.unbindsOnClose { self.windows.removeValue(forKey: uuid) }
            },
            passFinished: { [unowned self] in self.passFinishedCount += 1 },
            log: { [unowned self] message in self.logs.append(message) },
            driftedUUIDs: { [unowned self] in self.drifted },
            setPendingRemoval: { [unowned self] uuid, pending in
                self.pendingRemovalCalls.append(PendingRemovalCall(uuid: uuid, pending: pending))
                if pending { self.pendingRemoval.insert(uuid) } else { self.pendingRemoval.remove(uuid) }
            },
            isWindowTransitioning: { [unowned self] uuid in self.transitioning.contains(uuid) })
    }
}

/// Coordinator + clock + host, launched with windows open on `initial` and that
/// topology recorded as handled (what AppDelegate does at launch).
private final class Rig {
    let clock = VirtualClock()
    let host: FakeHost
    let coordinator: DisplayTopologyCoordinator

    init(initial: [DisplayInfo] = Fake.three) {
        host = FakeHost(attached: initial)
        coordinator = DisplayTopologyCoordinator(scheduler: clock, host: host.makeHost())
        coordinator.recordHandled(initial)
    }

    /// One notification, then let it settle (past the 0.5 s debounce).
    func notify() {
        coordinator.displaysChanged()
        clock.advance(by: 0.5)
    }

    /// Change what is attached and notify; the resulting pass has run on return.
    func setAttached(_ displays: [DisplayInfo]) {
        host.attached = displays
        notify()
    }
}

// MARK: - Fingerprint

final class DisplayTopologyFingerprintTests: XCTestCase {

    func test_fingerprint_is_independent_of_the_order_displays_are_listed() {
        XCTAssertEqual(DisplayTopologyFingerprint(displays: [Fake.builtIn, Fake.lg, Fake.dell]),
                       DisplayTopologyFingerprint(displays: [Fake.dell, Fake.builtIn, Fake.lg]))
    }

    func test_fingerprint_differs_when_a_display_is_added_or_removed() {
        XCTAssertNotEqual(DisplayTopologyFingerprint(displays: Fake.three),
                          DisplayTopologyFingerprint(displays: Fake.four))
        XCTAssertNotEqual(DisplayTopologyFingerprint(displays: Fake.three),
                          DisplayTopologyFingerprint(displays: [Fake.builtIn, Fake.lg]))
    }

    func test_fingerprint_differs_when_a_display_uuid_changes() {
        let renamed = Fake.dell.withUUID("DELL-OTHER")
        XCTAssertNotEqual(DisplayTopologyFingerprint(displays: Fake.three),
                          DisplayTopologyFingerprint(displays: [Fake.builtIn, Fake.lg, renamed]))
    }

    func test_fingerprint_differs_when_a_display_frame_changes() {
        XCTAssertNotEqual(DisplayTopologyFingerprint(displays: Fake.three),
                          DisplayTopologyFingerprint(displays: [Fake.builtIn, Fake.lg, Fake.moved(Fake.dell, by: 100)]))
        let resized = DisplayInfo(uuid: Fake.dell.uuid, screenNumber: Fake.dell.screenNumber,
                                  frame: CGRect(x: 1710, y: 0, width: 1920, height: 1080),
                                  visibleFrame: Fake.dell.visibleFrame,
                                  backingScaleFactor: Fake.dell.backingScaleFactor)
        XCTAssertNotEqual(DisplayTopologyFingerprint(displays: Fake.three),
                          DisplayTopologyFingerprint(displays: [Fake.builtIn, Fake.lg, resized]))
    }

    func test_fingerprint_differs_when_a_display_backing_scale_changes() {
        let retina = DisplayInfo(uuid: Fake.dell.uuid, screenNumber: Fake.dell.screenNumber,
                                 frame: Fake.dell.frame, visibleFrame: Fake.dell.visibleFrame,
                                 backingScaleFactor: 1)
        XCTAssertNotEqual(DisplayTopologyFingerprint(displays: Fake.three),
                          DisplayTopologyFingerprint(displays: [Fake.builtIn, Fake.lg, retina]))
    }

    func test_fingerprint_ignores_visible_frame_name_main_flag_and_screen_number() {
        let cosmetic = DisplayInfo(uuid: Fake.dell.uuid, screenNumber: 99,
                                   frame: Fake.dell.frame,
                                   visibleFrame: Fake.dell.visibleFrame.insetBy(dx: 0, dy: 40),
                                   backingScaleFactor: Fake.dell.backingScaleFactor,
                                   localizedName: "Renamed", isMain: true)
        XCTAssertEqual(DisplayTopologyFingerprint(displays: Fake.three),
                       DisplayTopologyFingerprint(displays: [Fake.builtIn, Fake.lg, cosmetic]))
    }
}

// MARK: - State (pure decisions)

final class DisplayTopologyStateTests: XCTestCase {

    private func seeded(_ displays: [DisplayInfo] = Fake.three) -> DisplayTopologyState {
        var state = DisplayTopologyState()
        state.recordHandled(displays)
        return state
    }

    private func keys(_ displays: [DisplayInfo]) -> Set<String> { Set(displays.map(\.uuid)) }

    private func pass(_ decision: DisplayTopologyState.Decision,
                      file: StaticString = #filePath, line: UInt = #line) -> DisplayTopologyState.Pass? {
        guard case .pass(let p) = decision else {
            XCTFail("expected a pass, got \(decision)", file: file, line: line)
            return nil
        }
        return p
    }

    func test_unchanged_topology_with_every_display_bound_does_nothing() {
        var state = seeded()
        XCTAssertEqual(state.reconcile(attached: Fake.three, bound: keys(Fake.three)),
                       .unchanged(shouldLog: true))
    }

    func test_unchanged_events_log_the_first_then_only_every_interval() {
        var state = seeded()
        let interval = DisplayTopologyState.unchangedLogInterval
        XCTAssertGreaterThan(interval, 1)
        for i in 1...(interval * 2 + 1) {
            let decision = state.reconcile(attached: Fake.three, bound: keys(Fake.three))
            let expected = i == 1 || i % interval == 0
            XCTAssertEqual(decision, .unchanged(shouldLog: expected), "unchanged event #\(i)")
        }
    }

    func test_a_real_change_between_unchanged_runs_restarts_the_logging() {
        var state = seeded()
        _ = state.reconcile(attached: Fake.three, bound: keys(Fake.three))
        XCTAssertEqual(state.reconcile(attached: Fake.three, bound: keys(Fake.three)), .unchanged(shouldLog: false))

        let moved = [Fake.builtIn, Fake.lg, Fake.moved(Fake.dell, by: 50)]
        _ = state.reconcile(attached: moved, bound: keys(moved))
        XCTAssertEqual(state.reconcile(attached: moved, bound: keys(moved)), .unchanged(shouldLog: true))
    }

    func test_changed_topology_gives_each_surviving_window_exactly_one_rehome_and_not_the_vanished_one() {
        var state = seeded(Fake.three)
        let attached = [Fake.builtIn, Fake.dell]   // LG vanished
        guard let p = pass(state.reconcile(attached: attached, bound: keys(Fake.three))) else { return }

        XCTAssertEqual(p.rehome, [Fake.builtIn.uuid, Fake.dell.uuid].sorted())
        XCTAssertFalse(p.rehome.contains(Fake.lg.uuid))
        XCTAssertEqual(p.scheduleClose.map(\.uuid), [Fake.lg.uuid])
        XCTAssertEqual(p.open, [])
        XCTAssertEqual(p.cancelledClose, [])

        // The same topology again is no longer a change.
        XCTAssertEqual(state.reconcile(attached: attached, bound: keys(Fake.three)),
                       .unchanged(shouldLog: true))
    }

    func test_rehome_list_is_sorted_regardless_of_the_order_displays_are_given() {
        var state = seeded(Fake.three)
        let attached = [Fake.dell, Fake.lg, Fake.moved(Fake.builtIn, by: 1)]
        guard let p = pass(state.reconcile(attached: attached, bound: keys(Fake.three))) else { return }
        XCTAssertEqual(p.rehome, Fake.three.map(\.uuid).sorted())
    }

    func test_newly_attached_display_without_a_window_is_opened_and_existing_windows_are_rehomed() {
        var state = seeded(Fake.three)
        guard let p = pass(state.reconcile(attached: Fake.four, bound: keys(Fake.three))) else { return }
        XCTAssertEqual(p.open, [Fake.airPlay])
        XCTAssertEqual(p.rehome, Fake.three.map(\.uuid).sorted())
        XCTAssertEqual(p.scheduleClose, [])
    }

    func test_unchanged_fingerprint_with_an_attached_display_lacking_a_window_opens_it_without_rehoming() {
        var state = seeded(Fake.three)
        let bound = keys([Fake.builtIn, Fake.lg])   // Dell's window is missing
        guard let p = pass(state.reconcile(attached: Fake.three, bound: bound)) else { return }
        XCTAssertEqual(p.open, [Fake.dell])
        XCTAssertEqual(p.rehome, [], "nothing changed topologically, so no re-home grants")
        XCTAssertEqual(p.scheduleClose, [])
    }

    func test_a_vanished_display_that_is_removed_again_is_not_scheduled_for_close_twice() {
        var state = seeded(Fake.three)
        let first = [Fake.builtIn, Fake.lg]
        guard let p1 = pass(state.reconcile(attached: first, bound: keys(Fake.three))) else { return }
        XCTAssertEqual(p1.scheduleClose.map(\.uuid), [Fake.dell.uuid])

        // Still bound, still gone, and a different display's frame changed, so the
        // fingerprint differs again.
        let second = [Fake.builtIn, Fake.moved(Fake.lg, by: 10)]
        guard let p2 = pass(state.reconcile(attached: second, bound: keys(Fake.three))) else { return }
        XCTAssertEqual(p2.scheduleClose, [], "Dell is already waiting out its grace")
        XCTAssertEqual(p2.rehome, [Fake.builtIn.uuid, Fake.lg.uuid].sorted())

        // And only the one pending close can actually close it.
        XCTAssertTrue(state.graceExpired(p1.scheduleClose[0], displayStillAttached: false))
        XCTAssertFalse(state.graceExpired(p1.scheduleClose[0], displayStillAttached: false))
    }

    func test_a_display_returning_within_the_grace_cancels_the_close_and_the_stale_timer_cannot_close() {
        var state = seeded(Fake.three)
        guard let gone = pass(state.reconcile(attached: [Fake.builtIn, Fake.lg], bound: keys(Fake.three))),
              let stale = gone.scheduleClose.first else { return }

        guard let back = pass(state.reconcile(attached: Fake.three, bound: keys(Fake.three))) else { return }
        XCTAssertEqual(back.cancelledClose, [Fake.dell.uuid])
        XCTAssertEqual(back.open, [], "the window was never closed, so none is reopened")
        XCTAssertEqual(back.scheduleClose, [])

        // Even if the display looks gone again at timer time, the stale token is dead.
        XCTAssertFalse(state.graceExpired(stale, displayStillAttached: false))
    }

    func test_flap_away_back_away_only_the_latest_timer_closes_and_only_once() {
        var state = seeded(Fake.three)
        let away = [Fake.builtIn, Fake.lg]

        guard let p1 = pass(state.reconcile(attached: away, bound: keys(Fake.three))),
              let first = p1.scheduleClose.first else { return }
        _ = state.reconcile(attached: Fake.three, bound: keys(Fake.three))
        guard let p3 = pass(state.reconcile(attached: away, bound: keys(Fake.three))),
              let second = p3.scheduleClose.first else { return }

        XCTAssertNotEqual(first, second)
        XCTAssertFalse(state.graceExpired(first, displayStillAttached: false), "first timer is stale")
        XCTAssertTrue(state.graceExpired(second, displayStillAttached: false))
        XCTAssertFalse(state.graceExpired(second, displayStillAttached: false), "closes exactly once")
    }

    func test_grace_expiring_while_the_display_is_attached_does_not_close_and_clears_the_pending_close() {
        var state = seeded(Fake.three)
        let away = [Fake.builtIn, Fake.lg]
        guard let p1 = pass(state.reconcile(attached: away, bound: keys(Fake.three))),
              let close = p1.scheduleClose.first else { return }

        XCTAssertFalse(state.graceExpired(close, displayStillAttached: true))

        // A later vanish of the same display schedules afresh.
        guard let p2 = pass(state.reconcile(attached: away, bound: keys(Fake.three))) else { return }
        XCTAssertEqual(p2.scheduleClose.map(\.uuid), [Fake.dell.uuid])
        XCTAssertNotEqual(p2.scheduleClose.first, close)
    }

    func test_a_pending_close_whose_window_was_unbound_by_other_means_does_not_block_a_later_close() {
        var state = seeded(Fake.three)
        let away = [Fake.builtIn, Fake.lg]
        guard let p1 = pass(state.reconcile(attached: away, bound: keys(Fake.three))),
              let old = p1.scheduleClose.first else { return }

        // The window went away by some other route; nothing to do.
        XCTAssertEqual(state.reconcile(attached: away, bound: keys(away)), .unchanged(shouldLog: true))

        // A window for that key exists again and the display is still gone: close it, afresh.
        guard let p2 = pass(state.reconcile(attached: away, bound: keys(Fake.three))) else { return }
        XCTAssertEqual(p2.scheduleClose.map(\.uuid), [Fake.dell.uuid])
        let fresh = p2.scheduleClose[0]
        XCTAssertFalse(state.graceExpired(old, displayStillAttached: false))
        XCTAssertTrue(state.graceExpired(fresh, displayStillAttached: false))
    }

    func test_losing_every_display_schedules_the_close_and_rehomes_nothing() {
        var state = seeded([Fake.builtIn])
        guard let p = pass(state.reconcile(attached: [], bound: keys([Fake.builtIn]))) else { return }
        XCTAssertEqual(p.rehome, [])
        XCTAssertEqual(p.scheduleClose.map(\.uuid), [Fake.builtIn.uuid])
    }

    func test_first_event_without_seeding_counts_as_a_change() {
        var state = DisplayTopologyState()
        guard let p = pass(state.reconcile(attached: Fake.three, bound: keys(Fake.three))) else { return }
        XCTAssertEqual(p.rehome, Fake.three.map(\.uuid).sorted())
    }
}

// MARK: - Coordinator: debounce and seeding

final class DisplayTopologyCoordinatorTests: XCTestCase {

    func test_a_burst_of_notifications_produces_one_pass_that_sees_the_latest_topology() {
        let rig = Rig(initial: [Fake.builtIn, Fake.lg])
        for i in 0..<8 {
            if i == 2 { rig.host.attached = [Fake.builtIn, Fake.lg, Fake.dell] }
            if i == 5 { rig.host.attached = [Fake.builtIn, Fake.lg, Fake.dell, Fake.airPlay] }
            rig.coordinator.displaysChanged()
            rig.clock.advance(by: 0.0625)          // 8 events inside 0.5 s
        }
        XCTAssertEqual(rig.host.topologyChangedCount, 0, "nothing runs while the burst is still settling")

        rig.clock.advance(by: 5)

        XCTAssertEqual(rig.host.topologyChangedCount, 1)
        XCTAssertEqual(rig.host.passFinishedCount, 1)
        XCTAssertEqual(rig.host.openBatches.count, 1, "both new displays are opened by the one pass")
        XCTAssertEqual(Set(rig.host.opened), [Fake.dell.uuid, Fake.airPlay.uuid])
        XCTAssertEqual(rig.host.rehomed.sorted(), [Fake.builtIn.uuid, Fake.lg.uuid].sorted())
        XCTAssertEqual(rig.host.closed, [])
    }

    func test_nothing_happens_before_the_settle_delay_and_the_pass_runs_once_it_elapses() {
        let rig = Rig(initial: Fake.three)
        rig.host.attached = Fake.four
        rig.coordinator.displaysChanged()

        rig.clock.advance(by: 0.25)
        XCTAssertEqual(rig.host.topologyChangedCount, 0)
        XCTAssertEqual(rig.host.opened, [])
        XCTAssertEqual(rig.host.rehomed, [])

        rig.clock.advance(by: 0.25)
        XCTAssertEqual(rig.host.topologyChangedCount, 1)
        XCTAssertEqual(rig.host.opened, [Fake.airPlayUUID])
    }

    func test_a_late_notification_in_a_burst_pushes_the_pass_out_again() {
        let rig = Rig(initial: Fake.three)
        rig.host.attached = Fake.four
        rig.coordinator.displaysChanged()
        rig.clock.advance(by: 0.25)
        rig.coordinator.displaysChanged()
        rig.clock.advance(by: 0.5)                 // 0.75 s after the first, 0.5 s after the last
        XCTAssertEqual(rig.host.topologyChangedCount, 1)
        XCTAssertEqual(rig.host.openBatches.count, 1)
    }

    func test_launch_seeding_makes_a_noise_notification_do_nothing() {
        let rig = Rig(initial: Fake.three)
        rig.notify()

        XCTAssertEqual(rig.host.rehomed, [])
        XCTAssertEqual(rig.host.opened, [])
        XCTAssertEqual(rig.host.closed, [])
        XCTAssertEqual(rig.host.topologyChangedCount, 0)
        XCTAssertEqual(rig.host.passFinishedCount, 0)
        XCTAssertLessThanOrEqual(rig.host.logs.filter { $0.contains("unchanged") }.count, 1)
    }

    func test_many_noise_notifications_after_launch_stay_quiet_in_the_log() {
        let rig = Rig(initial: Fake.three)
        for _ in 0..<(DisplayTopologyState.unchangedLogInterval - 1) { rig.notify() }

        XCTAssertEqual(rig.host.rehomed, [])
        XCTAssertEqual(rig.host.topologyChangedCount, 0)
        XCTAssertLessThanOrEqual(rig.host.logs.count, 1, "a flapping system must not flood the log")
    }

    func test_without_launch_seeding_the_first_notification_is_treated_as_a_change() {
        let clock = VirtualClock()
        let host = FakeHost(attached: Fake.three)
        let coordinator = DisplayTopologyCoordinator(scheduler: clock, host: host.makeHost())
        coordinator.displaysChanged()
        clock.advance(by: 0.5)
        XCTAssertEqual(host.topologyChangedCount, 1)
        XCTAssertEqual(host.rehomed.sorted(), Fake.three.map(\.uuid).sorted())
    }

    func test_a_missing_window_for_an_attached_display_is_opened_by_the_next_notification_without_a_rehome() {
        // Handled topology is all three, but the Dell has no window (lost by other means).
        let clock = VirtualClock()
        let host = FakeHost(attached: [Fake.builtIn, Fake.lg])
        let coordinator = DisplayTopologyCoordinator(scheduler: clock, host: host.makeHost())
        coordinator.recordHandled(Fake.three)
        host.attached = Fake.three                  // Dell present in the OS, no window, fingerprint as handled
        coordinator.displaysChanged()
        clock.advance(by: 0.5)

        XCTAssertEqual(host.opened, [Fake.dell.uuid])
        XCTAssertEqual(host.rehomed, [])
    }
}

// MARK: - Sequence replay (the logged bug)

final class DisplayTopologyReplayTests: XCTestCase {

    /// The logged sequence: three displays, then AirPlay "Flex Room" attaches,
    /// is hit with a storm of no-change events, vanishes, flaps and is unplugged.
    func test_replaying_the_logged_sequence_does_one_rehome_pass_per_real_change_and_never_recreates_a_returning_window() {
        let rig = Rig(initial: Fake.three)
        let host = rig.host
        let air = Fake.airPlayUUID
        var expectedRehomes = 0

        // 1. Flex Room attaches: a real change. One window opened, the three existing re-homed once.
        rig.setAttached(Fake.four)
        expectedRehomes += 3
        XCTAssertEqual(host.opened, [air])
        XCTAssertNotNil(host.windows[air])
        XCTAssertEqual(host.rehomed.count, expectedRehomes)
        XCTAssertEqual(host.topologyChangedCount, 1)

        // 2. A storm of events with nothing changed does nothing at all.
        for _ in 0..<60 { rig.clock.advance(by: 1); rig.notify() }
        XCTAssertEqual(host.rehomed.count, expectedRehomes)
        XCTAssertEqual(host.opened, [air])
        XCTAssertEqual(host.closed, [])
        XCTAssertEqual(host.topologyChangedCount, 1)
        XCTAssertEqual(host.passFinishedCount, 1)

        // 3. Flex Room vanishes. Surviving windows re-homed once; nothing closed before the grace.
        rig.setAttached(Fake.three)
        expectedRehomes += 3
        XCTAssertEqual(host.rehomed.count, expectedRehomes)
        XCTAssertFalse(host.rehomed.suffix(3).contains(air), "the vanished window gets no re-home grant")
        XCTAssertEqual(host.closed, [])

        //    "removed" again and noise while absent, still inside the grace.
        for _ in 0..<4 { rig.clock.advance(by: 0.5); rig.notify() }   // ~4 s since the pass
        XCTAssertEqual(host.closed, [], "not closed before the 5 s grace")
        rig.clock.advance(by: 1.5)
        XCTAssertEqual(host.closeCount(of: air), 1, "closed exactly once after the grace")
        XCTAssertNil(host.windows[air])

        //    More noise while absent: still exactly one close, no churn.
        for _ in 0..<10 { rig.clock.advance(by: 1); rig.notify() }
        XCTAssertEqual(host.closeCount(of: air), 1)
        XCTAssertEqual(host.rehomed.count, expectedRehomes)
        XCTAssertEqual(host.opened, [air])

        // 4. It comes back (the window was closed, so a new one is opened) ...
        rig.setAttached(Fake.four)
        expectedRehomes += 3
        XCTAssertEqual(host.openCount(of: air), 2)
        let windowAfterReturn = host.windows[air]
        XCTAssertNotNil(windowAfterReturn)
        XCTAssertEqual(host.rehomed.count, expectedRehomes)

        //    ... then flaps: gone for 2 s and back inside the grace. No close, no reopen.
        rig.setAttached(Fake.three)
        expectedRehomes += 3
        rig.clock.advance(by: 2)
        rig.setAttached(Fake.four)
        expectedRehomes += 4                         // the return is a real change; every window survived it
        XCTAssertEqual(host.rehomed.count, expectedRehomes)
        rig.clock.advance(by: 30)
        XCTAssertEqual(host.closeCount(of: air), 1, "no new close for a display that returned within the grace")
        XCTAssertEqual(host.openCount(of: air), 2, "no second open for the returning display")
        XCTAssertEqual(host.windows[air], windowAfterReturn, "the window is untouched, not recreated")

        // 5. Three-display noise (frames unchanged): no work.
        for _ in 0..<10 { rig.clock.advance(by: 1); rig.notify() }
        XCTAssertEqual(host.rehomed.count, expectedRehomes)

        // 6. A real unplug after the grace closes exactly once.
        rig.setAttached(Fake.three)
        expectedRehomes += 3
        rig.clock.advance(by: 4)
        XCTAssertEqual(host.closeCount(of: air), 1)
        rig.clock.advance(by: 2)
        XCTAssertEqual(host.closeCount(of: air), 2, "the second real unplug closes once more")
        rig.clock.advance(by: 60)
        XCTAssertEqual(host.closeCount(of: air), 2)

        // 7. A burst of events straddling a real change: one pass, one re-home per surviving window.
        for i in 0..<5 {
            if i == 2 { host.attached = Fake.four }
            rig.coordinator.displaysChanged()
            rig.clock.advance(by: 0.25)
        }
        rig.clock.advance(by: 1)
        expectedRehomes += 3                         // the three bound windows; AirPlay is opened, not re-homed
        XCTAssertEqual(host.openCount(of: air), 3)
        XCTAssertEqual(host.rehomed.count, expectedRehomes)

        // Totals across the whole replay: real changes x surviving windows, nothing more.
        XCTAssertEqual(host.rehomed.count, 3 + 3 + 3 + 3 + 4 + 3 + 3)
        XCTAssertEqual(host.closed.filter { $0 != air }, [], "no other display was ever closed")
    }

    func test_a_flap_within_the_grace_neither_closes_nor_reopens_the_window() {
        let rig = Rig(initial: Fake.four)
        let before = rig.host.windows[Fake.airPlayUUID]

        rig.setAttached(Fake.three)
        rig.clock.advance(by: 2)
        XCTAssertEqual(rig.host.closed, [])
        rig.setAttached(Fake.four)
        rig.clock.advance(by: 60)

        XCTAssertEqual(rig.host.closed, [])
        XCTAssertEqual(rig.host.opened, [])
        XCTAssertEqual(rig.host.windows[Fake.airPlayUUID], before)
    }

    func test_flap_away_back_away_closes_once_measured_from_the_last_departure() {
        let rig = Rig(initial: Fake.four)

        rig.setAttached(Fake.three)                  // away at t=0.5 (first close due ~5.5)
        rig.clock.advance(by: 2)
        rig.setAttached(Fake.four)                   // back
        rig.clock.advance(by: 1)
        rig.setAttached(Fake.three)                  // away again; the first timer must not close early
        rig.clock.advance(by: 3)                     // past the first timer's due time, inside the second grace
        XCTAssertEqual(rig.host.closed, [], "a stale timer from the first departure must not close")

        rig.clock.advance(by: 10)
        XCTAssertEqual(rig.host.closed, [Fake.airPlayUUID])
    }

    func test_a_real_unplug_closes_the_window_once_after_the_grace_and_not_before() {
        let rig = Rig(initial: Fake.four)
        rig.setAttached(Fake.three)

        rig.clock.advance(by: 4.5)
        XCTAssertEqual(rig.host.closed, [])
        rig.clock.advance(by: 1)
        XCTAssertEqual(rig.host.closed, [Fake.airPlayUUID])
        rig.clock.advance(by: 120)
        XCTAssertEqual(rig.host.closed, [Fake.airPlayUUID])
        XCTAssertEqual(rig.host.opened, [])
    }

    func test_unplugging_the_last_display_closes_its_window_after_the_grace_only_and_rehomes_nothing() {
        let rig = Rig(initial: [Fake.builtIn])

        rig.setAttached([])
        XCTAssertEqual(rig.host.topologyChangedCount, 1)
        XCTAssertEqual(rig.host.rehomed, [], "the vanished window is not re-homed")
        XCTAssertEqual(rig.host.closed, [])

        rig.clock.advance(by: 4.5)
        XCTAssertEqual(rig.host.closed, [])
        rig.clock.advance(by: 1)
        XCTAssertEqual(rig.host.closed, [Fake.builtIn.uuid])
        XCTAssertEqual(rig.host.rehomed, [])
    }

    func test_the_last_display_returning_within_the_grace_keeps_its_window() {
        let rig = Rig(initial: [Fake.builtIn])
        let before = rig.host.windows[Fake.builtIn.uuid]

        rig.setAttached([])
        rig.clock.advance(by: 2)
        rig.setAttached([Fake.builtIn])
        rig.clock.advance(by: 60)

        XCTAssertEqual(rig.host.closed, [])
        XCTAssertEqual(rig.host.opened, [])
        XCTAssertEqual(rig.host.windows[Fake.builtIn.uuid], before)
    }
}

// MARK: - Regression: repeated "removed" for one display

/// Root cause: the old handler unbound a vanished display's window only AFTER
/// AppKit calls that can synchronously post didChangeScreenParameters, so the
/// nested handler still saw the vanished display as bound and closed/logged it
/// again. The notification handler also did its work inside AppKit's delivery.
final class DisplayTopologyReentrancyTests: XCTestCase {

    func test_a_notification_posted_from_inside_closeWindow_before_the_unbind_does_not_close_the_display_again() {
        let rig = Rig(initial: Fake.four)
        let air = Fake.airPlayUUID
        rig.host.duringClose = { [unowned rig] _ in rig.coordinator.displaysChanged() }

        rig.setAttached(Fake.three)
        rig.clock.advance(by: 60)

        XCTAssertEqual(rig.host.closeCount(of: air), 1)
        XCTAssertEqual(rig.host.opened, [])
        XCTAssertNil(rig.host.windows[air])
    }

    func test_several_notifications_posted_from_inside_closeWindow_still_close_once() {
        let rig = Rig(initial: Fake.four)
        let air = Fake.airPlayUUID
        rig.host.duringClose = { [unowned rig] _ in
            for _ in 0..<5 { rig.coordinator.displaysChanged() }
        }

        rig.setAttached(Fake.three)
        rig.clock.advance(by: 60)

        XCTAssertEqual(rig.host.closeCount(of: air), 1)
        XCTAssertEqual(rig.host.opened, [])
    }

    func test_reentrant_notifications_do_not_close_once_per_real_vanish_more_than_once_across_repeated_unplugs() {
        let rig = Rig(initial: Fake.four)
        let air = Fake.airPlayUUID
        rig.host.duringClose = { [unowned rig] _ in rig.coordinator.displaysChanged() }

        for cycle in 1...3 {
            rig.setAttached(Fake.three)
            rig.clock.advance(by: 30)
            XCTAssertEqual(rig.host.closeCount(of: air), cycle, "one close per real vanish (cycle \(cycle))")
            rig.setAttached(Fake.four)
            rig.clock.advance(by: 30)
            XCTAssertEqual(rig.host.openCount(of: air), cycle, "one reopen per return (cycle \(cycle))")
        }
    }

    func test_the_handler_does_no_window_work_inside_the_notification_itself() {
        let rig = Rig(initial: Fake.three)
        rig.host.attached = Fake.four
        rig.coordinator.displaysChanged()

        XCTAssertEqual(rig.host.topologyChangedCount, 0)
        XCTAssertEqual(rig.host.rehomed, [])
        XCTAssertEqual(rig.host.opened, [])
        XCTAssertEqual(rig.host.closed, [])
        XCTAssertEqual(rig.host.logs, [])
    }

    func test_a_stale_binding_that_is_never_unbound_is_not_closed_repeatedly_by_noise_inside_the_grace() {
        let rig = Rig(initial: Fake.four)
        let air = Fake.airPlayUUID
        rig.host.unbindsOnClose = false

        rig.setAttached(Fake.three)
        for _ in 0..<3 { rig.clock.advance(by: 0.5); rig.notify() }   // ~3 s of events, inside the 5 s grace
        XCTAssertEqual(rig.host.closed, [])

        rig.clock.advance(by: 10)
        XCTAssertEqual(rig.host.closeCount(of: air), 1, "one scheduled close, however many events arrived")
        XCTAssertEqual(rig.host.opened, [])
    }

    func test_a_stale_binding_is_not_closed_again_without_any_further_notification() {
        let rig = Rig(initial: Fake.four)
        rig.host.unbindsOnClose = false

        rig.setAttached(Fake.three)
        rig.clock.advance(by: 10)
        XCTAssertEqual(rig.host.closeCount(of: Fake.airPlayUUID), 1)

        rig.clock.advance(by: 600)
        XCTAssertEqual(rig.host.closeCount(of: Fake.airPlayUUID), 1, "no timer keeps re-closing on its own")
    }

    func test_a_stale_binding_with_a_reentrant_close_does_not_loop_forever() {
        let rig = Rig(initial: Fake.four)
        rig.host.unbindsOnClose = false
        rig.host.duringClose = { [unowned rig] _ in rig.coordinator.displaysChanged() }

        rig.setAttached(Fake.three)
        rig.clock.advance(by: 600)

        XCTAssertLessThanOrEqual(rig.host.closeCount(of: Fake.airPlayUUID), 1,
                                 "a close that re-posts the notification must not re-trigger itself every grace period")
    }
}

// MARK: - Coordinator: a burst that never goes quiet

final class DisplayTopologyStarvationTests: XCTestCase {

    func test_a_steady_stream_of_notifications_is_still_handled_after_the_max_settle_delay() {
        let rig = Rig(initial: Fake.three)
        rig.host.attached = Fake.four

        // One notification every 0.25 s for 10 s: never quiet for the 0.5 s settle.
        for _ in 0..<40 {
            rig.coordinator.displaysChanged()
            rig.clock.advance(by: 0.25)
        }

        XCTAssertGreaterThanOrEqual(rig.host.topologyChangedCount, 1, "the stream must not starve the handler")
        XCTAssertEqual(rig.host.opened, [Fake.airPlayUUID], "the attached display is opened exactly once despite the stream")
    }

    func test_the_max_settle_delay_does_not_run_a_second_pass_for_a_burst_already_handled() {
        let rig = Rig(initial: Fake.three)
        rig.host.attached = Fake.four

        rig.coordinator.displaysChanged()
        rig.clock.advance(by: 10)

        XCTAssertEqual(rig.host.topologyChangedCount, 1)
        XCTAssertEqual(rig.host.passFinishedCount, 1)
    }
}

// MARK: - PR #254 review fix-ups

private func seededState(_ displays: [DisplayInfo] = Fake.three) -> DisplayTopologyState {
    var state = DisplayTopologyState()
    state.recordHandled(displays)
    return state
}

private func keySet(_ displays: [DisplayInfo]) -> Set<String> { Set(displays.map(\.uuid)) }

private func expectPass(_ decision: DisplayTopologyState.Decision,
                        file: StaticString = #filePath, line: UInt = #line) -> DisplayTopologyState.Pass? {
    guard case .pass(let p) = decision else {
        XCTFail("expected a pass, got \(decision)", file: file, line: line)
        return nil
    }
    return p
}

// MARK: B1: a close the host does not carry out must not orphan the window

/// `graceExpired` returning true records the close as ordered. If the host then
/// bails (the display came back, the window is already gone) and the state is never
/// told, every later `reconcile` that finds the display absent and the key bound
/// returns `.unchanged` forever: the window is orphaned.
final class DisplayTopologyAbortedCloseStateTests: XCTestCase {

    private let away = [Fake.builtIn, Fake.lg]          // Dell vanished
    private var bound: Set<String> { keySet(Fake.three) }

    func test_an_aborted_close_lets_the_next_pass_schedule_a_fresh_close_for_the_still_bound_vanished_key() {
        var state = seededState()
        guard let p1 = expectPass(state.reconcile(attached: away, bound: bound)),
              let close = p1.scheduleClose.first else { return }
        XCTAssertTrue(state.graceExpired(close, displayStillAttached: false))

        state.closeAborted(close)

        XCTAssertFalse(state.isCloseCurrent(close), "an aborted close is no longer the current close")
        XCTAssertFalse(state.hasOutstandingClose(for: Fake.dell.uuid))
        guard let p2 = expectPass(state.reconcile(attached: away, bound: bound)) else { return }
        XCTAssertEqual(p2.scheduleClose.map(\.uuid), [Fake.dell.uuid], "the vanished, still-bound window gets a fresh grace")
        XCTAssertNotEqual(p2.scheduleClose.first?.token, close.token)
    }

    /// Documented contrast: this is the bug. Without `closeAborted` the ordered close
    /// stays on the books and the window is never scheduled again.
    func test_without_closeAborted_an_ordered_close_blocks_every_later_schedule_for_that_key() {
        var state = seededState()
        guard let p1 = expectPass(state.reconcile(attached: away, bound: bound)),
              let close = p1.scheduleClose.first else { return }
        XCTAssertTrue(state.graceExpired(close, displayStillAttached: false))

        XCTAssertEqual(state.reconcile(attached: away, bound: bound), .unchanged(shouldLog: true))
        XCTAssertEqual(state.reconcile(attached: away, bound: bound), .unchanged(shouldLog: false))
        XCTAssertTrue(state.isCloseCurrent(close))
        XCTAssertTrue(state.hasOutstandingClose(for: Fake.dell.uuid))
    }

    func test_aborting_a_superseded_close_does_not_cancel_the_newer_one() {
        var state = seededState()
        guard let p1 = expectPass(state.reconcile(attached: away, bound: bound)),
              let first = p1.scheduleClose.first else { return }
        XCTAssertTrue(state.graceExpired(first, displayStillAttached: false))

        // The display returns (the ordered close is forgotten), then vanishes again.
        _ = state.reconcile(attached: Fake.three, bound: bound)
        guard let p3 = expectPass(state.reconcile(attached: away, bound: bound)),
              let second = p3.scheduleClose.first else { return }
        XCTAssertTrue(state.graceExpired(second, displayStillAttached: false))
        XCTAssertFalse(state.isCloseCurrent(first), "superseded")
        XCTAssertTrue(state.isCloseCurrent(second))

        state.closeAborted(first)                      // a stale abort
        XCTAssertTrue(state.isCloseCurrent(second), "a stale abort must not clear the newer close")

        state.closeAborted(second)
        XCTAssertFalse(state.isCloseCurrent(second))
        XCTAssertFalse(state.hasOutstandingClose(for: Fake.dell.uuid))
    }

    func test_a_close_waiting_out_its_grace_counts_as_outstanding_until_it_resolves() {
        var state = seededState()
        guard let p1 = expectPass(state.reconcile(attached: away, bound: bound)),
              let close = p1.scheduleClose.first else { return }
        XCTAssertTrue(state.hasOutstandingClose(for: Fake.dell.uuid))
        XCTAssertFalse(state.hasOutstandingClose(for: Fake.lg.uuid))

        XCTAssertFalse(state.graceExpired(close, displayStillAttached: true))
        XCTAssertFalse(state.hasOutstandingClose(for: Fake.dell.uuid), "grace expired with the display attached: nothing outstanding")
    }
}

// MARK: S1: re-home a window macOS moved even when the topology fingerprint did not change

final class DisplayTopologyDriftStateTests: XCTestCase {

    func test_a_drifted_window_gets_exactly_one_rehome_grant_when_the_fingerprint_is_unchanged() {
        var state = seededState()
        guard let p = expectPass(state.reconcile(attached: Fake.three, bound: keySet(Fake.three),
                                                 drifted: [Fake.dell.uuid])) else { return }
        XCTAssertEqual(p.rehome, [Fake.dell.uuid], "only the drifted window; the healthy ones get no grant")
        XCTAssertEqual(p.open, [])
        XCTAssertEqual(p.scheduleClose, [])
        XCTAssertEqual(p.cancelledClose, [])
    }

    func test_several_drifted_windows_are_each_granted_once_in_sorted_order() {
        var state = seededState()
        guard let p = expectPass(state.reconcile(attached: Fake.three, bound: keySet(Fake.three),
                                                 drifted: [Fake.lg.uuid, Fake.dell.uuid])) else { return }
        XCTAssertEqual(p.rehome, [Fake.dell.uuid, Fake.lg.uuid].sorted())
    }

    func test_once_the_window_is_back_the_next_unchanged_event_does_nothing_again() {
        var state = seededState()
        _ = state.reconcile(attached: Fake.three, bound: keySet(Fake.three), drifted: [Fake.dell.uuid])

        XCTAssertEqual(state.reconcile(attached: Fake.three, bound: keySet(Fake.three), drifted: []),
                       .unchanged(shouldLog: true))
    }

    func test_an_unchanged_topology_with_nothing_drifted_is_still_unchanged() {
        var state = seededState()
        XCTAssertEqual(state.reconcile(attached: Fake.three, bound: keySet(Fake.three), drifted: []),
                       .unchanged(shouldLog: true))
    }

    func test_a_drifted_key_that_has_no_window_is_ignored() {
        var state = seededState()
        XCTAssertEqual(state.reconcile(attached: Fake.three, bound: keySet(Fake.three), drifted: ["NO-SUCH-WINDOW"]),
                       .unchanged(shouldLog: true))
    }

    func test_a_drifted_window_whose_display_vanished_is_not_re_homed_it_is_being_closed() {
        var state = seededState([Fake.builtIn, Fake.lg])            // handled topology: Dell already gone
        guard let p = expectPass(state.reconcile(attached: [Fake.builtIn, Fake.lg], bound: keySet(Fake.three),
                                                 drifted: [Fake.dell.uuid])) else { return }
        XCTAssertEqual(p.scheduleClose.map(\.uuid), [Fake.dell.uuid])
        XCTAssertEqual(p.rehome, [], "a window being closed gets no grant")
    }

    func test_a_drifted_window_is_not_granted_twice_when_the_fingerprint_changed_too() {
        var state = seededState()
        let moved = [Fake.builtIn, Fake.lg, Fake.moved(Fake.dell, by: 50)]
        guard let p = expectPass(state.reconcile(attached: moved, bound: keySet(Fake.three),
                                                 drifted: [Fake.dell.uuid])) else { return }
        XCTAssertEqual(p.rehome, Fake.three.map(\.uuid).sorted(), "one grant per surviving window, no duplicates")
    }
}

final class DisplayTopologyDriftCoordinatorTests: XCTestCase {

    /// Display Dell vanishes and returns inside the 0.5 s settle: by the time the pass
    /// runs the fingerprint equals the handled one, but macOS moved Dell's window.
    private func flapInsideSettle(_ rig: Rig) {
        rig.host.attached = [Fake.builtIn, Fake.lg]
        rig.coordinator.displaysChanged()
        rig.clock.advance(by: 0.25)
        rig.host.attached = Fake.three
        rig.coordinator.displaysChanged()
        rig.clock.advance(by: 0.5)
    }

    func test_a_flap_inside_the_settle_that_left_a_window_moved_re_homes_exactly_that_window_once() {
        let rig = Rig(initial: Fake.three)
        rig.host.drifted = [Fake.dell.uuid]

        flapInsideSettle(rig)
        rig.clock.advance(by: 30)

        XCTAssertEqual(rig.host.rehomed, [Fake.dell.uuid], "one grant for the moved window, none for the healthy ones")
        XCTAssertEqual(rig.host.closed, [])
        XCTAssertEqual(rig.host.opened, [])
    }

    func test_a_flapping_noise_event_with_nothing_drifted_re_homes_nothing() {
        let rig = Rig(initial: Fake.three)

        flapInsideSettle(rig)
        rig.clock.advance(by: 30)

        XCTAssertEqual(rig.host.rehomed, [])
        XCTAssertEqual(rig.host.closed, [])
        XCTAssertEqual(rig.host.opened, [])
    }

    func test_drift_is_read_afresh_on_every_pass() {
        let rig = Rig(initial: Fake.three)
        rig.host.drifted = [Fake.lg.uuid]
        rig.notify()
        XCTAssertEqual(rig.host.rehomed, [Fake.lg.uuid])

        rig.host.drifted = []
        rig.notify()
        XCTAssertEqual(rig.host.rehomed, [Fake.lg.uuid], "no new grant once nothing is drifted")

        rig.host.drifted = [Fake.builtIn.uuid]
        rig.notify()
        XCTAssertEqual(rig.host.rehomed, [Fake.lg.uuid, Fake.builtIn.uuid])
    }
}

// MARK: S2: a doomed window must not stay alive during the grace

final class DisplayTopologyPendingRemovalTests: XCTestCase {

    private let air = Fake.airPlayUUID
    private let grace = DisplayTopologyCoordinator.defaultCloseGrace
    private let deferral = DisplayTopologyCoordinator.defaultCloseDeferralInterval
    private let limit = DisplayTopologyCoordinator.defaultCloseDeferralLimit

    /// The vanish pass has run (clock at its settle time); the next `grace` seconds are the grace.
    private func vanish(_ rig: Rig) { rig.setAttached(Fake.three) }

    /// Collapses consecutive duplicate calls so the assertions do not depend on redundant repeats.
    private func flagTransitions(_ host: FakeHost) -> [FakeHost.PendingRemovalCall] {
        var out: [FakeHost.PendingRemovalCall] = []
        for call in host.pendingRemovalCalls where out.last != call { out.append(call) }
        return out
    }

    func test_the_doomed_window_is_flagged_as_soon_as_its_close_is_scheduled_and_no_survivor_ever_is() {
        let rig = Rig(initial: Fake.four)

        vanish(rig)

        XCTAssertEqual(rig.host.pendingRemoval, [air])
        XCTAssertEqual(flagTransitions(rig.host), [.init(uuid: air, pending: true)])
        XCTAssertEqual(rig.host.closed, [], "flagged, not yet closed: that waits out the grace")

        rig.clock.advance(by: 60)
        XCTAssertTrue(rig.host.pendingRemovalCalls.allSatisfy { $0.uuid == air }, "surviving windows are never flagged")
    }

    func test_the_flag_is_cleared_when_the_display_returns_within_the_grace() {
        let rig = Rig(initial: Fake.four)
        vanish(rig)
        rig.clock.advance(by: 2)

        rig.setAttached(Fake.four)

        XCTAssertEqual(rig.host.pendingRemoval, [], "the window lives on: it may enter full-screen again")
        XCTAssertEqual(flagTransitions(rig.host), [.init(uuid: air, pending: true), .init(uuid: air, pending: false)])
        rig.clock.advance(by: 60)
        XCTAssertEqual(rig.host.closed, [])
    }

    func test_the_flag_is_cleared_when_the_grace_expires_and_the_display_is_attached_again() {
        let rig = Rig(initial: Fake.four)
        vanish(rig)
        rig.host.attached = Fake.four                   // back, with no notification

        rig.clock.advance(by: grace)

        XCTAssertEqual(rig.host.closed, [])
        XCTAssertEqual(rig.host.pendingRemoval, [])
        XCTAssertEqual(flagTransitions(rig.host).last, FakeHost.PendingRemovalCall(uuid: air, pending: false))
    }

    func test_the_flag_is_cleared_when_the_close_is_aborted_because_the_window_is_already_gone() {
        let rig = Rig(initial: Fake.four)
        vanish(rig)
        rig.host.dropWindow(air)

        rig.clock.advance(by: grace)

        XCTAssertEqual(rig.host.closed, [])
        XCTAssertEqual(rig.host.pendingRemoval, [])
        XCTAssertEqual(flagTransitions(rig.host).last, FakeHost.PendingRemovalCall(uuid: air, pending: false))
    }

    func test_a_flapping_display_is_flagged_again_each_time_it_goes_away() {
        let rig = Rig(initial: Fake.four)
        vanish(rig)
        rig.clock.advance(by: 1)
        rig.setAttached(Fake.four)
        rig.clock.advance(by: 1)
        rig.setAttached(Fake.three)

        XCTAssertEqual(flagTransitions(rig.host), [.init(uuid: air, pending: true),
                                                   .init(uuid: air, pending: false),
                                                   .init(uuid: air, pending: true)])
        XCTAssertEqual(rig.host.pendingRemoval, [air])
    }

    func test_another_windows_transition_does_not_defer_the_close() {
        let rig = Rig(initial: Fake.four)
        rig.host.transitioning = [Fake.builtIn.uuid, Fake.lg.uuid]    // siblings, not the doomed window
        vanish(rig)

        rig.clock.advance(by: grace - deferral)
        XCTAssertEqual(rig.host.closed, [], "not before the grace")
        rig.clock.advance(by: deferral)

        XCTAssertEqual(rig.host.closed, [air], "closed at the grace, siblings' transitions notwithstanding")
    }

    func test_the_doomed_windows_own_transition_defers_the_close_until_it_ends() {
        let rig = Rig(initial: Fake.four)
        rig.host.transitioning = [air]
        vanish(rig)

        rig.clock.advance(by: grace)                    // the grace has just expired
        XCTAssertEqual(rig.host.closed, [], "the window is mid-transition: deferred")
        rig.clock.advance(by: deferral)
        XCTAssertEqual(rig.host.closed, [])
        XCTAssertEqual(rig.host.pendingRemoval, [air], "still doomed while the close is deferred")

        rig.host.transitioning = []
        rig.clock.advance(by: deferral * 2)

        XCTAssertEqual(rig.host.closeCount(of: air), 1)
        rig.clock.advance(by: 60)
        XCTAssertEqual(rig.host.closeCount(of: air), 1)
    }

    /// Closing a full-screen window no longer drops its mask first, so the only protection
    /// against closing mid-transition is this deferral: its timings are part of the contract.
    func test_a_vanishing_display_mid_full_screen_transition_waits_it_out_and_closes_once_with_unchanged_timings() {
        XCTAssertEqual(grace, 5, "close grace")
        XCTAssertEqual(deferral, 0.5, "close deferral interval")
        XCTAssertEqual(limit, 6, "close deferral limit")

        let rig = Rig(initial: Fake.four)
        rig.host.transitioning = [air]                  // the doomed window is mid full-screen transition
        vanish(rig)

        rig.clock.advance(by: grace - 0.25)
        XCTAssertEqual(rig.host.closed, [], "not before the grace")
        rig.clock.advance(by: 0.25 + deferral * 3)      // grace expired, three deferrals later
        XCTAssertEqual(rig.host.closed, [], "never closed while its own transition is in flight")

        rig.host.transitioning = []                     // the transition ends
        rig.clock.advance(by: deferral)
        XCTAssertEqual(rig.host.closeCount(of: air), 1, "closed on the next deferral check after the transition ends")

        rig.clock.advance(by: 60)
        XCTAssertEqual(rig.host.closeCount(of: air), 1, "exactly once")
    }

    func test_a_transition_that_never_ends_defers_the_close_a_bounded_number_of_times_then_closes_anyway() {
        let rig = Rig(initial: Fake.four)
        rig.host.transitioning = [air]
        vanish(rig)
        rig.clock.advance(by: grace)

        rig.clock.advance(by: deferral * Double(limit - 1))
        XCTAssertEqual(rig.host.closed, [], "still within the deferral bound")

        rig.clock.advance(by: deferral * 2)
        XCTAssertEqual(rig.host.closed, [air], "forced close at the bound")
        rig.clock.advance(by: 60)
        XCTAssertEqual(rig.host.closeCount(of: air), 1, "the deferral chain ends with the close")
    }

    func test_the_deferral_interval_and_limit_are_the_coordinators_parameters() {
        let clock = VirtualClock()
        let host = FakeHost(attached: Fake.four)
        let coordinator = DisplayTopologyCoordinator(scheduler: clock, host: host.makeHost(),
                                                     closeDeferralInterval: 1, closeDeferralLimit: 2)
        coordinator.recordHandled(Fake.four)
        host.transitioning = [air]
        host.attached = Fake.three
        coordinator.displaysChanged()
        clock.advance(by: 0.5)                          // the vanish pass
        clock.advance(by: grace)                        // grace expires: deferral 1

        clock.advance(by: 1.5)
        XCTAssertEqual(host.closed, [], "deferral 2 at +1 s")
        clock.advance(by: 1)                            // +2.5 s
        XCTAssertEqual(host.closed, [air], "limit of 2 deferrals reached: closed at +2 s")
    }
}

// MARK: B1: end to end, the window is never orphaned

final class DisplayTopologyOrphanedWindowTests: XCTestCase {

    private let air = Fake.airPlayUUID
    private let grace = DisplayTopologyCoordinator.defaultCloseGrace
    private let deferral = DisplayTopologyCoordinator.defaultCloseDeferralInterval

    func test_a_display_returning_exactly_when_the_deferral_fires_does_not_orphan_the_window_if_it_goes_again() {
        let rig = Rig(initial: Fake.four)
        rig.host.transitioning = [air]                  // the doomed window is mid-transition at grace expiry
        rig.setAttached(Fake.three)
        rig.clock.advance(by: grace)                    // grace expires; the close is deferred
        XCTAssertEqual(rig.host.closed, [])

        rig.host.attached = Fake.four                   // back exactly when the deferral timer fires; no notification
        rig.clock.advance(by: deferral)
        XCTAssertEqual(rig.host.closed, [], "the display is back: the close is abandoned")

        rig.host.attached = Fake.three                  // flaps away and back, no reconcile in between
        rig.host.attached = Fake.four
        rig.clock.advance(by: 0.25)

        rig.host.attached = Fake.three                  // gone again
        rig.host.transitioning = []
        rig.notify()                                    // ... and a notification arrives
        XCTAssertEqual(rig.host.closed, [], "a fresh grace starts: not closed at once")
        rig.clock.advance(by: grace - deferral)
        XCTAssertEqual(rig.host.closed, [], "not before the fresh grace elapses")
        rig.clock.advance(by: deferral)

        XCTAssertEqual(rig.host.closeCount(of: air), 1, "the window is closed after a fresh grace, never orphaned")
        XCTAssertNil(rig.host.windows[air])
    }

    func test_a_window_that_vanished_by_other_means_is_not_closed_and_a_later_rebound_key_still_is() {
        let rig = Rig(initial: Fake.four)
        rig.setAttached(Fake.three)
        rig.host.dropWindow(air)                        // gone by another route before the grace ends

        rig.clock.advance(by: grace)
        XCTAssertEqual(rig.host.closed, [], "no window for the key: closeWindow is not called")

        rig.host.addWindow(air)                         // a window for the key exists again, display still gone
        rig.notify()
        rig.clock.advance(by: grace - deferral)
        XCTAssertEqual(rig.host.closed, [])
        rig.clock.advance(by: deferral)

        XCTAssertEqual(rig.host.closeCount(of: air), 1, "the later vanish of the re-bound key still closes it")
    }

    func test_a_stale_deferral_chain_does_nothing_after_its_close_was_superseded() {
        let rig = Rig(initial: Fake.four)
        rig.host.transitioning = [air]
        rig.setAttached(Fake.three)                     // t=0.5, grace due 5.5
        rig.clock.advance(by: 4.75)                     // t=5.25
        rig.coordinator.displaysChanged()               // a pass is due at 5.75
        rig.clock.advance(by: 0.25)                     // t=5.5: the grace expires, deferred to 6.0
        XCTAssertEqual(rig.host.closed, [])

        rig.host.attached = Fake.four                   // returns before the deferral timer
        rig.host.transitioning = []
        rig.clock.advance(by: 0.25)                     // t=5.75: the pass sees the display back

        rig.host.attached = Fake.three                  // vanishes again: a NEW close with a fresh grace
        rig.coordinator.displaysChanged()
        rig.clock.advance(by: 0.5)                      // t=6.25: the stale timer fired at 6.0, then the pass ran
        XCTAssertEqual(rig.host.closed, [], "the superseded deferral chain must not close the window")

        rig.clock.advance(by: 4.75)                     // t=11.0, just before the fresh grace (due 11.25)
        XCTAssertEqual(rig.host.closed, [], "the fresh grace is measured from the new vanish")
        rig.clock.advance(by: 0.5)
        XCTAssertEqual(rig.host.closeCount(of: air), 1)
    }
}

// MARK: N1: teardown order

final class VanishedWindowTeardownTests: XCTestCase {

    private static let unbindSteps = ["unbindKey", "dropController", "removeFromWindows", "afterUnbind"]
    private static let appKitSteps = ["prepareWindow", "close"]

    private func steps(_ record: @escaping (String) -> Void,
                       unbindKey: (() -> Void)? = nil,
                       prepareWindow: (() -> Void)? = nil,
                       close: (() -> Void)? = nil) -> VanishedWindowTeardown.Steps {
        VanishedWindowTeardown.Steps(
            unbindKey: { record("unbindKey"); unbindKey?() },
            dropController: { record("dropController") },
            removeFromWindows: { record("removeFromWindows") },
            afterUnbind: { record("afterUnbind") },
            prepareWindow: { record("prepareWindow"); prepareWindow?() },
            close: { record("close"); close?() })
    }

    func test_teardown_runs_every_step_once_in_the_contracted_order() {
        var order: [String] = []
        VanishedWindowTeardown.run(steps { order.append($0) })
        XCTAssertEqual(order, ["unbindKey", "dropController", "removeFromWindows", "afterUnbind",
                               "prepareWindow", "close"])
    }

    func test_no_appkit_facing_step_runs_before_the_key_is_unbound() {
        var order: [String] = []
        VanishedWindowTeardown.run(steps { order.append($0) })

        for appKit in Self.appKitSteps {
            guard let a = order.firstIndex(of: appKit) else { return XCTFail("\(appKit) never ran") }
            for unbind in Self.unbindSteps {
                guard let u = order.firstIndex(of: unbind) else { return XCTFail("\(unbind) never ran") }
                XCTAssertLessThan(u, a, "\(unbind) must precede \(appKit)")
            }
        }
    }

    func test_a_reentrant_notification_from_preparing_or_closing_finds_the_key_already_unbound() {
        var bound = true
        var boundSeenDuringPrepare: Bool?
        var boundSeenDuringClose: Bool?

        VanishedWindowTeardown.run(steps(
            { _ in },
            unbindKey: { bound = false },
            prepareWindow: { boundSeenDuringPrepare = bound },
            close: { boundSeenDuringClose = bound }))

        XCTAssertEqual(boundSeenDuringPrepare, false, "a handler re-entered while preparing the window must not see the key bound")
        XCTAssertEqual(boundSeenDuringClose, false, "a handler re-entered by close() must not see the key bound")
    }
}
