import XCTest
import AppKit
import Combine
import NostromoKit

// FV4 (transcript Focus view): one mode per focus, Focus or All activity.
//
// Source of truth: the design contract (§0 D1, §1 F3-F6, §2.2, §2.4) and the PRD's toggle section.
//   - A new focus opens in Focus: every activity row and tool group starts collapsed.
//   - Switching mode SETS every fold of that focus (hand-opened and hand-closed ones included, and a
//     stuck group) to the new mode's state; afterwards manual toggles persist.
//   - The mode is keyed by the focus's session tag. It survives relaunch, daemon restart, Clear Context
//     and a new Claude session in the focus, and it is shared by every window on the focus.
//   - A global default applies only to focuses with no explicit choice.
//   - Claude's own `viewMode` is never sent to the agent.
//
// Part 1 (`FocusModeSyncTests`) drives TF3's `ScrollRig`, which owns the same `PaneFoldSync` that
// `ReplView` owns, over an injected `TranscriptFoldStore`. Two rigs built on one store and one tag are
// two windows on one focus. The store's `changes` is a synchronous subject, so every assertion about
// "the other window" is made right after the call, with no run-loop turn in between.
// Part 2 (`FocusModePaneTests`) drives real `ReplView`s (chip, menu radio, announcements).
//
// No wall clock, no real pasteboard / UserDefaults domain / ~/.nostromo: every store is a temp file with
// a private defaults suite and a scheduler this file fires by hand.

private typealias F = FoldFixtures
private typealias X = FocusFixtures

// MARK: - Shared helpers (also used by TranscriptViewMenuTests and the chip tests)

/// A scheduler that records the store's debounced write instead of running it; `fire()` runs what is pending.
final class FV4Scheduler {
    private final class Entry {
        let work: () -> Void
        var cancelled = false
        init(_ work: @escaping () -> Void) { self.work = work }
    }

    private var entries: [Entry] = []

    var scheduler: WorkScheduler {
        WorkScheduler { [self] _, work in
            let entry = Entry(work)
            entries.append(entry)
            return { entry.cancelled = true }
        }
    }

    var pendingCount: Int { entries.filter { !$0.cancelled }.count }

    func fire() {
        let live = entries.filter { !$0.cancelled }
        entries.removeAll()
        live.forEach { $0.work() }
    }
}

/// A fold store over a temp file and a private defaults suite (both removed at teardown), whose
/// debounced write only happens when a test flushes it. `relaunch()` is a fresh store over the same
/// file and defaults.
final class FV4StoreWorld {
    let url: URL
    let defaults: UserDefaults
    let scheduler = FV4Scheduler()
    private(set) var store: TranscriptFoldStore!

    init(_ testCase: XCTestCase) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fv4-mode-\(UUID().uuidString)")
        let suite = "fv4-mode-\(UUID().uuidString)"
        url = dir.appendingPathComponent("transcript-folds.v1.json")
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        testCase.addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        store = makeStore()
    }

    private func makeStore() -> TranscriptFoldStore {
        TranscriptFoldStore(fileURL: url, defaults: defaults, scheduler: scheduler.scheduler)
    }

    /// Run the pending debounced write and wait (bounded, no sleeping) for the file to land.
    func flush(_ testCase: XCTestCase, file: StaticString = #filePath, line: UInt = #line) {
        guard scheduler.pendingCount > 0 else {
            return XCTFail("expected a pending debounced write, but nothing was scheduled", file: file, line: line)
        }
        let done = testCase.expectation(description: "fold store write completed")
        done.assertForOverFulfill = false
        store.onWriteCompleted = { done.fulfill() }
        scheduler.fire()
        testCase.wait(for: [done], timeout: 10)
        store.onWriteCompleted = nil
    }

    /// The app launching again: a new store over the same file and defaults.
    @discardableResult
    func relaunch() -> TranscriptFoldStore {
        store = makeStore()
        return store
    }
}

/// A real transcript pane in `window` (as its content view, or as a subview of the current one).
/// Its fold state lives in `store`. The window is not shown to the operator (alpha 0).
func fv4MakePane(tag: String = "fv4-\(UUID().uuidString)", store: TranscriptFoldStore, in window: NSWindow,
                 frame: NSRect = NSRect(x: 0, y: 0, width: 900, height: 700), asContentView: Bool = true) -> ReplView {
    let repl = ReplView(tag: tag, foldStore: store)
    repl.frame = frame
    if asContentView {
        repl.autoresizingMask = [.width, .height]
        window.contentView = repl
    } else {
        window.contentView?.addSubview(repl)
    }
    return repl
}

/// Let AppKit lay a window's hierarchy out, a bounded number of main-loop turns.
func fv4Settle(_ window: NSWindow) {
    for _ in 0 ..< 3 {
        modelFlushMain(generations: 1)
        window.contentView?.layoutSubtreeIfNeeded()
    }
}

/// `<repo>`: this file is `<repo>/macOS/NostromoTests/<file>`.
func fv4RepoRoot(file: StaticString = #filePath) -> URL {
    var url = URL(fileURLWithPath: "\(file)")
    for _ in 0 ..< 3 { url.deleteLastPathComponent() }
    return url
}

func fv4SwiftFiles(under directory: URL) -> [URL] {
    guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else { return [] }
    return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
}

/// `source` without `/* */` blocks and without `//` (and `///`) comment text.
func fv4StrippingComments(_ source: String) -> String {
    let block = try! NSRegularExpression(pattern: "/\\*.*?\\*/", options: [.dotMatchesLineSeparators])
    let whole = NSRange(source.startIndex..., in: source)
    let noBlocks = block.stringByReplacingMatches(in: source, range: whole, withTemplate: "")
    return noBlocks.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        if let slashes = line.range(of: "//") { return String(line[..<slashes.lowerBound]) }
        return String(line)
    }.joined(separator: "\n")
}

/// The `{ ... }` text of every `func <name>` in `source` (brace counting: a textual heuristic).
func fv4FunctionBodies(named name: String, in source: String) -> [String] {
    var bodies: [String] = []
    var from = source.startIndex
    while let hit = source.range(of: "func \(name)", range: from ..< source.endIndex) {
        guard let open = source[hit.upperBound...].firstIndex(of: "{") else { break }
        var depth = 0
        var index = open
        var close: String.Index?
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 { close = index; break }
            }
            index = source.index(after: index)
        }
        guard let close else { break }
        bodies.append(String(source[open ... close]))
        from = source.index(after: close)
    }
    return bodies
}

// MARK: - Fixtures

private func fv4RowGroupKeys(_ n: Int) -> [String] { ["g:ra\(n)_0", "g:rb\(n)_0"] }
private func fv4GroupKey(_ n: Int) -> String { "g:ga\(n)_0" }
private func fv4StuckKey(_ n: Int) -> String { "g:s\(n)_0" }
private func fv4ActivityKey(of turn: ChatTurn) -> String { X.segments(of: turn).first?.key ?? "no-activity-row" }

/// Prompt, an activity row (two messages with calls between them), the conclusion, the chip.
private func fv4RowTurn(_ n: Int = 0) -> ChatTurn {
    F.turn([X.message("row\(n)-A")] + F.run(3, prefix: "ra\(n)_") + [X.message("row\(n)-B")]
           + F.run(2, prefix: "rb\(n)_") + [X.message("row\(n)-C"), F.chip()], user: "row turn \(n)")
}

/// A message, a top-level group of three calls (the middle one failed: its result opens by itself,
/// the others' are closed), the chip.
private func fv4GroupTurn(_ n: Int = 0) -> ChatTurn {
    var blocks: [TurnBlock] = [X.message("grp\(n)")]
    for i in 0 ..< 3 {
        let id = "ga\(n)_\(i)"
        blocks.append(F.call("Bash", id: id, summary: "cmd \(id)"))
        blocks.append(F.result("line a \(i)\nline b\nline c", id: id, isError: i == 1))
    }
    blocks.append(F.chip())
    return F.turn(blocks, user: "group turn \(n)")
}

/// A turn that ended in error whose last group failed: that group is stuck, so it opens by the
/// stuck rule even in Focus.
private func fv4StuckTurn(_ n: Int = 0) -> ChatTurn {
    F.turn([X.message("stuck\(n)")] + X.failingRun("s\(n)_", calls: 4) + [X.errorChip()], user: "stuck turn \(n)")
}

private func fv4Turns(_ n: Int = 0) -> [ChatTurn] { [fv4RowTurn(n), fv4GroupTurn(n), fv4StuckTurn(n)] }

/// The same turn re-delivered by a restarted daemon: same record (identity), new id and epoch.
private func fv4Reattached(_ turn: ChatTurn) -> ChatTurn {
    ChatTurn(userInput: turn.userInput, timestamp: turn.timestamp, timestampRaw: turn.timestampRaw,
             blocks: turn.blocks, isComplete: turn.isComplete, daemonId: "t99", epoch: 1,
             subagentTextParents: turn.subagentTextParents)
}

/// What is open in a rig built on `fv4Turns()`. A nil is "no view": a row's lane exists only while the
/// row is open, and a group's results only while the group is.
private struct FV4Open: Equatable {
    var row: Bool?
    var rowGroupA: Bool?
    var rowGroupB: Bool?
    var group: Bool?
    var stuck: Bool?
    var results: [Bool]

    /// A new focus: everything folded, apart from the stuck group the stuck rule opens.
    static let focus = FV4Open(row: false, rowGroupA: nil, rowGroupB: nil, group: false, stuck: true, results: [])
    /// Focus after a switch: the stuck group is closed too.
    static let focusSwitched = FV4Open(row: false, rowGroupA: nil, rowGroupB: nil, group: false, stuck: false, results: [])
    /// Every row and group open; the results at their defaults (only the failed call's is open).
    static let allActivity = FV4Open(row: true, rowGroupA: true, rowGroupB: true, group: true, stuck: true,
                                     results: [false, true, false])
}

private func fv4OpenState(_ rig: ScrollRig, n: Int = 0) -> FV4Open {
    guard rig.turns.count >= 3 else { return FV4Open(row: nil, rowGroupA: nil, rowGroupB: nil, group: nil, stuck: nil, results: []) }
    let rowTurn = rig.turns[0], groupTurn = rig.turns[1], stuckTurn = rig.turns[2]
    let lane = fv4RowGroupKeys(n)
    return FV4Open(row: rig.activityRow(turn: rowTurn.id, key: fv4ActivityKey(of: rowTurn))?.isExpanded,
                   rowGroupA: rig.groupView(turn: rowTurn.id, key: lane[0])?.isExpanded,
                   rowGroupB: rig.groupView(turn: rowTurn.id, key: lane[1])?.isExpanded,
                   group: rig.groupView(turn: groupTurn.id, key: fv4GroupKey(n))?.isExpanded,
                   stuck: rig.groupView(turn: stuckTurn.id, key: fv4StuckKey(n))?.isExpanded,
                   results: fv4ResultStates(rig.groupView(turn: groupTurn.id, key: fv4GroupKey(n))))
}

private func fv4ResultButton(_ group: ToolGroupView?, at index: Int) -> NSButton? {
    guard let group else { return nil }
    let buttons = group.memberViews.compactMap { $0 as? ToolResultView }.compactMap { view in
        rigAllSubviews(of: view).compactMap { $0 as? NSButton }.first
    }
    return buttons.indices.contains(index) ? buttons[index] : nil
}

/// Open (true) or closed, per result of the group, in order.
private func fv4ResultStates(_ group: ToolGroupView?) -> [Bool] {
    guard let group else { return [] }
    return group.memberViews.compactMap { $0 as? ToolResultView }.compactMap { view in
        rigAllSubviews(of: view).compactMap { $0 as? NSButton }.first.map { $0.title.hasPrefix("\u{25BC}") }
    }
}

/// Drop every turn view and rebuild what the window needs: what scrolling away and back does.
private func fv4Evict(_ rig: ScrollRig) {
    for view in rig.materialized.values { view.removeFromSuperview() }
    rig.materialized.removeAll()
    rig.runPass()
}

// MARK: - Part 1: the store and the panes' shared state

final class FocusModeSyncTests: XCTestCase {

    private let tall = NSSize(width: 900, height: 3000)

    private func makeRig(_ turns: [ChatTurn]? = nil, store: TranscriptFoldStore, tag: String = "fv4-a",
                         file: StaticString = #filePath, line: UInt = #line) -> ScrollRig {
        let rig = ScrollRig(self, turns: turns ?? fv4Turns(), size: tall, foldStore: store, tag: tag)
        rig.start()
        XCTAssertEqual(rig.materialized.count, rig.turns.count, "precondition: every turn has a view", file: file, line: line)
        return rig
    }

    // MARK: A new focus

    func testANewFocusOpensInFocusWithEveryFoldClosedExceptAStuckGroup() {
        let world = FV4StoreWorld(self)
        let rig = makeRig(store: world.store)

        XCTAssertNil(world.store.explicitMode(tag: "fv4-a"), "no choice has been made")
        XCTAssertEqual(rig.sync.mode, .focus)
        XCTAssertEqual(fv4OpenState(rig), .focus)
    }

    // MARK: Show All Activity

    func testShowAllActivityOpensEveryRowAndGroupInThatFocusAndInNoOtherFocus() {
        let world = FV4StoreWorld(self)
        let a = makeRig(store: world.store, tag: "fv4-a")
        let other = makeRig(fv4Turns(), store: world.store, tag: "fv4-other")

        a.sync.setMode(.allActivity)

        XCTAssertEqual(fv4OpenState(a), .allActivity)
        XCTAssertEqual(a.sync.mode, .allActivity)
        XCTAssertEqual(fv4OpenState(other), .focus, "another focus is untouched")
        XCTAssertEqual(other.sync.mode, .focus)
        XCTAssertNil(world.store.explicitMode(tag: "fv4-other"))
        XCTAssertEqual(world.store.explicitMode(tag: "fv4-a"), .allActivity)
    }

    func testRowsAndGroupsThatArriveAfterShowAllActivityStartOpen() {
        let world = FV4StoreWorld(self)
        let rig = makeRig(store: world.store)
        rig.sync.setMode(.allActivity)
        let lateRow = fv4RowTurn(7), lateGroup = fv4GroupTurn(8)

        rig.appendTurn(lateRow)
        rig.appendTurn(lateGroup)

        XCTAssertNotNil(rig.materialized[lateRow.id], "precondition: the new turns are on screen")
        XCTAssertNotNil(rig.materialized[lateGroup.id])
        XCTAssertEqual(rig.activityRow(turn: lateRow.id, key: fv4ActivityKey(of: lateRow))?.isExpanded, true)
        for key in fv4RowGroupKeys(7) {
            XCTAssertEqual(rig.groupView(turn: lateRow.id, key: key)?.isExpanded, true, "\(key) arrived open")
        }
        XCTAssertEqual(rig.groupView(turn: lateGroup.id, key: fv4GroupKey(8))?.isExpanded, true)
    }

    func testSwitchingModeLeavesResultFoldsAsTheyWere() {
        let world = FV4StoreWorld(self)
        let rig = makeRig(store: world.store)
        let groupTurn = rig.turns[1]
        rig.sync.setMode(.allActivity)
        XCTAssertEqual(fv4OpenState(rig).results, [false, true, false], "precondition: only the failed call's result is open")

        // The operator opens one result and closes the failed one's.
        let first = fv4ResultButton(rig.groupView(turn: groupTurn.id, key: fv4GroupKey(0)), at: 0)
        first?.performClick(nil)
        rig.runPass()
        let failed = fv4ResultButton(rig.groupView(turn: groupTurn.id, key: fv4GroupKey(0)), at: 1)
        failed?.performClick(nil)
        rig.runPass()
        XCTAssertEqual(fv4OpenState(rig).results, [true, false, false], "precondition: the hand changes took")

        rig.sync.setMode(.focus)
        XCTAssertEqual(fv4OpenState(rig).results, [], "the group is closed: no result is on screen")
        rig.sync.setMode(.allActivity)

        XCTAssertEqual(fv4OpenState(rig).results, [true, false, false],
                       "a mode switch sets rows and groups, not result folds: the hand choices stand")
    }

    // MARK: Focus

    func testFocusClosesEveryFoldIncludingHandOpenedOnesAndAStuckGroup() {
        let world = FV4StoreWorld(self)
        let rig = makeRig(store: world.store)
        rig.toggleActivityRow(turn: rig.turns[0].id, key: fv4ActivityKey(of: rig.turns[0]))
        rig.toggleRow(turn: rig.turns[1].id, key: fv4GroupKey(0))
        let before = fv4OpenState(rig)
        XCTAssertEqual(before.row, true, "precondition: the row was opened by hand")
        XCTAssertEqual(before.group, true, "precondition: the group was opened by hand")
        XCTAssertEqual(before.stuck, true, "precondition: the stuck rule has the stuck group open")

        rig.sync.setMode(.focus)

        XCTAssertEqual(fv4OpenState(rig), .focusSwitched, "hand-opened and stuck folds close too")
        XCTAssertEqual(world.store.explicitMode(tag: "fv4-a"), .focus, "an explicit choice, even though Focus is the default")
    }

    func testAllActivityOpensTheStuckGroupExplicitlyAndAHandClosedOneStaysClosed() {
        let world = FV4StoreWorld(self)
        let rig = makeRig(store: world.store)
        rig.sync.setMode(.focus)
        XCTAssertEqual(fv4OpenState(rig).stuck, false, "precondition")

        rig.sync.setMode(.allActivity)
        XCTAssertEqual(fv4OpenState(rig).stuck, true)

        rig.toggleRow(turn: rig.turns[2].id, key: fv4StuckKey(0))
        XCTAssertEqual(fv4OpenState(rig).stuck, false, "the operator closed it")
        fv4Evict(rig)
        XCTAssertEqual(fv4OpenState(rig).stuck, false, "and it stays closed after the view was rebuilt")
    }

    func testSwitchingToTheModeAFocusIsAlreadyInStillResetsEveryHandChange() {
        let world = FV4StoreWorld(self)
        let rig = makeRig(store: world.store)
        rig.sync.setMode(.allActivity)
        rig.toggleRow(turn: rig.turns[1].id, key: fv4GroupKey(0))   // closed by hand
        XCTAssertEqual(fv4OpenState(rig).group, false, "precondition")

        rig.sync.setMode(.allActivity)

        XCTAssertEqual(fv4OpenState(rig), .allActivity, "Show All Activity sets every fold, hand-closed ones too")
    }

    // MARK: Manual folds afterwards

    func testManualTogglesAfterASwitchPersistAcrossEvictionAndAFullReset() {
        let world = FV4StoreWorld(self)
        let rig = makeRig(store: world.store)
        rig.sync.setMode(.allActivity)
        rig.toggleRow(turn: rig.turns[1].id, key: fv4GroupKey(0))                              // a group closed
        rig.toggleActivityRow(turn: rig.turns[0].id, key: fv4ActivityKey(of: rig.turns[0]))     // a row closed
        let expected = FV4Open(row: false, rowGroupA: nil, rowGroupB: nil, group: false, stuck: true, results: [])
        XCTAssertEqual(fv4OpenState(rig), expected, "precondition")

        fv4Evict(rig)
        XCTAssertEqual(fv4OpenState(rig), expected, "scrolling away and back keeps the hand choices")

        rig.virtualizer.reset(turns: rig.turns, width: rig.contentWidth)   // what a pane resize does
        fv4Evict(rig)
        XCTAssertEqual(fv4OpenState(rig), expected, "a full re-layout keeps them too")
    }

    func testAHandOpenedRowGroupAndResultSurviveARebuildOfTheViews() {
        let world = FV4StoreWorld(self)
        let rig = makeRig(store: world.store)
        rig.toggleActivityRow(turn: rig.turns[0].id, key: fv4ActivityKey(of: rig.turns[0]))
        rig.toggleRow(turn: rig.turns[1].id, key: fv4GroupKey(0))
        fv4ResultButton(rig.groupView(turn: rig.turns[1].id, key: fv4GroupKey(0)), at: 0)?.performClick(nil)
        rig.runPass()
        let expected = FV4Open(row: true, rowGroupA: false, rowGroupB: false, group: true, stuck: true,
                               results: [true, true, false])
        XCTAssertEqual(fv4OpenState(rig), expected, "precondition")

        fv4Evict(rig)

        XCTAssertEqual(fv4OpenState(rig), expected)
    }

    // MARK: Show All is every block, in order

    private func assertShowAllHoldsEveryBlockInOrder(_ turns: [ChatTurn], file: StaticString = #filePath, line: UInt = #line) {
        let world = FV4StoreWorld(self)
        world.store.setMode(tag: "fv4-equality", .allActivity)
        let sync = PaneFoldSync(tag: "fv4-equality", store: world.store)
        for turn in turns {
            let view = X.view(turn, folds: sync.resolver(turnKey: turn.identityKey))
            let tokens = X.contentTokens(of: view)

            XCTAssertEqual(tokens.filter { $0 != "row" }, X.expectedContentTokens(of: turn),
                           "\(turn.identityKey): All activity must show every block the transcript had, in order",
                           file: file, line: line)
            XCTAssertTrue(view.activityRowViews.allSatisfy(\.isExpanded), "\(turn.identityKey): every row is open",
                          file: file, line: line)
        }
    }

    func testAllActivityShowsEveryBlockOfTheBenchmarkSessionInOrder() throws {
        assertShowAllHoldsEveryBlockInOrder(Array(try F.benchmarkTurns().suffix(40)))
    }

    func testAllActivityShowsEveryBlockOfEveryFocusScenarioInOrder() throws {
        let scenarios = Array(try X.focusScenarioTurns().prefix(FocusScenario.allCases.count))
        XCTAssertEqual(scenarios.count, FocusScenario.allCases.count, "precondition: one turn per scenario")
        assertShowAllHoldsEveryBlockInOrder(scenarios)
    }

    // MARK: Persistence

    func testTheModeSurvivesARelaunch() {
        let world = FV4StoreWorld(self)
        world.store.setMode(tag: "fv4-a", .allActivity)
        world.store.setMode(tag: "fv4-b", .focus)
        world.flush(self)

        let reopened = world.relaunch()

        XCTAssertEqual(reopened.explicitMode(tag: "fv4-a"), .allActivity)
        XCTAssertEqual(reopened.explicitMode(tag: "fv4-b"), .focus, "an explicit Focus stays explicit")
        XCTAssertNil(reopened.explicitMode(tag: "fv4-never"))
        let rig = makeRig(store: reopened, tag: "fv4-a")
        XCTAssertEqual(fv4OpenState(rig), .allActivity, "a pane opened after the relaunch shows the saved mode")
    }

    func testManualFoldsAndTheModeSurviveARelaunchAndTheTurnsComingBackWithANewEpoch() {
        let world = FV4StoreWorld(self)
        let rig = makeRig(store: world.store)
        rig.toggleActivityRow(turn: rig.turns[0].id, key: fv4ActivityKey(of: rig.turns[0]))
        rig.toggleRow(turn: rig.turns[1].id, key: fv4GroupKey(0))
        fv4ResultButton(rig.groupView(turn: rig.turns[1].id, key: fv4GroupKey(0)), at: 0)?.performClick(nil)
        rig.runPass()
        world.flush(self)

        let reopened = world.relaunch()
        let again = ScrollRig(self, turns: fv4Turns().map(fv4Reattached), size: tall, foldStore: reopened, tag: "fv4-a")
        again.start()

        XCTAssertEqual(fv4OpenState(again),
                       FV4Open(row: true, rowGroupA: false, rowGroupB: false, group: true, stuck: true, results: [true, true, false]),
                       "same records under new ids: the choices follow the records")
    }

    func testTheModeAndManualFoldsSurviveADaemonRestartInTheSameProcess() {
        let world = FV4StoreWorld(self)
        let rig = makeRig(store: world.store)
        rig.sync.setMode(.allActivity)
        rig.toggleRow(turn: rig.turns[1].id, key: fv4GroupKey(0))   // closed by hand

        let restarted = ScrollRig(self, turns: fv4Turns().map(fv4Reattached), size: tall, foldStore: world.store, tag: "fv4-a")
        restarted.start()

        XCTAssertEqual(restarted.sync.mode, .allActivity)
        XCTAssertEqual(fv4OpenState(restarted),
                       FV4Open(row: true, rowGroupA: true, rowGroupB: true, group: false, stuck: true, results: []))
    }

    // MARK: Clear Context never touches the store

    func testNothingInTheClearContextPathTouchesTheFoldStore() throws {
        let root = fv4RepoRoot()
        let repl = fv4StrippingComments(try String(contentsOf: root.appendingPathComponent("macOS/Nostromo/UI/Views/ReplView.swift"),
                                                   encoding: .utf8))
        let start = try XCTUnwrap(repl.range(of: "case .cleared:"), "ReplView handles .cleared")
        let end = try XCTUnwrap(repl.range(of: "case .spliced", range: start.upperBound ..< repl.endIndex))
        let cleared = String(repl[start.upperBound ..< end.lowerBound])
        let chat = fv4StrippingComments(try String(contentsOf: root.appendingPathComponent("macOS/Nostromo/Data/ChatSession.swift"),
                                                   encoding: .utf8))
        let newSession = try XCTUnwrap(fv4FunctionBodies(named: "newSession()", in: chat).first)

        for forbidden in ["foldSync", "TranscriptFoldStore", "clearMode", "removeFocus", "setMode", "pinStuck"] {
            XCTAssertFalse(cleared.contains(forbidden), "ReplView's .cleared handling must not touch fold state (\(forbidden))")
            XCTAssertFalse(newSession.contains(forbidden), "ChatSession.newSession() must not touch fold state (\(forbidden))")
        }
    }

    func testASpliceFromTheStartForgetsChoicesAboutTurnsNoLongerHeld() {
        let world = FV4StoreWorld(self)
        let store: TranscriptFoldStore = world.store
        let sync = PaneFoldSync(tag: "fv4-a", store: store)
        sync.recordFold(key: "g:old", turnKey: "old-turn", open: true)
        sync.recordFold(key: "g:kept", turnKey: "kept-turn", open: true)
        sync.recordResult(key: "r:old", turnKey: "old-turn", open: true)
        sync.recordResult(key: "r:kept", turnKey: "kept-turn", open: true)
        store.pinStuck(tag: "fv4-a", keys: ["g:pinned"], open: true)

        sync.prune(keepingTurnKeys: ["kept-turn"])

        XCTAssertNil(store.foldState(tag: "fv4-a", key: "g:old"))
        XCTAssertNil(store.resultState(tag: "fv4-a", key: "r:old"))
        XCTAssertEqual(store.foldState(tag: "fv4-a", key: "g:kept")?.open, true)
        XCTAssertEqual(store.resultState(tag: "fv4-a", key: "r:kept"), true)
        XCTAssertEqual(store.foldState(tag: "fv4-a", key: "g:pinned")?.open, true, "a pin belongs to no turn: only the LRU bound removes it")
    }

    // MARK: The global default

    func testTheDefaultOnlyMovesFocusesWithNoChoiceOfTheirOwn() {
        let world = FV4StoreWorld(self)
        world.store.setMode(tag: "fv4-explicit", .focus)
        let follower = makeRig(store: world.store, tag: "fv4-follower")
        let explicit = makeRig(fv4Turns(), store: world.store, tag: "fv4-explicit")

        world.store.defaultMode = .allActivity

        XCTAssertEqual(follower.sync.mode, .allActivity)
        XCTAssertEqual(fv4OpenState(follower), .allActivity, "a focus with no choice follows the default")
        XCTAssertNil(world.store.explicitMode(tag: "fv4-follower"), "following the default is not a choice")
        XCTAssertEqual(explicit.sync.mode, .focus)
        XCTAssertEqual(fv4OpenState(explicit), .focus, "a focus with an explicit Focus stays in Focus")
    }

    func testTheDefaultSurvivesARelaunchAndIsKeptByFocusesThatChoseOtherwise() {
        let world = FV4StoreWorld(self)
        world.store.setMode(tag: "fv4-explicit", .focus)
        world.store.defaultMode = .allActivity
        world.flush(self)

        let reopened = world.relaunch()

        XCTAssertEqual(reopened.defaultMode, .allActivity)
        XCTAssertEqual(reopened.mode(tag: "fv4-follower"), .allActivity)
        XCTAssertEqual(reopened.mode(tag: "fv4-explicit"), .focus)
    }

    func testChangingTheDefaultWhileScrolledUpDoesNotMoveTheFirstVisibleLine() throws {
        let world = FV4StoreWorld(self)
        let rig = ScrollRig(self, turns: longTranscript(), foldStore: world.store, tag: "fv4-a")
        rig.start()
        let target = rig.turns[4].id
        XCTAssertNotNil(rig.placeRow(turn: target, key: "g:L4_0", atScreenY: -60))
        let probe = try XCTUnwrap(rig.probe())
        XCTAssertEqual(probe.landmark.turnID, target, "precondition: the first visible item is in the turn whose group is above it")
        XCTAssertFalse(rig.followTail.isPinned)

        world.store.defaultMode = .allActivity

        XCTAssertEqual(rig.groupView(turn: target, key: "g:L4_0")?.isExpanded, true, "the focus followed the default")
        assertStill(rig, probe, "after the default changed under a focus with no choice")
    }

    // MARK: Two windows, one focus

    func testAModeSwitchInOneWindowReachesTheOtherInTheSameCall() {
        let world = FV4StoreWorld(self)
        let a = makeRig(store: world.store, tag: "fv4-a")
        let b = makeRig(fv4Turns(), store: world.store, tag: "fv4-a")

        a.sync.setMode(.allActivity)
        // No run-loop turn: the other window has applied it by the time the call returns.
        XCTAssertEqual(fv4OpenState(b), .allActivity)
        XCTAssertEqual(b.sync.mode, .allActivity)

        a.sync.setMode(.focus)
        XCTAssertEqual(fv4OpenState(b), .focusSwitched)
        XCTAssertEqual(b.sync.mode, .focus)
    }

    func testAToggleOfOneRowOrGroupOrResultInOneWindowReachesTheOtherInTheSameCall() {
        let world = FV4StoreWorld(self)
        let a = makeRig(store: world.store, tag: "fv4-a")
        let b = makeRig(fv4Turns(), store: world.store, tag: "fv4-a")

        a.toggleRow(turn: a.turns[1].id, key: fv4GroupKey(0))
        XCTAssertEqual(fv4OpenState(b).group, true, "a group opened in A is open in B")
        XCTAssertEqual(b.groupToggles, [], "it is not B's operator toggle")

        a.toggleActivityRow(turn: a.turns[0].id, key: fv4ActivityKey(of: a.turns[0]))
        XCTAssertEqual(fv4OpenState(b).row, true, "a row opened in A is open in B")

        fv4ResultButton(a.groupView(turn: a.turns[1].id, key: fv4GroupKey(0)), at: 0)?.performClick(nil)
        a.runPass()
        XCTAssertEqual(fv4OpenState(b).results, [true, true, false], "a result opened in A is open in B")

        a.toggleRow(turn: a.turns[1].id, key: fv4GroupKey(0))
        XCTAssertEqual(fv4OpenState(b).group, false, "and closing it closes it in B")
    }

    func testAModeSwitchInOneWindowDoesNotMoveTheOtherWindowsFirstVisibleLineWhenItIsScrolledUp() throws {
        let world = FV4StoreWorld(self)
        let a = ScrollRig(self, turns: longTranscript(), foldStore: world.store, tag: "fv4-a")
        let b = ScrollRig(self, turns: longTranscript(), foldStore: world.store, tag: "fv4-a")
        a.start()
        b.start()
        let target = b.turns[4].id
        XCTAssertNotNil(b.placeRow(turn: target, key: "g:L4_0", atScreenY: -60))
        let probe = try XCTUnwrap(b.probe())
        XCTAssertEqual(probe.landmark.turnID, target, "precondition")
        XCTAssertFalse(b.followTail.isPinned)

        a.sync.setMode(.allActivity)

        XCTAssertEqual(b.groupView(turn: target, key: "g:L4_0")?.isExpanded, true)
        assertStill(b, probe, "after the other window switched to All activity")
        XCTAssertFalse(b.followTail.isPinned, "a switch elsewhere never re-pins a reader")
    }

    func testARowToggledInOneWindowDoesNotMoveTheOtherWindowsFirstVisibleLineWhenItIsScrolledUp() throws {
        let world = FV4StoreWorld(self)
        let a = ScrollRig(self, turns: longTranscript(), foldStore: world.store, tag: "fv4-a")
        let b = ScrollRig(self, turns: longTranscript(), foldStore: world.store, tag: "fv4-a")
        a.start()
        b.start()
        XCTAssertNotNil(a.placeRow(turn: a.turns[4].id, key: "g:L4_0", atScreenY: 100))
        let target = b.turns[4].id
        XCTAssertNotNil(b.placeRow(turn: target, key: "g:L4_0", atScreenY: -60))
        let probe = try XCTUnwrap(b.probe())
        XCTAssertEqual(probe.landmark.turnID, target, "precondition")

        a.toggleRow(turn: a.turns[4].id, key: "g:L4_0")

        XCTAssertEqual(b.groupView(turn: target, key: "g:L4_0")?.isExpanded, true)
        assertStill(b, probe, "after the other window opened a group above this window's viewport")
    }

    func testAModeSwitchInOneWindowKeepsAPinnedWindowAtTheBottom() {
        let world = FV4StoreWorld(self)
        let a = ScrollRig(self, turns: longTranscript(), foldStore: world.store, tag: "fv4-a")
        let b = ScrollRig(self, turns: longTranscript(), foldStore: world.store, tag: "fv4-a")
        a.start()
        b.start()
        XCTAssertTrue(b.followTail.isPinned, "precondition")

        a.sync.setMode(.allActivity)
        XCTAssertTrue(b.followTail.isPinned)
        XCTAssertLessThanOrEqual(b.gapBelowViewport, 0.5, "B still ends at the true bottom")

        a.sync.setMode(.focus)
        XCTAssertTrue(b.followTail.isPinned)
        XCTAssertLessThanOrEqual(b.gapBelowViewport, 0.5)
    }

    // MARK: Claude's own viewMode is never sent

    func testClaudesViewModeIsNeverSentToTheAgent() throws {
        // `NostromodClient` has no outbound-message tap, so this is a source scan: no identifier or
        // string named `viewMode` (a whole word: `viewModel` is everywhere) outside comments, in the app
        // or in NostromoKit. A frame carrying it would have to be built from one of them.
        let root = fv4RepoRoot()
        let directories = [root.appendingPathComponent("macOS/Nostromo"),
                           root.appendingPathComponent("Shared/NostromoKit/Sources")]
        let word = try NSRegularExpression(pattern: "\\bviewMode\\b")
        var scanned = 0
        var hits: [String] = []
        for directory in directories {
            for url in fv4SwiftFiles(under: directory) {
                let code = fv4StrippingComments(try String(contentsOf: url, encoding: .utf8))
                scanned += 1
                if word.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil { hits.append(url.lastPathComponent) }
            }
        }
        XCTAssertGreaterThan(scanned, 100, "precondition: the scan found the sources")
        XCTAssertEqual(hits, [], "`viewMode` must never be sent to the agent")
    }
}

// MARK: - Part 2: real panes

final class FocusModePaneTests: XCTestCase {
    private let windows = WindowBag()
    private var announced: [String: [String]] = [:]

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        announced = [:]
    }

    override func tearDown() {
        windows.tearDown()
        super.tearDown()
    }

    private func makePane(store: TranscriptFoldStore, tag: String = "fv4-\(UUID().uuidString)", name: String = "pane",
                          x: CGFloat = 100, y: CGFloat = 300) -> (repl: ReplView, window: NSWindow) {
        let window = windows.make(width: 900, height: 700, x: x, y: y)
        let repl = fv4MakePane(tag: tag, store: store, in: window)
        repl.announceModeChange = { [weak self] text in self?.announced[name, default: []].append(text) }
        window.alphaValue = 0
        window.orderFront(nil)
        fv4Settle(window)
        return (repl, window)
    }

    private func viewMenuItems() throws -> (focus: NSMenuItem, allActivity: NSMenuItem) {
        let main = MainMenu.make(target: nil)
        let view = try XCTUnwrap(main.items.first { $0.submenu?.title == TranscriptViewMenu.menuTitle }?.submenu)
        return (try XCTUnwrap(view.item(withTitle: TranscriptViewMenu.focusTitle)),
                try XCTUnwrap(view.item(withTitle: TranscriptViewMenu.allActivityTitle)))
    }

    func testANewFocusReadsFocusInTheChipAndHasFocusCheckedInTheMenu() throws {
        let world = FV4StoreWorld(self)
        let (pane, _) = makePane(store: world.store)
        let items = try viewMenuItems()

        XCTAssertEqual(pane.transcriptModeChip.title, "Focus")
        XCTAssertFalse(pane.transcriptShowsAllActivity)
        XCTAssertTrue(pane.validateMenuItem(items.focus))
        XCTAssertTrue(pane.validateMenuItem(items.allActivity))
        XCTAssertEqual(items.focus.state, .on)
        XCTAssertEqual(items.allActivity.state, .off)
    }

    func testTheChipAndTheMenuToggleTheSameStateAndStayInSync() throws {
        let world = FV4StoreWorld(self)
        let tag = "fv4-\(UUID().uuidString)"
        let (pane, window) = makePane(store: world.store, tag: tag)
        let items = try viewMenuItems()
        let chip = pane.transcriptModeChip

        // A click on the chip.
        XCTAssertTrue(chip.sendAction(chip.action, to: chip.target))
        XCTAssertEqual(world.store.explicitMode(tag: tag), .allActivity)
        XCTAssertEqual(chip.title, "All activity")
        XCTAssertTrue(pane.transcriptShowsAllActivity)
        _ = pane.validateMenuItem(items.focus)
        _ = pane.validateMenuItem(items.allActivity)
        XCTAssertEqual(items.focus.state, .off)
        XCTAssertEqual(items.allActivity.state, .on)

        // The menu's action, walked down the responder chain from the composer.
        XCTAssertTrue(window.makeFirstResponder(pane.composerBar.textView))
        let handled = window.firstResponder?.tryToPerform(TranscriptViewMenu.focusAction, with: items.focus)
        XCTAssertEqual(handled, true, "the pane catches the action")
        XCTAssertEqual(world.store.explicitMode(tag: tag), .focus)
        XCTAssertEqual(chip.title, "Focus")
        XCTAssertEqual(chip.accessibilityLabel(), TranscriptModeChip.accessibilityLabel(for: .focus))
        _ = pane.validateMenuItem(items.focus)
        _ = pane.validateMenuItem(items.allActivity)
        XCTAssertEqual(items.focus.state, .on)
        XCTAssertEqual(items.allActivity.state, .off)

        XCTAssertEqual(announced["pane"], ["Showing all activity", "Focus: activity folded"],
                       "each switch is announced once, in words")
    }

    func testAnnouncingIsDoneOnlyByThePaneThatPerformedTheToggle() {
        let world = FV4StoreWorld(self)
        let tag = "fv4-\(UUID().uuidString)"
        let a = makePane(store: world.store, tag: tag, name: "A", x: 100, y: 500)
        let b = makePane(store: world.store, tag: tag, name: "B", x: 100, y: 300)

        a.repl.setTranscriptAllActivityMode(nil)

        // Same call, no run-loop turn: the other window's chip and mode already follow.
        XCTAssertEqual(b.repl.transcriptModeChip.title, "All activity")
        XCTAssertTrue(b.repl.transcriptShowsAllActivity)
        XCTAssertEqual(announced["A"], ["Showing all activity"])
        XCTAssertNil(announced["B"], "the other window says nothing")

        b.repl.setTranscriptFocusMode(nil)
        XCTAssertEqual(a.repl.transcriptModeChip.title, "Focus")
        XCTAssertEqual(announced["A"], ["Showing all activity"])
        XCTAssertEqual(announced["B"], ["Focus: activity folded"])
    }

    func testAnotherFocusesChipIsLeftAlone() {
        let world = FV4StoreWorld(self)
        let a = makePane(store: world.store, name: "A")
        let other = makePane(store: world.store, name: "other", x: 100, y: 100)

        a.repl.setTranscriptAllActivityMode(nil)

        XCTAssertEqual(other.repl.transcriptModeChip.title, "Focus")
        XCTAssertFalse(other.repl.transcriptShowsAllActivity)
        XCTAssertNil(announced["other"])
    }

    func testTheDefaultMovesAChipThatHasNoChoiceAndLeavesAnExplicitOne() {
        let world = FV4StoreWorld(self)
        let explicitTag = "fv4-explicit-\(UUID().uuidString)"
        world.store.setMode(tag: explicitTag, .focus)
        let follower = makePane(store: world.store, name: "follower")
        let explicit = makePane(store: world.store, tag: explicitTag, name: "explicit", x: 100, y: 100)

        world.store.defaultMode = .allActivity

        XCTAssertEqual(follower.repl.transcriptModeChip.title, "All activity")
        XCTAssertTrue(follower.repl.transcriptShowsAllActivity)
        XCTAssertEqual(explicit.repl.transcriptModeChip.title, "Focus")
        XCTAssertFalse(explicit.repl.transcriptShowsAllActivity)
        XCTAssertNil(announced["follower"], "a change of the default is not a toggle in this pane")
    }

    func testClearContextAndANewClaudeSessionKeepTheModeTheChipAndTheFolds() throws {
        let world = FV4StoreWorld(self)
        let tag = "fv4-clear-\(UUID().uuidString)"
        let (pane, _) = makePane(store: world.store, tag: tag)
        pane.setTranscriptAllActivityMode(nil)
        world.store.setFold(tag: tag, key: "g:kept", turnKey: "turn-1", open: true, origin: .user)
        world.store.setResult(tag: tag, key: "r:kept", turnKey: "turn-1", open: true)
        // The pane's own session (the shared registry hands the same one out). The client is never
        // started in a test process, so what it would send goes nowhere.
        let session = AppStore.shared.session(for: tag)

        session.newSession()
        modelFlushMain()
        session.newSession()   // and again: a new Claude session in the same focus
        modelFlushMain()

        XCTAssertEqual(world.store.explicitMode(tag: tag), .allActivity)
        XCTAssertEqual(pane.transcriptModeChip.title, "All activity")
        XCTAssertTrue(pane.transcriptShowsAllActivity)
        XCTAssertEqual(world.store.foldState(tag: tag, key: "g:kept")?.open, true, "nothing is cleared on .cleared")
        XCTAssertEqual(world.store.resultState(tag: tag, key: "r:kept"), true)
    }

    func testAPerriStyleNewSessionInTheSameTagKeepsItsMode() {
        let world = FV4StoreWorld(self)
        let tag = "perri-fv4-\(UUID().uuidString)"
        let (pane, _) = makePane(store: world.store, tag: tag)
        world.store.setMode(tag: tag, .allActivity)

        AppStore.shared.session(for: tag).newSession()
        modelFlushMain()

        XCTAssertEqual(world.store.explicitMode(tag: tag), .allActivity)
        XCTAssertEqual(pane.transcriptModeChip.title, "All activity")
    }
}
