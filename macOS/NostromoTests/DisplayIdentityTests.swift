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

    /// Everything stored in this test's isolated suite.
    private func snapshot() -> NSDictionary {
        NSDictionary(dictionary: defaults.persistentDomain(forName: suiteName) ?? [:])
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

    func test_the_consumed_flag_is_per_window_index() {
        XCTAssertEqual(DisplayFocusKeys.migratedFlagKey(windowIndex: 0), "nostromo.displayFocusKeysMigrated.v2.window0")
        XCTAssertEqual(DisplayFocusKeys.migratedFlagKey(windowIndex: 2), "nostromo.displayFocusKeysMigrated.v2.window2")
    }

    func test_calling_the_migration_again_with_the_same_displays_changes_nothing() {
        setLegacy(0, "focus-a")
        setLegacy(1, "focus-b")
        XCTAssertEqual(DisplayFocusKeys.migrateLegacyKeys(onto: [Fake.main, Fake.aboveLeft], defaults: defaults), 2)
        let after = snapshot()

        let second = DisplayFocusKeys.migrateLegacyKeys(onto: [Fake.main, Fake.aboveLeft], defaults: defaults)

        XCTAssertEqual(second, 0)
        XCTAssertEqual(snapshot(), after)
    }

    func test_a_legacy_value_changed_after_it_was_consumed_is_not_copied_again() {
        setLegacy(0, "focus-a")
        DisplayFocusKeys.migrateLegacyKeys(onto: [Fake.main], defaults: defaults)

        // The user picks something else; the (unchanged-in-spirit) legacy key is edited and the UUID key vanishes.
        defaults.removeObject(forKey: DisplayFocusKeys.activeTabKey(displayUUID: Fake.main.uuid))
        setLegacy(0, "stale-legacy")

        let second = DisplayFocusKeys.migrateLegacyKeys(onto: [Fake.main], defaults: defaults)

        XCTAssertEqual(second, 0)
        XCTAssertNil(migrated(Fake.main), "a consumed index must never be migrated a second time")
    }

    func test_a_partial_display_set_migrates_only_its_own_indices_and_the_full_set_later_loses_nothing() {
        setLegacy(0, "focus-a")
        setLegacy(1, "focus-b")
        setLegacy(2, "focus-c")

        // First launch: only the laptop panel is awake.
        let first = DisplayFocusKeys.migrateLegacyKeys(onto: [Fake.main], defaults: defaults)
        XCTAssertEqual(first, 1)
        XCTAssertEqual(migrated(Fake.main), "focus-a")
        XCTAssertNil(migrated(Fake.aboveLeft))
        XCTAssertNil(migrated(Fake.aboveRight))

        // The user changes the first display's focus in the meantime.
        defaults.set("user-choice", forKey: DisplayFocusKeys.activeTabKey(displayUUID: Fake.main.uuid))

        // Later launch: all three are attached.
        let second = DisplayFocusKeys.migrateLegacyKeys(
            onto: [Fake.main, Fake.aboveLeft, Fake.aboveRight], defaults: defaults)

        XCTAssertEqual(second, 2, "only the two indices that were not available the first time")
        XCTAssertEqual(migrated(Fake.main), "user-choice", "index 0 was consumed and must not be re-copied")
        XCTAssertEqual(migrated(Fake.aboveLeft), "focus-b")
        XCTAssertEqual(migrated(Fake.aboveRight), "focus-c")
    }

    func test_indices_beyond_the_display_count_are_not_consumed() {
        setLegacy(0, "focus-a")
        setLegacy(1, "focus-b")

        DisplayFocusKeys.migrateLegacyKeys(onto: [Fake.main], defaults: defaults)

        XCTAssertTrue(defaults.bool(forKey: DisplayFocusKeys.migratedFlagKey(windowIndex: 0)))
        XCTAssertFalse(defaults.bool(forKey: DisplayFocusKeys.migratedFlagKey(windowIndex: 1)))
        XCTAssertFalse(defaults.bool(forKey: DisplayFocusKeys.migratedFlagKey(windowIndex: 2)))
    }

    func test_an_existing_uuid_value_is_never_clobbered_and_still_consumes_its_index() {
        setLegacy(0, "legacy-a")
        defaults.set("already-there", forKey: DisplayFocusKeys.activeTabKey(displayUUID: Fake.main.uuid))

        let copied = DisplayFocusKeys.migrateLegacyKeys(onto: [Fake.main], defaults: defaults)

        XCTAssertEqual(copied, 0)
        XCTAssertEqual(migrated(Fake.main), "already-there")
        XCTAssertTrue(defaults.bool(forKey: DisplayFocusKeys.migratedFlagKey(windowIndex: 0)))

        // A different display later occupies index 0: the consumed index is not migrated onto it.
        let later = DisplayFocusKeys.migrateLegacyKeys(onto: [Fake.aboveRight], defaults: defaults)

        XCTAssertEqual(later, 0)
        XCTAssertNil(migrated(Fake.aboveRight))
    }

    func test_empty_display_list_does_nothing_and_consumes_no_index() {
        setLegacy(0, "focus-a")
        setLegacy(1, "focus-b")

        XCTAssertEqual(DisplayFocusKeys.migrateLegacyKeys(onto: [], defaults: defaults), 0)
        XCTAssertFalse(defaults.bool(forKey: DisplayFocusKeys.migratedFlagKey(windowIndex: 0)),
                       "a launch with no displays must not use up the migration")
        XCTAssertFalse(defaults.bool(forKey: DisplayFocusKeys.migratedFlagKey(windowIndex: 1)))

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

// MARK: - Duplicate / missing display UUIDs

final class DisplayDisambiguationTests: XCTestCase {

    private func display(_ uuid: String, number: UInt32, name: String = "Panel", main: Bool = false) -> DisplayInfo {
        DisplayInfo(
            uuid: uuid, screenNumber: number,
            frame: CGRect(x: Int(number) * 2000, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: Int(number) * 2000, y: 0, width: 1920, height: 1055),
            backingScaleFactor: 2, localizedName: name, isMain: main)
    }

    private func keys(_ displays: [DisplayInfo]) -> [String] { displays.map(\.uuid) }

    func test_displays_that_report_the_same_uuid_get_distinct_keys() {
        let result = DisplayInfo.disambiguated([
            display("DUP", number: 1), display("DUP", number: 2), display("DUP", number: 3)])

        XCTAssertEqual(keys(result), ["DUP", "DUP#2", "DUP#3"])
    }

    func test_the_first_display_keeps_the_bare_uuid_whatever_follows_it() {
        let alone = DisplayInfo.disambiguated([display("DUP", number: 1)])
        let withTwin = DisplayInfo.disambiguated([display("DUP", number: 1), display("DUP", number: 2)])
        let withOthers = DisplayInfo.disambiguated([
            display("DUP", number: 1), display("OTHER", number: 5), display("DUP", number: 2)])

        XCTAssertEqual(alone.first?.uuid, "DUP")
        XCTAssertEqual(withTwin.first?.uuid, "DUP")
        XCTAssertEqual(withOthers.first?.uuid, "DUP")
        XCTAssertEqual(keys(withOthers), ["DUP", "OTHER", "DUP#2"])
    }

    func test_a_missing_uuid_falls_back_to_a_screen_number_token() {
        let result = DisplayInfo.disambiguated([display("", number: 7)])

        XCTAssertEqual(keys(result), ["display-number-7"])
    }

    func test_two_displays_with_missing_uuids_still_get_distinct_keys() {
        let result = DisplayInfo.disambiguated([display("", number: 7), display("", number: 7)])

        XCTAssertEqual(keys(result), ["display-number-7", "display-number-7#2"])
    }

    func test_input_without_duplicates_comes_back_unchanged() {
        let input = [display("A", number: 1, main: true), display("B", number: 2), display("C", number: 3)]

        XCTAssertEqual(DisplayInfo.disambiguated(input), input)
    }

    func test_an_empty_list_stays_empty() {
        XCTAssertEqual(DisplayInfo.disambiguated([]), [])
    }

    func test_order_and_every_other_property_are_preserved() {
        let a = display("DUP", number: 1, name: "Left", main: true)
        let b = display("DUP", number: 2, name: "Right")

        let result = DisplayInfo.disambiguated([a, b])

        XCTAssertEqual(result.map(\.screenNumber), [1, 2])
        for (original, changed) in zip([a, b], result) {
            XCTAssertEqual(changed.frame, original.frame)
            XCTAssertEqual(changed.visibleFrame, original.visibleFrame)
            XCTAssertEqual(changed.backingScaleFactor, original.backingScaleFactor)
            XCTAssertEqual(changed.localizedName, original.localizedName)
            XCTAssertEqual(changed.isMain, original.isMain)
        }
    }

    func test_keys_are_always_unique_even_when_a_suffixed_key_collides_with_a_real_one() {
        let inputs: [[DisplayInfo]] = [
            [display("A", number: 1), display("A", number: 2), display("A#2", number: 3)],
            [display("A", number: 1), display("A#2", number: 2), display("A", number: 3)],
            [display("A#2", number: 1), display("A", number: 2), display("A", number: 3), display("A", number: 4)],
        ]

        for input in inputs {
            let result = DisplayInfo.disambiguated(input)
            XCTAssertEqual(result.count, input.count)
            XCTAssertEqual(Set(keys(result)).count, input.count, "duplicate key in \(keys(result))")
            XCTAssertEqual(result.map(\.screenNumber), input.map(\.screenNumber))
        }
    }

    func test_applying_it_twice_gives_the_same_result_as_once() {
        let input = [display("DUP", number: 1), display("", number: 7), display("DUP", number: 2),
                     display("", number: 7), display("OTHER", number: 3)]

        let once = DisplayInfo.disambiguated(input)

        XCTAssertEqual(DisplayInfo.disambiguated(once), once)
    }

    // MARK: Reconciler with duplicates

    func test_the_plan_never_opens_two_windows_for_the_same_key_and_the_first_wins() {
        let first = display("DUP", number: 1)
        let second = display("DUP", number: 2)

        let plan = DisplayReconciler.plan(attached: [first, second], boundUUIDs: [])

        XCTAssertEqual(plan.toOpen, [first])
    }

    func test_two_displays_sharing_a_raw_uuid_both_get_a_window_once_disambiguated() {
        let attached = DisplayInfo.disambiguated([display("DUP", number: 1), display("DUP", number: 2)])

        let plan = DisplayReconciler.plan(attached: attached, boundUUIDs: [])

        XCTAssertEqual(plan.toOpen.count, 2)
        XCTAssertEqual(Set(plan.toOpen.map(\.uuid)).count, 2)
        XCTAssertEqual(plan.toOpen.map(\.screenNumber), [1, 2])
        XCTAssertEqual(plan.toClose, [])
    }

    func test_once_both_duplicate_keys_are_bound_the_next_plan_is_empty() {
        let attached = DisplayInfo.disambiguated([display("DUP", number: 1), display("DUP", number: 2)])
        let firstPlan = DisplayReconciler.plan(attached: attached, boundUUIDs: [])

        let second = DisplayReconciler.plan(attached: attached, boundUUIDs: Set(firstPlan.toOpen.map(\.uuid)))

        XCTAssertEqual(second, DisplayReconciler.Plan(toClose: [], toOpen: []), "both windows tracked: nothing to open or close")
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

// MARK: - Stable display count recorder

final class StableDisplayCountRecorderTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var scheduler: QueueScheduler!
    private var count = 3
    private var recorder: StableDisplayCountRecorder!

    override func setUp() {
        super.setUp()
        suiteName = UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)
        scheduler = QueueScheduler()
        count = 3
        recorder = StableDisplayCountRecorder(
            scheduler: scheduler, screenCount: { [unowned self] in self.count }, defaults: defaults)
    }

    override func tearDown() {
        recorder = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private var recorded: Int { LastKnownDisplayCount.load(defaults: defaults) }

    /// The checks armed so far, oldest first, without firing them.
    private func armedChecks() -> [() -> Void] { scheduler.scheduled.map(\.work) }

    func test_nothing_is_recorded_until_the_settle_interval_elapses() {
        recorder.topologyChanged()

        XCTAssertEqual(recorded, 0)
        XCTAssertEqual(scheduler.scheduled.count, 1)
    }

    func test_the_check_is_armed_after_the_settle_interval() {
        recorder.topologyChanged()
        XCTAssertEqual(scheduler.scheduled.map(\.delay), [3.0], "default settle")

        let custom = StableDisplayCountRecorder(
            scheduler: scheduler, screenCount: { 2 }, defaults: defaults, settle: 7.5)
        custom.topologyChanged()
        XCTAssertEqual(scheduler.scheduled.map(\.delay).last, 7.5)
    }

    func test_the_count_at_check_time_is_recorded_not_the_count_at_change_time() {
        count = 2
        recorder.topologyChanged()
        count = 3                       // a slow display finished waking during the settle interval

        scheduler.fireAll()

        XCTAssertEqual(recorded, 3)
    }

    func test_a_burst_of_changes_records_only_the_final_stable_count() {
        recorder.topologyChanged()      // 3
        let afterFirst = armedChecks()[0]
        count = 1
        recorder.topologyChanged()      // 1
        let afterSecond = armedChecks()[1]
        count = 3
        recorder.topologyChanged()      // back to 3
        XCTAssertEqual(scheduler.scheduled.count, 3)

        count = 1                       // would be wrong if an early check ran against it
        afterFirst()
        afterSecond()
        XCTAssertEqual(recorded, 0, "superseded checks must do nothing")

        count = 3
        armedChecks()[2]()
        XCTAssertEqual(recorded, 3)
    }

    func test_a_transient_drop_that_recovers_inside_the_settle_interval_never_records_the_drop() {
        LastKnownDisplayCount.record(3, defaults: defaults)
        count = 1
        recorder.topologyChanged()      // an external blinks off
        let transientCheck = armedChecks()[0]
        count = 3
        recorder.topologyChanged()      // and comes back

        transientCheck()                // fires while the count is back to 3, but it is superseded either way
        XCTAssertEqual(recorded, 3)
        count = 1
        transientCheck()                // even if it ran against the dropped count, it is stale
        XCTAssertEqual(recorded, 3, "the transient 1 must never be recorded")

        count = 3
        scheduler.fireAll()
        XCTAssertEqual(recorded, 3)
    }

    func test_a_count_of_zero_is_never_recorded() {
        LastKnownDisplayCount.record(3, defaults: defaults)
        count = 0
        recorder.topologyChanged()

        scheduler.fireAll()

        XCTAssertEqual(recorded, 3)
    }

    func test_a_later_stable_change_records_again() {
        recorder.topologyChanged()
        scheduler.fireAll()
        XCTAssertEqual(recorded, 3)

        count = 2
        recorder.topologyChanged()
        scheduler.fireAll()

        XCTAssertEqual(recorded, 2)
    }
}
