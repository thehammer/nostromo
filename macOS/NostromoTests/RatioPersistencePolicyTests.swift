import XCTest
// RatioPersistencePolicy is compiled into this target directly (logic test —
// no host app, no window). No module imports needed.

// MARK: - RatioPersistencePolicyTests

/// Behavioural tests for `RatioPersistencePolicy.shouldPersist`
/// (fix-collapsed-split-ratio-persistence).
///
/// This is the write-guard that used to not exist at all: `DynamicFocusView`'s
/// resize observer persisted every `NSSplitView.didResizeSubviewsNotification`
/// unconditionally, so a corrupt, near-collapsed ratio set — once written —
/// was authoritative forever, with every later daemon-broadcast ratio losing
/// to it. These tests pin the exact conditions under which a ratio set is
/// trusted enough to write to disk as "the operator chose this."
final class RatioPersistencePolicyTests: XCTestCase {

    // MARK: 1. The regression case: the operator's actual corrupted value

    func testTheObservedCollapsedRatio977022MustNeverBePersisted() {
        // The literal value read straight off `defaults read com.hammer.nostromo`
        // for the corrupted operator whose report started this fix: the detail
        // region had collapsed to a near-zero-width pane, and because that
        // ratio had already been written to disk, it outranked every
        // subsequent daemon-broadcast ratio forever. `0.022` is comfortably
        // under `minimumShare` (0.05) — this is exactly the shape the
        // minimum-share guard exists to catch.
        XCTAssertFalse(
            RatioPersistencePolicy.shouldPersist(ratios: [0.977, 0.022], total: 800, isProgrammatic: false),
            "a near-zero-width pane (0.022 share) must never be persisted as the operator's deliberate choice"
        )
    }

    // MARK: 2. Plausible, balanced ratios are persisted

    func testEvenlySplitRatiosArePersisted() {
        XCTAssertTrue(RatioPersistencePolicy.shouldPersist(ratios: [0.5, 0.5], total: 800, isProgrammatic: false))
    }

    func testModeratelyUnevenRatiosAreStillPersisted() {
        // 0.4 is well above minimumShare — a deliberate, usable drag, not a
        // near-collapse.
        XCTAssertTrue(RatioPersistencePolicy.shouldPersist(ratios: [0.6, 0.4], total: 800, isProgrammatic: false))
    }

    // MARK: 3. isProgrammatic always refuses, regardless of how plausible the ratios look

    func testProgrammaticApplicationIsNeverPersistedEvenWithPlausibleRatios() {
        // Whatever resize notification our own applyRatios/RatioSplitView.layout()
        // triggers is not an operator drag, full stop — even a perfectly
        // balanced 50/50 split must be refused when isProgrammatic is true,
        // because otherwise our own programmatic re-application could
        // re-enter the write path and stomp a value the operator never chose.
        XCTAssertFalse(RatioPersistencePolicy.shouldPersist(ratios: [0.5, 0.5], total: 800, isProgrammatic: true))
    }

    // MARK: 4. total <= 0 refuses to persist — no real geometry to have chosen a ratio from

    func testZeroTotalRefusesToPersistEvenWithPlausibleRatios() {
        XCTAssertFalse(RatioPersistencePolicy.shouldPersist(ratios: [0.5, 0.5], total: 0, isProgrammatic: false))
    }

    func testNegativeTotalRefusesToPersistEvenWithPlausibleRatios() {
        XCTAssertFalse(RatioPersistencePolicy.shouldPersist(ratios: [0.5, 0.5], total: -100, isProgrammatic: false))
    }

    // MARK: 5. Any ratio below minimumShare refuses, even if the set sums to ~1.0

    func testASetSummingToOneWithOneShareBelowMinimumIsRefused() {
        // 0.04 < minimumShare (0.05) — sums cleanly to 1.0, but one pane would
        // have no grabbable divider edge and effectively no visible content.
        // "Reset Layout" clears the whole saved set rather than repairing a
        // single bad value, so persisting a share this small would strand the
        // operator in a layout they can't escape from by dragging.
        XCTAssertFalse(RatioPersistencePolicy.shouldPersist(ratios: [0.96, 0.04], total: 800, isProgrammatic: false))
    }

    // MARK: 6. Degenerate ratio counts refuse without trapping

    func testEmptyRatiosArrayIsRefusedWithoutTrapping() {
        XCTAssertFalse(RatioPersistencePolicy.shouldPersist(ratios: [], total: 800, isProgrammatic: false))
    }

    func testSingleElementRatiosArrayIsRefusedWithoutTrapping() {
        // A single child has no divider to drag — there is no "choice" here
        // to persist, regardless of the (trivially valid-looking) value.
        XCTAssertFalse(RatioPersistencePolicy.shouldPersist(ratios: [1.0], total: 800, isProgrammatic: false))
    }
}
