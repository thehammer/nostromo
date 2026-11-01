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

    /// The second block adds `blockSpacing` exactly once (not per block) plus its own height.
    func testASecondBlockOfANoticeTurnAddsItsOwnHeightAndBlockSpacingExactlyOnce() {
        let one = MotherNoticeFixtures.turn(blocks: [.text("Noted.")])
        let two = MotherNoticeFixtures.turn(blocks: [.text("Noted."), .text("Done.")])
        for width: CGFloat in [220, 700, 900] {
            let textWidth = width * TurnHeightEstimator.blocksWidthFraction - 14
            let second = TurnHeightEstimator.estimate(block: .text("Done."), characters: 5, width: textWidth)
            XCTAssertEqual(TurnHeightEstimator.estimate(two, width: width) - TurnHeightEstimator.estimate(one, width: width),
                           TurnHeightEstimator.blockSpacing + second, accuracy: 0.001, "width \(width)")
        }
    }
}

// MARK: - Background task wakes (BA6b)

private final class WakeNotKeyWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var isKeyWindow: Bool { false }
}

final class TaskWakeMarkerAppearanceTests: XCTestCase {

    private static let hostileDescription = "\u{1B}[31mred\u{1B}[0m safe\u{202E}evil\u{2066}iso\u{2069} a\u{034F}b\u{115F}c\u{3164}d\u{2028}e "
        + String(repeating: "W", count: 10_240)

    private func content(_ description: String, n: Int = 1) -> WakeMarkerContent {
        WakeMarkerText.taskWake(Array(repeating: TaskWakeItemWire(taskId: "b1", toolUseId: nil, kind: "shell", outcome: "failed",
                                                                 description: description), count: n), omitted: 0)
    }

    private func laidOut(_ content: WakeMarkerContent, width: CGFloat) -> WakeMarkerView {
        let view = WakeMarkerView(content: content, noticeText: "raw", router: { _ in }, pasteboard: MotherNoticeFixtures.pasteboard(self))
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        view.frame = NSRect(x: 0, y: 0, width: width, height: TurnHeightEstimator.wakeMarkerHeight)
        view.layoutSubtreeIfNeeded()
        return view
    }

    func testAHugeHostileDescriptionIsOneFixedHeightLineThatNeverWidensThePane() {
        let tall = laidOut(content("short"), width: 220).fittingSize.height
        for width: CGFloat in [220, 700] {
            let view = laidOut(content(Self.hostileDescription), width: width)

            XCTAssertEqual(view.arithmeticHeight(atWidth: width), TurnHeightEstimator.wakeMarkerHeight)
            XCTAssertEqual(view.fittingSize.height, tall, accuracy: 0.5)
            XCTAssertLessThanOrEqual(view.fittingSize.width, width + 0.5)
            XCTAssertFalse(view.shownText.contains("\n"))
            XCTAssertLessThan(view.shownText.count, 140)
            XCTAssertTrue((view.toolTip ?? "").contains("…"), "the tooltip carries what the line cuts off, capped")
            let label = MotherNoticeFixtures.descendants(of: view).compactMap { $0 as? NSTextField }.first
            XCTAssertEqual(label?.lineBreakMode, .byTruncatingTail)
            XCTAssertEqual(label?.maximumNumberOfLines, 1)
        }
    }

    func testTheRealStateStaysVisibleAt220ForALongDescription() throws {
        let view = laidOut(content(String(repeating: " padding", count: 30)), width: 220)
        let label = try XCTUnwrap(MotherNoticeFixtures.descendants(of: view).compactMap { $0 as? NSTextField }.first)
        let font = try XCTUnwrap(label.font)
        let leading = String(label.stringValue.prefix(while: { $0 != "\"" }))

        XCTAssertEqual(leading, "⟲ Shell: failed ")
        XCTAssertLessThan((leading as NSString).size(withAttributes: [.font: font]).width, 220 - 16)
    }

    func testMutedTextMeasuresAtLeastFourPointFiveToOneInKeyAndNonKeyWindows() throws {
        func luminance(_ color: NSColor) -> Double {
            let c = color.usingColorSpace(.sRGB) ?? color
            func lin(_ v: CGFloat) -> Double { let s = Double(v); return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
        }
        for keyWindow in [true, false] {
            let window: NSWindow = keyWindow
                ? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60), styleMask: [.titled], backing: .buffered, defer: true)
                : WakeNotKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60), styleMask: [.titled], backing: .buffered, defer: true)
            let view = laidOut(content("CI"), width: 300)
            window.contentView?.addSubview(view)
            let label = try XCTUnwrap(MotherNoticeFixtures.descendants(of: view).compactMap { $0 as? NSTextField }.first)
            let text = try XCTUnwrap(label.textColor)
            let (a, b) = (luminance(text), luminance(Theme.bg))
            let ratio = (max(a, b) + 0.05) / (min(a, b) + 0.05)
            print("[TaskWakeMarkerAppearance key=\(keyWindow)] fgMuted on transcript background \(String(format: "%.2f", ratio)):1")

            XCTAssertGreaterThanOrEqual(ratio, 4.5, "key window: \(keyWindow)")
            XCTAssertEqual(text, Theme.fgMuted)
        }
    }
}
