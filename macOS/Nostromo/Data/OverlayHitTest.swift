import AppKit

/// Hit-testing for a full-area overlay that must let every click fall through
/// except those that land on one of its own subviews.
///
/// `NSView.hitTest(_:)` receives its point in the **superview's** coordinate
/// system. An overlay that pins itself to part of its parent (right of a
/// sidebar, say) has a frame origin that is not zero, so treating the incoming
/// point as local coordinates shifts the hit region by that origin: clicks on
/// the *sidebar* landed inside the overlay's line and were swallowed — the
/// sidebar's "+" opened the activity ticker instead of a new focus.
enum OverlayHitTest {
    /// The subview of `overlay` hit by `point` (given in `overlay`'s superview
    /// coordinates), or nil so the click falls through to what lies beneath.
    static func hit(in overlay: NSView, at point: NSPoint) -> NSView? {
        let local = overlay.superview.map { overlay.convert(point, from: $0) } ?? point
        for sub in overlay.subviews.reversed() where !sub.isHidden {
            if let hit = sub.hitTest(local) { return hit }
        }
        return nil
    }
}
