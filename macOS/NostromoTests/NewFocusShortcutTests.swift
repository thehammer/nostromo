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
    private func keyEvent(_ chars: String, flags: NSEvent.ModifierFlags, window: NSWindow? = nil, keyCode: UInt16 = 45) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: window?.windowNumber ?? 0, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars.lowercased(), isARepeat: false, keyCode: keyCode)!
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
        // Exactly ⌘: a mask that also tolerated shift could swallow ⇧⌘N.
        XCTAssertEqual(new.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask), [.command])
        XCTAssertFalse(new.keyEquivalentModifierMask.contains(.shift))
        XCTAssertEqual(new.action, #selector(MainMenuActions.newFocus(_:)))
        let resume = try XCTUnwrap(file.items.first { $0.title == "Resume Conversation\u{2026}" })
        // The same form as ⇧⌘T (New Remote Shell): a lowercase key with [.command, .shift].
        XCTAssertEqual(resume.keyEquivalent, "n")
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

    func testTheKeysAreNotConsumedByATerminal() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let terminal = TerminalStandIn()
        window.contentView = terminal
        XCTAssertTrue(window.makeFirstResponder(terminal))
        XCTAssertFalse(window.performKeyEquivalent(with: keyEvent("n", flags: .command, window: window)),
                       "the terminal must not consume ⌘N")
        XCTAssertFalse(window.performKeyEquivalent(with: keyEvent("N", flags: [.command, .shift], window: window)),
                       "the terminal must not consume ⇧⌘N")
        XCTAssertEqual(terminal.keyDowns, 0)
    }

    /// ⌘N through the real main menu with a real key event fires New Focus only.
    ///
    /// ⇧⌘N is NOT driven the same way, because it cannot be, in a test process: probed on this machine,
    /// `NSMenu.performKeyEquivalent(with:)` given a constructed event matches by key and ignores the shift
    /// flag (a menu holding only an `"n"` + [.command, .shift] item fires on a plain ⌘N event too; `"N"` +
    /// [.command] fires on neither), so a synthetic ⇧⌘N lands on whichever "n" item comes first. ⇧⌘T, whose
    /// form ⇧⌘N copies and which works live, behaves identically (⌘T and ⇧⌘T events both fire New Terminal).
    /// The shifted shortcut is therefore pinned by what AppKit compares, the item's key equivalent and mask,
    /// below. **Hammer must confirm ⇧⌘N live** (it is on the PR's list).
    func testCommandNFiresNewFocusOnlyThroughTheRealMenu() throws {
        _ = NSApplication.shared
        let recorder = Recorder()
        let main = MainMenu.make(target: recorder)
        let previous = NSApp.mainMenu
        NSApp.mainMenu = main
        addTeardownBlock { NSApp.mainMenu = previous }
        XCTAssertTrue(main.performKeyEquivalent(with: keyEvent("n", flags: .command)))
        XCTAssertEqual(recorder.calls, ["new"], "⌘N fires New Focus only")
    }

    /// What AppKit compares for ⇧⌘N: the item's resolved key and modifier mask, and nobody else holds that
    /// pair; ⌘N's mask is exactly ⌘ so it cannot also be the shifted shortcut.
    func testShiftCommandNIsPinnedByItsKeyEquivalentAndMask() throws {
        _ = NSApplication.shared
        let main = MainMenu.make(target: nil)
        let items = main.items.flatMap { $0.submenu?.items ?? [] }
        let resume = try XCTUnwrap(items.first { $0.action == #selector(MainMenuActions.resumeConversation(_:)) })
        let new = try XCTUnwrap(items.first { $0.action == #selector(MainMenuActions.newFocus(_:)) })
        let remote = try XCTUnwrap(items.first { $0.action == #selector(MainMenuActions.newRemoteShell(_:)) })
        let mask = { (i: NSMenuItem) in i.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) }
        // Same form as ⇧⌘T.
        XCTAssertEqual(resume.keyEquivalent, "n")
        XCTAssertEqual(mask(resume), [.command, .shift])
        XCTAssertEqual(remote.keyEquivalent, "t")
        XCTAssertEqual(mask(remote), [.command, .shift])
        XCTAssertEqual(new.keyEquivalent, "n")
        XCTAssertEqual(mask(new), [.command])
        let sharing = items.filter { $0.keyEquivalent.lowercased() == "n" && mask($0) == mask(resume) }
        XCTAssertEqual(sharing.map(\.title), ["Resume Conversation\u{2026}"])
        XCTAssertEqual(items.filter { $0.keyEquivalent.lowercased() == "n" && mask($0) == [.command] }.map(\.title),
                       ["New Focus\u{2026}"])
    }

    /// SwiftTerm's `TerminalView` must not override `performKeyEquivalent` (it would let a focused terminal take
    /// ⌘N / ⇧⌘N before the menu). The test target cannot reference SwiftTerm or `NostromoTerminalView` (T5 in
    /// `TerminalFitnessTests` forbids it, and the classes are not compiled into the tests), so the runtime
    /// check (`class_getInstanceMethod` against NSView's) is not possible here. What is checked instead:
    /// the app's own subclass has no override in source, and SwiftTerm is pinned to the exact version whose
    /// sources were read for one (1.18.0: none). A bump fails this test; whoever bumps it re-checks
    /// `grep -rn performKeyEquivalent Sources` in SwiftTerm and the live ⌘N / ⇧⌘N, then updates the pin here.
    func testSwiftTermIsPinnedToTheVersionCheckedForNoKeyEquivalentOverride() throws {
        let verifiedVersion = "1.18.0"
        let macOS = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let resolved = try String(contentsOf: macOS.appendingPathComponent(
            "Nostromo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"), encoding: .utf8)
        let pbx = try String(contentsOf: macOS.appendingPathComponent("Nostromo.xcodeproj/project.pbxproj"),
                             encoding: .utf8)
        XCTAssertTrue(resolved.contains("\"version\" : \"\(verifiedVersion)\""),
                      "SwiftTerm changed: re-check that TerminalView has no performKeyEquivalent override")
        XCTAssertTrue(pbx.contains("kind = exactVersion;\n\t\t\t\tversion = \(verifiedVersion);"),
                      "SwiftTerm must stay pinned to an exact, verified version")
    }

    func testTheTerminalViewSourceNeverOverridesKeyEquivalents() throws {
        let src = try appSource("UI/Terminal/NostromoTerminalView.swift")
        let code = src.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        XCTAssertFalse(code.contains { $0.contains("performKeyEquivalent") },
                       "a terminal override of performKeyEquivalent could take ⌘N from the menu")
    }

    // MARK: the menu items validate against the window and the daemon

    private func validate(window: NSWindow?, connected: Bool = true, history: Bool = true) throws -> (new: Bool, resume: Bool) {
        let file = try fileMenu(MainMenu.make(target: nil))
        let new = try XCTUnwrap(file.items.first { $0.action == #selector(MainMenuActions.newFocus(_:)) })
        let resume = try XCTUnwrap(file.items.first { $0.action == #selector(MainMenuActions.resumeConversation(_:)) })
        func check(_ item: NSMenuItem) -> Bool {
            XCTAssertTrue(FileMenuShortcuts.handles(item))
            return FileMenuShortcuts.validate(item, keyWindow: window, daemonConnected: connected,
                                              daemonKeepsHistory: history)
        }
        return (check(new), check(resume))
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

    func testTheItemsAreDisabledWithNoMainWindow() throws {
        _ = NSApplication.shared
        var r = try validate(window: nil)
        XCTAssertFalse(r.new); XCTAssertFalse(r.resume)
        let plain = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        plain.isReleasedWhenClosed = false
        r = try validate(window: plain)
        XCTAssertFalse(r.new, "a window that is not a main window"); XCTAssertFalse(r.resume)
    }

    func testTheItemsAreEnabledForAMainWindowAndForTheSheetOfOne() throws {
        let (layout, window) = layoutInWindow()
        var r = try validate(window: window)
        XCTAssertTrue(r.new); XCTAssertTrue(r.resume)
        layout.presentCreateFocusSheet(tab: .new)
        let sheet = try XCTUnwrap(window.attachedSheet)
        r = try validate(window: sheet)
        XCTAssertTrue(r.new, "with the sheet key, the shortcut still finds its parent main window")
        XCTAssertTrue(r.resume)
    }

    func testTheItemsAreDisabledWhenTheDaemonIsDisconnectedAndResumeWhenItKeepsNoHistory() throws {
        let (_, window) = layoutInWindow()
        var r = try validate(window: window, connected: false)
        XCTAssertFalse(r.new, "no daemon"); XCTAssertFalse(r.resume)
        r = try validate(window: window, connected: false, history: false)
        XCTAssertFalse(r.new); XCTAssertFalse(r.resume)
        r = try validate(window: window, connected: true, history: false)
        XCTAssertTrue(r.new, "an older daemon still creates focuses")
        XCTAssertFalse(r.resume, "but cannot resume: it keeps no history")
    }

    /// With some other sheet attached the shortcut opens nothing (and beeps: `presentCreateFocusSheet`;
    /// the sound itself is not observable here).
    func testAnotherSheetAttachedMeansNoSecondSheet() throws {
        let (layout, window) = layoutInWindow()
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                             backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        window.beginSheet(other, completionHandler: nil)
        layout.presentCreateFocusSheet(tab: .resume)
        XCTAssertTrue(window.attachedSheet === other, "the other sheet stays; ours does not stack")
        window.endSheet(other)
    }

    func testTheResumeTabsAgentQuestionPreselectsTheNewTabsDefaultAgent() {
        XCTAssertEqual(CreateFocusSheet.defaultAgent(in: ["cody", "claudia"]), "claudia")
        XCTAssertEqual(CreateFocusSheet.defaultAgent(in: ["cody", "zed"]), "cody", "no claudia: the first")
        XCTAssertNil(CreateFocusSheet.defaultAgent(in: []))
    }
}
