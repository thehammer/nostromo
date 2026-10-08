import XCTest
import AppKit

// JumpToLatestOverlay, FollowTailPolicy, OverlayHitTest and Theme are compiled into this target directly.

/// The "Jump to latest" pill: visible only while a pane is not following the
/// tail, clickable, and never swallowing clicks meant for what lies beneath.
final class JumpToLatestOverlayTests: XCTestCase {

    /// A 600x400 parent. Left to right / bottom to top:
    ///  - sidebar        (0,0)-(100,400)
    ///  - input bar      (100,0)-(600,40)
    ///  - transcript     (100,40)-(600,400)
    ///  - overlay on top (100,40)-(600,400): non-zero origin in its parent.
    private struct Scene {
        let parent: NSView
        let sidebar: NSView
        let inputBar: NSView
        let transcript: NSView
        let overlay: JumpToLatestOverlay
    }

    private func makeScene(following: Bool) -> Scene {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 400))
        let inputBar = NSView(frame: NSRect(x: 100, y: 0, width: 500, height: 40))
        let transcript = NSView(frame: NSRect(x: 100, y: 40, width: 500, height: 360))
        let overlay = JumpToLatestOverlay(frame: NSRect(x: 100, y: 40, width: 500, height: 360))
        [sidebar, inputBar, transcript, overlay].forEach { parent.addSubview($0) }
        overlay.setFollowingTail(following)
        overlay.layoutSubtreeIfNeeded()
        overlay.layout()
        return Scene(parent: parent, sidebar: sidebar, inputBar: inputBar,
                     transcript: transcript, overlay: overlay)
    }

    /// The centre of the pill, in the parent's coordinates.
    private func pillCenter(_ scene: Scene) -> NSPoint {
        let f = scene.overlay.button.frame
        return scene.overlay.convert(NSPoint(x: f.midX, y: f.midY), to: scene.parent)
    }

    // MARK: - Visibility follows the pane's following state

    func testPillIsHiddenWhileFollowingAndShownWhenNot() {
        let overlay = JumpToLatestOverlay(frame: NSRect(x: 0, y: 0, width: 500, height: 360))
        XCTAssertTrue(overlay.button.isHidden, "a new pane follows the tail")

        overlay.setFollowingTail(false)
        XCTAssertFalse(overlay.button.isHidden)

        overlay.setFollowingTail(true)
        XCTAssertTrue(overlay.button.isHidden)
    }

    // MARK: - Clicking

    func testClickingThePillInvokesOnJumpExactlyOnce() {
        let overlay = JumpToLatestOverlay(frame: NSRect(x: 0, y: 0, width: 500, height: 360))
        overlay.setFollowingTail(false)
        var jumps = 0
        overlay.onJump = { jumps += 1 }

        overlay.button.performClick(nil)

        XCTAssertEqual(jumps, 1)
    }

    // MARK: - Hit testing: only the pill takes clicks

    func testClickOnThePillHitsThePill() {
        let scene = makeScene(following: false)
        XCTAssertTrue(scene.parent.hitTest(pillCenter(scene)) === scene.overlay.button)
    }

    func testClicksElsewhereInTheOverlayFallThroughToWhatLiesBeneath() {
        let scene = makeScene(following: false)

        // Top-left and middle of the overlay: the transcript underneath.
        XCTAssertTrue(scene.parent.hitTest(NSPoint(x: 120, y: 380)) === scene.transcript)
        XCTAssertTrue(scene.parent.hitTest(NSPoint(x: 350, y: 220)) === scene.transcript)
        // Just under the pill, still inside the overlay.
        XCTAssertTrue(scene.parent.hitTest(NSPoint(x: pillCenter(scene).x, y: 44)) === scene.transcript)
        // The input bar region (below the overlay).
        XCTAssertTrue(scene.parent.hitTest(NSPoint(x: 350, y: 20)) === scene.inputBar)
        // Never the overlay itself.
        for point in [NSPoint(x: 120, y: 380), NSPoint(x: 350, y: 220), NSPoint(x: 350, y: 20)] {
            let hit = scene.parent.hitTest(point)
            XCTAssertFalse(hit === scene.overlay)
            XCTAssertFalse(hit === scene.overlay.button)
        }
    }

    func testOverlayWithNonZeroOriginDoesNotSwallowClicksOutsideItsFrame() {
        // The sidebar "+" regression (#185): the overlay sits right of the
        // sidebar, so hit points must be read in the parent's coordinates.
        let scene = makeScene(following: false)
        XCTAssertTrue(scene.parent.hitTest(NSPoint(x: 50, y: 60)) === scene.sidebar)

        // A point that lands on the pill only if the overlay's origin is ignored
        // (pill local frame ~ x 344...476, y 12...38) must reach the input bar.
        let pill = scene.overlay.button.frame
        let naive = NSPoint(x: pill.midX, y: pill.midY)
        XCTAssertTrue(scene.parent.hitTest(naive) === scene.inputBar,
                      "parent point \(naive) is below the overlay, over the input bar")
    }

    func testWhileFollowingEvenThePillsFormerFrameFallsThrough() {
        let scene = makeScene(following: true)
        let hit = scene.parent.hitTest(pillCenter(scene))
        XCTAssertTrue(hit === scene.transcript)
        XCTAssertFalse(hit === scene.overlay.button)
    }

    func testPillReturnsToTakingClicksWhenFollowingStopsAgain() {
        let scene = makeScene(following: true)
        scene.overlay.setFollowingTail(false)
        XCTAssertTrue(scene.parent.hitTest(pillCenter(scene)) === scene.overlay.button)
    }

    // MARK: - Independence

    func testOverlaysKeepIndependentStatePerInstance() {
        let a = JumpToLatestOverlay(frame: NSRect(x: 0, y: 0, width: 500, height: 360))
        let b = JumpToLatestOverlay(frame: NSRect(x: 0, y: 0, width: 500, height: 360))
        var aJumps = 0, bJumps = 0
        a.onJump = { aJumps += 1 }
        b.onJump = { bJumps += 1 }

        a.setFollowingTail(false)
        XCTAssertFalse(a.button.isHidden)
        XCTAssertTrue(b.button.isHidden, "b's pane is still following")

        b.setFollowingTail(false)
        a.setFollowingTail(true)
        XCTAssertTrue(a.button.isHidden)
        XCTAssertFalse(b.button.isHidden)

        b.button.performClick(nil)
        XCTAssertEqual(aJumps, 0)
        XCTAssertEqual(bJumps, 1)
    }
}
