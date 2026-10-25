import XCTest
import AppKit
import NostromoKit

// A held tracker row must not move while the reader's mouse button is down, and what `tracker show` says
// about where a row is displayed (fix/tracker-row-hold-and-less, PR #322).
//
// Live observation: a reader drags to select text, the drag collapses the old selection (or the pointer
// rests, held still, mid-drag), and the pane releases the held rows under the reader's hand: the rows
// jump while the button is still down. The rules these tests pin down:
//
//  - While a mouse button is down nothing is released, by either path (a selection clearing, or the idle
//    check / a click): no row moves, rows stay held.
//  - A release that was wanted and deferred for that reason happens, once, after the button is up and the
//    next mouse-up arrives (in the pane, or anywhere in the window), provided the conditions still hold:
//    no selection and the pointer not over a held row.
//  - A mouse-down or a drag in the pane counts as activity for the idle check (a held-still drag moves no
//    pointer), a mouse-up in the pane is a click, unless it is in the header or on the vertical scroller.
//    Events for another window are ignored.
//  - `tracker show` says, per item, which section the VIEW has the row under (`shown_section`) and whether
//    the displayed row's note is expanded (`shown_expanded`), next to the board's own `model_section`.
//
// Seams used: `TrackerPaneView.init(..., pointerLocation:, isMouseButtonDown:)`, `observe(_ event:)` (the
// local event monitor's entry point, fed hand-made NSEvents for the rig window), `registerActivity()`,
// `registerClick()`, `showReport()`. The idle scheduler, the pointer and the mouse button are manual.
// Boards come from `TrackerHoldBoard` (TrackerRowHoldTests.swift); `TrackerIdleScheduler` and
// `TrackerTestPointer` are in TrackerRowHoldReleaseTests.swift.

/// Whether a mouse button is down, as the pane is told.
final class TrackerTestMouseButton {
    var isDown = false
}

final class TrackerRowHoldMouseDownTests: XCTestCase {

    private typealias Hold = TrackerHoldBoard
    private typealias Fx = TrackerHoldFx

    private static let idleDelay: TimeInterval = 7
    private static let faraway = NSPoint(x: -5000, y: -5000)

    private struct Scene {
        let rig: TrackerPaneRig
        let idle: TrackerIdleScheduler
        let pointer: TrackerTestPointer
        let button: TrackerTestMouseButton
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
        let button = TrackerTestMouseButton()
        let pasteboard = rigPrivatePasteboard(self)
        let pane = TrackerPaneView(tag: tag, store: store, now: { clock.date }, reduceMotion: { true },
                                   pasteboard: pasteboard, schedule: { scheduler.schedule($0, $1) },
                                   timeZone: TrackerPaneFx.utc, tickInterval: nil,
                                   idleReleaseDelay: Self.idleDelay,
                                   idleSchedule: { idle.schedule($0, $1) },
                                   pointerLocation: { pointer.location },
                                   isMouseButtonDown: { button.isDown })
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
        return Scene(rig: rig, idle: idle, pointer: pointer, button: button, board: board)
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

    private func putThePointer(over key: String, _ scene: Scene, file: StaticString = #filePath, line: UInt = #line) throws {
        let row = try XCTUnwrap(scene.pane.rowViews[key], "a row \(key) to point at", file: file, line: line)
        let visible = row.frame.intersection(scene.pane.clipView.bounds)
        XCTAssertFalse(visible.isNull || visible.isEmpty, "setup: \(key) is on screen", file: file, line: line)
        scene.pointer.location = scene.pane.documentView.convert(NSPoint(x: visible.midX, y: visible.midY), to: nil)
    }

    private func putThePointerElsewhere(_ scene: Scene) {
        scene.pointer.location = Self.faraway
    }

    // MARK: Mouse events, as the pane's event monitor sees them

    /// A point in the pane's list area, clear of the vertical scroller, in window coordinates.
    private func pointInThePane(_ scene: Scene) -> NSPoint {
        scene.pane.convert(NSPoint(x: scene.pane.bounds.width * 0.25, y: scene.pane.scrollView.frame.midY), to: nil)
    }

    private func pointInTheHeader(_ scene: Scene) -> NSPoint {
        scene.pane.convert(NSPoint(x: scene.pane.bounds.width * 0.25, y: scene.pane.header.frame.midY), to: nil)
    }

    /// A point in the window that is not in the pane (the composer below it).
    private func pointOutsideThePane(_ scene: Scene) -> NSPoint {
        let composer = scene.rig.composer
        return composer.convert(NSPoint(x: composer.bounds.midX, y: composer.bounds.midY), to: nil)
    }

    private func mouseEvent(_ type: NSEvent.EventType, at location: NSPoint, in window: NSWindow,
                            file: StaticString = #filePath, line: UInt = #line) throws -> NSEvent {
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1),
            "a \(type) event", file: file, line: line)
        XCTAssertTrue(event.window === window, "setup: the event belongs to the rig window", file: file, line: line)
        return event
    }

    /// Deliver the event the way the local monitor does, then let the main queue run what it queued.
    private func deliver(_ type: NSEvent.EventType, at location: NSPoint, _ scene: Scene,
                         file: StaticString = #filePath, line: UInt = #line) throws {
        let event = try mouseEvent(type, at: location, in: scene.rig.window, file: file, line: line)
        scene.pane.observe(event)
        rigSettle(0.02)
        scene.rig.settle()
    }

    // MARK: What the pane shows

    private struct Picture {
        let frames: [String: CGRect]
        let scrollY: Double
        let documentHeight: Double
        let firstKey: String?
        let firstOffset: Double
    }

    private func picture(_ scene: Scene) -> Picture {
        let snapshot = scene.pane.anchorSnapshot(windowIndex: 0)
        return Picture(frames: scene.rig.rowFrames, scrollY: snapshot.scrollY, documentHeight: snapshot.documentHeight,
                       firstKey: snapshot.firstVisible?.rowKey, firstOffset: snapshot.firstVisible?.offsetPt ?? 0)
    }

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

    private func heldKeys(_ scene: Scene) -> Set<String> {
        Set(scene.pane.deferral.held.map(\.key))
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

    // MARK: - The selection clears while the button is down

    /// A is the target row (text selected), B is the bystander (done in place); both are held.
    private func holdASelectionAndADoneRow(_ scene: inout Scene, file: StaticString = #filePath, line: UInt = #line) throws {
        try select(text: Hold.targetText, inRow: Fx.targetKey, scene, file: file, line: line)
        try scene.board.moveItem(Hold.bystander, toSection: Hold.doneToday, status: "done")
        moveToDoneToday(&scene, file: file, line: line)
        let bystanderKey = TrackerRow.itemKey(Hold.bystander)
        XCTAssertTrue(heldKeys(scene).isSuperset(of: [Fx.targetKey, bystanderKey]),
                      "setup: both rows are held: \(scene.pane.deferral.held.map { "\($0.key) \($0.kind)" })", file: file, line: line)
    }

    func testCollapsingASelectionWithTheButtonDownMovesNothingAndTheRowsAreReleasedOnceItIsUp() throws {
        var scene = makeScene()
        try holdASelectionAndADoneRow(&scene)
        putThePointerElsewhere(scene)
        let held = heldKeys(scene)
        let before = picture(scene)
        scene.button.isDown = true

        clearTheSelection(scene)

        XCTAssertEqual(heldKeys(scene), held, "everything is still held while the button is down")
        assertStillHeld(scene, "selection collapsed with the button down")
        assertNothingMoved(scene, since: before, "selection collapsed with the button down")

        scene.button.isDown = false
        let generation = scene.pane.renderGeneration
        try deliver(.leftMouseUp, at: pointInThePane(scene), scene)

        assertReleased(scene, "after the button went up")
        XCTAssertFalse(Fx.isListed(Hold.bystander, under: Hold.waiting, in: scene.pane), "the other held row is released too")
        XCTAssertEqual(scene.pane.renderGeneration, generation + 1, "the release happened once")

        try deliver(.leftMouseUp, at: pointInThePane(scene), scene)
        XCTAssertEqual(scene.pane.renderGeneration, generation + 1, "a later mouse-up has nothing left to release")
    }

    func testAReleaseDeferredForTheButtonIsNotAppliedWhenThePointerIsOnAHeldRowByThen() throws {
        var scene = makeScene()
        try holdASelectionAndADoneRow(&scene)
        putThePointerElsewhere(scene)
        let held = heldKeys(scene)
        let before = picture(scene)
        scene.button.isDown = true
        clearTheSelection(scene)

        try putThePointer(over: Fx.targetKey, scene)   // the drag ended on a held row
        scene.button.isDown = false
        try deliver(.leftMouseUp, at: pointInThePane(scene), scene)

        XCTAssertEqual(heldKeys(scene), held, "still held")
        assertStillHeld(scene, "mouse up with the pointer on a held row")
        assertNothingMoved(scene, since: before, "mouse up with the pointer on a held row")
    }

    func testAReleaseDeferredForTheButtonIsNotAppliedWhenTextIsSelectedByThen() throws {
        var scene = makeScene()
        try holdASelectionAndADoneRow(&scene)
        putThePointerElsewhere(scene)
        let held = heldKeys(scene)
        let before = picture(scene)
        scene.button.isDown = true
        clearTheSelection(scene)

        // The drag selected something else.
        try select(text: "Rotate the avatar sync key", inRow: TrackerRow.itemKey("next-a"), scene)
        scene.button.isDown = false
        try deliver(.leftMouseUp, at: pointInThePane(scene), scene)

        XCTAssertEqual(heldKeys(scene), held, "still held")
        assertStillHeld(scene, "mouse up with text selected")
        assertNothingMoved(scene, since: before, "mouse up with text selected")
    }

    func testAMouseUpOutsideThePaneAppliesAReleaseThatWasDeferredForTheButton() throws {
        var scene = makeScene()
        try select(text: Hold.targetText, inRow: Fx.targetKey, scene)
        moveToDoneToday(&scene)
        putThePointerElsewhere(scene)
        scene.button.isDown = true
        clearTheSelection(scene)
        assertStillHeld(scene, "setup: the release waits for the button")

        scene.button.isDown = false
        try deliver(.leftMouseUp, at: pointOutsideThePane(scene), scene)

        assertReleased(scene, "after a mouse-up elsewhere in the window")
    }

    func testAMouseUpOutsideThePaneReleasesNothingWhenNoReleaseWasWaiting() throws {
        var scene = makeScene()
        moveToDoneToday(&scene)
        putThePointerElsewhere(scene)
        let before = picture(scene)

        try deliver(.leftMouseUp, at: pointOutsideThePane(scene), scene)

        assertStillHeld(scene, "after a mouse-up outside the pane")
        assertNothingMoved(scene, since: before, "mouse-up outside the pane")
    }

    // MARK: - The idle check and clicks while the button is down

    func testTheIdleCheckReleasesNothingWhileTheButtonIsDownAndTriesAgain() {
        var scene = makeScene()
        moveToDoneToday(&scene)
        putThePointerElsewhere(scene)
        assertStillHeld(scene, "setup")
        let before = picture(scene)
        scene.button.isDown = true

        scene.idle.fire()
        scene.rig.settle()

        assertStillHeld(scene, "idle check with the button down")
        assertNothingMoved(scene, since: before, "idle check with the button down")
        XCTAssertGreaterThanOrEqual(scene.idle.armedCount, 1, "the check was armed again")

        scene.button.isDown = false
        scene.idle.fire()
        scene.rig.settle()

        assertReleased(scene, "on the next idle check, with the button up")
    }

    func testAClickRegisteredWhileTheButtonIsDownReleasesNothingButTheNextOneDoes() {
        var scene = makeScene()
        moveToDoneToday(&scene)
        putThePointerElsewhere(scene)
        let before = picture(scene)
        scene.button.isDown = true

        scene.pane.registerClick()
        scene.rig.settle()

        assertStillHeld(scene, "click with the button down")
        assertNothingMoved(scene, since: before, "click with the button down")

        scene.button.isDown = false
        scene.pane.registerClick()
        scene.rig.settle()

        assertReleased(scene, "click with the button up")
    }

    // MARK: - A held-still drag is activity

    func testAMouseDownOrADragInThePaneCountsAsActivityForTheIdleCheck() throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseDragged] {
            var scene = makeScene()
            moveToDoneToday(&scene)
            putThePointerElsewhere(scene)

            try deliver(type, at: pointInThePane(scene), scene)
            assertStillHeld(scene, "\(type) in the pane releases nothing by itself")
            scene.idle.fire()
            scene.rig.settle()

            assertStillHeld(scene, "idle check after a \(type) in the pane")
            XCTAssertGreaterThanOrEqual(scene.idle.armedCount, 1, "the check was armed again after \(type)")
            scene.idle.fire()
            scene.rig.settle()
            assertReleased(scene, "the next quiet period after \(type)")
        }
    }

    func testAMouseDownThenAHeldStillDragKeepTheIdleCheckFromReleasing() throws {
        var scene = makeScene()
        moveToDoneToday(&scene)
        putThePointerElsewhere(scene)

        try deliver(.leftMouseDown, at: pointInThePane(scene), scene)
        try deliver(.leftMouseDragged, at: pointInThePane(scene), scene)
        scene.idle.fire()
        scene.rig.settle()

        assertStillHeld(scene, "idle check after a mouse-down and a drag, with the pointer not moving")
    }

    func testWithoutAnyMouseActivityTheIdleCheckReleases() {
        var scene = makeScene()
        moveToDoneToday(&scene)
        putThePointerElsewhere(scene)

        scene.idle.fire()
        scene.rig.settle()

        assertReleased(scene, "a quiet period")
    }

    func testMouseEventsForAnotherWindowOrInTheHeaderAreNeitherActivityNorAClick() throws {
        let other = makeRigWindow(self, size: NSSize(width: 200, height: 200))
        for inHeader in [false, true] {
            let name = inHeader ? "the header" : "another window"
            var scene = makeScene()
            moveToDoneToday(&scene)
            putThePointerElsewhere(scene)
            let at = inHeader ? pointInTheHeader(scene) : pointInThePane(scene)
            let window: NSWindow = inHeader ? scene.rig.window : other

            for type in [NSEvent.EventType.leftMouseDown, .leftMouseDragged, .leftMouseUp] {
                let event = try mouseEvent(type, at: at, in: window)
                scene.pane.observe(event)
                rigSettle(0.02)
                scene.rig.settle()
                assertStillHeld(scene, "\(type) in \(name) is not a click")
            }
            scene.idle.fire()
            scene.rig.settle()
            assertReleased(scene, "\(name): no activity was counted, so the idle check released")
        }
    }

    // MARK: - A mouse-up on the scroller is not a click elsewhere

    func testAMouseUpOnTheScrollersTrackIsNotAClickElsewhereButOneOnARowIs() throws {
        var scene = makeScene()
        scene.pane.scrollView.scrollerStyle = .legacy
        scene.pane.scrollView.tile()
        scene.pane.needsLayout = true
        scene.rig.settle()
        moveToDoneToday(&scene)
        putThePointerElsewhere(scene)

        let scrollView = scene.pane.scrollView
        guard let scroller = scrollView.verticalScroller, !scroller.isHidden, scroller.frame.width > 1,
              scrollView.documentView.map({ $0.frame.height > scrollView.contentView.bounds.height }) == true else {
            throw XCTSkip("the rig window cannot show a legacy vertical scroller; the scroller rule is not covered here")
        }
        let onTheScroller = scroller.convert(NSPoint(x: scroller.bounds.midX, y: scroller.bounds.midY), to: nil)
        XCTAssertTrue(scene.pane.bounds.contains(scene.pane.convert(onTheScroller, from: nil)), "setup: the scroller is inside the pane")
        let before = picture(scene)

        try deliver(.leftMouseUp, at: onTheScroller, scene)

        assertStillHeld(scene, "after a mouse-up on the scroller")
        assertNothingMoved(scene, since: before, "mouse-up on the scroller")

        try deliver(.leftMouseUp, at: pointInThePane(scene), scene)

        assertReleased(scene, "after a mouse-up on the list")
    }

    // MARK: - tracker show: where the view has each row

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

    func testShowReportsTheSectionTheViewHasAHeldRowUnderAndWhetherItsNoteIsExpanded() throws {
        var scene = makeScene()
        expandTheNote(scene)
        moveToDoneToday(&scene)
        assertStillHeld(scene, "setup")
        let report = scene.pane.showReport()

        let held = try XCTUnwrap(entry(report, section: Hold.waiting, item: Hold.target, folded: false))
        XCTAssertEqual(held["shown_section"] as? String, Hold.waiting, "the view still has it under its old heading: \(held)")
        XCTAssertEqual(held["model_section"] as? String, Hold.doneToday, "the board has it in Done today: \(held)")
        XCTAssertEqual(held["shown_expanded"] as? Bool, true, "its note is expanded on screen: \(held)")

        let bystander = try XCTUnwrap(entry(report, section: Hold.waiting, item: Hold.bystander, folded: false))
        XCTAssertEqual(bystander["shown_section"] as? String, Hold.waiting)
        XCTAssertEqual(bystander["model_section"] as? String, Hold.waiting)
        XCTAssertEqual(bystander["shown_expanded"] as? Bool, false, "nothing expanded it: \(bystander)")

        let next = try XCTUnwrap(entry(report, section: Hold.next, item: "next-a", folded: false))
        XCTAssertEqual(next["shown_section"] as? String, Hold.next)
        XCTAssertEqual(next["shown_expanded"] as? Bool, false)

        // The folded Done entry of the held item reports what the view shows of it; an untouched one, the model's.
        let folded = try XCTUnwrap(entry(report, section: Hold.doneToday, item: Hold.target, folded: true))
        XCTAssertEqual(folded["shown_section"] as? String, Hold.waiting, "the view holds it under Waiting on you: \(folded)")
        XCTAssertEqual(folded["model_section"] as? String, Hold.doneToday)
        XCTAssertEqual(folded["shown_expanded"] as? Bool, true, "the displayed row has its note expanded: \(folded)")
        let finished = try XCTUnwrap(entry(report, section: Hold.doneToday, item: Hold.finished, folded: true))
        XCTAssertEqual(finished["shown_section"] as? String, Hold.doneToday, "nothing holds it elsewhere: \(finished)")
        XCTAssertEqual(finished["shown_expanded"] as? Bool, false)
    }

    func testShowReportsAHeldRowUnderTheSectionItWasMovedToOnceItIsReleased() throws {
        var scene = makeScene()
        expandTheNote(scene)
        moveToDoneToday(&scene)
        putThePointerElsewhere(scene)
        scene.pane.registerClick()
        scene.rig.settle()
        assertReleased(scene, "setup")
        let report = scene.pane.showReport()

        let folded = try XCTUnwrap(entry(report, section: Hold.doneToday, item: Hold.target, folded: true))
        XCTAssertEqual(folded["shown_section"] as? String, Hold.doneToday, "no longer held elsewhere: \(folded)")
        for item in allEntries(report) {
            XCTAssertEqual(item["shown_section"] as? String, item["model_section"] as? String,
                           "\(item["id"] as? String ?? "?"): with nothing held the view and the board agree")
        }
    }

    func testShowReportsAMovedItemsStubUnderTheOldSectionAndItsLiveCopyUnderTheNewOne() throws {
        var scene = makeScene()
        try scene.board.moveItem(Hold.target, toSection: Hold.next, status: "todo")
        scene.rig.push(scene.board)
        let report = scene.pane.showReport()

        let stub = try XCTUnwrap(entry(report, section: Hold.waiting, item: Hold.target))
        XCTAssertEqual(stub["held"] as? String, "moved")
        XCTAssertEqual(stub["shown_section"] as? String, Hold.waiting, "the stub keeps the old place: \(stub)")
        XCTAssertEqual(stub["model_section"] as? String, Hold.next)
        XCTAssertTrue(stub["shown_expanded"] is Bool, "a stub says whether its note is expanded: \(stub)")

        let live = try XCTUnwrap(entry(report, section: Hold.next, item: Hold.target))
        XCTAssertEqual(live["shown_section"] as? String, Hold.next, "the live copy sits in the new section: \(live)")
        XCTAssertEqual(live["model_section"] as? String, Hold.next)
    }

    func testEveryItemInTheReportHasShownSectionAndShownExpandedAndNonFoldedOnesNameTheirHeading() throws {
        var scene = makeScene()
        expandTheNote(scene)
        try scene.board.moveItem(Hold.bystander, toSection: Hold.next, status: "todo")
        moveToDoneToday(&scene)
        let report = scene.pane.showReport()
        let sections = report["sections"] as? [Obj] ?? []
        let entries = allEntries(report)

        XCTAssertGreaterThan(entries.count, 25, "the report lists the whole board, folded items included")
        for item in entries {
            let id = item["id"] as? String ?? "?"
            XCTAssertTrue(item.keys.contains("shown_section"), "\(id) has shown_section")
            XCTAssertTrue(item.keys.contains("shown_expanded"), "\(id) has shown_expanded")
            XCTAssertTrue(item["shown_section"] is String, "\(id): shown_section names a section: \(String(describing: item["shown_section"]))")
            XCTAssertTrue(item["shown_expanded"] is Bool, "\(id): shown_expanded is a Bool: \(String(describing: item["shown_expanded"]))")
        }
        // A displayed row's shown_section is the heading it is listed under in the report.
        for section in sections {
            let heading = section["id"] as? String
            for item in section["items"] as? [Obj] ?? [] where (item["folded"] as? Bool) == false && (item["held"] as? String) != "moving" {
                XCTAssertEqual(item["shown_section"] as? String, heading,
                               "\(item["id"] as? String ?? "?") is listed under \(heading ?? "?")")
            }
        }
    }
}
