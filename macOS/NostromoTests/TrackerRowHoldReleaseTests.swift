import XCTest
import AppKit
import NostromoKit

// When a held tracker row goes away, and what `tracker show` says about one (fix/tracker-row-hold-and-less).
//
// A finished item that the agent moves to "Done today" while the reader is looking at it stays where it
// is, struck through (PRD 18). Before this fix it stayed until it scrolled out of view, the pane was
// reopened or the Done group was clicked, so a short board in a tall pane kept it forever. The release
// rule these tests pin down:
//
//  - Idle: a pane with held rows checks, once per idle period, whether anything happened in it. With no
//    pointer, scroll or key activity since the check was armed, and no text selected, and the pointer not
//    on a held row, everything held is released; otherwise the check tries again one period later.
//  - A click in the pane, a selection clearing and "less" release held rows too, under the same two
//    protections (a selection, the pointer on a held row), "less" being an explicit request.
//  - A release never moves what the reader is looking at: with a selection or the pointer on a held row
//    nothing moves at all; a row released above the viewport leaves the reading position where it was.
//
// `tracker show` explains a held row: `held_reason` says why it is held and names the section the
// board put the item in (`model_section`); the item's entry in the folded Done group says the same.
//
// The pane gets its own idle scheduler (a manual one that never re-runs what the fired work re-arms),
// a pointer the test places, and a short idle delay; the highlight scheduler, clock and pasteboard are
// the rig's. Boards come from `TrackerHoldBoard` (TrackerRowHoldTests.swift). No timers, no wall clock.
//
// This file uses the pane's release API (`idleReleaseDelay`, `idleSchedule`, `pointerLocation`,
// `registerActivity()`, `registerClick()`) and the report's `held_reason` and `model_section`.

/// The pane's idle scheduler: collects what is armed and runs it on demand, once.
final class TrackerIdleScheduler {
    private(set) var delays: [TimeInterval] = []
    private var armed: [() -> Void] = []

    func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        delays.append(delay)
        armed.append(work)
    }

    var armedCount: Int { armed.count }

    /// Run what is armed now. Work that re-arms itself waits for the next `fire()`.
    func fire() {
        let batch = armed
        armed = []
        batch.forEach { $0() }
    }
}

/// Where the pointer is, in window coordinates; nil when unknown.
final class TrackerTestPointer {
    var location: NSPoint? = NSPoint(x: -5000, y: -5000)
}

final class TrackerRowHoldReleaseTests: XCTestCase {

    private typealias Hold = TrackerHoldBoard
    private typealias Fx = TrackerHoldFx

    private static let idleDelay: TimeInterval = 7
    private static let faraway = NSPoint(x: -5000, y: -5000)

    private struct Scene {
        let rig: TrackerPaneRig
        let idle: TrackerIdleScheduler
        let pointer: TrackerTestPointer
        var board: TrackerHoldBoard
        var pane: TrackerPaneView { rig.pane }
    }

    private func makeScene(size: NSSize = NSSize(width: 360, height: 320)) -> Scene {
        let tag = TrackerPaneFx.uniqueTag()
        let store = TrackerPaneFx.makeImmediateStore()
        let clock = TrackerManualClock(TrackerPaneFx.now)
        let scheduler = TrackerManualScheduler()
        let idle = TrackerIdleScheduler()
        let pointer = TrackerTestPointer()
        let pasteboard = rigPrivatePasteboard(self)
        let pane = TrackerPaneView(tag: tag, store: store, now: { clock.date }, reduceMotion: { true },
                                   pasteboard: pasteboard, schedule: { scheduler.schedule($0, $1) },
                                   timeZone: TrackerPaneFx.utc, tickInterval: nil,
                                   idleReleaseDelay: Self.idleDelay,
                                   idleSchedule: { idle.schedule($0, $1) },
                                   pointerLocation: { pointer.location })
        let hostSize = NSSize(width: size.width, height: size.height + TrackerPaneFx.hostPadding)
        let window = makeRigWindow(self, size: hostSize)
        let host = RigFlippedDoc(frame: NSRect(origin: .zero, size: hostSize))
        pane.frame = NSRect(origin: .zero, size: size)
        let composer = NSTextField(string: "")
        composer.frame = NSRect(x: 0, y: size.height + 3, width: size.width, height: 28)
        host.addSubview(pane)
        host.addSubview(composer)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        pane.layoutSubtreeIfNeeded()
        let rig = TrackerPaneRig(window: window, host: host, pane: pane, store: store, tag: tag, clock: clock,
                                 scheduler: scheduler, pasteboard: pasteboard, composer: composer)
        let board = TrackerHoldBoard(tag: tag)
        rig.push(board)
        return Scene(rig: rig, idle: idle, pointer: pointer, board: board)
    }

    // MARK: Doing what the reader and the agent do

    private func click(_ title: String, onRow key: String, _ scene: Scene,
                       file: StaticString = #filePath, line: UInt = #line) {
        guard let row = scene.pane.rowViews[key] else {
            return XCTFail("no row \(key) to click \"\(title)\" on; rows: \(scene.pane.displayedRows.map(\.key))", file: file, line: line)
        }
        guard let button = Fx.disclosure(in: row), button.attributedTitle.string == title else {
            let offered = Fx.disclosure(in: row)?.attributedTitle.string ?? "no disclosure at all"
            return XCTFail("row \(key) offers \"\(offered)\", not \"\(title)\"", file: file, line: line)
        }
        button.performClick(nil)
        rigSettle(0.02)
        scene.rig.settle()
    }

    private func expandTheNote(_ scene: Scene, file: StaticString = #filePath, line: UInt = #line) {
        click("more", onRow: Fx.targetKey, scene, file: file, line: line)
        XCTAssertEqual(Fx.itemRow(Hold.target, in: scene.pane)?.row.item?.noteExpanded, true, "setup: the note is expanded",
                       file: file, line: line)
    }

    private func moveToDoneToday(_ scene: inout Scene, file: StaticString = #filePath, line: UInt = #line) {
        do {
            try scene.board.moveItem(Hold.target, toSection: Hold.doneToday, status: "done")
        } catch {
            return XCTFail("\(error)", file: file, line: line)
        }
        scene.rig.push(scene.board, file: file, line: line)
    }

    /// Select the first characters of `text` in the row `key`.
    private func select(text: String, inRow key: String, _ scene: Scene,
                        file: StaticString = #filePath, line: UInt = #line) throws {
        let row = try XCTUnwrap(scene.pane.rowViews[key], "a row \(key) to select in", file: file, line: line)
        let textView = try XCTUnwrap(row.allTextViews.first { $0.string.contains(text) },
                                     "a text view showing \"\(text)\"", file: file, line: line)
        XCTAssertTrue(scene.rig.window.makeFirstResponder(textView), file: file, line: line)
        textView.setSelectedRange(NSRange(location: 0, length: 6))
        rigSettle(0.02)
        XCTAssertNotNil(scene.pane.rowViews[key]?.selectedTextView, "setup: text is selected in \(key)", file: file, line: line)
    }

    private func clearTheSelection(_ scene: Scene) {
        for view in scene.pane.rowViews.values {
            for textView in view.allTextViews where textView.hasSelection {
                textView.setSelectedRange(NSRange(location: 0, length: 0))
            }
        }
        rigSettle(0.02)
        scene.rig.settle()
    }

    /// The pointer rests on the visible part of the row `key`.
    private func putThePointer(over key: String, _ scene: Scene, file: StaticString = #filePath, line: UInt = #line) throws {
        let row = try XCTUnwrap(scene.pane.rowViews[key], "a row \(key) to point at", file: file, line: line)
        let visible = row.frame.intersection(scene.pane.clipView.bounds)
        XCTAssertFalse(visible.isNull || visible.isEmpty, "setup: \(key) is on screen", file: file, line: line)
        scene.pointer.location = scene.pane.documentView.convert(NSPoint(x: visible.midX, y: visible.midY), to: nil)
    }

    private func putThePointerElsewhere(_ scene: Scene) {
        scene.pointer.location = Self.faraway
    }

    // MARK: What the pane shows

    /// Everything a reader can see move: each row's frame, the scroll position and the first visible row.
    private struct Picture {
        let frames: [String: CGRect]
        let scrollY: Double
        let documentHeight: Double
        let firstKey: String?
        let firstOffset: Double
        let firstScreenTop: CGFloat?
    }

    private func picture(_ scene: Scene) -> Picture {
        let snapshot = scene.pane.anchorSnapshot(windowIndex: 0)
        let key = snapshot.firstVisible?.rowKey
        return Picture(frames: scene.rig.rowFrames, scrollY: snapshot.scrollY, documentHeight: snapshot.documentHeight,
                       firstKey: key, firstOffset: snapshot.firstVisible?.offsetPt ?? 0,
                       firstScreenTop: key.flatMap { scene.pane.rowViews[$0] }.map { $0.convert($0.bounds, to: nil).maxY })
    }

    /// Nothing the reader sees moved or resized.
    private func assertNothingMoved(_ scene: Scene, since before: Picture, _ message: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let after = picture(scene)
        XCTAssertEqual(Set(after.frames.keys), Set(before.frames.keys), "\(message): the same rows are shown", file: file, line: line)
        for (key, frame) in before.frames {
            guard let now = after.frames[key] else { continue }
            XCTAssertEqual(now.minY, frame.minY, accuracy: 0.5, "\(message): \(key) moved", file: file, line: line)
            XCTAssertEqual(now.height, frame.height, accuracy: 0.5, "\(message): \(key) changed height", file: file, line: line)
        }
        XCTAssertEqual(after.scrollY, before.scrollY, accuracy: 0.5, "\(message): the viewport scrolled", file: file, line: line)
        XCTAssertEqual(after.documentHeight, before.documentHeight, accuracy: 0.5, "\(message): the document changed height",
                       file: file, line: line)
        XCTAssertEqual(after.firstKey, before.firstKey, "\(message): the first visible row changed", file: file, line: line)
        XCTAssertEqual(after.firstOffset, before.firstOffset, accuracy: 1, "\(message): the offset into the first row changed",
                       file: file, line: line)
    }

    /// The row the reader was reading is where it was on screen (the rows above it may have come and gone).
    private func assertReadingPositionKept(_ scene: Scene, since before: Picture, _ message: String,
                                           file: StaticString = #filePath, line: UInt = #line) {
        let after = picture(scene)
        XCTAssertEqual(after.firstKey, before.firstKey, "\(message): the first visible row changed", file: file, line: line)
        XCTAssertEqual(after.firstOffset, before.firstOffset, accuracy: 1, "\(message): the offset into the first row changed",
                       file: file, line: line)
        if let was = before.firstScreenTop, let now = after.firstScreenTop {
            XCTAssertEqual(now, was, accuracy: 1, "\(message): the line being read moved on screen", file: file, line: line)
        } else {
            XCTFail("\(message): the line being read is gone (\(String(describing: before.firstKey)))", file: file, line: line)
        }
    }

    private func assertStillHeld(_ scene: Scene, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(scene.pane.deferral.held.contains { $0.key == Fx.targetKey },
                      "\(message): the row is no longer held: \(scene.pane.deferral.held.map { "\($0.key) \($0.kind)" })",
                      file: file, line: line)
        XCTAssertTrue(Fx.isListed(Hold.target, under: Hold.waiting, in: scene.pane),
                      "\(message): the item left Waiting on you: \(Fx.placements(of: Hold.target, in: scene.pane))",
                      file: file, line: line)
    }

    private func assertReleased(_ scene: Scene, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let pane = scene.pane
        XCTAssertFalse(Fx.isListed(Hold.target, under: Hold.waiting, in: pane),
                       "\(message): the item is still shown under Waiting on you: \(Fx.placements(of: Hold.target, in: pane))",
                       file: file, line: line)
        XCTAssertNil(pane.rowViews[Fx.targetKey], "\(message): a row is left in the old place", file: file, line: line)
        XCTAssertEqual(Fx.doneGroup(Hold.doneToday, in: pane)?.itemIds.contains(Hold.target), true,
                       "\(message): Done today holds it", file: file, line: line)
        XCTAssertTrue(pane.deferral.held.isEmpty, "\(message): something is still held: \(pane.deferral.held.map(\.key))",
                      file: file, line: line)
    }

    // MARK: - TB-3: idle release

    func testAHeldRowIsReleasedWhenTheIdleCheckFiresWithNoActivity() {
        var scene = makeScene()
        moveToDoneToday(&scene)
        assertStillHeld(scene, "setup")
        XCTAssertGreaterThanOrEqual(scene.idle.armedCount, 1, "an idle check is armed while something is held")
        XCTAssertTrue(scene.idle.delays.allSatisfy { $0 == Self.idleDelay }, "the check waits the idle delay: \(scene.idle.delays)")

        scene.idle.fire()
        scene.rig.settle()

        assertReleased(scene, "after a quiet idle period")
    }

    func testActivityBetweenArmingAndFiringKeepsTheRowHeldAndTheCheckTriesAgain() {
        var scene = makeScene()
        moveToDoneToday(&scene)
        scene.pane.registerActivity()

        scene.idle.fire()
        scene.rig.settle()

        assertStillHeld(scene, "after a period with activity")
        XCTAssertGreaterThanOrEqual(scene.idle.armedCount, 1, "the check was armed again")

        scene.idle.fire()
        scene.rig.settle()

        assertReleased(scene, "after the next, quiet, period")
    }

    func testThePointerOverAHeldRowKeepsItHeldWithNothingMovingUntilThePointerLeaves() throws {
        var scene = makeScene()
        moveToDoneToday(&scene)
        // Read from the middle of the held row, so a release would move the first visible row.
        let frame = try XCTUnwrap(scene.pane.rowViews[Fx.targetKey]).frame
        scene.rig.scroll(to: frame.minY + 10)
        try putThePointer(over: Fx.targetKey, scene)
        let before = picture(scene)
        XCTAssertEqual(before.firstKey, Fx.targetKey, "setup: the held row is the one being read")

        scene.idle.fire()
        scene.rig.settle()

        assertStillHeld(scene, "with the pointer on it")
        assertNothingMoved(scene, since: before, "idle check with the pointer on the held row")
        XCTAssertGreaterThanOrEqual(scene.idle.armedCount, 1, "the check was armed again")

        putThePointerElsewhere(scene)
        scene.pane.registerActivity()   // the pointer moved
        scene.idle.fire()               // activity: tries again
        assertStillHeld(scene, "right after the pointer moved away")
        scene.idle.fire()               // quiet
        scene.rig.settle()
        assertReleased(scene, "once the pointer was away and the pane quiet")
    }

    func testASelectionKeepsAHeldRowAndItsSelectionUntouchedWhenTheIdleCheckFires() throws {
        var scene = makeScene()
        expandTheNote(scene)
        try select(text: Hold.firstNoteMarker, inRow: Fx.targetKey, scene)
        moveToDoneToday(&scene)
        assertStillHeld(scene, "setup")
        let before = picture(scene)
        let shown = Fx.shownText(scene.pane)

        scene.idle.fire()
        scene.rig.settle()

        assertStillHeld(scene, "with text selected")
        XCTAssertTrue(scene.pane.deferral.held.contains { $0.key == Fx.targetKey && $0.kind == .selection })
        XCTAssertNotNil(scene.pane.rowViews[Fx.targetKey]?.selectedTextView, "the selection is untouched")
        XCTAssertEqual(Fx.shownText(scene.pane), shown, "the selected row keeps its content")
        assertNothingMoved(scene, since: before, "idle check with text selected")
        XCTAssertGreaterThanOrEqual(scene.idle.armedCount, 1, "the check was armed again")
    }

    func testAHeldRowIsReleasedOnTheNextIdleCheckAfterASelectionClearedUnderThePointer() throws {
        var scene = makeScene()
        try select(text: Hold.targetText, inRow: Fx.targetKey, scene)
        moveToDoneToday(&scene)
        try putThePointer(over: Fx.targetKey, scene)

        clearTheSelection(scene)   // the pointer is still on the row: it stays
        assertStillHeld(scene, "selection cleared with the pointer on the row")

        putThePointerElsewhere(scene)
        scene.idle.fire()
        scene.rig.settle()

        assertReleased(scene, "on the idle check after the pointer left")
    }

    // MARK: - TB-3: "less" releases

    func testLessOnAHeldRowReleasesWhatIsHeld() {
        var scene = makeScene()
        expandTheNote(scene)
        moveToDoneToday(&scene)
        assertStillHeld(scene, "setup")

        click("less", onRow: Fx.targetKey, scene)

        assertReleased(scene, "after less")
    }

    func testLessOnTheLiveCopyOfAMovedItemReleasesItsMovedToStub() throws {
        var scene = makeScene()
        expandTheNote(scene)
        try scene.board.moveItem(Hold.target, toSection: Hold.next, status: "todo")
        scene.rig.push(scene.board)
        let stub = try XCTUnwrap(scene.pane.rowViews[Fx.targetKey])
        XCTAssertTrue(stub.visibleText.contains("moved to Next"), "setup: a stub holds the old place: \(stub.visibleText)")

        click("less", onRow: TrackerDeferral.movingPrefix + Hold.target, scene)

        XCTAssertTrue(scene.pane.deferral.held.isEmpty, "nothing is held after less: \(scene.pane.deferral.held.map(\.key))")
        XCTAssertFalse(Fx.isListed(Hold.target, under: Hold.waiting, in: scene.pane), "the stub is gone from Waiting on you")
        XCTAssertFalse(scene.pane.displayedRows.contains { $0.key.hasPrefix(TrackerDeferral.movingPrefix) }, "no temporary row is left")
        let row = try XCTUnwrap(scene.pane.rowViews[Fx.targetKey], "the item sits in Next under its own key")
        XCTAssertEqual(row.row.item?.noteExpanded, false)
        XCTAssertTrue(Fx.isListed(Hold.target, under: Hold.next, in: scene.pane))
    }

    func testLessKeepsTheContentOfARowThatHoldsATextSelectionElsewhere() throws {
        var scene = makeScene()
        expandTheNote(scene)
        let bystanderKey = TrackerRow.itemKey(Hold.bystander)
        try select(text: Hold.bystanderText, inRow: bystanderKey, scene)
        try scene.board.setText(Hold.bystander, "\(Hold.bystanderText) (revised)")
        moveToDoneToday(&scene)
        XCTAssertTrue(scene.pane.deferral.held.contains { $0.key == bystanderKey && $0.kind == .selection },
                      "setup: the selected row is held: \(scene.pane.deferral.held.map { "\($0.key) \($0.kind)" })")
        XCTAssertFalse(scene.pane.rowViews[bystanderKey]?.visibleText.contains("(revised)") ?? true, "setup: it shows its old text")

        click("less", onRow: Fx.targetKey, scene)

        let selected = try XCTUnwrap(scene.pane.rowViews[bystanderKey], "the selected row is still shown")
        XCTAssertNotNil(selected.selectedTextView, "its selection is untouched")
        XCTAssertFalse(selected.visibleText.contains("(revised)"), "its content did not change under the selection: \(selected.visibleText)")
        XCTAssertFalse(Fx.shownText(scene.pane).contains(Hold.lastNoteMarker), "the note collapsed")
    }

    // MARK: - TB-3: a click elsewhere releases

    func testAClickElsewhereReleasesAHeldRowWhenNothingIsSelected() {
        var scene = makeScene()
        moveToDoneToday(&scene)
        assertStillHeld(scene, "setup")
        putThePointerElsewhere(scene)

        scene.pane.registerClick()
        scene.rig.settle()

        assertReleased(scene, "after a click away from the held row")
    }

    func testAClickOnAHeldRowDoesNotReleaseIt() throws {
        var scene = makeScene()
        moveToDoneToday(&scene)
        try putThePointer(over: Fx.targetKey, scene)
        let before = picture(scene)

        scene.pane.registerClick()
        scene.rig.settle()

        assertStillHeld(scene, "after a click on the held row")
        assertNothingMoved(scene, since: before, "click on the held row")
    }

    func testAClickWhileTextIsSelectedDoesNotReleaseAHeldRow() throws {
        var scene = makeScene()
        try select(text: Hold.targetText, inRow: Fx.targetKey, scene)
        moveToDoneToday(&scene)
        putThePointerElsewhere(scene)
        let before = picture(scene)

        scene.pane.registerClick()
        scene.rig.settle()

        assertStillHeld(scene, "after a click while text is selected")
        XCTAssertNotNil(scene.pane.rowViews[Fx.targetKey]?.selectedTextView, "the selection is untouched")
        assertNothingMoved(scene, since: before, "click while text is selected")
    }

    // MARK: - TB-3: a selection clearing releases

    func testClearingTheSelectionReleasesAHeldRowWhenThePointerIsElsewhere() throws {
        var scene = makeScene()
        expandTheNote(scene)
        try select(text: Hold.firstNoteMarker, inRow: Fx.targetKey, scene)
        moveToDoneToday(&scene)
        putThePointerElsewhere(scene)
        assertStillHeld(scene, "setup")

        clearTheSelection(scene)

        assertReleased(scene, "after the selection cleared")
    }

    func testClearingTheSelectionDoesNotMoveAHeldRowThePointerIsOver() throws {
        var scene = makeScene()
        try select(text: Hold.targetText, inRow: Fx.targetKey, scene)
        moveToDoneToday(&scene)
        try putThePointer(over: Fx.targetKey, scene)
        let before = picture(scene)

        clearTheSelection(scene)

        assertStillHeld(scene, "after the selection cleared under the pointer")
        assertNothingMoved(scene, since: before, "selection cleared with the pointer on the row")
    }

    // MARK: - TB-3: a release above the viewport keeps the reading position

    func testReleasingARowAboveTheViewportLeavesTheReadingPositionWhereItWas() throws {
        var scene = makeScene()
        expandTheNote(scene)
        try select(text: Hold.firstNoteMarker, inRow: Fx.targetKey, scene)
        moveToDoneToday(&scene)
        let frame = try XCTUnwrap(scene.pane.rowViews[Fx.targetKey]).frame
        // The reader scrolls on while the selection still holds the row: it is above the viewport now.
        scene.rig.scroll(to: frame.maxY + 40)
        assertStillHeld(scene, "setup: a selected row is held wherever it scrolls")
        let held = try XCTUnwrap(scene.pane.rowViews[Fx.targetKey]).frame
        XCTAssertLessThanOrEqual(held.maxY, scene.pane.clipView.bounds.minY, "setup: the held row is above the viewport")
        putThePointerElsewhere(scene)
        let before = picture(scene)

        clearTheSelection(scene)

        assertReleased(scene, "after the selection cleared")
        assertReadingPositionKept(scene, since: before, "releasing the row above the viewport")
    }

    // MARK: - TB-4: tracker show explains a held row

    private typealias Obj = [String: Any]

    private func entry(_ report: Obj, section: String, item id: String, folded: Bool? = nil,
                       file: StaticString = #filePath, line: UInt = #line) -> Obj? {
        let found = TrackerHoldFx.items(inSection: section, of: report).first {
            ($0["id"] as? String) == id && (folded == nil || ($0["folded"] as? Bool) == folded)
        }
        if found == nil { XCTFail("tracker show has no \(folded.map { $0 ? "folded " : "" } ?? "")entry for \(id) under \(section)", file: file, line: line) }
        return found
    }

    private func allEntries(_ report: Obj) -> [Obj] {
        (report["sections"] as? [Obj] ?? []).flatMap { $0["items"] as? [Obj] ?? [] }
    }

    func testShowExplainsASelectionHeldRowAndADoneInPlaceRowAndTheirFoldedDoneEntries() throws {
        var scene = makeScene()
        try select(text: Hold.targetText, inRow: Fx.targetKey, scene)        // held for the selection
        try scene.board.moveItem(Hold.bystander, toSection: Hold.doneToday, status: "done")   // held in place
        moveToDoneToday(&scene)
        let report = scene.pane.showReport()

        let selected = try XCTUnwrap(entry(report, section: Hold.waiting, item: Hold.target, folded: false))
        XCTAssertEqual(selected["held"] as? String, "selection")
        let selectedReason = try XCTUnwrap(selected["held_reason"] as? String, "a held row says why: \(selected)")
        XCTAssertTrue(selectedReason.contains("done-today"), "the reason names the section the board put it in: \(selectedReason)")
        XCTAssertTrue(selectedReason.lowercased().contains("select"), "the reason says a selection holds it: \(selectedReason)")
        XCTAssertEqual(selected["model_section"] as? String, "done-today")

        let inPlace = try XCTUnwrap(entry(report, section: Hold.waiting, item: Hold.bystander, folded: false))
        XCTAssertEqual(inPlace["held"] as? String, "done_in_place")
        let inPlaceReason = try XCTUnwrap(inPlace["held_reason"] as? String, "a held row says why: \(inPlace)")
        XCTAssertTrue(inPlaceReason.contains("done-today"), "the reason names the section the board put it in: \(inPlaceReason)")
        XCTAssertEqual(inPlace["model_section"] as? String, "done-today")
        XCTAssertNotEqual(inPlaceReason, selectedReason, "each kind of hold has its own cause")

        // The item's entry in the folded Done group says the same: the view still holds it elsewhere.
        let foldedSelected = try XCTUnwrap(entry(report, section: Hold.doneToday, item: Hold.target, folded: true))
        XCTAssertEqual(foldedSelected["held"] as? String, "selection")
        XCTAssertTrue((foldedSelected["held_reason"] as? String)?.contains("done-today") ?? false, "\(foldedSelected)")
        let foldedInPlace = try XCTUnwrap(entry(report, section: Hold.doneToday, item: Hold.bystander, folded: true))
        XCTAssertEqual(foldedInPlace["held"] as? String, "done_in_place")
        XCTAssertTrue((foldedInPlace["held_reason"] as? String)?.contains("done-today") ?? false, "\(foldedInPlace)")

        // An item nothing holds, in the same group, is not reported as held.
        let finished = try XCTUnwrap(entry(report, section: Hold.doneToday, item: Hold.finished, folded: true))
        XCTAssertTrue(finished["held"] is NSNull)
        XCTAssertTrue(finished["held_reason"] is NSNull)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(report), "the report is valid JSON")
    }

    func testShowStopsReportingAFoldedDoneEntryAsHeldOnceTheRowIsReleased() throws {
        var scene = makeScene()
        moveToDoneToday(&scene)
        var report = scene.pane.showReport()
        XCTAssertEqual(try XCTUnwrap(entry(report, section: Hold.doneToday, item: Hold.target, folded: true))["held"] as? String,
                       "done_in_place", "setup: the folded entry is reported held while the row is")

        putThePointerElsewhere(scene)
        scene.pane.registerClick()
        scene.rig.settle()
        assertReleased(scene, "setup")
        report = scene.pane.showReport()

        let folded = try XCTUnwrap(entry(report, section: Hold.doneToday, item: Hold.target, folded: true))
        XCTAssertTrue(folded["held"] is NSNull, "nothing holds it now: \(folded)")
        XCTAssertTrue(folded["held_reason"] is NSNull)
        XCTAssertFalse(allEntries(report).contains { !($0["held"] is NSNull) }, "nothing in the report is held")
    }

    func testEveryItemInTheReportHasTheTwoHeldKeysAndNothingHeldHasNullForBoth() {
        let scene = makeScene()
        let report = scene.pane.showReport()
        let entries = allEntries(report)

        XCTAssertGreaterThan(entries.count, 25, "the report lists the whole board, folded items included")
        for item in entries {
            let id = item["id"] as? String ?? "?"
            XCTAssertTrue(item.keys.contains("held_reason"), "\(id) has held_reason")
            XCTAssertTrue(item.keys.contains("model_section"), "\(id) has model_section")
            XCTAssertTrue(item["held"] is NSNull, "\(id) is not held")
            XCTAssertTrue(item["held_reason"] is NSNull, "\(id): no hold, no reason")
        }
        XCTAssertTrue(entries.contains { ($0["folded"] as? Bool) == true }, "setup: a folded entry is among them")
    }

    func testShowGivesAMovedItemsStubAHeldReasonNamingTheSectionItMovedTo() throws {
        var scene = makeScene()
        try scene.board.moveItem(Hold.target, toSection: Hold.next, status: "todo")
        scene.rig.push(scene.board)
        let report = scene.pane.showReport()

        let stub = try XCTUnwrap(entry(report, section: Hold.waiting, item: Hold.target))
        XCTAssertEqual(stub["held"] as? String, "moved")
        let reason = try XCTUnwrap(stub["held_reason"] as? String, "a held stub says why: \(stub)")
        XCTAssertTrue(reason.contains("next"), "the reason names the section the board put the item in: \(reason)")
        XCTAssertEqual(stub["model_section"] as? String, "next")
        // held_reason is non-null exactly when held is, for every item in the report.
        for item in allEntries(report) {
            XCTAssertEqual(item["held"] is NSNull, item["held_reason"] is NSNull,
                           "\(item["id"] as? String ?? "?"): held \(String(describing: item["held"])), reason \(String(describing: item["held_reason"]))")
        }
    }
}
