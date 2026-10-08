import XCTest
import AppKit

// FollowTailPolicy is compiled into this target directly (logic test).

/// Reproduces the "pane stops following the tail" bug against a real
/// `NSScrollView` + `NSClipView` (the transcript's geometry, minus the turns),
/// so the claim "a resize posts a bounds change while the document is already
/// taller than the viewport's bottom" is checked against AppKit rather than
/// assumed.
final class FollowTailClipViewTests: XCTestCase {

    private final class FlippedClip: NSClipView { override var isFlipped: Bool { true } }
    private final class FlippedDoc: NSView { override var isFlipped: Bool { true } }

    private var window: NSWindow!
    private var scrollView: NSScrollView!
    private var clip: FlippedClip!
    private var observer: NSObjectProtocol?

    /// The virtualizer's cached height — grows on append, before any pass.
    private var documentHeight: CGFloat = 2000

    /// Pinned state under the new policy vs. the pre-fix "recompute on every
    /// bounds change" formula, both fed by the same notifications.
    private var pinned = true
    private var legacyPinned = true
    private var lastBounds: NSRect = .zero

    override func setUp() {
        super.setUp()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        clip = FlippedClip()
        scrollView.contentView = clip
        scrollView.hasVerticalScroller = true
        let doc = FlippedDoc(frame: NSRect(x: 0, y: 0, width: 400, height: 2000))
        scrollView.documentView = doc
        window.contentView = scrollView
        clip.postsBoundsChangedNotifications = true
        scrollToBottom()
        lastBounds = clip.bounds
        observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: nil
        ) { [unowned self] _ in
            let bounds = self.clip.bounds
            self.pinned = FollowTailPolicy.pinnedAfterBoundsChange(
                current: self.pinned, previousBounds: self.lastBounds, bounds: bounds,
                isMaterializing: false, documentHeight: self.documentHeight)
            self.legacyPinned = self.documentHeight - bounds.maxY < 40
            self.lastBounds = bounds
        }
        pinned = true
        legacyPinned = true
    }

    override func tearDown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        window = nil
        super.tearDown()
    }

    private func scrollToBottom() {
        clip.scroll(to: NSPoint(x: 0, y: documentHeight - clip.bounds.height))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Taller pane while parked at the bottom: AppKit moves the clip origin *up*
    /// to stay inside the document — the same direction as a user scrolling up,
    /// which is why direction alone can't be the signal.
    func testGrowingThePaneAfterAppendedTurnsKeepsAPinnedPaneFollowingButOldRuleLostIt() {
        XCTAssertEqual(clip.bounds.maxY, 2000, accuracy: 1, "precondition: parked at the bottom")

        documentHeight += 400                          // turns appended; no pass has scrolled yet
        window.setContentSize(NSSize(width: 400, height: 380))   // input bar shrank, split restored…

        XCTAssertLessThan(clip.bounds.origin.y, 1700, "AppKit clamped the origin up")
        XCTAssertTrue(pinned, "a resize is not the operator scrolling away")
        XCTAssertFalse(legacyPinned, "repro: the pre-fix formula read the same event as 'scrolled away'")
    }

    func testShrinkingThePaneAfterAppendedTurnsKeepsAPinnedPaneFollowing() {
        documentHeight += 400
        window.setContentSize(NSSize(width: 400, height: 220))

        XCTAssertTrue(pinned)
    }

    func testProgrammaticDocumentGrowthAndStrayBoundsEventKeepsFollowing() {
        documentHeight += 400
        // A bounds notification with no movement and no resize (layout churn, re-show).
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: clip)
        XCTAssertTrue(pinned)
        XCTAssertFalse(legacyPinned)
    }

    func testOperatorDraggingUpUnpinsAndDraggingBackDownRepins() {
        clip.scroll(to: NSPoint(x: 0, y: 800))         // scroller drag / wheel: origin moves, size doesn't
        scrollView.reflectScrolledClipView(clip)
        XCTAssertFalse(pinned)

        documentHeight += 400                           // output arrives while reading history
        clip.scroll(to: NSPoint(x: 0, y: 820))          // still far from the bottom
        XCTAssertFalse(pinned, "growth alone must not re-pin a reader")

        clip.scroll(to: NSPoint(x: 0, y: documentHeight - clip.bounds.height))
        XCTAssertTrue(pinned, "back at the bottom re-arms following")
    }
}
