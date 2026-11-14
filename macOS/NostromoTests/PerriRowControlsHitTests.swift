import XCTest
import AppKit
import NostromoKit

// Perri side pane, slice 2: pressing a row control opens a side-pane tab and does NOT load the PR
// (criterion 8); pressing anywhere else on the row loads the PR and opens nothing. Real mouse events go
// through a real window to the real `PaneContentView`; the buttons are found where they are drawn.

@MainActor
final class PerriRowControlsHitTests: XCTestCase {

    private var rigs: [PerriRowsRig] = []

    private func makeRig(width: CGFloat, reviewing: ReviewingPR? = nil, selected: Int? = 4520) -> PerriRowsRig {
        let r = PerriRowsRig(width: width, selected: selected, withActions: true, reviewing: reviewing)
        rigs.append(r)
        return r
    }

    override func tearDown() {
        rigs.forEach { $0.close() }
        rigs = []
        super.tearDown()
    }

    /// The two control buttons on the selected row, left one first (Conversation, then Diff).
    private func controls(_ r: PerriRowsRig) throws -> (conversation: PerriRowsRig.Box, diff: PerriRowsRig.Box, scale: CGFloat) {
        let (pixels, scale) = try r.render()
        let boxes = r.buttonBoxes(pixels, scale: scale).sorted { $0.x0 < $1.x0 }
        XCTAssertEqual(boxes.count, 2, "the selected row draws Conversation and Diff. Colours: \(pixels.summary())")
        return (try XCTUnwrap(boxes.first), try XCTUnwrap(boxes.last), scale)
    }

    func testPressingConversationOpensItForThatPRAndDoesNotLoadIt() throws {
        for width in [200, 320, 480] as [CGFloat] {
            let r = makeRig(width: width)
            let (conversation, _, scale) = try controls(r)

            r.click(px: conversation.centre.x, py: conversation.centre.y, scale: scale)

            XCTAssertEqual(r.recordedConversations, [4520], "Conversation opened for #4520 at \(Int(width)) pt")
            XCTAssertEqual(r.recordedDiffs, [])
            XCTAssertEqual(r.recordedLoads, [], "criterion 8: the row's own load never ran at \(Int(width)) pt")
        }
    }

    func testPressingDiffOpensItForThatPRAndDoesNotLoadIt() throws {
        for width in [200, 320, 480] as [CGFloat] {
            let r = makeRig(width: width)
            let (_, diff, scale) = try controls(r)

            r.click(px: diff.centre.x, py: diff.centre.y, scale: scale)

            XCTAssertEqual(r.recordedDiffs, [4520], "Diff opened for #4520 at \(Int(width)) pt")
            XCTAssertEqual(r.recordedConversations, [])
            XCTAssertEqual(r.recordedLoads, [], "criterion 8 at \(Int(width)) pt")
        }
    }

    func testPressingAControlTwiceOpensItTwiceAndStillLoadsNothing() throws {
        let r = makeRig(width: 320)
        let (conversation, _, scale) = try controls(r)
        r.click(px: conversation.centre.x, py: conversation.centre.y, scale: scale)
        r.click(px: conversation.centre.x, py: conversation.centre.y, scale: scale)
        XCTAssertEqual(r.recordedConversations, [4520, 4520])
        XCTAssertEqual(r.recordedLoads, [])
    }

    func testClickingElsewhereOnTheRowLoadsThePRAndOpensNothing() throws {
        for width in [200, 320, 480] as [CGFloat] {
            let r = makeRig(width: width)
            let (pixels, scale) = try r.render()
            let bands = r.titleBands(pixels)
            XCTAssertEqual(bands.count, 5)
            guard bands.count == 5 else { continue }

            // Row 3's title, on its left: nowhere near a control.
            r.click(px: Int(60 * scale), py: bands[2].lowerBound + 2, scale: scale)

            XCTAssertEqual(r.recordedLoads, [4521], "row 3 loaded at \(Int(width)) pt")
            XCTAssertEqual(r.recordedConversations, [])
            XCTAssertEqual(r.recordedDiffs, [])
        }
    }

    func testClickingTheSelectedRowOutsideItsControlsStillLoadsIt() throws {
        let r = makeRig(width: 480)
        let (pixels, scale) = try r.render()
        let bands = r.titleBands(pixels)
        guard bands.count == 5 else { return XCTFail("\(bands)") }

        r.click(px: Int(60 * scale), py: bands[1].lowerBound + 2, scale: scale)

        XCTAssertEqual(r.recordedLoads, [4520])
        XCTAssertEqual(r.recordedConversations, [])
        XCTAssertEqual(r.recordedDiffs, [])
    }

    func testTheReviewingRowsControlsOpenTabsForThePinnedPRAndLoadNothing() throws {
        // The pinned PR is not in the queue: a "Reviewing #N" row stands in for it, with the same controls.
        let reviewing = ReviewingPR(repo: "acme/web", number: 9001, title: "Pinned but not queued")
        let r = makeRig(width: 480, reviewing: reviewing, selected: nil)
        let (pixels, scale) = try r.render()
        let boxes = r.buttonBoxes(pixels, scale: scale).sorted { $0.x0 < $1.x0 }
        XCTAssertEqual(boxes.count, 2, "the reviewing row always shows its controls: \(boxes)")
        guard boxes.count == 2 else { return }

        r.click(px: boxes[0].centre.x, py: boxes[0].centre.y, scale: scale)
        r.click(px: boxes[1].centre.x, py: boxes[1].centre.y, scale: scale)

        XCTAssertEqual(r.recordedConversations, [9001])
        XCTAssertEqual(r.recordedDiffs, [9001])
        XCTAssertEqual(r.recordedLoads, [])
    }

    func testAPinnedPRThatIsInTheQueueGetsNoSeparateReviewingRow() throws {
        let reviewing = ReviewingPR(repo: "acme/web", number: 4520, title: "Row title 2")
        let r = makeRig(width: 480, reviewing: reviewing, selected: 4520)
        let (pixels, scale) = try r.render()
        XCTAssertEqual(r.titleBands(pixels).count, 5, "no sixth row")
        XCTAssertEqual(r.buttonBoxes(pixels, scale: scale).count, 2, "only the queue row's own controls")
    }

    // MARK: Wiring: only a Perri focus gets the controls

    func testAPerriFocusGetsRowControlsAndAnotherFocusDoesNot() throws {
        let perri = Focus(id: "1a2b3c4d-1111", agentTag: "perri", projectPath: "/tmp/row-controls-wiring", isBuiltIn: false)
        let cody = Focus(id: "1a2b3c4d-2222", agentTag: "cody", projectPath: "/tmp/row-controls-wiring", isBuiltIn: false)
        let perriView = DynamicFocusView(focus: perri, windowId: "row-controls-\(UUID().uuidString.prefix(6))")
        let codyView = DynamicFocusView(focus: cody, windowId: "row-controls-\(UUID().uuidString.prefix(6))")

        let perriQueue = try XCTUnwrap(perriView.makeLeafView(paneId: "queue-test", reusing: nil) as? PaneContentNSView)
        let codyQueue = try XCTUnwrap(codyView.makeLeafView(paneId: "queue-test", reusing: nil) as? PaneContentNSView)

        XCTAssertNotNil(perriQueue.rowActions, "a Perri focus's queue offers the side-pane controls")
        XCTAssertNil(codyQueue.rowActions, "every other pane's queue is as it was")
    }
}
