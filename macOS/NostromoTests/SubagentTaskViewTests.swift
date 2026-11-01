import XCTest
import AppKit
import Combine
import NostromoKit

// BA4: the subagent viewer, the body of an agent task's window (plan acceptance criteria "Subagent
// viewer ..." and "Hostile content").
//
// The viewer reads a focus's transcript through `SubagentTranscriptSource`; here that is a tiny fake
// holding recorded turns, the shape the daemon produces: the Agent call, the subagent's own calls and
// results (carrying the Agent call's id as `parentToolUseId`), the subagent's text blocks (marked in
// `ChatTurn.subagentTextParents`), the main agent's own blocks (which must never appear), a nested
// subagent's blocks (which must not leak in), and the Agent call's result.
//
// What is asserted is what the viewer shows: the prompt, the messages and tool groups in order through
// the transcript's own `ChatTurnView`, new blocks appearing live without a rebuild, the final result
// once the task has ended, the honest message when the conversation is gone, folds that belong to the
// viewer alone, and hostile text drawn harmless. The view lives in a sized window, so it lays out.
//
// No wall clock, no real pasteboard, no real UserDefaults, no ~/.nostromo, no daemon.

private typealias F = FoldFixtures

// MARK: - Fakes and fixtures

private final class FakeSubagentSource: SubagentTranscriptSource {
    var turns: [ChatTurn]
    let changes = PassthroughSubject<TurnChange, Never>()

    init(turns: [ChatTurn]) {
        self.turns = turns
    }
}

private enum SubagentFixtures {
    static let agentId = "toolu_agent"
    static let otherAgentId = "toolu_other"
    static let prompt = "Find every caller of the old API and report them."
    static let finalResult = "Two callers: Alpha.swift and Beta.swift."

    static func agentInput(prompt: String = prompt) -> String {
        F.jsonInput(["prompt": prompt, "description": "Find callers", "subagent_type": "explore"])
    }

    /// One turn the way the daemon records an Agent call that ran to the end.
    static func turn(complete: Bool = true, withResult: Bool = true, input: String? = nil) -> ChatTurn {
        var blocks: [TurnBlock] = [
            .text("MAIN: I will hand this to a subagent."),                                                    // 0
            F.call("Agent", id: agentId, summary: "Find callers", full: input ?? agentInput()),                // 1
            .text("SUB: Looking at the call sites."),                                                          // 2
            F.call("Read", id: "s1", summary: "Read Alpha.swift", parent: agentId),                            // 3
            F.result("alpha contents", id: "s1", parent: agentId),                                             // 4
            F.call("Grep", id: "s2", summary: "Grep oldApi", parent: agentId),                                 // 5
            F.result("2 matches", id: "s2", parent: agentId),                                                  // 6
            .text("SUB: Found two callers."),                                                                  // 7
            F.call("Read", id: "n1", summary: "Read nested", parent: otherAgentId),                            // 8: another subagent's
            F.result("nested out", id: "n1", parent: otherAgentId),                                            // 9
            .text("OTHER: another subagent's note."),                                                          // 10
            F.call("Bash", id: "u1", summary: "echo unknown owner", parent: "?"),                              // 11: owner unknown
        ]
        if withResult { blocks.append(F.result(finalResult, id: agentId)) }                                    // the Agent's result
        blocks.append(.text("MAIN: all done."))
        return F.turn(blocks, complete: complete, user: "delegate the search",
                      textParents: [2: agentId, 7: agentId, 10: otherAgentId])
    }

    static func describe(_ block: TurnBlock) -> String {
        switch block {
        case .text(let text): return "text:\(text)"
        case .toolCall(let call): return "call:\(call.toolName):\(call.toolUseId ?? "-"):parent=\(call.parentToolUseId ?? "nil")"
        case .toolResult(let result): return "result:\(result.content):parent=\(result.parentToolUseId ?? "nil")"
        default: return "other"
        }
    }

    static let expectedBlocks = [
        "text:SUB: Looking at the call sites.",
        "call:Read:s1:parent=nil",
        "result:alpha contents:parent=nil",
        "call:Grep:s2:parent=nil",
        "result:2 matches:parent=nil",
        "text:SUB: Found two callers.",
    ]
}

private typealias Fx = SubagentFixtures

// MARK: - Tests

final class SubagentTaskViewTests: XCTestCase {

    private var windows: [RigWindow] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        windows = []
    }

    override func tearDown() {
        windows = []
        super.tearDown()
    }

    // MARK: Helpers

    private struct Rig {
        let window: RigWindow
        let view: SubagentTaskView
        let source: FakeSubagentSource?

        func settle() {
            window.contentView?.layoutSubtreeIfNeeded()
            view.turnView?.layoutSubtreeIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
        }

        func show(_ content: TaskWindowContent) {
            view.apply(content: content)
            settle()
        }

        func send(_ change: TurnChange) {
            source?.changes.send(change)
            settle()
        }
    }

    private func makeRig(turns: [ChatTurn], hasSource: Bool = true) -> Rig {
        let source = hasSource ? FakeSubagentSource(turns: turns) : nil
        return makeRig(source: source)
    }

    private func makeRig(source: FakeSubagentSource?) -> Rig {
        let window = makeRigWindow(self, size: NSSize(width: 700, height: 700))
        windows.append(window)
        let view = SubagentTaskView(focusTag: "claudia", taskId: "task-1", source: source)
        view.frame = window.contentView!.bounds
        view.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(view)
        window.contentView?.layoutSubtreeIfNeeded()
        return Rig(window: window, view: view, source: source)
    }

    private func content(status: TaskStatusWire = .running, prompt: String? = nil, completion: String? = nil,
                         toolUseId: String? = Fx.agentId) -> TaskWindowContent {
        let meta = TaskMetaWire(id: "task-1", kind: .agent, description: "Find callers", subagentType: "explore",
                                toolUseId: toolUseId, status: status, startedAtMs: 1_000,
                                endedAtMs: status.isTerminal ? 5_000 : nil)
        let detail: SessionTaskDetailWire? = (prompt != nil || completion != nil)
            ? SessionTaskDetailWire(tag: "claudia", taskId: "task-1", completionSummary: completion, prompt: prompt)
            : nil
        return TaskWindowContent.make(tag: "claudia", focusName: "Claudia", meta: meta, row: nil, detail: detail, nowMs: 6_000)
    }

    private func groupViews(in turnView: ChatTurnView) -> [ToolGroupView] {
        rigAllSubviews(of: turnView).compactMap { $0 as? ToolGroupView }
    }

    /// Distance of `view`'s top edge from the top of `root` (smaller: nearer the top).
    private func top(of view: NSView, in root: NSView) -> CGFloat {
        let rect = root.convert(view.bounds, from: view)
        return root.isFlipped ? rect.minY : -rect.maxY
    }

    private func textView(containing needle: String, in root: NSView) -> NSView? {
        rigAllSubviews(of: root).first { sub in
            if let field = sub as? NSTextField { return field.stringValue.contains(needle) || field.attributedStringValue.string.contains(needle) }
            if let text = sub as? NSTextView { return text.string.contains(needle) }
            return false
        }
    }

    private func texts(in root: NSView) -> String {
        FocusFixtures.texts(in: root).joined(separator: "\n")
    }

    /// The scroll area's label that shows `text`, if any (the header above it is not looked in).
    private func conversationLabel(showing text: String, in view: SubagentTaskView) -> NSTextField? {
        rigAllSubviews(of: view.scrollView).compactMap { $0 as? NSTextField }.first { !$0.isHidden && $0.stringValue == text }
    }

    private func assertNoHostileScalars(_ text: String?, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let hostile: [UInt32] = [0x1B, 0x07, 0x202E, 0x202C, 0x200B, 0x2066, 0x2069]
        for scalar in (text ?? "").unicodeScalars where hostile.contains(scalar.value) {
            XCTFail("\(what) still holds U+\(String(scalar.value, radix: 16, uppercase: true))", file: file, line: line)
        }
    }

    // MARK: Collecting the subagent's part of a transcript

    func testCollectGathersTheSubagentsTextCallsAndResultsInOrderAndNothingElse() {
        let found = SubagentConversation.collect(toolUseId: Fx.agentId, from: [Fx.turn()])

        XCTAssertEqual(found.blocks.map(Fx.describe), Fx.expectedBlocks)
        XCTAssertTrue(found.agentCallFound)
    }

    func testCollectLeavesOutTheMainAgentsOwnBlocksAnotherSubagentsAndUnownedOnes() {
        let found = SubagentConversation.collect(toolUseId: Fx.agentId, from: [Fx.turn()])
        let all = found.blocks.map(Fx.describe).joined(separator: "\n")

        XCTAssertFalse(all.contains("MAIN:"), "the main agent's prose is not the subagent's")
        XCTAssertFalse(all.contains("OTHER:"), "another subagent's prose does not leak in")
        XCTAssertFalse(all.contains("nested"), "nor does what another call's children did")
        XCTAssertFalse(all.contains("echo unknown owner"), "a call whose owner is unknown belongs to nobody here")
        XCTAssertFalse(all.contains(Fx.finalResult), "the Agent call's own result is the result, not a block")
    }

    func testCollectDropsTheParentIdSoTheCopiesReadAsAnOrdinaryTurn() {
        let found = SubagentConversation.collect(toolUseId: Fx.agentId, from: [Fx.turn()])

        for block in found.blocks {
            switch block {
            case .toolCall(let call): XCTAssertNil(call.parentToolUseId)
            case .toolResult(let result): XCTAssertNil(result.parentToolUseId)
            default: break
            }
        }
    }

    func testCollectReadsThePromptAndTheResultFromTheAgentCall() {
        let found = SubagentConversation.collect(toolUseId: Fx.agentId, from: [Fx.turn()])

        XCTAssertEqual(found.callPrompt, Fx.prompt)
        XCTAssertEqual(found.callResult, Fx.finalResult)
    }

    func testCollectFindsNothingWhenTheAgentCallIsNotInTheTranscript() {
        let found = SubagentConversation.collect(toolUseId: "toolu_missing", from: [Fx.turn()])

        XCTAssertFalse(found.agentCallFound)
        XCTAssertTrue(found.blocks.isEmpty)
        XCTAssertNil(found.callPrompt)
        XCTAssertNil(found.callResult)
        XCTAssertTrue(SubagentConversation.collect(toolUseId: Fx.agentId, from: []).blocks.isEmpty)
    }

    func testCollectGathersAcrossTurnsInOrder() {
        let first = F.turn([F.call("Agent", id: Fx.agentId, summary: "Find callers", full: Fx.agentInput()),
                            .text("SUB: first part"), F.call("Read", id: "s1", summary: "Read a", parent: Fx.agentId)],
                           complete: true, user: "one", textParents: [1: Fx.agentId])
        let second = F.turn([F.result("a contents", id: "s1", parent: Fx.agentId), .text("SUB: second part"),
                             F.result("all found", id: Fx.agentId)],
                            complete: true, user: "two", raw: "2026-10-13T00:01:00.000Z", textParents: [1: Fx.agentId])

        let found = SubagentConversation.collect(toolUseId: Fx.agentId, from: [first, second])

        XCTAssertEqual(found.blocks.map(Fx.describe), ["text:SUB: first part", "call:Read:s1:parent=nil",
                                                       "result:a contents:parent=nil", "text:SUB: second part"])
        XCTAssertEqual(found.callResult, "all found")
    }

    func testCollectSkipsTurnsWhoseTextWentCold() {
        var cold = Fx.turn()
        cold.truncatedLengths = ChatTurn.TruncatedLengths(userInput: 20, blocks: Array(repeating: 10, count: cold.blocks.count))

        let found = SubagentConversation.collect(toolUseId: Fx.agentId, from: [cold])

        XCTAssertTrue(found.blocks.isEmpty, "a turn kept only as a skeleton has no text to show")
        XCTAssertFalse(found.agentCallFound)
    }

    func testThePromptIsTheAgentCallsPromptFieldAndNothingWhenThereIsNone() {
        XCTAssertEqual(SubagentConversation.prompt(inputFull: Fx.agentInput(prompt: "do it")), "do it")
        XCTAssertNil(SubagentConversation.prompt(inputFull: Fx.agentInput(prompt: "")))
        XCTAssertNil(SubagentConversation.prompt(inputFull: F.jsonInput(["description": "no prompt here"])))
        XCTAssertNil(SubagentConversation.prompt(inputFull: "not json at all"))
    }

    // MARK: The prompt

    func testTheViewShowsThePromptAsTheMessageTheSubagentWasGiven() throws {
        let rig = makeRig(turns: [Fx.turn()])

        rig.show(content())

        XCTAssertEqual(rig.view.promptText, Fx.prompt)
        let turnView = try XCTUnwrap(rig.view.turnView)
        XCTAssertEqual(turnView.userBubbleContent?.text, Fx.prompt)
    }

    func testThePromptFromTheTaskDetailWinsOverTheCalls() throws {
        let rig = makeRig(turns: [Fx.turn()])

        rig.show(content(prompt: "The daemon's own copy of the prompt."))

        XCTAssertEqual(rig.view.promptText, "The daemon's own copy of the prompt.")
        XCTAssertEqual(try XCTUnwrap(rig.view.turnView).userBubbleContent?.text, "The daemon's own copy of the prompt.")
    }

    func testWithNoPromptAnywhereTheViewSaysSoInsteadOfLeavingItBlank() throws {
        let rig = makeRig(turns: [Fx.turn(input: "not json")])

        rig.show(content())

        XCTAssertNil(rig.view.promptText)
        XCTAssertEqual(try XCTUnwrap(rig.view.turnView).userBubbleContent?.text, SubagentTaskView.missingPrompt)
    }

    // MARK: Messages and tool groups

    func testTheSubagentsMessagesAndToolGroupsRenderInOrderUnderThePrompt() throws {
        let rig = makeRig(turns: [Fx.turn()])

        rig.show(content())

        XCTAssertEqual(rig.view.conversationBlockCount, 6)
        let turnView = try XCTUnwrap(rig.view.turnView)
        let bubble = try XCTUnwrap(FocusFixtures.all(UserBubbleView.self, in: turnView).first, "the prompt is a bubble")
        let opening = try XCTUnwrap(textView(containing: "Looking at the call sites", in: turnView), "the first message is drawn")
        let group = try XCTUnwrap(groupViews(in: turnView).first, "the tool calls are a group")
        let closing = try XCTUnwrap(textView(containing: "Found two callers", in: turnView), "the last message is drawn")
        XCTAssertLessThan(top(of: bubble, in: turnView), top(of: opening, in: turnView), "the prompt comes first")
        XCTAssertLessThan(top(of: opening, in: turnView), top(of: group, in: turnView), "then the message, then its calls")
        XCTAssertLessThan(top(of: group, in: turnView), top(of: closing, in: turnView), "then the closing message")
        XCTAssertTrue(turnView.groupView(forKey: group.group.key) === group)
    }

    func testEveryToolGroupStartsOpen() throws {
        let rig = makeRig(turns: [Fx.turn()])

        rig.show(content())

        let groups = groupViews(in: try XCTUnwrap(rig.view.turnView))
        XCTAssertFalse(groups.isEmpty)
        for group in groups { XCTAssertTrue(group.isExpanded, "the viewer shows all activity") }
    }

    func testTheMainAgentsOwnBlocksAndOtherSubagentsNeverAppear() throws {
        let rig = makeRig(turns: [Fx.turn()])

        rig.show(content())

        let drawn = texts(in: try XCTUnwrap(rig.view.turnView))
        XCTAssertFalse(drawn.contains("MAIN:"))
        XCTAssertFalse(drawn.contains("OTHER:"))
        XCTAssertFalse(drawn.contains("nested"))
        XCTAssertFalse(drawn.contains("unknown owner"))
    }

    // MARK: Live

    func testANewSubagentBlockAppearsWithoutReopeningTheWindow() throws {
        let rig = makeRig(turns: [Fx.turn(complete: false, withResult: false)])
        rig.show(content())
        XCTAssertEqual(rig.view.conversationBlockCount, 6, "precondition")

        var turn = rig.source!.turns[0]
        turn.blocks.append(.text("SUB: One more thing I noticed."))
        turn.subagentTextParents[turn.blocks.count - 1] = Fx.agentId
        rig.source!.turns[0] = turn
        rig.send(.updatedBlocks(index: 0, addedCount: 1))

        XCTAssertEqual(rig.view.conversationBlockCount, 7)
        XCTAssertTrue(FocusFixtures.contains("One more thing I noticed", in: try XCTUnwrap(rig.view.turnView)))
    }

    func testBlocksThatOnlyGrewUpdateTheTurnViewInPlace() throws {
        let rig = makeRig(turns: [Fx.turn(complete: false, withResult: false)])
        rig.show(content())
        let before = try XCTUnwrap(rig.view.turnView)

        var turn = rig.source!.turns[0]
        turn.blocks.append(.text("SUB: A late addition."))
        turn.subagentTextParents[turn.blocks.count - 1] = Fx.agentId
        rig.source!.turns[0] = turn
        rig.send(.updatedBlocks(index: 0, addedCount: 1))

        XCTAssertTrue(rig.view.turnView === before, "an append does not rebuild what is on screen")
    }

    func testAMessageStreamingInPlaceGrowsWithoutARebuild() throws {
        let rig = makeRig(turns: [Fx.turn(complete: false, withResult: false)])
        rig.show(content())
        let before = try XCTUnwrap(rig.view.turnView)

        var turn = rig.source!.turns[0]
        turn.blocks[7] = .text("SUB: Found two callers. And a third in a test.")
        rig.source!.turns[0] = turn
        rig.send(.updatedBlocks(index: 0, addedCount: 0))

        XCTAssertTrue(rig.view.turnView === before)
        XCTAssertTrue(FocusFixtures.contains("And a third in a test", in: before))
        XCTAssertEqual(rig.view.conversationBlockCount, 6)
    }

    func testAChangeThatIsNotTheSubagentsLeavesTheConversationAlone() throws {
        let rig = makeRig(turns: [Fx.turn(complete: false, withResult: false)])
        rig.show(content())
        let before = try XCTUnwrap(rig.view.turnView)

        var turn = rig.source!.turns[0]
        turn.blocks.append(.text("MAIN: a new remark from the main agent."))
        rig.source!.turns[0] = turn
        rig.send(.updatedBlocks(index: 0, addedCount: 1))

        XCTAssertEqual(rig.view.conversationBlockCount, 6)
        XCTAssertTrue(rig.view.turnView === before)
        XCTAssertFalse(texts(in: before).contains("a new remark"))
    }

    // MARK: The result

    func testTheResultShowsOnlyOnceTheTaskHasEnded() throws {
        let rig = makeRig(turns: [Fx.turn()])

        rig.show(content(status: .running))
        XCTAssertNil(rig.view.resultText, "a running task has no result yet, even if the transcript already holds one")

        rig.show(content(status: .completed))
        XCTAssertEqual(rig.view.resultText, Fx.finalResult)
    }

    func testTheResultSitsBelowTheConversation() throws {
        let rig = makeRig(turns: [Fx.turn()])

        rig.show(content(status: .completed))

        let turnView = try XCTUnwrap(rig.view.turnView)
        let label = try XCTUnwrap(conversationLabel(showing: Fx.finalResult, in: rig.view), "the result is drawn")
        XCTAssertGreaterThanOrEqual(label.frame.minY, turnView.frame.maxY - 1, "at the bottom, under the last message")
    }

    func testTheCallsResultIsPreferredToTheCompletionSummary() {
        let rig = makeRig(turns: [Fx.turn()])

        rig.show(content(status: .completed, completion: "The daemon's one-line summary"))

        XCTAssertEqual(rig.view.resultText, Fx.finalResult)
    }

    func testWithoutTheCallsResultTheCompletionSummaryIsTheResult() {
        let rig = makeRig(turns: [Fx.turn(withResult: false)])

        rig.show(content(status: .completed, completion: "The daemon's one-line summary"))

        XCTAssertEqual(rig.view.resultText, "The daemon's one-line summary")
    }

    func testAnEndedTaskWithNoResultAnywhereShowsNone() {
        let rig = makeRig(turns: [Fx.turn(withResult: false)])

        rig.show(content(status: .completed))

        XCTAssertNil(rig.view.resultText)
    }

    func testTheResultAppearsWhenTheTaskEndsWithoutReopening() throws {
        let rig = makeRig(turns: [Fx.turn()])
        rig.show(content(status: .running))
        let before = try XCTUnwrap(rig.view.turnView)

        rig.show(content(status: .completed))

        XCTAssertEqual(rig.view.resultText, Fx.finalResult)
        XCTAssertTrue(rig.view.turnView === before, "the conversation stays as it was")
    }

    // MARK: When there is no conversation

    func testWithNoTranscriptAtAllItSaysTheConversationIsUnavailableWithThePromptAndResultItKnows() {
        let rig = makeRig(turns: [])

        rig.show(content(status: .completed, prompt: "What the daemon remembers of the prompt", completion: "How it ended"))

        XCTAssertEqual(rig.view.conversationMessage, SubagentTaskView.unavailableMessage)
        XCTAssertNil(rig.view.turnView, "no empty conversation")
        XCTAssertEqual(rig.view.promptText, "What the daemon remembers of the prompt")
        XCTAssertEqual(rig.view.resultText, "How it ended")
    }

    func testWhenTheTurnsWentColdItSaysTheConversationIsUnavailable() {
        var cold = Fx.turn()
        cold.truncatedLengths = ChatTurn.TruncatedLengths(userInput: 20, blocks: Array(repeating: 10, count: cold.blocks.count))
        let rig = makeRig(turns: [cold])

        rig.show(content(status: .completed, prompt: "Prompt from the daemon", completion: "Summary from the daemon"))

        XCTAssertEqual(rig.view.conversationMessage, SubagentTaskView.unavailableMessage)
        XCTAssertNil(rig.view.turnView)
        XCTAssertEqual(rig.view.promptText, "Prompt from the daemon")
        XCTAssertEqual(rig.view.resultText, "Summary from the daemon")
    }

    func testWithNoSourceAtAllItSaysTheConversationIsUnavailable() {
        let rig = makeRig(turns: [], hasSource: false)

        rig.show(content(prompt: "Prompt from the daemon"))

        XCTAssertEqual(rig.view.conversationMessage, SubagentTaskView.unavailableMessage)
        XCTAssertEqual(rig.view.promptText, "Prompt from the daemon")
    }

    func testATaskWithoutAnAgentCallIdSaysTheConversationIsUnavailable() {
        let rig = makeRig(turns: [Fx.turn()])

        rig.show(content(toolUseId: nil))

        XCTAssertEqual(rig.view.conversationMessage, SubagentTaskView.unavailableMessage)
        XCTAssertNil(rig.view.turnView)
    }

    func testARunningTaskWhoseCallHasNoBlocksYetSaysItHasNotSaidAnythingYet() {
        let justStarted = F.turn([F.call("Agent", id: Fx.agentId, summary: "Find callers", full: Fx.agentInput())],
                                 complete: false, user: "delegate the search")
        let rig = makeRig(turns: [justStarted])

        rig.show(content(status: .running))

        XCTAssertEqual(rig.view.conversationMessage, SubagentTaskView.waitingMessage)
        XCTAssertNil(rig.view.turnView)
        XCTAssertEqual(rig.view.promptText, Fx.prompt, "the prompt is known from the call")
    }

    func testAnEndedTaskWhoseCallHasNoBlocksIsUnavailableNotWaiting() {
        let silent = F.turn([F.call("Agent", id: Fx.agentId, summary: "Find callers", full: Fx.agentInput()),
                             F.result("It did nothing.", id: Fx.agentId)], complete: true, user: "delegate the search")
        let rig = makeRig(turns: [silent])

        rig.show(content(status: .completed))

        XCTAssertEqual(rig.view.conversationMessage, SubagentTaskView.unavailableMessage)
        XCTAssertEqual(rig.view.resultText, "It did nothing.")
    }

    func testTheWaitingMessageGoesWhenTheFirstBlockArrives() throws {
        let justStarted = F.turn([F.call("Agent", id: Fx.agentId, summary: "Find callers", full: Fx.agentInput())],
                                 complete: false, user: "delegate the search")
        let rig = makeRig(turns: [justStarted])
        rig.show(content(status: .running))
        XCTAssertEqual(rig.view.conversationMessage, SubagentTaskView.waitingMessage, "precondition")

        var turn = rig.source!.turns[0]
        turn.blocks.append(.text("SUB: Starting with the call sites."))
        turn.subagentTextParents[turn.blocks.count - 1] = Fx.agentId
        rig.source!.turns[0] = turn
        rig.send(.updatedBlocks(index: 0, addedCount: 1))

        XCTAssertNil(rig.view.conversationMessage, "the conversation replaces the message")
        XCTAssertNotNil(rig.view.turnView)
        XCTAssertEqual(rig.view.conversationBlockCount, 1)
    }

    func testTheConversationReturnsToTheMessageWhenTheTranscriptIsCleared() {
        let rig = makeRig(turns: [Fx.turn()])
        rig.show(content(status: .completed))
        XCTAssertNotNil(rig.view.turnView, "precondition")

        rig.source!.turns = []
        rig.send(.cleared)

        XCTAssertNil(rig.view.turnView)
        XCTAssertEqual(rig.view.conversationMessage, SubagentTaskView.unavailableMessage)
    }

    // MARK: Folds belong to the viewer

    func testTogglingGroupsInTheViewerWritesNothingToTheMainTranscriptsFoldStore() throws {
        // The store the main transcript folds through (`TranscriptFoldStore.shared`); read only here,
        // its mutations are published at once and its file write follows a debounce, so a change count
        // and a write count that did not move say it received nothing. A second store on a private
        // temp file stands in for another transcript's: nothing reaches it either.
        let shared = TranscriptFoldStore.shared
        let sharedWrites = shared.writeCount
        var sharedEvents = 0
        let sharedSub = shared.changes.sink { _ in sharedEvents += 1 }

        let suite = "BA4SV-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BA4SV-\(UUID().uuidString)")
        let own = TranscriptFoldStore(fileURL: dir.appendingPathComponent("folds.json"), defaults: defaults,
                                      scheduler: WorkScheduler { _, _ in return {} })
        var ownEvents = 0
        let ownSub = own.changes.sink { _ in ownEvents += 1 }
        addTeardownBlock {
            sharedSub.cancel()
            ownSub.cancel()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: dir)
        }

        let rig = makeRig(turns: [Fx.turn()])
        rig.show(content())
        let group = try XCTUnwrap(groupViews(in: try XCTUnwrap(rig.view.turnView)).first)
        XCTAssertTrue(group.isExpanded, "precondition")

        group.row.toggle()
        rig.settle()
        XCTAssertFalse(group.isExpanded, "precondition: the toggle took effect in the viewer")
        group.row.toggle()
        rig.settle()
        XCTAssertTrue(group.isExpanded)

        XCTAssertEqual(sharedEvents, 0, "the main transcript's fold store heard nothing")
        XCTAssertEqual(shared.writeCount, sharedWrites, "and wrote nothing")
        XCTAssertEqual(ownEvents, 0)
        XCTAssertEqual(own.writeCount, 0)
    }

    func testAFoldTheOperatorSetSurvivesNewBlocksAndARebuild() throws {
        let rig = makeRig(turns: [Fx.turn(complete: false, withResult: false)])
        rig.show(content())
        let first = try XCTUnwrap(rig.view.turnView)
        let group = try XCTUnwrap(groupViews(in: first).first)
        let key = group.group.key
        group.row.toggle()
        rig.settle()
        XCTAssertFalse(group.isExpanded, "precondition: the operator closed the group")

        // New blocks: the view updates in place and the group stays closed.
        var turn = rig.source!.turns[0]
        turn.blocks.append(.text("SUB: Something new."))
        turn.subagentTextParents[turn.blocks.count - 1] = Fx.agentId
        rig.source!.turns[0] = turn
        rig.send(.updatedBlocks(index: 0, addedCount: 1))
        XCTAssertTrue(rig.view.turnView === first, "precondition: an append is an in-place update")
        XCTAssertEqual(first.groupView(forKey: key)?.isExpanded, false, "a refresh keeps the fold")

        // A different prompt rebuilds the turn view from scratch: the fold is still the operator's.
        rig.show(content(prompt: "A different prompt for the same subagent."))
        let rebuilt = try XCTUnwrap(rig.view.turnView)
        XCTAssertFalse(rebuilt === first, "precondition: the view was rebuilt")
        XCTAssertEqual(rebuilt.groupView(forKey: key)?.isExpanded, false, "a rebuild keeps the fold too")
    }

    func testFoldsAreKeptPerViewer() throws {
        let source = FakeSubagentSource(turns: [Fx.turn()])
        let one = makeRig(source: source)
        let two = makeRig(source: source)
        one.show(content())
        two.show(content())
        let groupOne = try XCTUnwrap(groupViews(in: try XCTUnwrap(one.view.turnView)).first)

        groupOne.row.toggle()
        one.settle()

        XCTAssertFalse(groupOne.isExpanded)
        let groupTwo = try XCTUnwrap(groupViews(in: try XCTUnwrap(two.view.turnView)).first)
        XCTAssertTrue(groupTwo.isExpanded, "another window on the same subagent keeps its own folds")
    }

    // MARK: Hostile content

    private static let hostile = "visible-start \u{1B}[31mred\u{1B}[0m \u{202E}evil\u{202C} zero\u{200B}width "
        + "\u{2066}iso\u{2069} \u{1B}]0;fake title\u{07} visible-end"

    func testAHostilePromptFromTheAgentCallIsDrawnHarmless() throws {
        let long = Self.hostile + String(repeating: "A", count: 10_240)
        let rig = makeRig(turns: [Fx.turn(input: Fx.agentInput(prompt: long))])

        rig.show(content())

        assertNoHostileScalars(rig.view.promptText, "the prompt")
        XCTAssertTrue(rig.view.promptText?.contains("visible-start") ?? false, "the readable part is kept")
        XCTAssertTrue(rig.view.promptText?.contains("visible-end") ?? false)
        XCTAssertLessThanOrEqual(rig.view.promptText?.count ?? 0, SubagentConversation.textLimit)
        assertNoHostileScalars(try XCTUnwrap(rig.view.turnView).userBubbleContent?.text, "the prompt bubble")
    }

    func testAHostilePromptFromTheTaskDetailIsDrawnHarmless() throws {
        let rig = makeRig(turns: [Fx.turn()])

        rig.show(content(prompt: Self.hostile))

        assertNoHostileScalars(rig.view.promptText, "the prompt")
        XCTAssertTrue(rig.view.promptText?.contains("visible-start") ?? false)
    }

    func testAnEnormousPromptIsCutToTheViewersLimit() {
        let huge = String(repeating: "word ", count: 20_000)
        let rig = makeRig(turns: [Fx.turn(input: Fx.agentInput(prompt: huge))])

        rig.show(content())

        XCTAssertLessThanOrEqual(rig.view.promptText?.count ?? 0, SubagentConversation.textLimit)
        XCTAssertGreaterThan(rig.view.promptText?.count ?? 0, 1_000, "it is cut, not dropped")
    }

    func testAHostileResultIsDrawnHarmless() {
        var turn = Fx.turn(withResult: false)
        turn.blocks.append(F.result(Self.hostile + String(repeating: "B", count: 10_240), id: Fx.agentId))
        let rig = makeRig(turns: [turn])

        rig.show(content(status: .completed))

        assertNoHostileScalars(rig.view.resultText, "the result")
        XCTAssertTrue(rig.view.resultText?.contains("visible-start") ?? false)
        XCTAssertLessThanOrEqual(rig.view.resultText?.count ?? 0, SubagentConversation.textLimit)
    }

    func testAHostileCompletionSummaryIsDrawnHarmless() {
        let rig = makeRig(turns: [Fx.turn(withResult: false)])

        rig.show(content(status: .completed, completion: Self.hostile))

        assertNoHostileScalars(rig.view.resultText, "the completion summary")
        XCTAssertTrue(rig.view.resultText?.contains("visible-end") ?? false)
    }
}
