import XCTest
import AppKit
import SwiftUI
import NostromoKit

// Perri side pane, slice 2: the Conversation and Diff controls on a queue row.
//
//   * they are an overlay: no row moves or changes height whether the controls are drawn or not
//     (criterion 10), at every list width
//   * only the selected row and the hovered row draw them; every other row looks as it did
//   * a drawn control's glyph and label sit well inside its own button, at every width: nothing is clipped
//     at an edge (the lesson of the sidebar pill digits, #456 and #457)
//
// The real `PaneContentView` is rendered inside a real window and read back pixel by pixel. The buttons are
// found by their fill colour, the rows by the bright text of each title, so nothing is read from the views.

@MainActor
final class PerriRowControlsRenderTests: XCTestCase {

    private let widths: [CGFloat] = [200, 320, 480]
    private var rigs: [PerriRowsRig] = []

    private func rig(width: CGFloat, selected: Int? = 4520, withActions: Bool = true) -> PerriRowsRig {
        let r = PerriRowsRig(width: width, selected: selected, withActions: withActions)
        rigs.append(r)
        return r
    }

    override func tearDown() {
        rigs.forEach { $0.close() }
        rigs = []
        super.tearDown()
    }

    /// The vertical span of row `index` (0-based) in pixels, from the title bands.
    private func span(_ index: Int, bands: [ClosedRange<Int>], scale: CGFloat, height: Int) -> ClosedRange<Int> {
        let top = bands[index].lowerBound - Int(6 * scale)
        let bottom = index + 1 < bands.count ? bands[index + 1].lowerBound - Int(6 * scale) - 1 : height - 1
        return top...bottom
    }

    // MARK: Criterion 10: nothing moves

    func testNoRowMovesWhetherTheControlsAreDrawnOrNotAtEveryWidth() throws {
        for width in widths {
            let plain = rig(width: width, selected: nil, withActions: false)    // the queue every other pane shows
            let idle = rig(width: width, selected: nil, withActions: true)      // a Perri focus, no row selected
            let drawn = rig(width: width, selected: 4520, withActions: true)    // row 2 selected: its controls are drawn

            let plainBands = plain.titleBands(try plain.render().pixels)
            XCTAssertEqual(plainBands.count, 5, "five rows, five titles at \(Int(width)) pt: \(plainBands)")
            XCTAssertEqual(idle.titleBands(try idle.render().pixels), plainBands, "controls present but not drawn: rows unmoved at \(Int(width)) pt")
            XCTAssertEqual(drawn.titleBands(try drawn.render().pixels), plainBands, "controls drawn on row 2: no row moved at \(Int(width)) pt")
        }
    }

    func testARowIsExactlyAsTallWithTheControlsAsWithout() {
        for width in widths {
            for marked in [false, true] {
                let item = PrListItemModel(repo: "acme/web", number: 4520, title: "A pull request title that is long enough to wrap onto a second line at the narrow width",
                                           author: "dev", bucket: "needs_review", ciState: .success, newActivity: true,
                                           url: "https://github.com/acme/web/pull/4520", headSha: "abc")
                let model = item.toRowModel(marked: marked)
                let rowWidth = width - 16
                let bare = NSHostingView(rootView: NostromoKit.PerriPRRow(model: model).frame(width: rowWidth))
                let withControls = NSHostingView(rootView: PerriQueueRow(
                    model: model, repo: "acme/web", number: 4520,
                    actions: PerriRowActions(openConversation: { _, _ in }, openDiff: { _, _ in }), onLoad: {}).frame(width: rowWidth))
                XCTAssertEqual(withControls.fittingSize.height, bare.fittingSize.height, accuracy: 0.01,
                               "marked \(marked), \(Int(width)) pt")
            }
        }
    }

    // MARK: Which rows draw controls

    func testAnUnselectedUnhoveredRowDrawsNoControlPixels() throws {
        for width in widths {
            let plain = rig(width: width, selected: nil, withActions: false)
            let idle = rig(width: width, selected: nil, withActions: true)
            let (plainPixels, scale) = try plain.render()
            let (idlePixels, _) = try idle.render()

            XCTAssertEqual(idle.buttonBoxes(idlePixels, scale: scale), [], "no button anywhere at \(Int(width)) pt")
            var differing = 0
            for y in 0..<plainPixels.height { for x in 0..<plainPixels.width where plainPixels.rgb(x, y) != idlePixels.rgb(x, y) { differing += 1 } }
            XCTAssertLessThanOrEqual(differing, plainPixels.width * plainPixels.height / 2000,
                                     "the queue looks as it did: \(differing) pixels differ at \(Int(width)) pt")
        }
    }

    func testTheSelectedRowDrawsTwoControlsAndNoOtherRowDoes() throws {
        for width in widths {
            let r = rig(width: width)
            let (pixels, scale) = try r.render()
            let bands = r.titleBands(pixels)
            XCTAssertEqual(bands.count, 5)
            guard bands.count == 5 else { continue }
            let boxes = r.buttonBoxes(pixels, scale: scale)
            XCTAssertEqual(boxes.count, 2, "Conversation and Diff at \(Int(width)) pt: \(boxes). Colours: \(pixels.summary())")
            let row2 = span(1, bands: bands, scale: scale, height: pixels.height)
            for box in boxes {
                XCTAssertTrue(row2.contains(box.centre.y), "the controls sit on the selected row (\(box.centre.y) in \(row2)) at \(Int(width)) pt")
            }
        }
    }

    func testAHoveredRowDrawsItsControlsAsWellAsTheSelectedOne() throws {
        for width in widths {
            let r = rig(width: width)
            let (before, scale) = try r.render()
            let bands = r.titleBands(before)
            guard bands.count == 5 else { return XCTFail("five rows expected, got \(bands)") }
            let row4 = span(3, bands: bands, scale: scale, height: before.height)

            r.hover(px: Int(60 * scale), py: bands[3].lowerBound + 2, scale: scale)

            let (after, _) = try r.render()
            let boxes = r.buttonBoxes(after, scale: scale)
            XCTAssertEqual(boxes.count, 4, "row 2 (selected) and row 4 (hovered) at \(Int(width)) pt: \(boxes). Colours: \(after.summary())")
            XCTAssertEqual(boxes.filter { row4.contains($0.centre.y) }.count, 2, "two of them on row 4")
            XCTAssertEqual(r.titleBands(after), bands, "and still nothing moved")
        }
    }

    // MARK: No clipping

    func testEveryControlsGlyphSitsAtLeastTwoPixelsInsideItsButtonAtEveryWidth() throws {
        for width in widths {
            let r = rig(width: width)
            let (pixels, scale) = try r.render()
            let boxes = r.buttonBoxes(pixels, scale: scale)
            XCTAssertEqual(boxes.count, 2, "\(Int(width)) pt. Colours: \(pixels.summary())")
            for box in boxes {
                var glyph: PerriRowsRig.Box?
                var touchingEdge = 0
                for y in box.y0...box.y1 {
                    for x in box.x0...box.x1 where pixels.rgb(x, y).luminance > 150 {
                        glyph = PerriRowsRig.Box(x0: min(glyph?.x0 ?? x, x), y0: min(glyph?.y0 ?? y, y),
                                                 x1: max(glyph?.x1 ?? x, x), y1: max(glyph?.y1 ?? y, y))
                        if x < box.x0 + 2 || x > box.x1 - 2 || y < box.y0 + 2 || y > box.y1 - 2 { touchingEdge += 1 }
                    }
                }
                XCTAssertNotNil(glyph, "the button \(box) shows a glyph at \(Int(width)) pt")
                XCTAssertEqual(touchingEdge, 0, "glyph pixels within 2 px of the button's edge (clipped?) in \(box) at \(Int(width)) pt")
                if let g = glyph {
                    XCTAssertGreaterThanOrEqual(g.x0 - box.x0, 2, "left inset at \(Int(width)) pt")
                    XCTAssertGreaterThanOrEqual(box.x1 - g.x1, 2, "right inset at \(Int(width)) pt")
                    XCTAssertGreaterThanOrEqual(g.y0 - box.y0, 2, "top inset at \(Int(width)) pt")
                    XCTAssertGreaterThanOrEqual(box.y1 - g.y1, 2, "bottom inset at \(Int(width)) pt")
                }
            }
        }
    }

    func testTheControlsStayInsideTheListAtEveryWidth() throws {
        for width in widths {
            let r = rig(width: width)
            let (pixels, scale) = try r.render()
            for box in r.buttonBoxes(pixels, scale: scale) {
                XCTAssertGreaterThanOrEqual(box.x0, Int(8 * scale), "not pushed off the left at \(Int(width)) pt")
                XCTAssertLessThanOrEqual(box.x1, pixels.width - Int(8 * scale), "kept off the right edge at \(Int(width)) pt: \(box)")
            }
        }
    }

    func testTheControlsAreComfortableToHitAtEveryWidth() throws {
        for width in widths {
            let r = rig(width: width)
            let (pixels, scale) = try r.render()
            for box in r.buttonBoxes(pixels, scale: scale) {
                XCTAssertGreaterThanOrEqual(CGFloat(box.x1 - box.x0 + 1) / scale, 20, "wide enough at \(Int(width)) pt")
                XCTAssertGreaterThanOrEqual(CGFloat(box.y1 - box.y0 + 1) / scale, 14, "tall enough at \(Int(width)) pt")
            }
        }
    }

    func testTheWideListNamesTheButtonsAndTheNarrowListFallsBackToIcons() throws {
        func firstButtonWidth(_ width: CGFloat) throws -> CGFloat {
            let r = rig(width: width)
            let (pixels, scale) = try r.render()
            let boxes = r.buttonBoxes(pixels, scale: scale)
            return CGFloat((boxes.first.map { $0.x1 - $0.x0 + 1 }) ?? 0) / scale
        }
        let narrow = try firstButtonWidth(200)
        let wide = try firstButtonWidth(480)
        XCTAssertGreaterThan(wide, narrow + 30, "480 pt shows a labelled button (\(wide) pt), 200 pt an icon (\(narrow) pt)")
    }
}
