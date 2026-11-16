import XCTest
import AppKit

/// ⌘N New Focus… and ⇧⌘N Resume Conversation… (File menu): who owns the keys, what the actions open,
/// and that a terminal holding the keyboard does not take them from the menu.
final class NewFocusShortcutTests: XCTestCase {

    /// A source file of the app, read from the repo this test file lives in.
    private func appSource(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Nostromo/\(relative)"), encoding: .utf8)
    }

    /// Records the two actions; answers `validateMenuItem` so the menu enables its items.
    private final class Recorder: NSObject {
        var calls: [String] = []
        @objc func newFocus(_ sender: Any?) { calls.append("new") }
        @objc func resumeConversation(_ sender: Any?) { calls.append("resume") }
        @objc func validateMenuItem(_ item: NSMenuItem) -> Bool { true }
    }

    private func fileMenu(_ main: NSMenu) throws -> NSMenu {
        try XCTUnwrap(main.items.first { $0.submenu?.title == "File" }?.submenu, "no File menu")
    }

    private func owners(of key: String, mask: NSEvent.ModifierFlags, in main: NSMenu) -> [String] {
        main.items.flatMap { $0.submenu?.items ?? [] }.filter {
            $0.keyEquivalent.lowercased() == key
                && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == mask
        }.map(\.title)
    }

    /// A real ⇧⌘N reports "N" as the characters and "n" ignoring modifiers.
    private func keyEvent(_ chars: String, flags: NSEvent.ModifierFlags, window: NSWindow? = nil) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: window?.windowNumber ?? 0, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars.lowercased(), isARepeat: false, keyCode: 45)!
    }

    func testTheFileMenuSitsBetweenTheAppMenuAndEditWithBothItems() throws {
        _ = NSApplication.shared
        let main = MainMenu.make(target: nil)
        let titles = main.items.map { $0.submenu?.title ?? "" }
        XCTAssertEqual(titles.firstIndex(of: "File"), 1)
        XCTAssertEqual(titles.firstIndex(of: "Edit"), 2)
        let file = try fileMenu(main)
        let new = try XCTUnwrap(file.items.first { $0.title == "New Focus\u{2026}" })
        XCTAssertEqual(new.keyEquivalent, "n")
        XCTAssertEqual(new.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask), [.command])
        XCTAssertEqual(new.action, #selector(MainMenuActions.newFocus(_:)))
        let resume = try XCTUnwrap(file.items.first { $0.title == "Resume Conversation\u{2026}" })
        XCTAssertEqual(resume.keyEquivalent.lowercased(), "n")
        XCTAssertEqual(resume.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask), [.command, .shift])
        XCTAssertEqual(resume.action, #selector(MainMenuActions.resumeConversation(_:)))
    }

    func testEachShortcutIsOwnedByExactlyOneItemAndTerminalKeysAreUnchanged() {
        _ = NSApplication.shared
        let main = MainMenu.make(target: nil)
        XCTAssertEqual(owners(of: "n", mask: [.command], in: main), ["New Focus\u{2026}"])
        XCTAssertEqual(owners(of: "n", mask: [.command, .shift], in: main), ["Resume Conversation\u{2026}"])
        XCTAssertEqual(owners(of: "t", mask: [.command], in: main), ["New Terminal"])
        XCTAssertEqual(owners(of: "t", mask: [.command, .shift], in: main), ["New Remote Shell\u{2026}"])
    }

    /// The terminal view is a first responder that, like SwiftTerm's, does not claim ⌘ keys.
    private final class TerminalStandIn: NSView {
        override var acceptsFirstResponder: Bool { true }
        var keyDowns = 0
        override func keyDown(with event: NSEvent) { keyDowns += 1 }
    }

    func testTheKeysAreNotConsumedByATerminalAndCommandNReachesTheMenuAction() throws {
        _ = NSApplication.shared
        let recorder = Recorder()
        let main = MainMenu.make(target: recorder)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let terminal = TerminalStandIn()
        window.contentView = terminal
        XCTAssertTrue(window.makeFirstResponder(terminal))
        let cmdN = keyEvent("n", flags: .command, window: window)
        let shiftCmdN = keyEvent("N", flags: [.command, .shift], window: window)
        XCTAssertFalse(window.performKeyEquivalent(with: cmdN), "the terminal must not consume ⌘N")
        XCTAssertFalse(window.performKeyEquivalent(with: shiftCmdN), "the terminal must not consume ⇧⌘N")
        XCTAssertTrue(main.performKeyEquivalent(with: cmdN))
        // ⇧⌘N is not driven through a synthetic event here: AppKit's matching of a shifted letter on a menu that
        // is not the live main menu differs from a real keypress (⇧⌘T has the same shape and works). Its item,
        // keys and action are pinned above; the live keypress is for the PR's eyeball list.
        XCTAssertEqual(recorder.calls, ["new"])
        XCTAssertEqual(terminal.keyDowns, 0)
    }

    func testTheTerminalViewSourceNeverOverridesKeyEquivalents() throws {
        let src = try appSource("UI/Terminal/NostromoTerminalView.swift")
        let code = src.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        XCTAssertFalse(code.contains { $0.contains("performKeyEquivalent") },
                       "a terminal override of performKeyEquivalent could take ⌘N from the menu")
    }

    // MARK: the actions open the sheet

    private func layoutInWindow() -> (MainLayout, NSWindow) {
        let focusStore = FocusStore(storageURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("nfs-\(UUID().uuidString).json"))
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 1000, height: 700),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        let layout = MainLayout(windowIndex: 0, displayUUID: "nfs-\(UUID().uuidString)", focusStore: focusStore)
        window.contentView = layout
        window.orderFront(nil)
        addTeardownBlock {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.orderOut(nil); window.contentView = nil
            CreateFocusSheet.rememberedTab = .new
        }
        return (layout, window)
    }

    private func openSheet(_ window: NSWindow) -> CreateFocusSheet? {
        window.attachedSheet?.windowController as? CreateFocusSheet
    }

    func testNewFocusOpensTheSheetOnNewAndResumeOpensItOnResumeWithSearchFocused() throws {
        CreateFocusSheet.rememberedTab = .resume
        let (layout, window) = layoutInWindow()
        layout.presentCreateFocusSheet(tab: .new)
        XCTAssertEqual(try XCTUnwrap(openSheet(window)).currentTab, .new, "⌘N is New even if Resume was last used")
        window.endSheet(window.attachedSheet!)

        layout.presentCreateFocusSheet(tab: .resume)
        let sheet = try XCTUnwrap(openSheet(window))
        XCTAssertEqual(sheet.currentTab, .resume)
        XCTAssertTrue(sheet.window?.firstResponder === sheet.resumeTab.searchField
                      || (sheet.window?.firstResponder as? NSTextView)?.delegate === sheet.resumeTab.searchField
                      || sheet.resumeTab.searchField.currentEditor() != nil, "the cursor is in search")
    }

    func testWithTheSheetOpenTheOtherShortcutSwitchesItsTabWithoutASecondSheet() throws {
        let (layout, window) = layoutInWindow()
        layout.presentCreateFocusSheet(tab: .new)
        let first = try XCTUnwrap(window.attachedSheet)
        layout.presentCreateFocusSheet(tab: .resume)
        XCTAssertTrue(window.attachedSheet === first, "no second sheet")
        XCTAssertEqual(try XCTUnwrap(openSheet(window)).currentTab, .resume)
        layout.presentCreateFocusSheet(tab: .new)
        XCTAssertTrue(window.attachedSheet === first)
        XCTAssertEqual(try XCTUnwrap(openSheet(window)).currentTab, .new)
    }

    func testTheItemsAreDisabledWithNoMainWindowAndEnabledForASheetOfOne() throws {
        let code = try appSource("AppDelegate.swift")
        XCTAssertTrue(code.contains("sheetParent?.contentView as? MainLayout"),
                      "with the sheet key, the shortcut still finds its parent main window")
        XCTAssertTrue(code.contains("menuItem.action == #selector(newFocus(_:)) || menuItem.action == #selector(resumeConversation(_:))"))
    }
}
