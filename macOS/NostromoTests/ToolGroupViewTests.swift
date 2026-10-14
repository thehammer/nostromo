import XCTest
import AppKit
import NostromoKit

// TF2 (transcript tool folds): the Mac view layer.
//
// `ChatTurnView`, `ToolGroupView`, `ToolGroupRowView`, `AgentActivityView`, `ToolCallView`,
// `ToolResultView` and `TurnPayloadStore` are compiled into this logic-test bundle directly (no
// host app). `ReplView` is not, so the transcript is rebuilt the way `ProseSelectionTests` does:
// `makeTranscriptRig` / `RigWindow` / `AppControlMouse`.
//
// Everything is stated from outside: the views AppKit holds, the strings they show, the heights
// they report, the callbacks they fire, the text on a private pasteboard. No wall clock.

private typealias F = FoldFixtures

// MARK: - Helpers

private let paneWidth: CGFloat = 900

private func makeTurnView(_ turn: ChatTurn, interaction: TurnInteractionState = TurnInteractionState(),
                          folds: FoldResolver? = nil, contentAvailable: Bool = true) -> ChatTurnView {
    let view = ChatTurnView(turn: turn, contentAvailable: contentAvailable, interaction: interaction, folds: folds)
    view.setIslandWidth(paneWidth)
    return view
}

private func groupViews(in view: NSView) -> [ToolGroupView] {
    rigAllSubviews(of: view).compactMap { $0 as? ToolGroupView }
}

private func typeName(_ view: NSView) -> String { String(describing: type(of: view)) }

/// The turn's direct column views (everything but the user bubble), by class name.
private func columnKinds(_ turn: ChatTurnView) -> [String] {
    turn.subviews.filter { !($0 is UserBubbleView) }.map(typeName)
}

private func expanded(_ keys: String...) -> TurnInteractionState {
    var state = TurnInteractionState()
    for key in keys { state.groupStates[key] = true }
    return state
}

private func disclosure(of view: NSView) -> NSButton? {
    rigAllSubviews(of: view).compactMap { $0 as? NSButton }.first
}

private func isOpenArrow(_ button: NSButton) -> Bool { button.title.hasPrefix("▼") }

private func textFields(in view: NSView) -> [NSTextField] {
    rigAllSubviews(of: view).compactMap { $0 as? NSTextField }
}

private func memberKinds(_ group: ToolGroupView) -> [String] {
    group.memberViews.map { view in
        switch view {
        case is ToolCallView:      return "call"
        case is ToolResultView:    return "result"
        case is AgentActivityView: return "agent"
        default:                   return typeName(view)
        }
    }
}

private func keyEvent(_ keyCode: UInt16, _ characters: String, in window: NSWindow,
                      flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                     windowNumber: window.windowNumber, context: nil, characters: characters,
                     charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
}

private func arrow(_ function: Int) -> String { String(UnicodeScalar(UInt32(function))!) }

private enum Key {
    static let space: UInt16 = 49, `return`: UInt16 = 36
    static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
}

// MARK: - A turn with tool calls

final class ToolGroupViewTests: XCTestCase {

    // MARK: collapsed

    func testACollapsedRunOfCallsIsOneRowBetweenTheProse() {
        let turn = F.turn([.text("before")] + F.run(4) + [.text("after")])
        let view = makeTurnView(turn)
        XCTAssertEqual(view.subviews.map(typeName), ["UserBubbleView", "TextBlockView", "ToolGroupView", "TextBlockView"])
    }

    func testACollapsedGroupBuildsNoCallOrResultViewAnywhere() {
        let turn = F.turn([.text("before")] + F.run(4) + [.text("after")])
        let view = makeTurnView(turn)
        let all = rigAllSubviews(of: view)
        XCTAssertFalse(all.contains { $0 is ToolCallView }, "no call header while collapsed")
        XCTAssertFalse(all.contains { $0 is ToolResultView }, "no result row while collapsed")
        XCTAssertEqual(groupViews(in: view).first?.memberViews.count, 0)
    }

    func testACollapsedGroupsRowShowsTheSummary() throws {
        let turn = F.turn([.text("before")] + F.run(4) + [.text("after")])
        let group = F.groups(of: turn)[0]
        let view = makeTurnView(turn)
        let row = try XCTUnwrap(groupViews(in: view).first?.row)
        XCTAssertEqual(row.summaryField.stringValue, ToolGroupSummary.summary(for: group))
        XCTAssertEqual(row.summaryField.stringValue, "Ran 4 commands")
    }

    func testAGroupViewKnowsItsGroupAndItsKey() throws {
        let turn = F.turn(F.run(2, prefix: "toolu_"))
        let view = makeTurnView(turn)
        let group = try XCTUnwrap(groupViews(in: view).first)
        XCTAssertEqual(group.group.key, "g:toolu_0")
        XCTAssertEqual(group.group.callCount, 2)
        XCTAssertFalse(group.isExpanded)
    }

    func testAnIdlessGroupIsKeyedByTheTurnsIdentityAndTheCallsOrdinal() {
        let blocks: [TurnBlock] = [F.call(summary: "a"), F.result(), F.call(summary: "b"), .text("break"), F.call(summary: "c")]
        let turn = F.turn(blocks)
        let keys = groupViews(in: makeTurnView(turn)).map(\.group.key)
        XCTAssertEqual(keys, ["g:\(turn.identityKey)#c0", "g:\(turn.identityKey)#c2"])
    }

    // MARK: a single call

    func testASingleCallIsOneGroupWhoseRowShowsTheCallsHeader() throws {
        let turn = F.turn([.text("go"), F.call("Bash", id: "u1", summary: "git status --short"), F.result("clean", id: "u1")])
        let view = makeTurnView(turn)
        XCTAssertEqual(view.subviews.map(typeName), ["UserBubbleView", "TextBlockView", "ToolGroupView"])
        let row = try XCTUnwrap(groupViews(in: view).first?.row)
        XCTAssertTrue(row.summaryField.stringValue.contains("git status --short"), row.summaryField.stringValue)
        XCTAssertTrue(row.summaryField.stringValue.contains("Bash"), row.summaryField.stringValue)
    }

    func testASingleCallWithNoInputSummaryStillShowsItsToolName() throws {
        let turn = F.turn([F.call("TodoWrite", id: "u1", summary: ""), F.result("ok", id: "u1")])
        let row = try XCTUnwrap(groupViews(in: makeTurnView(turn)).first?.row)
        XCTAssertTrue(row.summaryField.stringValue.contains("TodoWrite"), row.summaryField.stringValue)
    }

    // MARK: expanded

    func testAnExpandedGroupShowsTheCallsAndResultsInBlockOrder() throws {
        let turn = F.turn([.text("before")] + F.run(4) + [.text("after")])
        let key = F.groups(of: turn)[0].key
        for view in [makeTurnView(turn, interaction: expanded(key)),
                     makeTurnView(turn, folds: FoldResolver(expandedByDefault: true))] {
            let group = try XCTUnwrap(groupViews(in: view).first)
            XCTAssertTrue(group.isExpanded)
            XCTAssertEqual(memberKinds(group), Array(repeating: ["call", "result"], count: 4).flatMap { $0 })
        }
    }

    func testAnExpandedGroupsCallsRenderAsTheCallRowsAlwaysHave() throws {
        let turn = F.turn(F.run(2))
        let view = makeTurnView(turn, folds: FoldResolver(expandedByDefault: true))
        let group = try XCTUnwrap(groupViews(in: view).first)
        let summaries = group.memberViews.filter { $0 is ToolCallView }.flatMap { textFields(in: $0) }.map(\.stringValue)
        XCTAssertTrue(summaries.contains("cmd t0"), "\(summaries)")
        XCTAssertTrue(summaries.contains("cmd t1"), "\(summaries)")
        XCTAssertTrue(summaries.contains("Bash"), "\(summaries)")
    }

    func testExplicitChoicesBeatTheDefaultAndOnlyAffectTheirOwnGroup() throws {
        let turn = F.turn(F.run(2, prefix: "a") + [.text("between")] + F.run(2, prefix: "b"))
        var state = TurnInteractionState()
        state.groupStates["g:b0"] = true
        let collapsedDefault = groupViews(in: makeTurnView(turn, interaction: state)).map(\.isExpanded)
        XCTAssertEqual(collapsedDefault, [false, true])
        var close = TurnInteractionState()
        close.groupStates["g:a0"] = false
        let expandedDefault = groupViews(in: makeTurnView(turn, interaction: close, folds: FoldResolver(state: close, expandedByDefault: true)))
            .map(\.isExpanded)
        XCTAssertEqual(expandedDefault, [false, true])
    }

    func testEachResultFoldInsideAnExpandedGroupTogglesOnItsOwn() throws {
        let turn = F.turn([.text("before")] + F.run(3) + [.text("after")])
        let view = makeTurnView(turn, folds: FoldResolver(expandedByDefault: true))
        let group = try XCTUnwrap(groupViews(in: view).first)
        let results = group.memberViews.filter { $0 is ToolResultView }
        XCTAssertEqual(results.count, 3)
        let buttons = try results.map { try XCTUnwrap(disclosure(of: $0)) }
        XCTAssertEqual(buttons.map(isOpenArrow), [false, false, false], "non-error results start closed")

        buttons[1].performClick(nil)
        XCTAssertEqual(buttons.map(isOpenArrow), [false, true, false], "only the clicked result opened")
        buttons[1].performClick(nil)
        XCTAssertEqual(buttons.map(isOpenArrow), [false, false, false])
    }

    func testAnErrorResultStartsOpenInsideAnExpandedGroup() throws {
        let blocks: [TurnBlock] = [F.call(id: "u1", summary: "false"), F.result("exit 1", id: "u1", isError: true),
                                   F.call(id: "u2", summary: "true"), F.result("fine", id: "u2")]
        let view = makeTurnView(F.turn(blocks), folds: FoldResolver(expandedByDefault: true))
        let group = try XCTUnwrap(groupViews(in: view).first)
        let buttons = try group.memberViews.filter { $0 is ToolResultView }.map { try XCTUnwrap(disclosure(of: $0)) }
        XCTAssertEqual(buttons.map(isOpenArrow), [true, false])
    }

    func testAResultToggleInsideAGroupReportsTheResultsBlockIndex() throws {
        // block indices: 0 prose, 1 call, 2 result, 3 call, 4 result, 5 call, 6 result
        let turn = F.turn([.text("before")] + F.run(3))
        let view = makeTurnView(turn, folds: FoldResolver(expandedByDefault: true))
        var events: [[Int]] = []
        view.onBlockExpansion = { index, open in events.append([index, open ? 1 : 0]) }
        let group = try XCTUnwrap(groupViews(in: view).first)
        let results = group.memberViews.filter { $0 is ToolResultView }
        try XCTUnwrap(disclosure(of: results[1])).performClick(nil)
        try XCTUnwrap(disclosure(of: results[2])).performClick(nil)
        try XCTUnwrap(disclosure(of: results[1])).performClick(nil)
        XCTAssertEqual(events, [[4, 1], [6, 1], [4, 0]])
    }

    func testAResultTheOperatorHadExpandedComesBackOpenInsideAnExpandedGroup() throws {
        let turn = F.turn([.text("before")] + F.run(2, output: { "line one of \($0)\nline two" }))
        var state = expanded(F.groups(of: turn)[0].key)
        state.expandedBlocks = [4]   // the second result
        let view = makeTurnView(turn, interaction: state)
        let group = try XCTUnwrap(groupViews(in: view).first)
        let buttons = try group.memberViews.filter { $0 is ToolResultView }.map { try XCTUnwrap(disclosure(of: $0)) }
        XCTAssertEqual(buttons.map(isOpenArrow), [false, true])
        XCTAssertTrue(textFields(in: group).contains { $0.stringValue.contains("line one of 1") })
    }

    // MARK: toggling

    func testClickingTheRowOpensTheGroupAndTellsTheOwnerAndTheHeightGrows() throws {
        let turn = F.turn([.text("before")] + F.run(4) + [.text("after")])
        let key = F.groups(of: turn)[0].key
        let view = makeTurnView(turn)
        var toggles: [String] = []
        var geometryChanges = 0
        view.onGroupToggle = { toggles.append("\($0)=\($1)") }
        view.onIntrinsicHeightChange = { geometryChanges += 1 }
        let collapsedHeight = view.islandHeight()

        let group = try XCTUnwrap(groupViews(in: view).first)
        group.row.toggle()

        XCTAssertEqual(toggles, ["\(key)=true"])
        XCTAssertGreaterThan(geometryChanges, 0, "the owner is told the geometry changed")
        XCTAssertTrue(group.isExpanded)
        XCTAssertGreaterThan(view.islandHeight(), collapsedHeight + 4 * 30, "four call rows and four result rows appeared")
        XCTAssertEqual(memberKinds(group).count, 8)

        group.row.toggle()
        XCTAssertEqual(toggles, ["\(key)=true", "\(key)=false"])
        XCTAssertEqual(view.islandHeight(), collapsedHeight, accuracy: 0.001, "collapsing restores the collapsed height exactly")
    }

    func testAnExpandedTurnsHeightIsWhatAFreshlyBuiltExpandedTurnMeasures() throws {
        let turn = F.turn([.text("before")] + F.run(4) + [.text("after")])
        let key = F.groups(of: turn)[0].key
        let clicked = makeTurnView(turn)
        try XCTUnwrap(groupViews(in: clicked).first).row.toggle()
        let fresh = makeTurnView(turn, interaction: expanded(key))
        XCTAssertEqual(clicked.islandHeight(), fresh.islandHeight(), accuracy: 0.5)
    }

    // MARK: separators

    private func separators() -> [(name: String, block: TurnBlock, isThatView: (NSView) -> Bool)] {
        [("prose", .text("prose between the runs"), { $0 is TextBlockView }),
         ("ask card", F.question(), { $0 is AskQuestionView }),
         ("error message", .errorMessage("the child exited"), { $0 is ErrorBlockView }),
         ("note", .note("Model changed to Opus (from Sonnet) by you."), { $0 is NoteBlockView }),
         ("result chip", F.chip(), { $0 is ResultChipView })]
    }

    func testEachSeparatorSplitsTwoRunsAndStaysOutsideEveryGroup() {
        for separator in separators() {
            let turn = F.turn(F.run(2, prefix: "a") + [separator.block] + F.run(2, prefix: "b"))
            for folds in [FoldResolver(), FoldResolver(expandedByDefault: true)] {
                let view = makeTurnView(turn, folds: folds)
                let direct = view.subviews.filter { !($0 is UserBubbleView) }
                XCTAssertEqual(direct.count, 3, "\(separator.name): group, separator, group")
                guard direct.count == 3 else { continue }
                XCTAssertTrue(direct[0] is ToolGroupView && direct[2] is ToolGroupView, "\(separator.name)")
                XCTAssertTrue(separator.isThatView(direct[1]), "\(separator.name): the middle column is \(typeName(direct[1]))")
                for group in groupViews(in: view) {
                    XCTAssertFalse(rigAllSubviews(of: group).contains(where: separator.isThatView),
                                   "\(separator.name) must never be inside a group")
                }
            }
        }
    }

    func testWhitespaceOnlyProseBetweenCallsDoesNotSplitTheGroup() {
        let turn = F.turn(F.run(1, prefix: "a") + [.text("  \n ")] + F.run(1, prefix: "b"))
        XCTAssertEqual(groupViews(in: makeTurnView(turn)).count, 1)
    }

    func testTheUserMessageIsNeverInsideAGroup() {
        let turn = F.turn(F.run(3), user: "please run three commands")
        let view = makeTurnView(turn, folds: FoldResolver(expandedByDefault: true))
        XCTAssertTrue(view.subviews.first is UserBubbleView)
        for group in groupViews(in: view) {
            XCTAssertFalse(rigAllSubviews(of: group).contains { $0 is UserBubbleView })
        }
    }

    // MARK: streaming

    private func assertStreamingMatchesOneShot(expanded isExpanded: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let all: [TurnBlock] = [.text(F.prose)] + F.run(3) + [.text("after"), F.chip()]
        let folds = FoldResolver(expandedByDefault: isExpanded)
        let oneShot = makeTurnView(F.turn(all, complete: false), folds: folds)
        let streamed = makeTurnView(F.turn([], complete: false), folds: folds)
        for k in 1 ... all.count { streamed.update(turn: F.turn(Array(all.prefix(k)), complete: false)) }

        XCTAssertEqual(columnKinds(streamed), columnKinds(oneShot), "expanded=\(isExpanded)", file: file, line: line)
        XCTAssertEqual(groupViews(in: streamed).map(\.group), groupViews(in: oneShot).map(\.group), file: file, line: line)
        XCTAssertEqual(groupViews(in: streamed).map { memberKinds($0).count }, groupViews(in: oneShot).map { memberKinds($0).count },
                       file: file, line: line)
        XCTAssertEqual(streamed.islandHeight(), oneShot.islandHeight(), accuracy: 0.5, "expanded=\(isExpanded)", file: file, line: line)
    }

    func testStreamingBlockByBlockBuildsWhatAOneShotBuildDoesCollapsed() { assertStreamingMatchesOneShot(expanded: false) }
    func testStreamingBlockByBlockBuildsWhatAOneShotBuildDoesExpanded() { assertStreamingMatchesOneShot(expanded: true) }

    func testGrowingACollapsedGroupDoesNotChangeTheTurnsHeight() {
        let all: [TurnBlock] = [.text(F.prose)] + F.run(6)
        let view = makeTurnView(F.turn(Array(all.prefix(2)), complete: false))
        let height = view.islandHeight()
        XCTAssertEqual(groupViews(in: view).count, 1)
        for k in 3 ... all.count {
            view.update(turn: F.turn(Array(all.prefix(k)), complete: false))
            XCTAssertEqual(view.islandHeight(), height, accuracy: 0.001, "after block \(k - 1) the collapsed row is still one 22 pt row")
        }
        XCTAssertEqual(groupViews(in: view).count, 1, "the new calls joined the one group")
        XCTAssertEqual(groupViews(in: view).first?.group.callCount, 6)
    }

    func testGrowingAnExpandedGroupGrowsTheTurn() {
        let all: [TurnBlock] = [.text(F.prose)] + F.run(4)
        let view = makeTurnView(F.turn(Array(all.prefix(2)), complete: false), folds: FoldResolver(expandedByDefault: true))
        var previous = view.islandHeight()
        for k in 3 ... all.count {
            view.update(turn: F.turn(Array(all.prefix(k)), complete: false))
            let height = view.islandHeight()
            XCTAssertGreaterThan(height, previous, "block \(k - 1) added a visible member")
            previous = height
        }
    }

    func testGrowingAGroupKeepsItsViewAndItsExpansion() throws {
        let all: [TurnBlock] = F.run(3)
        let view = makeTurnView(F.turn(Array(all.prefix(2)), complete: false), folds: FoldResolver(expandedByDefault: true))
        let before = try XCTUnwrap(groupViews(in: view).first)
        let members = before.memberViews
        view.update(turn: F.turn(all, complete: false))
        let after = try XCTUnwrap(groupViews(in: view).first)
        XCTAssertTrue(before === after, "an extending group updates in place")
        XCTAssertTrue(after.isExpanded)
        XCTAssertEqual(after.memberViews.count, 6)
        XCTAssertTrue(zip(members, after.memberViews).allSatisfy { $0 === $1 }, "existing members are kept")
    }

    // MARK: the 22 pt row

    func testTheRowIsTwentyTwoPoints() { XCTAssertEqual(ToolGroupRowView.height, 22) }

    private func collapsedIslandHeight(_ blocks: [TurnBlock]) throws -> CGFloat {
        let turn = F.turn(blocks)
        let group = try XCTUnwrap(F.groups(of: turn).first)
        let view = ToolGroupView(group: group, blocks: turn.blocks, contentAvailable: true,
                                 interaction: TurnInteractionState(), isExpanded: false)
        return ChatTurnView.measureIsland(view, width: ChatTurnView.blockWidth(paneWidth: paneWidth))
    }

    func testACollapsedGroupIsTwentyTwoPointsWhateverItHolds() throws {
        XCTAssertEqual(try collapsedIslandHeight(F.run(1)), 22, accuracy: 0.5, "one call")
        XCTAssertEqual(try collapsedIslandHeight(F.run(60)), 22, accuracy: 0.5, "sixty calls")
        let hostile = [F.call("Bash", id: "u1", summary: F.longCommand, full: F.bashInput(F.longCommand)), F.result("ok", id: "u1")]
        XCTAssertEqual(try collapsedIslandHeight(hostile), 22, accuracy: 0.5, "a 10,000-character command on one line")
    }

    func testAnExpandedTurnsHeightIsTheCollapsedHeightPlusTheMembers() throws {
        let turn = F.turn(F.run(3))
        let collapsed = makeTurnView(turn).islandHeight()
        let open = makeTurnView(turn, folds: FoldResolver(expandedByDefault: true)).islandHeight()
        let width = ChatTurnView.blockWidth(paneWidth: paneWidth)
        let members = turn.blocks.reduce(CGFloat(0)) { sum, block in
            switch block {
            case .toolCall(let d): return sum + 6 + ChatTurnView.measureIsland(ToolCallView(data: d), width: width)
            case .toolResult(let d):
                return sum + 6 + ChatTurnView.measureIsland(ToolResultView(data: d, contentAvailable: true, startExpanded: false), width: width)
            default: return sum
            }
        }
        XCTAssertEqual(open - collapsed, members, accuracy: 1.0)
    }
}

// MARK: - The row

final class ToolGroupRowTests: XCTestCase {

    private func makeRow(_ group: ToolGroup, expanded: Bool = false, payloadAvailable: Bool = true,
                         reduceMotion: @escaping () -> Bool = { false }) -> (RigWindow, ToolGroupRowView) {
        let window = makeRigWindow(self, size: NSSize(width: 700, height: 200))
        let row = ToolGroupRowView(group: group, isExpanded: expanded, payloadAvailable: payloadAvailable,
                                   reduceMotion: reduceMotion)
        row.frame = NSRect(x: 20, y: 100, width: 600, height: ToolGroupRowView.height)
        window.contentView!.addSubview(row)
        window.contentView!.layoutSubtreeIfNeeded()
        return (window, row)
    }

    // MARK: texts

    func testALargerGroupsRowShowsTheSummary() {
        let group = F.plainGroup(calls: 3)
        let (_, row) = makeRow(group)
        XCTAssertEqual(row.summaryField.stringValue, ToolGroupSummary.summary(for: group))
        XCTAssertEqual(row.summaryField.stringValue, "Ran 3 commands")
    }

    func testAGroupOfOneShowsTheCallsHeader() {
        let group = F.group([F.foldCall("Read", id: "r1", summary: "Package.swift", target: "/repo/Package.swift"), F.foldResult(id: "r1")])
        let (_, row) = makeRow(group)
        XCTAssertTrue(row.summaryField.stringValue.contains("Read"), row.summaryField.stringValue)
        XCTAssertTrue(row.summaryField.stringValue.contains("Package.swift"), row.summaryField.stringValue)
    }

    func testAHostileCallSummaryRendersAsOneCleanLine() {
        let hostile = [F.hostileSummary, F.longCommand, F.megabyte]
        for summary in hostile {
            let group = F.group([F.foldCall("Bash", id: "h", summary: summary), F.foldResult(id: "h")])
            let (_, row) = makeRow(group)
            for text in [row.summaryField.stringValue, row.summaryField.attributedStringValue.string] {
                XCTAssertFalse(text.unicodeScalars.contains(where: F.isForbiddenOnARow),
                               "escape, newline, control or bidi scalar survived on the row")
                XCTAssertLessThanOrEqual(text.utf16.count, 512 + 16, "a huge input costs one bounded line")
            }
        }
    }

    func testTheFailureBadgeShowsTheCountInTheFailureColourOnlyWhenSomethingFailed() {
        let (_, clean) = makeRow(F.plainGroup(calls: 3))
        XCTAssertTrue(clean.badgeField.isHidden)

        let (_, failing) = makeRow(F.failingGroup(calls: 3))
        XCTAssertFalse(failing.badgeField.isHidden)
        XCTAssertEqual(failing.badgeField.stringValue.trimmingCharacters(in: .whitespaces), "· 1 failed")
        XCTAssertEqual(failing.badgeField.textColor, Theme.foldFailure)
    }

    func testTheTimeShowsTheGroupsDurationAndIsHiddenWhenUnknown() {
        let (_, unknown) = makeRow(F.plainGroup(calls: 3))
        XCTAssertTrue(unknown.timeField.isHidden)

        let group = F.failingGroup(calls: 3)
        let (_, known) = makeRow(group)
        XCTAssertFalse(known.timeField.isHidden)
        XCTAssertEqual(ToolGroupSummary.durationText(for: group), "4.1 s")
        XCTAssertEqual(known.timeField.stringValue.trimmingCharacters(in: .whitespaces), "· 4.1 s")
    }

    func testUpdatingTheGroupRefreshesTheSummaryBadgeAndTime() {
        let (_, row) = makeRow(F.plainGroup(calls: 2))
        XCTAssertEqual(row.summaryField.stringValue, "Ran 2 commands")
        XCTAssertTrue(row.badgeField.isHidden)
        row.update(group: F.failingGroup(calls: 5))
        XCTAssertEqual(row.summaryField.stringValue, "Ran 5 commands")
        XCTAssertFalse(row.badgeField.isHidden)
        XCTAssertFalse(row.timeField.isHidden)
    }

    // MARK: keyboard

    private func press(_ code: UInt16, _ characters: String, on row: ToolGroupRowView, in window: NSWindow) {
        row.keyDown(with: keyEvent(code, characters, in: window))
    }

    func testTheRowIsAKeyboardControl() {
        let (window, row) = makeRow(F.plainGroup(calls: 3))
        XCTAssertTrue(row.acceptsFirstResponder)
        XCTAssertTrue(row.canBecomeKeyView)
        XCTAssertTrue(window.makeFirstResponder(row))
        XCTAssertTrue(window.firstResponder === row)
    }

    func testSpaceAndReturnToggleTheFocusedRow() {
        let (window, row) = makeRow(F.plainGroup(calls: 3))
        var toggles: [Bool] = []
        row.onToggle = { toggles.append($0) }
        XCTAssertTrue(window.makeFirstResponder(row))

        press(Key.space, " ", on: row, in: window)
        XCTAssertTrue(row.isExpanded)
        press(Key.space, " ", on: row, in: window)
        XCTAssertFalse(row.isExpanded)
        press(Key.return, "\r", on: row, in: window)
        XCTAssertTrue(row.isExpanded)
        press(Key.return, "\r", on: row, in: window)
        XCTAssertFalse(row.isExpanded)
        XCTAssertEqual(toggles, [true, false, true, false])
    }

    func testRightArrowOpensAndLeavesItOpenAndLeftArrowCloses() {
        let (window, row) = makeRow(F.plainGroup(calls: 3))
        var toggles: [Bool] = []
        row.onToggle = { toggles.append($0) }
        XCTAssertTrue(window.makeFirstResponder(row))

        press(Key.right, arrow(NSRightArrowFunctionKey), on: row, in: window)
        XCTAssertTrue(row.isExpanded)
        press(Key.right, arrow(NSRightArrowFunctionKey), on: row, in: window)
        XCTAssertTrue(row.isExpanded, "→ never closes")
        press(Key.left, arrow(NSLeftArrowFunctionKey), on: row, in: window)
        XCTAssertFalse(row.isExpanded)
        press(Key.left, arrow(NSLeftArrowFunctionKey), on: row, in: window)
        XCTAssertFalse(row.isExpanded, "← never opens")
        XCTAssertEqual(toggles, [true, false], "only real changes are reported")
    }

    func testUpAndDownArrowsMoveFocusBetweenGroupRowsInTheSameWindow() throws {
        let turn = F.turn(F.run(2, prefix: "a") + [.text("between")] + F.run(2, prefix: "b"))
        let rig = makeTranscriptRig(self, blocks: turn.blocks)
        let rows = rigAllSubviews(of: rig.turn).compactMap { $0 as? ToolGroupRowView }
        XCTAssertEqual(rows.count, 2)
        guard rows.count == 2 else { return }
        XCTAssertTrue(rig.window.makeFirstResponder(rows[0]))

        rows[0].keyDown(with: keyEvent(Key.down, arrow(NSDownArrowFunctionKey), in: rig.window))
        XCTAssertTrue(rig.window.firstResponder === rows[1], "↓ went to \(String(describing: rig.window.firstResponder))")
        rows[1].keyDown(with: keyEvent(Key.up, arrow(NSUpArrowFunctionKey), in: rig.window))
        XCTAssertTrue(rig.window.firstResponder === rows[0], "↑ went to \(String(describing: rig.window.firstResponder))")
    }

    func testBuildingAndUpdatingGroupsNeverTakesFocusFromTheComposer() throws {
        let rig = makeTranscriptRig(self, blocks: [.text(F.prose)] + F.run(2, prefix: "a"))
        let composer = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        rig.content.addSubview(composer)
        XCTAssertTrue(rig.window.makeFirstResponder(composer))

        // A group built into the window, then grown, then a whole new group streamed in.
        let extra = F.turn(F.run(2, prefix: "x"))
        let built = ToolGroupView(group: F.groups(of: extra)[0], blocks: extra.blocks,
                                  contentAvailable: true, interaction: TurnInteractionState(), isExpanded: true)
        rig.content.addSubview(built)
        rig.window.makeKey()
        XCTAssertTrue(rig.window.firstResponder === composer, "building a group view took focus")

        let grown = F.turn([.text(F.prose)] + F.run(4, prefix: "a") + [.text("after")] + F.run(1, prefix: "b"))
        rig.turn.update(turn: grown)
        rig.relayout(width: 900)
        rigSettle()
        XCTAssertTrue(rig.window.firstResponder === composer, "streaming new tool blocks took focus: \(String(describing: rig.window.firstResponder))")
        XCTAssertGreaterThanOrEqual(rigAllSubviews(of: rig.turn).compactMap { $0 as? ToolGroupRowView }.count, 1)
    }

    // MARK: accessibility

    func testTheRowIsAnAccessibleDisclosureTriangleWithTheFullSummaryAndState() {
        let group = F.failingGroup(calls: 3)
        let (_, row) = makeRow(group)
        XCTAssertEqual(row.accessibilityRole(), .disclosureTriangle)
        XCTAssertTrue(row.isAccessibilityElement())
        XCTAssertEqual(row.accessibilityLabel(), ToolGroupSummary.accessibilityLabel(for: group))
        XCTAssertTrue(row.accessibilityLabel()?.contains("1 failed call") ?? false)
        XCTAssertEqual(row.accessibilityValue() as? String, "collapsed")
        row.setExpanded(true, animated: false)
        XCTAssertEqual(row.accessibilityValue() as? String, "expanded")
    }

    func testAccessibilityPressTogglesTheRow() {
        let (_, row) = makeRow(F.plainGroup(calls: 3))
        var toggles: [Bool] = []
        row.onToggle = { toggles.append($0) }
        XCTAssertTrue(row.accessibilityPerformPress())
        XCTAssertEqual(toggles, [true])
        XCTAssertEqual(row.accessibilityValue() as? String, "expanded")
        XCTAssertTrue(row.accessibilityPerformPress())
        XCTAssertEqual(toggles, [true, false])
        XCTAssertEqual(row.accessibilityValue() as? String, "collapsed")
    }

    func testSettingTheStateDoesNotCountAsTheOperatorsToggle() {
        let (_, row) = makeRow(F.plainGroup(calls: 3))
        row.onToggle = { _ in XCTFail("a programmatic change is not a click") }
        row.setExpanded(true, animated: false)
        row.setExpanded(false, animated: true)
        XCTAssertFalse(row.isExpanded)
    }

    // MARK: Reduce Motion

    func testTheTriangleDoesNotAnimateUnderReduceMotion() {
        let (_, row) = makeRow(F.plainGroup(calls: 3), reduceMotion: { true })
        row.setExpanded(true, animated: true)
        XCTAssertTrue(row.triangleLayer.animationKeys()?.isEmpty ?? true, "\(String(describing: row.triangleLayer.animationKeys()))")
        row.toggle()
        XCTAssertTrue(row.triangleLayer.animationKeys()?.isEmpty ?? true, "\(String(describing: row.triangleLayer.animationKeys()))")
    }

    func testTheTriangleAnimatesWhenMotionIsAllowed() {
        let (_, row) = makeRow(F.plainGroup(calls: 3), reduceMotion: { false })
        row.setExpanded(true, animated: true)
        XCTAssertFalse(row.triangleLayer.animationKeys()?.isEmpty ?? true)
    }

    // MARK: click versus drag

    private func center(of view: NSView) -> NSPoint {
        let rect = view.convert(view.bounds, to: nil)
        return NSPoint(x: rect.midX, y: rect.midY)
    }

    func testAClickOnTheRowToggles() throws {
        let (window, row) = makeRow(F.plainGroup(calls: 10))
        var toggles: [Bool] = []
        row.onToggle = { toggles.append($0) }

        let summary = row.summaryField.convert(row.summaryField.bounds, to: nil)
        try AppControlMouse.click(in: window, at: NSPoint(x: summary.minX + 8, y: summary.midY))
        XCTAssertEqual(toggles, [true], "a click on the summary text")
        XCTAssertTrue(row.isExpanded)

        let rowRect = row.convert(row.bounds, to: nil)
        try AppControlMouse.click(in: window, at: NSPoint(x: rowRect.maxX - 6, y: rowRect.midY))
        XCTAssertEqual(toggles, [true, false], "a click on the empty end of the row")
    }

    func testAMouseUpWithinFourPointsOfTheMouseDownIsStillAClick() throws {
        let (window, row) = makeRow(F.plainGroup(calls: 10))
        var toggles: [Bool] = []
        row.onToggle = { toggles.append($0) }
        let summary = row.summaryField.convert(row.summaryField.bounds, to: nil)
        let from = NSPoint(x: summary.minX + 20, y: summary.midY)
        try AppControlMouse.drag(in: window, from: from, to: NSPoint(x: from.x + 2, y: from.y))
        XCTAssertEqual(toggles, [true])
    }

    func testADragAcrossTheSummaryDoesNotToggleAndSelectsTheText() throws {
        let (window, row) = makeRow(F.plainGroup(calls: 10))
        var toggles: [Bool] = []
        row.onToggle = { toggles.append($0) }
        let summary = row.summaryField.convert(row.summaryField.bounds, to: nil)
        let from = NSPoint(x: summary.minX + 6, y: summary.midY)
        try AppControlMouse.drag(in: window, from: from, to: NSPoint(x: from.x + 40, y: from.y))

        XCTAssertEqual(toggles, [], "a 40 pt drag is a selection, not a click")
        XCTAssertFalse(row.isExpanded)
        let editor = rigEditor(of: row.summaryField)
        XCTAssertGreaterThan(editor?.selectedRange.length ?? 0, 0, "the drag selected part of the summary")
    }

    func testTheSummaryIsSelectableText() {
        let (_, row) = makeRow(F.plainGroup(calls: 3))
        XCTAssertTrue(row.summaryField.isSelectable)
        XCTAssertFalse(row.summaryField.isEditable)
    }
}

// MARK: - The island

final class ToolGroupIslandTests: XCTestCase {

    private func makeGroupView(_ blocks: [TurnBlock], expanded: Bool = false,
                               interaction: TurnInteractionState = TurnInteractionState(),
                               contentAvailable: Bool = true, textParents: [Int: String] = [:]) -> ToolGroupView {
        let turn = F.turn(blocks, textParents: textParents)
        return ToolGroupView(group: F.groups(of: turn)[0], blocks: turn.blocks,
                             contentAvailable: contentAvailable, interaction: interaction, isExpanded: expanded)
    }

    private let width = ChatTurnView.blockWidth(paneWidth: paneWidth)

    func testCollapsedItHoldsOnlyItsRow() {
        let view = makeGroupView(F.run(5))
        XCTAssertTrue(view.memberViews.isEmpty)
        XCTAssertFalse(rigAllSubviews(of: view).contains { $0 is ToolCallView || $0 is ToolResultView })
        XCTAssertTrue(view.subviews.contains { $0 === view.row })
    }

    func testTheFirstExpandBuildsTheMembersAndCollapsingKeepsTheSameOnes() {
        let view = makeGroupView(F.run(3))
        var toggles = 0
        view.onToggle = { _ in toggles += 1 }
        let collapsedHeight = ChatTurnView.measureIsland(view, width: width)

        view.setExpanded(true)
        XCTAssertEqual(toggles, 0, "setExpanded is not the operator's click")
        XCTAssertTrue(view.isExpanded)
        XCTAssertTrue(view.row.isExpanded)
        XCTAssertEqual(view.memberViews.map { $0 is ToolCallView ? "call" : "result" },
                       ["call", "result", "call", "result", "call", "result"])
        let built = view.memberViews
        XCTAssertGreaterThan(ChatTurnView.measureIsland(view, width: width), collapsedHeight + 100)

        view.setExpanded(false)
        XCTAssertFalse(view.isExpanded)
        XCTAssertTrue(view.memberViews.allSatisfy { $0.isHidden || $0.superview == nil }, "members are hidden while collapsed")
        XCTAssertEqual(ChatTurnView.measureIsland(view, width: width), collapsedHeight, accuracy: 0.5)

        view.setExpanded(true)
        XCTAssertEqual(view.memberViews.count, built.count)
        XCTAssertTrue(zip(built, view.memberViews).allSatisfy { $0 === $1 }, "re-expanding reuses the members it built")
        XCTAssertTrue(view.memberViews.allSatisfy { !$0.isHidden })
    }

    func testTheRowsClickExpandsTheIslandAndTellsItsOwner() {
        let view = makeGroupView(F.run(3))
        var toggles: [Bool] = []
        view.onToggle = { toggles.append($0) }
        view.row.toggle()
        XCTAssertEqual(toggles, [true])
        XCTAssertTrue(view.isExpanded)
        XCTAssertEqual(view.memberViews.count, 6)
    }

    func testMembersKeepTodaysXAndWidth() {
        let view = makeGroupView(F.run(3), expanded: true)
        _ = ChatTurnView.measureIsland(view, width: width)
        XCTAssertEqual(view.memberViews.count, 6)
        for member in view.memberViews {
            XCTAssertEqual(member.frame.minX, 0, accuracy: 0.5, "\(typeName(member)) x")
            XCTAssertEqual(member.frame.width, width, accuracy: 0.5, "\(typeName(member)) width")
        }
    }

    func testMembersRenderAtTheHeightTheyAlwaysDid() {
        let turn = F.turn(F.run(2))
        let view = makeGroupView(turn.blocks, expanded: true)
        _ = ChatTurnView.measureIsland(view, width: width)
        for (member, block) in zip(view.memberViews, turn.blocks) {
            switch block {
            case .toolCall(let d):
                XCTAssertEqual(member.frame.height, ChatTurnView.measureIsland(ToolCallView(data: d), width: width), accuracy: 0.5)
            case .toolResult(let d):
                XCTAssertEqual(member.frame.height,
                               ChatTurnView.measureIsland(ToolResultView(data: d, contentAvailable: true, startExpanded: false), width: width),
                               accuracy: 0.5)
            default: XCTFail("unexpected block")
            }
        }
    }

    func testUpdatingACollapsedGroupChangesItsCountsNotItsHeight() {
        let view = makeGroupView(F.run(2))
        let bigger = F.turn(F.run(3))
        let changed = view.update(group: F.groups(of: bigger)[0], blocks: bigger.blocks)
        XCTAssertFalse(changed, "a collapsed group is 22 pt however many calls it holds")
        XCTAssertEqual(view.group.callCount, 3)
        XCTAssertEqual(view.row.summaryField.stringValue, "Ran 3 commands")
        XCTAssertTrue(view.memberViews.isEmpty, "still nothing built")
    }

    func testUpdatingAnExpandedGroupAddsMembersAndReportsTheHeightChange() {
        let view = makeGroupView(F.run(2), expanded: true)
        let bigger = F.turn(F.run(3))
        let changed = view.update(group: F.groups(of: bigger)[0], blocks: bigger.blocks)
        XCTAssertTrue(changed)
        XCTAssertEqual(view.memberViews.count, 6)
    }

    // MARK: Agent / Task

    /// 0 prose, 1 Agent call, 2 sub call, 3 sub result, 4 sub prose, 5 the Agent's own result.
    private var agentBlocks: [TurnBlock] {
        [.text("intro"),
         F.call("Agent", id: "toolu_agent", summary: "explore the repo"),
         F.call("Bash", id: "sub1", summary: "grep -r foo", parent: "toolu_agent"),
         F.result("foo.txt", id: "sub1", parent: "toolu_agent"),
         .text("the subagent thinks"),
         F.result("report from the agent", id: "toolu_agent")]
    }
    private let agentParents = [4: "toolu_agent"]

    func testAnAgentCallGetsItsSubagentActivityRightAfterItAndNotAsSeparateMembers() throws {
        let view = makeGroupView(agentBlocks, expanded: true, textParents: agentParents)
        XCTAssertEqual(memberKinds(view), ["call", "agent", "result"])
        XCTAssertEqual(view.memberViews.filter { $0 is ToolCallView }.count, 1, "the subagent's own call is not a member")
        let activity = try XCTUnwrap(view.memberViews[1] as? AgentActivityView)
        XCTAssertFalse(activity.isExpanded, "collapsed by default")
    }

    func testAnAgentWithNoSubagentBlocksHasNoActivityView() {
        let blocks: [TurnBlock] = [F.call("Agent", id: "toolu_agent", summary: "x"), F.result("done", id: "toolu_agent")]
        XCTAssertEqual(memberKinds(makeGroupView(blocks, expanded: true)), ["call", "result"])
    }

    func testTheActivityTogglesUnderTheAgentCallsBlockIndex() throws {
        let view = makeGroupView(agentBlocks, expanded: true, textParents: agentParents)
        var events: [[Int]] = []
        view.onBlockExpansion = { events.append([$0, $1 ? 1 : 0]) }
        let activity = try XCTUnwrap(view.memberViews[1] as? AgentActivityView)
        try XCTUnwrap(disclosure(of: activity)).performClick(nil)
        XCTAssertTrue(activity.isExpanded)
        XCTAssertEqual(events.first, [1, 1], "the Agent call is block 1")
    }

    func testTheActivityComesBackOpenWhenItsStateWasKept() throws {
        var state = TurnInteractionState()
        state.expandedBlocks = [1]
        let view = makeGroupView(agentBlocks, expanded: true, interaction: state, textParents: agentParents)
        let activity = try XCTUnwrap(view.memberViews[1] as? AgentActivityView)
        XCTAssertTrue(activity.isExpanded)
        XCTAssertTrue(textFields(in: activity).contains { $0.stringValue.contains("grep -r foo") },
                      "the subagent's call is listed inside its activity")
    }

    func testTheActivityIsNotBuiltOutOfThinAirWhileTheGroupIsCollapsed() {
        let view = makeGroupView(agentBlocks, expanded: false, textParents: agentParents)
        XCTAssertTrue(view.memberViews.isEmpty)
        XCTAssertFalse(rigAllSubviews(of: view).contains { $0 is AgentActivityView })
    }

    func testAnAgentActivityToggleInsideATurnReportsTheAgentBlockIndexToTheTurn() throws {
        let turn = F.turn(agentBlocks, textParents: agentParents)
        let view = makeTurnView(turn, folds: FoldResolver(expandedByDefault: true))
        var events: [[Int]] = []
        view.onBlockExpansion = { events.append([$0, $1 ? 1 : 0]) }
        let activity = try XCTUnwrap(rigAllSubviews(of: view).compactMap { $0 as? AgentActivityView }.first)
        try XCTUnwrap(disclosure(of: activity)).performClick(nil)
        XCTAssertEqual(events.first, [1, 1])
    }
}

// MARK: - What a collapsed group hides, and what selection can reach

final class ToolGroupSelectionTests: XCTestCase {

    private static let sentinel = "HIDDEN-OUTPUT-SENTINEL"

    private func turnWithHiddenOutput() -> ChatTurn {
        F.turn([.text("Intro prose that is long enough to be a real paragraph of assistant text. " + F.prose)]
               + F.run(3, output: { "result \($0) \(Self.sentinel) more output" })
               + [.text("Outro prose, also a paragraph of assistant text. " + F.prose)])
    }

    private func everyString(in view: NSView) -> [String] {
        rigAllSubviews(of: view).flatMap { sub -> [String] in
            if let field = sub as? NSTextField { return [field.stringValue, field.attributedStringValue.string] }
            if let text = sub as? NSTextView { return [text.string] }
            return []
        }
    }

    func testNoViewInACollapsedTurnHoldsTheHiddenOutput() {
        let view = makeTurnView(turnWithHiddenOutput())
        XCTAssertFalse(everyString(in: view).contains { $0.contains(Self.sentinel) },
                       "text inside a collapsed group is not in the view tree, so a drag cannot select it")
        XCTAssertFalse(rigAllSubviews(of: view).contains { $0.toolTip?.contains(Self.sentinel) ?? false })
    }

    func testExpandingTheGroupAndItsResultsPutsTheOutputInTheTree() throws {
        let turn = turnWithHiddenOutput()
        var state = expanded(F.groups(of: turn)[0].key)
        state.expandedBlocks = [2, 4, 6]
        let view = makeTurnView(turn, interaction: state)
        let labels = textFields(in: view).filter { $0.stringValue.contains(Self.sentinel) }
        XCTAssertEqual(labels.count, 3, "one output label per expanded result")
    }

    func testCollapsingAgainTakesTheOutputOutOfReachOfSelection() throws {
        let turn = turnWithHiddenOutput()
        var state = expanded(F.groups(of: turn)[0].key)
        state.expandedBlocks = [2, 4, 6]
        let view = makeTurnView(turn, interaction: state)
        let group = try XCTUnwrap(groupViews(in: view).first)
        group.row.toggle()
        XCTAssertFalse(group.isExpanded)
        let reachable = rigAllSubviews(of: group).filter { sub in
            var cursor: NSView? = sub
            while let c = cursor { if c.isHidden { return false }; cursor = c.superview }
            return true
        }
        XCTAssertFalse(reachable.contains { ($0 as? NSTextField)?.stringValue.contains(Self.sentinel) ?? false },
                       "hidden members must not be selectable")
    }

    func testADragFromTheProseIntoTheRowSelectsOnlyProseText() throws {
        let prose = "Intro prose that is long enough to be a real paragraph of assistant text. " + F.prose
        let rig = makeTranscriptRig(self, blocks: [.text(prose)] + F.run(3, output: { "result \($0) \(Self.sentinel)" })
                                    + [.text("Outro. " + F.prose)])
        let proseLabel = try XCTUnwrap(textFields(in: rig.turn).first { $0.stringValue == prose },
                                       "the first paragraph is a label: \(textFields(in: rig.turn).map(\.stringValue))")
        let row = try XCTUnwrap(rigAllSubviews(of: rig.turn).compactMap { $0 as? ToolGroupRowView }.first)

        let from = proseLabel.convert(NSPoint(x: 12, y: proseLabel.bounds.midY), to: nil)
        let rowRect = row.convert(row.bounds, to: nil)
        let to = NSPoint(x: rowRect.minX + 60, y: rowRect.midY)
        try AppControlMouse.drag(in: rig.window, from: from, to: to)

        let selected = rigEditor(of: proseLabel).flatMap { editor -> String? in
            let range = editor.selectedRange
            guard range.length > 0, NSMaxRange(range) <= (editor.string as NSString).length else { return nil }
            return (editor.string as NSString).substring(with: range)
        }
        XCTAssertNotNil(selected, "the drag selected text in the prose label")
        XCTAssertTrue(prose.contains(selected ?? "\u{0}"), "the selection is part of the prose: \(String(describing: selected))")
        XCTAssertFalse((selected ?? "").contains(Self.sentinel))

        for field in textFields(in: rig.turn) where field !== proseLabel {
            XCTAssertEqual(rigEditor(of: field)?.selectedRange.length ?? 0, 0,
                           "nothing outside the prose is selected: \(field.stringValue.prefix(40))")
        }
        XCTAssertEqual(rigEditor(of: row.summaryField)?.selectedRange.length ?? 0, 0, "the row's summary holds no selection")
        XCTAssertFalse(row.isExpanded, "a drag that ends on the row is not a click on it")
    }
}

// MARK: - Cold and dropped turns

final class ToolGroupColdTurnTests: XCTestCase {

    private func fullTurn() -> ChatTurn {
        let blocks: [TurnBlock] = [.text(F.prose),
            F.call("Bash", id: "c1", summary: "make build", start: 0), F.result("built", id: "c1", time: 1.0),
            F.call("Bash", id: "c2", summary: "make test", start: 1), F.result("1 failure", id: "c2", isError: true, time: 4.1),
            F.call("Read", id: "c3", summary: "Package.swift", target: "/repo/Package.swift", start: 2),
            F.result("// swift-tools", id: "c3", time: 3),
            .text("done")]
        return F.turn(blocks)
    }

    func testASkeletonPlansTheSameGroupsCountsFailuresAndDurationAsTheFullTurn() {
        let full = fullTurn()
        let skeleton = TurnPayloadStore.skeleton(of: full)
        let a = F.groups(of: full), b = F.groups(of: skeleton)
        XCTAssertEqual(b.count, a.count)
        XCTAssertEqual(b.map(\.key), a.map(\.key))
        XCTAssertEqual(b.map(\.callCount), a.map(\.callCount))
        XCTAssertEqual(b.map(\.failedCount), a.map(\.failedCount))
        XCTAssertEqual(b.map { ToolGroupSummary.durationText(for: $0) }, a.map { ToolGroupSummary.durationText(for: $0) })
        XCTAssertEqual(b.map { ToolGroupSummary.summary(for: $0) }, a.map { ToolGroupSummary.summary(for: $0) })
        // And the adapter agrees.
        XCTAssertEqual(ToolFoldAdapter.plan(skeleton).count, ToolFoldAdapter.plan(full).count)
    }

    func testAColdTurnsRowShowsTheSameSummaryBadgeAndTime() throws {
        let full = fullTurn()
        let skeleton = TurnPayloadStore.skeleton(of: full)
        let fullRow = try XCTUnwrap(groupViews(in: makeTurnView(full)).first?.row)
        let coldRow = try XCTUnwrap(groupViews(in: makeTurnView(skeleton, contentAvailable: false)).first?.row)
        XCTAssertEqual(coldRow.summaryField.stringValue, fullRow.summaryField.stringValue)
        XCTAssertEqual(coldRow.badgeField.stringValue, fullRow.badgeField.stringValue)
        XCTAssertEqual(coldRow.timeField.stringValue, fullRow.timeField.stringValue)
        XCTAssertFalse(coldRow.badgeField.isHidden)
        XCTAssertFalse(coldRow.timeField.isHidden)
    }

    func testExpandingADroppedTurnsGroupAndResultSaysTheContentIsNoLongerRetained() throws {
        let skeleton = TurnPayloadStore.skeleton(of: fullTurn())
        var state = expanded(F.groups(of: skeleton)[0].key)
        state.expandedBlocks = [2]
        let view = makeTurnView(skeleton, interaction: state, contentAvailable: false)
        let group = try XCTUnwrap(groupViews(in: view).first)
        XCTAssertTrue(group.isExpanded)
        // The result the operator expanded, and the failing one, which always opens.
        let notes = textFields(in: group).map(\.stringValue).filter { $0.contains("no longer retained") }
        XCTAssertEqual(notes.count, 2, "\(textFields(in: group).map(\.stringValue))")
    }

    func testCopyCommandsOnADroppedTurnFallsBackToSummariesAndSaysSo() throws {
        let skeleton = TurnPayloadStore.skeleton(of: fullTurn())
        let view = makeTurnView(skeleton, contentAvailable: false)
        let row = try XCTUnwrap(groupViews(in: view).first?.row)
        let pasteboard = rigPrivatePasteboard(self)
        row.pasteboard = pasteboard
        row.copyCommands()

        let text = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertEqual(text, ToolGroupSummary.commandsText(for: F.groups(of: skeleton)[0], payloadAvailable: false))
        XCTAssertTrue(text.contains("make build …"), text)
        XCTAssertTrue(text.contains("make test …"), text)
        XCTAssertTrue(text.hasSuffix(ToolGroupSummary.truncatedCommandsNote), text)
    }

    func testCopyCommandsOnALiveTurnIsTheCompleteInputAndHasNoTruncationNote() throws {
        let full = fullTurn()
        let row = try XCTUnwrap(groupViews(in: makeTurnView(full)).first?.row)
        let pasteboard = rigPrivatePasteboard(self)
        row.pasteboard = pasteboard
        row.copyCommands()
        let text = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertTrue(text.hasPrefix("make build\nmake test\nRead "), text)
        XCTAssertFalse(text.contains(ToolGroupSummary.truncatedCommandsNote))
    }
}

// MARK: - Layout cost and hostile content

final class ToolGroupCostTests: XCTestCase {

    private func turnWithGroup(of n: Int) -> ChatTurn {
        F.turn([.text("before")] + F.run(n) + [.text("after")])
    }

    #if DEBUG
    private func islandsMeasured(building turn: ChatTurn) -> Int {
        ChatTurnView.measureIslandCount = 0
        let view = ChatTurnView(turn: turn, contentAvailable: true, interaction: TurnInteractionState())
        view.setIslandWidth(paneWidth)
        _ = view.islandHeight()
        return ChatTurnView.measureIslandCount
    }

    func testASixtyCallGroupCostsTheSameMeasuresAsAOneCallGroupWhileCollapsed() {
        let one = islandsMeasured(building: turnWithGroup(of: 1))
        let sixty = islandsMeasured(building: turnWithGroup(of: 60))
        XCTAssertGreaterThan(one, 0)
        XCTAssertEqual(sixty, one, "collapsed, a group's layout cost does not depend on its size")
    }

    func testStreamingMoreCallsIntoACollapsedGroupMeasuresNothingNew() {
        let all: [TurnBlock] = [.text("a")] + F.run(8)
        let view = ChatTurnView(turn: F.turn(Array(all.prefix(2)), complete: false),
                                contentAvailable: true, interaction: TurnInteractionState())
        view.setIslandWidth(paneWidth)
        _ = view.islandHeight()
        ChatTurnView.measureIslandCount = 0
        view.update(turn: F.turn(all, complete: false))
        _ = view.islandHeight()
        XCTAssertEqual(ChatTurnView.measureIslandCount, 0, "extending a collapsed group re-measures nothing")
    }
    #endif

    func testTheViewCountOfASixtyCallGroupIsWithinTenPercentOfAOneCallGroup() {
        let one = rigAllSubviews(of: makeTurnView(turnWithGroup(of: 1))).count
        let sixty = rigAllSubviews(of: makeTurnView(turnWithGroup(of: 60))).count
        XCTAssertLessThanOrEqual(abs(sixty - one), Int((Double(max(one, sixty)) * 0.10).rounded(.up)),
                                 "1 call: \(one) views, 60 calls: \(sixty) views")
    }

    func testACollapsedGroupWithAMegabyteResultBuildsNoResultLabel() {
        let blocks: [TurnBlock] = [F.call(id: "u1", summary: "cat big"), F.result(F.megabyte, id: "u1"),
                                   F.call(id: "u2", summary: "cat small"), F.result("small", id: "u2")]
        let view = makeTurnView(F.turn(blocks))
        let all = rigAllSubviews(of: view)
        XCTAssertFalse(all.contains { $0 is ToolResultView })
        XCTAssertFalse(textFields(in: view).contains { $0.stringValue.utf8.count > 100_000 || $0.attributedStringValue.length > 100_000 },
                       "no label holds the megabyte")
    }

    func testAHostileSummaryNeverReachesAnyLabelOfACollapsedGroup() {
        let blocks: [TurnBlock] = [F.call(id: "u1", summary: F.hostileSummary), F.result("ok", id: "u1")]
        let view = makeTurnView(F.turn(blocks))
        XCTAssertFalse(textFields(in: view).isEmpty)
        for field in textFields(in: view) {
            XCTAssertFalse(field.stringValue.unicodeScalars.contains(where: F.isForbiddenOnARow), field.stringValue)
        }
    }

    func testTheBenchmarkTailBuildsHalfTheIslandsOrFewerThanOneToOneMappingWould() throws {
        let turns = Array(try F.benchmarkTurns().suffix(15))
        XCTAssertEqual(turns.count, 15)
        let blocks = turns.reduce(0) { $0 + $1.blocks.count }
        var islands = 0
        for turn in turns {
            let view = makeTurnView(turn)
            islands += view.subviews.filter { !($0 is UserBubbleView) }.count
        }
        XCTAssertGreaterThan(blocks, 0)
        XCTAssertLessThanOrEqual(Double(islands), Double(blocks) * 0.5,
                                 "\(islands) islands for \(blocks) blocks across the last 15 turns")
    }
}

// MARK: - Review follow-ups (Perri, TF2)

final class ToolGroupReviewFollowUpTests: XCTestCase {

    private typealias F = FoldFixtures

    /// Building a turn touches a big group once per block; its row must be brought up to
    /// date once, not once per op (a 2,000-call group took 27 s that way).
    func testBuildingATurnUpdatesEachGroupRowAtMostTwice() {
        let turn = F.turn([.text(F.prose)] + F.run(1_000, name: "Read") + [.text(F.prose)] + F.run(3, prefix: "b"))
        ToolGroupRowView.updateCount = 0
        let view = ChatTurnView(turn: turn, contentAvailable: true, interaction: TurnInteractionState())
        XCTAssertEqual(rigAllSubviews(of: view).compactMap { $0 as? ToolGroupView }.count, 2)
        XCTAssertLessThanOrEqual(ToolGroupRowView.updateCount, 4, "one at creation and one with the final state, per group")
    }

    func testStreamingAGroupUpdatesItsRowOncePerArrivingBlock() {
        var turn = F.turn([.text(F.prose)], complete: false)
        let view = ChatTurnView(turn: turn, contentAvailable: true, interaction: TurnInteractionState())
        ToolGroupRowView.updateCount = 0
        for block in F.run(5) {
            turn.blocks.append(block)
            view.update(turn: turn)
        }
        XCTAssertLessThanOrEqual(ToolGroupRowView.updateCount, 2 * 10)
    }

    /// Toggling a focused row re-measures its turn, which detaches it; focus must come back
    /// so a second Space (or ↓) still reaches the row.
    func testAKeyboardFocusedRowKeepsFocusAcrossItsOwnToggleAndRemeasure() throws {
        let turn = F.turn([.text(F.prose)] + F.run(2, prefix: "a") + [.text("between")] + F.run(2, prefix: "b"))
        let rig = makeTranscriptRig(self, blocks: turn.blocks)
        let rows = rigAllSubviews(of: rig.turn).compactMap { $0 as? ToolGroupRowView }
        guard rows.count == 2 else { return XCTFail("expected two rows, got \(rows.count)") }
        XCTAssertTrue(rig.window.makeFirstResponder(rows[0]))

        rows[0].keyDown(with: keyEvent(Key.space, " ", in: rig.window))
        rig.relayout(width: 900)   // what ReplView.measure does next: detach, measure, reattach
        XCTAssertTrue(rows[0].isExpanded)
        XCTAssertTrue(rig.window.firstResponder === rows[0], "focus went to \(String(describing: rig.window.firstResponder))")

        rows[0].keyDown(with: keyEvent(Key.space, " ", in: rig.window))
        rig.relayout(width: 900)
        XCTAssertFalse(rows[0].isExpanded, "the second Space reached the row")
        XCTAssertTrue(rig.window.firstResponder === rows[0])

        rows[0].keyDown(with: keyEvent(Key.down, arrow(NSDownArrowFunctionKey), in: rig.window))
        XCTAssertTrue(rig.window.firstResponder === rows[1])
    }

    /// Collapsing must not leave a selection alive in hidden output, where ⌘C would copy it.
    func testCollapsingAGroupTakesFocusOutOfItsHiddenMembers() throws {
        let turn = F.turn([.text(F.prose)] + F.run(1, output: { _ in "HIDDEN-OUTPUT-SENTINEL and more" }))
        var state = TurnInteractionState()
        state.expandedBlocks = [2]
        let rig = makeTranscriptRig(self, blocks: turn.blocks, interaction: state,
                                    folds: FoldResolver(expandedByDefault: true))
        let group = try XCTUnwrap(rigAllSubviews(of: rig.turn).compactMap { $0 as? ToolGroupView }.first)
        let output = try XCTUnwrap(rigAllSubviews(of: group).compactMap { $0 as? NSTextField }
            .first { $0.stringValue.contains("HIDDEN-OUTPUT-SENTINEL") })
        output.selectText(nil)
        XCTAssertNotNil(output.currentEditor(), "the output holds a selection")

        group.row.toggle()
        XCTAssertFalse(group.isExpanded)
        let editorOwner = (rig.window.firstResponder as? NSTextView)?.delegate as? NSView
        XCTAssertFalse(editorOwner?.isDescendant(of: group) ?? false, "no field editor left in the hidden output")
    }

    func testModifiedArrowsDoNotToggle() {
        let window = makeRigWindow(self)
        let row = ToolGroupRowView(group: F.plainGroup(calls: 2), isExpanded: false, payloadAvailable: true)
        window.contentView?.addSubview(row)
        for flags: NSEvent.ModifierFlags in [.command, .option, .control] {
            row.keyDown(with: keyEvent(Key.right, arrow(NSRightArrowFunctionKey), in: window, flags: flags))
            XCTAssertFalse(row.isExpanded, "\(flags) → belongs to someone else")
        }
    }

    func testTheVirtualizerReusesACompletedTurnsFoldShapeUntilItsBlocksChange() {
        let virtualizer = TurnListVirtualizer()
        var turn = F.turn([.text(F.prose)] + F.run(3))
        let first = virtualizer.foldShape(for: turn)
        XCTAssertEqual(first, virtualizer.foldShape(for: turn))
        turn.blocks += [.text("more"), F.call(id: "z")]
        XCTAssertEqual(virtualizer.foldShape(for: turn)?.items.count, 3 + 1, "prose, group, prose, new group")
        XCTAssertNil(virtualizer.foldShape(for: F.turn([.text(F.prose)])), "nothing folds without tool calls")
    }
}
