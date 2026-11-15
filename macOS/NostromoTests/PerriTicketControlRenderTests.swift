import XCTest
import AppKit
import SwiftUI
import NostromoKit

// Perri side pane, slice 3: the ticket control is an overlay like Conversation and Diff. Rendered pixels in a
// real window at 200 / 320 / 480 pt: no row moves because it is drawn, nothing in it touches its own
// edge (the lesson of the sidebar pill digits, #456 and #457), and the `+2` badge is whole.

@MainActor
final class PerriTicketControlRenderTests: XCTestCase {

    private let widths: [CGFloat] = [200, 320, 480]
    private let site = "carefeed.atlassian.net"
    private var rigs: [PerriRowsRig] = []

    private func rig(_ width: CGFloat, keys: [String], site: String?) -> PerriRowsRig {
        let r = PerriRowsRig(width: width, selected: 4520, withActions: true,
                             tickets: keys.isEmpty ? [:] : [4520: keys], jiraSite: site)
        rigs.append(r)
        return r
    }

    override func tearDown() {
        rigs.forEach { $0.close() }
        rigs = []
        super.tearDown()
    }

    /// Title bands as `PerriRowsRig.titleBands` finds them (bright text in the left 40%), ignoring pixels
    /// inside a control button: at 200 pt the buttons reach into that region and their glyphs are bright too.
    private func titleBands(_ r: PerriRowsRig) throws -> [ClosedRange<Int>] {
        let (pixels, scale) = try r.render()
        let boxes = r.buttonBoxes(pixels, scale: scale)
        let xEnd = Int(CGFloat(pixels.width) * 0.4)
        var bands: [ClosedRange<Int>] = []
        var start: Int?
        for y in 0..<pixels.height {
            var bright = false
            for x in 0..<xEnd where pixels.rgb(x, y).luminance > 180 {
                if boxes.contains(where: { (($0.x0 - 1)...($0.x1 + 1)).contains(x) && (($0.y0 - 1)...($0.y1 + 1)).contains(y) }) { continue }
                bright = true; break
            }
            if bright { if start == nil { start = y } }
            else if let st = start { bands.append(st...(y - 1)); start = nil }
        }
        if let st = start { bands.append(st...(pixels.height - 1)) }
        return bands
    }

    func testNoRowMovesWhetherTheTicketControlIsDrawnOrNot() throws {
        for width in widths {
            let without = rig(width, keys: [], site: site)
            let one = rig(width, keys: ["CORE-2841"], site: site)
            let three = rig(width, keys: ["CORE-2841", "PAYM-77", "INT-9"], site: site)
            let bands = try titleBands(without)
            XCTAssertEqual(bands.count, 5, "five rows at \(Int(width)) pt: \(bands)")
            XCTAssertEqual(try titleBands(one), bands, "one key: rows unmoved at \(Int(width)) pt")
            XCTAssertEqual(try titleBands(three), bands, "three keys: rows unmoved at \(Int(width)) pt")
        }
    }

    func testARowIsExactlyAsTallWithTheTicketControlAsWithout() {
        for width in widths {
            let item = PrListItemModel(repo: "acme/web", number: 4520,
                                       title: "A pull request title that is long enough to wrap onto a second line at the narrow width",
                                       author: "dev", bucket: "needs_review", ciState: .success, newActivity: true,
                                       url: "https://github.com/acme/web/pull/4520", headSha: "abc")
            let model = item.toRowModel(marked: true)
            let actions = PerriRowActions(openConversation: { _, _ in }, openDiff: { _, _ in }, jiraSite: { self.site })
            func height(_ keys: [String]) -> CGFloat {
                NSHostingView(rootView: PerriQueueRow(model: model, repo: "acme/web", number: 4520, actions: actions,
                                                      tickets: keys, onLoad: {}).frame(width: width - 16)).fittingSize.height
            }
            XCTAssertEqual(height(["CORE-2841", "PAYM-77", "INT-9"]), height([]), accuracy: 0.01, "\(Int(width)) pt")
        }
    }

    func testTheTicketControlsGlyphsAndTheBadgeSitAtLeastTwoPixelsInsideTheirButtons() throws {
        for width in widths {
            let r = rig(width, keys: ["CORE-2841", "PAYM-77", "INT-9"], site: site)
            let (pixels, scale) = try r.render()
            let boxes = r.buttonBoxes(pixels, scale: scale).sorted { $0.x0 < $1.x0 }
            XCTAssertEqual(boxes.count, 4, "\(Int(width)) pt: \(boxes). Colours: \(pixels.summary())")
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
                XCTAssertNotNil(glyph, "\(box) shows a glyph at \(Int(width)) pt")
                XCTAssertEqual(touchingEdge, 0, "glyph pixels within 2 px of the edge (clipped?) in \(box) at \(Int(width)) pt")
                if let g = glyph {
                    XCTAssertGreaterThanOrEqual(g.x0 - box.x0, 2, "left inset at \(Int(width)) pt")
                    XCTAssertGreaterThanOrEqual(box.x1 - g.x1, 2, "right inset at \(Int(width)) pt")
                    XCTAssertGreaterThanOrEqual(g.y0 - box.y0, 2, "top inset at \(Int(width)) pt")
                    XCTAssertGreaterThanOrEqual(box.y1 - g.y1, 2, "bottom inset at \(Int(width)) pt")
                }
            }
        }
    }

    func testTheTicketControlsStayInsideTheListAtEveryWidth() throws {
        for width in widths {
            let r = rig(width, keys: ["CORE-2841", "PAYM-77", "INT-9"], site: site)
            let (pixels, scale) = try r.render()
            for box in r.buttonBoxes(pixels, scale: scale) {
                XCTAssertGreaterThanOrEqual(box.x0, Int(8 * scale), "not pushed off the left at \(Int(width)) pt")
                XCTAssertLessThanOrEqual(box.x1, pixels.width - Int(8 * scale), "kept off the right edge at \(Int(width)) pt: \(box)")
            }
        }
    }

    func testTheRowDrawsNoTicketPixelsWithoutASite() throws {
        for width in widths {
            let withSite = rig(width, keys: ["CORE-2841"], site: site)
            let noSite = rig(width, keys: ["CORE-2841"], site: nil)
            let none = rig(width, keys: [], site: site)
            let (a, scale) = try withSite.render()
            let (b, _) = try noSite.render()
            let (c, _) = try none.render()
            XCTAssertEqual(withSite.buttonBoxes(a, scale: scale).count, 3)
            XCTAssertEqual(noSite.buttonBoxes(b, scale: scale).count, 2)
            XCTAssertEqual(none.buttonBoxes(c, scale: scale).count, 2)
        }
    }
}
