import XCTest
import AppKit
import NostromoKit

// MF2c: how the marker looks and lays out. One line, a fixed 22 pt tall at every width, never wider
// than the pane (the line truncates at its tail), and the tooltip carries what the line cuts off.
//
// WakeMarkerView, WakeMarkerText and ChatTurnView are compiled into this target directly. No window,
// no wall clock, no real pasteboard.

final class WakeMarkerAppearanceTests: XCTestCase {

    /// A 400-character title, wide letters, and a hostile variant carrying every control and
    /// direction scalar the sanitizer exists for.
    private static let wideTitle = String(repeating: "W", count: 400)
    /// Copied from NostromoKit's `HostileContent`, which the Mac target cannot see: ANSI, OSC 8, bidi,
    /// tag characters, NUL, line breaks and the invisible fillers, then the wide letters.
    private static let hostileTitle = "\u{1B}[31mred\u{1B}[0m \u{1B}]8;;https://x\u{1B}\\label\u{1B}]8;;\u{1B}\\"
        + "safe\u{202E}evil\u{2066}iso\u{2069}\u{200E}\u{200F}tail tag\u{E0041}\u{E007F}ged before\u{0}after "
        + "one\ntwo\r\nthree\tfour\u{7F}five \u{2028}\u{2029} a\u{034F}b\u{115F}c\u{1160}d\u{17B4}e\u{17B5}f\u{2800}g\u{3164}h\u{FFA0}i "
        + String(repeating: "W", count: 400)

    /// Scalars that must never survive onto a drawn row (as `HostileContent.isForbiddenOnARow`).
    private static func isForbiddenOnARow(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0000 ... 0x001F, 0x007F, 0x0080 ... 0x009F,
             0x200E, 0x200F, 0x202A ... 0x202E, 0x2066 ... 0x2069,
             0xE0000 ... 0xE007F,
             0x034F, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x2800, 0x3164, 0xFFA0:
            return true
        default:
            return false
        }
    }
    private static let shortTitle = "short"

    private func content(_ title: String) -> WakeMarkerContent {
        WakeMarkerText.motherNotice([MotherNoticeItemWire(jobId: "j-1", title: title, state: "succeeded", since: [],
                                                           prUrl: nil, prNumber: 391)])
    }

    private func marker(_ content: WakeMarkerContent) -> WakeMarkerView {
        WakeMarkerView(content: content, noticeText: "raw", router: { _ in }, pasteboard: MotherNoticeFixtures.pasteboard(self))
    }

    /// The marker pinned to `width` and laid out.
    private func laidOut(_ content: WakeMarkerContent, width: CGFloat) -> WakeMarkerView {
        let view = marker(content)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        view.frame = NSRect(x: 0, y: 0, width: width, height: TurnHeightEstimator.wakeMarkerHeight)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func labels(in view: NSView) -> [NSTextField] {
        MotherNoticeFixtures.descendants(of: view).compactMap { $0 as? NSTextField }
    }

    func testTheHeightIsFixedAtNarrowAndWideWidthsForAHostileLongTitle() {
        for title in [Self.wideTitle, Self.hostileTitle] {
            for width: CGFloat in [220, 700] {
                let view = laidOut(content(title), width: width)

                XCTAssertEqual(view.arithmeticHeight(atWidth: width), TurnHeightEstimator.wakeMarkerHeight, "width \(width)")
            }
        }
    }

    func testALongTitleDoesNotMakeTheViewTallerThanAShortOne() {
        for width: CGFloat in [220, 700] {
            let short = laidOut(content(Self.shortTitle), width: width).fittingSize.height
            for title in [Self.wideTitle, Self.hostileTitle] {
                XCTAssertEqual(laidOut(content(title), width: width).fittingSize.height, short, accuracy: 0.5,
                               "width \(width): the label is one line, so a long title adds no height")
            }
        }
    }

    func testTheLabelIsOneLineThatTruncatesAtItsTail() throws {
        let view = laidOut(content(Self.wideTitle), width: 220)

        let label = try XCTUnwrap(labels(in: view).first { $0.stringValue == view.shownText }, "the marker draws its line in a label")
        XCTAssertEqual(label.maximumNumberOfLines, 1)
        XCTAssertEqual(label.lineBreakMode, .byTruncatingTail)
        XCTAssertLessThan(label.contentCompressionResistancePriority(for: .horizontal), .defaultHigh,
                          "the pane's width wins over the text's")
    }

    func testTheLabelNeverWidensTheViewBeyondTheGivenWidth() {
        for title in [Self.wideTitle, Self.hostileTitle] {
            for width: CGFloat in [220, 700] {
                let view = laidOut(content(title), width: width)

                XCTAssertLessThanOrEqual(view.fittingSize.width, width + 0.5, "width \(width)")
                for label in labels(in: view) {
                    // The alignment rect: a text field's frame is 2 pt wider each side (the cell's own padding).
                    let rect = label.alignmentRect(forFrame: label.frame)
                    XCTAssertLessThanOrEqual(rect.maxX, width + 0.5, "width \(width): the label stays inside the view")
                    XCTAssertGreaterThanOrEqual(rect.minX, -0.5)
                }
            }
        }
    }

    func testTheTooltipCarriesTheFullTitleUpToItsCap() {
        let view = marker(content(Self.wideTitle))

        let tooltip = view.toolTip ?? ""
        XCTAssertTrue(tooltip.contains(String(repeating: "W", count: 119) + "…"), "the tooltip's title is 119 characters and an ellipsis")
        XCTAssertFalse(tooltip.contains(String(repeating: "W", count: 120)))
        XCTAssertGreaterThan(tooltip.count, view.shownText.count, "the tooltip says more than the cut-off line")
    }

    func testAHostileTitleLeavesNoControlOrDirectionScalarInTheLineOrTheTooltip() {
        let view = marker(content(Self.hostileTitle))

        for text in [view.shownText, view.toolTip ?? ""] {
            for scalar in text.unicodeScalars where scalar != "\n" || text == view.shownText {
                XCTAssertFalse(Self.isForbiddenOnARow(scalar), "U+\(String(scalar.value, radix: 16, uppercase: true))")
            }
        }
        XCTAssertFalse(view.shownText.contains("\n"))
    }

    // MARK: In a turn

    func testABlocklessNoticeTurnHasTheSameHeightAtNarrowAndWideWidths() {
        let turn = MotherNoticeFixtures.turn(origin: .motherJobNotice(items: [
            MotherNoticeItemWire(jobId: "j-1", title: Self.wideTitle, state: "succeeded", since: [], prUrl: nil, prNumber: 391)]))
        let view = MotherNoticeFixtures.turnView(turn)

        view.setIslandWidth(700)
        let wide = view.islandHeight()
        view.setIslandWidth(220)
        let narrow = view.islandHeight()

        XCTAssertEqual(narrow, wide, accuracy: 0.5, "a marker is one line however narrow the pane")
        XCTAssertEqual(narrow, TurnHeightEstimator.estimate(turn, width: 220), accuracy: 1)
    }

    func testAForgedSuffixTitleStillShowsTheRealStateWithinTheVisibleWidthAt220() throws {
        let forged = WakeMarkerText.motherNotice([MotherNoticeItemWire(
            jobId: "j-1", title: "Deploy\" succeeded · PR #1 \"x" + String(repeating: " padding", count: 20),
            state: "failed", since: [], prUrl: nil, prNumber: 9)])
        let view = laidOut(forged, width: 220)
        let label = try XCTUnwrap(labels(in: view).first)
        let font = try XCTUnwrap(label.font)
        let leading = String(label.stringValue.prefix(while: { $0 != "\"" }))   // "⟲ Mother: failed "

        XCTAssertEqual(leading, "⟲ Mother: failed ")
        let leadingWidth = (leading as NSString).size(withAttributes: [.font: font]).width
        XCTAssertLessThan(leadingWidth, 220 - 16, "the real state sits inside the visible width, ahead of the title")
    }

    /// The drawn layout puts only `bubbleGap` between the user slot and the first column and adds
    /// `blockSpacing` only after column 0, so the first block adds exactly its own height.
    func testTheFirstBlockOfANoticeTurnAddsExactlyItsOwnHeightWithNoBlockSpacing() {
        let blockless = MotherNoticeFixtures.turn()
        let withText = MotherNoticeFixtures.turn(blocks: [.text("Noted.")])
        for width: CGFloat in [220, 700, 900] {
            let own = TurnHeightEstimator.estimate(block: .text("Noted."), characters: 6,
                                                   width: width * TurnHeightEstimator.blocksWidthFraction - 14)
            XCTAssertEqual(TurnHeightEstimator.estimate(withText, width: width) - TurnHeightEstimator.estimate(blockless, width: width),
                           own, accuracy: 0.001, "width \(width)")
        }
    }
}
