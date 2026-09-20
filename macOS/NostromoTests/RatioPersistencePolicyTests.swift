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
///
/// `isUserDrag` (added on a second adherence pass) is the positive signal
/// that a divider was actually under the operator's mouse button: a window
/// resize, a fullscreen transition, and a display reconfiguration all fire
/// the exact same `NSSplitView.didResizeSubviewsNotification` a divider drag
/// does, and `isProgrammatic` alone cannot distinguish any of them from an
/// operator's deliberate choice, because none of them are programmatic
/// either. Most tests below pass `isUserDrag: true` specifically so they
/// still isolate and exercise whichever *other* guard they're named after,
/// rather than being trivially satisfied by the drag guard alone.
final class RatioPersistencePolicyTests: XCTestCase {

    // MARK: 1. The regression case: the operator's actual corrupted value

    func testTheObservedCollapsedRatio977022MustNeverBePersisted() {
        // The literal value read straight off `defaults read com.hammer.nostromo`
        // for the corrupted operator whose report started this fix: the detail
        // region had collapsed to a near-zero-width pane, and because that
        // ratio had already been written to disk, it outranked every
        // subsequent daemon-broadcast ratio forever. `0.022` is comfortably
        // under `minimumShare` (0.05) — this is exactly the shape the
        // minimum-share guard exists to catch. `isUserDrag: true` because the
        // operator really did drag to produce this value — the low-share
        // guard, not the drag guard, is what must catch it.
        XCTAssertFalse(
            RatioPersistencePolicy.shouldPersist(ratios: [0.977, 0.022], total: 800, isProgrammatic: false, isUserDrag: true),
            "a near-zero-width pane (0.022 share) must never be persisted as the operator's deliberate choice"
        )
    }

    // MARK: 2. Plausible, balanced ratios dragged by the operator are persisted

    func testEvenlySplitRatiosDraggedByTheOperatorArePersisted() {
        XCTAssertTrue(RatioPersistencePolicy.shouldPersist(ratios: [0.5, 0.5], total: 800, isProgrammatic: false, isUserDrag: true))
    }

    func testModeratelyUnevenRatiosDraggedByTheOperatorAreStillPersisted() {
        // 0.4 is well above minimumShare — a deliberate, usable drag, not a
        // near-collapse.
        XCTAssertTrue(RatioPersistencePolicy.shouldPersist(ratios: [0.6, 0.4], total: 800, isProgrammatic: false, isUserDrag: true))
    }

    // MARK: 3. isUserDrag: false always refuses, even with no other red flags —
    // this is the regression this pass of the fix actually closes: a window
    // resize, fullscreen toggle, or display reconfiguration is neither
    // programmatic nor operator-chosen, but used to slip past the old
    // signature (which only ever checked `isProgrammatic`) and get persisted
    // anyway.

    func testWindowResizeFullscreenOrDisplayReconfigurationWithNoDividerDragIsNeverPersisted() {
        // Plausible, well-formed, perfectly balanced ratios — everything the
        // old signature checked says "persist this." The only thing that
        // distinguishes this from an operator's deliberate drag is that no
        // divider was ever under the mouse, which is exactly what
        // `isUserDrag: false` represents here (a window resize, a fullscreen
        // transition, and a display reconfiguration all reduce to this same
        // "no divider drag happened" case for this pure function).
        XCTAssertFalse(RatioPersistencePolicy.shouldPersist(ratios: [0.5, 0.5], total: 800, isProgrammatic: false, isUserDrag: false))
    }

    // MARK: 4. isProgrammatic always refuses, regardless of how plausible the ratios look

    func testProgrammaticApplicationIsNeverPersistedEvenWithPlausibleRatiosAndADragSignal() {
        // Whatever resize notification our own applyRatios/RatioSplitView.layout()
        // triggers is not an operator drag, full stop — even a perfectly
        // balanced 50/50 split must be refused when isProgrammatic is true,
        // because otherwise our own programmatic re-application could
        // re-enter the write path and stomp a value the operator never chose.
        // `isUserDrag: true` here is the defensive, shouldn't-happen-in-practice
        // case (mouse down on a divider *and* a programmatic apply at once) —
        // deliberately chosen so this test actually exercises the
        // `isProgrammatic` guard on its own, rather than being trivially
        // satisfied by `isUserDrag` being false.
        XCTAssertFalse(RatioPersistencePolicy.shouldPersist(ratios: [0.5, 0.5], total: 800, isProgrammatic: true, isUserDrag: true))
    }

    // MARK: 5. total <= 0 refuses to persist — no real geometry to have chosen a ratio from

    func testZeroTotalRefusesToPersistEvenWithPlausibleDraggedRatios() {
        XCTAssertFalse(RatioPersistencePolicy.shouldPersist(ratios: [0.5, 0.5], total: 0, isProgrammatic: false, isUserDrag: true))
    }

    func testNegativeTotalRefusesToPersistEvenWithPlausibleDraggedRatios() {
        XCTAssertFalse(RatioPersistencePolicy.shouldPersist(ratios: [0.5, 0.5], total: -100, isProgrammatic: false, isUserDrag: true))
    }

    // MARK: 6. Any ratio below minimumShare refuses, even if the set sums to ~1.0

    func testASetSummingToOneWithOneShareBelowMinimumIsRefused() {
        // 0.04 < minimumShare (0.05) — sums cleanly to 1.0, but one pane would
        // have no grabbable divider edge and effectively no visible content.
        // "Reset Layout" clears the whole saved set rather than repairing a
        // single bad value, so persisting a share this small would strand the
        // operator in a layout they can't escape from by dragging.
        XCTAssertFalse(RatioPersistencePolicy.shouldPersist(ratios: [0.96, 0.04], total: 800, isProgrammatic: false, isUserDrag: true))
    }

    // MARK: 7. Degenerate ratio counts refuse without trapping

    func testEmptyRatiosArrayIsRefusedWithoutTrapping() {
        XCTAssertFalse(RatioPersistencePolicy.shouldPersist(ratios: [], total: 800, isProgrammatic: false, isUserDrag: true))
    }

    func testSingleElementRatiosArrayIsRefusedWithoutTrapping() {
        // A single child has no divider to drag — there is no "choice" here
        // to persist, regardless of the (trivially valid-looking) value.
        XCTAssertFalse(RatioPersistencePolicy.shouldPersist(ratios: [1.0], total: 800, isProgrammatic: false, isUserDrag: true))
    }
}
