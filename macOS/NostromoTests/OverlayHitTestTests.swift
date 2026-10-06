import XCTest
import AppKit

// OverlayHitTest is compiled into this target directly (logic test).

final class OverlayHitTestTests: XCTestCase {

    private final class Overlay: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { OverlayHitTest.hit(in: self, at: point) }
    }

    /// A 400×200 parent: a 100-wide sidebar on the left, the overlay filling
    /// the rest, with a 20pt "line" subview along the overlay's bottom edge.
    private func makeLayout() -> (parent: NSView, sidebarButton: NSView, line: NSView) {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let sidebarButton = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 32))
        let overlay = Overlay(frame: NSRect(x: 100, y: 0, width: 300, height: 200))
        let line = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 20))
        overlay.addSubview(line)
        parent.addSubview(sidebarButton)
        parent.addSubview(overlay)   // on top, like the real overlay
        return (parent, sidebarButton, line)
    }

    func testClickOnSiblingToTheLeftOfTheOverlayIsNotSwallowed() {
        let (parent, sidebarButton, _) = makeLayout()
        // Inside the sidebar button, and — in the overlay's *local* numbers — inside its line.
        XCTAssertTrue(parent.hitTest(NSPoint(x: 50, y: 10)) === sidebarButton)
    }

    func testClickOnTheOverlaysOwnSubviewHitsIt() {
        let (parent, _, line) = makeLayout()
        XCTAssertTrue(parent.hitTest(NSPoint(x: 250, y: 10)) === line)
    }

    func testClickOnEmptyOverlayAreaFallsThrough() {
        let (parent, sidebarButton, line) = makeLayout()
        let hit = parent.hitTest(NSPoint(x: 250, y: 150))
        XCTAssertFalse(hit === line)
        XCTAssertFalse(hit === sidebarButton)
    }
}
