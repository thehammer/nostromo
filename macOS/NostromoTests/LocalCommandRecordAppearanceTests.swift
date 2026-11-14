import XCTest
import AppKit
import NostromoKit

// The local command record, RENDERED: real pixels and real TextKit layout.
//
// Frame and string checks cannot see the failure these guard against: an expanded record whose height is
// measured a line short draws all its text, but the last line falls below the view and is cut. So the view
// is put on the transcript background, drawn into a bitmap exactly as tall as the view is, and the pixels
// are read back: the header is the muted colour (amber only for the word `error`), the output is muted, and
// the LAST output line's ink is inside the view. The real layout (the body text view's own layout manager)
// must agree with `LocalCommandRecordMetrics` and with `TurnHeightEstimator` at three widths.
//
// LocalCommandRecordView, LocalCommandRecordMetrics, ChatTurnView, TurnHeightEstimator and Theme are compiled
// into this target directly. Reuses `WindowBag` and the luminance helpers of ModelChipAppearanceTests.swift.

private final class RecordHost: NSView {
    override var isFlipped: Bool { true }
}

final class LocalCommandRecordAppearanceTests: XCTestCase {

    private let widths: [CGFloat] = [260, 420, 900]

    /// A borderless window of exactly `size` (a titled one clamps a very short content height), parked
    /// unordered: only its view hierarchy is drawn.
    private func makeWindow(_ size: NSSize) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.appearance = NSAppearance(named: .darkAqua)
        addTeardownBlock { window.orderOut(nil) }
        return window
    }

    // MARK: Fixtures

    private func lines(_ n: Int) -> String { (1...n).map { "line \($0)" }.joined(separator: "\n") }

    /// Five lines, the third long enough to wrap at every width here.
    private var wrapped: String {
        "line 1\nline 2\n" + (1...60).map { "word\($0)" }.joined(separator: " ") + "\nline 4\nline 5 END"
    }

    private var multiLineOutputs: [(name: String, output: String)] {
        [("5 lines", lines(5)), ("200 lines", lines(200)), ("5 lines, one wrapped", wrapped)]
    }

    // MARK: Rendering

    private struct Snapshot {
        let view: LocalCommandRecordView
        let rep: NSBitmapImageRep
        let scale: CGFloat
        let size: NSSize

        /// The pixels of `rect` (points, from the top-left, which is also the view's own flipped space).
        func pixels(in rect: NSRect) -> [NSColor] {
            let r = rect.intersection(NSRect(origin: .zero, size: size))
            guard !r.isNull, r.width > 0, r.height > 0 else { return [] }
            var out: [NSColor] = []
            for y in Int((r.minY * scale).rounded(.down)) ..< Int((r.maxY * scale).rounded(.up)) where y >= 0 && y < rep.pixelsHigh {
                for x in Int((r.minX * scale).rounded(.down)) ..< Int((r.maxX * scale).rounded(.up)) where x >= 0 && x < rep.pixelsWide {
                    if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) { out.append(c) }
                }
            }
            return out
        }
    }

    /// The record at `width`, drawn on the transcript background into a bitmap as tall as the record.
    private func render(output: String, stream: String = "stdout", expanded: Bool, width: CGFloat,
                        file: StaticString = #filePath, line: UInt = #line) throws -> Snapshot {
        let view = LocalCommandRecordView(command: "context", args: "", output: output, stream: stream, startExpanded: expanded)
        let height = view.arithmeticHeight(atWidth: width)
        let window = makeWindow(NSSize(width: width, height: height))
        let host = RecordHost(frame: NSRect(x: 0, y: 0, width: width, height: height))
        host.wantsLayer = true
        host.layer?.backgroundColor = Theme.bg.cgColor
        window.contentView = host
        view.frame = host.bounds
        host.addSubview(view)
        host.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds), file: file, line: line)
        host.cacheDisplay(in: host.bounds, to: rep)
        return Snapshot(view: view, rep: rep, scale: CGFloat(rep.pixelsWide) / host.bounds.width, size: host.bounds.size)
    }

    private func isInk(_ c: NSColor) -> Bool { modelRelativeLuminance(c) > 0.06 }

    private func isAmber(_ c: NSColor) -> Bool { c.redComponent - c.blueComponent > 0.15 }

    private func brightest(_ pixels: [NSColor]) -> NSColor? {
        pixels.max { modelRelativeLuminance($0) < modelRelativeLuminance($1) }
    }

    /// `color` as this render path draws it (a swatch of it on the transcript background, read back), so the
    /// comparison is pixels with pixels and the colour-space round trip stays out of the test.
    private func renderedSwatch(_ color: NSColor) throws -> NSColor {
        let size = NSSize(width: 40, height: 40)
        let window = makeWindow(size)
        let host = RecordHost(frame: NSRect(origin: .zero, size: size))
        host.wantsLayer = true
        host.layer?.backgroundColor = Theme.bg.cgColor
        let swatch = NSView(frame: NSRect(x: 10, y: 10, width: 20, height: 20))
        swatch.wantsLayer = true
        swatch.layer?.backgroundColor = color.cgColor
        host.addSubview(swatch)
        window.contentView = host
        host.displayIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
    }

    private func isMuted(_ ink: NSColor, swatch: NSColor) -> Bool {
        abs(ink.redComponent - swatch.redComponent) < 0.12 && abs(ink.greenComponent - swatch.greenComponent) < 0.12
            && abs(ink.blueComponent - swatch.blueComponent) < 0.12
            && modelRelativeLuminance(ink) <= modelRelativeLuminance(swatch) + 0.03
    }

    // MARK: Layout truth

    private func body(of view: LocalCommandRecordView) throws -> NSTextView {
        try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextView }.first, "an open record holds its output in a text view")
    }

    /// The last output line's rect in the record's own (flipped) space, from the real layout manager.
    private func lastLineRect(of view: LocalCommandRecordView) throws -> NSRect {
        let text = try body(of: view)
        let manager = try XCTUnwrap(text.layoutManager)
        let container = try XCTUnwrap(text.textContainer)
        manager.ensureLayout(for: container)
        let local = manager.lineFragmentUsedRect(forGlyphAt: max(manager.numberOfGlyphs - 1, 0), effectiveRange: nil)
        let origin = text.textContainerOrigin
        return NSRect(x: text.frame.minX + origin.x + local.minX, y: text.frame.minY + origin.y + local.minY,
                      width: local.width, height: local.height)
    }

    /// The record's height rebuilt from the body text view's own layout: header, gap, the real used height, padding.
    private func realHeight(of view: LocalCommandRecordView) throws -> CGFloat {
        let text = try body(of: view)
        let manager = try XCTUnwrap(text.layoutManager)
        let container = try XCTUnwrap(text.textContainer)
        manager.ensureLayout(for: container)
        return LocalCommandRecordMetrics.headerHeight + LocalCommandRecordMetrics.bodyGap
            + ceil(manager.usedRect(for: container).height) + LocalCommandRecordMetrics.bottomPadding
    }

    // MARK: Header colour

    func testTheHeaderIsDrawnInTheMutedColourWithNoAmberAnywhereInAnOrdinaryRecord() throws {
        let muted = try renderedSwatch(Theme.fgMuted)
        for width in widths {
            for expanded in [false, true] {
                let shot = try render(output: lines(5), expanded: expanded, width: width)
                let header = shot.pixels(in: NSRect(x: 0, y: 0, width: width, height: LocalCommandRecordMetrics.headerHeight))

                let ink = try XCTUnwrap(brightest(header.filter(isInk)), "the header drew nothing at width \(width)")
                XCTAssertTrue(isMuted(ink, swatch: muted), "header ink at width \(width), expanded \(expanded): \(ink)")
                XCTAssertFalse(shot.pixels(in: NSRect(origin: .zero, size: shot.size)).contains(where: isAmber),
                               "no amber anywhere in an ordinary record (width \(width), expanded \(expanded))")
            }
        }
    }

    func testAnErrorRecordDrawsAmberInTheHeaderAndMutedInkAroundIt() throws {
        let muted = try renderedSwatch(Theme.fgMuted)
        let shot = try render(output: "Unknown model\nsecond line", stream: "stderr", expanded: true, width: 600)
        let header = shot.pixels(in: NSRect(x: 0, y: 0, width: 600, height: LocalCommandRecordMetrics.headerHeight))
        let below = shot.pixels(in: NSRect(x: 0, y: LocalCommandRecordMetrics.headerHeight, width: 600,
                                           height: shot.size.height - LocalCommandRecordMetrics.headerHeight))

        XCTAssertTrue(header.contains(where: isAmber), "the word `error` is amber")
        let grayInk = header.filter { isInk($0) && !isAmber($0) }
        XCTAssertFalse(grayInk.isEmpty, "the rest of the header is not amber")
        if let ink = brightest(grayInk) { XCTAssertTrue(isMuted(ink, swatch: muted), "\(ink)") }
        XCTAssertFalse(below.contains(where: isAmber), "the output is muted, not amber")
    }

    func testTheOutputIsDrawnInTheMutedColour() throws {
        let muted = try renderedSwatch(Theme.fgMuted)
        let shot = try render(output: lines(5), expanded: true, width: 420)
        let bodyRect = try XCTUnwrap(shot.view.bodyFrame)

        let ink = try XCTUnwrap(brightest(shot.pixels(in: bodyRect).filter(isInk)), "the output drew nothing")

        XCTAssertTrue(isMuted(ink, swatch: muted), "output ink: \(ink)")
    }

    // MARK: The last line

    func testTheLastOutputLineIsInsideTheViewAndDrawn() throws {
        for (name, output) in multiLineOutputs {
            for width in widths {
                let shot = try render(output: output, expanded: true, width: width)
                let last = try lastLineRect(of: shot.view)

                XCTAssertLessThanOrEqual(last.maxY, shot.size.height - LocalCommandRecordMetrics.bottomPadding + 0.5,
                                         "\(name) at \(width): the last line ends below the view (\(last.maxY) of \(shot.size.height))")
                XCTAssertGreaterThanOrEqual(last.minY, LocalCommandRecordMetrics.headerHeight, "\(name) at \(width): clear of the header")
                let ink = shot.pixels(in: last).filter(isInk)
                XCTAssertGreaterThan(ink.count, 8, "\(name) at \(width): the last line's ink is missing from the view")
            }
        }
    }

    func testEveryLineOfAShortRecordIsDrawnNotJustTheFirst() throws {
        let shot = try render(output: lines(5), expanded: true, width: 420)
        let bodyRect = try XCTUnwrap(shot.view.bodyFrame)
        let rowHeight = bodyRect.height / 5

        for i in 0..<5 {
            let band = NSRect(x: bodyRect.minX, y: bodyRect.minY + CGFloat(i) * rowHeight, width: bodyRect.width, height: rowHeight)
            XCTAssertGreaterThan(shot.pixels(in: band).filter(isInk).count, 8, "line \(i + 1) has no ink")
        }
    }

    // MARK: Height: the real layout against the arithmetic

    func testTheRealLaidOutHeightEqualsTheArithmeticHeightAtEveryWidth() throws {
        for (name, output) in multiLineOutputs {
            for width in widths {
                let shot = try render(output: output, expanded: true, width: width)
                let real = try realHeight(of: shot.view)
                let text = try body(of: shot.view)
                let container = try XCTUnwrap(text.textContainer)

                XCTAssertEqual(container.size.width, width, accuracy: 0.5, "\(name) at \(width): the output wraps at the view's width")
                XCTAssertEqual(shot.view.arithmeticHeight(atWidth: width), real, accuracy: 0.5, "\(name) at \(width): arithmetic vs real layout")
                XCTAssertEqual(LocalCommandRecordMetrics.height(output: output, expanded: true, width: width), real, accuracy: 0.5,
                               "\(name) at \(width): metrics vs real layout")
                XCTAssertEqual(shot.view.intrinsicContentSize.height, real, accuracy: 0.5, "\(name) at \(width): intrinsic height")
                XCTAssertEqual(text.frame.maxY + LocalCommandRecordMetrics.bottomPadding, shot.size.height, accuracy: 0.5,
                               "\(name) at \(width): the output ends one padding above the view's bottom")
            }
        }
    }

    func testACollapsedRecordIsOneHeaderLineTall() throws {
        for (_, output) in multiLineOutputs {
            for width in widths {
                let shot = try render(output: output, expanded: false, width: width)

                XCTAssertEqual(shot.view.arithmeticHeight(atWidth: width), LocalCommandRecordMetrics.headerHeight, accuracy: 0.001)
                XCTAssertEqual(shot.size.height, TurnHeightEstimator.wakeMarkerHeight, accuracy: 0.001)
                XCTAssertNil(shot.view.bodyFrame)
                XCTAssertTrue(shot.view.subviews.compactMap { $0 as? NSTextView }.isEmpty, "a closed record holds no output view")
            }
        }
    }

    func testASingleLineRecordIsTheSameOneLineWhetherOrNotItIsAskedToOpen() throws {
        for expanded in [false, true] {
            for width in widths {
                let shot = try render(output: "3k tokens used", expanded: expanded, width: width)

                XCTAssertFalse(shot.view.hasChevron)
                XCTAssertEqual(shot.size.height, LocalCommandRecordMetrics.headerHeight, accuracy: 0.001)
                XCTAssertNil(shot.view.bodyFrame)
                XCTAssertTrue(shot.pixels(in: NSRect(origin: .zero, size: shot.size)).contains(where: isInk), "the header drew nothing")
            }
        }
    }

    // MARK: Height: the estimator against the drawn turn

    func testTheEstimatorAgreesWithTheRealLayoutOfAnOpenRecordAtEveryWidth() throws {
        var folds = FoldResolver()
        folds.resultStates[LocalCommandRecordKey.blockIndex] = true
        for (name, output) in multiLineOutputs {
            for pane in widths {
                let slot = pane - ChatTurnView.blocksLeadingInset - ChatTurnView.bubbleTrailingInset
                let shot = try render(output: output, expanded: true, width: slot)
                let real = try realHeight(of: shot.view)
                let turn = OriginFixtures.turn(userInput: "/context",
                                               origin: .localCommand(command: "context", args: "", output: output,
                                                                     stream: "stdout", truncated: false))

                XCTAssertEqual(TurnHeightEstimator.estimate(turn, width: pane, folds: folds),
                               TurnHeightEstimator.turnChrome + real + TurnHeightEstimator.userSlotGap, accuracy: 0.5,
                               "\(name) at pane width \(pane)")
                XCTAssertEqual(LocalCommandRecordMetrics.height(output: output, expanded: true, width: slot), real, accuracy: 0.5,
                               "\(name) at pane width \(pane)")
            }
        }
    }

    func testTheEstimatorAgreesWithTheDrawnTurnWhenItHoldsAnOpenRecord() {
        var folds = FoldResolver()
        folds.resultStates[LocalCommandRecordKey.blockIndex] = true
        for (name, output) in multiLineOutputs {
            for pane in widths {
                let turn = OriginFixtures.turn(userInput: "/context",
                                               origin: .localCommand(command: "context", args: "", output: output,
                                                                     stream: "stdout", truncated: false))
                let view = ChatTurnView(turn: turn, contentAvailable: true, interaction: TurnInteractionState(), folds: folds)
                view.setIslandWidth(pane)

                XCTAssertEqual(view.islandHeight(), TurnHeightEstimator.estimate(turn, width: pane, folds: folds), accuracy: 0.5,
                               "\(name) at pane width \(pane)")
            }
        }
    }

    // MARK: Compact header

    func testTheCompactHeaderArrowAndFinalNumberAreDrawnInsideTheViewAtANarrowWidth() throws {
        let width: CGFloat = 260
        let view = LocalCommandRecordView(command: "compact", args: "", output: "Compacted", stream: "stdout",
                                          compact: CompactInfoWire(preTokens: 45_123, postTokens: 19_700),
                                          startExpanded: false)
        XCTAssertEqual(view.headerText, "/compact \u{00B7} Compacted \u{00B7} 45.1k \u{2192} 19.7k tokens")
        let height = view.arithmeticHeight(atWidth: width)
        let window = makeWindow(NSSize(width: width, height: height))
        let host = RecordHost(frame: NSRect(x: 0, y: 0, width: width, height: height))
        host.wantsLayer = true
        host.layer?.backgroundColor = Theme.bg.cgColor
        window.contentView = host
        view.frame = host.bounds
        host.addSubview(view)
        host.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / width

        // Ink columns of the header row: where the text is actually drawn, in points from the left.
        var inkColumns: [Int] = []
        let headerRows = Int((LocalCommandRecordMetrics.headerHeight * scale).rounded(.up))
        for x in 0 ..< rep.pixelsWide {
            for y in 0 ..< min(headerRows, rep.pixelsHigh) {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), isInk(c) { inkColumns.append(x); break }
            }
        }
        let lastInk = try XCTUnwrap(inkColumns.max(), "the compact header drew nothing")
        // The label's own layout: the whole line must fit, with its last glyph's ink inside the bounds.
        let label = view.headerFrame
        XCTAssertLessThanOrEqual(label.maxX, width, "the header label ends inside the view")
        XCTAssertLessThan(CGFloat(lastInk) / scale, width, "the last digit of 19.7k is drawn inside the view")
        XCTAssertGreaterThan(CGFloat(lastInk) / scale, width * 0.5, "the line was drawn out to its end, not cut short")
        let text = NSAttributedString(string: view.headerText, attributes: [.font: LocalCommandRecordMetrics.headerFont])
        XCTAssertLessThanOrEqual(ceil(text.size().width) + label.minX, width,
                                 "the whole compact header fits at \(width) pt, so neither the arrow nor the last digit is clipped")
    }
}
