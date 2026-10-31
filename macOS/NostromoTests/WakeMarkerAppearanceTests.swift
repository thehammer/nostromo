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
    private static let hostileTitle = String((HostileContent.kitchenSink + String(repeating: "W", count: 400)).prefix(2_000))
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
                    XCTAssertLessThanOrEqual(label.frame.maxX, width + 0.5, "width \(width): the label stays inside the view")
                    XCTAssertGreaterThanOrEqual(label.frame.minX, -0.5)
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
                XCTAssertFalse(HostileContent.isForbiddenOnARow(scalar), "U+\(String(scalar.value, radix: 16, uppercase: true))")
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
}
