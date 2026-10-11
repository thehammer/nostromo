import XCTest
import AppKit

// NostromoWindow.swift is compiled into this target directly. Passing `nil` for
// the screen and never showing the window keeps these independent of how many
// displays are attached (1, 2 or 3) and of their arrangement.
//
// Required behavior: before full-screen, the frame we ask for is the frame we
// get. AppKit's default constraining would shove a window onto the main display
// when it sits on a display stacked above/left of main, or when it is taller than
// a display's visible frame (the menu-bar band).

final class NostromoWindowConstrainTests: XCTestCase {

    private var window: NostromoWindow!

    override func setUp() {
        super.setUp()
        window = NostromoWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true)
    }

    override func tearDown() {
        window = nil
        super.tearDown()
    }

    private func assertUnchanged(_ proposed: NSRect, _ message: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(window.styleMask.contains(.fullScreen), "precondition: window is not full-screen",
                       file: file, line: line)
        XCTAssertEqual(window.constrainFrameRect(proposed, to: nil), proposed, message, file: file, line: line)
    }

    func test_a_frame_on_the_main_display_is_returned_unchanged() {
        assertUnchanged(NSRect(x: 0, y: 0, width: 1710, height: 1073), "frame inside the main display")
    }

    func test_a_frame_above_the_main_display_is_returned_unchanged() {
        // A display stacked above main: its y is beyond main's height.
        assertUnchanged(NSRect(x: 0, y: 1107, width: 1920, height: 1055), "frame stacked above main (y > main height)")
    }

    func test_a_frame_above_and_to_the_left_of_main_is_returned_unchanged() {
        assertUnchanged(NSRect(x: -1920, y: 1107, width: 1920, height: 1055), "frame above-left of main")
    }

    func test_a_frame_far_above_main_is_returned_unchanged() {
        assertUnchanged(NSRect(x: 0, y: 4000, width: 1920, height: 1080), "frame on a third tier of stacked displays")
    }

    func test_a_frame_to_the_left_of_main_is_returned_unchanged() {
        assertUnchanged(NSRect(x: -2560, y: 0, width: 2560, height: 1415), "frame left of main")
    }

    func test_a_frame_below_main_is_returned_unchanged() {
        assertUnchanged(NSRect(x: 0, y: -1080, width: 1920, height: 1055), "frame below main")
    }

    func test_a_frame_taller_than_any_visible_frame_is_not_shrunk() {
        // The full screen.frame includes the menu-bar band, so it is taller than visibleFrame.
        assertUnchanged(NSRect(x: 0, y: 1107, width: 1920, height: 1080), "full display frame including the menu-bar band")
        assertUnchanged(NSRect(x: 0, y: 0, width: 1710, height: 5000), "absurdly tall frame")
    }

    func test_a_frame_wider_than_any_display_is_not_shrunk() {
        assertUnchanged(NSRect(x: -3000, y: 0, width: 9000, height: 800), "absurdly wide frame")
    }

    func test_a_frame_that_straddles_two_displays_is_returned_unchanged() {
        assertUnchanged(NSRect(x: 1500, y: 900, width: 800, height: 600), "frame spanning the seam between displays")
    }

    func test_the_result_does_not_depend_on_the_screen_argument_being_nil() {
        // With a real screen (whatever is attached) the answer must still be the proposed frame.
        guard let screen = NSScreen.screens.first else { return }
        let proposed = NSRect(x: 0, y: 4000, width: 1920, height: 6000)
        XCTAssertEqual(window.constrainFrameRect(proposed, to: screen), proposed)
    }

    func test_the_unconstrained_frame_behavior_is_on_by_default() {
        XCTAssertTrue(window.allowsUnconstrainedFrame)
    }

    // MARK: Scope: only before / while entering full-screen

    private static let allPhases: [PlacementPhase] = [
        .idle, .placing(attempt: 1), .placing(attempt: 2), .placing(attempt: 3),
        .enteringFullScreen, .exitingForRetry, .fullScreen, .gaveUp,
    ]

    func test_the_frame_is_left_unconstrained_while_idle_placing_or_entering_full_screen() {
        let leaving: [PlacementPhase] = [.idle, .placing(attempt: 1), .placing(attempt: 2), .placing(attempt: 3), .enteringFullScreen]
        for phase in leaving {
            XCTAssertTrue(
                NostromoWindow.leavesFrameUnconstrained(allowsUnconstrainedFrame: true, isFullScreen: false, phase: phase),
                "\(phase)")
        }
    }

    func test_appkits_default_constraining_applies_once_the_window_is_settled_exiting_or_gave_up() {
        for phase in [PlacementPhase.exitingForRetry, .fullScreen, .gaveUp] {
            XCTAssertFalse(
                NostromoWindow.leavesFrameUnconstrained(allowsUnconstrainedFrame: true, isFullScreen: false, phase: phase),
                "\(phase)")
        }
    }

    func test_a_window_that_opted_out_is_never_left_unconstrained_in_any_phase() {
        for phase in Self.allPhases {
            XCTAssertFalse(
                NostromoWindow.leavesFrameUnconstrained(allowsUnconstrainedFrame: false, isFullScreen: false, phase: phase),
                "\(phase)")
        }
    }

    func test_a_full_screen_window_is_never_left_unconstrained_in_any_phase() {
        for phase in Self.allPhases {
            XCTAssertFalse(
                NostromoWindow.leavesFrameUnconstrained(allowsUnconstrainedFrame: true, isFullScreen: true, phase: phase),
                "\(phase)")
        }
    }

    func test_a_window_starts_in_the_idle_placement_phase() {
        XCTAssertEqual(window.placementPhase, .idle)
    }

    func test_the_window_stores_the_placement_phase_it_is_told_about() {
        for phase in Self.allPhases {
            window.placementPhaseChanged(phase)
            XCTAssertEqual(window.placementPhase, phase)
        }
    }

    func test_while_placing_or_entering_the_proposed_frame_is_returned_unchanged() {
        let proposed = NSRect(x: 0, y: 4000, width: 1920, height: 6000)
        for phase in [PlacementPhase.idle, .placing(attempt: 2), .enteringFullScreen] {
            window.placementPhaseChanged(phase)
            XCTAssertEqual(window.constrainFrameRect(proposed, to: nil), proposed, "\(phase)")
        }
    }

    /// What AppKit's own constraining returns for `proposed` (an opted-out window always defers to super).
    private func appKitsAnswer(for proposed: NSRect) -> NSRect {
        let reference = NostromoWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true)
        reference.allowsUnconstrainedFrame = false
        return reference.constrainFrameRect(proposed, to: nil)
    }

    func test_in_settled_phases_the_window_defers_to_appkit_like_an_opted_out_window() {
        let proposed = NSRect(x: 0, y: 4000, width: 1920, height: 6000)
        let expected = appKitsAnswer(for: proposed)
        for phase in [PlacementPhase.exitingForRetry, .fullScreen, .gaveUp] {
            window.placementPhaseChanged(phase)
            XCTAssertEqual(window.constrainFrameRect(proposed, to: nil), expected, "\(phase)")
        }
    }

    func test_an_opted_out_window_defers_to_appkit_even_while_placing() {
        let proposed = NSRect(x: 0, y: 4000, width: 1920, height: 6000)
        let expected = appKitsAnswer(for: proposed)
        window.allowsUnconstrainedFrame = false
        window.placementPhaseChanged(.placing(attempt: 1))

        XCTAssertEqual(window.constrainFrameRect(proposed, to: nil), expected)
    }
}
