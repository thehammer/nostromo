import XCTest
import AppKit
import NostromoKit

// MV-2: the job detail scrolls internally. Content taller than the pane is reached by scrolling, not
// by growing the window (MV-1), so the detail holds a vertical `NSScrollView`
// (`MotherJobDetail.contentScrollView`, the scroll view of the Overview: everything except the title and
// switch above it, the Plan and Log segments, and the reply box, which keeps its own).
//
// The reader's place is theirs: data arriving for the job they are reading (a state change, a progress
// tick, a todo list, log lines, gates, an error, a longer or shorter plan) must not move what they are
// looking at. That is measured on a row they can see (a `PLAN-n` row): its offset
// from the viewport's top edge holds within 1 pt while the sections above it grow and shrink. The clip's
// own origin is NOT the measure: it has to change when the content above changes height. A document that
// shrinks clamps the position, and opening a different job starts at the top.
final class MotherDetailScrollTests: XCTestCase {

    private let tolerance: CGFloat = 1

    // MARK: - Helpers

    private func scrollView(_ rig: MDRig) -> NSScrollView { rig.detail.contentScrollView }

    private func scroll(_ rig: MDRig, toY y: CGFloat) {
        let sv = scrollView(rig)
        let clip = sv.contentView
        clip.scroll(to: NSPoint(x: 0, y: y))
        sv.reflectScrolledClipView(clip)
        rig.window.contentView?.layoutSubtreeIfNeeded()
    }

    private func maxScrollY(_ rig: MDRig) -> CGFloat {
        let sv = scrollView(rig)
        return max(0, (sv.documentView?.frame.height ?? 0) - sv.contentView.bounds.height)
    }

    private func originY(_ rig: MDRig) -> CGFloat { scrollView(rig).contentView.bounds.origin.y }

    private func documentHeight(_ rig: MDRig) -> CGFloat { scrollView(rig).documentView?.frame.height ?? 0 }

    /// The top edge of `view` measured from the top edge of the viewport: what the reader sees.
    private func offsetFromViewportTop(_ rig: MDRig, _ view: NSView) -> CGFloat {
        let doc = scrollView(rig).documentView!
        return doc.convert(view.bounds, from: view).minY - originY(rig)
    }

    private func labels(_ rig: MDRig, prefix: String) -> [NSTextField] {
        MD.allSubviews(rig.detail).compactMap { $0 as? NSTextField }
            .filter { $0.stringValue.hasPrefix(prefix) && !$0.isHiddenOrHasHiddenAncestor }
    }

    /// The labels starting with `prefix` that are entirely inside the viewport, top to bottom.
    private func visibleLabels(_ rig: MDRig, prefix: String) -> [NSTextField] {
        let sv = scrollView(rig)
        let doc = sv.documentView!
        return labels(rig, prefix: prefix)
            .filter { sv.documentVisibleRect.contains(doc.convert($0.bounds, from: $0)) }
            .sorted { offsetFromViewportTop(rig, $0) < offsetFromViewportTop(rig, $1) }
    }

    /// The reader is inside the plan: scrolled `below` pt past the plan's first row. Returns the first
    /// and last plan rows they can see (what they are looking at).
    private func scrollIntoPlan(_ rig: MDRig, below: CGFloat = 900,
                                file: StaticString = #filePath, line: UInt = #line) throws -> [(String, NSView)] {
        let first = try XCTUnwrap(labels(rig, prefix: "PLAN-0 ").first, "the plan is rendered", file: file, line: line)
        let planTop = scrollView(rig).documentView!.convert(first.bounds, from: first).minY
        scrollAndConfirm(rig, toY: planTop + below, file: file, line: line)
        let rows = visibleLabels(rig, prefix: "PLAN-")
        XCTAssertGreaterThanOrEqual(rows.count, 2, "precondition: at least two plan rows are in view", file: file, line: line)
        return [("first visible plan row", try XCTUnwrap(rows.first, file: file, line: line)),
                ("last visible plan row", try XCTUnwrap(rows.last, file: file, line: line))]
    }

    /// The reader is at the end of the Overview (which now ends with the plan checklist; the log has a segment
    /// of its own): `slack` pt above the very end of the document (0 is the end itself, where a shrinking
    /// document clamps to the same place with or without an anchor; the slack makes a shrink above the reader
    /// a real test). Returns what they see: the last plan rows in view.
    private func scrollToOverviewEnd(_ rig: MDRig, slack: CGFloat = 0,
                                     file: StaticString = #filePath, line: UInt = #line) throws -> [(String, NSView)] {
        scrollAndConfirm(rig, toY: maxScrollY(rig) - slack, file: file, line: line)
        let rows = visibleLabels(rig, prefix: "PLAN-")
        XCTAssertGreaterThanOrEqual(rows.count, 2, "precondition: plan rows are in view at the end of the Overview", file: file, line: line)
        return [("last visible plan row", try XCTUnwrap(rows.last, file: file, line: line)),
                ("first visible plan row", try XCTUnwrap(rows.first, file: file, line: line))]
    }

    /// A rig that starts with no action error showing. `makeRig`'s usual one clears itself 5 s after it
    /// arrives, and a test that measures where the reader is would then depend on how fast the runner is:
    /// the clearing shrinks what is above the reader mid-test. The tests that want an error send their own.
    private func makeScrollRig(long: Set<MDField>, index: Int, bare: Bool = false) throws -> MDRig {
        try MD.makeRig(self, long: long, index: index, bare: bare, startupError: false)
    }

    private enum Change { case grows, shrinks, either }

    /// Runs `event` and asserts every anchor is still in the detail and still at the same distance from the
    /// viewport's top edge (within 1 pt), and that the document changed the way the event says (so the
    /// event really moved what is above the reader).
    private func assertAnchorsHold(_ rig: MDRig, _ name: String, _ change: Change, anchors: [(String, NSView)],
                                   file: StaticString = #filePath, line: UInt = #line,
                                   event: () throws -> Void) rethrows {
        let before = anchors.map { offsetFromViewportTop(rig, $0.1) }
        let heightBefore = documentHeight(rig)
        try event()
        rig.awaitRendered(file: file, line: line)
        let heightAfter = documentHeight(rig)
        switch change {
        case .grows:
            XCTAssertGreaterThan(heightAfter, heightBefore + 1, "\(name): precondition: the document grows (\(heightBefore) -> \(heightAfter))", file: file, line: line)
        case .shrinks:
            XCTAssertLessThan(heightAfter, heightBefore - 1, "\(name): precondition: the document shrinks (\(heightBefore) -> \(heightAfter))", file: file, line: line)
        case .either:
            break
        }
        for (k, anchor) in anchors.enumerated() {
            XCTAssertTrue(anchor.1.isDescendant(of: rig.detail), "\(name): the \(anchor.0) is gone", file: file, line: line)
            let after = offsetFromViewportTop(rig, anchor.1)
            XCTAssertEqual(after, before[k], accuracy: tolerance,
                           "after \"\(name)\" the \(anchor.0) moved from \(before[k]) to \(after) pt below the top of the viewport (document \(heightBefore) -> \(heightAfter), origin \(originY(rig)))",
                           file: file, line: line)
        }
        assertHorizontallyAtRest(rig, "after \"\(name)\"", file: file, line: line)
    }

    /// The events a running or held job delivers while someone reads it, each with how it moves the
    /// sections above the plan and the log. The long action error clears itself after a few seconds
    /// (the shrinking half of it); the rig waits for that, bounded.
    private func liveEvents(_ rig: MDRig) -> [(String, Change, () throws -> Void)] {
        [
            ("60 long todos arrive", .grows, { rig.sendPeek(todos: 60) }),
            ("the todo list shrinks to 5", .shrinks, { rig.sendPeek(todos: 5) }),
            ("the todo list empties", .shrinks, { rig.sendPeek(todos: 0) }),
            ("the todo list is back at 40", .grows, { rig.sendPeek(todos: 40) }),
            ("gates grow to 40 rows", .either, { rig.setGates(40) }),
            ("gates shrink to 3 rows", .either, { rig.setGates(3) }),
            ("the job resumes (state running)", .either, { rig.setState("running") }),
            ("a progress tick", .either, { rig.setProgress(40) }),
            ("another progress tick", .either, { rig.setProgress(55) }),
            ("the job holds again (state awaiting)", .either, { rig.setState("awaiting") }),
            ("an action error arrives", .grows, { rig.host.errorSubject.send(MDFixtures.actionError(long: true)) }),
            ("the action error clears itself", .shrinks, {
                XCTAssertTrue(MD.pumpUntil(rig.window) { rig.renderedCount(prefix: "ERR") == 0 },
                              "the action error never cleared")
            }),
        ]
    }

    /// Scrolls to `y` and checks it took, so a later "still at `y`" proves something.
    private func scrollAndConfirm(_ rig: MDRig, toY y: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        scroll(rig, toY: y)
        XCTAssertEqual(originY(rig), y, accuracy: tolerance, "precondition: scrolled to \(y)", file: file, line: line)
    }

    private func assertHorizontallyAtRest(_ rig: MDRig, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let sv = scrollView(rig)
        let clip = sv.contentView
        XCTAssertEqual(clip.bounds.origin.x, 0, accuracy: tolerance, "\(label): the clip is scrolled sideways", file: file, line: line)
        if let doc = sv.documentView {
            XCTAssertEqual(doc.frame.width, clip.bounds.width, accuracy: tolerance,
                           "\(label): the document is \(doc.frame.width) wide in a \(clip.bounds.width) clip (it scrolls sideways)",
                           file: file, line: line)
        }
    }

    // MARK: - Scroller style

    private func styleName(_ style: NSScroller.Style) -> String { style == .legacy ? "legacy" : "overlay" }

    /// What a failure needs to show: the style, and the widths that decide whether the document tracks the clip.
    private func scrollerState(_ rig: MDRig, _ style: NSScroller.Style) -> String {
        let sv = scrollView(rig)
        let docWidth = sv.documentView?.frame.width ?? -1
        return "style \(styleName(style)), document \(docWidth) wide, clip \(sv.contentView.bounds.width) wide, "
            + "scroll view \(sv.frame.width) wide, vertical scroller hidden: \(String(describing: sv.verticalScroller?.isHidden))"
    }

    /// The document is exactly as wide as the clip (no sideways scrolling), whatever the scroller style.
    private func assertTracksClip(_ rig: MDRig, _ style: NSScroller.Style, _ moment: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let state = scrollerState(rig, style)
        XCTAssertEqual(scrollView(rig).scrollerStyle, style, "\(moment): precondition: the style took (\(state))", file: file, line: line)
        assertHorizontallyAtRest(rig, "\(moment) (\(state))", file: file, line: line)
    }

    // Proves the Overview never scrolls sideways, in either scroller style, when the log tail changes: legacy is what a runner without a trackpad has.
    func testTheOverviewNeverScrollsSidewaysWithEitherScrollerStyleWhenTheLogChanges() throws {
        for (offset, (name, style)) in [("legacy", NSScroller.Style.legacy), ("overlay", NSScroller.Style.overlay)].enumerated() {
            let rig = try makeScrollRig(long: [.planChecklist], index: 960 + offset)
            let sv = scrollView(rig)
            sv.scrollerStyle = style
            MD.pump(rig.window)
            rig.awaitRendered()

            XCTAssertEqual(sv.scrollerStyle, style, "\(name): precondition: the style took")
            if style == .legacy {
                let sv = scrollView(rig)
                let scroller = try XCTUnwrap(sv.verticalScroller, "\(name): the scroll view has a vertical scroller")
                XCTAssertFalse(scroller.isHidden, "precondition: the legacy vertical scroller is showing (\(scrollerState(rig, style)))")
                let width = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
                XCTAssertEqual(sv.frame.width - sv.contentView.bounds.width, width, accuracy: tolerance,
                               "precondition: the legacy scroller takes its width out of the clip (\(scrollerState(rig, style)))")
            }
            assertTracksClip(rig, style, "right after the style is set")

            rig.detail.setLogAttributed(MDFixtures.logText(lines: 120, long: true))
            rig.awaitRendered()
            assertTracksClip(rig, style, "after a 120-line log of long lines")

            rig.detail.setLogAttributed(MDFixtures.logText(lines: 40, long: false))
            rig.awaitRendered()
            assertTracksClip(rig, style, "after a 40-line log of short lines")

            rig.close()
        }
    }

    // Proves the document keeps tracking the clip when the scroller style flips while the job is open (overlay -> legacy -> overlay).
    func testTheOverviewStaysTheWidthOfItsClipWhenTheScrollerStyleFlipsAtRuntime() throws {
        let rig = try makeScrollRig(long: [.planChecklist], index: 962)
        let sv = scrollView(rig)
        for (name, style) in [("overlay", NSScroller.Style.overlay), ("legacy", .legacy), ("overlay again", .overlay)] {
            sv.scrollerStyle = style
            MD.pump(rig.window)
            rig.awaitRendered()
            assertTracksClip(rig, style, "after flipping to \(name)")
            if style == .legacy {
                XCTAssertFalse(sv.verticalScroller?.isHidden ?? true,
                               "precondition: the legacy vertical scroller is showing (\(scrollerState(rig, style)))")
            }
        }
    }

    // Proves 200 overlay <-> legacy flips in one open job never hang, never leave the document off its clip, and cost a bounded number of layouts each (a layout that keeps asking for itself would show as a timeout or a count).
    func testTheOverviewTracksItsClipThroughTwoHundredScrollerStyleFlipsWithoutALayoutStorm() throws {
        // A broken flip would otherwise report the same failure 200 times.
        continueAfterFailure = false
        let rig = try makeScrollRig(long: [.planChecklist], index: 963)
        let sv = scrollView(rig)
        let doc = try XCTUnwrap(sv.documentView as? DetailDocumentView, "the Overview's document is a DetailDocumentView")
        let styles: [NSScroller.Style] = [.legacy, .overlay]
        let flips = 200
        let layoutsPerFlipLimit = 20

        var mostLayouts = 0
        for flip in 0..<flips {
            let style = styles[flip % 2]
            let layoutsBefore = doc.layoutCount
            sv.scrollerStyle = style
            // Cheap on purpose: the clip's width settles within a few passes, and 200 flips must stay quick.
            MD.pump(rig.window, seconds: 0.05)
            let layouts = doc.layoutCount - layoutsBefore
            mostLayouts = max(mostLayouts, layouts)
            assertTracksClip(rig, style, "flip \(flip + 1) of \(flips), to \(styleName(style))")
            XCTAssertLessThanOrEqual(layouts, layoutsPerFlipLimit,
                                     "flip \(flip + 1) of \(flips), to \(styleName(style)): the document was laid out \(layouts) times (\(scrollerState(rig, style)))")
        }

        rig.awaitRendered()
        assertTracksClip(rig, styles[(flips - 1) % 2], "after \(flips) flips (most layouts for one flip: \(mostLayouts))")
    }

    // MARK: - It scrolls

    func testTheDetailHoldsAVerticalScrollViewWhoseDocumentIsTallerThanItsClipForALongPlan() throws {
        let rig = try MD.makeRig(self, long: [.planChecklist], index: 930)
        let sv = scrollView(rig)

        XCTAssertTrue(sv.isDescendant(of: rig.detail), "the content scroll view is inside the detail")
        XCTAssertFalse(sv === rig.detail.logScrollView, "it is not the log's scroll view")
        let doc = try XCTUnwrap(sv.documentView, "the content scroll view has a document")
        let clip = sv.contentView

        XCTAssertGreaterThan(clip.bounds.height, 100, "the clip is laid out")
        XCTAssertGreaterThan(doc.frame.height, clip.bounds.height + 500,
                             "a 200-item plan makes the document \(doc.frame.height) tall in a \(clip.bounds.height) clip: it scrolls")
        XCTAssertTrue(doc.isFlipped, "the document is flipped, so the top stays put when its height changes")
        XCTAssertEqual(clip.bounds.origin.y, 0, accuracy: tolerance, "it starts at the top")
        assertHorizontallyAtRest(rig, "long plan")
        MD.assertFits(rig, "long plan, with the scroll view")
    }

    func testEveryFieldLongStillScrollsVerticallyAndNeverSideways() throws {
        let rig = try MD.makeRig(self, long: Set(MDField.allCases), index: 931)
        let sv = scrollView(rig)
        let doc = try XCTUnwrap(sv.documentView)
        XCTAssertGreaterThan(doc.frame.height, sv.contentView.bounds.height + 500, "everything long: it scrolls")
        XCTAssertTrue(doc.isFlipped)
        assertHorizontallyAtRest(rig, "every field long")

        // Scrolled to the very end, the clip is still at x == 0 and inside the document.
        scroll(rig, toY: maxScrollY(rig))
        assertHorizontallyAtRest(rig, "scrolled to the end")
        XCTAssertEqual(originY(rig), maxScrollY(rig), accuracy: tolerance, "the end of the document can be reached")
        MD.assertFits(rig, "every field long, scrolled to the end")
    }

    func testAShortJobDoesNotNeedToScroll() throws {
        // A job with no crew data and no hold: the fixture's usual short job (a hold with three options,
        // gates and a review wave) is itself about as tall as the pane.
        let rig = try MD.makeRig(self, long: [], index: 932, bare: true)
        XCTAssertEqual(maxScrollY(rig), 0, accuracy: tolerance, "short content: nothing to scroll to")
        XCTAssertEqual(originY(rig), 0, accuracy: tolerance)
        assertHorizontallyAtRest(rig, "short content")
        MD.assertFits(rig, "short content, with the scroll view")
    }

    // MARK: - The reader's place survives updates to the same job

    func testTheRowsInViewStayPutWhileTheSectionsAboveThePlanGrowAndShrink() throws {
        let rig = try makeScrollRig(long: [.planChecklist], index: 940)
        // Everything the reader sees, kept across all the events: no re-scrolling in between.
        let anchors = try scrollIntoPlan(rig)
        for (name, change, event) in liveEvents(rig) {
            try assertAnchorsHold(rig, name, change, anchors: anchors, event: event)
        }
    }

    func testTheEndOfTheOverviewInViewStaysPutWhileTheSectionsAboveItGrowAndShrink() throws {
        // At the very end of the document, and a little above it (where a shrink cannot hide in the clamp).
        for (index, slack) in [(941, CGFloat(0)), (947, 150)] {
            let rig = try makeScrollRig(long: [.planChecklist], index: index)
            let anchors = try scrollToOverviewEnd(rig, slack: slack)
            for (name, change, event) in liveEvents(rig) {
                try assertAnchorsHold(rig, "\(name) (\(slack) pt above the end)", change, anchors: anchors, event: event)
            }
            rig.close()
        }
    }

    func testCrewDataArrivingForAJobThatHadNoneKeepsTheRowsInViewPut() throws {
        // The crew section goes from zero height to its full height above the reader.
        let rig = try makeScrollRig(long: [.planChecklist], index: 945, bare: true)
        let anchors = try scrollIntoPlan(rig)
        rig.bare = false
        try assertAnchorsHold(rig, "the first crew data arrives", .grows, anchors: anchors) { rig.setProgress(40) }
    }

    func testALiveUpdateNeverCarriesTheReaderToTheNextJob() throws {
        // An update takes an anchor in the plan; a different job then opens: top, and still the top
        // after everything has settled (a held anchor must not pull the new job back down).
        let rig = try makeScrollRig(long: [.planChecklist], index: 946)
        _ = try scrollIntoPlan(rig)
        rig.sendPeek(todos: 60)
        MD.pump(rig.window, seconds: 0.05)
        try rig.selectOtherJob(planItems: 200)
        XCTAssertEqual(originY(rig), 0, accuracy: tolerance, "a different job starts at the top")
        MD.pump(rig.window, seconds: 0.5)
        XCTAssertEqual(originY(rig), 0, accuracy: tolerance, "and stays there once layout has settled")
    }

    func testLiveUpdatesLeaveFocusAndTheDraftAloneAndWriteNothing() throws {
        let rig = try makeScrollRig(long: [.planChecklist], index: 949)
        let reply = rig.detail.replyTextView
        XCTAssertTrue(rig.window.makeFirstResponder(reply), "precondition: the guidance box can take focus")
        reply.string = "half-written guidance"
        _ = try scrollIntoPlan(rig)

        // Not the state flips: leaving the awaiting state is meant to clear the draft. (Where the page
        // sits is not asserted here: AppKit itself brings a focused text view into view when its
        // geometry changes. That the rows stay put is the other tests' subject.)
        for (name, _, event) in liveEvents(rig) where !name.contains("state") {
            try event()
            rig.awaitRendered()
            XCTAssertTrue(rig.window.firstResponder === reply, "after \"\(name)\" the guidance box lost focus (\(String(describing: rig.window.firstResponder)))")
            XCTAssertEqual(reply.string, "half-written guidance", "after \"\(name)\" the draft changed")
        }
        XCTAssertEqual(rig.host.writes, [], "reading a job's updates must not send, answer, cancel or retry anything")
        let keyed = MD.allSubviews(rig.detail).compactMap { $0 as? NSButton }.filter { !$0.keyEquivalent.isEmpty }
        XCTAssertTrue(keyed.isEmpty, "buttons with key equivalents: \(keyed.map(\.title))")
        XCTAssertNil(rig.window.defaultButtonCell, "no button is the window's default")
    }

    func testAReaderInThePlanWhoScrollsOnIsAnchoredWhereTheyStopped() throws {
        // The anchor follows the reader: after scrolling to a new place, the next update holds THAT place.
        let rig = try makeScrollRig(long: [.planChecklist], index: 943)
        for (k, below) in [CGFloat(2_400), 5_000].enumerated() {
            let anchors = try scrollIntoPlan(rig, below: below)
            try assertAnchorsHold(rig, "the todo list grows (stop \(k))", .grows, anchors: anchors) {
                rig.sendPeek(todos: k == 0 ? 50 : 70)
            }
            try assertAnchorsHold(rig, "the todo list shrinks (stop \(k))", .shrinks, anchors: anchors) {
                rig.sendPeek(todos: 3)
            }
        }
    }

    func testDataBelowTheReaderOrInsideTheLogLeavesTheScrollPositionAlone() throws {
        // Nothing above the reader changes height, so the clip itself must not move either.
        let rig = try makeScrollRig(long: [.planChecklist], index: 944)
        let anchors = try scrollIntoPlan(rig)
        let origin = originY(rig)
        let logEvents: [(String, () throws -> Void)] = [
            ("the log tail refreshes", { rig.detail.setLogAttributed(MDFixtures.logText(lines: 120, long: true)) }),
            ("the log tail refreshes again", { rig.detail.setLogAttributed(MDFixtures.logText(lines: 40, long: false)) }),
        ]
        for (name, event) in logEvents {
            try assertAnchorsHold(rig, name, .either, anchors: anchors, event: event)
            XCTAssertEqual(originY(rig), origin, accuracy: tolerance, "after \"\(name)\" nothing above the reader changed, yet the clip moved")
        }
        // The plan is replaced under the reader (its rows are new views): the plan's own top has not moved.
        try rig.setPlan(items: 300)
        rig.awaitRendered()
        XCTAssertEqual(originY(rig), origin, accuracy: tolerance, "a longer plan replaced the rows in view and the reader's place moved")
    }

    func testTheScrollPositionStaysWhenTheDocumentGrowsBelowTheViewport() throws {
        let rig = try makeScrollRig(long: [.planChecklist], index: 934)
        scrollAndConfirm(rig, toY: 300)
        let before = try XCTUnwrap(scrollView(rig).documentView).frame.height

        try rig.setPlan(items: 400)
        rig.awaitRendered()

        let after = try XCTUnwrap(scrollView(rig).documentView).frame.height
        XCTAssertGreaterThan(after, before + 1_000, "precondition: the document grew (\(before) -> \(after))")
        XCTAssertEqual(originY(rig), 300, accuracy: tolerance, "the document grew below the viewport and the reader's place moved")
        assertHorizontallyAtRest(rig, "after the plan doubled")
    }

    func testTheScrollPositionStaysWhenTheDocumentGrowsFromEmpty() throws {
        // Short plan first (nothing to scroll), then a long one arrives: still at the top, no jump to the end.
        let rig = try makeScrollRig(long: [], index: 935)
        XCTAssertEqual(originY(rig), 0, accuracy: tolerance)
        try rig.setPlan(items: 300)
        rig.awaitRendered()
        XCTAssertGreaterThan(maxScrollY(rig), 500, "precondition: the document now scrolls")
        XCTAssertEqual(originY(rig), 0, accuracy: tolerance, "content arriving below the top must not carry the reader to the end")
    }

    // MARK: - A shrinking document clamps the position

    func testWhenTheDocumentShrinksThePositionClampsToTheNewEnd() throws {
        for (target, index) in [(200, 936), (3, 937)] {
            let rig = try makeScrollRig(long: [.planChecklist], index: index)
            try rig.setPlan(items: 400)
            rig.awaitRendered()

            let oldMax = maxScrollY(rig)
            XCTAssertGreaterThan(oldMax, 2_000, "precondition: a 400-item plan scrolls a long way")
            scrollAndConfirm(rig, toY: oldMax)

            try rig.setPlan(items: target)
            rig.awaitRendered()

            let newMax = maxScrollY(rig)
            XCTAssertLessThan(newMax + tolerance, oldMax, "precondition: the document shrank (\(oldMax) -> \(newMax))")
            let y = originY(rig)
            XCTAssertGreaterThanOrEqual(y, 0, "400 -> \(target) items: the position went negative")
            XCTAssertLessThanOrEqual(y, newMax + tolerance, "400 -> \(target) items: the position is \(y), beyond the new end \(newMax)")
            XCTAssertEqual(y, newMax, accuracy: tolerance, "400 -> \(target) items: the position clamps to the new end")
            assertHorizontallyAtRest(rig, "400 -> \(target) items")
            rig.close()
        }
    }

    // MARK: - A different job starts at the top

    func testSelectingADifferentJobStartsAtTheTop() throws {
        let rig = try makeScrollRig(long: [.planChecklist], index: 938)
        scrollAndConfirm(rig, toY: 300)

        try rig.selectOtherJob(planItems: 200)

        XCTAssertGreaterThan(maxScrollY(rig), 500, "precondition: the other job scrolls too, so staying at 300 would be possible")
        XCTAssertEqual(originY(rig), 0, accuracy: tolerance, "opening a different job must start at the top")
        assertHorizontallyAtRest(rig, "after selecting another job")
    }

    func testUpdatingToADifferentJobStartsAtTheTop() throws {
        let rig = try makeScrollRig(long: [.planChecklist], index: 939)
        scrollAndConfirm(rig, toY: 300)

        try rig.updateToOtherJob(planItems: 200)

        XCTAssertGreaterThan(maxScrollY(rig), 500, "precondition: the other job scrolls too")
        XCTAssertEqual(originY(rig), 0, accuracy: tolerance, "an update naming a different job is a selection and starts at the top")
    }

    // MARK: - The actions scroll with the content and stay reachable

    func testEveryDecisionButtonCanBeScrolledIntoViewWithLongConsequences() throws {
        let rig = try makeScrollRig(long: [.consequences], index: 942)
        let sv = scrollView(rig)
        let doc = try XCTUnwrap(sv.documentView)
        XCTAssertGreaterThan(doc.frame.height, sv.contentView.bounds.height, "precondition: three long consequences make the detail scroll")

        let buttons = MD.allSubviews(rig.detail).compactMap { $0 as? NSButton }
            .filter { ($0.identifier?.rawValue ?? "").hasPrefix("mother.option.") }
        XCTAssertEqual(buttons.count, MDFixtures.optionCount, "the decision's options are buttons")
        for button in buttons {
            let top = doc.convert(button.bounds, from: button).minY
            scroll(rig, toY: min(max(0, top - 20), maxScrollY(rig)))
            let rect = doc.convert(button.bounds, from: button)
            XCTAssertTrue(sv.documentVisibleRect.contains(rect),
                          "\(button.title): at \(rect), not inside the viewport \(sv.documentVisibleRect) after scrolling to it")
            XCTAssertFalse(button.isHiddenOrHasHiddenAncestor, "\(button.title) is shown")
            let content = try XCTUnwrap(rig.window.contentView)
            XCTAssertTrue(content.bounds.contains(content.convert(button.bounds, from: button)),
                          "\(button.title) is inside the window once scrolled to")
        }
    }

    // MARK: - The harness waits on real conditions

    func testDrainMainQueueRunsABlockQueuedBeforeTheCall() {
        var ran = false
        DispatchQueue.main.async { ran = true }
        XCTAssertTrue(MD.drainMainQueue())
        XCTAssertTrue(ran, "a block queued on the main queue before the drain has run when it returns")
    }

    func testTodosDeliveredJustBeforeSwitchingJobsStillShowForTheNewJob() throws {
        let rig = try makeScrollRig(long: [], index: 950)
        rig.sendPeek(todos: 60)
        try rig.selectOtherJob()

        XCTAssertEqual(rig.renderedCount(prefix: "TODO-"), 60, "the todos delivered before the switch are shown for the new job")
        MD.pump(rig.window, seconds: 0.5)
        XCTAssertEqual(rig.renderedCount(prefix: "TODO-"), 60, "a late delivery for the old job does not clear them")
    }

    func testAwaitRenderedSeesAnUpdateThatWasOnlyQueued() throws {
        let rig = try makeScrollRig(long: [], index: 951)
        rig.sendPeek(todos: 60)
        rig.awaitRendered()
        XCTAssertEqual(rig.renderedCount(prefix: "TODO-"), 60, "precondition: the todos are shown")

        rig.sendPeek(todos: 0)
        rig.awaitRendered()
        XCTAssertEqual(rig.renderedCount(prefix: "TODO-"), 0, "an empty list is not mistaken for 'not yet applied'")
    }

    func testARigWithoutTheStartupErrorShowsNoErrorRow() throws {
        let quiet = try makeScrollRig(long: [], index: 952)
        XCTAssertEqual(quiet.renderedCount(prefix: "ERR"), 0, "startupError: false leaves out the action error")

        let usual = try MD.makeRig(self, long: [], index: 953)
        MD.drainMainQueue()
        MD.pump(usual.window)
        XCTAssertEqual(usual.renderedCount(prefix: "ERR"), 1, "the default rig starts with one action error showing")
    }
}
