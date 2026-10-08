import XCTest
import AppKit

// ChatModels.swift and ChatTurnView.swift are compiled directly into this
// logic-test target (no host app). `ReplView` is not (its `init` reaches
// `AppStore.shared` and the daemon stack), so the focus rule and selection
// restore it applies are tested through `TranscriptFocusPolicy` /
// `TranscriptSelection`, plus source checks that it calls them.
//
// Contract: text in the transcript can be selected and copied. A Bash tool
// call's full command is reachable (context menu + tooltip) even though the
// row shows only a one-line summary, and an in-progress selection is neither
// cleared by re-render nor by the input bar grabbing focus.

// MARK: - Helpers

private func allSubviews(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + allSubviews(of: $0) }
}

private func textFields(in view: NSView) -> [NSTextField] {
    allSubviews(of: view).compactMap { $0 as? NSTextField }
}

private func jsonString(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
    return String(data: data, encoding: .utf8)!
}

/// >80 chars, multiline, quotes, backslashes, unicode.
private let trickyCommand = """
git log --format="%h %s" | grep -E 'fix|feat' \\
  && echo "done — ✓ naïve café 日本語" \\
  && printf 'tab\\there\\n' # trailing comment that pushes this well past eighty chars
"""

private func bashData(command: String = trickyCommand, summary: String = "git log --format=… (truncated)") -> ToolCallData {
    ToolCallData(toolName: "Bash",
                 inputSummary: summary,
                 inputFull: jsonString(["command": command, "description": "x"]))
}

private func privatePasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("nostromo.test.\(UUID())"))
}

private func invokeItem(_ title: String, in menu: NSMenu) -> Bool {
    guard let idx = menu.items.firstIndex(where: { $0.title == title }) else { return false }
    menu.performActionForItem(at: idx)
    return true
}

private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// Offscreen window that can host a field editor (selectable labels only get
/// one when their window is key). Never ordered front, so nothing flashes.
private func makeWindow(_ size: NSSize = NSSize(width: 700, height: 600)) -> NSWindow {
    let w = KeyableWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: .borderless, backing: .buffered, defer: false)
    w.isReleasedWhenClosed = false
    w.makeKey()
    return w
}

// MARK: - ToolCallData.fullCommand

final class ToolCallFullCommandTests: XCTestCase {

    func testBashReturnsCommandVerbatimNotJSONEscaped() {
        XCTAssertGreaterThan(trickyCommand.count, 80)
        XCTAssertEqual(bashData().fullCommand, trickyCommand)
    }

    func testNonBashFallsBackToInputSummary() {
        let d = ToolCallData(toolName: "Read", inputSummary: "/tmp/a.txt",
                             inputFull: jsonString(["command": "should not be used", "file_path": "/tmp/a.txt"]))
        XCTAssertEqual(d.fullCommand, "/tmp/a.txt")
    }

    func testMalformedJSONFallsBackToInputSummary() {
        let d = ToolCallData(toolName: "Bash", inputSummary: "the summary", inputFull: "{ not json")
        XCTAssertEqual(d.fullCommand, "the summary")
    }

    func testMissingCommandKeyFallsBackToInputSummary() {
        let d = ToolCallData(toolName: "Bash", inputSummary: "the summary",
                             inputFull: jsonString(["description": "no command here"]))
        XCTAssertEqual(d.fullCommand, "the summary")
    }

    func testEmptyInputFullFallsBackToInputSummary() {
        let d = ToolCallData(toolName: "Bash", inputSummary: "the summary", inputFull: "")
        XCTAssertEqual(d.fullCommand, "the summary")
    }
}

// MARK: - Selectability

final class TranscriptSelectabilityTests: XCTestCase {

    func testToolCallSummaryLabelIsSelectable() {
        let data = bashData()
        let view = ToolCallView(data: data)
        let summary = textFields(in: view).filter { $0.stringValue == data.inputSummary }
        XCTAssertFalse(summary.isEmpty, "summary label not found")
        for f in summary { XCTAssertTrue(f.isSelectable) }
    }

    func testUserBubbleTextIsSelectable() {
        let view = UserBubbleView(text: "what the operator typed", imageURLs: [])
        let labels = textFields(in: view).filter { $0.stringValue == "what the operator typed" }
        XCTAssertFalse(labels.isEmpty, "bubble label not found")
        for f in labels { XCTAssertTrue(f.isSelectable) }
    }

    func testErrorBlockMessageLabelIsSelectable() {
        let message = "Something failed: exit code 2"
        let view = ErrorBlockView(message: message)
        let labels = textFields(in: view).filter { $0.stringValue.contains(message) }
        XCTAssertFalse(labels.isEmpty, "message label not found")
        for f in labels { XCTAssertTrue(f.isSelectable) }
    }
}

// MARK: - Copy menu & tooltip

final class ToolCallCopyMenuTests: XCTestCase {

    private func makeView(_ data: ToolCallData) -> (ToolCallView, NSPasteboard) {
        let view = ToolCallView(data: data)
        let pb = privatePasteboard()
        view.pasteboard = pb
        addTeardownBlock { pb.releaseGlobally() }
        return (view, pb)
    }

    func testCopyCommandPutsFullCommandOnPasteboard() {
        let (view, pb) = makeView(bashData())
        XCTAssertTrue(invokeItem("Copy command", in: view.copyMenu()))
        XCTAssertEqual(pb.string(forType: .string), trickyCommand)
    }

    func testCopyFullInputPutsInputFullOnPasteboard() {
        let data = bashData()
        let (view, pb) = makeView(data)
        XCTAssertTrue(invokeItem("Copy full input", in: view.copyMenu()))
        XCTAssertEqual(pb.string(forType: .string), data.inputFull)
    }

    func testCopySummaryPutsInputSummaryOnPasteboard() {
        let data = bashData()
        let (view, pb) = makeView(data)
        XCTAssertTrue(invokeItem("Copy summary", in: view.copyMenu()))
        XCTAssertEqual(pb.string(forType: .string), data.inputSummary)
    }

    func testNonBashMenuHasNoCopyCommandButKeepsOtherItems() {
        let d = ToolCallData(toolName: "Read", inputSummary: "/tmp/a.txt",
                             inputFull: jsonString(["file_path": "/tmp/a.txt"]))
        let (view, pb) = makeView(d)
        let titles = view.copyMenu().items.map(\.title)
        XCTAssertFalse(titles.contains("Copy command"))
        XCTAssertTrue(titles.contains("Copy full input"))
        XCTAssertTrue(titles.contains("Copy summary"))
        XCTAssertTrue(invokeItem("Copy summary", in: view.copyMenu()))
        XCTAssertEqual(pb.string(forType: .string), "/tmp/a.txt")
    }

    func testBashMenuListsAllThreeItems() {
        let (view, _) = makeView(bashData())
        let titles = view.copyMenu().items.map(\.title)
        XCTAssertTrue(titles.contains("Copy command"))
        XCTAssertTrue(titles.contains("Copy full input"))
        XCTAssertTrue(titles.contains("Copy summary"))
    }

    func testContextMenuIsTheCopyMenu() {
        let (view, _) = makeView(bashData())
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                                       timestamp: 0, windowNumber: 0, context: nil,
                                       eventNumber: 0, clickCount: 1, pressure: 1)!
        let titles = view.menu(for: event)?.items.map(\.title) ?? []
        XCTAssertTrue(titles.contains("Copy command"))
    }

    func testToolTipIsFullCommandForBash() {
        let (view, _) = makeView(bashData())
        XCTAssertEqual(view.toolTip, trickyCommand)
    }

    func testToolTipIsCappedForHugeCommand() {
        let huge = String(repeating: "x", count: 5000)
        let (view, _) = makeView(bashData(command: huge))
        let tip = view.toolTip
        XCTAssertNotNil(tip)
        XCTAssertLessThanOrEqual(tip!.count, 2001)
        XCTAssertTrue(tip!.hasPrefix(String(repeating: "x", count: 2000)))
    }

    func testToolTipIsNonNilForNonBash() {
        let d = ToolCallData(toolName: "Read", inputSummary: "/tmp/a.txt", inputFull: "{}")
        XCTAssertNotNil(ToolCallView(data: d).toolTip)
    }
}

// MARK: - Context menu reachability

/// `ToolCallView.menu(for:)` is only useful if a real right-click gets there.
/// A selectable label that owns the field editor answers the click itself, so
/// these tests hit-test like AppKit does instead of calling `menu(for:)` on the
/// row directly.
final class ToolCallContextMenuReachabilityTests: XCTestCase {

    private struct Row {
        let window: NSWindow
        let view: ToolCallView
        let pasteboard: NSPasteboard
    }

    private func makeRow(_ data: ToolCallData) -> Row {
        let window = makeWindow(NSSize(width: 420, height: 200))
        let view = ToolCallView(data: data)
        let pb = privatePasteboard()
        view.pasteboard = pb
        addTeardownBlock { pb.releaseGlobally() }
        view.frame = NSRect(x: 0, y: 100, width: 400, height: 30)
        window.contentView!.addSubview(view)
        view.layoutSubtreeIfNeeded()
        window.contentView!.layoutSubtreeIfNeeded()
        return Row(window: window, view: view, pasteboard: pb)
    }

    /// The menu AppKit would pop for a right-click at the centre of `target`:
    /// hit-test the window, then take the first non-nil `menu(for:)` walking up
    /// the superview chain.
    private func contextMenu(atCentreOf target: NSView, in window: NSWindow) -> NSMenu? {
        let point = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        guard let hit = window.contentView!.superview!.hitTest(point),
              let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                                             timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1)
        else { return nil }
        var view: NSView? = hit
        while let current = view {
            if let menu = current.menu(for: event) { return menu }
            view = current.superview
        }
        return nil
    }

    private func assertCopyItems(_ menu: NSMenu?, file: StaticString = #filePath, line: UInt = #line) {
        let titles = menu?.items.map(\.title) ?? []
        for expected in ["Copy command", "Copy full input", "Copy summary"] {
            XCTAssertTrue(titles.contains(expected), "right-click menu is \(titles); missing \(expected)",
                          file: file, line: line)
        }
    }

    func testRightClickOnEveryLabelOfTheRowReachesTheCopyMenu() {
        let row = makeRow(bashData(summary: "git log --format=… (truncated)"))
        let labels = textFields(in: row.view)
        XCTAssertGreaterThanOrEqual(labels.count, 4)
        for label in labels {
            assertCopyItems(contextMenu(atCentreOf: label, in: row.window))
        }
    }

    func testRightClickOnSelectedSummaryLabelReachesTheCopyMenu() {
        let data = bashData(summary: "git log --format=… (truncated)")
        let row = makeRow(data)
        guard let label = textFields(in: row.view).first(where: { $0.stringValue == data.inputSummary }) else {
            return XCTFail("summary label not found")
        }
        label.selectText(nil)   // the label now owns the field editor and answers clicks itself
        XCTAssertNotNil(label.currentEditor(), "precondition: label is being edited")
        assertCopyItems(contextMenu(atCentreOf: label, in: row.window))
    }

    func testCopyCommandFromMenuReachedWhileSelectedCopiesFullCommand() {
        let data = bashData(summary: "git log --format=… (truncated)")
        let row = makeRow(data)
        guard let label = textFields(in: row.view).first(where: { $0.stringValue == data.inputSummary }) else {
            return XCTFail("summary label not found")
        }
        label.selectText(nil)
        guard let menu = contextMenu(atCentreOf: label, in: row.window) else { return XCTFail("no menu") }
        XCTAssertTrue(invokeItem("Copy command", in: menu))
        XCTAssertEqual(row.pasteboard.string(forType: .string), trickyCommand)
    }
}

// MARK: - Layout unchanged

final class ToolCallLayoutUnchangedTests: XCTestCase {

    func testInputFullDoesNotAffectRowSize() {
        let short = "ls -la"
        let a = ToolCallView(data: ToolCallData(toolName: "Bash", inputSummary: short,
                                                inputFull: jsonString(["command": short])))
        let b = ToolCallView(data: ToolCallData(toolName: "Bash", inputSummary: short,
                                                inputFull: jsonString(["command": String(repeating: "word ", count: 2000)])))
        for v in [a, b] {
            v.frame = NSRect(x: 0, y: 0, width: 600, height: 10)
            v.layoutSubtreeIfNeeded()
        }
        XCTAssertEqual(a.fittingSize.height, b.fittingSize.height, accuracy: 0.01)
        XCTAssertEqual(a.fittingSize.width, b.fittingSize.width, accuracy: 0.01)
    }

    /// A selectable label that takes the field editor must lay out exactly as it
    /// did unselected — same frame in place, same row height when the app next
    /// measures it (`ChatTurnView.measureIsland`, at the column width). The editor
    /// takes its font and wrapping from the cell, so this fails if the label
    /// carries them only in its attributed string.
    func testSelectingALongSummaryDoesNotChangeRowHeightOrLabelGeometry() {
        let long = String(repeating: "git log --format=abc | grep fix && ", count: 8)
        let data = ToolCallData(toolName: "Bash", inputSummary: long,
                                inputFull: jsonString(["command": long]))
        let window = makeWindow(NSSize(width: 420, height: 200))
        let view = ToolCallView(data: data)
        view.pasteboard = privatePasteboard()
        window.contentView!.addSubview(view)

        let heightBefore = ChatTurnView.measureIsland(view, width: 400)
        view.layoutSubtreeIfNeeded()
        window.contentView!.layoutSubtreeIfNeeded()
        guard let label = textFields(in: view).first(where: { $0.stringValue == long }) else {
            return XCTFail("summary label not found")
        }
        let frameBefore = label.frame
        let rowFrameBefore = view.frame

        label.selectText(nil)
        XCTAssertNotNil(label.currentEditor(), "precondition: label is being edited")
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        window.contentView!.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.frame, rowFrameBefore, "row frame changed while its label is being edited")
        XCTAssertEqual(label.frame, frameBefore, "label frame changed while being edited")
        XCTAssertEqual(label.lineBreakMode, .byWordWrapping)
        XCTAssertEqual(label.font, Theme.monoFont, "editor would pick up a different font from the cell")
        XCTAssertEqual(ChatTurnView.measureIsland(view, width: 400), heightBefore, accuracy: 0.01)
    }
}

// MARK: - Focus policy

/// A pane's transcript, as `ReplView` builds it: a scroll view whose document
/// view holds the turn views.
private func makeTranscript(containing views: [NSView], width: CGFloat = 400) -> NSScrollView {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 200))
    let document = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 200))
    scroll.documentView = document
    for v in views { document.addSubview(v) }
    return scroll
}

final class TranscriptFocusPolicyTests: XCTestCase {

    private struct Pane {
        let window: NSWindow
        let transcript: NSScrollView
        let label: NSTextField
        let input: NSTextView
    }

    /// Window holding a transcript (one text block) and an input view.
    private func makePane(text: String = "select me please", in window: NSWindow? = nil,
                          x: CGFloat = 0) -> Pane {
        let window = window ?? makeWindow()
        let bubble = TextBlockView(text: text)
        bubble.frame = NSRect(x: 0, y: 0, width: 400, height: 60)
        let transcript = makeTranscript(containing: [bubble])
        transcript.frame.origin = NSPoint(x: x, y: 300)
        let input = NSTextView(frame: NSRect(x: x, y: 100, width: 400, height: 30))
        window.contentView!.addSubview(transcript)
        window.contentView!.addSubview(input)
        window.contentView!.layoutSubtreeIfNeeded()
        let label = textFields(in: transcript).first { $0.stringValue.contains(text) }!
        return Pane(window: window, transcript: transcript, label: label, input: input)
    }

    private func select(_ range: NSRange, in label: NSTextField) -> NSTextView? {
        label.selectText(nil)   // creates the field editor even in an unshown test window
        guard let editor = label.currentEditor() as? NSTextView else { return nil }
        editor.setSelectedRange(range)
        return editor
    }

    func testDoesNotStealFocusWhileTranscriptTextIsSelected() {
        let pane = makePane()
        guard select(NSRange(location: 0, length: 6), in: pane.label) != nil else {
            return XCTFail("could not focus the paragraph label")
        }
        XCTAssertFalse(TranscriptFocusPolicy.shouldFocusInput(
            currentFirstResponder: pane.window.firstResponder, inputTextView: pane.input,
            transcript: pane.transcript))
    }

    func testFocusesInputWhenTranscriptEditorHasNoSelection() {
        let pane = makePane()
        guard select(NSRange(location: 3, length: 0), in: pane.label) != nil else {
            return XCTFail("could not focus the paragraph label")
        }
        XCTAssertTrue(TranscriptFocusPolicy.shouldFocusInput(
            currentFirstResponder: pane.window.firstResponder, inputTextView: pane.input,
            transcript: pane.transcript))
    }

    func testFocusesInputForNilWindowAndContentViewResponders() {
        let pane = makePane()
        let input = pane.input
        let t = pane.transcript
        XCTAssertTrue(TranscriptFocusPolicy.shouldFocusInput(currentFirstResponder: nil, inputTextView: input, transcript: t))
        XCTAssertTrue(TranscriptFocusPolicy.shouldFocusInput(currentFirstResponder: pane.window, inputTextView: input, transcript: t))
        XCTAssertTrue(TranscriptFocusPolicy.shouldFocusInput(currentFirstResponder: pane.window.contentView, inputTextView: input, transcript: t))
        XCTAssertTrue(TranscriptFocusPolicy.shouldFocusInput(currentFirstResponder: nil, inputTextView: nil, transcript: t))
    }

    func testInputViewItselfWithSelectionStillCountsAsFocusable() {
        let pane = makePane()
        pane.input.string = "draft message"
        pane.input.setSelectedRange(NSRange(location: 0, length: 5))
        XCTAssertTrue(TranscriptFocusPolicy.shouldFocusInput(
            currentFirstResponder: pane.input, inputTextView: pane.input, transcript: pane.transcript))
    }

    /// A plain (non field-editor) text view inside the transcript with a selection.
    func testPlainTextViewInsideTranscriptWithSelectionBlocksFocus() {
        let inside = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        inside.string = "some transcript text"
        inside.setSelectedRange(NSRange(location: 0, length: 4))
        let transcript = makeTranscript(containing: [inside])
        let input = NSTextView(frame: .zero)
        XCTAssertFalse(TranscriptFocusPolicy.shouldFocusInput(
            currentFirstResponder: inside, inputTextView: input, transcript: transcript))
    }

    /// An unrelated selection (a text view elsewhere in the window) must not stop
    /// a newly attached pane from taking focus.
    func testTextViewOutsideTranscriptWithSelectionDoesNotBlockFocus() {
        let other = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        other.string = "some draft elsewhere"
        other.setSelectedRange(NSRange(location: 0, length: 4))
        let transcript = makeTranscript(containing: [])
        let input = NSTextView(frame: .zero)
        XCTAssertTrue(TranscriptFocusPolicy.shouldFocusInput(
            currentFirstResponder: other, inputTextView: input, transcript: transcript))
    }

    /// Sibling pane A has a selection in its input draft; pane B attaching must still focus.
    func testSiblingPaneInputDraftSelectionDoesNotBlockFocus() {
        let window = makeWindow(NSSize(width: 900, height: 700))
        let a = makePane(in: window, x: 0)
        let b = makePane(in: window, x: 450)
        a.input.string = "draft in pane A"
        a.input.setSelectedRange(NSRange(location: 0, length: 5))
        XCTAssertTrue(TranscriptFocusPolicy.shouldFocusInput(
            currentFirstResponder: a.input, inputTextView: b.input, transcript: b.transcript))
    }

    /// Sibling pane A has selected transcript text (field editor); pane B attaching must still focus.
    func testSiblingPaneTranscriptSelectionDoesNotBlockFocus() {
        let window = makeWindow(NSSize(width: 900, height: 700))
        let a = makePane(text: "pane A text", in: window, x: 0)
        let b = makePane(text: "pane B text", in: window, x: 450)
        guard select(NSRange(location: 0, length: 4), in: a.label) != nil else {
            return XCTFail("could not focus pane A's label")
        }
        XCTAssertTrue(TranscriptFocusPolicy.shouldFocusInput(
            currentFirstResponder: window.firstResponder, inputTextView: b.input, transcript: b.transcript))
        // …while A's own attach would still respect its own selection.
        XCTAssertFalse(TranscriptFocusPolicy.shouldFocusInput(
            currentFirstResponder: window.firstResponder, inputTextView: a.input, transcript: a.transcript))
    }

    // MARK: Window-level wiring (what ReplView.viewDidMoveToWindow calls)

    func testFocusInputIfAppropriateLeavesSelectedTranscriptTextAlone() {
        let pane = makePane()
        guard let editor = select(NSRange(location: 1, length: 5), in: pane.label) else {
            return XCTFail("could not focus the paragraph label")
        }
        TranscriptFocusPolicy.focusInputIfAppropriate(in: pane.window, inputTextView: pane.input,
                                                      transcript: pane.transcript)
        XCTAssertTrue(pane.window.firstResponder === editor, "selection holder lost first responder")
        XCTAssertEqual(editor.selectedRange, NSRange(location: 1, length: 5))
    }

    func testFocusInputIfAppropriateFocusesInputWithoutSelection() {
        let pane = makePane()
        TranscriptFocusPolicy.focusInputIfAppropriate(in: pane.window, inputTextView: pane.input,
                                                      transcript: pane.transcript)
        XCTAssertTrue(pane.window.firstResponder === pane.input)
    }

    func testFocusInputIfAppropriateFocusesInputDespiteUnrelatedSelection() {
        let window = makeWindow(NSSize(width: 900, height: 700))
        let a = makePane(text: "pane A text", in: window, x: 0)
        let b = makePane(text: "pane B text", in: window, x: 450)
        guard select(NSRange(location: 0, length: 4), in: a.label) != nil else {
            return XCTFail("could not focus pane A's label")
        }
        TranscriptFocusPolicy.focusInputIfAppropriate(in: window, inputTextView: b.input, transcript: b.transcript)
        XCTAssertTrue(window.firstResponder === b.input)
    }

    /// `ReplView` can't be built in this target (its `init` reaches
    /// `AppStore.shared` and the daemon stack), so pin the one call it makes.
    func testReplViewAttachGoesThroughTheFocusPolicy() throws {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Nostromo/UI/Views/ReplView.swift")
        let source = try String(contentsOf: views, encoding: .utf8)
        guard let start = source.range(of: "override func viewDidMoveToWindow()") else {
            return XCTFail("viewDidMoveToWindow not found in ReplView.swift")
        }
        let body = String(source[start.lowerBound...].prefix(900))
        XCTAssertTrue(body.contains("TranscriptFocusPolicy.focusInputIfAppropriate"),
                      "viewDidMoveToWindow no longer routes focus through TranscriptFocusPolicy")
        XCTAssertTrue(body.contains("transcript: self.scrollView"),
                      "the focus guard must be scoped to this pane's transcript scroll view")
        XCTAssertFalse(body.contains("window.makeFirstResponder(self.inputBar.textView)"),
                       "viewDidMoveToWindow focuses the input directly again, bypassing the guard")
    }
}

// MARK: - Selection survival

final class TranscriptSelectionSurvivalTests: XCTestCase {

    private let paragraph = "A paragraph of assistant text that the operator wants to copy."

    private func makeSelectedTurn(width: CGFloat = 900, extraBlocks: [TurnBlock] = [])
        -> (ChatTurnView, NSWindow, NSTextField, NSTextView, NSRange)? {
        let turn = ChatTurn(userInput: "hi", timestamp: Date(),
                            blocks: [.text(paragraph)] + extraBlocks, isComplete: false)
        let view = ChatTurnView(turn: turn, contentAvailable: true, interaction: TurnInteractionState())
        let window = makeWindow(NSSize(width: 900, height: 900))
        window.contentView!.addSubview(view)
        view.setIslandWidth(width)
        view.frame = NSRect(x: 0, y: 0, width: width, height: view.islandHeight())
        view.layoutSubtreeIfNeeded()
        guard let label = textFields(in: view).first(where: { $0.stringValue == paragraph }) else { return nil }
        label.selectText(nil)   // creates the field editor even in an unshown test window
        guard let editor = label.currentEditor() as? NSTextView else { return nil }
        let range = NSRange(location: 2, length: 9)
        editor.setSelectedRange(range)
        return (view, window, label, editor, range)
    }

    func testSelectionSurvivesRelayoutAndAppendedBlocks() {
        var turn = ChatTurn(userInput: "hi", timestamp: Date(),
                            blocks: [.text(paragraph)], isComplete: false)
        guard let (view, window, label, _, range) = makeSelectedTurn() else {
            return XCTFail("could not select the paragraph")
        }

        // Unchanged-width relayout.
        view.setIslandWidth(900)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        window.contentView!.layoutSubtreeIfNeeded()

        // Streaming: a new block is appended; earlier blocks must be left alone.
        turn.blocks.append(.text("A second paragraph arrives while selecting."))
        view.update(turn: turn)
        view.frame = NSRect(x: 0, y: 0, width: 900, height: view.islandHeight())
        view.layoutSubtreeIfNeeded()

        XCTAssertTrue(label.window === window, "selected label was removed from the window")
        XCTAssertNotNil(label.currentEditor(), "selection lost: label is no longer being edited/selected")
        XCTAssertEqual((label.currentEditor() as? NSTextView)?.selectedRange, range)
    }

    /// A pane resize re-measures every block, and `measureIsland` detaches the
    /// block it measures — which drops a live field editor unless the selection
    /// is put back.
    func testSelectionSurvivesColumnWidthChange() {
        guard let (view, window, label, _, range) = makeSelectedTurn() else {
            return XCTFail("could not select the paragraph")
        }
        view.setIslandWidth(640)
        view.frame = NSRect(x: 0, y: 0, width: 640, height: view.islandHeight())
        view.layoutSubtreeIfNeeded()

        XCTAssertTrue(label.window === window)
        guard let editor = label.currentEditor() as? NSTextView else {
            return XCTFail("selection lost across a width change")
        }
        XCTAssertEqual(editor.selectedRange, range)
        XCTAssertTrue(window.firstResponder === editor)
    }

    /// Expanding a tool result re-measures only that block (`remeasureColumnView`).
    func testSelectionInAnotherBlockSurvivesToolResultExpand() {
        let result = TurnBlock.toolResult(ToolResultData(content: "line1\nline2\nline3\nline4", isError: false))
        guard let (view, window, label, _, range) = makeSelectedTurn(extraBlocks: [result]) else {
            return XCTFail("could not select the paragraph")
        }
        let disclosures = allSubviews(of: view).compactMap { $0 as? NSButton }
        guard let disclosure = disclosures.first else { return XCTFail("tool result disclosure not found") }
        disclosure.performClick(nil)
        view.frame = NSRect(x: 0, y: 0, width: 900, height: view.islandHeight())
        view.layoutSubtreeIfNeeded()

        XCTAssertTrue(label.window === window)
        XCTAssertEqual((label.currentEditor() as? NSTextView)?.selectedRange, range,
                       "selection in a sibling block lost when a tool result expanded")
    }

    /// The same detach/re-attach `ReplView.measure()` performs on a whole turn.
    func testCaptureAndRestoreBringBackSelectionAcrossDetach() {
        guard let (view, window, label, _, range) = makeSelectedTurn() else {
            return XCTFail("could not select the paragraph")
        }
        let parent = view.superview!
        let saved = TranscriptSelection.capture(in: view)
        XCTAssertNotNil(saved)
        view.removeFromSuperview()
        XCTAssertNil(label.currentEditor(), "precondition: detaching drops the field editor")
        parent.addSubview(view)
        saved?.restore()

        XCTAssertEqual((label.currentEditor() as? NSTextView)?.selectedRange, range)
        XCTAssertTrue(window.firstResponder === label.currentEditor())
    }

    /// `restore()` re-selects through `selectText(_:)`, which makes a field editor first
    /// responder and can scroll the enclosing scroll view to show it. `ReplView.measure`
    /// runs this for the turn being read on every streamed block, so a reader parked
    /// elsewhere in the transcript must not be moved.
    func testRestoreDoesNotMoveTheEnclosingScrollView() {
        let paragraph = "A paragraph of assistant text that the operator wants to copy."
        let turn = ChatTurn(userInput: "hi", timestamp: Date(),
                            blocks: [.text(paragraph)], isComplete: false)
        let view = ChatTurnView(turn: turn, contentAvailable: true, interaction: TurnInteractionState())
        let window = makeWindow(NSSize(width: 900, height: 300))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
        let doc = FlippedTestView(frame: NSRect(x: 0, y: 0, width: 900, height: 5000))
        scroll.documentView = doc
        window.contentView!.addSubview(scroll)
        view.setIslandWidth(900)
        // The selected turn sits far below the viewport the reader is looking at.
        view.frame = NSRect(x: 0, y: 4000, width: 900, height: view.islandHeight())
        doc.addSubview(view)
        view.layoutSubtreeIfNeeded()
        guard let label = textFields(in: view).first(where: { $0.stringValue == paragraph }) else {
            return XCTFail("no paragraph label")
        }
        label.selectText(nil)
        guard let editor = label.currentEditor() as? NSTextView else { return XCTFail("no field editor") }
        editor.setSelectedRange(NSRange(location: 2, length: 9))

        // The reader is looking at the top of the transcript.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        let before = scroll.contentView.bounds.origin

        let saved = TranscriptSelection.capture(in: view)
        XCTAssertNotNil(saved)
        view.removeFromSuperview()
        doc.addSubview(view)
        saved?.restore()

        XCTAssertEqual(scroll.contentView.bounds.origin, before,
                       "restoring a selection must not scroll the reader away")
        XCTAssertEqual((label.currentEditor() as? NSTextView)?.selectedRange,
                       NSRange(location: 2, length: 9), "the selection itself must still come back")
    }

    func testCaptureIgnoresSelectionElsewhere() {
        guard let (view, window, _, _, _) = makeSelectedTurn() else {
            return XCTFail("could not select the paragraph")
        }
        let otherTurn = ChatTurnView(turn: ChatTurn(userInput: "x", timestamp: Date(), blocks: [], isComplete: true),
                                     contentAvailable: true, interaction: TurnInteractionState())
        window.contentView!.addSubview(otherTurn)
        XCTAssertNil(TranscriptSelection.capture(in: otherTurn))
        XCTAssertNotNil(TranscriptSelection.capture(in: view))
    }

    func testCaptureIsNilWithoutASelection() {
        let turn = ChatTurn(userInput: "hi", timestamp: Date(), blocks: [.text(paragraph)], isComplete: false)
        let view = ChatTurnView(turn: turn, contentAvailable: true, interaction: TurnInteractionState())
        let window = makeWindow()
        window.contentView!.addSubview(view)
        XCTAssertNil(TranscriptSelection.capture(in: view))
    }

    /// `ReplView` isn't compilable here; pin that its detach-to-measure path
    /// goes through the same capture/restore.
    func testReplViewMeasureRestoresSelection() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Nostromo/UI/Views/ReplView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        guard let start = source.range(of: "private func measure(_ view: TurnIsland") else {
            return XCTFail("measure() not found in ReplView.swift")
        }
        let body = String(source[start.lowerBound...].prefix(3500))
        XCTAssertTrue(body.contains("TranscriptSelection.capture"))
        XCTAssertTrue(body.contains(".restore()"))
    }
}

/// A flipped container so test geometry matches the transcript's document view.
private final class FlippedTestView: NSView {
    override var isFlipped: Bool { true }
}
