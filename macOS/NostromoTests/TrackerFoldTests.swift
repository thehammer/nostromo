import XCTest
import AppKit
import NostromoKit

// The tracker's title and fold (TRK title/fold): an item row shows a one-line plain-text title; whatever
// else the item has (the text after the title, then the note) sits under a disclosure and shows only
// while it is open. These tests read the behaviour from outside: the row's texts, the disclosure
// button an operator clicks or Space-presses, what VoiceOver is told about it, where the reader's
// line sits on screen when a fold opens above it, the Waiting strip, and `tracker show`.
//
// Boards are the golden frame with in-memory edits (`TrackerBoardScript`), the scroll test runs on the
// scroll-safety gate's pane (`TrackerGateHarness`). Every collaborator is injected: no wall clock, no
// real pasteboard, no UserDefaults at all, no daemon.
//
// What the tests are meant to catch, for whoever mutates the implementation to check them:
//  - Build the title with `TrackerTextView.make()` instead of `make(singleLine: true)`: a long title
//    wraps, so the "one title line" assertions fail here (the title view is taller than a one-line
//    row's) and in TrackerFoldAppearanceTests (several lines of ink, a taller row).
//  - Draw the body in the collapsed row (or keep the old first-line-of-the-note): the "no body, no
//    note while collapsed" assertions fail.
//  - Rebuild the row on toggle without handing focus to the new button: the focus tests fail.
//  - Set the disclosure's accessibility label, role or state wrong: the accessibility test fails.
//  - Keep the expanded set only per board version: the "survives a newer version" test fails.
//  - Let the row's height change shift the reader (no anchor): the scroll test fails.
//  - Show the whole text in the strip or in `tracker show` instead of the title: those tests fail.
//  - Drop `foldColumnWidth` (the column that keeps titles aligned and the chevron clear of the mark):
//    caught by TrackerFoldAppearanceTests (chevron against the mark and the title).

final class TrackerFoldTests: XCTestCase {

    private typealias Fx = TrackerPaneFx
    private typealias Obj = [String: Any]

    // The long item: a title, the ": " separator the title rule splits at, and a body. The text is
    // well over 80 characters, so the rule gives `title` as the title and `body` as the rest.
    private static let title = "Rotate the signing key"
    private static let body = "The vendor rotated the key on Tuesday and every consumer must refresh its cached copy "
        + "before the next deploy window opens, so this stays open until the canary confirms it."
    private static var longText: String { "\(title): \(body)" }
    private static let noteLines = ["Runbook step one: fetch the new key", "Runbook step two: restart the workers"]

    /// An in-progress item with an owner and no note in the golden board: made long and given a note.
    private let foldItem = "verif-1037"
    /// Short text, no note, no links: nothing under a fold.
    private let plainItem = "revie-1111"
    /// Short text and a note in the golden board: foldable by its note alone.
    private let noteOnlyItem = "check-1000"

    // MARK: - Rigs and reading

    private func foldRig(file: StaticString = #filePath, line: UInt = #line)
        throws -> (rig: TrackerPaneRig, script: TrackerBoardScript) {
        let tag = Fx.uniqueTag()
        let rig = Fx.makeRig(self, tag: tag)
        var script = try TrackerBoardScript(tag: tag, file: file)
        try script.setText(foldItem, Self.longText)
        try script.setNote(foldItem, paragraphs: Self.noteLines)
        rig.push(script, file: file, line: line)
        return (rig, script)
    }

    private func row(_ rig: TrackerPaneRig, _ id: String, file: StaticString = #filePath, line: UInt = #line) throws -> TrackerRowView {
        try XCTUnwrap(rig.pane.rowViews["item:\(id)"], "no row for \(id); rows: \(rig.pane.displayedRows.map(\.key))",
                      file: file, line: line)
    }

    /// The row's disclosure as it is right now (a toggle may have rebuilt it).
    private func disclosure(_ rig: TrackerPaneRig, _ id: String, file: StaticString = #filePath, line: UInt = #line) throws -> NSButton {
        try XCTUnwrap(try row(rig, id, file: file, line: line).disclosureButton, "\(id) has no disclosure button",
                      file: file, line: line)
    }

    private func click(_ rig: TrackerPaneRig, _ id: String, file: StaticString = #filePath, line: UInt = #line) throws {
        try disclosure(rig, id, file: file, line: line).performClick(nil)
        rig.settle()
    }

    /// The text of the disclosure's accessibility value as a flag: nil when it is neither a number nor
    /// words that say expanded / collapsed.
    private func accessibilityValueSaysExpanded(_ button: NSButton) -> Bool? {
        switch button.accessibilityValue() {
        case let number as NSNumber:
            return number.intValue != 0
        case let text as String:
            let lowered = text.lowercased()
            if lowered.contains("collapsed") { return false }
            if lowered.contains("expanded") { return true }
            return nil
        default:
            return nil
        }
    }

    private func assertCollapsed(_ rig: TrackerPaneRig, _ id: String, _ message: String,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let text = try row(rig, id, file: file, line: line).visibleText
        XCTAssertTrue(text.contains(Self.title), "\(message): the title shows: \(text)", file: file, line: line)
        XCTAssertFalse(text.contains(Self.body), "\(message): the rest of the text is folded away: \(text)", file: file, line: line)
        XCTAssertFalse(text.contains("Runbook step"), "\(message): the note is folded away: \(text)", file: file, line: line)
        XCTAssertEqual(try disclosure(rig, id, file: file, line: line).state, .off, "\(message): the disclosure reads closed",
                       file: file, line: line)
    }

    private func assertExpanded(_ rig: TrackerPaneRig, _ id: String, _ message: String,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let text = try row(rig, id, file: file, line: line).visibleText
        XCTAssertTrue(text.contains(Self.title), "\(message): the title still shows: \(text)", file: file, line: line)
        XCTAssertTrue(text.contains(Self.body), "\(message): the rest of the text shows: \(text)", file: file, line: line)
        XCTAssertTrue(text.contains("Runbook step one"), "\(message): the note's first paragraph shows: \(text)", file: file, line: line)
        XCTAssertTrue(text.contains("Runbook step two"), "\(message): the note's last paragraph shows: \(text)", file: file, line: line)
        XCTAssertEqual(try disclosure(rig, id, file: file, line: line).state, .on, "\(message): the disclosure reads open",
                       file: file, line: line)
    }

    // MARK: - Collapsed, expanded

    func testAFoldableItemShowsOneTitleLineAndNeitherTheRestOfItsTextNorItsNote() throws {
        let (rig, _) = try foldRig()
        let view = try row(rig, foldItem)
        XCTAssertEqual(view.textViews.count, 1, "one text view: the title")
        XCTAssertEqual(view.textViews.first?.string, Self.title, "the title is the text up to the separator, without it")
        XCTAssertNil(view.proseView, "no note is laid out while collapsed")
        try assertCollapsed(rig, foldItem, "collapsed")

        // One line tall: as tall as the title of an item whose whole text is short.
        let reference = try XCTUnwrap(try row(rig, plainItem).textViews.first, "the plain item shows its text")
        let title = try XCTUnwrap(view.textViews.first)
        XCTAssertGreaterThan(reference.frame.height, 0)
        XCTAssertEqual(title.frame.height, reference.frame.height, accuracy: 0.5, "the title takes one line, like a short item's text")
    }

    func testClickingTheDisclosureShowsTheRestOfTheTextAndTheNoteAndClickingAgainHidesThem() throws {
        let (rig, _) = try foldRig()
        try assertCollapsed(rig, foldItem, "before any click")

        try click(rig, foldItem)
        try assertExpanded(rig, foldItem, "after the first click")
        let lead = try XCTUnwrap(try row(rig, foldItem).textViews.dropFirst().first, "the rest of the text has a view of its own")
        XCTAssertEqual(lead.string, Self.body, "the rest of the text is shown whole, after the title")

        try click(rig, foldItem)
        try assertCollapsed(rig, foldItem, "after the second click")
    }

    func testAnItemWithNothingUnderTheFoldHasNoDisclosure() throws {
        let (rig, _) = try foldRig()
        let view = try row(rig, plainItem)
        XCTAssertNil(view.disclosureButton, "short text and no note: nothing to fold")
        XCTAssertEqual(view.row.item?.isFoldable, false)
        XCTAssertEqual(view.row.item?.isExpanded, false)
    }

    func testAnItemWhoseOnlyDetailIsANoteFoldsAndOpensToTheNote() throws {
        let tag = Fx.uniqueTag()
        let rig = Fx.makeRig(self, tag: tag)
        var script = try TrackerBoardScript(tag: tag)
        try script.setNote(noteOnlyItem, paragraphs: ["Only a note, line one", "Only a note, line two"])
        rig.push(script)

        let collapsed = try row(rig, noteOnlyItem).visibleText
        XCTAssertFalse(collapsed.contains("Only a note"), "the note is not shown while collapsed: \(collapsed)")
        XCTAssertEqual(try row(rig, noteOnlyItem).textViews.count, 1, "no rest of the text, only the title")

        try click(rig, noteOnlyItem)
        let expanded = try row(rig, noteOnlyItem).visibleText
        XCTAssertTrue(expanded.contains("Only a note, line one"), expanded)
        XCTAssertTrue(expanded.contains("Only a note, line two"), expanded)
    }

    func testTheExpandedStateSurvivesANewerBoardVersionThatChangesAnotherItem() throws {
        let (rig, script) = try foldRig()
        try click(rig, foldItem)
        try assertExpanded(rig, foldItem, "setup")

        var newer = script
        newer.setVersion(8)
        try newer.setText(plainItem, "Reworded while the other item is open")
        try newer.setStatus(plainItem, "in-progress")
        rig.push(newer)

        XCTAssertTrue(try row(rig, plainItem).visibleText.contains("Reworded while the other item is open"),
                      "setup: the newer board arrived")
        try assertExpanded(rig, foldItem, "after the newer board")

        var again = newer
        again.setVersion(9)
        try again.setNote(foldItem, paragraphs: Self.noteLines + ["Runbook step three: confirm the canary"])
        rig.push(again)
        try assertExpanded(rig, foldItem, "after a board that changes the open item's own note")
        XCTAssertTrue(try row(rig, foldItem).visibleText.contains("Runbook step three"), "and it shows the new note")
    }

    // MARK: - Keyboard focus

    func testWithTheDisclosureFocusedTogglingKeepsFocusOnTheRowsNewDisclosure() throws {
        let (rig, _) = try foldRig()
        let first = try disclosure(rig, foldItem)
        XCTAssertTrue(rig.window.makeFirstResponder(first), "setup: the window can focus the disclosure button")
        XCTAssertTrue(rig.window.firstResponder === first, "setup: it is the first responder")

        first.performClick(nil)
        rig.settle()
        try assertExpanded(rig, foldItem, "after Space on the focused disclosure")
        let opened = try disclosure(rig, foldItem)
        XCTAssertTrue(rig.window.firstResponder === opened,
                      "focus is on the row's current disclosure, not lost with the rebuilt row: \(String(describing: rig.window.firstResponder))")

        opened.performClick(nil)
        rig.settle()
        try assertCollapsed(rig, foldItem, "after Space again")
        let closed = try disclosure(rig, foldItem)
        XCTAssertTrue(rig.window.firstResponder === closed,
                      "and still after folding it again: \(String(describing: rig.window.firstResponder))")
    }

    func testTogglingWithTheMouseWhileAnotherFieldHasFocusDoesNotMoveFocusToTheTracker() throws {
        let (rig, _) = try foldRig()
        XCTAssertTrue(rig.window.makeFirstResponder(rig.composer), "setup: the composer has focus")

        try click(rig, foldItem)
        try assertExpanded(rig, foldItem, "after the click")
        let owner = rig.window.firstResponder as? NSView
        let button = try disclosure(rig, foldItem)
        XCTAssertFalse(owner === button, "the disclosure did not take focus")
        XCTAssertFalse(owner.map { $0 === rig.pane || $0.isDescendant(of: rig.pane) } ?? false,
                       "nothing in the tracker took focus: \(String(describing: rig.window.firstResponder))")
    }

    func testWithTheDisclosureFocusedABoardUpdateToTheItemKeepsFocusOnItsRebuiltDisclosure() throws {
        let (rig, script) = try foldRig()
        let first = try disclosure(rig, foldItem)
        XCTAssertTrue(rig.window.makeFirstResponder(first), "setup: the disclosure has focus")

        var newer = script
        newer.setVersion(8)
        try newer.setNote(foldItem, paragraphs: Self.noteLines + ["Runbook step three: confirm the canary"])
        try newer.setStatus(foldItem, "blocked")
        rig.push(newer)

        let rebuilt = try disclosure(rig, foldItem)
        XCTAssertFalse(rebuilt === first, "setup: the agent's update rebuilt the row's button")
        XCTAssertTrue(rig.window.firstResponder === rebuilt,
                      "focus follows the row's new disclosure: \(String(describing: rig.window.firstResponder))")
    }

    func testAnUpdateToAnItemWhoseDisclosureIsNotFocusedTakesNoFocus() throws {
        let (rig, script) = try foldRig()
        XCTAssertTrue(rig.window.makeFirstResponder(rig.composer), "setup: the composer has focus")
        var newer = script
        newer.setVersion(8)
        try newer.setStatus(foldItem, "blocked")
        rig.push(newer)
        XCTAssertFalse(rig.window.firstResponder === (try disclosure(rig, foldItem)), "the rebuilt button did not take focus")
    }

    func testTheDisclosureCanTakeKeyboardFocusSoSpaceCanOperateIt() throws {
        let (rig, _) = try foldRig()
        let button = try disclosure(rig, foldItem)
        XCTAssertTrue(button.acceptsFirstResponder, "the disclosure accepts first responder")
        XCTAssertTrue(button.canBecomeKeyView, "the disclosure is in the key-view loop")
        XCTAssertFalse(button.refusesFirstResponder)
    }

    // MARK: - The fold's change highlight

    func testTheUsersOwnFoldToggleDoesNotFlashTheChangeHighlightButARealChangeDoes() throws {
        let (rig, script) = try foldRig()
        XCTAssertTrue(rig.pane.rowViews.values.allSatisfy { !$0.isHighlighted }, "setup: nothing is highlighted")

        try click(rig, foldItem)
        try assertExpanded(rig, foldItem, "setup: the click opened the item")
        XCTAssertTrue(rig.pane.rowViews.values.allSatisfy { !$0.isHighlighted }, "opening is not a content change")
        XCTAssertTrue(rig.scheduler.scheduled.isEmpty, "and nothing was scheduled to clear a highlight")

        try click(rig, foldItem)
        try assertCollapsed(rig, foldItem, "setup: the click closed it")
        XCTAssertTrue(rig.pane.rowViews.values.allSatisfy { !$0.isHighlighted }, "closing is not a content change either")

        var newer = script
        newer.setVersion(8)
        try newer.setNote(foldItem, paragraphs: Self.noteLines + ["Runbook step three: confirm the canary"])
        rig.push(newer)
        XCTAssertTrue(try row(rig, foldItem).isHighlighted, "a real content change still flashes")
    }

    // MARK: - The disclosure's click area

    func testTheFoldClickAreaCoversTheMarkAndFoldColumnsAndStopsWhereTheTitleStarts() throws {
        let (rig, _) = try foldRig()
        let item = try row(rig, foldItem)
        let title = try XCTUnwrap(item.textViews.first)
        let button = try disclosure(rig, foldItem)
        XCTAssertEqual(item.foldHitRect.minX, TrackerRowView.hPad, accuracy: 0.01, "starts at the mark column")
        XCTAssertEqual(item.foldHitRect.maxX, title.frame.minX, accuracy: 0.01, "ends exactly where the title starts")
        XCTAssertLessThanOrEqual(button.frame.maxX, title.frame.minX + 0.01, "the chevron does not overlap the title")
        XCTAssertGreaterThanOrEqual(button.frame.minX, TrackerRowView.hPad + TrackerRowView.markWidth - 0.01,
                                    "the chevron does not overlap the status mark")

        func hit(_ x: CGFloat) -> NSView? {
            item.hitTest(item.convert(NSPoint(x: x, y: 10), to: item.superview))
        }
        for x in [TrackerRowView.hPad + 1, 20, TrackerRowView.hPad + TrackerRowView.markWidth + 1, title.frame.minX - 1] {
            let target = try XCTUnwrap(hit(x), "x=\(x) hits something")
            XCTAssertTrue(target === item || target === button, "x=\(x) is on the fold's click area, got \(target)")
        }
        for x in [title.frame.minX + 0.5, title.frame.minX + 4, title.frame.minX + 8] {
            let target = try XCTUnwrap(hit(x), "x=\(x) hits something")
            XCTAssertTrue(target === title || target.isDescendant(of: title), "x=\(x) is the title's, got \(target)")
        }
    }

    func testClickingTheStatusMarkColumnOfAFoldableItemTogglesItAndAPlainItemIgnoresIt() throws {
        let (rig, _) = try foldRig()
        func mouseDown(_ id: String, atX x: CGFloat) throws {
            let item = try row(rig, id)
            let inWindow = item.convert(NSPoint(x: x, y: 10), to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown, location: inWindow, modifierFlags: [], timestamp: 0,
                windowNumber: rig.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            item.mouseDown(with: event)
            rig.settle()
        }
        try mouseDown(foldItem, atX: TrackerRowView.hPad + 4)
        try assertExpanded(rig, foldItem, "a click on the status mark opens the item")
        try mouseDown(foldItem, atX: TrackerRowView.hPad + 4)
        try assertCollapsed(rig, foldItem, "and again closes it")
        try mouseDown(foldItem, atX: 60)
        try assertCollapsed(rig, foldItem, "a click on the title does not toggle")
        try mouseDown(plainItem, atX: TrackerRowView.hPad + 4)
        XCTAssertNil(try row(rig, plainItem).disclosureButton, "an item with nothing under a fold has no fold to toggle")
    }

    // MARK: - Accessibility

    func testTheDisclosureIsADisclosureTriangleThatSaysItsItemAndWhetherItIsOpen() throws {
        let (rig, _) = try foldRig()
        let closed = try disclosure(rig, foldItem)
        XCTAssertEqual(closed.accessibilityRole(), NSAccessibility.Role.disclosureTriangle)
        XCTAssertEqual(closed.accessibilityLabel(), "Details: \(Self.title)")
        XCTAssertEqual(closed.state, .off, "collapsed reads as off")
        XCTAssertEqual(accessibilityValueSaysExpanded(closed), false,
                       "collapsed: the accessibility value says so (\(String(describing: closed.accessibilityValue())))")

        try click(rig, foldItem)
        let opened = try disclosure(rig, foldItem)
        XCTAssertEqual(opened.accessibilityRole(), NSAccessibility.Role.disclosureTriangle)
        XCTAssertEqual(opened.accessibilityLabel(), "Details: \(Self.title)", "the label names the item whichever state it is in")
        XCTAssertEqual(opened.state, .on, "expanded reads as on")
        XCTAssertEqual(accessibilityValueSaysExpanded(opened), true,
                       "expanded: the accessibility value says so (\(String(describing: opened.accessibilityValue())))")
    }

    func testTheDisclosureOfANoteOnlyItemIsLabelledWithItsWholeShortText() throws {
        let (rig, _) = try foldRig()
        let item = try XCTUnwrap(try row(rig, noteOnlyItem).row.item)
        let button = try disclosure(rig, noteOnlyItem)
        XCTAssertEqual(button.accessibilityLabel(), "Details: \(item.title)")
        XCTAssertEqual(item.title, "Check referral 4411 duplicate", "setup: the golden item's text is its title")
    }

    // MARK: - The reader's line

    private func makeHarness(size: NSSize = NSSize(width: 380, height: 420)) throws -> TrackerGateHarness {
        let window = makeRigWindow(self, size: size)
        let harness = try TrackerGateHarness(self)
        let content = window.contentView!
        harness.pane.frame = content.bounds
        harness.pane.autoresizingMask = [.width, .height]
        content.addSubview(harness.pane)
        harness.layout()
        try harness.push()
        harness.layout()
        try harness.start(.mid)
        return harness
    }

    func testOpeningAnItemAboveTheViewportDoesNotMoveTheLineBeingRead() throws {
        let h = try makeHarness()
        let viewport = h.pane.clipView.bounds
        let above = try h.requireItem(.above)
        let key = TrackerRow.itemKey(above.id)
        guard let frame = h.frame(of: key), frame.maxY <= viewport.minY else {
            return XCTFail("setup: \(above.id) is not above the viewport (\(String(describing: h.frame(of: key))) vs \(viewport))")
        }
        // Make it foldable whatever it was: a note of several lines, folded away.
        try h.mutate { try $0.setNote(above.id, lines: ["Above one", "Above two", "Above three", "Above four"]) }
        let button = try XCTUnwrap(h.pane.rowViews[key]?.disclosureButton, "setup: \(above.id) folds")
        XCTAssertEqual(button.state, .off, "setup: it is collapsed")

        let before = h.pane.anchorSnapshot(windowIndex: 0)
        let read = try XCTUnwrap(before.firstVisible, "setup: something is being read")
        XCTAssertNotEqual(read.rowKey, key, "setup: the opened item is not the one being read")
        let screenBefore = try XCTUnwrap(h.screenTop(of: read.rowKey))
        let heightBefore = try XCTUnwrap(h.frame(of: key)?.height)

        button.performClick(nil)
        h.layout()

        let heightOpen = try XCTUnwrap(h.frame(of: key)?.height)
        XCTAssertGreaterThan(heightOpen, heightBefore + 10, "opening it made the row taller")
        func assertStayed(_ what: String) throws {
            let after = h.pane.anchorSnapshot(windowIndex: 0)
            XCTAssertEqual(after.firstVisible?.rowKey, read.rowKey, "\(what): the row being read is still the first visible")
            let drift = abs((after.firstVisible?.offsetPt ?? .infinity) - read.offsetPt)
            XCTAssertLessThan(drift, 1, "\(what): the reader's offset into the row moved \(drift) pt")
            let moved = abs(try XCTUnwrap(h.screenTop(of: read.rowKey)) - screenBefore)
            XCTAssertLessThan(moved, 1, "\(what): the line being read moved \(moved) pt on screen")
        }
        try assertStayed("after opening it")

        let reopened = try XCTUnwrap(h.pane.rowViews[key]?.disclosureButton)
        reopened.performClick(nil)
        h.layout()
        XCTAssertEqual(try XCTUnwrap(h.frame(of: key)?.height), heightBefore, accuracy: 0.5, "folding it again restores its height")
        try assertStayed("after folding it again")
    }

    // MARK: - The Waiting strip

    func testTheWaitingStripShowsAnItemsTitleNeverItsRestOrItsNote() throws {
        let tag = Fx.uniqueTag()
        let rig = Fx.makeRig(self, tag: tag)
        var script = try TrackerBoardScript(tag: tag)
        let needsYou = "docum-1740"
        XCTAssertEqual(script.status(needsYou), "needs-you", "setup: the golden item waits on the person")
        try script.setText(needsYou, Self.longText)
        try script.setNote(needsYou, paragraphs: Self.noteLines)
        rig.push(script)

        let strip = rig.pane.strip
        XCTAssertTrue(strip.text.contains(Self.title), "the strip names the item by its title: \(strip.text)")
        XCTAssertFalse(strip.text.contains(Self.body), "the strip does not carry the rest of the text: \(strip.text)")
        XCTAssertFalse(strip.text.contains("Runbook step"), "or the note: \(strip.text)")
        XCTAssertTrue(strip.strip.entries.contains { $0.text == Self.title }, "the entry's text is the title alone")
        let everything = Fx.allTexts(in: strip).joined(separator: "\n") + "\n" + (strip.toolTip ?? "")
        XCTAssertFalse(everything.contains(Self.body), "nothing in the strip's views or tooltip has the rest of the text")
        XCTAssertFalse(everything.contains("Runbook step"), "nor the note")
    }

    // MARK: - tracker show

    func testTrackerShowReportsEachItemsTitleBodyLeadFoldableAndExpanded() throws {
        let (rig, _) = try foldRig()
        func item(_ id: String) throws -> Obj {
            let sections = rig.pane.showReport()["sections"] as? [Obj] ?? []
            let all = sections.flatMap { $0["items"] as? [Obj] ?? [] }
            return try XCTUnwrap(all.first { ($0["id"] as? String) == id }, "tracker show lists \(id)")
        }

        let long = try item(foldItem)
        XCTAssertEqual(long["title"] as? String, Self.title)
        XCTAssertEqual(long["body_lead"] as? String, Self.body)
        XCTAssertEqual(long["foldable"] as? Bool, true)
        XCTAssertEqual(long["expanded"] as? Bool, false)
        XCTAssertEqual(long["text"] as? String, Self.longText, "the item's own text is reported whole")

        let noteOnly = try item(noteOnlyItem)
        XCTAssertEqual(noteOnly["title"] as? String, "Check referral 4411 duplicate")
        XCTAssertTrue(noteOnly["body_lead"] is NSNull, "no rest of the text: null, not an empty string")
        XCTAssertEqual(noteOnly["foldable"] as? Bool, true, "a note alone makes it foldable")
        XCTAssertEqual(noteOnly["expanded"] as? Bool, false)

        let plain = try item(plainItem)
        XCTAssertEqual(plain["title"] as? String, "Review queue job 8812")
        XCTAssertTrue(plain["body_lead"] is NSNull)
        XCTAssertEqual(plain["foldable"] as? Bool, false)
        XCTAssertEqual(plain["expanded"] as? Bool, false, "an item with nothing to open is never expanded")

        try click(rig, foldItem)
        let opened = try item(foldItem)
        XCTAssertEqual(opened["expanded"] as? Bool, true, "tracker show follows the click")
        XCTAssertEqual(opened["foldable"] as? Bool, true)
        XCTAssertEqual(opened["title"] as? String, Self.title, "the title is the same open or closed")
        XCTAssertEqual(opened["body_lead"] as? String, Self.body)
        XCTAssertEqual(opened["shown_expanded"] as? Bool, true, "and so does what the view shows")
        XCTAssertEqual(try item(noteOnlyItem)["expanded"] as? Bool, false, "another item stays closed")

        try click(rig, foldItem)
        XCTAssertEqual(try item(foldItem)["expanded"] as? Bool, false)
    }
}
