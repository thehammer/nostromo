import XCTest
import AppKit
import NostromoKit

// MV-2: the job detail scrolls internally. Content taller than the pane is reached by scrolling, not
// by growing the window (MV-1), so the detail holds a vertical `NSScrollView`
// (`MotherJobDetail.contentScrollView`, the scroll view of everything except the log tail and the
// reply box, which keep their own).
//
// The reader's place is theirs: data arriving for the job they are reading (a state change, a progress
// tick, a todo list, log lines, gates, an error, a longer or shorter plan) must not move it, a document
// that shrinks clamps it, and opening a different job starts at the top.
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

    // MARK: - It scrolls

    func testTheDetailHoldsAVerticalScrollViewWhoseDocumentIsTallerThanItsClipForALongPlan() throws {
        let rig = try MD.makeRig(self, long: [.planChecklist], index: 930)
        let sv = scrollView(rig)

        XCTAssertTrue(sv.isDescendant(of: rig.detail), "the content scroll view is inside the detail")
        XCTAssertFalse(sv === rig.detail.logScrollView, "it is not the log tail's scroll view")
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

    func testTheScrollPositionSurvivesDataArrivingForTheJobBeingRead() throws {
        let rig = try MD.makeRig(self, long: [.planChecklist], index: 933)

        let events: [(String, () throws -> Void)] = [
            ("the job's state changes", { rig.setState("running") }),
            ("a progress tick", { rig.setProgress(40) }),
            ("a progress tick again", { rig.setProgress(55) }),
            ("a new peek payload with 60 todos", { rig.sendPeek(todos: 60) }),
            ("a new peek payload with 5 todos", { rig.sendPeek(todos: 5) }),
            ("the log tail refreshes", { rig.detail.setLogAttributed(MDFixtures.logText(lines: 120, long: true)) }),
            ("the log tail refreshes again", { rig.detail.setLogAttributed(MDFixtures.logText(lines: 40, long: false)) }),
            ("gates grow to 40 rows", { rig.setGates(40) }),
            ("gates shrink to 3 rows", { rig.setGates(3) }),
            ("an action error arrives", { rig.host.errorSubject.send(MDFixtures.actionError(long: true)) }),
            ("the job's state changes back", { rig.setState("awaiting") }),
        ]
        for (name, event) in events {
            scrollAndConfirm(rig, toY: 300)
            try event()
            rig.awaitRendered()
            XCTAssertEqual(originY(rig), 300, accuracy: tolerance, "after \"\(name)\" the reader's place moved")
            assertHorizontallyAtRest(rig, "after \"\(name)\"")
        }
    }

    func testTheScrollPositionStaysWhenTheDocumentGrowsBelowTheViewport() throws {
        let rig = try MD.makeRig(self, long: [.planChecklist], index: 934)
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
        let rig = try MD.makeRig(self, long: [], index: 935)
        XCTAssertEqual(originY(rig), 0, accuracy: tolerance)
        try rig.setPlan(items: 300)
        rig.awaitRendered()
        XCTAssertGreaterThan(maxScrollY(rig), 500, "precondition: the document now scrolls")
        XCTAssertEqual(originY(rig), 0, accuracy: tolerance, "content arriving below the top must not carry the reader to the end")
    }

    // MARK: - A shrinking document clamps the position

    func testWhenTheDocumentShrinksThePositionClampsToTheNewEnd() throws {
        for (target, index) in [(200, 936), (3, 937)] {
            let rig = try MD.makeRig(self, long: [.planChecklist], index: index)
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
        let rig = try MD.makeRig(self, long: [.planChecklist], index: 938)
        scrollAndConfirm(rig, toY: 300)

        try rig.selectOtherJob(planItems: 200)

        XCTAssertGreaterThan(maxScrollY(rig), 500, "precondition: the other job scrolls too, so staying at 300 would be possible")
        XCTAssertEqual(originY(rig), 0, accuracy: tolerance, "opening a different job must start at the top")
        assertHorizontallyAtRest(rig, "after selecting another job")
    }

    func testUpdatingToADifferentJobStartsAtTheTop() throws {
        let rig = try MD.makeRig(self, long: [.planChecklist], index: 939)
        scrollAndConfirm(rig, toY: 300)

        try rig.updateToOtherJob(planItems: 200)

        XCTAssertGreaterThan(maxScrollY(rig), 500, "precondition: the other job scrolls too")
        XCTAssertEqual(originY(rig), 0, accuracy: tolerance, "an update naming a different job is a selection and starts at the top")
    }
}
