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
//  - the selection highlight is opaque, legible against the text (WCAG contrast
//    >= 3:1) and visible against the label's own dark surface (>= 1.5:1);
//  - the insertion point is not black.
//
// Uses the shared `RigWindow` (a key, never-shown window) from ProseSelectionTests.

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
    let make: (RigWindow) -> NSTextField?
}

private func place(_ view: NSView, in window: RigWindow, height: CGFloat = 160) {
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
                XCTAssertGreaterThanOrEqual(surfaceContrast, 1.5,
                    "\(tag): selection \(describe(background)) is invisible on the label surface, \(String(format: "%.2f", surfaceContrast)):1")
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
            XCTAssertGreaterThanOrEqual(surfaceContrast, 1.5,
                "\(tag): selection \(describe(background)) is invisible on the card, \(String(format: "%.2f", surfaceContrast)):1")
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

