import XCTest
import CoreGraphics

// DisplayIdentity.swift is compiled into this target directly. Nothing here
// touches NSScreen: every display is a fake `DisplayInfo`, so results do not
// depend on how many real displays the machine has.

// MARK: - Fake topology

/// Built-in laptop panel (main) plus two externals stacked ABOVE main — the
/// layout that exposed the original "everything lands on one display" bug.
private enum Fake {
    static let main = DisplayInfo(
        uuid: "UUID-MAIN", screenNumber: 1,
        frame: CGRect(x: 0, y: 0, width: 1710, height: 1107),
        visibleFrame: CGRect(x: 0, y: 0, width: 1710, height: 1073),
        localizedName: "Built-in", isMain: true)
    static let aboveLeft = DisplayInfo(
        uuid: "UUID-ABOVE-LEFT", screenNumber: 2,
        frame: CGRect(x: -1920, y: 1107, width: 1920, height: 1080),
        visibleFrame: CGRect(x: -1920, y: 1107, width: 1920, height: 1055),
        localizedName: "External L")
    static let aboveRight = DisplayInfo(
        uuid: "UUID-ABOVE-RIGHT", screenNumber: 3,
        frame: CGRect(x: 0, y: 1107, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 1107, width: 1920, height: 1080),
        localizedName: "External R")
}

// MARK: - DisplayInfo

final class DisplayInfoPlacementFrameTests: XCTestCase {

    func test_placement_frame_is_the_visible_frame_not_the_full_frame() {
        XCTAssertEqual(Fake.main.placementFrame, Fake.main.visibleFrame)
        XCTAssertNotEqual(Fake.main.placementFrame, Fake.main.frame)
    }

    func test_placement_frame_for_a_display_stacked_above_main_stays_above_main() {
        let f = Fake.aboveLeft.placementFrame
        XCTAssertEqual(f, Fake.aboveLeft.visibleFrame)
        XCTAssertGreaterThanOrEqual(f.minY, Fake.main.frame.height,
                                    "placement for a stacked display must not overlap the main display")
        XCTAssertLessThan(f.minX, 0)
    }
}

// MARK: - Focus-key migration

final class DisplayFocusKeysMigrationTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func setLegacy(_ index: Int, _ value: String) {
        defaults.set(value, forKey: DisplayFocusKeys.legacyKey(windowIndex: index))
    }

    private func migrated(_ display: DisplayInfo) -> String? {
        defaults.string(forKey: DisplayFocusKeys.activeTabKey(displayUUID: display.uuid))
    }

    func test_legacy_index_keys_are_copied_to_the_uuid_of_the_display_at_that_position() {
        setLegacy(0, "focus-a")
        setLegacy(1, "focus-b")
        setLegacy(2, "focus-c")

        let copied = DisplayFocusKeys.migrateLegacyKeys(
            onto: [Fake.main, Fake.aboveLeft, Fake.aboveRight], defaults: defaults)

        XCTAssertEqual(copied, 3)
        XCTAssertEqual(migrated(Fake.main), "focus-a")
        XCTAssertEqual(migrated(Fake.aboveLeft), "focus-b")
        XCTAssertEqual(migrated(Fake.aboveRight), "focus-c")
    }

    func test_mapping_follows_list_position_not_frame_or_screen_number() {
        // Externals first: position 0 is the display with the HIGHEST screen number.
        setLegacy(0, "first")
        setLegacy(1, "second")

        DisplayFocusKeys.migrateLegacyKeys(onto: [Fake.aboveRight, Fake.main], defaults: defaults)

        XCTAssertEqual(migrated(Fake.aboveRight), "first")
        XCTAssertEqual(migrated(Fake.main), "second")
    }

    func test_an_existing_uuid_key_is_never_overwritten() {
        setLegacy(0, "legacy-value")
        setLegacy(1, "legacy-b")
        defaults.set("already-there", forKey: DisplayFocusKeys.activeTabKey(displayUUID: Fake.main.uuid))

        let copied = DisplayFocusKeys.migrateLegacyKeys(onto: [Fake.main, Fake.aboveLeft], defaults: defaults)

        XCTAssertEqual(migrated(Fake.main), "already-there")
        XCTAssertEqual(migrated(Fake.aboveLeft), "legacy-b")
        XCTAssertEqual(copied, 1, "only the key that was actually copied is counted")
    }

    func test_migration_runs_only_once() {
        setLegacy(0, "focus-a")
        XCTAssertEqual(DisplayFocusKeys.migrateLegacyKeys(onto: [Fake.main], defaults: defaults), 1)

        // The user changes the focus on that display, and an old legacy key shows up again.
        defaults.set("user-choice", forKey: DisplayFocusKeys.activeTabKey(displayUUID: Fake.main.uuid))
        setLegacy(0, "stale-legacy")
        setLegacy(1, "focus-b")

        let second = DisplayFocusKeys.migrateLegacyKeys(onto: [Fake.main, Fake.aboveLeft], defaults: defaults)

        XCTAssertEqual(second, 0)
        XCTAssertEqual(migrated(Fake.main), "user-choice")
        XCTAssertNil(migrated(Fake.aboveLeft))
    }

    func test_empty_display_list_does_nothing_and_does_not_consume_the_one_shot() {
        setLegacy(0, "focus-a")

        XCTAssertEqual(DisplayFocusKeys.migrateLegacyKeys(onto: [], defaults: defaults), 0)
        XCTAssertFalse(defaults.bool(forKey: DisplayFocusKeys.migrationFlagKey),
                       "a launch with no displays must not use up the migration")

        // A later launch with real displays still migrates.
        XCTAssertEqual(DisplayFocusKeys.migrateLegacyKeys(onto: [Fake.main], defaults: defaults), 1)
        XCTAssertEqual(migrated(Fake.main), "focus-a")
    }

    func test_legacy_keys_are_left_in_place() {
        setLegacy(0, "focus-a")

        DisplayFocusKeys.migrateLegacyKeys(onto: [Fake.main], defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: DisplayFocusKeys.legacyKey(windowIndex: 0)), "focus-a")
    }

    func test_legacy_indices_beyond_the_display_count_are_ignored() {
        setLegacy(0, "focus-a")
        setLegacy(1, "focus-b")
        setLegacy(2, "focus-c")

        let copied = DisplayFocusKeys.migrateLegacyKeys(onto: [Fake.main], defaults: defaults)

        XCTAssertEqual(copied, 1)
        XCTAssertEqual(migrated(Fake.main), "focus-a")
        XCTAssertNil(migrated(Fake.aboveLeft))
        XCTAssertNil(migrated(Fake.aboveRight))
    }

    func test_displays_without_a_legacy_key_get_no_uuid_key() {
        setLegacy(1, "focus-b") // nothing for index 0

        let copied = DisplayFocusKeys.migrateLegacyKeys(onto: [Fake.main, Fake.aboveLeft], defaults: defaults)

        XCTAssertEqual(copied, 1)
        XCTAssertNil(migrated(Fake.main))
        XCTAssertEqual(migrated(Fake.aboveLeft), "focus-b")
    }

    func test_active_tab_keys_differ_per_display_uuid() {
        XCTAssertNotEqual(DisplayFocusKeys.activeTabKey(displayUUID: "A"),
                          DisplayFocusKeys.activeTabKey(displayUUID: "B"))
        XCTAssertEqual(DisplayFocusKeys.activeTabKey(displayUUID: "A"),
                       DisplayFocusKeys.activeTabKey(displayUUID: "A"))
    }
}

// MARK: - Reconciliation

final class DisplayReconcilerTests: XCTestCase {

    func test_a_disappeared_display_is_scheduled_to_close_and_nothing_opens() {
        let plan = DisplayReconciler.plan(
            attached: [Fake.main, Fake.aboveRight],
            boundUUIDs: [Fake.main.uuid, Fake.aboveLeft.uuid, Fake.aboveRight.uuid])

        XCTAssertEqual(plan.toClose, [Fake.aboveLeft.uuid])
        XCTAssertEqual(plan.toOpen, [])
    }

    func test_a_new_display_is_scheduled_to_open() {
        let plan = DisplayReconciler.plan(
            attached: [Fake.main, Fake.aboveLeft],
            boundUUIDs: [Fake.main.uuid])

        XCTAssertEqual(plan.toClose, [])
        XCTAssertEqual(plan.toOpen, [Fake.aboveLeft])
    }

    func test_a_reappeared_display_opens_bound_to_its_original_uuid() {
        // Unplugged, then replugged: macOS may hand it a different screen number and frame,
        // but the UUID is what identifies it.
        let replugged = DisplayInfo(
            uuid: Fake.aboveLeft.uuid, screenNumber: 99,
            frame: CGRect(x: 1710, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 1710, y: 0, width: 1920, height: 1055),
            localizedName: "External L")

        let plan = DisplayReconciler.plan(attached: [Fake.main, replugged], boundUUIDs: [Fake.main.uuid])

        XCTAssertEqual(plan.toOpen.map(\.uuid), [Fake.aboveLeft.uuid])
        XCTAssertEqual(plan.toOpen.first?.screenNumber, 99)
        XCTAssertEqual(plan.toClose, [])
    }

    func test_an_unchanged_topology_produces_an_empty_plan() {
        let plan = DisplayReconciler.plan(
            attached: [Fake.main, Fake.aboveLeft, Fake.aboveRight],
            boundUUIDs: [Fake.main.uuid, Fake.aboveLeft.uuid, Fake.aboveRight.uuid])

        XCTAssertEqual(plan, DisplayReconciler.Plan(toClose: [], toOpen: []))
    }

    func test_identity_is_the_uuid_not_the_frame_or_screen_number() {
        // Same UUID, completely different geometry and number: still "the same display".
        let moved = DisplayInfo(
            uuid: Fake.main.uuid, screenNumber: 42,
            frame: CGRect(x: 500, y: -900, width: 1000, height: 800),
            visibleFrame: CGRect(x: 500, y: -900, width: 1000, height: 780))

        let plan = DisplayReconciler.plan(attached: [moved], boundUUIDs: [Fake.main.uuid])

        XCTAssertEqual(plan, DisplayReconciler.Plan(toClose: [], toOpen: []))
    }

    func test_when_every_display_is_gone_everything_closes_and_nothing_opens() {
        let plan = DisplayReconciler.plan(
            attached: [],
            boundUUIDs: [Fake.main.uuid, Fake.aboveLeft.uuid, Fake.aboveRight.uuid])

        XCTAssertEqual(Set(plan.toClose),
                       [Fake.main.uuid, Fake.aboveLeft.uuid, Fake.aboveRight.uuid])
        XCTAssertEqual(plan.toClose.count, 3)
        XCTAssertEqual(plan.toOpen, [])
    }

    func test_no_windows_yet_opens_every_attached_display() {
        let plan = DisplayReconciler.plan(
            attached: [Fake.main, Fake.aboveLeft, Fake.aboveRight], boundUUIDs: [])

        XCTAssertEqual(plan.toClose, [])
        XCTAssertEqual(plan.toOpen.map(\.uuid), [Fake.main.uuid, Fake.aboveLeft.uuid, Fake.aboveRight.uuid])
    }

    func test_close_and_open_can_both_happen_in_one_reconfiguration() {
        let plan = DisplayReconciler.plan(
            attached: [Fake.main, Fake.aboveRight],
            boundUUIDs: [Fake.main.uuid, Fake.aboveLeft.uuid])

        XCTAssertEqual(plan.toClose, [Fake.aboveLeft.uuid])
        XCTAssertEqual(plan.toOpen, [Fake.aboveRight])
    }
}

// MARK: - Last known display count

final class LastKnownDisplayCountTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func test_nothing_recorded_loads_as_zero() {
        XCTAssertEqual(LastKnownDisplayCount.load(defaults: defaults), 0)
    }

    func test_a_recorded_count_round_trips() {
        LastKnownDisplayCount.record(3, defaults: defaults)
        XCTAssertEqual(LastKnownDisplayCount.load(defaults: defaults), 3)
    }

    func test_the_latest_positive_count_wins() {
        LastKnownDisplayCount.record(3, defaults: defaults)
        LastKnownDisplayCount.record(2, defaults: defaults)
        XCTAssertEqual(LastKnownDisplayCount.load(defaults: defaults), 2)
    }

    func test_zero_is_never_recorded_and_does_not_erase_a_previous_count() {
        LastKnownDisplayCount.record(0, defaults: defaults)
        XCTAssertEqual(LastKnownDisplayCount.load(defaults: defaults), 0)

        LastKnownDisplayCount.record(3, defaults: defaults)
        LastKnownDisplayCount.record(0, defaults: defaults)
        XCTAssertEqual(LastKnownDisplayCount.load(defaults: defaults), 3)
    }
}

// MARK: - Display availability waiter

/// Queues scheduled closures; the test decides when (and in what order) they fire.
private final class QueueScheduler: PlacementScheduler {
    private(set) var scheduled: [(delay: TimeInterval, work: () -> Void)] = []

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
        scheduled.append((delay, work))
    }

    /// Fire everything queued so far (including anything queued while firing).
    func fireAll() {
        while !scheduled.isEmpty {
            let next = scheduled.removeFirst()
            next.work()
        }
    }
}

final class DisplayAvailabilityWaiterTests: XCTestCase {

    private var scheduler: QueueScheduler!
    private var count = 1
    private var completions: [Bool] = []
    private var waiter: DisplayAvailabilityWaiter?

    override func setUp() {
        super.setUp()
        scheduler = QueueScheduler()
        count = 1
        completions = []
        waiter = nil
    }

    private func makeWaiter(expected: Int, timeout: TimeInterval = 5) {
        waiter = DisplayAvailabilityWaiter(
            expected: expected, timeout: timeout, scheduler: scheduler,
            screenCount: { [unowned self] in self.count },
            completion: { [unowned self] reached in self.completions.append(reached) })
    }

    func test_completes_with_reached_expected_as_soon_as_the_count_arrives() {
        makeWaiter(expected: 3)

        count = 2
        waiter?.screensChanged()
        XCTAssertEqual(completions, [], "still short of the expected count")

        count = 3
        waiter?.screensChanged()
        XCTAssertEqual(completions, [true])
        XCTAssertEqual(waiter?.isFinished, true)
    }

    func test_a_count_above_expected_also_counts_as_reached() {
        makeWaiter(expected: 2)
        count = 3
        waiter?.screensChanged()
        XCTAssertEqual(completions, [true])
    }

    func test_completes_with_reached_expected_false_when_the_timeout_elapses_short() {
        makeWaiter(expected: 3)
        count = 1

        scheduler.fireAll()

        XCTAssertEqual(completions, [false])
        XCTAssertEqual(waiter?.isFinished, true)
    }

    func test_the_timeout_is_armed_with_the_requested_delay() {
        makeWaiter(expected: 3, timeout: 7.5)
        XCTAssertEqual(scheduler.scheduled.map(\.delay), [7.5])
    }

    func test_timeout_after_the_count_was_reached_does_not_complete_a_second_time() {
        makeWaiter(expected: 2)
        count = 2
        waiter?.screensChanged()

        scheduler.fireAll()

        XCTAssertEqual(completions, [true])
    }

    func test_screens_changed_after_a_timeout_does_not_complete_a_second_time() {
        makeWaiter(expected: 2)
        scheduler.fireAll()
        XCTAssertEqual(completions, [false])

        count = 2
        waiter?.screensChanged()
        waiter?.screensChanged()

        XCTAssertEqual(completions, [false])
    }

    func test_repeated_screens_changed_after_reaching_the_count_completes_only_once() {
        makeWaiter(expected: 2)
        count = 2
        waiter?.screensChanged()
        waiter?.screensChanged()
        waiter?.screensChanged()
        XCTAssertEqual(completions, [true])
    }

    func test_timeout_reports_true_if_the_count_arrived_without_a_notification() {
        // The count is re-read at the deadline, so a display that came up silently still counts.
        makeWaiter(expected: 2)
        count = 2

        scheduler.fireAll()

        XCTAssertEqual(completions, [true])
    }

    func test_already_satisfied_at_the_first_screens_changed_completes_immediately_as_reached() {
        count = 2
        makeWaiter(expected: 2)

        waiter?.screensChanged()

        XCTAssertEqual(completions, [true])
    }
}
