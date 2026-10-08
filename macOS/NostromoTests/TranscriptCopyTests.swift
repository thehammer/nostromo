import XCTest
import AppKit

// ChatModels.swift and ChatTurnView.swift are compiled directly into this
// logic-test target (no host app). `ReplView` is not, so the focus-stealing
// rule it applies is tested through `TranscriptFocusPolicy`.
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
}

// MARK: - Focus policy

final class TranscriptFocusPolicyTests: XCTestCase {

    private func selectedLabel(in window: NSWindow, text: String) -> (NSTextField, NSTextView)? {
        guard let label = textFields(in: window.contentView!).first(where: { $0.stringValue.contains(text) })
        else { return nil }
        label.selectText(nil)   // creates the field editor even in an unshown test window
        guard let editor = label.currentEditor() as? NSTextView else { return nil }
        return (label, editor)
    }

    func testDoesNotStealFocusWhileTranscriptTextIsSelected() {
        let window = makeWindow()
        let bubble = TextBlockView(text: "select me please")
        bubble.frame = NSRect(x: 0, y: 0, width: 400, height: 60)
        window.contentView!.addSubview(bubble)
        window.contentView!.layoutSubtreeIfNeeded()
        let input = NSTextView(frame: NSRect(x: 0, y: 100, width: 400, height: 30))
        window.contentView!.addSubview(input)

        guard let (_, editor) = selectedLabel(in: window, text: "select me") else {
            return XCTFail("could not focus the paragraph label")
        }
        editor.setSelectedRange(NSRange(location: 0, length: 6))
        XCTAssertFalse(TranscriptFocusPolicy.shouldFocusInput(currentFirstResponder: window.firstResponder,
                                                              inputTextView: input))
    }

    func testFocusesInputWhenTranscriptEditorHasNoSelection() {
        let window = makeWindow()
        let bubble = TextBlockView(text: "select me please")
        bubble.frame = NSRect(x: 0, y: 0, width: 400, height: 60)
        window.contentView!.addSubview(bubble)
        window.contentView!.layoutSubtreeIfNeeded()
        let input = NSTextView(frame: NSRect(x: 0, y: 100, width: 400, height: 30))
        window.contentView!.addSubview(input)

        guard let (_, editor) = selectedLabel(in: window, text: "select me") else {
            return XCTFail("could not focus the paragraph label")
        }
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertTrue(TranscriptFocusPolicy.shouldFocusInput(currentFirstResponder: window.firstResponder,
                                                             inputTextView: input))
    }

    func testFocusesInputForNilWindowAndContentViewResponders() {
        let window = makeWindow()
        let input = NSTextView(frame: .zero)
        XCTAssertTrue(TranscriptFocusPolicy.shouldFocusInput(currentFirstResponder: nil, inputTextView: input))
        XCTAssertTrue(TranscriptFocusPolicy.shouldFocusInput(currentFirstResponder: window, inputTextView: input))
        XCTAssertTrue(TranscriptFocusPolicy.shouldFocusInput(currentFirstResponder: window.contentView, inputTextView: input))
        XCTAssertTrue(TranscriptFocusPolicy.shouldFocusInput(currentFirstResponder: nil, inputTextView: nil))
    }

    func testInputViewItselfWithSelectionStillCountsAsFocusable() {
        let input = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        input.string = "draft message"
        input.setSelectedRange(NSRange(location: 0, length: 5))
        XCTAssertTrue(TranscriptFocusPolicy.shouldFocusInput(currentFirstResponder: input, inputTextView: input))
    }

    func testOtherTextViewWithSelectionBlocksFocus() {
        let other = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        other.string = "some transcript text"
        other.setSelectedRange(NSRange(location: 0, length: 4))
        let input = NSTextView(frame: .zero)
        XCTAssertFalse(TranscriptFocusPolicy.shouldFocusInput(currentFirstResponder: other, inputTextView: input))
    }
}

// MARK: - Selection survival

final class TranscriptSelectionSurvivalTests: XCTestCase {

    func testSelectionSurvivesRelayoutAndAppendedBlocks() {
        let paragraph = "A paragraph of assistant text that the operator wants to copy."
        var turn = ChatTurn(userInput: "hi", timestamp: Date(),
                            blocks: [.text(paragraph)], isComplete: false)
        let view = ChatTurnView(turn: turn, contentAvailable: true, interaction: TurnInteractionState())

        let window = makeWindow(NSSize(width: 900, height: 900))
        window.contentView!.addSubview(view)
        view.setIslandWidth(900)
        view.frame = NSRect(x: 0, y: 0, width: 900, height: view.islandHeight())
        view.layoutSubtreeIfNeeded()

        guard let label = textFields(in: view).first(where: { $0.stringValue == paragraph }) else {
            return XCTFail("paragraph label not found")
        }
        label.selectText(nil)   // creates the field editor even in an unshown test window
        guard let editor = label.currentEditor() as? NSTextView else {
            return XCTFail("label has no field editor")
        }
        let range = NSRange(location: 2, length: 9)
        editor.setSelectedRange(range)

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
}
