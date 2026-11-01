import XCTest
import AppKit
import NostromoKit

// FV4: View ▸ Focus (⌥⌘←), View ▸ Show All Activity (⌥⌘→) and View ▸ Default for New Focuses.
//
// What these pin, from outside:
//   - the View menu sits between Edit and Terminal; its two pane items are a radio pair on ⌥⌘← / ⌥⌘→
//     and nothing else in the app takes those chords or any other chord twice;
//   - the chord reaches the transcript pane under the keyboard from the composer (without moving the
//     insertion point), while ⌥→ and ⌘→ stay the text view's own (word and line moves);
//   - with the keyboard in a terminal pane or a list the items act on the window's single visible
//     transcript pane; with none, or several, they are disabled;
//   - the radio state follows the target's effective mode; the Default submenu follows the store's default;
//   - a fold row's context menu offers the same two items after its Copy items.
//
// The mode actions change how the transcript is shown and nothing else: like `ModelShortcut` they are
// deliberately NOT `HumanGesture`-gated. Nothing about them reaches the agent.
//
// The main menu is the live one (`MainMenu.make(target: nil)`). Its exact set of key equivalents, and
// that no two share one, is pinned by `TrackerPaneViewTests.pinnedKeyEquivalents` (updated for ⌥⌘← and
// ⌥⌘→); the small item collector below is only for looking up titles, masks and targets.
//
// Not testable here: SwiftTerm's own `TerminalView` (the test bundle does not link SwiftTerm), so
// whether it lets ⌥⌘← through to the menu is checked by source scan and a stand-in only. And the app
// delegate (`AppDelegate` is not compiled into the tests) is stood in for by a copy of its three
// members, which a source scan ties to the real ones.

private typealias F = FoldFixtures
private typealias X = FocusFixtures

// MARK: - Stand-ins

/// A pane the transcript menu does not know: takes the keyboard, counts the keys it is handed.
private final class FV4TerminalStandIn: NSView {
    private(set) var keyDowns = 0
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { keyDowns += 1 }
}

/// What `AppDelegate.setTranscriptFocusMode`, `setTranscriptAllActivityMode` and `validateMenuItem` do
/// for the View items, with the key window passed in (a logic test has no key window).
private final class FV4DelegateStandIn: NSObject, NSMenuItemValidation {
    var keyWindow: NSWindow?

    @objc func setTranscriptFocusMode(_ sender: Any?) {
        TranscriptViewMenu.target(in: keyWindow)?.setTranscriptFocusMode(sender)
    }

    @objc func setTranscriptAllActivityMode(_ sender: Any?) {
        TranscriptViewMenu.target(in: keyWindow)?.setTranscriptAllActivityMode(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == TranscriptViewMenu.focusAction || menuItem.action == TranscriptViewMenu.allActivityAction {
            return TranscriptViewMenu.validate(menuItem, target: TranscriptViewMenu.target(in: keyWindow))
        }
        return true
    }
}

// MARK: - Tests

final class TranscriptViewMenuTests: XCTestCase {
    private let windows = WindowBag()
    private var previousMainMenu: NSMenu?
    private var announced: [String] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        previousMainMenu = NSApp.mainMenu
        announced = []
    }

    override func tearDown() {
        windows.tearDown()
        NSApp.mainMenu = previousMainMenu
        super.tearDown()
    }

    // MARK: Helpers

    private func allItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map { allItems(in: $0) } ?? []) }
    }

    private func viewMenu(of main: NSMenu) throws -> NSMenu {
        try XCTUnwrap(main.items.first { $0.submenu?.title == TranscriptViewMenu.menuTitle }?.submenu, "the main menu has a View menu")
    }

    private func modeItems(of main: NSMenu = MainMenu.make(target: nil)) throws -> (focus: NSMenuItem, allActivity: NSMenuItem) {
        let view = try viewMenu(of: main)
        return (try XCTUnwrap(view.item(withTitle: "Focus")), try XCTUnwrap(view.item(withTitle: "Show All Activity")))
    }

    private let relevantFlags: NSEvent.ModifierFlags = [.command, .option, .shift, .control]

    /// A key-down for ← or → as the keyboard sends it (arrows carry numeric-pad and function flags).
    private func arrowEvent(right: Bool, flags: NSEvent.ModifierFlags, window: NSWindow? = nil) throws -> NSEvent {
        let character = right ? "\u{F703}" : "\u{F702}"
        return try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags.union([.numericPad, .function]), timestamp: 0,
            windowNumber: window?.windowNumber ?? 0, context: nil, characters: character,
            charactersIgnoringModifiers: character, isARepeat: false, keyCode: right ? 124 : 123))
    }

    /// The item AppKit would run for this key: same key, same modifiers.
    private func menuItem(matching event: NSEvent, in menu: NSMenu) -> NSMenuItem? {
        let chord = event.modifierFlags.intersection(relevantFlags)
        return allItems(in: menu).first { item in
            !item.keyEquivalent.isEmpty && item.keyEquivalent == event.charactersIgnoringModifiers
                && item.keyEquivalentModifierMask.intersection(relevantFlags) == chord
        }
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: fv4RepoRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: The menu

    func testTheViewMenuSitsBetweenEditAndTerminal() {
        let titles = MainMenu.make(target: nil).items.map { $0.submenu?.title ?? "" }

        XCTAssertEqual(titles.count, 6, "App, Edit, View, Terminal, Debug, Session: \(titles)")
        XCTAssertEqual(Array(titles.dropFirst()), ["Edit", "View", "Terminal", "Debug", "Session"])
    }

    func testTheViewMenuHoldsFocusShowAllActivityAndTheDefaultSubmenu() throws {
        let view = try viewMenu(of: MainMenu.make(target: nil))

        XCTAssertEqual(view.items.map(\.title), ["Focus", "Show All Activity", "", "Default for New Focuses"])
        XCTAssertTrue(view.items[2].isSeparatorItem)
        let defaults = try XCTUnwrap(view.items[3].submenu)
        XCTAssertEqual(defaults.items.map(\.title), ["Focus", "All Activity"])
    }

    func testTheArrowChordsAreOnTheTwoModeItemsAndOnNoOtherItem() throws {
        let main = MainMenu.make(target: nil)
        let items = try modeItems(of: main)

        XCTAssertEqual(items.focus.keyEquivalent, "\u{F702}")
        XCTAssertEqual(items.focus.keyEquivalentModifierMask.intersection(relevantFlags), [.command, .option])
        XCTAssertEqual(items.allActivity.keyEquivalent, "\u{F703}")
        XCTAssertEqual(items.allActivity.keyEquivalentModifierMask.intersection(relevantFlags), [.command, .option])
        XCTAssertEqual(items.focus.action, #selector(TranscriptViewModeTarget.setTranscriptFocusMode(_:)))
        XCTAssertEqual(items.allActivity.action, #selector(TranscriptViewModeTarget.setTranscriptAllActivityMode(_:)))
        XCTAssertNil(items.focus.target, "no target: the action walks the responder chain from the keyboard")
        XCTAssertNil(items.allActivity.target)

        let arrows = allItems(in: main).filter { ["\u{F700}", "\u{F701}", "\u{F702}", "\u{F703}"].contains($0.keyEquivalent) }
        XCTAssertEqual(arrows.map(\.title).sorted(), ["Focus", "Show All Activity"], "no other item takes an arrow key")
    }

    func testNoTwoMenuItemsShareAKeyAndModifierPair() {
        var seen: [String: String] = [:]
        for item in allItems(in: MainMenu.make(target: nil)) where !item.keyEquivalent.isEmpty {
            let mask = item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
            let pair = "\(item.keyEquivalent)|\(mask.rawValue)"
            if let other = seen[pair] { XCTFail("\"\(other)\" and \"\(item.title)\" share \(pair)") }
            seen[pair] = item.title
        }
        XCTAssertTrue(seen.values.contains("Background Activity\u{2026}"), "precondition: \u{21E7}\u{2318}B is in the walk")
        XCTAssertTrue(seen.values.contains("Focus Staged Commands"), "precondition: the Terminal menu is in the walk")
    }

    func testNoItemAnywhereIsNamedToolActivity() {
        let main = MainMenu.make(target: nil)
        let titles = allItems(in: main).flatMap { [$0.title, $0.submenu?.title ?? ""] }

        XCTAssertFalse(titles.contains { $0.contains("Tool Activity") }, "the setting is Focus / All activity: \(titles)")
    }

    func testCommandPeriodStaysOnTheInputBarsStopButtonAndInNoMenu() throws {
        let bar = ReplInputBar(frame: NSRect(x: 0, y: 0, width: 600, height: 60))
        let stop = try XCTUnwrap(bar.subviews.compactMap { $0 as? NSButton }.first {
            $0.attributedTitle.string.contains("Stop") || $0.title.contains("Stop")
        })

        XCTAssertEqual(stop.keyEquivalent, ".")
        XCTAssertEqual(stop.keyEquivalentModifierMask, .command)
        XCTAssertFalse(allItems(in: MainMenu.make(target: nil)).contains { $0.keyEquivalent == "." },
                       "\u{2318}. is the Stop button's alone")
    }

    // MARK: Nothing else takes the chord

    func testNoKeyEquivalentOverrideInTheAppHandlesTheOptionCommandArrows() throws {
        var overrides: [String: Int] = [:]
        let arrowWord = try NSRegularExpression(pattern: "\\b12[34]\\b")
        for url in fv4SwiftFiles(under: fv4RepoRoot().appendingPathComponent("macOS/Nostromo")) {
            let code = fv4StrippingComments(try String(contentsOf: url, encoding: .utf8))
            let bodies = fv4FunctionBodies(named: "performKeyEquivalent", in: code)
            guard !bodies.isEmpty else { continue }
            overrides[url.lastPathComponent] = bodies.count
            for body in bodies {
                for forbidden in ["NSLeftArrowFunctionKey", "NSRightArrowFunctionKey", "F702", "F703", "leftArrow", "rightArrow"] {
                    XCTAssertFalse(body.contains(forbidden), "\(url.lastPathComponent): performKeyEquivalent mentions \(forbidden)")
                }
                XCTAssertNil(arrowWord.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
                             "\(url.lastPathComponent): performKeyEquivalent tests the arrow key codes")
            }
        }
        XCTAssertNotNil(overrides["TeriSurfaceView.swift"], "precondition: the scan found TeriSurfaceView's override")
        XCTAssertNotNil(overrides["SendToAgentSheet.swift"], "precondition: the scan found SendToAgentSheet's override")
    }

    func testTheTerminalPaneViewsTakeNoKeyEquivalentOfTheirOwn() throws {
        // The SwiftTerm view cannot be built here. What can be said is that the app's own subclass and
        // host do not claim key equivalents or the arrow function keys, so the chord is SwiftTerm's to
        // pass on (not provable without it: reported, not asserted).
        for file in ["NostromoTerminalView.swift", "TerminalPaneHostView.swift"] {
            let code = fv4StrippingComments(try source("macOS/Nostromo/UI/Terminal/\(file)"))
            XCTAssertFalse(code.contains("performKeyEquivalent"), "\(file) must not take key equivalents")
            XCTAssertFalse(code.contains("NSLeftArrowFunctionKey") || code.contains("NSRightArrowFunctionKey"), file)
        }
    }

    func testTheAppDelegateForwardsTheTwoActionsAndTheValidationToTheKeyWindowsPane() throws {
        let code = fv4StrippingComments(try source("macOS/Nostromo/AppDelegate.swift"))
        let target = "TranscriptViewMenu.target(in: NSApp.keyWindow)"

        for name in ["setTranscriptFocusMode", "setTranscriptAllActivityMode"] {
            let body = try XCTUnwrap(fv4FunctionBodies(named: "\(name)(", in: code).first, "AppDelegate implements \(name)")
            XCTAssertTrue(body.contains(target), "\(name) acts on the key window's pane")
            XCTAssertTrue(body.contains("\(name)(sender)"), "\(name) forwards the same action")
        }
        let validators = fv4FunctionBodies(named: "validateMenuItem(", in: code)
        XCTAssertTrue(validators.contains { $0.contains("TranscriptViewMenu.validate") && $0.contains(target) },
                      "AppDelegate validates the two items against the key window's pane")
    }

    // MARK: Context menus

    private func assertModeItemsFollowCopyItems(in menu: NSMenu, file: StaticString = #filePath, line: UInt = #line) {
        let items = menu.items
        XCTAssertGreaterThanOrEqual(items.count, 4, "copies, a separator and the two mode items", file: file, line: line)
        let tail = Array(items.suffix(3))
        XCTAssertTrue(tail[0].isSeparatorItem, "a separator before the mode items", file: file, line: line)
        XCTAssertEqual(tail[1].title, "Focus", file: file, line: line)
        XCTAssertEqual(tail[1].action, TranscriptViewMenu.focusAction, file: file, line: line)
        XCTAssertEqual(tail[2].title, "Show All Activity", file: file, line: line)
        XCTAssertEqual(tail[2].action, TranscriptViewMenu.allActivityAction, file: file, line: line)
        for item in tail.dropFirst() {
            XCTAssertNil(item.target, "no target: they act on the pane the row is in", file: file, line: line)
            XCTAssertEqual(item.keyEquivalent, "", "the main menu owns the shortcuts", file: file, line: line)
        }
        let copies = items.dropLast(3)
        XCTAssertFalse(copies.isEmpty, file: file, line: line)
        XCTAssertTrue(copies.allSatisfy { $0.title.hasPrefix("Copy") }, "the mode items come after the Copy items: \(items.map(\.title))",
                      file: file, line: line)
    }

    func testAToolGroupRowsContextMenuEndsWithTheTwoModeItemsAfterItsCopyItems() throws {
        let turn = F.turn([X.message("m")] + F.run(3, prefix: "c") + [F.chip()])
        let group = try XCTUnwrap(F.groups(of: turn).first)
        let row = ToolGroupRowView(group: group, isExpanded: false, payloadAvailable: true)

        assertModeItemsFollowCopyItems(in: row.contextMenu())
    }

    func testAnActivityRowsContextMenuEndsWithTheTwoModeItemsAfterItsCopyItems() throws {
        let turn = F.turn([X.message("A")] + F.run(2, prefix: "a") + [X.message("B")] + F.run(2, prefix: "b")
                          + [X.message("C"), F.chip()])
        let segment = try XCTUnwrap(X.segments(of: turn).first)
        let header = ActivityRowHeaderView(segment: segment, isExpanded: false, payloadAvailable: true)

        assertModeItemsFollowCopyItems(in: header.contextMenu())
    }

    // MARK: The composer

    private struct Typed {
        let pane: ReplView
        let window: NSWindow
        let world: FV4StoreWorld
        let tag: String
        var text: NSTextView { pane.composerBar.textView }
    }

    private func typedPane(_ content: String = "alpha beta gamma", selection: NSRange = NSRange(location: 6, length: 4)) -> Typed {
        let world = FV4StoreWorld(self)
        let tag = "fv4-menu-\(UUID().uuidString)"
        let window = windows.make(width: 900, height: 700)
        let pane = fv4MakePane(tag: tag, store: world.store, in: window)
        pane.announceModeChange = { [weak self] text in self?.announced.append(text) }
        window.alphaValue = 0
        window.orderFront(nil)
        fv4Settle(window)
        let typed = Typed(pane: pane, window: window, world: world, tag: tag)
        typed.text.string = content
        XCTAssertTrue(window.makeFirstResponder(typed.text), "precondition: the composer holds the keyboard")
        typed.text.setSelectedRange(selection)
        return typed
    }

    func testTheModeChordInTheComposerSwitchesTheFocusAndLeavesTheInsertionPoint() throws {
        let typed = typedPane()
        let main = MainMenu.make(target: nil)
        let responder = try XCTUnwrap(typed.window.firstResponder)

        // The chord names the item (same key, same modifiers) and the item's action goes down the
        // responder chain from the composer: the same route a real key takes.
        let right = try XCTUnwrap(menuItem(matching: try arrowEvent(right: true, flags: [.command, .option], window: typed.window), in: main))
        XCTAssertEqual(right.title, "Show All Activity")
        let rightAction = try XCTUnwrap(right.action)
        XCTAssertTrue(responder.tryToPerform(rightAction, with: right), "the pane catches the action")
        XCTAssertEqual(typed.world.store.explicitMode(tag: typed.tag), .allActivity)
        XCTAssertEqual(announced, ["Showing all activity"])
        XCTAssertEqual(typed.text.selectedRange(), NSRange(location: 6, length: 4), "the insertion point did not move")
        XCTAssertEqual(typed.text.string, "alpha beta gamma")

        let left = try XCTUnwrap(menuItem(matching: try arrowEvent(right: false, flags: [.command, .option], window: typed.window), in: main))
        XCTAssertEqual(left.title, "Focus")
        let leftAction = try XCTUnwrap(left.action)
        XCTAssertTrue(responder.tryToPerform(leftAction, with: left))
        XCTAssertEqual(typed.world.store.explicitMode(tag: typed.tag), .focus)
        XCTAssertEqual(announced, ["Showing all activity", "Focus: activity folded"])
        XCTAssertEqual(typed.text.selectedRange(), NSRange(location: 6, length: 4))
    }

    func testTheModeChordThroughTheMainMenuSwitchesTheFocusWhenTheMenuCanRoute() throws {
        let typed = typedPane()
        let main = MainMenu.make(target: nil)
        NSApp.mainMenu = main
        let event = try arrowEvent(right: true, flags: [.command, .option], window: typed.window)
        let item = try XCTUnwrap(menuItem(matching: event, in: main))
        let action = try XCTUnwrap(item.action)
        try XCTSkipUnless((NSApp.target(forAction: action, to: nil, from: item) as AnyObject?) === typed.pane,
                          "the test process has no key window to route a nil-target menu action from")

        let handled = main.performKeyEquivalent(with: event)

        XCTAssertTrue(handled)
        XCTAssertEqual(typed.world.store.explicitMode(tag: typed.tag), .allActivity)
        XCTAssertEqual(typed.text.selectedRange(), NSRange(location: 6, length: 4))
    }

    func testOptionArrowAndCommandArrowAreNotMenuShortcuts() throws {
        let main = MainMenu.make(target: nil)

        let combos: [NSEvent.ModifierFlags] = [[.option], [.command], [], [.shift, .option], [.control, .option, .command]]
        for right in [true, false] {
            for flags in combos {
                let event = try arrowEvent(right: right, flags: flags)
                XCTAssertNil(menuItem(matching: event, in: main),
                             "\(right ? "right" : "left") arrow with \(flags.rawValue) must stay the text view's own")
            }
        }
    }

    func testOptionArrowAndCommandArrowStillMoveTheInsertionPointAndSwitchNothing() throws {
        let typed = typedPane("alpha beta gamma", selection: NSRange(location: 0, length: 0))
        func key(_ flags: NSEvent.ModifierFlags) throws -> NSEvent { try arrowEvent(right: true, flags: flags, window: typed.window) }

        // A plain → is the control: where this process cannot turn a key into an edit command, nothing
        // below would mean anything.
        typed.text.keyDown(with: try key([]))
        try XCTSkipUnless(typed.text.selectedRange() == NSRange(location: 1, length: 0),
                          "this process cannot interpret key events in a text view")

        typed.text.setSelectedRange(NSRange(location: 0, length: 0))
        typed.text.keyDown(with: try key([.option]))
        XCTAssertGreaterThan(typed.text.selectedRange().location, 1, "\u{2325}\u{2192} moves by word")

        typed.text.setSelectedRange(NSRange(location: 0, length: 0))
        typed.text.keyDown(with: try key([.command]))
        XCTAssertEqual(typed.text.selectedRange().location, (typed.text.string as NSString).length, "\u{2318}\u{2192} moves to the end of the line")

        XCTAssertNil(typed.world.store.explicitMode(tag: typed.tag), "neither switched the mode")
        XCTAssertEqual(announced, [])
        XCTAssertEqual(typed.text.string, "alpha beta gamma")
    }

    // MARK: Focus in a terminal pane or a list

    private struct Split {
        let window: NSWindow
        let repls: [ReplView]
        let terminal: FV4TerminalStandIn
        let world: FV4StoreWorld
    }

    /// One window: `panes` transcript panes side by side, then a stand-in terminal pane.
    private func split(panes: Int) -> Split {
        let world = FV4StoreWorld(self)
        let window = windows.make(width: 900, height: 700)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let repls = (0 ..< panes).map { index in
            fv4MakePane(tag: "fv4-split-\(index)-\(UUID().uuidString)", store: world.store, in: window,
                        frame: NSRect(x: CGFloat(index) * 300, y: 0, width: 300, height: 700), asContentView: false)
        }
        let terminal = FV4TerminalStandIn(frame: NSRect(x: CGFloat(panes) * 300, y: 0, width: 300, height: 700))
        window.contentView?.addSubview(terminal)
        window.alphaValue = 0
        window.orderFront(nil)
        fv4Settle(window)
        return Split(window: window, repls: repls, terminal: terminal, world: world)
    }

    func testWithATerminalHoldingTheKeyboardTheItemsActOnTheWindowsOnlyTranscriptPane() throws {
        let s = split(panes: 1)
        XCTAssertTrue(s.window.makeFirstResponder(s.terminal))
        let items = try modeItems()
        let delegate = FV4DelegateStandIn()
        delegate.keyWindow = s.window

        // Nothing on the terminal's own chain takes the action, so it goes on to the app delegate.
        XCTAssertFalse(s.terminal.tryToPerform(TranscriptViewMenu.allActivityAction, with: items.allActivity))
        XCTAssertTrue(delegate.validateMenuItem(items.allActivity), "enabled: there is exactly one pane to act on")
        XCTAssertTrue(delegate.validateMenuItem(items.focus))
        XCTAssertEqual(items.focus.state, .on)
        XCTAssertEqual(items.allActivity.state, .off)

        delegate.setTranscriptAllActivityMode(items.allActivity)

        XCTAssertTrue(s.repls[0].transcriptShowsAllActivity)
        XCTAssertEqual(s.terminal.keyDowns, 0, "no key reached the terminal")
        XCTAssertTrue(delegate.validateMenuItem(items.allActivity))
        XCTAssertEqual(items.allActivity.state, .on, "the radio follows the pane's mode")
        XCTAssertEqual(items.focus.state, .off)

        delegate.setTranscriptFocusMode(items.focus)
        XCTAssertFalse(s.repls[0].transcriptShowsAllActivity)
    }

    func testWithNoTranscriptPaneInTheWindowTheItemsAreDisabled() throws {
        let s = split(panes: 0)
        XCTAssertTrue(s.window.makeFirstResponder(s.terminal))
        let items = try modeItems()
        let delegate = FV4DelegateStandIn()
        delegate.keyWindow = s.window

        XCTAssertNil(TranscriptViewMenu.target(in: s.window))
        XCTAssertFalse(delegate.validateMenuItem(items.focus))
        XCTAssertFalse(delegate.validateMenuItem(items.allActivity))
        XCTAssertEqual(items.focus.state, .off)
        XCTAssertEqual(items.allActivity.state, .off)
        delegate.setTranscriptAllActivityMode(items.allActivity)   // a no-op, not a crash
        XCTAssertEqual(s.terminal.keyDowns, 0)
    }

    func testWithTwoTranscriptPanesAndTheKeyboardInNeitherTheItemsAreDisabled() throws {
        let s = split(panes: 2)
        XCTAssertTrue(s.window.makeFirstResponder(s.terminal))
        let items = try modeItems()
        let delegate = FV4DelegateStandIn()
        delegate.keyWindow = s.window

        XCTAssertNil(TranscriptViewMenu.target(in: s.window), "which pane? neither is named")
        XCTAssertFalse(delegate.validateMenuItem(items.focus))
        XCTAssertFalse(delegate.validateMenuItem(items.allActivity))
        delegate.setTranscriptAllActivityMode(items.allActivity)
        XCTAssertFalse(s.repls[0].transcriptShowsAllActivity)
        XCTAssertFalse(s.repls[1].transcriptShowsAllActivity, "neither pane changed")
    }

    func testThePaneHoldingTheKeyboardWinsWhenTwoAreVisible() throws {
        let s = split(panes: 2)
        let items = try modeItems()
        let delegate = FV4DelegateStandIn()
        delegate.keyWindow = s.window

        XCTAssertTrue(s.window.makeFirstResponder(s.repls[1].composerBar.textView))
        XCTAssertTrue(TranscriptViewMenu.target(in: s.window) === s.repls[1])
        XCTAssertTrue(delegate.validateMenuItem(items.allActivity))
        XCTAssertTrue(s.window.firstResponder?.tryToPerform(TranscriptViewMenu.allActivityAction, with: items.allActivity) == true)
        XCTAssertTrue(s.repls[1].transcriptShowsAllActivity)
        XCTAssertFalse(s.repls[0].transcriptShowsAllActivity, "not the other pane")

        XCTAssertTrue(s.window.makeFirstResponder(s.repls[0].composerBar.textView))
        XCTAssertTrue(TranscriptViewMenu.target(in: s.window) === s.repls[0])
    }

    func testAHiddenPaneIsNotACandidate() throws {
        let s = split(panes: 2)
        s.repls[1].isHidden = true
        XCTAssertTrue(s.window.makeFirstResponder(s.terminal))

        XCTAssertTrue(TranscriptViewMenu.target(in: s.window) === s.repls[0], "the one visible pane")
    }

    // MARK: The radio and the Default submenu

    func testTheRadioPairFollowsTheTargetsEffectiveMode() throws {
        let world = FV4StoreWorld(self)
        let window = windows.make(width: 900, height: 700)
        let pane = fv4MakePane(store: world.store, in: window)
        let items = try modeItems()

        XCTAssertTrue(TranscriptViewMenu.validate(items.focus, target: pane))
        XCTAssertTrue(TranscriptViewMenu.validate(items.allActivity, target: pane))
        XCTAssertEqual([items.focus.state, items.allActivity.state], [.on, .off], "Focus is checked in Focus")

        pane.setTranscriptAllActivityMode(nil)
        _ = TranscriptViewMenu.validate(items.focus, target: pane)
        _ = TranscriptViewMenu.validate(items.allActivity, target: pane)
        XCTAssertEqual([items.focus.state, items.allActivity.state], [.off, .on], "Show All Activity is checked in All activity")

        // A focus with no choice shows the default.
        let follower = fv4MakePane(store: world.store, in: windows.make(width: 900, height: 700, x: 100, y: 100))
        world.store.defaultMode = .allActivity
        _ = TranscriptViewMenu.validate(items.focus, target: follower)
        _ = TranscriptViewMenu.validate(items.allActivity, target: follower)
        XCTAssertEqual([items.focus.state, items.allActivity.state], [.off, .on], "the effective mode, not only the explicit one")
    }

    func testTheItemsAreDisabledAndUncheckedWithNoTarget() throws {
        let items = try modeItems()
        items.focus.state = .on
        items.allActivity.state = .on

        XCTAssertFalse(TranscriptViewMenu.validate(items.focus, target: nil))
        XCTAssertFalse(TranscriptViewMenu.validate(items.allActivity, target: nil))
        XCTAssertEqual([items.focus.state, items.allActivity.state], [.off, .off])
    }

    private func installedMenu(store: TranscriptFoldStore) -> NSMenu {
        let main = NSMenu()
        for title in ["App", "Edit", "Terminal"] {
            let item = NSMenuItem()
            item.submenu = NSMenu(title: title)
            main.addItem(item)
        }
        TranscriptViewMenu.install(in: main, store: store)
        return main
    }

    func testTheDefaultSubmenuSetsTheGlobalDefaultAndItsRadioFollowsIt() throws {
        let world = FV4StoreWorld(self)
        let main = installedMenu(store: world.store)
        XCTAssertEqual(main.items.map { $0.submenu?.title ?? "" }, ["App", "Edit", "View", "Terminal"])
        let defaults = try XCTUnwrap(try viewMenu(of: main).item(withTitle: TranscriptViewMenu.defaultSubmenuTitle)?.submenu)
        let focus = try XCTUnwrap(defaults.item(withTitle: "Focus"))
        let all = try XCTUnwrap(defaults.item(withTitle: "All Activity"))
        let handler = try XCTUnwrap(focus.target as? NSMenuItemValidation)
        world.store.setMode(tag: "fv4-explicit", .focus)

        XCTAssertTrue(handler.validateMenuItem(focus))
        XCTAssertTrue(handler.validateMenuItem(all))
        XCTAssertEqual([focus.state, all.state], [.on, .off], "the default starts as Focus")

        let allAction = try XCTUnwrap(all.action)
        XCTAssertTrue(NSApp.sendAction(allAction, to: all.target, from: all))

        XCTAssertEqual(world.store.defaultMode, .allActivity)
        XCTAssertTrue(handler.validateMenuItem(focus))
        XCTAssertTrue(handler.validateMenuItem(all))
        XCTAssertEqual([focus.state, all.state], [.off, .on])
        XCTAssertEqual(world.store.explicitMode(tag: "fv4-explicit"), .focus, "changing the default never flips a focus with a choice")
    }

    func testTheDefaultSubmenuRadioIsRefreshedWhenTheMenuUpdates() throws {
        let world = FV4StoreWorld(self)
        let main = installedMenu(store: world.store)
        let defaults = try XCTUnwrap(try viewMenu(of: main).item(withTitle: TranscriptViewMenu.defaultSubmenuTitle)?.submenu)
        world.store.defaultMode = .allActivity
        defaults.items.forEach { $0.state = .mixed }   // stale on purpose

        defaults.update()

        XCTAssertEqual(defaults.items.map(\.state), [.off, .on], "All Activity is checked after the default became All activity")
    }
}
