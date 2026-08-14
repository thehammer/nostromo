import XCTest
import AppKit

// TurnInteractionStore, AskQuestionView, ToolResultView, AskQuestionData,
// ToolResultData are compiled into this target directly (logic test — no
// host app, no `@testable import`).

// MARK: - Shared view-hierarchy helpers

/// Depth-first search for the first descendant of `type` under `view`,
/// including `view`'s own subviews but not `view` itself. Used instead of
/// asking Cody for internal accessors — the membrane these tests enforce is
/// "what an operator's click and AppKit's own state say", not the view's
/// private layout.
private func firstDescendant<T>(of type: T.Type, in view: NSView) -> T? {
    for sub in view.subviews {
        if let match = sub as? T { return match }
        if let found = firstDescendant(of: type, in: sub) { return found }
    }
    return nil
}

// MARK: - AskQuestionViewTests

/// The serious defect these guard: turn views are destroyed routinely now
/// (virtualizer eviction, every pane-width change) and rebuilt from state that
/// must live outside the view. An answered `AskUserQuestion` card rebuilt
/// without knowing it was answered re-arms itself — one stray click on the
/// rebuilt card then sends a duplicate message into a live agent session.
final class AskQuestionViewTests: XCTestCase {

    private func makeQuestion(
        question: String = "Ship it?",
        options: [AskQuestionData.Option] = [
            AskQuestionData.Option(label: "Yes", description: "merge"),
            AskQuestionData.Option(label: "No", description: "hold"),
        ]
    ) -> AskQuestionData {
        AskQuestionData(question: question, header: "Decision", options: options, multiSelect: false)
    }

    private func optionButtons(in view: NSView) -> [NSButton] {
        view.subviews.compactMap { $0 as? NSButton }.sorted { $0.tag < $1.tag }
    }

    // MARK: 1. A fresh card answers exactly once

    func testFreshCardAnswersExactlyOnceOnFirstClickAndIgnoresEverythingAfter() throws {
        let data = makeQuestion()
        let view = AskQuestionView(data: data, answeredOptionIndex: nil)
        var answers: [(reply: String, optionIndex: Int)] = []
        view.onAnswer = { reply, optionIndex in answers.append((reply, optionIndex)) }

        let buttons = optionButtons(in: view)
        XCTAssertEqual(buttons.count, 2, "one button per option")

        buttons[1].performClick(nil)
        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(answers[0].optionIndex, 1)
        XCTAssertTrue(answers[0].reply.contains(data.options[1].label),
                      "the reply must carry the chosen option's label")

        // Re-clicking the same button, and clicking a different one, must not
        // fire again — a card answers exactly once.
        buttons[1].performClick(nil)
        buttons[0].performClick(nil)
        XCTAssertEqual(answers.count, 1,
                       "an already-answered card must never send a second message")
    }

    // MARK: 2. A restored card does not re-send on construction

    func testRestoredCardDoesNotInvokeOnAnswerAtConstruction() {
        // This is the duplicate-message scenario itself: a card rebuilt after
        // eviction, already knowing it was answered, must not replay that
        // answer into the agent session the instant it exists.
        let data = makeQuestion()
        let view = AskQuestionView(data: data, answeredOptionIndex: 1)
        view.onAnswer = { reply, optionIndex in
            XCTFail("a restored card must never call onAnswer on its own — got (\(reply), \(optionIndex))")
        }
        // Give anything deferred to `DispatchQueue.main` or an animation
        // completion a chance to surface before we call the test passed.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    // MARK: 3. A restored card is inert

    func testRestoredCardIgnoresClicksOnEveryOptionAndReportsDisabled() {
        let data = makeQuestion()
        let view = AskQuestionView(data: data, answeredOptionIndex: 0)
        var fired = false
        view.onAnswer = { _, _ in fired = true }

        let buttons = optionButtons(in: view)
        for button in buttons { button.performClick(nil) }

        XCTAssertFalse(fired, "a restored card must be inert — no click should reach onAnswer")
        for button in buttons {
            XCTAssertFalse(button.isEnabled, "every option button must be disabled once answered")
        }
    }

    // MARK: 4. A restored card looks answered

    func testRestoredCardVisuallyDistinguishesTheChosenOptionFromTheRest() throws {
        let data = makeQuestion()
        let view = AskQuestionView(data: data, answeredOptionIndex: 1)

        let buttons = optionButtons(in: view)
        let chosen = try XCTUnwrap(buttons.first { $0.tag == 1 })
        let others = buttons.filter { $0.tag != 1 }
        XCTAssertFalse(others.isEmpty)

        XCTAssertEqual(chosen.alphaValue, 1.0, "the chosen option must render at full opacity")
        for other in others {
            XCTAssertLessThan(other.alphaValue, 1.0,
                              "a non-chosen option must render dimmed, or a restored card looks unanswered")
        }
    }

    // MARK: 5. Out-of-range restore

    func testOutOfRangeRestoreIndexDoesNotCrashAndStillLeavesTheCardInert() {
        let data = makeQuestion()   // 2 options: valid indices are 0 and 1
        let view = AskQuestionView(data: data, answeredOptionIndex: 99)
        var fired = false
        view.onAnswer = { _, _ in fired = true }

        let buttons = optionButtons(in: view)
        XCTAssertEqual(buttons.count, 2, "construction with a bogus restore index must not lose the options")

        for button in buttons { button.performClick(nil) }
        XCTAssertFalse(fired, "an out-of-range restore must still leave the card inert")
        for button in buttons {
            XCTAssertFalse(button.isEnabled, "an out-of-range restore must still disable every option")
        }
    }
}

// MARK: - ToolResultViewTests

/// The same eviction problem, for the disclosure state of a tool-result row:
/// a pane-width change or a scroll-driven eviction must not silently re-close
/// a card an operator manually expanded, or re-open one they collapsed.
final class ToolResultViewTests: XCTestCase {

    private func disclosureButton(in view: NSView) throws -> NSButton {
        try XCTUnwrap(firstDescendant(of: NSButton.self, in: view),
                     "ToolResultView must have exactly one disclosure NSButton")
    }

    private func contentWrap(in view: NSView) throws -> NSView {
        let stack = try XCTUnwrap(firstDescendant(of: NSStackView.self, in: view),
                                  "ToolResultView must lay out via an NSStackView")
        let wrap = try XCTUnwrap(stack.arrangedSubviews.first { !($0 is NSButton) },
                                 "the stack must contain a non-button content wrapper alongside the disclosure")
        return wrap
    }

    // MARK: 6. startExpanded controls the initial state; init fires nothing

    func testStartExpandedTrueOpensANonErrorResultWithNoInitialCallback() throws {
        let data = ToolResultData(content: "line one\nline two\nline three", isError: false)
        let view = ToolResultView(data: data, contentAvailable: true, startExpanded: true)
        var fired = false
        view.onExpansionChange = { _ in fired = true }
        XCTAssertFalse(fired, "construction must not fire onExpansionChange")

        let button = try disclosureButton(in: view)
        XCTAssertTrue(button.title.hasPrefix("▼"), "startExpanded: true must render the open arrow")
        let wrap = try contentWrap(in: view)
        XCTAssertFalse(wrap.isHidden, "startExpanded: true must show the content")
    }

    func testStartExpandedFalseCollapsesANonErrorResult() throws {
        let data = ToolResultData(content: "line one", isError: false)
        let view = ToolResultView(data: data, contentAvailable: true, startExpanded: false)

        let button = try disclosureButton(in: view)
        XCTAssertTrue(button.title.hasPrefix("▶"), "startExpanded: false must render the closed arrow")
        let wrap = try contentWrap(in: view)
        XCTAssertTrue(wrap.isHidden, "startExpanded: false must hide the content")
    }

    func testAnErrorResultStartsExpandedRegardlessOfStartExpanded() throws {
        // Existing behaviour that must not regress: errors always open, even
        // when the caller says the operator had collapsed it.
        let data = ToolResultData(content: "boom", isError: true)
        let view = ToolResultView(data: data, contentAvailable: true, startExpanded: false)

        let button = try disclosureButton(in: view)
        XCTAssertTrue(button.title.hasPrefix("▼"), "an error result must ignore startExpanded and open")
        let wrap = try contentWrap(in: view)
        XCTAssertFalse(wrap.isHidden)
    }

    // MARK: 7. Toggling fires the new value and flips the arrow

    func testTogglingTheDisclosureFiresTheNewValueAndFlipsTheArrowBothWays() throws {
        let data = ToolResultData(content: "line one\nline two", isError: false)
        let view = ToolResultView(data: data, contentAvailable: true, startExpanded: false)
        let button = try disclosureButton(in: view)
        XCTAssertTrue(button.title.hasPrefix("▶"))

        var observed: [Bool] = []
        view.onExpansionChange = { observed.append($0) }

        button.performClick(nil)
        XCTAssertEqual(observed, [true])
        XCTAssertTrue(button.title.hasPrefix("▼"))

        button.performClick(nil)
        XCTAssertEqual(observed, [true, false])
        XCTAssertTrue(button.title.hasPrefix("▶"))
    }
}

// MARK: - TurnInteractionStoreTests

/// The store that lets `AskQuestionView`/`ToolResultView` be rebuilt honestly:
/// answers and expansion are keyed per turn, so evicting and rebuilding a
/// view can restore exactly the state it had before — and pruning bounds the
/// store itself, so the fix for the duplicate-message bug does not become its
/// own unbounded leak.
final class TurnInteractionStoreTests: XCTestCase {

    func testStateForAnUnknownTurnIsEmpty() {
        let store = TurnInteractionStore()
        XCTAssertTrue(store.state(for: UUID()).isEmpty)
    }

    func testStateIsScopedPerTurnNotGlobal() {
        let store = TurnInteractionStore()
        let turnA = UUID()
        let turnB = UUID()

        store.recordAnswer(turn: turnA, block: 0, option: 1)

        XCTAssertEqual(store.state(for: turnA).answeredOptions[0], 1)
        XCTAssertTrue(store.state(for: turnB).isEmpty,
                      "recording an answer for one turn must not leak into another turn's state")
    }

    func testSetExpandedTracksPerBlockExpansionIndependentlyOfAnswers() {
        let store = TurnInteractionStore()
        let turn = UUID()

        store.setExpanded(turn: turn, block: 2, true)
        XCTAssertTrue(store.state(for: turn).expandedBlocks.contains(2))

        store.setExpanded(turn: turn, block: 2, false)
        XCTAssertFalse(store.state(for: turn).expandedBlocks.contains(2))
    }

    func testPruneDropsTurnsNotInTheKeepSetAndLeavesTheRestIntact() {
        let store = TurnInteractionStore()
        let kept = UUID()
        let evicted = UUID()

        store.recordAnswer(turn: kept, block: 0, option: 0)
        store.setExpanded(turn: kept, block: 1, true)
        store.recordAnswer(turn: evicted, block: 0, option: 0)

        store.prune(keeping: [kept])

        XCTAssertFalse(store.state(for: kept).isEmpty, "prune must not drop turns being kept")
        XCTAssertTrue(store.state(for: evicted).isEmpty,
                      "prune must drop turns that fell out of retention, or this becomes an unbounded leak")
    }

    func testRemoveAllEmptiesTheStore() {
        let store = TurnInteractionStore()
        let turn = UUID()
        store.recordAnswer(turn: turn, block: 0, option: 0)
        store.setExpanded(turn: turn, block: 1, true)

        store.removeAll()

        XCTAssertTrue(store.state(for: turn).isEmpty)
    }
}

// MARK: - TurnInteractionWiringTests

/// A fitness function, not a behavioural test — the same spirit as
/// `ImageDecodePolicyTests`. `ReplView.swift` builds the AppKit call sites
/// that actually thread interaction state through, and it is deliberately
/// not part of this logic-test target (it needs a real window to mean
/// anything). Reading it as text is the only way left to enforce that the fix
/// is actually wired up rather than merely available.
///
/// This is a wiring check: it says the call sites exist and don't hard-code
/// away the fix. It says nothing about runtime behaviour — that's what the
/// rest of this file is for.
final class TurnInteractionWiringTests: XCTestCase {

    func testChatTurnViewIsConstructedWithInteractionState() throws {
        let calls = Self.balancedCalls(startingAt: "ChatTurnView(", in: try Self.replViewSource())
        XCTAssertFalse(calls.isEmpty, "ChatTurnView( construction site not found — did it move or rename?")
        for call in calls {
            XCTAssertTrue(call.contains("interaction:"), """
                ChatTurnView must be constructed with the turn's interaction state, or a view rebuilt \
                after eviction starts blank every time:
                \(call)
                """)
        }
    }

    func testAskQuestionViewIsNeverConstructedWithAHardcodedNilRestoreIndex() throws {
        let calls = Self.balancedCalls(startingAt: "AskQuestionView(", in: try Self.replViewSource())
        XCTAssertFalse(calls.isEmpty, "AskQuestionView( construction site not found — did it move or rename?")
        for call in calls {
            XCTAssertFalse(call.contains("answeredOptionIndex: nil"), """
                a hard-coded nil throws away the answer on every rebuild — the exact duplicate-message bug:
                \(call)
                """)
        }
    }

    func testToolResultViewIsNeverConstructedWithAHardcodedFalseStartExpanded() throws {
        let calls = Self.balancedCalls(startingAt: "ToolResultView(", in: try Self.replViewSource())
        XCTAssertFalse(calls.isEmpty, "ToolResultView( construction site not found — did it move or rename?")
        for call in calls {
            XCTAssertFalse(call.contains("startExpanded: false"), """
                a hard-coded false forgets an operator's manual expand on every rebuild:
                \(call)
                """)
        }
    }

    // MARK: - Helpers

    /// `ReplView.swift` is not compiled into this target, so it has to be read
    /// as text — same idiom as `ImageDecodePolicyTests.sourceRoot`.
    private static func replViewSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)     // …/macOS/NostromoTests/TurnInteractionTests.swift
            .deletingLastPathComponent()                // …/macOS/NostromoTests
            .deletingLastPathComponent()                // …/macOS
            .appendingPathComponent("Nostromo/UI/Views/ReplView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Every call `marker` … `)` in `source`, matching parentheses so a nested
    /// call (e.g. building an argument inline) doesn't truncate the match.
    private static func balancedCalls(startingAt marker: String, in source: String) -> [String] {
        var calls: [String] = []
        var searchStart = source.startIndex
        while let markerRange = source.range(of: marker, range: searchStart..<source.endIndex) {
            var depth = 1   // `marker` already includes the opening "("
            var idx = markerRange.upperBound
            while idx < source.endIndex, depth > 0 {
                if source[idx] == "(" { depth += 1 }
                if source[idx] == ")" { depth -= 1 }
                idx = source.index(after: idx)
            }
            calls.append(String(source[markerRange.lowerBound..<idx]))
            searchStart = idx
        }
        return calls
    }
}
