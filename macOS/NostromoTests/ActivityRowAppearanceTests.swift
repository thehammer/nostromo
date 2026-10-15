import XCTest
import AppKit
import NostromoKit

// FV2: the Focus layout must be legible. A real `ChatTurnView` (its activity row open, so the lane,
// its rule and the folded prose show, with a latest message below) is rendered to a bitmap under
// the app's dark appearance (`AppAppearance`), on the colour the transcript actually draws
// (`Theme.bg`), in a key window and in one that is not key, and with the row hovered. Contrast is
// the WCAG ratio, (L1 + 0.05) / (L2 + 0.05), over the relative luminance of the pixels that came
// out, not of the colours that went in.
//
// PRD thresholds: prose >= 7:1, folded messages >= 7:1, row summary >= 4.5:1, failure badge
// >= 4.5:1 on the base and on the hover fill, lane rule >= 3:1, hover fill >= 1.2:1. Every ratio
// is printed (`FV2 contrast <element> key=... nonkey=...`) for the PR's table.
//
// Every colour is explicit (never a semantic or catalogue colour), so the result cannot depend on
// the system appearance (the Teri tab lesson).

private typealias F = FoldFixtures
private typealias X = FocusFixtures

private final class FocusNotKeyWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var isKeyWindow: Bool { false }
}

final class ActivityRowAppearanceTests: XCTestCase {

    private var previousAppearance: NSAppearance?

    override func setUp() {
        super.setUp()
        previousAppearance = NSApplication.shared.appearance
        AppAppearance.apply(to: NSApplication.shared)
    }

    override func tearDown() {
        NSApplication.shared.appearance = previousAppearance
        super.tearDown()
    }

    // MARK: Pixels and contrast

    private func relativeLuminance(_ color: NSColor) -> Double {
        let c = color.usingColorSpace(.sRGB) ?? color
        func linear(_ v: CGFloat) -> Double {
            let s = Double(v)
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let (la, lb) = (relativeLuminance(a), relativeLuminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private func name(_ c: NSColor) -> String {
        let s = c.usingColorSpace(.sRGB) ?? c
        return String(format: "rgb(%.0f,%.0f,%.0f)", s.redComponent * 255, s.greenComponent * 255, s.blueComponent * 255)
    }

    /// What was drawn: every colour is a pixel read back from the rendered turn.
    private struct Sample {
        var base: NSColor
        var latest: NSColor
        var latestBase: NSColor
        var folded: NSColor
        var foldedBase: NSColor
        var summary: NSColor
        var badge: NSColor
        var rowFill: NSColor
        var rule: NSColor
        var ruleBase: NSColor
    }

    private func blocks() -> [TurnBlock] {
        let longProse = String(repeating: "\(F.prose) ", count: 3)
        return [.text("ALPHA-MSG \(longProse)")] + X.failingRun("f") + [.text("BRAVO-MSG \(longProse)")] + F.run(1, prefix: "g")
            + [.text("CHARLIE-MSG \(longProse)"), F.chip()]
    }

    private func render(keyWindow: Bool, hovered: Bool, file: StaticString = #filePath, line: UInt = #line) -> Sample? {
        _ = NSApplication.shared
        let turn = F.turn(blocks())
        var state = TurnInteractionState()
        state.activityStates[X.segments(of: turn)[0].key] = true
        let view = X.view(turn, interaction: state, folds: FoldResolver(state: state))
        let size = NSSize(width: X.paneWidth, height: view.islandHeight())

        let window: NSWindow
        if keyWindow {
            window = makeRigWindow(self, size: size, appearance: NSAppearance(named: .darkAqua))
        } else {
            window = FocusNotKeyWindow(contentRect: NSRect(origin: .zero, size: size),
                                       styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            addTeardownBlock { window.close() }
        }
        XCTAssertEqual(window.isKeyWindow, keyWindow, file: file, line: line)

        let host = NSView(frame: NSRect(origin: .zero, size: size))
        host.wantsLayer = true
        host.layer?.backgroundColor = Theme.bg.cgColor
        window.contentView = host
        view.setFrameSize(size)
        view.frame.origin = .zero
        host.addSubview(view)
        guard let activity = view.activityRowViews.first, activity.isExpanded,
              let foldedBlock = activity.laneMemberViews.first(where: { $0 is TextBlockView }),
              let latestBlock = X.columns(view).first(where: { $0 is TextBlockView })
        else {
            XCTFail("the turn did not build an open row with folded prose and a latest message", file: file, line: line)
            return nil
        }
        activity.row.isHovered = hovered
        host.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            XCTFail("could not render the turn", file: file, line: line)
            return nil
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width

        func pixels(in rect: NSRect) -> [NSColor] {
            let r = rect.intersection(host.bounds)
            guard !r.isNull, r.width > 0, r.height > 0 else { return [] }
            let xs = Int((r.minX * scale).rounded(.down)) ..< Int((r.maxX * scale).rounded(.up))
            let ys = Int(((host.bounds.height - r.maxY) * scale).rounded(.down)) ..< Int(((host.bounds.height - r.minY) * scale).rounded(.up))
            var out: [NSColor] = []
            for y in ys where y >= 0 && y < rep.pixelsHigh {
                for x in xs where x >= 0 && x < rep.pixelsWide {
                    if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) { out.append(c) }
                }
            }
            return out
        }
        func rect(of other: NSView) -> NSRect { other.convert(other.bounds, to: host) }
        func median(_ rect: NSRect) -> NSColor? {
            let sorted = pixels(in: rect).sorted { relativeLuminance($0) < relativeLuminance($1) }
            return sorted.isEmpty ? nil : sorted[sorted.count / 2]
        }
        func brightest(_ rect: NSRect) -> NSColor? {
            pixels(in: rect).max { relativeLuminance($0) < relativeLuminance($1) }
        }

        let ruleRect = rect(of: activity.laneRule)
        let beside = NSRect(x: max(0, ruleRect.minX - 9), y: ruleRect.minY, width: 6, height: ruleRect.height)
        guard let latest = brightest(rect(of: latestBlock)), let latestBase = median(rect(of: latestBlock)),
              let folded = brightest(rect(of: foldedBlock)), let foldedBase = median(rect(of: foldedBlock)),
              let summary = brightest(rect(of: activity.row.summaryField)),
              let badge = brightest(rect(of: activity.row.badgeField)),
              let rowFill = median(rect(of: activity.row)),
              let rule = median(ruleRect), let ruleBase = median(beside),
              let base = median(NSRect(x: 0, y: 0, width: 8, height: host.bounds.height))
        else {
            XCTFail("nothing drawn: latest \(rect(of: latestBlock)) folded \(rect(of: foldedBlock)) rule \(ruleRect) "
                    + "badge hidden=\(activity.row.badgeField.isHidden)", file: file, line: line)
            return nil
        }
        return Sample(base: base, latest: latest, latestBase: latestBase, folded: folded, foldedBase: foldedBase,
                      summary: summary, badge: badge, rowFill: rowFill, rule: rule, ruleBase: ruleBase)
    }

    /// Every measured ratio for one window state.
    private func ratios(keyWindow: Bool, file: StaticString = #filePath, line: UInt = #line) -> [String: Double]? {
        guard let rest = render(keyWindow: keyWindow, hovered: false, file: file, line: line),
              let hover = render(keyWindow: keyWindow, hovered: true, file: file, line: line)
        else { return nil }
        print("[FV2 pixels key=\(keyWindow)] bg \(name(rest.base)) rowFill \(name(rest.rowFill)) hoverFill \(name(hover.rowFill)) "
              + "latest \(name(rest.latest)) folded \(name(rest.folded)) summary \(name(rest.summary)) "
              + "badge \(name(rest.badge)) rule \(name(rest.rule))")
        return [
            "latest prose": contrast(rest.latest, rest.latestBase),
            "folded message": contrast(rest.folded, rest.foldedBase),
            "row summary": contrast(rest.summary, rest.rowFill),
            "row summary (hover)": contrast(hover.summary, hover.rowFill),
            "failure badge": contrast(rest.badge, rest.rowFill),
            "failure badge (hover)": contrast(hover.badge, hover.rowFill),
            "lane rule": contrast(rest.rule, rest.ruleBase),
            "hover fill": contrast(hover.rowFill, rest.rowFill),
        ]
    }

    // MARK: Tests

    func testEveryElementMeetsItsContrastInTheKeyWindowAndInAWindowThatIsNotKey() throws {
        let key = try XCTUnwrap(ratios(keyWindow: true))
        let nonKey = try XCTUnwrap(ratios(keyWindow: false))
        let minimums: [(String, Double)] = [
            ("latest prose", 7), ("folded message", 7), ("row summary", 4.5), ("row summary (hover)", 4.5),
            ("failure badge", 4.5), ("failure badge (hover)", 4.5), ("lane rule", 3), ("hover fill", 1.2),
        ]
        for (element, minimum) in minimums {
            let k = try XCTUnwrap(key[element]), n = try XCTUnwrap(nonKey[element])
            print("FV2 contrast \(element) key=\(String(format: "%.2f", k)) nonkey=\(String(format: "%.2f", n)) (need >= \(minimum))")
            XCTAssertGreaterThanOrEqual(k, minimum, "\(element) in the key window")
            XCTAssertGreaterThanOrEqual(n, minimum, "\(element) in a window that is not key")
        }
    }

    func testTheFoldedMessageIsDimmerThanTheLatestOneButStillProse() throws {
        let sample = try XCTUnwrap(render(keyWindow: true, hovered: false))
        XCTAssertLessThan(relativeLuminance(sample.folded), relativeLuminance(sample.latest),
                          "folded prose reads as quieter than the conversation")
        XCTAssertGreaterThan(relativeLuminance(sample.folded), relativeLuminance(sample.summary),
                             "but it is brighter than the row's own text: it must stay readable")
    }

    /// `color` as this render path draws it: a layer-backed swatch of it on `Theme.bg`, read back.
    /// (Every pixel comes back a little lighter than the nominal grey: the colours are generic
    /// grey gamma 2.2, the bitmap sRGB. Comparing pixels with pixels keeps that out of the test.)
    private func renderedSwatch(_ color: NSColor) throws -> NSColor {
        let size = NSSize(width: 40, height: 40)
        let window = makeRigWindow(self, size: size, appearance: NSAppearance(named: .darkAqua))
        let host = NSView(frame: NSRect(origin: .zero, size: size))
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

    func testTheLaneRuleIsDrawnWithTheRuleColourOnTheTranscriptBackground() throws {
        let sample = try XCTUnwrap(render(keyWindow: true, hovered: false))
        XCTAssertEqual(contrast(sample.rule, try renderedSwatch(Theme.foldLaneRule)), 1.0, accuracy: 0.05,
                       "the pixels are the rule's colour")
        XCTAssertEqual(contrast(sample.ruleBase, sample.base), 1.0, accuracy: 0.05)
    }

    func testTheViewLooksTheSameWhetherOrNotItsWindowIsKey() throws {
        let key = try XCTUnwrap(render(keyWindow: true, hovered: false))
        let nonKey = try XCTUnwrap(render(keyWindow: false, hovered: false))
        XCTAssertEqual(contrast(key.latest, nonKey.latest), 1.0, accuracy: 0.05, "prose does not dim in an inactive window")
        XCTAssertEqual(contrast(key.folded, nonKey.folded), 1.0, accuracy: 0.05)
        XCTAssertEqual(contrast(key.summary, nonKey.summary), 1.0, accuracy: 0.05)
        XCTAssertEqual(contrast(key.badge, nonKey.badge), 1.0, accuracy: 0.05)
        XCTAssertEqual(contrast(key.rule, nonKey.rule), 1.0, accuracy: 0.05)
    }

    func testTheBadgeIsReadableAsRedNotJustBright() throws {
        let sample = try XCTUnwrap(render(keyWindow: true, hovered: false))
        let c = try XCTUnwrap(sample.badge.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(c.redComponent, c.greenComponent + 0.15)
        XCTAssertGreaterThan(c.redComponent, c.blueComponent + 0.15)
    }

    // MARK: Colours

    func testEveryColourTheFocusLayoutDrawsWithIsExplicit() throws {
        let palette: [(String, NSColor)] = [
            ("fg", Theme.fg), ("foldedProse", Theme.foldedProse), ("fgMuted", Theme.fgMuted),
            ("foldFailure", Theme.foldFailure), ("foldHover", Theme.foldHover), ("foldLaneRule", Theme.foldLaneRule),
            ("bg", Theme.bg), ("codeBlockBackground", Theme.codeBlockBackground),
        ]
        for (label, color) in palette {
            XCTAssertEqual(color.type, .componentBased,
                           "\(label) is a catalogue or pattern colour: it would change with the system appearance")
        }
    }

    func testTheViewsTextColoursAreTheExplicitOnes() throws {
        let turn = F.turn(blocks())
        var state = TurnInteractionState()
        state.activityStates[X.segments(of: turn)[0].key] = true
        let view = X.view(turn, interaction: state, folds: FoldResolver(state: state))
        let activity = try XCTUnwrap(view.activityRowViews.first)

        XCTAssertTrue(X.same(activity.row.summaryField.textColor, Theme.fgMuted) || activity.row.summaryField.textColor == Theme.fgMuted,
                      "\(String(describing: activity.row.summaryField.textColor))")
        XCTAssertTrue(X.same(activity.row.badgeField.textColor, Theme.foldFailure))
        let drawn = X.proseColors(in: view)
        XCTAssertFalse(drawn.isEmpty)
        XCTAssertTrue(drawn.allSatisfy { $0.type == .componentBased }, "a prose colour is not explicit: \(drawn)")
        XCTAssertTrue(drawn.allSatisfy { X.same($0, Theme.fg) || X.same($0, Theme.foldedProse) },
                      "prose is drawn in the conversation colour or the folded colour and nothing else: \(drawn)")
    }

    func testTheHoverFillIsTheFoldHoverColour() throws {
        let view = X.view(F.turn(blocks()))
        let activity = try XCTUnwrap(view.activityRowViews.first)
        activity.row.isHovered = true
        XCTAssertTrue(X.same(activity.row.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }, Theme.foldHover))
        activity.row.isHovered = false
        XCTAssertNil(activity.row.layer?.backgroundColor)
    }
}
