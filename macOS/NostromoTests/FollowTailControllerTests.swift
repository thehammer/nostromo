import XCTest
import AppKit

// FollowTailController, FollowTailPolicy, JumpToLatestOverlay, OverlayHitTest
// and Theme are compiled into this target directly (logic test, no app host).

/// Drives the REAL `FollowTailController` against a real `NSScrollView` /
/// flipped `NSClipView` / `NSWindow` / `JumpToLatestOverlay` — the same
/// geometry `ReplView` builds — so a regression in the production wiring
/// (not just in the pure `FollowTailPolicy` rule) turns these red.
///
/// Snapshot output: set `FOLLOW_TAIL_SNAPSHOT_DIR` (via xcodebuild, pass it as
/// `TEST_RUNNER_FOLLOW_TAIL_SNAPSHOT_DIR`) to also write a PNG of the un-pinned
/// pane.
final class FollowTailControllerTests: XCTestCase {

    // MARK: - Rig

    private final class FlippedClip: NSClipView { override var isFlipped: Bool { true } }
    private final class FlippedDoc: NSView { override var isFlipped: Bool { true } }

    private final class Backdrop: NSView {
        override func draw(_ dirtyRect: NSRect) {
            Theme.bg.setFill()
            dirtyRect.fill()
        }
    }

    /// A tall, solid, labelled block standing in for a turn.
    private final class RowView: NSView {
        let fill: NSColor
        init(frame: NSRect, fill: NSColor, label: String) {
            self.fill = fill
            super.init(frame: frame)
            autoresizingMask = [.width]
            let text = NSTextField(labelWithString: label)
            text.font = .systemFont(ofSize: 28, weight: .bold)
            text.textColor = .white
            text.frame = NSRect(x: 16, y: 16, width: 300, height: 40)
            addSubview(text)
        }
        required init?(coder: NSCoder) { fatalError() }
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            fill.setFill()
            bounds.insetBy(dx: 0, dy: 4).fill()
        }
    }

    private final class Rig {
        let window: NSWindow
        let container: Backdrop
        let scrollView = NSScrollView()
        let clip = FlippedClip()
        let doc = FlippedDoc()
        let overlay: JumpToLatestOverlay
        let controller: FollowTailController

        /// What the virtualizer would report. Grows on append, before any pass.
        var documentHeight: CGFloat
        var contentWidth: CGFloat = 400
        var isMaterializing = false
        var passCount = 0
        var flips: [FollowTailController.Flip] = []

        init(viewport: NSSize = NSSize(width: 400, height: 300),
             documentHeight: CGFloat = 2000,
             scrollerStyleBeforeConfigure: NSScroller.Style? = nil) {
            self.documentHeight = documentHeight
            window = NSWindow(contentRect: NSRect(origin: .zero, size: viewport),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            container = Backdrop(frame: NSRect(origin: .zero, size: viewport))
            overlay = JumpToLatestOverlay(frame: container.bounds)
            overlay.autoresizingMask = [.width, .height]

            // Same shape as ReplView: flipped clip, vertical scroller on.
            scrollView.frame = container.bounds
            scrollView.autoresizingMask = [.width, .height]
            scrollView.contentView = clip
            scrollView.drawsBackground = false
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            if let style = scrollerStyleBeforeConfigure { scrollView.scrollerStyle = style }
            doc.frame = NSRect(x: 0, y: 0, width: viewport.width, height: documentHeight)
            scrollView.documentView = doc
            container.addSubview(scrollView)
            container.addSubview(overlay, positioned: .above, relativeTo: scrollView)
            window.contentView = container

            controller = FollowTailController(scrollView: scrollView, overlay: overlay)
            controller.documentHeight = { [unowned self] in self.documentHeight }
            controller.contentWidth = { [unowned self] in self.contentWidth }
            controller.isMaterializing = { [unowned self] in self.isMaterializing }
            controller.requestPass = { [unowned self] in self.passCount += 1 }
            controller.onFlip = { [unowned self] in self.flips.append($0) }

            // Parked at the bottom, like a pane that has been following.
            controller.scrollToBottom()
            passCount = 0
            flips = []
        }

        var viewportHeight: CGFloat { clip.bounds.height }
        var bottomOriginY: CGFloat { doc.frame.height - clip.bounds.height }

        /// The operator moving the viewport: origin moves, size does not.
        func userScroll(to y: CGFloat) {
            clip.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(clip)
        }

        func settleLayout() {
            container.layoutSubtreeIfNeeded()
            scrollView.tile()
            overlay.layoutSubtreeIfNeeded()
            overlay.layout()
        }

        /// Stand-in for `ReplView`'s materialization pass: skips when there is
        /// no usable width (and says so), otherwise sizes the document and, when
        /// pinned, scrolls to the bottom (materialize step 5).
        func installFakePass() {
            controller.requestPass = { [unowned self] in
                self.passCount += 1
                self.runFakePass()
            }
        }

        private func runFakePass() {
            guard !isMaterializing else { return }
            isMaterializing = true
            defer { isMaterializing = false }
            guard contentWidth > 1 else {
                controller.notePassSkippedForWidth()
                return
            }
            doc.setFrameSize(NSSize(width: doc.frame.width, height: documentHeight))
            if controller.isPinned { controller.scrollToBottom() }
            controller.notePassRan()
        }
    }

    // MARK: - (a) A non-user bounds change never un-pins a following pane

    func testPinnedPaneStaysPinnedWhenContentGrowsAndThePaneIsResizedAndClampedUp() {
        let rig = Rig()
        XCTAssertEqual(rig.clip.bounds.maxY, 2000, accuracy: 1, "precondition: parked at the bottom")
        XCTAssertTrue(rig.controller.isPinned)

        rig.documentHeight += 400                                  // turns appended; no pass has scrolled yet
        rig.window.setContentSize(NSSize(width: 400, height: 380)) // input bar shrank, split restored...

        XCTAssertLessThan(rig.clip.bounds.origin.y, 1700, "AppKit clamped the origin up")
        // Repro: the pre-fix "recompute on every bounds change" formula would have
        // read this same event as the operator scrolling away.
        XCTAssertGreaterThanOrEqual(rig.documentHeight - rig.clip.bounds.maxY,
                                    FollowTailPolicy.pinThreshold)
        XCTAssertTrue(rig.controller.isPinned, "a resize is not the operator scrolling away")
        XCTAssertTrue(rig.overlay.button.isHidden)
        XCTAssertTrue(rig.flips.isEmpty, "no flip at all")
    }

    func testPinnedPaneStaysPinnedWhenContentGrowsAndThePaneIsShrunk() {
        let rig = Rig()
        rig.documentHeight += 400
        rig.window.setContentSize(NSSize(width: 400, height: 220))
        XCTAssertTrue(rig.controller.isPinned)
        XCTAssertTrue(rig.flips.isEmpty)
    }

    func testPinnedPaneStaysPinnedOnAStrayBoundsNotificationAfterContentGrows() {
        let rig = Rig()
        rig.documentHeight += 400
        // A bounds notification with no movement and no resize (layout churn, re-show).
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: rig.clip)
        XCTAssertTrue(rig.controller.isPinned)
        XCTAssertTrue(rig.flips.isEmpty)
    }

    func testBoundsChangeCausedByThePassItselfIsNeverOperatorIntent() {
        let rig = Rig()
        rig.documentHeight += 4000
        rig.isMaterializing = true
        rig.userScroll(to: 300)                                    // far from the bottom, moving up
        rig.isMaterializing = false
        XCTAssertTrue(rig.controller.isPinned)
    }

    // MARK: - (b) "Jump to latest" works end to end

    func testClickingJumpToLatestRepinsHidesThePillScrollsToTheBottomAndRequestsAPass() {
        let rig = Rig()
        rig.userScroll(to: 500)
        XCTAssertFalse(rig.controller.isPinned, "precondition: operator is reading history")
        XCTAssertFalse(rig.overlay.button.isHidden, "precondition: the pill is offered")
        rig.passCount = 0
        rig.flips = []

        rig.overlay.button.performClick(nil)

        XCTAssertTrue(rig.controller.isPinned)
        XCTAssertTrue(rig.overlay.button.isHidden)
        XCTAssertEqual(rig.clip.bounds.maxY, rig.doc.frame.height, accuracy: 1, "scrolled to the bottom")
        XCTAssertGreaterThanOrEqual(rig.passCount, 1, "a pass was requested")
        XCTAssertEqual(rig.flips.count, 1)
        XCTAssertEqual(rig.flips.first?.pinned, true)
        XCTAssertEqual(rig.flips.first?.cause, .jumpToLatest)
        XCTAssertNil(rig.flips.first?.originDeltaY, "not a bounds-driven flip")
        XCTAssertNil(rig.flips.first?.sizeChanged)
    }

    func testSendingRepinsAndFlipHasNoBoundsDiagnostics() {
        let rig = Rig()
        rig.userScroll(to: 500)
        rig.flips = []

        rig.controller.setPinned(true, cause: .send)

        XCTAssertTrue(rig.controller.isPinned)
        XCTAssertTrue(rig.overlay.button.isHidden)
        XCTAssertEqual(rig.flips.first?.cause, .send)
        XCTAssertNil(rig.flips.first?.originDeltaY)
        XCTAssertNil(rig.flips.first?.sizeChanged)
    }

    // MARK: - (c) A pane pinned while it could not be laid out catches up

    func testPanePinnedWhileHiddenCatchesUpToTheBottomOnceItHasWidth() {
        let rig = Rig()
        rig.installFakePass()
        rig.contentWidth = 0                                       // hidden / collapsed

        rig.controller.paneWasShown()                              // pinned: asks for a pass...
        XCTAssertEqual(rig.passCount, 1)                           // ...which finds no width and is skipped
        rig.documentHeight = 3200                                  // content keeps streaming in
        rig.passCount = 0

        rig.controller.paneMayHaveBecomeUsable()
        XCTAssertEqual(rig.passCount, 0, "still no usable width: nothing to catch up on yet")

        rig.contentWidth = 400                                     // un-hidden
        rig.controller.paneMayHaveBecomeUsable()

        XCTAssertGreaterThanOrEqual(rig.passCount, 1, "the owed pass fires")
        XCTAssertTrue(rig.controller.isPinned)
        XCTAssertEqual(rig.clip.bounds.maxY, 3200, accuracy: 1, "ends at the new bottom")

        rig.passCount = 0
        rig.controller.paneMayHaveBecomeUsable()
        XCTAssertEqual(rig.passCount, 0, "paid back once; nothing further is owed")
    }

    func testUnpinnedPaneIsNotYankedToTheBottomWhenItBecomesUsable() {
        let rig = Rig()
        rig.installFakePass()
        rig.contentWidth = 0
        rig.controller.paneWasShown()                              // pass skipped for width
        rig.userScroll(to: 500)                                    // operator scrolls away (still no width)
        XCTAssertFalse(rig.controller.isPinned)
        rig.contentWidth = 400                                     // the skipped-pass flag is still owed
        rig.passCount = 0
        rig.documentHeight = 3200

        rig.controller.paneMayHaveBecomeUsable()

        XCTAssertEqual(rig.passCount, 0)
        XCTAssertFalse(rig.controller.isPinned)
        XCTAssertEqual(rig.clip.bounds.origin.y, 500, accuracy: 1, "viewport did not move")
    }

    func testReShowingAPinnedPaneRequestsAPassButAnUnpinnedOneDoesNot() {
        let rig = Rig()
        rig.controller.paneWasShown()
        XCTAssertEqual(rig.passCount, 1)

        rig.userScroll(to: 500)
        rig.passCount = 0
        rig.controller.paneWasShown()
        XCTAssertEqual(rig.passCount, 0)
    }

    // MARK: - (d) The operator scrolling un-pins and re-pins

    func testScrollingUpUnpinsAndShowsThePillAndScrollingBackToTheBottomRepinsAndHidesIt() {
        let rig = Rig()
        XCTAssertTrue(rig.overlay.button.isHidden)

        rig.userScroll(to: 800)
        XCTAssertFalse(rig.controller.isPinned)
        XCTAssertFalse(rig.overlay.button.isHidden)

        rig.documentHeight += 400                                  // output arrives while reading history
        rig.doc.setFrameSize(NSSize(width: 400, height: rig.documentHeight))
        rig.userScroll(to: 820)                                    // still far from the bottom
        XCTAssertFalse(rig.controller.isPinned, "growth alone must not re-pin a reader")

        rig.userScroll(to: rig.bottomOriginY)
        XCTAssertTrue(rig.controller.isPinned, "back at the bottom re-arms following")
        XCTAssertTrue(rig.overlay.button.isHidden)
    }

    // MARK: - Diagnostics handed to onFlip

    func testBoundsDrivenUnpinFlipCarriesTheOriginDeltaAndNoSizeChange() {
        let rig = Rig()
        let before = rig.clip.bounds.origin.y

        rig.userScroll(to: 1000)

        let flip = rig.flips.last
        XCTAssertNotNil(flip)
        XCTAssertEqual(flip?.pinned, false)
        XCTAssertEqual(flip?.originDeltaY ?? .nan, 1000 - before, accuracy: 1)
        XCTAssertEqual(flip?.sizeChanged, false)
    }

    func testBoundsFlipWithNoLiveScrollInFlightIsAttributedToABoundsChange() {
        let rig = Rig()
        rig.userScroll(to: 1000)                                   // knob drag / keys: no live-scroll notification
        XCTAssertEqual(rig.flips.last?.pinned, false)
        XCTAssertEqual(rig.flips.last?.cause, .boundsChange)

        rig.userScroll(to: rig.bottomOriginY)
        XCTAssertEqual(rig.flips.last?.pinned, true)
        XCTAssertEqual(rig.flips.last?.cause, .boundsChange)
    }

    func testBoundsFlipWhileALiveScrollIsInFlightIsAttributedToTheUserAndRevertsAfterItEnds() {
        let rig = Rig()
        let nc = NotificationCenter.default

        nc.post(name: NSScrollView.willStartLiveScrollNotification, object: rig.scrollView)
        rig.userScroll(to: 1000)
        XCTAssertEqual(rig.flips.last?.pinned, false)
        XCTAssertEqual(rig.flips.last?.cause, .userScroll)
        nc.post(name: NSScrollView.didEndLiveScrollNotification, object: rig.scrollView)

        rig.userScroll(to: rig.bottomOriginY)
        XCTAssertEqual(rig.flips.last?.pinned, true)
        XCTAssertEqual(rig.flips.last?.cause, .boundsChange, "after didEnd, back to a plain bounds change")
    }

    func testLiveScrollTickThatLandsAtTheBottomRepinsAsAUserScroll() {
        let rig = Rig()
        rig.userScroll(to: 1000)
        XCTAssertFalse(rig.controller.isPinned)
        rig.flips = []

        // The bounds change landed while our own pass was running, so it was
        // ignored; the live-scroll tick that follows is the operator's.
        rig.isMaterializing = true
        rig.userScroll(to: rig.bottomOriginY)
        rig.isMaterializing = false
        XCTAssertFalse(rig.controller.isPinned)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: rig.scrollView)

        XCTAssertTrue(rig.controller.isPinned)
        XCTAssertEqual(rig.flips.last?.cause, .userScroll)
    }

    // MARK: - Resize near the bottom re-pins

    func testUnpinnedPaneWhoseResizeClampsTheViewportToTheBottomRepins() {
        let rig = Rig()
        rig.userScroll(to: 1000)
        XCTAssertFalse(rig.controller.isPinned)
        rig.flips = []

        // Taller pane: 1000 + 1100 > 2000, so AppKit clamps the origin down to
        // 900 and the viewport now ends exactly at the bottom.
        rig.window.setContentSize(NSSize(width: 400, height: 1100))

        XCTAssertEqual(rig.clip.bounds.maxY, 2000, accuracy: 1, "precondition: clamped to the bottom")
        XCTAssertTrue(rig.controller.isPinned)
        XCTAssertTrue(rig.overlay.button.isHidden)
        XCTAssertEqual(rig.flips.last?.pinned, true)
        XCTAssertEqual(rig.flips.last?.sizeChanged, true)
        XCTAssertNotNil(rig.flips.last?.originDeltaY)
    }

    func testUnpinnedPaneWhoseResizeLeavesItFarFromTheBottomStaysUnpinned() {
        let rig = Rig()
        rig.userScroll(to: 500)
        rig.window.setContentSize(NSSize(width: 400, height: 380))
        XCTAssertFalse(rig.controller.isPinned)
    }

    // MARK: - Epsilon: sub-half-point jitter is not scrolling

    func testSubPixelUpwardJitterDoesNotUnpinButARealUpwardMoveDoes() {
        let rig = Rig()
        rig.userScroll(to: 1000)                                   // un-pinned, far from the bottom
        rig.controller.setPinned(true, cause: .send)               // ...but following again (e.g. user sent)
        rig.flips = []

        rig.userScroll(to: 999.7)                                  // -0.3
        XCTAssertTrue(rig.controller.isPinned, "-0.3 pt is rounding noise")

        rig.userScroll(to: 998.0)                                  // clearly upward
        XCTAssertFalse(rig.controller.isPinned)
    }

    // MARK: - (1) Scroller: always visible and legacy-styled while reading history

    func testScrollerIsLegacyStyleAndVisibleWhileUnpinned() {
        // A trackpad Mac defaults to overlay scrollers, which are invisible
        // until you scroll; the controller must override that.
        let rig = Rig(scrollerStyleBeforeConfigure: .overlay)
        rig.userScroll(to: 600)
        rig.settleLayout()

        XCTAssertEqual(rig.scrollView.scrollerStyle, .legacy)
        XCTAssertTrue(rig.scrollView.hasVerticalScroller)
        XCTAssertFalse(rig.controller.isPinned)
        let scroller = rig.scrollView.verticalScroller
        XCTAssertNotNil(scroller)
        XCTAssertEqual(scroller?.isHidden, false)
    }

    func testScrollerStyleIsLegacyEvenBeforeAnyScrolling() {
        let rig = Rig(scrollerStyleBeforeConfigure: .overlay)
        XCTAssertEqual(rig.scrollView.scrollerStyle, .legacy)
    }

    // MARK: - (1) Snapshot: something is drawn where the scroller sits

    func testUnpinnedPaneDrawsAScrollerAlongTheRightEdgeWithThePillOnTop() throws {
        let rig = Rig(viewport: NSSize(width: 480, height: 320),
                      documentHeight: 2000,
                      scrollerStyleBeforeConfigure: .overlay)
        rig.settleLayout()

        // A few tall, coloured, labelled rows as the document.
        let bounds0 = rig.container.bounds
        let colors: [NSColor] = [Theme.cornflower, Theme.sage, Theme.amber, Theme.redSweater, Theme.cornflower]
        // Exactly the width left of a legacy scroller, whatever style is active
        // when this runs, so the strip is only ever painted by the scroller.
        let docWidth = bounds0.width - NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        rig.doc.setFrameSize(NSSize(width: docWidth, height: 2000))
        for (i, color) in colors.enumerated() {
            rig.doc.addSubview(RowView(frame: NSRect(x: 0, y: CGFloat(i) * 400, width: docWidth, height: 400),
                                       fill: color.withAlphaComponent(0.55), label: "Turn \(i + 1)"))
        }
        rig.userScroll(to: 600)                                    // reading history: un-pinned
        rig.settleLayout()
        XCTAssertFalse(rig.controller.isPinned)
        XCTAssertFalse(rig.overlay.button.isHidden)

        let bounds = rig.container.bounds
        let rep = try XCTUnwrap(rig.container.bitmapImageRepForCachingDisplay(in: bounds))
        rig.container.cacheDisplay(in: bounds, to: rep)
        // AppKit's offscreen display pass (cacheDisplay) leaves legacy NSScrollers
        // blank in a headless logic-test process, though the same scroller draws
        // fine when asked directly. Composite the scroller the scroll view
        // actually placed (frame, hidden state) so the pixels below reflect
        // whether there is a visible, correctly placed scroller to draw.
        if let scroller = rig.scrollView.verticalScroller, !scroller.isHidden,
           let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            ctx.cgContext.translateBy(x: scroller.frame.minX, y: scroller.frame.minY)
            scroller.draw(scroller.bounds)
            NSGraphicsContext.restoreGraphicsState()
        }

        if let dir = ProcessInfo.processInfo.environment["FOLLOW_TAIL_SNAPSHOT_DIR"], !dir.isEmpty,
           let png = rep.representation(using: .png, properties: [:]) {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("follow-tail-unpinned.png"))
        }

        // Right-edge strip where a legacy scroller (15 pt) sits: not just backdrop.
        let scale = CGFloat(rep.pixelsWide) / bounds.width
        // The column through the middle of the scroller. A legacy scroller keeps
        // its track visible the whole height; an overlay one shows at most a
        // knob (and only while flashing), so "most rows drawn" means an
        // always-visible scroller.
        let x = Int((bounds.width - 8.5) * scale)
        let backdrop = Theme.bg.usingColorSpace(.deviceRGB)!
        var drawnRows = 0
        for y in 0..<rep.pixelsHigh {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            let delta = abs(c.redComponent - backdrop.redComponent)
                      + abs(c.greenComponent - backdrop.greenComponent)
                      + abs(c.blueComponent - backdrop.blueComponent)
            if delta > 0.06 { drawnRows += 1 }
        }
        XCTAssertGreaterThan(Double(drawnRows) / Double(rep.pixelsHigh), 0.8,
                             "the right edge is mostly bare backdrop: no always-visible scroller track is drawn")
    }
}
