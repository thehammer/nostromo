import XCTest
import AppKit

// A memory shed must not blank a pane somebody is looking at.
//
// The incident: the app's footprint sat permanently above the watchdog's shed line because of a
// leak that has nothing to do with transcript views, so `MemoryWatchdog.poll()` shed every 30 s,
// forever. Every shed released ALL materialized turn views, including the ones on screen, and then
// waited for a compaction before drawing them again. The operator watched the transcript go blank
// and redraw twice a minute, and the shed freed nothing.
//
// The fix has two halves. The watchdog backs off when sheds do not help (`MemoryWatchdogBackoffTests`),
// and a poll-triggered shed asks panes for `.offscreenOnly`: keep what the operator can see and what
// is about to be scrolled to (one viewport height above and below), release the rest. Critical OS
// pressure still asks for `.everything`. This file pins the pane's half, on a REAL `ReplView` in an
// offscreen window (the rig `PaneBlankDetectorTests` uses), delivering turns the way the daemon does.
//
// Everything is observed from outside: which turn views are subviews of the transcript's document
// view and where their frames are, `visibleTurnViewCount`, `materializedViewCount`, the flight
// recorder's `viewsEvicted` events, and whether the compaction `completion` fires. Visibility is
// forced with `renderWatch.visibilityOverride`, because offscreen occlusion is unreliable.
final class ShedKeepsVisibleViewsTests: XCTestCase {

    // MARK: - Rig (the PaneBlankDetectorTests rig, trimmed to what a shed needs)

    private final class FixedWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private struct Pane {
        let repl: ReplView
        let window: NSWindow
        let tag: String
        var watch: PaneRenderWatch { repl.renderWatch }
    }

    private var client: NostromodClient { AppStore.shared.client }

    private func makePane(size: NSSize = NSSize(width: 900, height: 700)) -> Pane {
        let tag = "skv-\(UUID().uuidString)"
        let repl = ReplView(tag: tag)
        // A test must never write a capture into the user's home: the detector may fire on a
        // pane that is deliberately emptied here.
        repl.renderWatch.captureDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("shed-keeps-visible-\(UUID().uuidString)", isDirectory: true)
        repl.renderWatch.visibilityOverride = true

        let window = FixedWindow(contentRect: NSRect(origin: NSPoint(x: 60, y: 60), size: size),
                                 styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        repl.frame = NSRect(origin: .zero, size: size)
        repl.autoresizingMask = [.width, .height]
        window.contentView = repl
        window.alphaValue = 0
        window.orderFront(nil)
        addTeardownBlock {
            // A finished test's pane must not answer a later test's "capture every visible pane".
            repl.renderWatch.visibilityOverride = false
            window.orderOut(nil)
            window.contentView = nil
        }
        settle(window)
        return Pane(repl: repl, window: window, tag: tag)
    }

    private func settle(_ window: NSWindow) {
        for _ in 0 ..< 4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    private func pump(_ pane: Pane, _ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        pane.window.contentView?.layoutSubtreeIfNeeded()
        pane.window.displayIfNeeded()
    }

    @discardableResult
    private func waitUntil(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("condition not met within \(timeout)s", file: file, line: line)
                return false
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return true
    }

    private static let base = Date(timeIntervalSince1970: 1_780_000_000)
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let prose = "The transcript keeps a long paragraph of ordinary words so that each turn is tall enough to matter. "

    private func turn(_ i: Int) -> DaemonTurn {
        DaemonTurn(id: "turn-\(i)",
                   userInput: "question number \(i)",
                   timestamp: Self.iso.string(from: Self.base.addingTimeInterval(Double(i))),
                   blocks: [.text(String(repeating: Self.prose, count: 6))],
                   isComplete: true)
    }

    /// A pane with enough tall turns that the transcript is many viewports long, so the
    /// materialization window (about three viewports) is a small part of it.
    private func makeMaterializedPane(turns count: Int = 60,
                                      file: StaticString = #filePath, line: UInt = #line) -> Pane {
        let pane = makePane()
        client.messages.send(.sessionSpawned(tag: pane.tag, sessionId: "session-\(pane.tag)"))
        client.messages.send(.sessionTurns(tag: pane.tag, turns: (0 ..< count).map { turn($0) }))
        waitUntil(file: file, line: line) {
            self.pump(pane, 0.02)
            return pane.repl.visibleTurnViewCount > 0
        }
        // Let the follow-tail scroll and the passes it triggers finish.
        for _ in 0 ..< 6 { pump(pane, 0.03) }
        return pane
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews { if let found = scrollView(in: sub) { return found } }
        return nil
    }

    private func transcriptScroll(_ pane: Pane) throws -> NSScrollView {
        try XCTUnwrap(scrollView(in: pane.repl), "the pane has a scroll view")
    }

    /// The turn views currently hanging off the transcript's document view.
    private func turnViews(in pane: Pane) throws -> [NSView] {
        let document = try XCTUnwrap(try transcriptScroll(pane).documentView, "the pane has a document view")
        return document.subviews.filter { $0 is TurnIsland }
    }

    private func identities(_ views: [NSView]) -> Set<ObjectIdentifier> {
        Set(views.map { ObjectIdentifier($0) })
    }

    /// The recorder's "views remaining" figure for every shed-caused eviction so far.
    private func remainingViewsAfterShedEvictions(_ pane: Pane) -> [Double] {
        pane.watch.recorder.events
            .filter { $0.kind == .viewsEvicted && $0.reason == .shed }
            .map(\.b)
    }

    /// Calls the shed and returns a flag the completion sets.
    private final class Completion {
        private(set) var fired = false
        lazy var callback: () -> Void = { [weak self] in self?.fired = true }
    }

    // MARK: - `.everything` is today's behaviour

    func testShedEverythingReleasesEveryTurnViewIncludingTheVisibleOnes() {
        let pane = makeMaterializedPane()
        XCTAssertGreaterThan(pane.repl.visibleTurnViewCount, 0, "precondition: the pane shows turns")
        XCTAssertGreaterThan(pane.repl.materializedViewCount, 0)

        let completion = Completion()
        pane.repl.shedMaterializedViews(scope: .everything, completion: completion.callback)

        XCTAssertEqual(pane.repl.materializedViewCount, 0, ".everything releases every view")
        XCTAssertEqual(pane.repl.visibleTurnViewCount, 0, "including the visible ones")
        XCTAssertTrue(remainingViewsAfterShedEvictions(pane).contains(0),
                      "the recorder says the shed left no views")

        waitUntil { self.pump(pane, 0.02); return completion.fired }
        waitUntil { self.pump(pane, 0.02); return pane.repl.visibleTurnViewCount > 0 }
    }

    /// The parameter has a default, and the default is the old behaviour: existing callers
    /// (`AppStore`'s fan-out before it learned about scopes) keep their meaning.
    func testShedWithNoScopeReleasesEverythingAsItAlwaysDid() {
        let pane = makeMaterializedPane()
        XCTAssertGreaterThan(pane.repl.materializedViewCount, 0)

        let completion = Completion()
        pane.repl.shedMaterializedViews(completion: completion.callback)

        XCTAssertEqual(pane.repl.materializedViewCount, 0)
        XCTAssertEqual(pane.repl.visibleTurnViewCount, 0)
        waitUntil { self.pump(pane, 0.02); return completion.fired }
    }

    // MARK: - `.offscreenOnly` on a visible pane keeps what is on screen

    func testOffscreenOnlyShedKeepsTheSameVisibleViewsInstead() throws {
        let pane = makeMaterializedPane()
        let before = try turnViews(in: pane)
        let visibleBefore = pane.repl.visibleTurnViewCount
        XCTAssertGreaterThan(visibleBefore, 0, "precondition: the pane shows turns")

        let completion = Completion()
        pane.repl.shedMaterializedViews(scope: .offscreenOnly, completion: completion.callback)

        // Straight after the call, before any run-loop turn could rebuild anything.
        XCTAssertEqual(pane.repl.visibleTurnViewCount, visibleBefore,
                       "the operator's view of the transcript must not change at all")
        XCTAssertGreaterThan(pane.repl.visibleTurnViewCount, 0, "never blank")
        let after = try turnViews(in: pane)
        let visibleViews = before.filter { visible($0, in: pane) }
        XCTAssertFalse(visibleViews.isEmpty)
        for view in visibleViews {
            XCTAssertTrue(identities(after).contains(ObjectIdentifier(view)),
                          "a view on screen must be the very same instance afterwards, not rebuilt")
            XCTAssertNotNil(view.superview, "and still attached to the document view")
        }

        XCTAssertFalse(remainingViewsAfterShedEvictions(pane).contains(0),
                       "no shed event may report an empty pane: \(remainingViewsAfterShedEvictions(pane))")
        waitUntil { self.pump(pane, 0.02); return completion.fired }
    }

    func testOffscreenOnlyShedStillCompletesSoTheWatchdogCanMeasure() {
        let pane = makeMaterializedPane()

        let completion = Completion()
        pane.repl.shedMaterializedViews(scope: .offscreenOnly, completion: completion.callback)

        waitUntil(timeout: 10) { self.pump(pane, 0.02); return completion.fired }
        XCTAssertTrue(completion.fired, "the compaction completion is how the watchdog knows memory was freed")
    }

    /// The incident, replayed: a poll shed on a pane someone is reading, then the run loop turning.
    /// There is never a turn of the run loop at which the pane has nothing in view, and it stays
    /// that way through repeated sheds.
    func testARepeatedPollStyleShedNeverLeavesTheVisiblePaneBlankAtAnyRunLoopTurn() throws {
        let pane = makeMaterializedPane()
        XCTAssertGreaterThan(pane.repl.visibleTurnViewCount, 0)

        for round in 1 ... 3 {
            let completion = Completion()
            pane.repl.shedMaterializedViews(scope: .offscreenOnly, completion: completion.callback)
            XCTAssertGreaterThan(pane.repl.visibleTurnViewCount, 0, "round \(round): immediately after the shed")

            var turns = 0
            while !completion.fired || turns < 8 {
                pump(pane, 0.02)
                turns += 1
                XCTAssertGreaterThan(pane.repl.visibleTurnViewCount, 0,
                                     "round \(round), run-loop turn \(turns): the pane went blank")
                if turns > 500 { return XCTFail("round \(round): the shed never completed") }
            }
        }
        XCTAssertFalse(remainingViewsAfterShedEvictions(pane).contains(0),
                       "the recorder saw an eviction that left no views: \(remainingViewsAfterShedEvictions(pane))")
    }

    // MARK: - `.offscreenOnly` releases what is outside the one-viewport band

    /// The pane is scrolled away from where its views were built (a scroll whose materialization
    /// pass has not run yet), so the materialized set is larger than the band around what is on
    /// screen now. The shed keeps what is inside "viewport +/- one viewport height" and releases
    /// the rest, which is what makes it a shed and not a no-op.
    ///
    /// Frames are compared with a 2 pt margin on every boundary, because which side of the line a
    /// view that merely touches the band falls on is not part of the contract.
    func testOffscreenOnlyShedKeepsViewsInsideTheBandAndReleasesViewsOutsideIt() throws {
        let pane = makeMaterializedPane()
        let scroll = try transcriptScroll(pane)
        let clip = scroll.contentView
        let viewportHeight = clip.bounds.height
        let documentHeight = try XCTUnwrap(scroll.documentView).frame.height
        XCTAssertGreaterThan(documentHeight, viewportHeight * 8,
                             "precondition: the transcript is many viewports long")

        // Read the middle of the transcript, and let the pane build the views around it.
        let middle = (documentHeight - viewportHeight) / 2
        clip.scroll(to: NSPoint(x: 0, y: middle))
        scroll.reflectScrolledClipView(clip)
        for _ in 0 ..< 8 { pump(pane, 0.03) }
        XCTAssertGreaterThan(pane.repl.visibleTurnViewCount, 0, "precondition: the middle is materialized")

        // Scroll on by a viewport and a half, and shed before the pane's pass catches up.
        clip.scroll(to: NSPoint(x: 0, y: middle + viewportHeight * 1.5))
        scroll.reflectScrolledClipView(clip)

        let bounds = clip.bounds
        let bandMin = bounds.minY - bounds.height
        let bandMax = bounds.maxY + bounds.height
        let margin: CGFloat = 2
        let before = try turnViews(in: pane)
        let mustKeep = before.filter { $0.frame.maxY > bandMin + margin && $0.frame.minY < bandMax - margin }
        let mustRelease = before.filter { $0.frame.maxY < bandMin - margin || $0.frame.minY > bandMax + margin }
        let visibleBefore = pane.repl.visibleTurnViewCount
        XCTAssertFalse(mustRelease.isEmpty,
                       "precondition: some materialized views lie outside the band (otherwise this test proves nothing)")
        XCTAssertFalse(mustKeep.isEmpty, "precondition: some materialized views lie inside the band")
        XCTAssertGreaterThan(visibleBefore, 0, "precondition: part of the scrolled-to position is built")

        let completion = Completion()
        pane.repl.shedMaterializedViews(scope: .offscreenOnly, completion: completion.callback)

        let afterIdentities = identities(try turnViews(in: pane))
        for view in mustKeep {
            XCTAssertTrue(afterIdentities.contains(ObjectIdentifier(view)),
                          "a view inside the band (y \(view.frame.minY) to \(view.frame.maxY), "
                          + "band \(bandMin) to \(bandMax)) was released")
        }
        for view in mustRelease {
            XCTAssertFalse(afterIdentities.contains(ObjectIdentifier(view)),
                           "a view outside the band (y \(view.frame.minY) to \(view.frame.maxY), "
                           + "band \(bandMin) to \(bandMax)) was kept: that is what the shed is for")
            XCTAssertNil(view.superview, "a released view must come off the document view")
        }
        XCTAssertEqual(pane.repl.visibleTurnViewCount, visibleBefore,
                       "the views on screen are all inside the band, so none of them may go")
        XCTAssertGreaterThan(pane.repl.visibleTurnViewCount, 0)
        XCTAssertLessThan(pane.repl.materializedViewCount, before.count, "the shed released something")
        XCTAssertFalse(remainingViewsAfterShedEvictions(pane).contains(0))

        waitUntil { self.pump(pane, 0.02); return completion.fired }
        XCTAssertGreaterThan(pane.repl.visibleTurnViewCount, 0, "and the pane is still showing turns when it is done")
    }

    // MARK: - `.offscreenOnly` on a pane nobody can see releases everything

    func testOffscreenOnlyShedOnAPaneThatIsNotVisibleReleasesEveryView() {
        let pane = makeMaterializedPane()
        XCTAssertGreaterThan(pane.repl.materializedViewCount, 0)
        pane.watch.visibilityOverride = false

        let completion = Completion()
        pane.repl.shedMaterializedViews(scope: .offscreenOnly, completion: completion.callback)

        XCTAssertEqual(pane.repl.materializedViewCount, 0,
                       "a pane nobody is looking at has no visible region to protect: everything goes")
        XCTAssertEqual(pane.repl.visibleTurnViewCount, 0)
        waitUntil { self.pump(pane, 0.02); return completion.fired }
    }

    // MARK: - Geometry helper

    /// Same test the pane itself uses for "on screen": the view's frame overlaps the clip bounds.
    private func visible(_ view: NSView, in pane: Pane) -> Bool {
        guard let scroll = scrollView(in: pane.repl) else { return false }
        let bounds = scroll.contentView.bounds
        return view.frame.maxY > bounds.minY && view.frame.minY < bounds.maxY
    }
}
