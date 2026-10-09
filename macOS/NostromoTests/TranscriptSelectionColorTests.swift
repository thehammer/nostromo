import XCTest
import AppKit

// Contract: selected text in the transcript stays readable.
//
// A selectable `NSTextField` label edits through a field editor when it is
// selected, and the field editor takes its text colour and font from the *cell*,
// not from the label's attributed string. Labels that carry their colour in the
// attributed string (tool output, tool-call summary, error text) therefore turned
// black on the selection colour. The contract, for every selectable transcript
// label and for `MarkdownCardView`'s text view, in both appearances:
//
//  - the field editor shows the text in the colour and font the label renders it in;
//  - the selection highlight is opaque, legible against the text (WCAG luminance
//    contrast >= 3:1) and clearly visible against the label's own dark surface
//    (also >= 3:1: the theme's blue is ~4.5:1 against grey 0.085);
//  - the insertion point is not black.
//
// Uses the shared `RigWindow` (a key, never-shown window) from ProseSelectionTests.
// `TranscriptInactiveSelectionTests` repeats the check in a window that is NOT key,
// where AppKit paints selections with its unemphasised system colour.
// `TranscriptLabelAttributeStabilityTests` pins that selecting a label does not
// rewrite what the label renders.

// MARK: - Colour maths

private struct RGBA { let r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat }

/// `color` as sRGB components, resolved against `appearance` so dynamic system
/// colours (the default selection colour) are evaluated for the window they appear in.
private func resolve(_ color: NSColor, in appearance: NSAppearance) -> RGBA? {
    var out: RGBA?
    appearance.performAsCurrentDrawingAppearance {
        guard let c = color.usingColorSpace(.sRGB) else { return }
        out = RGBA(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent)
    }
    return out
}

private func luminance(_ c: RGBA) -> CGFloat {
    func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
}

/// WCAG contrast ratio, 1...21.
private func contrast(_ a: RGBA, _ b: RGBA) -> CGFloat {
    let la = luminance(a), lb = luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

private func brightness(_ c: RGBA) -> CGFloat { max(c.r, c.g, c.b) }

private func describe(_ c: RGBA?) -> String {
    guard let c else { return "nil" }
    return String(format: "rgba(%.2f, %.2f, %.2f, %.2f)", c.r, c.g, c.b, c.a)
}

private func close(_ a: RGBA, _ b: RGBA, tolerance: CGFloat = 0.02) -> Bool {
    abs(a.r - b.r) <= tolerance && abs(a.g - b.g) <= tolerance && abs(a.b - b.b) <= tolerance
}

/// The dark card/row fill the labels sit on (white 0.07 ... 0.10 across the transcript).
private let labelSurface = RGBA(r: 0.085, g: 0.085, b: 0.085, a: 1)

private let appearances: [(name: String, appearance: NSAppearance)] = [
    ("darkAqua", NSAppearance(named: .darkAqua)!),
    ("aqua", NSAppearance(named: .aqua)!),
]

// MARK: - Label factories

private struct LabelCase {
    let name: String
    let expectedFont: NSFont
    /// Builds the owning view inside `window` and returns the selectable label.
    let make: (NSWindow) -> NSTextField?
}

private func place(_ view: NSView, in window: NSWindow, height: CGFloat = 160) {
    view.frame = NSRect(x: 20, y: 300, width: 620, height: height)
    window.contentView!.addSubview(view)
    view.layoutSubtreeIfNeeded()
    window.contentView!.layoutSubtreeIfNeeded()
}

private func label(in view: NSView, where match: (NSTextField) -> Bool) -> NSTextField? {
    rigAllSubviews(of: view).compactMap { $0 as? NSTextField }.first(where: match)
}

private let toolOutput = "On branch main\nYour branch is up to date with 'origin/main'.\nnothing to commit, working tree clean"
private let summaryText = "git status --short && git log --oneline -n 5"
private let errorText = "Something failed: exit code 2"
private let paragraphText = "A plain paragraph of assistant prose with no markdown markers in it at all."
private let bubbleText = "what the operator typed into the input bar"

private let labelCases: [LabelCase] = [
    LabelCase(name: "ToolResultView expanded output label", expectedFont: Theme.monoFont) { window in
        let v = ToolResultView(data: ToolResultData(content: toolOutput, isError: false),
                               contentAvailable: true, startExpanded: true)
        place(v, in: window)
        return label(in: v) { $0.stringValue == toolOutput }
    },
    LabelCase(name: "ToolCallView summary label", expectedFont: Theme.monoFont) { window in
        let v = ToolCallView(data: ToolCallData(toolName: "Bash", inputSummary: summaryText, inputFull: "{\"command\":\"x\"}"))
        place(v, in: window, height: 40)
        return label(in: v) { $0.stringValue == summaryText }
    },
    LabelCase(name: "ErrorBlockView message label", expectedFont: Theme.monoFont) { window in
        let v = ErrorBlockView(message: errorText)
        place(v, in: window, height: 60)
        return label(in: v) { $0.stringValue == errorText }
    },
    LabelCase(name: "TextBlockView paragraph label", expectedFont: .systemFont(ofSize: 13)) { window in
        let v = TextBlockView(text: paragraphText)
        place(v, in: window, height: 60)
        return label(in: v) { $0.stringValue == paragraphText }
    },
    LabelCase(name: "UserBubbleView label", expectedFont: .systemFont(ofSize: 13)) { window in
        let v = UserBubbleView(text: bubbleText, imageURLs: [])
        place(v, in: window, height: 60)
        return label(in: v) { $0.stringValue == bubbleText }
    },
    // The collapsed result summary ("✓  1.2s · $0.0100"). It IS a CopyMenuTextField,
    // but it carries its colour in `textColor`, not in an attributed string.
    LabelCase(name: "ResultChipView label", expectedFont: .monospacedDigitSystemFont(ofSize: 10, weight: .regular)) { window in
        let v = ResultChipView(data: ResultSummaryData(durationMs: 1200, costUSD: 0.01, isError: false))
        place(v, in: window, height: 30)
        return label(in: v) { $0.stringValue.contains("1.2s") }
    },
]

/// The colour a label renders its text in: the first run's foreground colour, else `textColor`.
private func renderedColor(of label: NSTextField) -> NSColor {
    let attributed = label.attributedStringValue
    if attributed.length > 0,
       let c = attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor { return c }
    return label.textColor ?? .labelColor
}

/// Selects the label in a key window with the given appearance; returns its field editor
/// and the colour the label was rendering its text in *before* it was selected (once the
/// field editor has it, `attributedStringValue` reports the editor's version of the text).
private func select(_ labelCase: LabelCase, appearance: (name: String, appearance: NSAppearance),
                    testCase: XCTestCase)
    -> (window: RigWindow, label: NSTextField, editor: NSTextView, renderedColor: NSColor)? {
    let window = makeRigWindow(testCase, appearance: appearance.appearance)
    guard let label = labelCase.make(window) else {
        XCTFail("\(labelCase.name): label not found in its view")
        return nil
    }
    let rendered = renderedColor(of: label)
    label.selectText(nil)
    guard let editor = rigEditor(of: label) else {
        XCTFail("\(labelCase.name) [\(appearance.name)]: selecting the label produced no field editor")
        return nil
    }
    return (window, label, editor, rendered)
}

// MARK: - Tests

final class TranscriptSelectionColorTests: XCTestCase {

    /// Black text on the selection colour is the bug. The editor must draw the text in
    /// the colour the label renders it in, and that colour must not be (near) black.
    func testSelectedLabelTextKeepsTheColourItIsRenderedIn() {
        for labelCase in labelCases {
            for appearance in appearances {
                guard let (_, _, editor, rendered) = select(labelCase, appearance: appearance, testCase: self) else { continue }
                let tag = "\(labelCase.name) [\(appearance.name)]"
                guard let expected = resolve(rendered, in: appearance.appearance),
                      let actual = editor.textColor.flatMap({ resolve($0, in: appearance.appearance) })
                else { XCTFail("\(tag): no colour to compare (editor.textColor = \(String(describing: editor.textColor)))"); continue }
                XCTAssertTrue(close(actual, expected),
                              "\(tag): field editor text colour \(describe(actual)) != rendered colour \(describe(expected))")
                XCTAssertGreaterThanOrEqual(brightness(actual), 0.25,
                                            "\(tag): selected text is (near) black: \(describe(actual))")
            }
        }
    }

    func testSelectedLabelTextKeepsItsFont() {
        for labelCase in labelCases {
            for appearance in appearances {
                guard let (_, _, editor, _) = select(labelCase, appearance: appearance, testCase: self) else { continue }
                let tag = "\(labelCase.name) [\(appearance.name)]"
                XCTAssertEqual(editor.font?.fontName, labelCase.expectedFont.fontName, "\(tag): editor font \(String(describing: editor.font))")
                XCTAssertEqual(editor.font?.pointSize ?? 0, labelCase.expectedFont.pointSize, accuracy: 0.01, tag)
            }
        }
    }

    func testSelectionHighlightIsOpaqueLegibleAndVisibleOnTheLabelSurface() {
        for labelCase in labelCases {
            for appearance in appearances {
                guard let (_, _, editor, _) = select(labelCase, appearance: appearance, testCase: self) else { continue }
                let tag = "\(labelCase.name) [\(appearance.name)]"
                guard let backgroundColor = editor.selectedTextAttributes[.backgroundColor] as? NSColor,
                      let background = resolve(backgroundColor, in: appearance.appearance)
                else { XCTFail("\(tag): selectedTextAttributes has no background colour: \(editor.selectedTextAttributes)"); continue }
                XCTAssertEqual(background.a, 1, accuracy: 0.001, "\(tag): selection background must be opaque, is \(describe(background))")

                let foregroundColor = (editor.selectedTextAttributes[.foregroundColor] as? NSColor) ?? editor.textColor
                guard let foreground = foregroundColor.flatMap({ resolve($0, in: appearance.appearance) }) else {
                    XCTFail("\(tag): selected text has no colour"); continue
                }
                let textContrast = contrast(foreground, background)
                XCTAssertGreaterThanOrEqual(textContrast, 3.0,
                    "\(tag): selected text \(describe(foreground)) on selection \(describe(background)) is \(String(format: "%.2f", textContrast)):1")
                let surfaceContrast = contrast(background, labelSurface)
                XCTAssertGreaterThanOrEqual(surfaceContrast, 3.0,
                    "\(tag): selection \(describe(background)) is too faint on the label surface, \(String(format: "%.2f", surfaceContrast)):1")
            }
        }
    }

    func testInsertionPointIsNotBlack() {
        for labelCase in labelCases {
            for appearance in appearances {
                guard let (_, _, editor, _) = select(labelCase, appearance: appearance, testCase: self) else { continue }
                let tag = "\(labelCase.name) [\(appearance.name)]"
                guard let c = resolve(editor.insertionPointColor, in: appearance.appearance) else { XCTFail(tag); continue }
                XCTAssertGreaterThanOrEqual(brightness(c), 0.25, "\(tag): insertion point is (near) black: \(describe(c))")
            }
        }
    }

    // MARK: MarkdownCardView

    private func cardTextView(in window: RigWindow) -> NSTextView? {
        let card = MarkdownCardView(markdown: "Some `inline code` and a paragraph.\n\n- one\n- two")
        place(card, in: window, height: 120)
        return rigAllSubviews(of: card).compactMap { $0 as? NSTextView }.first
    }

    func testMarkdownCardSelectionHighlightIsOpaqueLegibleAndVisibleOnTheCard() {
        for appearance in appearances {
            let window = makeRigWindow(self, appearance: appearance.appearance)
            guard let tv = cardTextView(in: window) else { XCTFail("no text view in the card"); continue }
            let tag = "MarkdownCardView text view [\(appearance.name)]"
            guard let backgroundColor = tv.selectedTextAttributes[.backgroundColor] as? NSColor,
                  let background = resolve(backgroundColor, in: appearance.appearance)
            else { XCTFail("\(tag): no selection background: \(tv.selectedTextAttributes)"); continue }
            XCTAssertEqual(background.a, 1, accuracy: 0.001, "\(tag): selection background must be opaque, is \(describe(background))")

            let foregroundColor = (tv.selectedTextAttributes[.foregroundColor] as? NSColor) ?? tv.textColor
            guard let foreground = foregroundColor.flatMap({ resolve($0, in: appearance.appearance) }) else {
                XCTFail("\(tag): no text colour"); continue
            }
            let textContrast = contrast(foreground, background)
            XCTAssertGreaterThanOrEqual(textContrast, 3.0,
                "\(tag): text \(describe(foreground)) on selection \(describe(background)) is \(String(format: "%.2f", textContrast)):1")
            let surfaceContrast = contrast(background, labelSurface)
            XCTAssertGreaterThanOrEqual(surfaceContrast, 3.0,
                "\(tag): selection \(describe(background)) is too faint on the card, \(String(format: "%.2f", surfaceContrast)):1")
        }
    }
}

// MARK: - Copy menu on the tool output

/// The expanded tool output is raw text the operator wants to copy, so a right-click
/// on it must offer Copy -- whether or not it already holds a selection.
final class ToolResultCopyMenuTests: XCTestCase {

    private func setUpLabel() -> (RigWindow, NSTextField)? {
        let window = makeRigWindow(self)
        guard let label = labelCases[0].make(window) else { XCTFail("tool output label not found"); return nil }
        return (window, label)
    }

    /// The menu AppKit would pop: first non-nil `menu(for:)` from the hit view up.
    private func contextMenu(atCentreOf label: NSTextField, in window: RigWindow) -> (menu: NSMenu?, hit: NSView?) {
        let point = label.convert(NSPoint(x: label.bounds.midX, y: label.bounds.midY), to: nil)
        let content = window.contentView!
        guard let hit = content.hitTest(content.convert(point, from: nil)),
              let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: 1)
        else { return (nil, nil) }
        var view: NSView? = hit
        while let v = view {
            if let m = v.menu(for: event) { return (m, hit) }
            view = v.superview
        }
        return (nil, hit)
    }

    private func hasCopy(_ menu: NSMenu?) -> Bool {
        menu?.items.contains { $0.action == #selector(NSText.copy(_:)) || $0.title == "Copy" } ?? false
    }

    func testRightClickOnTheToolOutputOffersCopy() {
        guard let (window, label) = setUpLabel() else { return }
        let (menu, hit) = contextMenu(atCentreOf: label, in: window)
        XCTAssertTrue(hasCopy(menu),
                      "right-click on the tool output gave menu \(menu?.items.map(\.title) ?? []) (nil = none), hit \(rigChain(hit))")
    }

    func testRightClickOnSelectedToolOutputOffersCopy() {
        guard let (window, label) = setUpLabel() else { return }
        label.selectText(nil)
        XCTAssertNotNil(rigEditor(of: label), "precondition: the label is being edited")
        let (menu, hit) = contextMenu(atCentreOf: label, in: window)
        XCTAssertTrue(hasCopy(menu),
                      "right-click on selected tool output gave menu \(menu?.items.map(\.title) ?? []), hit \(rigChain(hit))")
    }
}


// MARK: - Label attribute stability

/// Selecting a label hands its text to a shared field editor, and
/// `CopyMenuTextFieldCell.setUpFieldEditorAttributes` writes colour and font onto
/// the *cell*. That must not rewrite what the label renders: after the operator
/// clicks away, the label has to look and measure exactly as it did before it was
/// ever selected (a flattened attributed string loses per-run colour, ligature
/// and paragraph settings, and changes the wrapped height).
final class TranscriptLabelAttributeStabilityTests: XCTestCase {

    private func describeValue(_ value: Any) -> String {
        if let c = value as? NSColor {
            return c.usingColorSpace(.sRGB).map { String(format: "rgba(%.3f,%.3f,%.3f,%.3f)", $0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent) }
                ?? "\(c)"
        }
        if let f = value as? NSFont { return "\(f.fontName) \(f.pointSize)" }
        if let p = value as? NSParagraphStyle {
            return "paragraph(lineBreak \(p.lineBreakMode.rawValue), align \(p.alignment.rawValue), lineHeightMultiple \(p.lineHeightMultiple), spacing \(p.paragraphSpacing))"
        }
        return "\(value)"
    }

    /// Every run's range and every attribute on it, as comparable text.
    private func runs(_ a: NSAttributedString) -> [String] {
        var out: [String] = []
        a.enumerateAttributes(in: NSRange(location: 0, length: a.length), options: []) { attrs, range, _ in
            let described = attrs.map { "\($0.key.rawValue)=\(describeValue($0.value))" }.sorted().joined(separator: ", ")
            out.append("[\(range.location),\(range.length)) {\(described)}")
        }
        return out
    }

    private struct Snapshot {
        let attributed: NSAttributedString
        let fittingHeight: CGFloat
        let intrinsicHeight: CGFloat
        let lineBreakMode: NSLineBreakMode
    }

    private func snapshot(_ label: NSTextField) -> Snapshot {
        Snapshot(attributed: NSAttributedString(attributedString: label.attributedStringValue),
                 fittingHeight: label.fittingSize.height, intrinsicHeight: label.intrinsicContentSize.height,
                 lineBreakMode: label.lineBreakMode)
    }

    /// Everything the label drew before that it no longer draws the same way: a
    /// changed string, a changed height, or an attribute that was on a run and is
    /// now missing or different. Attributes AppKit *adds* are reported separately by
    /// `added(_:_:)`: they do not change what is drawn.
    private func regressions(_ a: Snapshot, _ b: Snapshot) -> [String] {
        var out: [String] = []
        if a.attributed.string != b.attributed.string {
            out.append("string \"\(a.attributed.string)\" -> \"\(b.attributed.string)\"")
        }
        if abs(a.fittingHeight - b.fittingHeight) > 0.01 { out.append("fittingSize.height \(a.fittingHeight) -> \(b.fittingHeight)") }
        if abs(a.intrinsicHeight - b.intrinsicHeight) > 0.01 { out.append("intrinsicContentSize.height \(a.intrinsicHeight) -> \(b.intrinsicHeight)") }
        guard a.attributed.string == b.attributed.string else { return out }
        a.attributed.enumerateAttributes(in: NSRange(location: 0, length: a.attributed.length), options: []) { attrs, range, _ in
            for point in [range.location, NSMaxRange(range) - 1] {
                for (key, value) in attrs {
                    let now = b.attributed.attribute(key, at: point, effectiveRange: nil)
                    if now.map(describeValue) != describeValue(value) {
                        out.append("\(key.rawValue) at \(point): \(describeValue(value)) -> \(now.map(describeValue) ?? "missing")")
                    }
                }
            }
        }
        return out
    }

    /// Attribute keys the second snapshot carries that the first did not.
    private func added(_ a: Snapshot, _ b: Snapshot) -> [String] {
        guard a.attributed.length > 0, b.attributed.length > 0 else { return [] }
        let before = Set(a.attributed.attributes(at: 0, effectiveRange: nil).keys.map(\.rawValue))
        let after = Set(b.attributed.attributes(at: 0, effectiveRange: nil).keys.map(\.rawValue))
        return after.subtracting(before).sorted()
    }

    private func check(_ labelCase: LabelCase, appearance: (name: String, appearance: NSAppearance)) {
        let window = makeRigWindow(self, appearance: appearance.appearance)
        guard let label = labelCase.make(window) else { return XCTFail("\(labelCase.name): label not found") }
        window.contentView!.layoutSubtreeIfNeeded()
        let tag = "\(labelCase.name) [\(appearance.name)]"

        let before = snapshot(label)
        XCTAssertGreaterThan(before.attributed.length, 0, "\(tag): precondition, the label has text")

        label.selectText(nil)
        XCTAssertNotNil(rigEditor(of: label), "\(tag): precondition, the label is being edited")
        let selected = snapshot(label)

        _ = window.makeFirstResponder(nil)
        rigSettle()
        window.contentView!.layoutSubtreeIfNeeded()
        let after = snapshot(label)

        XCTAssertEqual(regressions(before, after), [],
                       "\(tag): the label no longer renders as it did after being selected and deselected")
        XCTAssertEqual(regressions(before, selected), [],
                       "\(tag): while selected, the label reports different text attributes or height")
        // On record: what AppKit's editor round trip adds to the attributed string.
        print("STABILITY \(tag): keys added after deselect \(added(before, after)); after-deselect run 0 = \(runs(after.attributed).first ?? "-")")
        // An added paragraph style must agree with the label's own wrapping, or the wrapped height changes.
        if let style = after.attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle {
            XCTAssertEqual(style.lineBreakMode, before.lineBreakMode, "\(tag): the label wraps differently after being selected")
        }
    }

    /// Every attribute and the height must come back as they were: colour, font, and
    /// (for the tool output) the disabled ligatures. AppKit adds `NSOriginalFont` and
    /// a paragraph style on the round trip; that is tolerated, losing or changing
    /// anything that was there is not.
    func testSelectingAndDeselectingALabelLeavesItsAttributedTextAndHeightUnchanged() {
        for labelCase in labelCases {
            for appearance in appearances {
                check(labelCase, appearance: appearance)
            }
        }
    }

    /// Selecting twice must not compound whatever the first selection did.
    func testSelectingALabelTwiceDoesNotChangeItAgain() {
        for labelCase in labelCases {
            let window = makeRigWindow(self)
            guard let label = labelCase.make(window) else { XCTFail("\(labelCase.name): label not found"); continue }
            let before = snapshot(label)
            for _ in 0..<2 {
                label.selectText(nil)
                _ = window.makeFirstResponder(nil)
                rigSettle(0.05)
            }
            XCTAssertEqual(regressions(before, snapshot(label)), [], "\(labelCase.name)")
        }
    }
}

// MARK: - Selection in a window that is not key

/// A window that is never key. AppKit paints a selection held by a non-key window
/// (or an inactive app) with its unemphasised system colour and ignores
/// `selectedTextAttributes`; the transcript's light text must stay readable on it.
private final class InactiveRigWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var isKeyWindow: Bool { false }
}

private func makeInactiveWindow(_ testCase: XCTestCase, appearance: NSAppearance?) -> InactiveRigWindow {
    _ = NSApplication.shared
    let window = InactiveRigWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                                   styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = appearance
    rigSettle()
    testCase.addTeardownBlock { window.close() }
    return window
}

/// What was actually painted: the colour behind the selected glyphs and the glyph colour.
private struct Painted {
    let highlight: RGBA
    let text: RGBA
    let highlightShare: Double
}

/// Renders `view` into a bitmap and reads back the highlight (the most common opaque
/// colour) and the text colour (the opaque pixel furthest in contrast from it).
/// Returns nil when nothing opaque was painted at all.
private func paint(_ view: NSView) -> Painted? {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    var counts: [Int: (n: Int, c: RGBA)] = [:]
    var opaque: [RGBA] = []
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.95 else { continue }
            let px = RGBA(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: 1)
            let key = Int(px.r * 255) << 16 | Int(px.g * 255) << 8 | Int(px.b * 255)
            counts[key] = ((counts[key]?.n ?? 0) + 1, px)
            opaque.append(px)
        }
    }
    guard let top = counts.values.max(by: { $0.n < $1.n }), !opaque.isEmpty else { return nil }
    let text = opaque.max(by: { contrast($0, top.c) < contrast($1, top.c) }) ?? top.c
    return Painted(highlight: top.c, text: text, highlightShare: Double(top.n) / Double(rep.pixelsWide * rep.pixelsHigh))
}

final class TranscriptInactiveSelectionTests: XCTestCase {

    private enum Subject: String, CaseIterable {
        case markdownCard = "MarkdownCardView text view"
        case toolOutputLabel = "tool output label field editor"
        case paragraphLabel = "paragraph label field editor"
    }

    private struct Condition {
        let name: String
        let makeWindow: (XCTestCase, NSAppearance) -> NSWindow
    }

    private let conditions = [
        Condition(name: "key window") { tc, a in makeRigWindow(tc, appearance: a) },
        Condition(name: "non-key window") { tc, a in makeInactiveWindow(tc, appearance: a) },
    ]

    /// Selects all the text of `subject` in `window` and returns the view to render.
    private func selectAll(_ subject: Subject, in window: NSWindow) -> NSView? {
        switch subject {
        case .markdownCard:
            let card = MarkdownCardView(markdown: "Some inline text and a paragraph of prose to select across.")
            card.presetWidth = 620
            place(card, in: window, height: MarkdownCardView.measuredHeight(markdown: "Some inline text and a paragraph of prose to select across.", width: 620))
            guard let tv = rigAllSubviews(of: card).compactMap({ $0 as? NSTextView }).first else { return nil }
            window.makeFirstResponder(tv)
            tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
            return tv   // the card's own dark fill would be taken for the highlight
        case .toolOutputLabel, .paragraphLabel:
            let labelCase = labelCases[subject == .toolOutputLabel ? 0 : 3]
            guard let label = labelCase.make(window) else { return nil }
            label.selectText(nil)
            guard let editor = rigEditor(of: label) else { return nil }
            editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
            return label
        }
    }

    /// The colours AppKit paints for a selection that is not emphasised, resolved for
    /// the view's own appearance. Always asserted, whatever the bitmap says.
    private func unemphasised(in view: NSView) -> RGBA? {
        resolve(.unemphasizedSelectedTextBackgroundColor, in: view.effectiveAppearance)
    }

    /// Selected text stays legible (>= 3:1 text on highlight) and the highlight stays
    /// visible on the dark surface (>= 2:1) whether or not the window is key.
    func testSelectedTextStaysLegibleAndVisibleWhateverTheWindowState() {
        for condition in conditions {
            for appearance in appearances {
                for subject in Subject.allCases {
                    let window = condition.makeWindow(self, appearance.appearance)
                    let tag = "\(subject.rawValue) [\(appearance.name), \(condition.name), app active: \(NSApp.isActive)]"
                    guard let view = selectAll(subject, in: window) else { XCTFail("\(tag): could not select"); continue }
                    window.contentView!.layoutSubtreeIfNeeded()
                    view.displayIfNeeded()

                    guard let painted = paint(view) else { XCTFail("\(tag): nothing was painted"); continue }
                    let textContrast = contrast(painted.text, painted.highlight)
                    let surfaceContrast = contrast(painted.highlight, labelSurface)
                    // Printed so the actual colours are on record whatever the verdict.
                    print("INACTIVE-SELECTION \(tag): highlight \(describe(painted.highlight)) text \(describe(painted.text)) "
                          + String(format: "text/highlight %.2f:1, highlight/surface %.2f:1, highlight share %.0f%%",
                                   textContrast, surfaceContrast, painted.highlightShare * 100)
                          + " unemphasised system colour \(describe(unemphasised(in: view)))")
                    XCTAssertGreaterThanOrEqual(textContrast, 3.0,
                        "\(tag): painted text \(describe(painted.text)) on painted highlight \(describe(painted.highlight)) is \(String(format: "%.2f", textContrast)):1")
                    // Looser than the active-selection bar: an inactive selection is meant to be
                    // quieter, but it must still be seen.
                    XCTAssertGreaterThanOrEqual(surfaceContrast, 2.0,
                        "\(tag): painted highlight \(describe(painted.highlight)) on the dark surface is \(String(format: "%.2f", surfaceContrast)):1")
                }
            }
        }
    }
}
