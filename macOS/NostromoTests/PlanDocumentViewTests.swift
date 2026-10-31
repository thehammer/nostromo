import XCTest
import AppKit
import NostromoKit

// R12 / R13 / SR2 / SR7, at the level of the plan view itself: what a person sees and can do with a
// plan inside the Mother job detail. Real files (copies of the Kit fixtures, or files written here),
// the real loader, a real window; only the outside world (open, reveal, copy) is recorded.
//
// No wall-clock bounds: loading is async (read and parse off the main thread), so every test waits on
// a condition; the watcher's debounce is driven by hand where a test needs a reload.

final class PlanDocumentViewTests: XCTestCase {

    // MARK: - Rig

    /// What the outside world was asked to do.
    private final class Recorder {
        var openedPlans: [String] = []
        var openedURLs: [URL] = []
        var revealed: [URL] = []
        var copied: [String] = []

        var actions: PlanViewActions {
            PlanViewActions(openPlan: { [weak self] in self?.openedPlans.append($0) },
                            openURL: { [weak self] in self?.openedURLs.append($0) },
                            reveal: { [weak self] in self?.revealed.append($0) },
                            copy: { [weak self] in self?.copied.append($0) })
        }
    }

    private final class Counter { var n = 0 }

    private struct Rig {
        let view: PlanDocumentView
        let container: NSView
        let window: NSWindow
        let path: String
    }

    /// A plan view, `width` x `height`, filling a container of exactly that size inside a window.
    private func makeRig(path: String, width: CGFloat = 700, height: CGFloat = 600,
                         loader: PlanFileLoader = PlanFileLoader(),
                         actions: PlanViewActions = PlanViewActions()) -> Rig {
        let window = MDFixedWindow(contentRect: NSRect(x: 40, y: 40, width: 1000, height: 800),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.alphaValue = 0
        window.orderFront(nil)
        addTeardownBlock { window.orderOut(nil); window.contentView = nil }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        window.contentView?.addSubview(container)
        let view = PlanDocumentView(frame: container.bounds, loader: loader, actions: actions)
        container.addSubview(view)
        return Rig(view: view, container: container, window: window, path: path)
    }

    private func waitForState(_ rig: Rig, _ state: PlanDocumentView.State,
                              file: StaticString = #filePath, line: UInt = #line) {
        let ok = MD.pumpUntil(rig.window) { rig.view.state == state }
        XCTAssertTrue(ok, "the view never reached \(state); it is \(rig.view.state)", file: file, line: line)
        rig.view.layoutSubtreeIfNeeded()
    }

    /// Show `rig.path`, make the view active and wait for the document.
    private func open(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) {
        rig.view.show(planPath: rig.path)
        rig.view.setActive(true)
        waitForState(rig, .document, file: file, line: line)
    }

    /// A copy of a fixture (under its own name) in a fresh temp directory, shown and loaded.
    private func openFixture(_ name: String, width: CGFloat = 700, height: CGFloat = 600,
                             loader: PlanFileLoader = PlanFileLoader(),
                             actions: PlanViewActions = PlanViewActions()) throws -> Rig {
        let dir = try PlanTestSupport.tempDirectory(self)
        let url = try PlanTestSupport.copyFixture(name, into: dir, as: name)
        let rig = makeRig(path: url.path, width: width, height: height, loader: loader, actions: actions)
        open(rig)
        return rig
    }

    private func scroll(_ view: PlanDocumentView, toY y: CGFloat) {
        let clip = view.documentScrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: y))
        view.documentScrollView.reflectScrolledClipView(clip)
    }

    private func heading(_ view: PlanDocumentView, titled prefix: String) -> (level: Int, title: String, frame: NSRect, blockIndex: Int)? {
        view.headings.first { $0.title.hasPrefix(prefix) }
    }

    private func clipWidth(_ scrollView: NSScrollView) -> CGFloat { scrollView.contentView.bounds.width }
    private func documentWidth(_ scrollView: NSScrollView) -> CGFloat { scrollView.documentView?.frame.width ?? 0 }

    // MARK: - Layout (R12: the plan never makes the pane wider)

    /// Views of the plan that must stay inside it: everything but what lives inside a sideways-scrolling block.
    private func assertNothingPastTheEdge(_ view: PlanDocumentView, file: StaticString = #filePath, line: UInt = #line) {
        let hscrolls = Set((view.tableScrollViews + view.codeScrollViews).map { ObjectIdentifier($0) })
        func insideASidewaysScroller(_ v: NSView) -> Bool {
            var ancestor = v.superview
            while let a = ancestor, a !== view {
                if hscrolls.contains(ObjectIdentifier(a)) { return true }
                ancestor = a.superview
            }
            return false
        }
        for v in MD.allSubviews(view) where !v.isHiddenOrHasHiddenAncestor && !insideASidewaysScroller(v) {
            let r = view.convert(v.bounds, from: v)
            XCTAssertGreaterThanOrEqual(r.minX, -1, "\(type(of: v)) starts left of the plan view", file: file, line: line)
            XCTAssertLessThanOrEqual(r.maxX, view.bounds.width + 1,
                                     "\(type(of: v)) (\(Int(r.minX))...\(Int(r.maxX))) reaches past the plan view's \(view.bounds.width) pt",
                                     file: file, line: line)
        }
    }

    private func assertWideBlocksScrollSideways(width: CGFloat, tableOverflows: Bool,
                                                file: StaticString = #filePath, line: UInt = #line) throws {
        let rig = try openFixture("plan-full.md", width: width)
        let view = rig.view
        view.buildAllRows()
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.frame.width, rig.container.frame.width, "the view is as wide as its container", file: file, line: line)
        XCTAssertEqual(view.tableScrollViews.count, 1, file: file, line: line)
        XCTAssertEqual(view.codeScrollViews.count, 1, file: file, line: line)

        // The 300-character yaml line is wider than any pane we draw.
        for code in view.codeScrollViews {
            XCTAssertGreaterThan(documentWidth(code), clipWidth(code), "the code line scrolls sideways", file: file, line: line)
        }
        for table in view.tableScrollViews {
            if tableOverflows {
                XCTAssertGreaterThan(documentWidth(table), clipWidth(table), "the 12-column table scrolls sideways", file: file, line: line)
            } else {
                XCTAssertGreaterThanOrEqual(documentWidth(table), clipWidth(table), "the table fills its clip at least", file: file, line: line)
            }
        }

        // Prose wraps: no text view outside a sideways scroller is wider than the plan view.
        let sidewaysDocuments = (view.tableScrollViews + view.codeScrollViews).compactMap { $0.documentView }
        for tv in view.textViews where !sidewaysDocuments.contains(where: { $0 === tv }) {
            let r = view.convert(tv.bounds, from: tv)
            XCTAssertLessThanOrEqual(r.maxX, view.bounds.width + 1, "prose reaches past the plan view", file: file, line: line)
        }

        assertNothingPastTheEdge(view, file: file, line: line)
        XCTAssertEqual(view.intrinsicContentSize.width, NSView.noIntrinsicMetric, "the plan view demands no width", file: file, line: line)
        XCTAssertLessThanOrEqual(view.fittingSize.width, width + 1, "the plan view's fitting width", file: file, line: line)
    }

    func testAtANarrowPaneWideBlocksScrollSidewaysAndNothingReachesPastTheEdge() throws {
        try assertWideBlocksScrollSideways(width: 260, tableOverflows: true)
    }

    func testAtAWidePaneTheLongCodeLineStillScrollsAndNothingReachesPastTheEdge() throws {
        try assertWideBlocksScrollSideways(width: 700, tableOverflows: false)
    }

    // MARK: - Checklist (R12) and accessibility (R13)

    func testTaskItemsAreDisabledLabelledCheckboxesWithTheirState() throws {
        let rig = try openFixture("plan-full.md")
        rig.view.buildAllRows()
        let items = PlanChecklist.parse(try PlanTestSupport.fixtureText("plan-full.md"))
        let boxes = rig.view.checkboxes
        XCTAssertEqual(boxes.count, 7)
        XCTAssertEqual(boxes.count, items.count)
        XCTAssertEqual(boxes.filter { $0.state == .on }.count, 3)
        XCTAssertEqual(boxes.filter { $0.state == .off }.count, 4)
        for (box, item) in zip(boxes, items) {
            XCTAssertFalse(box.isEnabled, "a plan's boxes are read-only: \(item.text)")
            XCTAssertEqual(box.accessibilityRole(), .checkBox)
            XCTAssertEqual(box.state, item.done ? .on : .off, item.text)
            XCTAssertEqual((box.accessibilityValue() as? NSNumber)?.intValue, item.done ? 1 : 0, item.text)
            XCTAssertEqual(box.accessibilityLabel(), item.text)
        }
    }

    func testNestedTaskItemsAreAllCheckboxes() throws {
        let rig = try openFixture("plan-task-nested.md")
        rig.view.buildAllRows()
        let items = PlanChecklist.parse(try PlanTestSupport.fixtureText("plan-task-nested.md"))
        XCTAssertEqual(rig.view.checkboxes.count, items.count)
        XCTAssertEqual(rig.view.checkboxes.map { $0.state == .on }, items.map(\.done))
    }

    func testEveryHeadingIsAnAccessibilityHeadingWithItsLevel() throws {
        let rig = try openFixture("plan-full.md")
        let views = rig.view.headingViews
        XCTAssertEqual(views.count, rig.view.headings.count)
        XCTAssertFalse(views.isEmpty)
        var levels = Set<Int>()
        for v in views {
            XCTAssertEqual(v.accessibilityRole(), NSAccessibility.Role(rawValue: "AXHeading"))
            let level = (v.accessibilityValue() as? NSNumber)?.intValue
            XCTAssertNotNil(level)
            if let level { levels.insert(level) }
            XCTAssertFalse(v.accessibilityLabel()?.isEmpty ?? true, "a heading is read out by its title")
        }
        XCTAssertTrue(levels.isSuperset(of: [1, 2, 3, 4]), "levels found: \(levels.sorted())")
        // The value is the heading's own level, in document order.
        XCTAssertEqual(views.compactMap { ($0.accessibilityValue() as? NSNumber)?.intValue }, rig.view.headings.map(\.level))
    }

    // MARK: - Criteria count (MF4-3)

    func testTheCriteriaCountIsTheKitChecklistCount() throws {
        for name in ["plan-full.md", "plan-2000-lines.md", "plan-task-nested.md"] {
            let rig = try openFixture(name)
            let items = PlanChecklist.parse(try PlanTestSupport.fixtureText(name))
            let done = items.filter(\.done).count
            XCTAssertEqual(rig.view.criteriaText, "✓ \(done)/\(items.count) criteria", name)
        }
    }

    func testTheCriteriaCountOfKnownPlans() throws {
        XCTAssertEqual(try openFixture("plan-full.md").view.criteriaText, "✓ 3/7 criteria")
        XCTAssertEqual(try openFixture("plan-2000-lines.md").view.criteriaText, "✓ 107/320 criteria")
    }

    func testAPlanWithoutTasksShowsNoCriteriaCount() throws {
        let dir = try PlanTestSupport.tempDirectory(self)
        let url = dir.appendingPathComponent("plain.md")
        try PlanTestSupport.writeInPlace("# Just prose\n\nNothing to tick.\n\n- a bullet\n", to: url)
        let rig = makeRig(path: url.path)
        open(rig)
        XCTAssertNil(rig.view.criteriaText)
    }

    // MARK: - Outline

    func testTheOutlineListsEveryHeadingIndentedByLevel() throws {
        let rig = try openFixture("plan-full.md")
        let menu = try XCTUnwrap(rig.view.outlineButton.menu)
        let entries = Array(menu.items.dropFirst())   // a pull-down's first item is its own title
        let headings = rig.view.headings
        XCTAssertEqual(entries.count, headings.count)

        var indentByLevel: [Int: Int] = [:]
        for (entry, heading) in zip(entries, headings) {
            XCTAssertEqual(entry.title.trimmingCharacters(in: .whitespaces), heading.title)
            let indent = entry.title.prefix { $0 == " " || $0 == "\u{00A0}" }.count
            if let known = indentByLevel[heading.level] { XCTAssertEqual(indent, known, "one indent per level") }
            indentByLevel[heading.level] = indent
        }
        XCTAssertEqual(indentByLevel[1], 0)
        let ordered = indentByLevel.keys.sorted().compactMap { indentByLevel[$0] }
        XCTAssertEqual(ordered, ordered.sorted(), "deeper headings are indented more")
        XCTAssertEqual(Set(ordered).count, ordered.count, "each level has its own indent")
    }

    func testChoosingAnOutlineEntryScrollsItsHeadingToTheTopOfTheView() throws {
        let rig = try openFixture("plan-2000-lines.md")
        let view = rig.view
        let target = try XCTUnwrap(heading(view, titled: "Section 40:"))
        let menu = try XCTUnwrap(view.outlineButton.menu)
        let entry = try XCTUnwrap(menu.items.first { $0.title.trimmingCharacters(in: .whitespaces).hasPrefix("Section 40:") })
        let owner = try XCTUnwrap(entry.target as? NSObject)
        let action = try XCTUnwrap(entry.action)

        XCTAssertGreaterThan(target.frame.minY, 5_000, "the heading is far down the document")
        _ = owner.perform(action, with: entry)

        let now = try XCTUnwrap(heading(view, titled: "Section 40:"))
        XCTAssertEqual(now.frame.minY - view.scrollOffset, 0, accuracy: 1, "the heading's top is the viewport's top")
    }

    // MARK: - Links (SR2)

    func testLinkPolicyOpensWebLinksRevealsFilesAndIgnoresEverythingElse() {
        let planDir = URL(fileURLWithPath: "/tmp/plan-dir-\(UUID().uuidString)", isDirectory: true)
        func action(_ s: String) -> PlanLinkAction { PlanLinkPolicy.action(for: s, planDirectory: planDir) }

        XCTAssertEqual(action("https://example.invalid/spec"), .open(URL(string: "https://example.invalid/spec")!))
        XCTAssertEqual(action("http://example.invalid/x"), .open(URL(string: "http://example.invalid/x")!))

        if case .reveal(let url) = action("file:///tmp/notes.md") {
            XCTAssertTrue(url.isFileURL)
            XCTAssertEqual(url.lastPathComponent, "notes.md")
        } else { XCTFail("a file: link is revealed") }

        if case .reveal(let url) = action("docs/spec.md") {
            XCTAssertTrue(url.isFileURL)
            XCTAssertTrue(url.path.hasSuffix("/\(planDir.lastPathComponent)/docs/spec.md"), "relative to the plan's folder: \(url.path)")
        } else { XCTFail("a relative path is revealed") }

        if case .reveal(let url) = action("/var/log/system.md") {
            XCTAssertEqual(url.lastPathComponent, "system.md")
        } else { XCTFail("an absolute path is revealed") }

        for inert in ["javascript:alert(1)", "JavaScript:alert(1)", "  javascript:alert(1)", "data:text/html,<b>x</b>",
                      "mailto:someone@example.invalid", "ftp://example.invalid/x", "tel:5551234", "vbscript:x",
                      "#anchor", "#", ""] {
            XCTAssertEqual(action(inert), .none, "'\(inert)' does nothing")
        }
    }

    func testClickingLinksDoesWhatThePolicySaysAndNeverOpensAFile() throws {
        let recorder = Recorder()
        let rig = makeRig(path: "/tmp/plans/plan.md", actions: recorder.actions)
        let view = rig.view
        view.show(planPath: rig.path)   // gives relative links a folder to resolve against; the view is not active, so nothing is read

        view.handleLink(URL(string: "https://example.invalid/spec")!)
        XCTAssertEqual(recorder.openedURLs, [URL(string: "https://example.invalid/spec")!])
        XCTAssertTrue(recorder.revealed.isEmpty)

        view.handleLink(URL(string: "file:///tmp/notes.md")!)
        view.handleLink("docs/spec.md")
        XCTAssertEqual(recorder.revealed.count, 2, "file links are revealed")
        XCTAssertEqual(recorder.openedURLs.count, 1, "and never opened")

        view.handleLink(URL(string: "javascript:alert(1)")!)
        view.handleLink("javascript:alert(1)")
        view.handleLink("#top")
        XCTAssertEqual(recorder.openedURLs.count, 1)
        XCTAssertEqual(recorder.revealed.count, 2)
        XCTAssertTrue(recorder.openedPlans.isEmpty)
        XCTAssertTrue(recorder.copied.isEmpty)
    }

    func testEveryLinkInTheTextIsSafeAndAClickOnItGoesThroughThePolicy() throws {
        let recorder = Recorder()
        let rig = try openFixture("plan-full.md", actions: recorder.actions)
        rig.view.buildAllRows()

        var links: [(textView: NSTextView, value: Any, index: Int)] = []
        for tv in rig.view.textViews {
            guard let storage = tv.textStorage else { continue }
            storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                if let value { links.append((tv, value, range.location)) }
            }
        }
        XCTAssertGreaterThanOrEqual(links.count, 3, "the https, file: and relative links are links")

        var web = 0
        for link in links {
            let url = try XCTUnwrap(link.value as? URL, "a link's value is a URL")
            XCTAssertTrue(["http", "https", "file"].contains(url.scheme?.lowercased() ?? ""), "unexpected link scheme: \(url)")
            if url.scheme == "https" || url.scheme == "http" { web += 1 }
            _ = link.textView.delegate?.textView?(link.textView, clickedOnLink: link.value, at: link.index)
        }
        XCTAssertGreaterThanOrEqual(web, 1)
        XCTAssertEqual(recorder.openedURLs.count, web, "only web links open")
        XCTAssertTrue(recorder.openedURLs.allSatisfy { !$0.isFileURL })
        XCTAssertEqual(recorder.revealed.count, links.count - web, "every other link is revealed")
    }

    func testJavascriptLinksAreShownAsPlainTextWithoutALinkAttribute() throws {
        let rig = try openFixture("plan-full.md")
        rig.view.buildAllRows()
        XCTAssertTrue(rig.view.shownPlainText.contains("click me"), "the words of the link are still shown")

        var sawTheWords = false
        for tv in rig.view.textViews {
            guard let storage = tv.textStorage else { continue }
            storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                if let value { XCTAssertFalse("\(value)".lowercased().contains("javascript"), "a javascript: link must not be a link") }
            }
            let range = (tv.string as NSString).range(of: "click me")
            if range.location != NSNotFound {
                sawTheWords = true
                XCTAssertNil(storage.attribute(.link, at: range.location, effectiveRange: nil))
            }
        }
        XCTAssertTrue(sawTheWords)
    }

    func testAnImageIsItsAltTextAndNoImageAddressAppearsAnywhere() throws {
        let rig = try openFixture("plan-full.md")
        rig.view.buildAllRows()
        XCTAssertTrue(rig.view.shownPlainText.contains("[image: diagram]"))
        XCTAssertFalse(rig.view.shownPlainText.contains("diagram.png"))
        XCTAssertFalse(rig.view.shownPlainText.contains("example.invalid/diagram"))

        for tv in rig.view.textViews {
            guard let storage = tv.textStorage else { continue }
            storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, _, _ in
                for (key, value) in attributes {
                    XCTAssertFalse(value is NSTextAttachment, "no attachment (no image) in the text")
                    let text = "\(value)"
                    XCTAssertFalse(text.contains("diagram.png"), "the image address leaked into attribute \(key.rawValue)")
                    if key != .link, let url = value as? URL {
                        XCTFail("unexpected URL-valued attribute \(key.rawValue): \(url)")
                    }
                }
            }
        }
        XCTAssertTrue(MD.allSubviews(rig.view).allSatisfy { !($0 is NSImageView) }, "no image view either")
    }

    // MARK: - Header buttons

    func testTheHeaderShowsTheFileNameAndItsButtonsDoExactlyOneThingEach() throws {
        let recorder = Recorder()
        let rig = try openFixture("plan-full.md", actions: recorder.actions)
        XCTAssertEqual(rig.view.fileNameText, "plan-full.md")

        for button in [rig.view.openButton, rig.view.finderButton, rig.view.copyPathButton] {
            XCTAssertFalse(button.isHiddenOrHasHiddenAncestor)
            XCTAssertTrue(button.isEnabled)
        }

        _ = rig.view.openButton.sendAction(rig.view.openButton.action, to: rig.view.openButton.target)
        XCTAssertEqual(recorder.openedPlans, [rig.path])
        XCTAssertTrue(recorder.revealed.isEmpty && recorder.copied.isEmpty)

        _ = rig.view.finderButton.sendAction(rig.view.finderButton.action, to: rig.view.finderButton.target)
        XCTAssertEqual(recorder.revealed, [URL(fileURLWithPath: rig.path)])
        XCTAssertEqual(recorder.openedPlans, [rig.path])

        _ = rig.view.copyPathButton.sendAction(rig.view.copyPathButton.action, to: rig.view.copyPathButton.target)
        XCTAssertEqual(recorder.copied, [rig.path])
        XCTAssertEqual(recorder.openedURLs.count, 0)
    }

    // MARK: - Unreadable files (SR7)

    private func assertUnreadable(_ path: String, shows result: PlanFileResult, message: String, opensInEditor: Bool,
                                  revealsInFinder: Bool = false, secret: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let recorder = Recorder()
        let rig = makeRig(path: path, actions: recorder.actions)
        rig.view.show(planPath: path)
        rig.view.setActive(true)
        waitForState(rig, .unreadable(result), file: file, line: line)
        let view = rig.view

        XCTAssertEqual(view.unreadableMessage, message, file: file, line: line)
        XCTAssertFalse(view.messageCopyPathButton.isHiddenOrHasHiddenAncestor, "Copy path is offered", file: file, line: line)
        XCTAssertEqual(view.messageOpenPlanButton.isHiddenOrHasHiddenAncestor, !opensInEditor,
                       "Open ↗ is offered only when the plan can be opened in an editor instead", file: file, line: line)
        XCTAssertEqual(view.messageRevealButtonView.isHiddenOrHasHiddenAncestor, !revealsInFinder,
                       "Show in Finder is offered for a file that is not markdown, cannot be read or is not UTF-8", file: file, line: line)
        XCTAssertNil(rig.window.attachedSheet, "no sheet", file: file, line: line)
        XCTAssertTrue(view.documentScrollView.isHidden, "no document is shown", file: file, line: line)

        let copy = view.messageCopyPathButton
        _ = copy.sendAction(copy.action, to: copy.target)
        XCTAssertEqual(recorder.copied, [path], "Copy path copies the path", file: file, line: line)
        if opensInEditor {
            let open = view.messageOpenPlanButton
            _ = open.sendAction(open.action, to: open.target)
            XCTAssertEqual(recorder.openedPlans, [path], file: file, line: line)
        }
        if revealsInFinder {
            let reveal = view.messageRevealButtonView
            _ = reveal.sendAction(reveal.action, to: reveal.target)
            XCTAssertEqual(recorder.revealed, [URL(fileURLWithPath: path)], file: file, line: line)
            XCTAssertTrue(recorder.openedPlans.isEmpty, "a file that is not markdown is never handed to be opened", file: file, line: line)
        }

        if let secret {
            for v in ([view] as [NSView]) + MD.allSubviews(view) {
                var strings: [String] = [v.toolTip ?? "", v.accessibilityLabel() ?? "", v.accessibilityTitle() ?? "",
                                         v.accessibilityHelp() ?? "", v.accessibilityValue().map { "\($0)" } ?? ""]
                if let tv = v as? NSTextView { strings.append(tv.string) }
                if let tf = v as? NSTextField { strings.append(tf.stringValue) }
                if let button = v as? NSButton { strings.append(button.title) }
                for s in strings {
                    XCTAssertFalse(s.contains(secret), "the file's text reached \(type(of: v))", file: file, line: line)
                }
            }
        }
    }

    func testAMissingPlanSaysSoCalmly() throws {
        let dir = try PlanTestSupport.tempDirectory(self)
        assertUnreadable(dir.appendingPathComponent("gone.md").path, shows: .notFound,
                         message: "Plan file not found. Mother may have archived or cleaned up this job's copy. "
                                + "The job keeps running from its own copy if it is still running.",
                         opensInEditor: false)
    }

    func testAnUnreadablePlanSaysItIsAPermissionsProblem() throws {
        try XCTSkipIf(geteuid() == 0, "root reads files whatever their mode")
        let dir = try PlanTestSupport.tempDirectory(self)
        let url = dir.appendingPathComponent("plan.md")
        try PlanTestSupport.writeInPlace("# Hidden\n", to: url)
        XCTAssertEqual(chmod(url.path, 0o000), 0)
        assertUnreadable(url.path, shows: .notReadable, message: "Can't read this file (permissions).",
                         opensInEditor: false, revealsInFinder: true)
    }

    func testAFileThatIsNotMarkdownIsNotShownAndItsTextIsNowhereOnScreen() throws {
        let dir = try PlanTestSupport.tempDirectory(self)
        let secret = "SECRET-\(UUID().uuidString)"
        let url = dir.appendingPathComponent("notes.txt")
        try PlanTestSupport.writeInPlace(secret, to: url)
        assertUnreadable(url.path, shows: .notMarkdown, message: "This plan isn't a markdown file, so it isn't shown or opened from here. Show it in Finder or copy its path.",
                         opensInEditor: false, revealsInFinder: true, secret: "SECRET-")
    }

    func testAMarkdownNamedLinkToANonMarkdownFileIsNotShownEither() throws {
        let dir = try PlanTestSupport.tempDirectory(self)
        let secret = "SECRET-\(UUID().uuidString)"
        let target = dir.appendingPathComponent("secret.txt")
        try PlanTestSupport.writeInPlace(secret, to: target)
        let link = dir.appendingPathComponent("plan.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        assertUnreadable(link.path, shows: .notMarkdown, message: "This plan isn't a markdown file, so it isn't shown or opened from here. Show it in Finder or copy its path.",
                         opensInEditor: false, revealsInFinder: true, secret: "SECRET-")
    }

    func testAPlanOverOneMebibyteIsNotShown() throws {
        let dir = try PlanTestSupport.tempDirectory(self)
        let url = dir.appendingPathComponent("plan.md")
        try Data(repeating: UInt8(ascii: "a"), count: 1_048_577).write(to: url)
        assertUnreadable(url.path, shows: .tooLarge, message: "This plan can't be shown here. Open it in your editor.",
                         opensInEditor: true)
    }

    func testAPlanThatIsNotUTF8IsNotShown() throws {
        let dir = try PlanTestSupport.tempDirectory(self)
        let url = dir.appendingPathComponent("plan.md")
        try Data([0xFF, 0xFE, 0x41, 0x80]).write(to: url)
        assertUnreadable(url.path, shows: .notUTF8, message: "This plan isn't UTF-8 text.",
                         opensInEditor: false, revealsInFinder: true)
    }

    // MARK: - Hostile text (SR2)

    /// What is never on screen, whatever is next to it. NOT in this set, because each is allowed in a context
    /// (see PlanViewFixupTests.testNoJoinerOrSelectorSitsNextToAnASCIIScalarAnywhereOnScreen): U+200C and
    /// U+200D (between two non-ASCII scalars that are not joiners), U+FE0E and U+FE0F (after an emoji).
    private static let forbiddenScalars: Set<UInt32> = {
        var s = Set<UInt32>()
        s.formUnion(0x202A...0x202E)                       // bidi embeddings and overrides
        s.formUnion(0x2066...0x2069)                       // bidi isolates
        s.formUnion([0x061C])                              // Arabic letter mark
        s.formUnion([0x200B, 0x200E, 0x200F])              // zero-width space, left-to-right and right-to-left marks
        s.formUnion(0x2060...0x2064)                       // word joiner, invisible operators
        s.formUnion([0x00AD, 0x180E])                      // soft hyphen, Mongolian vowel separator
        s.formUnion(0xFE00...0xFE0D)                       // variation selectors (FE0E, FE0F are in context only)
        s.formUnion(0xE0100...0xE01EF)                     // variation selectors supplement
        s.insert(0xFEFF)                                   // BOM / zero-width no-break space
        s.formUnion([0x034F, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x2800, 0x3164, 0xFFA0])   // blank-looking fillers
        s.formUnion([0x2028, 0x2029])                      // line and paragraph separators
        s.formUnion(0x80...0x9F)                           // C1 controls
        s.formUnion(0x00...0x1F)                           // C0 controls (ESC, NUL, ...)
        s.insert(0x7F)
        s.remove(0x0A)                                     // a line break and a tab are text
        s.remove(0x09)
        return s
    }()

    func testHostileCharactersNeverReachTheScreenWhileCodeKeepsItsLayout() throws {
        let rig = try openFixture("plan-hostile.md")
        rig.view.buildAllRows()
        let shown = rig.view.shownPlainText

        for scalar in shown.unicodeScalars where Self.forbiddenScalars.contains(scalar.value) {
            XCTFail("U+\(String(scalar.value, radix: 16, uppercase: true)) is on screen")
        }
        for word in ["safe-heading", "safe-para", "zw-item", "safe-item", "safe-cell", "tail-para"] {
            XCTAssertTrue(shown.contains(word), "the safe text '\(word)' is still shown")
        }

        let code = try XCTUnwrap(rig.view.codeScrollViews.first?.documentView as? NSTextView, "the code block is shown")
        XCTAssertGreaterThanOrEqual(code.string.components(separatedBy: "\n").count, 4, "the code block keeps its lines")
        XCTAssertTrue(code.string.contains("\t"), "and its tab")
    }

    func testAllTextCanBeSelectedAndNothingCanBeEdited() throws {
        let rig = try openFixture("plan-full.md")
        rig.view.buildAllRows()
        XCTAssertFalse(rig.view.textViews.isEmpty)
        for tv in rig.view.textViews {
            XCTAssertTrue(tv.isSelectable)
            XCTAssertFalse(tv.isEditable)
        }
    }

    // MARK: - Find

    private func selections(_ view: PlanDocumentView) -> [(textView: NSTextView, range: NSRange)] {
        view.textViews.compactMap { $0.selectedRange().length > 0 ? ($0, $0.selectedRange()) : nil }
    }

    private func selectionID(_ view: PlanDocumentView) -> String? {
        guard let one = selections(view).first else { return nil }
        return "\(ObjectIdentifier(one.textView).hashValue):\(one.range.location)"
    }

    private func menuItem(_ action: NSTextFinder.Action) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.tag = action.rawValue
        return item
    }

    func testShowingFindOpensTheFieldAndGivesItTheKeyboard() throws {
        let rig = try openFixture("plan-full.md")
        let view = rig.view
        view.showFind()
        XCTAssertTrue(view.findVisible)
        XCTAssertFalse(view.findSearchField.isHiddenOrHasHiddenAncestor)
        let responder = rig.window.firstResponder
        XCTAssertTrue(responder === view.findSearchField || ((responder as? NSText)?.delegate as AnyObject?) === view.findSearchField,
                      "the find field has the keyboard, not \(String(describing: responder))")
        XCTAssertTrue(PlanDocumentView.containing(responder) === view, "the field editor is found inside its plan view")
        XCTAssertTrue(PlanDocumentView.containing(view.findSearchField) === view)
    }

    func testFindNextWalksEveryMatchIgnoringCaseAndWraps() throws {
        let rig = try openFixture("plan-full.md")
        let view = rig.view
        view.showFind()
        view.findSearchField.stringValue = "LEVEL"

        let expected = try PlanTestSupport.fixtureText("plan-full.md").lowercased().components(separatedBy: "level").count - 1
        XCTAssertEqual(expected, 5)

        XCTAssertTrue(view.findNext())
        let firstSelection = try XCTUnwrap(selections(view).first)
        XCTAssertEqual(selections(view).count, 1)
        XCTAssertEqual((firstSelection.textView.string as NSString).substring(with: firstSelection.range).lowercased(), "level")
        let firstID = try XCTUnwrap(selectionID(view))

        var seen = [firstID]
        for _ in 0..<(expected + 3) {
            XCTAssertTrue(view.findNext())
            let id = try XCTUnwrap(selectionID(view))
            if id == firstID { break }
            seen.append(id)
        }
        XCTAssertEqual(seen.count, expected, "each match is visited once before the search wraps to the first")
        XCTAssertEqual(Set(seen).count, expected)
        XCTAssertEqual(selectionID(view), firstID, "and then it is back at the first match")
    }

    func testFindBringsAFarAwayMatchIntoViewAndSelectsIt() throws {
        let rig = try openFixture("plan-2000-lines.md")
        let view = rig.view
        view.showFind()
        view.findSearchField.stringValue = "Section 77"

        XCTAssertTrue(view.findNext())
        let found = try XCTUnwrap(selections(view).first, "the match is selected in a text view that exists")
        XCTAssertEqual((found.textView.string as NSString).substring(with: found.range).lowercased(), "section 77")

        let visible = view.documentScrollView.documentVisibleRect
        let inDocument = view.documentContentView.convert(found.textView.bounds, from: found.textView)
        XCTAssertTrue(inDocument.intersects(visible), "the match \(inDocument) is within the visible \(visible)")
        XCTAssertGreaterThan(view.scrollOffset, 5_000, "the view moved to it")
    }

    func testTheFindMenuItemsOpenTheFieldAndStepThroughMatches() throws {
        let rig = try openFixture("plan-full.md")
        let view = rig.view
        view.performFind(menuItem(.showFindInterface))
        XCTAssertTrue(view.findVisible)

        view.findSearchField.stringValue = "level"
        view.performFind(menuItem(.nextMatch))
        let first = try XCTUnwrap(selectionID(view), "Find Next selects a match")
        view.performFind(menuItem(.nextMatch))
        let second = try XCTUnwrap(selectionID(view))
        XCTAssertNotEqual(first, second, "Find Next moves on")
    }

    func testEscapeClosesTheFindField() throws {
        let rig = try openFixture("plan-full.md")
        let view = rig.view
        view.showFind()
        view.findSearchField.stringValue = "level"
        let editor = (rig.window.firstResponder as? NSTextView) ?? NSTextView()

        XCTAssertFalse(view.control(view.findSearchField, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))),
                       "other keys are left to the field")
        XCTAssertTrue(view.findVisible)

        XCTAssertTrue(view.control(view.findSearchField, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertFalse(view.findVisible)
        XCTAssertTrue(view.findSearchField.isHidden)
    }

    func testOnlyRespondersInsideAPlanViewBelongToIt() throws {
        let rig = try openFixture("plan-full.md")
        rig.view.buildAllRows()
        XCTAssertNil(PlanDocumentView.containing(nil))
        XCTAssertNil(PlanDocumentView.containing(NSView()))
        XCTAssertNil(PlanDocumentView.containing(NSTextField(labelWithString: "terminal")))
        XCTAssertNil(PlanDocumentView.containing(NSResponder()))
        XCTAssertTrue(PlanDocumentView.containing(rig.view) === rig.view)
        XCTAssertTrue(PlanDocumentView.containing(rig.view.textViews.first) === rig.view)
    }

    // MARK: - Large documents

    func testALargePlanBuildsOnlyTheRowsNearTheViewportAndEveryHeading() throws {
        let rig = try openFixture("plan-2000-lines.md", height: 600)
        let view = rig.view
        XCTAssertGreaterThan(view.rowCount, 1_000)
        XCTAssertLessThan(view.textViews.count * 3, view.rowCount, "rows far from the viewport have no views")
        XCTAssertEqual(view.headings.count, 80)
        XCTAssertEqual(view.headingViews.count, 80, "every heading has a view, so VoiceOver can move between them")

        let width = view.documentContentView.frame.width
        let flow = view.documentContentView
        scroll(view, toY: flow.frame.height / 2)
        view.layoutSubtreeIfNeeded()

        let visible = view.documentScrollView.documentVisibleRect
        let hereNow = view.textViews.filter { flow.convert($0.bounds, from: $0).intersects(visible) }
        XCTAssertGreaterThanOrEqual(hereNow.count, 5, "the rows in the middle were built when the reader got there")
        XCTAssertLessThan(view.textViews.count * 3, view.rowCount, "and the document is still mostly unbuilt")
        XCTAssertEqual(flow.frame.width, width, accuracy: 0.5, "scrolling does not change the document's width")
        XCTAssertEqual(view.headingViews.count, 80)
    }

    // MARK: - Reading position (MF4-4)

    private struct Reloadable {
        let rig: Rig
        let loader: PlanFileLoader
        let scheduler: ManualPlanReloadScheduler
        let url: URL
        /// Results the loader has delivered to the view since the rig was made.
        let delivered: Counter
        let originalText: String
    }

    private func openReloadable(_ fixture: String) throws -> Reloadable {
        let scheduler = ManualPlanReloadScheduler()
        let loader = PlanFileLoader(scheduler: scheduler)
        let dir = try PlanTestSupport.tempDirectory(self)
        let url = try PlanTestSupport.copyFixture(fixture, into: dir, as: "plan.md")
        let rig = makeRig(path: url.path, height: 600, loader: loader)
        let delivered = Counter()
        let viewsHandler = loader.onResult
        loader.onResult = { result in delivered.n += 1; viewsHandler?(result) }
        open(rig)
        XCTAssertTrue(loader.isWatching)
        return Reloadable(rig: rig, loader: loader, scheduler: scheduler, url: url, delivered: delivered,
                          originalText: try PlanTestSupport.fixtureText(fixture))
    }

    /// Write `text`, wait for the watcher to notice, run the debounce by hand.
    private func edit(_ r: Reloadable, to text: String, file: StaticString = #filePath, line: UInt = #line) throws {
        try PlanTestSupport.writeInPlace(text, to: r.url)
        let seen = PlanTestSupport.pumpUntil { r.loader.hasPendingReload }
        XCTAssertTrue(seen, "the edit was never noticed", file: file, line: line)
        r.scheduler.fire()
    }

    /// The topmost heading the reader can see.
    private func topHeading(_ view: PlanDocumentView) throws -> (level: Int, title: String, frame: NSRect, blockIndex: Int) {
        try XCTUnwrap(view.headings.first { $0.frame.maxY > view.scrollOffset })
    }

    func testAReloadThatAddsLinesAboveKeepsTheReaderOnTheSameHeadingAtTheSameOffset() throws {
        let r = try openReloadable("plan-2000-lines.md")
        let view = r.rig.view
        let target = try XCTUnwrap(heading(view, titled: "Section 40:"))
        scroll(view, toY: target.frame.minY - 40)
        let anchor = try topHeading(view)
        let before = anchor.frame.minY - view.scrollOffset
        XCTAssertGreaterThan(view.scrollOffset, 5_000)

        var lines = r.originalText.components(separatedBy: "\n")
        lines.insert(contentsOf: (0..<40).flatMap { ["", "Inserted paragraph \($0) above the reading position."] }, at: 1)
        let edited = lines.joined(separator: "\n")
            .replacingOccurrences(of: "Paragraph A of section 70:", with: "Paragraph A (edited) of section 70:")
        XCTAssertNotEqual(edited, r.originalText)

        try edit(r, to: edited)
        let moved = MD.pumpUntil(r.rig.window) { view.headings.first { $0.title == anchor.title }.map { $0.frame.minY != anchor.frame.minY } ?? false }
        XCTAssertTrue(moved, "the reload never changed the document")

        let now = try XCTUnwrap(view.headings.first { $0.title == anchor.title })
        XCTAssertGreaterThan(now.frame.minY, anchor.frame.minY + 500, "the lines above pushed the heading down")
        XCTAssertEqual(now.frame.minY - view.scrollOffset, before, accuracy: 1, "the reader still sees the same place")
    }

    func testAReloadWithTheSameTextRebuildsNothing() throws {
        let r = try openReloadable("plan-2000-lines.md")
        let view = r.rig.view
        scroll(view, toY: view.documentContentView.frame.height / 2)
        view.layoutSubtreeIfNeeded()
        let rowsBefore = view.documentContentView.subviews
        let offsetBefore = view.scrollOffset
        let deliveredBefore = r.delivered.n

        try edit(r, to: r.originalText)
        XCTAssertTrue(MD.pumpUntil(r.rig.window) { r.delivered.n > deliveredBefore }, "the reload never delivered")

        let rowsAfter = view.documentContentView.subviews
        XCTAssertEqual(rowsAfter.count, rowsBefore.count)
        XCTAssertTrue(zip(rowsBefore, rowsAfter).allSatisfy { $0 === $1 }, "the same row views, not rebuilt ones")
        XCTAssertEqual(view.scrollOffset, offsetBefore, accuracy: 0.5)
        XCTAssertEqual(view.state, .document)
    }

    func testWhenTheHeadingIsDeletedTheReaderLandsOnTheNearestEarlierHeadingAtTheTop() throws {
        let r = try openReloadable("plan-2000-lines.md")
        let view = r.rig.view
        let all = view.headings
        let index = try XCTUnwrap(all.firstIndex { $0.title.hasPrefix("Section 40:") })
        let target = all[index]
        let preceding = all[index - 1]
        scroll(view, toY: target.frame.minY)
        XCTAssertEqual(try topHeading(view).title, target.title)

        var lines = r.originalText.components(separatedBy: "\n")
        let line = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("#") && $0.contains("Section 40:") })
        lines.remove(at: line)
        try edit(r, to: lines.joined(separator: "\n"))

        let gone = MD.pumpUntil(r.rig.window) { !view.headings.contains { $0.title == target.title } }
        XCTAssertTrue(gone, "the heading is still there after the reload")
        let landing = try XCTUnwrap(view.headings.first { $0.title == preceding.title })
        XCTAssertEqual(landing.frame.minY - view.scrollOffset, 0, accuracy: 1, "the nearest earlier heading is at the top")
    }

    // MARK: - Lifecycle

    func testAViewThatIsNotActiveReadsAndWatchesNothing() throws {
        let dir = try PlanTestSupport.tempDirectory(self)
        let url = try PlanTestSupport.copyFixture("plan-full.md", into: dir)
        let rig = makeRig(path: url.path)
        rig.view.show(planPath: url.path)
        XCTAssertEqual(rig.view.state, .loading)
        XCTAssertFalse(rig.view.isWatchingFile)

        var drained = false
        DispatchQueue.main.async { drained = true }
        XCTAssertTrue(MD.pumpUntil(rig.window) { drained })
        XCTAssertEqual(rig.view.state, .loading, "nothing was read while hidden")

        rig.view.setActive(true)
        waitForState(rig, .document)
        XCTAssertTrue(rig.view.isWatchingFile)
    }

    func testDeactivatingTheViewStopsTheWatchAndActivatingItReadsAgain() throws {
        let rig = try openFixture("plan-full.md")
        XCTAssertTrue(rig.view.isWatchingFile)

        rig.view.setActive(false)
        XCTAssertFalse(rig.view.isWatchingFile)

        rig.view.setActive(true)
        XCTAssertTrue(rig.view.isWatchingFile)
        waitForState(rig, .document)
        XCTAssertEqual(rig.view.criteriaText, "✓ 3/7 criteria")
    }

    func testRemovingTheViewFromItsWindowStopsTheWatchAndAddingItBackWatchesAgain() throws {
        let rig = try openFixture("plan-full.md")
        XCTAssertTrue(rig.view.isWatchingFile)

        rig.view.removeFromSuperview()
        XCTAssertFalse(rig.view.isWatchingFile, "a view that is off screen holds no watcher")

        rig.container.addSubview(rig.view)
        XCTAssertTrue(rig.view.isWatchingFile, "back on screen it reads and watches again")
        waitForState(rig, .document)
    }
}
