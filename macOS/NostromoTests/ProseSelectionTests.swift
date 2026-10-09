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

    /// Taking focus is not enough to scroll a reader headlessly: in a never-activated
    /// xctest process AppKit does not scroll when a text view becomes first responder
    /// or its selection is set, so a plain rig cannot tell a guarded restore from an
    /// unguarded one. This window does what AppKit does in an active window -- taking
    /// first responder, and any selection change, scrolls the selection into view --
    /// so that `TranscriptSelection.restore`'s own guard is what keeps the reader put.
    func testRestoringACardSelectionDoesNotScrollTheReader() {
        let window = makeScrollOnFocusWindow(self, size: NSSize(width: 900, height: 300))
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
        let follow = NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification,
                                                            object: tv, queue: nil) { _ in
            tv.scrollRangeToVisible(tv.selectedRange)
        }
        addTeardownBlock { NotificationCenter.default.removeObserver(follow) }
        let clip = scroll.contentView
        func readFromTheTop() {
            clip.scroll(to: NSPoint(x: 0, y: 0))
            scroll.reflectScrolledClipView(clip)
        }

        // Control: without the guard, taking focus in this window really does yank the reader.
        readFromTheTop()
        XCTAssertTrue(window.makeFirstResponder(tv))
        tv.setSelectedRange(selected)
        let yanked = clip.bounds.origin.y
        print("SCROLLGUARD control: unguarded focus + selection moved the clip origin by \(yanked)")
        XCTAssertGreaterThan(yanked, 1000, "precondition: the harness must scroll when nothing guards it, or this test proves nothing")
        _ = window.makeFirstResponder(nil)

        // The reader is looking at the top of the transcript.
        readFromTheTop()
        let before = clip.bounds.origin

        let saved = TranscriptSelection.capture(in: turn)
        XCTAssertNil(saved, "precondition: nothing is selected while focus is elsewhere")
        XCTAssertTrue(window.makeFirstResponder(tv))
        tv.setSelectedRange(selected)
        readFromTheTop()   // the reader never moved: only the capture below matters
        let held = TranscriptSelection.capture(in: turn)
        XCTAssertNotNil(held, "capture ignored a selection held by a plain text view")
        turn.removeFromSuperview()
        doc.addSubview(turn)
        held?.restore()

        XCTAssertEqual(clip.bounds.origin, before, "restoring a selection must not scroll the reader away")
        XCTAssertEqual(tv.selectedRange, selected, "the selection itself must still come back")
        XCTAssertTrue(window.firstResponder === tv, "focus must come back too")
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




// MARK: - A window whose focus changes scroll, like an active window's do

/// Offscreen key window that, like AppKit in an active window, scrolls a text view's
/// selection into view when the text view takes first responder. Headless AppKit
/// does not do that, which would make every "must not scroll the reader" guard
/// vacuous.
final class RigScrollOnFocusWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var isKeyWindow: Bool { true }
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let ok = super.makeFirstResponder(responder)
        if ok, let tv = responder as? NSTextView, !tv.isFieldEditor { tv.scrollRangeToVisible(tv.selectedRange) }
        return ok
    }
}

func makeScrollOnFocusWindow(_ testCase: XCTestCase, size: NSSize) -> RigScrollOnFocusWindow {
    _ = NSApplication.shared
    let window = RigScrollOnFocusWindow(contentRect: NSRect(origin: .zero, size: size),
                                        styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.makeKey()
    rigSettle()
    testCase.addTeardownBlock { window.close() }
    return window
}

// MARK: - A rig shaped like the real ReplView pane

/// Mirrors `ReplClipView` (flipped clip). `ReplView.swift` is not compiled into this
/// test bundle (it needs `AppStore` and half the app), so the real classes cannot be
/// named here; both are plain flipped views, which is all they are.
final class RigReplClipView: NSClipView { override var isFlipped: Bool { true } }
/// Mirrors `TranscriptDocumentView`: flipped, not opaque, no constraints.
final class RigTranscriptDocumentView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
}

/// window content -> pane -> { NSScrollView(ReplClipView-shaped clip, TranscriptDocumentView-shaped
/// document view -> ChatTurnView), JumpToLatestOverlay above it, an input-bar stand-in }, plus a
/// window-level `ToastBannerView` above everything, as `MainLayout` stacks them. The pane's
/// `FollowTailController` is the real one.
///
/// Not present: `ActivityTickerView` (its `setup()` subscribes to `AppStore.shared`, which
/// cannot be built in a logic test). Its hit-test is the same `OverlayHitTest` pass-through
/// `ToastBannerView` and `JumpToLatestOverlay` use.
final class ReplRig {
    static let windowWidth: CGFloat = 1500
    static let paneHeight: CGFloat = 640
    static let inputBarHeight: CGFloat = 60

    let window: RigWindow
    let pane = NSView()
    let scroll = NSScrollView()
    let clip = RigReplClipView()
    let doc = RigTranscriptDocumentView()
    let overlay: JumpToLatestOverlay
    let toast = ToastBannerView()
    let inputBar = NSView()
    let followTail: FollowTailController
    private(set) var turn: ChatTurnView
    private(set) var blocks: [TurnBlock]
    private(set) var paneWidth: CGFloat
    /// The width turns are measured at. `ReplView` reads it from the clip view; a rig
    /// may pin it so that two rigs measure at the same width.
    var islandWidth: CGFloat?
    var flips: [FollowTailController.Flip] = []
    var content: NSView { window.contentView! }

    var contentWidth: CGFloat { islandWidth ?? max(clip.bounds.width, 1) }

    init(_ testCase: XCTestCase, blocks: [TurnBlock], paneWidth: CGFloat, islandWidth: CGFloat? = nil,
         pinned: Bool = true) {
        let window = makeRigWindow(testCase, size: NSSize(width: Self.windowWidth,
                                                          height: Self.paneHeight + Self.inputBarHeight))
        self.window = window
        self.paneWidth = paneWidth
        self.islandWidth = islandWidth
        self.blocks = blocks
        let overlay = JumpToLatestOverlay(frame: .zero)
        self.overlay = overlay
        let contentView = window.contentView!

        pane.frame = contentView.bounds
        contentView.addSubview(pane)
        scroll.contentView = clip
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        pane.addSubview(scroll)
        doc.frame = NSRect(x: 0, y: 0, width: 400, height: 1)
        scroll.documentView = doc
        pane.addSubview(inputBar)
        pane.addSubview(overlay, positioned: .above, relativeTo: scroll)
        contentView.addSubview(toast)   // last: on top of everything, like MainLayout's overlays
        followTail = FollowTailController(scrollView: scroll, overlay: overlay)
        turn = ReplRig.makeTurn(blocks)
        followTail.documentHeight = { [unowned doc] in doc.frame.height }
        followTail.contentWidth = { [unowned self] in self.contentWidth }
        followTail.onFlip = { [unowned self] flip in self.flips.append(flip) }
        if !pinned { overlay.setFollowingTail(false) }
        resizeFrames(to: paneWidth)
        materializeTurn()
    }

    private static func makeTurn(_ blocks: [TurnBlock]) -> ChatTurnView {
        ChatTurnView(turn: ChatTurn(userInput: "hi", timestamp: Date(), blocks: blocks, isComplete: true),
                     contentAvailable: true, interaction: TurnInteractionState())
    }

    private func resizeFrames(to width: CGFloat) {
        paneWidth = width
        let area = NSRect(x: 0, y: Self.inputBarHeight, width: width, height: Self.paneHeight)
        scroll.frame = area
        overlay.frame = area
        inputBar.frame = NSRect(x: 0, y: 0, width: width, height: Self.inputBarHeight)
        toast.frame = content.bounds
    }

    /// `ReplView.measure`: detached, width then height then frame; the held selection is
    /// carried across the detach.
    @discardableResult
    func measure() -> CGFloat {
        let superview = turn.superview
        let selection = TranscriptSelection.capture(in: turn)
        superview.map { _ in turn.removeFromSuperview() }
        turn.setIslandWidth(contentWidth)
        let height = max(turn.islandHeight(), TurnHeightEstimator.minimumTurnHeight)
        turn.setFrameSize(NSSize(width: contentWidth, height: height))
        superview?.addSubview(turn)
        selection?.restore()
        return height
    }

    /// `ReplView.materialize` steps 3 and 4 for a turn that is not there yet: measure
    /// detached, add, position, size the document.
    func materializeTurn() {
        measure()
        doc.addSubview(turn)
        place()
    }

    func place() {
        turn.setFrameOrigin(NSPoint(x: 0, y: 0))
        doc.setFrameSize(NSSize(width: contentWidth, height: max(turn.frame.height, clip.bounds.height)))
    }

    /// A pane width change as `ReplView` sees it: frames first, then the pass that re-measures.
    func changePane(to width: CGFloat, islandWidth: CGFloat? = nil) {
        self.islandWidth = islandWidth
        resizeFrames(to: width)
        measure()
        place()
    }

    /// A block streams into the turn, then the pass re-measures it.
    func stream(_ block: TurnBlock) {
        blocks.append(block)
        turn.update(turn: ChatTurn(userInput: "hi", timestamp: Date(), blocks: blocks, isComplete: false))
        measure()
        place()
    }

    /// Lays the pane out until the clip view's width (which a scroller appearing changes) stops moving
    /// the width turns are measured at.
    func converge() {
        for _ in 0..<5 {
            content.layoutSubtreeIfNeeded()
            let width = max(clip.bounds.width, 1)
            if islandWidth == nil, abs(width - turn.frame.width) > 0.5 {
                measure()
                place()
            } else { break }
        }
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
    }

    var cardTextView: NSTextView? {
        rigAllSubviews(of: turn).compactMap { $0 as? NSTextView }.first { !$0.isFieldEditor }
    }

    func hit(atWindowPoint p: NSPoint) -> NSView? { content.hitTest(content.convert(p, from: nil)) }

    /// Points over the paragraph, in window coordinates: across the first, a middle and the
    /// last line, from near the left edge to near the right.
    func probePoints() -> [NSPoint] {
        guard let tv = cardTextView, let lm = tv.layoutManager, let tc = tv.textContainer else { return [] }
        lm.ensureLayout(for: tc)
        let glyphs = lm.numberOfGlyphs
        guard glyphs > 0 else { return [] }
        let origin = tv.textContainerOrigin
        var points: [NSPoint] = []
        for glyph in [0, glyphs / 2, glyphs - 1] {
            let rect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            for fraction in [CGFloat(0.04), 0.3, 0.6, 0.96] {
                let local = NSPoint(x: origin.x + rect.minX + rect.width * fraction, y: origin.y + rect.midY)
                points.append(tv.convert(local, to: nil))
            }
        }
        return points
    }
}

// MARK: - Hit-testing in the real pane's shape

/// A mouse-down over the paragraph must reach the card's text view, at any pane width,
/// whatever phase of layout the pane is in, with the pane's overlays over it.
final class ReplPaneHitTestFidelityTests: XCTestCase {

    private let widths: [CGFloat] = [520, 640, 780, 900, 1415]
    private let blocks: [TurnBlock] = [.text(ProseElement.markdown)]

    /// Window-coordinate probe points and the converged island width for a pane width,
    /// from a fully laid-out twin of the pane.
    private func reference(width: CGFloat) -> (points: [NSPoint], islandWidth: CGFloat)? {
        let twin = ReplRig(self, blocks: blocks, paneWidth: width)
        twin.converge()
        let points = twin.probePoints()
        guard !points.isEmpty, twin.cardTextView != nil else { XCTFail("twin pane has no card text view at \(width)"); return nil }
        return (points, twin.turn.frame.width)
    }

    private func misses(_ rig: ReplRig, _ points: [NSPoint]) -> [String] {
        guard let tv = rig.cardTextView else { return ["no card text view"] }
        return points.compactMap { p in
            let hit = rig.hit(atWindowPoint: p)
            return hit === tv ? nil : "(\(Int(p.x)),\(Int(p.y))) -> \(rigChain(hit))"
        }
    }

    private enum Phase: String, CaseIterable {
        case beforeAnyLayoutPass = "before any layout pass (frames set, nothing laid out)"
        case afterARunLoopTurn = "after a run-loop turn without an explicit layout"
        case afterALayoutPass = "after a layout pass"
    }

    private func advance(_ rig: ReplRig, to phase: Phase) {
        switch phase {
        case .beforeAnyLayoutPass: break
        case .afterARunLoopTurn: rigSettle()
        case .afterALayoutPass: rig.content.layoutSubtreeIfNeeded()
        }
    }

    private func checkFreshPanes(_ phases: [Phase]) {
        for pinned in [true, false] {
            for width in widths {
                guard let ref = reference(width: width) else { continue }
                let rig = ReplRig(self, blocks: blocks, paneWidth: width, islandWidth: ref.islandWidth, pinned: pinned)
                for phase in phases {
                    advance(rig, to: phase)
                    let failed = misses(rig, ref.points)
                    XCTAssertTrue(failed.isEmpty,
                                  "pane \(Int(width)), \(pinned ? "following the tail" : "scrolled back, pill shown"), \(phase.rawValue): \(failed.count) of \(ref.points.count) points miss the card text view: \(failed.prefix(3))")
                }
            }
        }
    }

    /// A freshly materialized turn, the moment it is added: measured, sized and positioned by
    /// `ReplView`, but `ChatTurnView.layout()` has not placed its blocks yet.
    func testTheCardTextViewIsHitOverTheParagraphAtEveryWidthBeforeTheFirstLayoutPass() {
        checkFreshPanes([.beforeAnyLayoutPass])
    }

    /// Fresh pane at each width, with the pill hidden and shown.
    func testTheCardTextViewIsHitOverTheParagraphAtEveryWidthOnceLayoutHasRun() {
        checkFreshPanes([.afterARunLoopTurn, .afterALayoutPass])
    }

    /// One pane, resized through the widths via the sequence `ReplView.measure` uses.
    func testTheCardTextViewIsHitOverTheParagraphAfterEveryPaneWidthChange() {
        guard let start = reference(width: 900) else { return }
        let rig = ReplRig(self, blocks: blocks, paneWidth: 900, islandWidth: start.islandWidth)
        rig.converge()
        for width in [640, 520, 1415, 780, 900, 520, 1415 as CGFloat] {
            guard let ref = reference(width: width) else { continue }
            rig.changePane(to: width, islandWidth: ref.islandWidth)
            for phase in Phase.allCases {
                advance(rig, to: phase)
                let failed = misses(rig, ref.points)
                XCTAssertTrue(failed.isEmpty,
                              "after resizing to \(Int(width)), \(phase.rawValue): \(failed.count) of \(ref.points.count) points miss the card text view: \(failed.prefix(3))")
            }
        }
    }
}

// MARK: - A re-measure in the middle of a drag

/// `ReplView.measure` detaches the turn (dropping first responder) and puts the held
/// selection back. A streamed block, or a tool result expanding, can trigger that while
/// the operator is still dragging. The drag must still end up selecting what was dragged.
///
/// The drag is driven through `RigWindow` as elsewhere: the mouse-down enters the text
/// view's own nested tracking loop. The re-measure runs from a timer that fires *inside*
/// that loop (event-tracking run-loop mode, as a main-queue pass would), after the first
/// dragged events have been consumed; the timer then queues the rest of the drag and the
/// mouse-up.
final class ProseSelectionRemeasureMidDragTests: XCTestCase {

    private struct Gesture {
        let expected: NSRange
        let expectedString: String
        let points: [NSPoint]
    }

    /// A drag across the end of one wrapped line and the start of the next.
    private func gesture(in tv: NSTextView, steps: Int = 8) -> Gesture? {
        let text = tv.string as NSString
        let start = text.range(of: "Second paragraph").location
        guard start != NSNotFound else { return nil }
        let lines = Target.lineRanges(tv).filter { $0.location >= start && $0.length >= 20 }
        guard let first = lines.first, let second = lines.first(where: { $0.location == NSMaxRange(first) }) else { return nil }
        let range = NSRange(location: NSMaxRange(first) - 8, length: 16)
        _ = second
        let a = Target.windowRect(tv, NSRange(location: range.location, length: 1))
        let b = Target.windowRect(tv, NSRange(location: NSMaxRange(range) - 1, length: 1))
        let from = NSPoint(x: a.minX + 1, y: a.midY), to = NSPoint(x: b.maxX - 1, y: b.midY)
        let points = (1...steps).map { i -> NSPoint in
            let f = CGFloat(i) / CGFloat(steps)
            return NSPoint(x: from.x + (to.x - from.x) * f, y: from.y + (to.y - from.y) * f)
        }
        return Gesture(expected: range, expectedString: text.substring(with: range), points: [from] + points)
    }

    private func mouse(_ type: NSEvent.EventType, _ window: NSWindow, _ p: NSPoint, _ n: Int, _ t: TimeInterval) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: t, windowNumber: window.windowNumber,
                           context: nil, eventNumber: n, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    /// Runs the drag, calling `interrupt` after the first dragged events have been consumed.
    /// Returns whether the safety net (a background mouse-up) had to release a stuck loop.
    private func dragInterrupted(_ rig: ReplRig, _ g: Gesture, interrupt: @escaping () -> Void) -> Bool {
        let window = rig.window
        let t0 = ProcessInfo.processInfo.systemUptime
        let number = 777
        let down = mouse(.leftMouseDown, window, g.points[0], number, t0)
        let drags = Array(g.points.dropFirst())
        let early = drags.prefix(3), late = drags.dropFirst(3)
        for (i, p) in early.enumerated() { NSApp.postEvent(mouse(.leftMouseDragged, window, p, number, t0 + 0.001 * Double(i + 1)), atStart: false) }
        let lateEvents = late.enumerated().map { mouse(.leftMouseDragged, window, $0.element, number, t0 + 0.001 * Double($0.offset + 4)) }
        let up = mouse(.leftMouseUp, window, g.points.last!, number, t0 + 0.05)

        let timer = Timer(timeInterval: 0.15, repeats: false) { _ in
            interrupt()
            for e in lateEvents { NSApp.postEvent(e, atStart: false) }
            NSApp.postEvent(up, atStart: false)
        }
        RunLoop.main.add(timer, forMode: .common)
        let rescue = mouse(.leftMouseUp, window, g.points.last!, number, t0 + 0.06)
        let fired = Fired()
        let net = DispatchSource.makeTimerSource(queue: .global())
        net.schedule(deadline: .now() + 4)
        net.setEventHandler { fired.set(); NSApp.postEvent(rescue, atStart: false) }
        net.resume()
        window.sendEvent(down)
        net.cancel()
        timer.invalidate()
        return fired.value
    }

    private final class Fired {
        private let lock = NSLock()
        private var v = false
        func set() { lock.lock(); v = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
    }

    private func leftovers() -> Int {
        var n = 0
        while NSApp.nextEvent(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged], until: .distantPast,
                              inMode: .default, dequeue: true) != nil { n += 1 }
        return n
    }

    private func run(_ what: String, expectInterrupt: Bool = true, interrupt: (ReplRig) -> () -> Void) throws {
        let rig = ReplRig(self, blocks: [.text(ProseElement.markdown)], paneWidth: 900)
        rig.converge()
        guard let tv = rig.cardTextView, let g = gesture(in: tv) else { return XCTFail("could not plan the drag") }
        let action = interrupt(rig)
        var ran = false
        var midSelection = NSRange(location: NSNotFound, length: 0)
        var heldWhenInterrupted = false
        let rescued = dragInterrupted(rig, g) {
            ran = true
            midSelection = tv.selectedRange
            heldWhenInterrupted = TranscriptSelection.capture(in: rig.turn) != nil
            action()
        }
        if expectInterrupt {
            XCTAssertTrue(ran, "\(what): the mid-drag interruption never ran, so nothing was tested")
            XCTAssertGreaterThan(midSelection.length, 0, "\(what): no selection was in progress when the re-measure ran")
            XCTAssertTrue(heldWhenInterrupted, "\(what): the card text view was not the first responder holding a selection when the re-measure ran")
        }
        let selection = tv.selectedRange
        let selectedText = (selection.location != NSNotFound && NSMaxRange(selection) <= (tv.string as NSString).length)
            ? (tv.string as NSString).substring(with: selection) : "?"
        print("MIDDRAG \(what): selection \(selection) \"\(selectedText)\" expected \(g.expected) first responder \(String(describing: rig.window.firstResponder)) rescued \(rescued) card still attached \(tv.window != nil)")
        _ = leftovers()
        XCTAssertFalse(rescued, "\(what): the drag was still waiting for its mouse-up after 4 s; tracking was lost mid-drag")
        XCTAssertEqual(selection, g.expected,
                       "\(what): after a re-measure mid-drag the selection is \"\(selectedText)\" \(selection), not the dragged \"\(g.expectedString)\" \(g.expected)")
        XCTAssertTrue(rig.window.firstResponder === tv, "\(what): the card text view lost focus: \(String(describing: rig.window.firstResponder))")
    }

    func testControlADragWithNoReMeasureSelectsExactlyTheDraggedText() throws {
        try run("control (no re-measure)", expectInterrupt: false) { _ in {} }
    }

    func testADragStillSelectsTheDraggedTextWhenTheTurnIsReMeasuredMidDrag() throws {
        try run("ReplView.measure sequence mid-drag") { rig in { rig.measure() } }
    }

    func testADragStillSelectsTheDraggedTextWhenTheBlockIsMeasuredMidDrag() throws {
        try run("ChatTurnView.measureIsland mid-drag") { rig in {
            if let island = rigAllSubviews(of: rig.turn).first(where: { $0 is TextBlockView }) {
                _ = ChatTurnView.measureIsland(island, width: ChatTurnView.blockWidth(paneWidth: rig.contentWidth))
            }
        } }
    }

    func testADragStillSelectsTheDraggedTextWhenABlockStreamsInMidDrag() throws {
        try run("a streamed block mid-drag") { rig in { rig.stream(.text("A block that streamed in while the operator was dragging.")) } }
    }
}

// MARK: - Follow-tail while a selection is held

final class PinnedPaneSelectionTests: XCTestCase {

    private let card = TurnBlock.text(ProseElement.markdown)

    /// `ReplView` pass step 5: a pinned pane ends the pass at the bottom.
    private func finishPass(_ rig: ReplRig) {
        if rig.followTail.isPinned { rig.followTail.scrollToBottom() }
    }

    private func maxOrigin(_ rig: ReplRig) -> CGFloat { rig.doc.frame.height - rig.clip.bounds.height }

    private func run(scrollOnFocus: Bool) {
        let rig = ReplRig(self, blocks: Array(repeating: card, count: 10), paneWidth: 520)
        rig.converge()
        XCTAssertGreaterThan(rig.doc.frame.height, rig.clip.bounds.height + 300, "precondition: the transcript is taller than the pane")
        rig.followTail.scrollToBottom()
        XCTAssertTrue(rig.followTail.isPinned, "precondition")
        XCTAssertEqual(rig.clip.bounds.origin.y, maxOrigin(rig), accuracy: 1, "precondition: at the bottom")
        // The held selection is in the first card, far above the viewport.
        guard let tv = rig.cardTextView else { return XCTFail("no card text view") }
        XCTAssertTrue(rig.window.makeFirstResponder(tv))
        tv.setSelectedRange(NSRange(location: 7, length: 12))
        rig.followTail.scrollToBottom()   // taking focus may have moved the reader; this is the pinned pane
        rig.flips.removeAll()

        var follower: NSObjectProtocol?
        if scrollOnFocus {
            follower = NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: tv, queue: nil) { _ in
                tv.scrollRangeToVisible(tv.selectedRange)
            }
        }
        defer { follower.map(NotificationCenter.default.removeObserver) }

        for i in 1...3 {
            rig.stream(.text("streamed block \(i)"))   // measure(): detach, re-measure, re-attach, restore the selection
            finishPass(rig)
            XCTAssertTrue(rig.followTail.isPinned, "block \(i): the pane stopped following the tail")
            XCTAssertEqual(rig.clip.bounds.origin.y, maxOrigin(rig), accuracy: 1,
                           "block \(i): the pane is not at the bottom (origin \(rig.clip.bounds.origin.y), bottom \(maxOrigin(rig)))")
        }
        XCTAssertEqual(tv.selectedRange, NSRange(location: 7, length: 12), "the held selection was lost")
        print("PINNEDSELECTION scrollOnFocus=\(scrollOnFocus): flips \(rig.flips.map { "\($0.pinned ? "pin" : "unpin")(\($0.cause.rawValue))" })")
        if !scrollOnFocus {
            XCTAssertTrue(rig.flips.isEmpty, "the pinned flag flipped while a block streamed in: \(rig.flips.map { "\($0.pinned) \($0.cause.rawValue)" })")
        }
    }

    func testAPinnedPaneKeepsFollowingTheTailWhenABlockStreamsIntoATurnHoldingASelection() {
        run(scrollOnFocus: false)
    }

    /// If taking focus does scroll (as in an active window), the restore guard must still
    /// leave the pane pinned and at the bottom when the pass is over.
    func testAPinnedPaneEndsAtTheBottomEvenIfTakingFocusScrollsToTheSelection() {
        run(scrollOnFocus: true)
    }
}

// MARK: - MarkdownCardView layout

/// The card sizes its text view by frame in `layout()` (the text view is neither
/// vertically resizable nor constraint-driven). So a resize of the card has to reach
/// `layout()`, and the text view must always be tall enough for its laid-out text:
/// with `isVerticallyResizable` off, anything below the frame is hard-clipped.
final class MarkdownCardLayoutTests: XCTestCase {

    private let md = "Filed `bugs/open/prose-selection.md` for this one.\n\n"
        + "Second paragraph with some words to select across lines when the pane is narrow enough to wrap; "
        + "this sentence keeps going so the paragraph is certain to wrap onto several lines at the width of the "
        + "transcript pane, and then it goes on a little further for good measure.\n\n- item one\n- item two"

    /// An offscreen window that IS on the window server's books (ordered front, parked far
    /// outside every screen, never activated), so AppKit's own display-cycle layout runs.
    private func makeParkedWindow() -> RigWindow {
        _ = NSApplication.shared
        let window = RigWindow(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 700),
                               styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.orderFrontRegardless()
        window.makeKey()
        rigSettle(0.15)
        addTeardownBlock { window.close() }
        return window
    }

    private func textView(of card: MarkdownCardView) -> NSTextView? {
        card.subviews.compactMap { $0 as? NSTextView }.first
    }

    private func place(_ card: MarkdownCardView, width: CGFloat, in window: NSWindow) {
        card.presetWidth = width
        card.frame = NSRect(x: 20, y: 20, width: width, height: MarkdownCardView.measuredHeight(markdown: md, width: width))
        window.contentView!.addSubview(card)
    }

    private func assertFillsInterior(_ card: MarkdownCardView, _ tv: NSTextView, _ message: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(tv.frame.width, card.bounds.width - 24, accuracy: 0.5, "\(message): width. card \(card.frame), text view \(tv.frame)", file: file, line: line)
        XCTAssertEqual(tv.frame.height, card.bounds.height - 24, accuracy: 0.5, "\(message): height. card \(card.frame), text view \(tv.frame)", file: file, line: line)
        XCTAssertEqual(tv.frame.minX, 12, accuracy: 0.5, message, file: file, line: line)
        XCTAssertEqual(tv.frame.minY, 12, accuracy: 0.5, message, file: file, line: line)
    }

    // (1) A pure frame resize of the card, nothing else.

    func testResizingTheCardsFrameBringsItsTextViewWithIt() throws {
        let window = makeParkedWindow()
        let card = MarkdownCardView(markdown: md)
        place(card, width: 500, in: window)
        rigSettle()
        let tv = try XCTUnwrap(textView(of: card))
        assertFillsInterior(card, tv, "initial")

        card.setFrameSize(NSSize(width: 360, height: MarkdownCardView.measuredHeight(markdown: md, width: 360)))
        rigSettle()
        assertFillsInterior(card, tv, "after card.setFrameSize(360 wide)")

        card.frame = NSRect(x: 20, y: 20, width: 700, height: MarkdownCardView.measuredHeight(markdown: md, width: 700))
        rigSettle()
        assertFillsInterior(card, tv, "after card.frame = 700 wide")
    }

    func testAPaneWidthChangeInTheRealHierarchyBringsTheCardsTextViewWithIt() throws {
        let rig = ReplRig(self, blocks: [.text(md)], paneWidth: 900)
        rig.converge()
        for width in [640 as CGFloat, 520, 1100, 780] {
            rig.changePane(to: width)
            rigSettle()   // no explicit layout: whatever AppKit does by itself
            let tv = try XCTUnwrap(rig.cardTextView)
            let card = try XCTUnwrap(tv.superview as? MarkdownCardView, "text view is not in a card: \(rigChain(tv))")
            assertFillsInterior(card, tv, "pane \(Int(width)), no explicit layout pass")
            XCTAssertEqual(card.bounds.width, ChatTurnView.blockWidth(paneWidth: rig.contentWidth), accuracy: 0.5,
                           "pane \(Int(width)): the card is not as wide as its block column")
        }
    }

    // (2) The last line is never hard-clipped.

    /// Lays `card` out at `layoutWidth`, with the height `measuredHeight` gave for `presetWidth`
    /// (which is what the real pane does), and returns how much taller the laid-out text is
    /// than its view (positive = clipped).
    private func shortfall(presetWidth: CGFloat, layoutWidth: CGFloat, in window: NSWindow) -> CGFloat? {
        let card = MarkdownCardView(markdown: md)
        card.presetWidth = presetWidth
        card.frame = NSRect(x: 0, y: 0, width: layoutWidth,
                            height: MarkdownCardView.measuredHeight(markdown: md, width: presetWidth))
        window.contentView!.addSubview(card)
        card.layoutSubtreeIfNeeded()
        defer { card.removeFromSuperview() }
        guard let tv = textView(of: card), let lm = tv.layoutManager, let tc = tv.textContainer else { return nil }
        lm.ensureLayout(for: tc)
        return lm.usedRect(for: tc).height - tv.frame.height
    }

    func testTheCardsTextViewIsNeverShorterThanItsLaidOutTextAcrossWidthsAndHalfPointOffsets() throws {
        let window = makeRigWindow(self, size: NSSize(width: 1500, height: 900))
        var worst: (shortfall: CGFloat, desc: String) = (-.infinity, "")
        var failures: [String] = []
        // ~10 coarse widths, then a fine sweep so a wrap boundary lands within half a point of some of them.
        let widths = [300, 380, 460, 540, 620, 700, 820, 940, 1100, 1400].map { CGFloat($0) }
            + stride(from: 300 as CGFloat, through: 1400, by: 3.7).map { $0 }
        for w in widths {
            for offset in [-0.5, 0, 0.5 as CGFloat] {
                guard let miss = shortfall(presetWidth: w, layoutWidth: w + offset, in: window) else {
                    return XCTFail("no text view in the card")
                }
                if miss > worst.shortfall { worst = (miss, "preset \(w), laid out at \(w + offset)") }
                if miss > 0.5 { failures.append("preset \(w), laid out at \(w + offset): text is \(miss) pt taller than its view") }
            }
        }
        print("CARDCLIP widths checked \(widths.count * 3), max shortfall \(worst.shortfall) pt at \(worst.desc)")
        XCTAssertTrue(failures.isEmpty, "\(failures.count) layouts clip the last line (max shortfall \(worst.shortfall) pt at \(worst.desc)); first: \(failures.prefix(3))")
    }
}
