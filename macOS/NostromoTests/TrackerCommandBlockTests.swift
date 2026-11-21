import XCTest
import AppKit
import NostromoKit

// PRD 44-48 (Mac half), "Staged commands (display-only, by requirement)". The block shows a command and
// can copy it; nothing in it runs, sends or types anything. The daemon half of the no-shell proof is
// `tests/no_shell_surface.rs` and `tests/no_shell_behaviour.rs`.
final class TrackerCommandBlockTests: XCTestCase {

    // MARK: Fixtures

    /// `tests/fixtures/tracker/commands.txt`: `(name, text)` for every command that must be accepted.
    private func fixtureCommands(file: StaticString = #filePath) throws -> [(name: String, text: String)] {
        try TrackerPaneFx.fixtureText("commands.txt", file: file).split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.hasPrefix("#") }
            .compactMap { line -> (String, String)? in
                let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, !parts[0].hasPrefix("hostile_") else { return nil }
                return (String(parts[0]), Self.decode(String(parts[1])))
            }
    }

    private static func decode(_ raw: String) -> String {
        var out = ""
        var it = raw.makeIterator()
        while let c = it.next() {
            guard c == "\\" else { out.append(c); continue }
            switch it.next() {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "e": out.append("\u{1b}")
            case "a": out.append("\u{07}")
            case "r": out.append("\r")
            case "\\": out.append("\\")
            case "u":
                _ = it.next() // {
                var hex = ""
                while let h = it.next(), h != "}" { hex.append(h) }
                if let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) { out.unicodeScalars.append(scalar) }
            default: break
            }
        }
        return out
    }

    private func pasteboard() -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("TrackerCommandTests-\(UUID().uuidString)"))
        addTeardownBlock { board.releaseGlobally() }
        return board
    }

    private func block(_ command: String, env: TrackerEnvWire? = .prod, ran: Bool = false, canMarkRan: Bool = true,
                       showsEnvBadge: Bool = true, board: NSPasteboard? = nil) -> TrackerCommandBlockView {
        let view = TrackerCommandBlockView(command: command, env: env, ran: ran, canMarkRan: canMarkRan,
                                           showsEnvBadge: showsEnvBadge, pasteboard: board ?? pasteboard())
        view.frame = NSRect(x: 0, y: 0, width: 320, height: view.height(forWidth: 320))
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// AppKit mirrors every plain string under its legacy name; anything else (rich text, HTML, a file URL) is a leak.
    private func assertPlainTextOnly(_ board: NSPasteboard, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let allowed: Set<NSPasteboard.PasteboardType> = [.string, NSPasteboard.PasteboardType("NSStringPboardType")]
        XCTAssertTrue(Set(board.types ?? []).isSubset(of: allowed), "\(message): \(board.types ?? [])", file: file, line: line)
        XCTAssertTrue(board.types?.contains(.string) ?? false, message, file: file, line: line)
    }

    private func everyView(_ root: NSView) -> [NSView] { [root] + rigAllSubviews(of: root) }

    /// Every title and label a person or VoiceOver meets in `root` (the command's own text is a value).
    private func namesInTree(_ root: NSView) -> [String] {
        everyView(root).flatMap { view -> [String] in
            var names: [String] = []
            if let label = view.accessibilityLabel(), !label.isEmpty { names.append(label) }
            if let title = view.accessibilityTitle(), !title.isEmpty { names.append(title) }
            if let button = view as? NSButton { names += [button.title, button.attributedTitle.string] }
            if let field = view as? NSTextField { names.append(field.stringValue) }
            names += (view.accessibilityCustomActions() ?? []).map(\.name)
            return names.filter { !$0.isEmpty }
        }
    }

    private let forbidden = try! NSRegularExpression(pattern: "run|send|execute|open in (shell|terminal)", options: .caseInsensitive)

    private func assertNoRunAffordance(_ names: [String], allowing allowed: Set<String> = ["Ran it"],
                                       file: StaticString = #filePath, line: UInt = #line) {
        for name in names where !allowed.contains(name) {
            let range = NSRange(name.startIndex..., in: name)
            XCTAssertNil(forbidden.firstMatch(in: name, range: range), "'\(name)' reads as running something",
                         file: file, line: line)
        }
    }

    private func luminance(_ color: NSColor) -> Double {
        let c = color.usingColorSpace(.sRGB) ?? color
        func lin(_ v: CGFloat) -> Double { Double(v) <= 0.04045 ? Double(v) / 12.92 : pow((Double(v) + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let (hi, lo) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (hi + 0.05) / (lo + 0.05)
    }

    /// `top` (with its alpha) laid over `base`.
    private func composite(_ top: NSColor, over base: NSColor) -> NSColor {
        let t = top.usingColorSpace(.sRGB) ?? top, b = base.usingColorSpace(.sRGB) ?? base
        let a = t.alphaComponent
        return NSColor(srgbRed: t.redComponent * a + b.redComponent * (1 - a),
                       green: t.greenComponent * a + b.greenComponent * (1 - a),
                       blue: t.blueComponent * a + b.blueComponent * (1 - a), alpha: 1)
    }

    // MARK: PRD 44: the block

    func testACommandIsMonospacedWithItsEnvironmentBadgeCopyAndRanIt() throws {
        let view = block("php artisan queue:retry 8812", env: .prod)
        let text = try XCTUnwrap(rigAllSubviews(of: view).compactMap { $0 as? NSTextView }.first)
        XCTAssertTrue(text.font?.isFixedPitch ?? false, "monospaced")
        XCTAssertEqual(text.string, "php artisan queue:retry 8812")
        XCTAssertTrue(view.envBadge?.stringValue.contains("PROD") ?? false)
        XCTAssertEqual(view.copyButton.title, "Copy")
        XCTAssertEqual(view.ranItCheckbox.title, "Ran it")
        XCTAssertEqual(view.ranItCheckbox.state, .off)
        XCTAssertNil(view.lineBadge, "a one-line command has no line count")
        XCTAssertFalse(text.isEditable)
    }

    func testEveryEnvironmentHasItsWordAndOnlyTheHazardousOnesHaveTheHazardTreatment() {
        let expectations: [(TrackerEnvWire, String, Bool)] = [
            (.prod, "PROD", true), (.canada, "CANADA", true), (.demo, "DEMO", true), (.unset, "ENV?", true),
            (.staging, "STAGING", false), (.local, "LOCAL", false)]
        for (env, word, hazard) in expectations {
            let view = block("ls", env: env)
            let badge = view.envBadge?.stringValue ?? ""
            XCTAssertTrue(badge.hasSuffix(word), "\(word): \(badge)")
            XCTAssertEqual(view.isHazard, hazard, word)
            XCTAssertEqual(badge.contains("\u{26A0}"), hazard, "\(word): the hazard has a glyph as well as a colour")
            let edge = everyView(view).first { $0.layer?.backgroundColor == TrackerTheme.hazard.cgColor }
            XCTAssertEqual(edge != nil, hazard, "\(word): the red edge")
            if hazard {
                XCTAssertEqual(view.envBadge?.textColor, TrackerTheme.hazard)
            }
        }
    }

    func testTheHazardBadgeTextIsAtLeast4_5To1OnItsFillOverTheBlock() {
        let blockFill = composite(NSColor(white: 1, alpha: 0.05), over: TrackerTheme.background)
        let badgeFill = composite(TrackerTheme.hazardFill, over: blockFill)
        XCTAssertGreaterThanOrEqual(contrast(TrackerTheme.hazard, badgeFill), 4.5)
        XCTAssertGreaterThanOrEqual(contrast(TrackerTheme.text, blockFill), 7)
    }

    func testAMultiLineCommandShowsItsLineCountAndEveryLine() throws {
        let view = block("set -e\ncd /srv/app\n./deploy.sh")
        XCTAssertEqual(view.lineBadge?.stringValue, "3 lines")
        let text = try XCTUnwrap(rigAllSubviews(of: view).compactMap { $0 as? NSTextView }.first)
        XCTAssertEqual(text.string, "set -e\ncd /srv/app\n./deploy.sh")
        XCTAssertGreaterThan(view.height(forWidth: 320), block("set -e").height(forWidth: 320))
    }

    func testTheCommandNeverWrapsItScrollsSidewaysInsideTheBlock() throws {
        let long = String(repeating: "x", count: 600)
        let view = block(long)
        let scroll = try XCTUnwrap(rigAllSubviews(of: view).compactMap { $0 as? NSScrollView }.first)
        let text = try XCTUnwrap(scroll.documentView as? NSTextView)
        XCTAssertGreaterThan(text.frame.width, scroll.frame.width, "the line is wider than the block")
        XCTAssertEqual(view.height(forWidth: 320), view.height(forWidth: 3_000), "no width reflows it")
        XCTAssertTrue(scroll.hasHorizontalScroller)
        XCTAssertFalse(scroll.hasVerticalScroller)
        XCTAssertEqual(text.string, long)
    }

    func testThereIsNoRunSendExecuteOrOpenInShellElementAndNoKeyEquivalent() throws {
        let view = block("kubectl rollout restart deploy/web", env: .prod)
        assertNoRunAffordance(namesInTree(view))
        XCTAssertTrue(namesInTree(view).contains("Ran it"))
        for control in everyView(view).compactMap({ $0 as? NSControl }) {
            XCTAssertEqual((control as? NSButton)?.keyEquivalent ?? "", "", "\(control): no key equivalent")
        }
        let text = try XCTUnwrap(rigAllSubviews(of: view).compactMap { $0 as? NSTextView }.first)
        let menuTitles = (text.menu?.items ?? []).map(\.title)
        XCTAssertEqual(menuTitles, ["Copy", "Select All"])
        assertNoRunAffordance(menuTitles)
        for item in text.menu?.items ?? [] { XCTAssertEqual(item.keyEquivalent, "") }
    }

    func testARowHostingACommandHasNoRunAffordanceInItsTreeOrItsContextMenu() throws {
        let h = try TrackerEditHarness(self)
        // A done command lives in its section's folded Done group, which has no row of its own.
        let ids = h.script.itemNodes.filter { ($0["kind"] as? String) == "command" && ($0["status"] as? String) != "done" }
            .compactMap { $0["id"] as? String }
        XCTAssertGreaterThanOrEqual(ids.count, 4, "the golden board stages open commands in several environments")
        for id in ids {
            let row = try h.row(id)
            XCTAssertNotNil(row.commandBlock, "\(id) hosts a command block")
            // The row's own text is the board's data (an item's title), not a control.
            let data = Set(row.textViews.map(\.string))
            assertNoRunAffordance(namesInTree(row).filter { !data.contains($0) }.filter {
                !(row.commandBlock?.displayedText.contains($0) ?? false)
            })
            func walk(_ items: [NSMenuItem]) {
                for item in items {
                    assertNoRunAffordance([item.title])
                    XCTAssertEqual(item.keyEquivalent, "", "'\(item.title)' has a key equivalent")
                    walk(item.submenu?.items ?? [])
                }
            }
            walk(row.menuItems())
        }
    }

    // MARK: PRD 45: Copy

    func testCopyPutsExactlyTheCommandsBytesOnThePasteboardAsPlainTextOnly() throws {
        let commands = try fixtureCommands()
        XCTAssertGreaterThanOrEqual(commands.count, 15, "the fixture is read")
        for (name, command) in commands {
            let board = pasteboard()
            let view = block(command, board: board)
            XCTAssertEqual(view.displayedText, command, "\(name): the displayed string is the staged one")
            view.copyButton.performClick(nil)
            assertPlainTextOnly(board, "\(name): plain text only")
            let copied = try XCTUnwrap(board.data(forType: .string), name)
            XCTAssertEqual(Array(copied), Array(command.utf8), "\(name): byte for byte")
        }
    }

    func testCopyFromARowWritesToThePanesPasteboard() throws {
        let h = try TrackerEditHarness(self)
        let row = try h.row("retry-1074")
        let block = try XCTUnwrap(row.commandBlock)
        h.rig.pasteboard.clearContents()
        block.copyButton.performClick(nil)
        XCTAssertEqual(h.rig.pasteboard.string(forType: .string), "php artisan queue:retry 8812")
        assertPlainTextOnly(h.rig.pasteboard, "plain text only")
    }

    func testWhatIsDrawnAndCopiedHasNoControlBidiOrZeroWidthCharacterWhateverArrives() {
        let hostile = "echo a\u{1b}[31mb\u{9b}c\r\u{202e}d\u{200b}e\u{feff}f\u{7}g\u{2028}h\u{3164}\u{2800}\nsecond\tline"
        let board = pasteboard()
        let view = block(hostile, board: board)
        XCTAssertEqual(view.displayedText, "echo a[31mbcdefgh\nsecond\tline")
        view.copyButton.performClick(nil)
        XCTAssertEqual(board.string(forType: .string), view.displayedText, "hostile bytes never reach the pasteboard")
        let huge = String(repeating: "a", count: 50_000)
        XCTAssertEqual(block(huge).displayedText.count, TrackerCommandText.maxScalars, "the length is capped")
    }

    // MARK: PRD 47: Ran it

    func testRanItSendsThePanesTickAgainstTheVersionTheUserSawAndNeverFlipsByItself() throws {
        let h = try TrackerEditHarness(self)
        let id = "retry-1074"
        let block = try XCTUnwrap(try h.row(id).commandBlock)
        XCTAssertEqual(block.ranItCheckbox.state, .off)
        block.ranItCheckbox.performClick(nil)
        XCTAssertEqual(h.sent.map(\.ops), [[.status(id: id, status: "done")]])
        XCTAssertEqual(h.sent.first?.base, 7)
        XCTAssertEqual(try XCTUnwrap(try h.row(id).commandBlock).ranItCheckbox.state, .off,
                       "no optimistic display: the box shows the board until the board changes")
    }

    func testRanItIsDisabledInAPaneThatCannotEdit() throws {
        let h = try TrackerEditHarness(self, supported: false)
        let block = try XCTUnwrap(try h.row("retry-1074").commandBlock)
        XCTAssertFalse(block.ranItCheckbox.isEnabled)
        XCTAssertEqual(block.copyButton.isEnabled, true, "Copy never needs the daemon")
        block.ranItCheckbox.performClick(nil)
        XCTAssertTrue(h.sent.isEmpty)
    }

    func testTheShowReportKeepsTheCommandBlocksFieldsHonest() throws {
        let h = try TrackerEditHarness(self)
        let sections = try XCTUnwrap(h.pane.showReport()["sections"] as? [[String: Any]])
        let items = sections.flatMap { ($0["items"] as? [[String: Any]]) ?? [] }
        let command = try XCTUnwrap(items.first { ($0["id"] as? String) == "retry-1074" })
        XCTAssertEqual(command["kind"] as? String, "command")
        XCTAssertEqual(command["command"] as? String, "php artisan queue:retry 8812")
        XCTAssertEqual(command["ran"] as? Bool, false)
        XCTAssertEqual(command["env"] as? String, "PROD")
        XCTAssertEqual(command["tickable"] as? Bool, true, "Ran it is the command's tick")
        XCTAssertEqual(command["status_editable"] as? Bool, false, "a command has no status menu")
        let plain = try XCTUnwrap(items.first { ($0["id"] as? String) == "revie-1111" })
        XCTAssertEqual(plain["kind"] as? String, "item")
        XCTAssertTrue(plain["command"] is NSNull)
    }
}
