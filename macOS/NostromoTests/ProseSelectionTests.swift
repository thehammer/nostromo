import XCTest
import AppKit

// Contract: assistant prose in the transcript can be selected and copied.
//
// The bug: dragging over a paragraph rendered by `MarkdownCardView` showed no
// highlight at all, because the card's text view was a zero-height sliver in the
// card, so a mouse-down over the paragraph hit the card instead of the text.
// These tests drive the real view hierarchy `ReplView` builds (scroll view ->
// flipped document view -> `ChatTurnView` -> block views), optionally with the
// "Jump to latest" overlay laid over it, and exercise the gestures through
// `AppControlMouse` -- the same code the control socket uses.
//
// ## Harness
//
// A never-activated xctest process silently drops `NSWindow.sendEvent(mouseDown)`
// for views that do not accept first mouse, which includes every stock
// `NSTextView` and `NSTextField`. So `RigWindow` routes mouse events straight to
// the view `hitTest` finds, as AppKit would for a key window. The nested
// tracking loop inside `mouseDown(with:)` is real: `AppControlMouse` queues the
// drag and the up before sending the down, and AppKit's own loop finds them.
// The window is never ordered onto a screen (so nothing flashes and the operator's
// real mouse cannot reach it), and nothing here activates the app.
// Nothing touches the general pasteboard.

// MARK: - Shared rig (also used by TranscriptSelectionColorTests)

/// Offscreen window that can be key and routes mouse events to the hit view.
final class RigWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var isKeyWindow: Bool { true }
    private var tracked: NSView?

    override func sendEvent(_ e: NSEvent) {
        guard let cv = contentView else { return super.sendEvent(e) }
        switch e.type {
        case .leftMouseDown:
            tracked = cv.hitTest(cv.convert(e.locationInWindow, from: nil))
            // What AppKit does for a text view in a key window: it takes focus
            // on a click. Not done for labels, which start editing themselves.
            if let tv = tracked as? NSTextView, !tv.isFieldEditor { _ = makeFirstResponder(tv) }
            tracked?.mouseDown(with: e)
        case .leftMouseDragged: tracked?.mouseDragged(with: e)
        case .leftMouseUp: tracked?.mouseUp(with: e); tracked = nil
        default: super.sendEvent(e)
        }
    }
}

/// Lets AppKit finish setting a window (and its hierarchy) up. A mouse event queued
/// for a window that has not settled comes back out of `nextEvent` with its
/// location displaced -- by hundreds of points in the worst case -- which sent a
/// drag's end point to the end of the text. A few run-loop turns fix it.
func rigSettle(_ seconds: TimeInterval = 0.1) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}
final class RigFlippedDoc: NSView { override var isFlipped: Bool { true } }

func rigAllSubviews(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + rigAllSubviews(of: $0) }
}

/// "NSTextView <- MarkdownCardView <- TextBlockView <- ..." for failure messages.
func rigChain(_ v: NSView?) -> String {
    guard v != nil else { return "nil" }
    var out: [String] = []
    var cur = v
    while let c = cur { out.append(String(describing: type(of: c))); cur = c.superview }
    return out.joined(separator: " <- ")
}

func rigPrivatePasteboard(_ testCase: XCTestCase) -> NSPasteboard {
    let pb = NSPasteboard(name: NSPasteboard.Name("nostromo.test.\(UUID())"))
    testCase.addTeardownBlock { pb.releaseGlobally() }
    return pb
}

func makeRigWindow(_ testCase: XCTestCase, size: NSSize = NSSize(width: 900, height: 700),
                   appearance: NSAppearance? = nil) -> RigWindow {
    _ = NSApplication.shared
    let window = RigWindow(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = appearance
    window.makeKey()
    rigSettle()
    testCase.addTeardownBlock { window.close() }
    return window
}

/// The field editor a label is currently editing with: AppKit's `currentEditor()`
/// when it answers, otherwise the text view installed under the label.
func rigEditor(of label: NSTextField) -> NSTextView? {
    (label.currentEditor() as? NSTextView) ?? label.subviews.compactMap { $0 as? NSTextView }.first
}

/// A transcript turn in the hierarchy `ReplView` builds.
struct TranscriptRig {
    let window: RigWindow
    let scroll: NSScrollView
    let doc: RigFlippedDoc
    let turn: ChatTurnView
    let overlay: JumpToLatestOverlay?
    var content: NSView { window.contentView! }

    /// Same order `ReplView` uses: width, then height, then frames, then a layout pass.
    func relayout(width: CGFloat) {
        turn.setIslandWidth(width)
        let height = turn.islandHeight()
        turn.setFrameSize(NSSize(width: width, height: height))
        doc.setFrameSize(NSSize(width: width, height: height))
        if turn.superview == nil { doc.addSubview(turn) }
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        content.layoutSubtreeIfNeeded()
    }

    /// `windowPoint` is in window (bottom-left origin) coordinates.
    func hit(atWindowPoint windowPoint: NSPoint) -> NSView? {
        content.hitTest(content.convert(windowPoint, from: nil))
    }
}

func makeTranscriptRig(_ testCase: XCTestCase, blocks: [TurnBlock],
                       interaction: TurnInteractionState = TurnInteractionState(),
                       paneWidth: CGFloat = 900, withOverlay: Bool = false) -> TranscriptRig {
    let window = makeRigWindow(testCase)
    let scroll = NSScrollView(frame: window.contentView!.bounds)
    scroll.hasVerticalScroller = true
    let doc = RigFlippedDoc(frame: NSRect(x: 0, y: 0, width: paneWidth, height: 1))
    scroll.documentView = doc
    window.contentView!.addSubview(scroll)
    var overlay: JumpToLatestOverlay?
    if withOverlay {
        // Laid over the scroll view exactly as in the pane; must pass hits through.
        let o = JumpToLatestOverlay(frame: scroll.frame)
        window.contentView!.addSubview(o)
        overlay = o
    }
    let turn = ChatTurn(userInput: "hi", timestamp: Date(), blocks: blocks, isComplete: true)
    let view = ChatTurnView(turn: turn, contentAvailable: true, interaction: interaction)
    let rig = TranscriptRig(window: window, scroll: scroll, doc: doc, turn: view, overlay: overlay)
    rig.relayout(width: paneWidth)
    rigSettle()
    return rig
}

// MARK: - Elements under test

private enum ProseElement: CaseIterable {
    case markdownCard        // MarkdownCardView's NSTextView
    case plainParagraph      // TextBlockView's paragraph label
    case toolResultOutput    // ToolResultView's expanded output label
    case toolCallSummary     // ToolCallView's summary label

    var name: String {
        switch self {
        case .markdownCard:     return "MarkdownCardView text view"
        case .plainParagraph:   return "TextBlockView paragraph label"
        case .toolResultOutput: return "ToolResultView expanded label"
        case .toolCallSummary:  return "ToolCallView summary label"
        }
    }

    static let markdown = "Filed `bugs/open/prose-selection.md` for this one.\n\n"
        + "Second paragraph with some words to select across lines when the pane is narrow enough to wrap; "
        + "this sentence keeps going so the paragraph is certain to wrap onto several lines at the width of the "
        + "transcript pane, and then it goes on a little further for good measure.\n\n- item one\n- item two"
    static let plain = "A plain paragraph of assistant prose with no markdown markers at all, long enough that it "
        + "wraps onto at least two lines when the transcript pane is a reasonable width, so that a drag can run "
        + "from one line into the next one and keep going for a while after that."
    static let toolOutput = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november "
        + "oscar papa quebec romeo sierra tango uniform victor whiskey xray yankee zulu\n"
        + "second line of tool output with more words in it"
    static let toolSummary = "git log --format=%h --since yesterday --author someone --stat -- path/to/some/deeply/nested "
        + "directory and then a few more words so this summary is certain to wrap onto a second line"

    var blocks: [TurnBlock] {
        switch self {
        case .markdownCard:     return [.text(Self.markdown)]
        case .plainParagraph:   return [.text(Self.plain)]
        case .toolResultOutput: return [.toolResult(ToolResultData(content: Self.toolOutput, isError: false))]
        case .toolCallSummary:
            return [.toolCall(ToolCallData(toolName: "Bash", inputSummary: Self.toolSummary,
                                           inputFull: "{\"command\":\"git log\"}"))]
        }
    }

    var interaction: TurnInteractionState {
        var s = TurnInteractionState()
        if self == .toolResultOutput { s.expandedBlocks = [0] }   // the label is built on expand
        return s
    }

    /// A word that sits on the first line and does not wrap.
    var word: String {
        switch self {
        case .markdownCard:     return "words"
        case .plainParagraph:   return "assistant"
        case .toolResultOutput: return "charlie"
        case .toolCallSummary:  return "yesterday"
        }
    }

    /// Where the two-line selection starts looking for two consecutive wrapped lines.
    var wrappedParagraphStart: String {
        switch self {
        case .markdownCard:     return "Second paragraph"
        case .plainParagraph:   return "A plain"
        case .toolResultOutput: return "alpha"
        case .toolCallSummary:  return "git log"
        }
    }

    var isLabel: Bool { self != .markdownCard }
}

/// One element located inside a rig.
private struct Target {
    let element: ProseElement
    let rig: TranscriptRig
    let owner: NSView   // the card's NSTextView, or the label

    var label: NSTextField? { owner as? NSTextField }

    static func locate(_ element: ProseElement, in rig: TranscriptRig) -> Target? {
        let all = rigAllSubviews(of: rig.turn)
        let found: NSView?
        switch element {
        case .markdownCard:
            found = all.compactMap { $0 as? NSTextView }.first { !$0.isFieldEditor }
        case .plainParagraph:
            found = all.compactMap { $0 as? NSTextField }.first { $0.stringValue == ProseElement.plain }
        case .toolResultOutput:
            found = all.compactMap { $0 as? NSTextField }.first { $0.stringValue == ProseElement.toolOutput }
        case .toolCallSummary:
            found = all.compactMap { $0 as? NSTextField }.first { $0.stringValue == ProseElement.toolSummary }
        }
        return found.map { Target(element: element, rig: rig, owner: $0) }
    }

    /// The text view whose layout answers "where is this character". A label has
    /// no text view until it is edited, so it is selected for the duration of
    /// `body` and the editing is ended again afterwards.
    func measure<T>(_ body: (NSTextView) -> T) -> T? {
        if let tv = owner as? NSTextView {
            tv.layoutManager?.ensureLayout(for: tv.textContainer!)
            return body(tv)
        }
        guard let label else { return nil }
        label.selectText(nil)
        guard let editor = rigEditor(of: label) else { return nil }
        editor.layoutManager?.ensureLayout(for: editor.textContainer!)
        let result = body(editor)
        _ = rig.window.makeFirstResponder(nil)
        rigSettle(0.05)
        return result
    }

    /// The text view currently holding the selection, if any.
    var liveTextView: NSTextView? {
        if let tv = owner as? NSTextView { return tv }
        return label.flatMap(rigEditor(of:))
    }

    var selectedString: String? {
        guard let tv = liveTextView else { return nil }
        let r = tv.selectedRange
        guard r.location != NSNotFound, NSMaxRange(r) <= (tv.string as NSString).length else { return nil }
        return (tv.string as NSString).substring(with: r)
    }

    // MARK: Geometry (window coordinates, bottom-left origin)

    static func windowRect(_ tv: NSTextView, _ range: NSRange) -> NSRect {
        let lm = tv.layoutManager!, tc = tv.textContainer!
        let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        rect.origin.x += tv.textContainerOrigin.x
        rect.origin.y += tv.textContainerOrigin.y
        return tv.convert(rect, to: nil)
    }

    static func lineRanges(_ tv: NSTextView) -> [NSRange] {
        let lm = tv.layoutManager!, tc = tv.textContainer!
        var out: [NSRange] = []
        lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(for: tc)) { _, _, _, glyphs, _ in
            out.append(lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
        }
        return out
    }

    /// Centre of the target word, where a hit-test is expected to find the text.
    func wordCentre() -> NSPoint? {
        measure { tv in
            let r = (tv.string as NSString).range(of: element.word)
            guard r.location != NSNotFound else { return nil }
            let rect = Self.windowRect(tv, r)
            return NSPoint(x: rect.midX, y: rect.midY)
        } ?? nil
    }

    /// Press-and-release points that select exactly `range`: the left edge of its
    /// first character to the right edge of its last. Derived from the layout, so
    /// no pixel is hard-coded.
    func dragPoints(for range: NSRange, in tv: NSTextView) -> (from: NSPoint, to: NSPoint) {
        let first = Self.windowRect(tv, NSRange(location: range.location, length: 1))
        let last = Self.windowRect(tv, NSRange(location: NSMaxRange(range) - 1, length: 1))
        return (NSPoint(x: first.minX + 1, y: first.midY), NSPoint(x: last.maxX - 1, y: last.midY))
    }

    struct Plan { let expected: String; let from: NSPoint; let to: NSPoint }

    func planForWord() -> Plan? {
        measure { tv -> Plan? in
            let r = (tv.string as NSString).range(of: element.word)
            guard r.location != NSNotFound else { return nil }
            let p = dragPoints(for: r, in: tv)
            return Plan(expected: element.word, from: p.from, to: p.to)
        } ?? nil
    }

    /// From a few characters before the end of one wrapped line to a few into the next.
    func planAcrossTwoLines() -> Plan? {
        measure { tv -> Plan? in
            let text = tv.string as NSString
            let start = text.range(of: element.wrappedParagraphStart).location
            guard start != NSNotFound else { return nil }
            let lines = Self.lineRanges(tv).filter { $0.location >= start && $0.length >= 20 }
            guard let first = lines.first,
                  let second = lines.first(where: { $0.location == NSMaxRange(first) })
            else { return nil }
            let s = NSMaxRange(first) - 8
            let e = second.location + 8
            let range = NSRange(location: s, length: e - s)
            let p = dragPoints(for: range, in: tv)
            return Plan(expected: text.substring(with: range), from: p.from, to: p.to)
        } ?? nil
    }
}

// MARK: - Tests

final class ProseSelectionTests: XCTestCase {

    private func rig(for element: ProseElement, width: CGFloat = 900, overlay: Bool = false)
        -> (TranscriptRig, Target)? {
        let rig = makeTranscriptRig(self, blocks: element.blocks, interaction: element.interaction,
                                    paneWidth: width, withOverlay: overlay)
        guard let target = Target.locate(element, in: rig) else {
            XCTFail("\(element.name): not found in the turn (subviews: \(rigAllSubviews(of: rig.turn).map { String(describing: type(of: $0)) }))")
            return nil
        }
        return (rig, target)
    }

    private func isTheTextSurface(_ hit: NSView?, _ target: Target) -> Bool {
        guard let hit else { return false }
        if hit === target.owner { return true }
        // A label being edited answers through its field editor.
        if let editor = hit as? NSTextView, editor.isFieldEditor, editor.delegate === target.owner { return true }
        return false
    }

    // MARK: hit-testing

    func testAMouseDownOverTheTextReachesTheTextItself() {
        for element in ProseElement.allCases {
            for overlay in [false, true] {
                guard let (rig, target) = rig(for: element, overlay: overlay) else { continue }
                guard let point = target.wordCentre() else { XCTFail("\(element.name): no word rect"); continue }
                let hit = rig.hit(atWindowPoint: point)
                XCTAssertTrue(isTheTextSurface(hit, target),
                              "\(element.name)\(overlay ? " (with JumpToLatestOverlay)" : ""): a mouse-down over the text hit \(rigChain(hit))")
            }
        }
    }

    func testTheTextStaysReachableAfterThePaneChangesWidth() {
        for element in ProseElement.allCases {
            guard let (rig, target) = rig(for: element, overlay: true) else { continue }
            for width in [640 as CGFloat, 780, 900] {
                rig.relayout(width: width)
                guard let point = target.wordCentre() else { XCTFail("\(element.name) @\(width): no word rect"); continue }
                let hit = rig.hit(atWindowPoint: point)
                XCTAssertTrue(isTheTextSurface(hit, target),
                              "\(element.name) @\(Int(width)): a mouse-down over the text hit \(rigChain(hit))")
            }
        }
    }

    // MARK: geometry

    /// The text view must fill the card's interior -- not be a zero-height sliver
    /// that leaves the paragraph to the card, which cannot select text.
    func testTheCardsTextViewFillsTheCardInterior() throws {
        guard let (rig, target) = rig(for: .markdownCard) else { return }
        let tv = try XCTUnwrap(target.owner as? NSTextView)
        var heights: [CGFloat] = []
        for width in [900 as CGFloat, 640, 780] {
            rig.relayout(width: width)
            let card = try XCTUnwrap(tv.superview as? MarkdownCardView, "text view is not inside a MarkdownCardView: \(rigChain(tv))")
            let tag = "pane \(Int(width)): card \(card.frame), text view \(tv.frame)"
            XCTAssertGreaterThan(card.bounds.height, 24, "card has no height. \(tag)")
            XCTAssertEqual(tv.frame.height, card.bounds.height - 24, accuracy: 0.5,
                           "text view should fill the card interior (card height - 2 x 12). \(tag)")
            XCTAssertEqual(tv.frame.width, card.bounds.width - 24, accuracy: 0.5, tag)
            XCTAssertEqual(tv.frame.minX, 12, accuracy: 0.5, tag)
            XCTAssertEqual(tv.frame.minY, 12, accuracy: 0.5, tag)
            // All the text lives inside the view that is supposed to answer for it.
            let used = tv.layoutManager!.usedRect(for: tv.textContainer!)
            XCTAssertLessThanOrEqual(used.height, tv.frame.height + 0.5,
                                     "laid-out text (\(used.height)) is taller than its view. \(tag)")
            heights.append(card.bounds.height)
        }
        // A narrower pane wraps more, so the card must have been re-measured.
        XCTAssertGreaterThan(heights[1], heights[0], "card height did not grow when the pane narrowed: \(heights)")
    }

    // MARK: first responder

    func testTheTextSurfaceAcceptsFirstResponder() {
        for element in ProseElement.allCases {
            guard let (rig, target) = rig(for: element) else { continue }
            if let tv = target.owner as? NSTextView {
                XCTAssertTrue(tv.acceptsFirstResponder, "\(element.name): acceptsFirstResponder is false")
                XCTAssertTrue(rig.window.makeFirstResponder(tv),
                              "\(element.name): the window refused to make the text first responder")
                XCTAssertTrue(rig.window.firstResponder === tv,
                              "\(element.name): first responder is \(String(describing: rig.window.firstResponder))")
            } else if let label = target.label {
                // A selectable label is not itself a first responder; it hands focus
                // to a field editor when it is selected, and that must take it.
                XCTAssertTrue(label.isSelectable, "\(element.name): not selectable")
                label.selectText(nil)
                let editor = rigEditor(of: label)
                XCTAssertNotNil(editor, "\(element.name): selecting the label produced no field editor")
                XCTAssertTrue(editor.map { rig.window.makeFirstResponder($0) } ?? false,
                              "\(element.name): the window refused to make the field editor first responder")
                XCTAssertTrue(rig.window.firstResponder === editor,
                              "\(element.name): first responder is \(String(describing: rig.window.firstResponder))")
            }
        }
    }

    // MARK: drag selection

    func testDraggingOverAWordSelectsExactlyThatWord() throws {
        for element in ProseElement.allCases {
            guard let (rig, target) = rig(for: element, overlay: true) else { continue }
            guard let plan = target.planForWord() else { XCTFail("\(element.name): could not plan a word drag"); continue }
            try AppControlMouse.drag(in: rig.window, from: plan.from, to: plan.to)
            let range = target.liveTextView?.selectedRange
            XCTAssertEqual(target.selectedString, plan.expected,
                           "\(element.name): selectedRange \(String(describing: range)), "
                           + "first responder \(String(describing: rig.window.firstResponder)), "
                           + "hit at start \(rigChain(rig.hit(atWindowPoint: plan.from)))")
        }
    }

    func testDraggingAcrossTwoLinesSelectsExactlyTheSpannedText() throws {
        for element in ProseElement.allCases {
            guard let (rig, target) = rig(for: element, overlay: true) else { continue }
            guard let plan = target.planAcrossTwoLines() else {
                XCTFail("\(element.name): fixture did not wrap onto two lines, or no plan"); continue
            }
            try AppControlMouse.drag(in: rig.window, from: plan.from, to: plan.to)
            let range = target.liveTextView?.selectedRange
            XCTAssertGreaterThan(range?.length ?? 0, 0, "\(element.name): nothing selected across two lines")
            XCTAssertEqual(target.selectedString, plan.expected,
                           "\(element.name): selectedRange \(String(describing: range)), "
                           + "first responder \(String(describing: rig.window.firstResponder))")
        }
    }

    func testTheCardTextViewIsFirstResponderAfterADragSoItsSelectionShowsActive() throws {
        guard let (rig, target) = rig(for: .markdownCard) else { return }
        guard let plan = target.planForWord() else { return XCTFail("no plan") }
        try AppControlMouse.drag(in: rig.window, from: plan.from, to: plan.to)
        XCTAssertTrue(rig.window.firstResponder === target.owner,
                      "after a drag the first responder is \(String(describing: rig.window.firstResponder))")
    }

    // MARK: copy

    func testCopyingTheSelectionPutsExactlyTheSelectedTextOnThePasteboard() throws {
        for element in ProseElement.allCases {
            guard let (rig, target) = rig(for: element) else { continue }
            guard let plan = target.planAcrossTwoLines() else { XCTFail("\(element.name): no plan"); continue }
            try AppControlMouse.drag(in: rig.window, from: plan.from, to: plan.to)
            guard let tv = target.liveTextView, tv.selectedRange.length > 0 else {
                XCTFail("\(element.name): nothing selected to copy"); continue
            }
            let pb = rigPrivatePasteboard(self)
            pb.clearContents()
            // `copy(_:)` would write to the general pasteboard.
            // The text view's own writable types: it does not accept the modern `.string` UTI here.
            XCTAssertTrue(tv.writeSelection(to: pb, types: tv.writablePasteboardTypes), "\(element.name): writeSelection failed")
            XCTAssertEqual(pb.string(forType: .string), plan.expected, "\(element.name): wrong text on the pasteboard")
        }
    }

    // MARK: context menu

    private func rightClick(at point: NSPoint, in window: NSWindow) -> NSEvent? {
        NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    }

    private func hasCopy(_ menu: NSMenu?) -> Bool {
        menu?.items.contains { $0.action == #selector(NSText.copy(_:)) || $0.title == "Copy" } ?? false
    }

    /// The menu AppKit would pop: the first non-nil `menu(for:)` from the hit view up.
    private func contextMenu(at point: NSPoint, rig: TranscriptRig) -> (menu: NSMenu?, hit: NSView?) {
        guard let hit = rig.hit(atWindowPoint: point), let event = rightClick(at: point, in: rig.window)
        else { return (nil, nil) }
        var view: NSView? = hit
        while let v = view {
            if let m = v.menu(for: event) { return (m, hit) }
            view = v.superview
        }
        return (nil, hit)
    }

    func testRightClickOnTheCardsTextOffersCopy() {
        guard let (rig, target) = rig(for: .markdownCard, overlay: true) else { return }
        guard let point = target.wordCentre() else { return XCTFail("no word rect") }
        let (menu, hit) = contextMenu(at: point, rig: rig)
        XCTAssertTrue(hasCopy(menu), "right-click menu \(menu?.items.map(\.title) ?? []) has no Copy; hit \(rigChain(hit))")
    }

    func testRightClickOnSelectedLabelTextOffersCopy() throws {
        for element in ProseElement.allCases where element.isLabel {
            guard let (rig, target) = rig(for: element) else { continue }
            guard let plan = target.planForWord() else { XCTFail("\(element.name): no plan"); continue }
            try AppControlMouse.drag(in: rig.window, from: plan.from, to: plan.to)
            let (menu, hit) = contextMenu(at: NSPoint(x: (plan.from.x + plan.to.x) / 2, y: plan.from.y), rig: rig)
            XCTAssertTrue(hasCopy(menu),
                          "\(element.name): right-click menu \(menu?.items.map(\.title) ?? []) has no Copy; hit \(rigChain(hit))")
        }
    }
}

// MARK: - Selection survival for plain text views

/// `TranscriptSelection` already carries a selection held by a *field editor*
/// across the detach/re-attach that measuring performs (see
/// `TranscriptSelectionSurvivalTests`). The card's text view is a plain
/// `NSTextView`, not a field editor, so a selection in it has to survive the
/// same trip: a width change, a streamed block, or a tool result expanding
/// must not silently clear what the operator is copying.
final class TranscriptTextViewSelectionSurvivalTests: XCTestCase {

    private let selected = NSRange(location: 7, length: 12)

    private struct Fixture {
        let rig: TranscriptRig
        let textView: NSTextView
        let island: NSView   // the TextBlockView holding the card
    }

    private func makeFixture(select: Bool = true, makeFirst: Bool = true) -> Fixture? {
        let rig = makeTranscriptRig(self, blocks: [.text(ProseElement.markdown)])
        guard let tv = rigAllSubviews(of: rig.turn).compactMap({ $0 as? NSTextView }).first(where: { !$0.isFieldEditor }),
              let island = rigAllSubviews(of: rig.turn).first(where: { $0 is TextBlockView })
        else { XCTFail("card text view / TextBlockView not found"); return nil }
        if makeFirst {
            XCTAssertTrue(rig.window.makeFirstResponder(tv), "precondition: the card text view can take focus")
        }
        if select { tv.setSelectedRange(selected) }
        return Fixture(rig: rig, textView: tv, island: island)
    }

    func testSelectionInTheCardSurvivesMeasuringItsBlock() {
        guard let f = makeFixture() else { return }
        XCTAssertTrue(f.rig.window.firstResponder === f.textView, "precondition")

        _ = ChatTurnView.measureIsland(f.island, width: 600)

        XCTAssertTrue(f.rig.window.firstResponder === f.textView,
                      "card text view is no longer first responder: \(String(describing: f.rig.window.firstResponder))")
        XCTAssertEqual(f.textView.selectedRange, selected, "the selection in the card was lost")
    }

    func testSelectionInTheCardSurvivesAPaneWidthChange() {
        guard let f = makeFixture() else { return }
        f.rig.relayout(width: 640)
        XCTAssertTrue(f.rig.window.firstResponder === f.textView,
                      "card text view is no longer first responder after a width change: \(String(describing: f.rig.window.firstResponder))")
        XCTAssertEqual(f.textView.selectedRange, selected, "the selection in the card was lost on a width change")
    }

    func testCaptureAndRestoreBringBackACardSelectionAcrossADetach() {
        guard let f = makeFixture() else { return }
        let parent = f.rig.turn.superview!
        let saved = TranscriptSelection.capture(in: f.rig.turn)
        XCTAssertNotNil(saved, "capture ignored a selection held by a plain text view inside the measured view")
        f.rig.turn.removeFromSuperview()
        XCTAssertFalse(f.rig.window.firstResponder === f.textView, "precondition: detaching drops first responder")
        parent.addSubview(f.rig.turn)
        saved?.restore()

        XCTAssertTrue(f.rig.window.firstResponder === f.textView)
        XCTAssertEqual(f.textView.selectedRange, selected)
    }

    func testRestoringACardSelectionDoesNotScrollTheReader() {
        let window = makeRigWindow(self, size: NSSize(width: 900, height: 300))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
        let doc = RigFlippedDoc(frame: NSRect(x: 0, y: 0, width: 900, height: 5000))
        scroll.documentView = doc
        window.contentView!.addSubview(scroll)
        let turn = ChatTurnView(turn: ChatTurn(userInput: "hi", timestamp: Date(),
                                               blocks: [.text(ProseElement.markdown)], isComplete: true),
                                contentAvailable: true, interaction: TurnInteractionState())
        turn.setIslandWidth(900)
        // The selected turn sits far below the viewport the reader is looking at.
        turn.frame = NSRect(x: 0, y: 4000, width: 900, height: turn.islandHeight())
        doc.addSubview(turn)
        turn.layoutSubtreeIfNeeded()
        guard let tv = rigAllSubviews(of: turn).compactMap({ $0 as? NSTextView }).first(where: { !$0.isFieldEditor }) else {
            return XCTFail("no card text view")
        }
        XCTAssertTrue(window.makeFirstResponder(tv))
        tv.setSelectedRange(selected)

        // The reader is looking at the top of the transcript.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        let before = scroll.contentView.bounds.origin

        let saved = TranscriptSelection.capture(in: turn)
        XCTAssertNotNil(saved, "capture ignored a selection held by a plain text view")
        turn.removeFromSuperview()
        doc.addSubview(turn)
        saved?.restore()

        XCTAssertEqual(scroll.contentView.bounds.origin, before, "restoring a selection must not scroll the reader away")
        XCTAssertEqual(tv.selectedRange, selected, "the selection itself must still come back")
    }

    func testCaptureIsNilWhenTheCardTextViewHasNoSelection() {
        guard let f = makeFixture(select: false) else { return }
        f.textView.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertTrue(f.rig.window.firstResponder === f.textView, "precondition")
        XCTAssertNil(TranscriptSelection.capture(in: f.rig.turn), "an insertion point is not a selection to carry")
    }

    func testMeasuringDoesNotStealFocusFromElsewhere() {
        guard let f = makeFixture(select: true, makeFirst: false) else { return }
        // The card keeps a leftover range, but focus is in the input bar.
        let input = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        input.string = "a draft the operator is typing"
        f.rig.content.addSubview(input)
        XCTAssertTrue(f.rig.window.makeFirstResponder(input))
        input.setSelectedRange(NSRange(location: 2, length: 5))

        XCTAssertNil(TranscriptSelection.capture(in: f.rig.turn),
                     "a selection held by a view outside the measured view must be ignored")
        _ = ChatTurnView.measureIsland(f.island, width: 600)

        XCTAssertTrue(f.rig.window.firstResponder === input,
                      "measuring a block moved focus to \(String(describing: f.rig.window.firstResponder))")
        XCTAssertEqual(input.selectedRange, NSRange(location: 2, length: 5))
    }

    func testCaptureReportsOnlyTheSelectionInsideTheMeasuredView() {
        guard let f = makeFixture() else { return }
        let other = ChatTurnView(turn: ChatTurn(userInput: "x", timestamp: Date(), blocks: [], isComplete: true),
                                 contentAvailable: true, interaction: TurnInteractionState())
        f.rig.content.addSubview(other)
        XCTAssertNil(TranscriptSelection.capture(in: other))
        XCTAssertNotNil(TranscriptSelection.capture(in: f.rig.turn),
                        "capture ignored a selection held by a plain text view inside the measured view")
    }
}



