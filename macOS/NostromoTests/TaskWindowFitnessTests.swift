import XCTest

// BA4 fitness functions over the task window's source, in the spirit of `PerFocusEvictionWiringTests`.
//
// Source scans, not behaviour: they guard rules a behavioural test cannot see (nothing is ever logged, a view
// never declares `tag`, a subscription never retains its owner) and wiring in files the test bundle does not
// compile (`AppDelegate.swift`). Every scan runs over the code with comments and string literals removed, so a
// doc comment that names `print(` or `NostromoWindow` is not a hit. Each rule has a test of the scan itself
// on a small snippet, so a scan that has stopped seeing anything fails instead of passing.
//
// They are textual heuristics: a determined refactor can dodge one. Each failure message says which rule
// broke and why it exists.

final class TaskWindowFitnessTests: XCTestCase {

    private static let newSources = [
        "Nostromo/Data/TaskRequests.swift",
        "Nostromo/Data/TaskOutputModel.swift",
        "Nostromo/UI/Background/TaskWindowContent.swift",
        "Nostromo/UI/Background/TaskWindowHeaderView.swift",
        "Nostromo/UI/Background/TaskOutputView.swift",
        "Nostromo/UI/Background/SubagentTaskView.swift",
        "Nostromo/UI/Background/TaskWindowController.swift",
    ]
    private static let stopButton = "Nostromo/UI/Background/TaskStopButton.swift"
    private static let controller = "Nostromo/UI/Background/TaskWindowController.swift"

    // MARK: (a) Nothing is logged

    func testNoTaskWindowSourceLogsAnything() throws {
        var hits: [String] = []
        for path in Self.newSources + [Self.stopButton] {
            let code = try Self.code(path)
            for hit in Self.loggingCalls(in: code) { hits.append("\(path):\(hit.line) \(hit.what)") }
        }

        XCTAssertTrue(hits.isEmpty, """
            The task window's files must not log at all: a description, an output line, a prompt, a command or a \
            path in a log line is content in a log, and there is no value in a count of how often a window opened \
            that is worth the risk. Found: \(hits.joined(separator: "; "))
            """)
    }

    func testTheLoggingScanSeesCallsButNotCommentsOrStrings() {
        let snippet = """
            // print("a comment")
            let text = "NSLog(1) and log. and Logger( in a string"
            /* os_log("block comment") */
            print(value)
            NSLog("x")
            os_log("y")
            let logger = Logger(subsystem: "s", category: "c")
            log.info("z")
            appLog.warn("w")
            debugPrint(value)
            """

        let found = Self.loggingCalls(in: Self.strippingCommentsAndStrings(snippet)).map(\.what)

        XCTAssertEqual(Set(found), ["print(", "NSLog(", "os_log(", "Logger", "log.", "appLog.", "debugPrint("])
        XCTAssertEqual(Self.loggingCalls(in: Self.strippingCommentsAndStrings("let a = \"print(1)\" // NSLog(2)\n")).count, 0)
    }

    // MARK: (b) No `tag` on a view

    func testNoViewInTheTaskWindowSourcesDeclaresATagProperty() throws {
        var hits: [String] = []
        var views: [String] = []
        for path in Self.newSources + [Self.stopButton] {
            let code = try Self.code(path)
            let found = Self.viewClasses(in: code)
            views += found.map(\.name)
            for view in found where view.declaresTag { hits.append("\(path): \(view.name)") }
        }

        XCTAssertGreaterThanOrEqual(views.count, 5, "the scan found the views of these files (found \(views))")
        XCTAssertTrue(hits.isEmpty, """
            A view in the task window's files declares `tag`, which is `NSView.tag` (an `Int`): the override \
            collides, and a `String` tag shadows it. Use `focusTag`. Found: \(hits.joined(separator: "; "))
            """)
    }

    func testTheTagScanSeesAViewsTagAndNotAModelsTag() {
        let snippet = """
            final class FakeView: NSView {
                let tag: String
            }
            final class FakeRow: FakeView, Something {
                var tag: Int { 3 }
            }
            final class FakeModel {
                let tag: String
            }
            final class FakeFine: NSView {
                let focusTag: String
            }
            """

        let found = Self.viewClasses(in: snippet)

        XCTAssertEqual(found.map(\.name), ["FakeView", "FakeRow", "FakeFine"])
        XCTAssertEqual(found.map(\.declaresTag), [true, true, false])
    }

    // MARK: (c) Subscriptions capture self weakly

    func testEveryClosureThatSubscribesCapturesSelfWeakly() throws {
        var hits: [String] = []
        var inspected = 0
        for path in Self.newSources {
            let code = try Self.code(path)
            let result = Self.closuresMissingWeakSelf(in: code)
            inspected += result.inspected
            hits += result.lines.map { "\(path):\($0)" }
        }

        XCTAssertGreaterThanOrEqual(inspected, 5, "the scan found the subscribing closures of these files (found \(inspected))")
        XCTAssertTrue(hits.isEmpty, """
            A closure that subscribes (`.sink`, `addObserver`, `schedule(`, `Timer`) and uses `self` must capture \
            `[weak self]`: a strong capture keeps the window, the pane or the model alive for as long as the \
            publisher, the notification centre or the run loop does. Found: \(hits.joined(separator: "; "))
            """)
    }

    func testTheWeakSelfScanFlagsAStrongCaptureAndPassesAWeakOneOrOneThatNeverUsesSelf() {
        let strong = """
            cancellable = subject.sink { value in self.handle(value) }
            """
        let weak = """
            cancellable = subject.sink { [weak self] value in self?.handle(value) }
            observers.append(NotificationCenter.default.addObserver(
                forName: .x, object: nil, queue: .main
            ) { [weak self] _ in self?.go() })
            timer = schedule(1) { [weak self] in
                guard let self else { return }
                self.fire()
            }
            let t = Timer(timeInterval: 1, repeats: false) { _ in work() }
            """

        XCTAssertEqual(Self.closuresMissingWeakSelf(in: strong).lines, [1])
        let fine = Self.closuresMissingWeakSelf(in: weak)
        XCTAssertEqual(fine.lines, [])
        XCTAssertEqual(fine.inspected, 4)
    }

    // MARK: (d) The window is a panel the app does not terminate with

    func testTaskPanelIsAPanelAndNotANostromoWindow() throws {
        let code = try Self.code(Self.controller)

        let inheritance = try XCTUnwrap(Self.inheritance(of: "TaskPanel", in: code), "TaskPanel is declared in \(Self.controller)")
        XCTAssertTrue(inheritance.contains("NSPanel"), "TaskPanel is an NSPanel: \(inheritance)")
        XCTAssertFalse(inheritance.contains("NostromoWindow"),
                       "NostromoWindow's windowShouldClose ends the app; a task window must never inherit it")
    }

    func testTheControllerIsTheDelegateWhoseWindowShouldCloseSaysYesAndNeverTerminatesTheApp() throws {
        let code = try Self.code(Self.controller)

        let inheritance = try XCTUnwrap(Self.inheritance(of: "TaskWindowController", in: code), "TaskWindowController is declared")
        XCTAssertTrue(inheritance.contains("NSWindowDelegate"), "TaskWindowController is a window delegate: \(inheritance)")
        XCTAssertTrue(code.contains("panel.delegate = self"), "and it is the panel's delegate")
        let body = try Self.isolatedFunctionBody(named: "func windowShouldClose", in: code, sourceFile: "TaskWindowController.swift")
        XCTAssertTrue(body.contains("true"), "windowShouldClose answers yes")
        XCTAssertFalse(body.contains("false"), "and never no")
        XCTAssertNil(code.range(of: #"\bterminate\b"#, options: .regularExpression),
                     "closing a task window must never end the app: TaskWindowController.swift must not call terminate")
    }

    // MARK: (e) Menu validation

    private static func validateMenuItemChunks() throws -> [String] {
        let code = try Self.code("Nostromo/AppDelegate.swift")
        let body = try Self.isolatedFunctionBody(named: "func validateMenuItem", in: code, sourceFile: "AppDelegate.swift")
        return body.components(separatedBy: "menuItem.action ==")
    }

    private func assertGate(_ action: String, requires needle: String, because reason: String,
                            file: StaticString = #filePath, line: UInt = #line) throws {
        let chunk = try XCTUnwrap(try Self.validateMenuItemChunks().first { $0.contains(action) },
                                  "AppDelegate.validateMenuItem has no case for \(action)", file: file, line: line)
        XCTAssertTrue(chunk.contains(needle),
                      "validateMenuItem must gate \(action) on `\(needle)`: \(reason)", file: file, line: line)
    }

    func testMenuValidationStillGatesTheTerminalItemsOnTheKeyWindowsFirstResponder() throws {
        let reason = "with a task panel key its text view holds the keyboard, so the item must be off"
        for action in ["#selector(terminalFind(_:))", "#selector(terminalSendSelection(_:))",
                       "#selector(focusStagedCommands(_:))", "#selector(closeTerminalPane(_:))"] {
            try assertGate(action, requires: "firstResponder", because: reason)
        }
    }

    func testMenuValidationStillGatesNewTerminalAndNewRemoteShellOnTheMainLayout() throws {
        let reason = "⌘T and ⇧⌘T open into the key window's focus; a task panel has none, so with it key they are off"
        try assertGate("#selector(newTerminal(_:))", requires: "contentView is MainLayout", because: reason)
        try assertGate("#selector(newRemoteShell(_:))", requires: "contentView is MainLayout", because: reason)
    }

    func testMenuValidationStillGatesTheModelAndBackgroundShortcutsOnTheKeyWindowsInputBars() throws {
        let reason = "⇧⌘M and ⇧⌘B act on an input bar of the key window; a task panel has none, so they are off"
        try assertGate("ModelShortcut.action", requires: "bars(in: NSApp.keyWindow)", because: reason)
        try assertGate("BackgroundShortcut.action", requires: "bars(in: NSApp.keyWindow)", because: reason)
    }

    /// ⌥⌘A is not in `validateMenuItem`: it is routed to `MainMenuActions.goToApprovalCard`, which acts on the
    /// key window only (and beeps when that window has no approval card), so a task panel being key is a no-op.
    func testGoToApprovalCardActsOnTheKeyWindowOnly() throws {
        let code = try Self.code("Nostromo/AppDelegate.swift")

        let body = try Self.isolatedFunctionBody(named: "func goToApprovalCard", in: code, sourceFile: "AppDelegate.swift")

        XCTAssertTrue(body.contains("NSApp.keyWindow"), "⌥⌘A must look for the card in the key window only")
    }

    // MARK: (f) Eviction closes the focus's task windows

    func testEvictPerFocusStateClosesTheFocusTaskWindows() throws {
        let code = try Self.code("Nostromo/Data/AppStore.swift")

        let body = try Self.isolatedFunctionBody(named: "func evictPerFocusState", in: code, sourceFile: "AppStore.swift")

        XCTAssertTrue(body.contains("TaskWindowManager.shared.closeWindows(forFocus: tag)"), """
            evictPerFocusState must call TaskWindowManager.shared.closeWindows(forFocus: tag): a closed focus's \
            task windows would otherwise outlive it, polling a session that no longer exists.
            """)
    }

    // MARK: (g) The daemon's output answers reach the requests

    /// `tasks output` returns raw task output, which terminals and screenshots never give an agent in the real
    /// app: the server (not in the test bundle) must hand `AppControlTasks.output` the synthetic-input gate.
    func testTheTasksOutputVerbIsGatedOnTheSyntheticInputGate() throws {
        let server = try Self.source("Nostromo/AppControl/AppControlServer.swift")
        let body = try Self.isolatedFunctionBody(named: "private func tasks(", in: server, sourceFile: "AppControlServer.swift")
        XCTAssertTrue(body.contains("AppControlTasks.output("), "`tasks output` must answer from AppControlTasks.output")
        XCTAssertTrue(body.contains("allowsText: SyntheticInputGate.allowsSynthetic"),
                      "the text of `tasks output` must be withheld unless SyntheticInputGate.allowsSynthetic")
        XCTAssertFalse(body.contains("TaskWindowManager.shared.open"), "`tasks output` must never open a window")
    }

    func testAppStoreRoutesTaskOutputResultsToTheSharedRequests() throws {
        let code = try Self.code("Nostromo/Data/AppStore.swift")
        let body = try Self.isolatedFunctionBody(named: "func handle(_ msg: ServerMsg)", in: code, sourceFile: "AppStore.swift")

        let lines = body.components(separatedBy: "\n")
        let start = try XCTUnwrap(lines.firstIndex { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("case ") && trimmed.contains(".sessionTaskOutputResult")
        }, "AppStore.handle has no case for .sessionTaskOutputResult")
        var arm = ""
        for line in lines[(start + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("case ") || trimmed.hasPrefix("default") { break }
            arm += line + "\n"
        }

        XCTAssertTrue(arm.contains("TaskRequests.shared.ingest"), """
            AppStore.handle must hand .sessionTaskOutputResult to TaskRequests.shared.ingest: without it no read \
            ever completes, and every task window stays on "Loading output" until the request times out.
            """)
    }

    // MARK: (h) The panel is not an app-control window

    func testTheTaskPanelIsNotRegisteredWithTheAppsWindowLists() throws {
        let code = try Self.code(Self.controller)

        for name in ["qaExtraWindows", "appDelegate", "AppDelegate", "NostromoWindow"] {
            XCTAssertNil(code.range(of: "\\b\(name)\\b", options: .regularExpression), """
                TaskWindowController.swift must not mention \(name): a window in AppDelegate.windows or \
                qaExtraWindows is reachable by app-control (screenshot, tree, click), which would bypass the \
                screenshot redaction policy for a task's output.
                """)
        }
    }

    // MARK: The scan helpers themselves

    func testTheStripperKeepsCodeAndLineNumbersAndDropsCommentsAndStrings() {
        let source = "let a = \"x \\(y(\"q\")) z\" // c\n/* b\nb */ print(1)\nlet m = \"\"\"\nprint(2)\n\"\"\"\nprint(3)\n"

        let code = Self.strippingCommentsAndStrings(source)

        XCTAssertTrue(code.contains("print(1)"))
        XCTAssertTrue(code.contains("print(3)"))
        XCTAssertFalse(code.contains("print(2)"), "the body of a multi-line string is not code")
        XCTAssertFalse(code.contains("q"), "an interpolation inside a string is not scanned")
        XCTAssertEqual(code.components(separatedBy: "\n").count, source.components(separatedBy: "\n").count, "lines are kept")
    }

    // MARK: - Scans

    private struct LoggingHit { let line: Int; let what: String }

    private static func loggingCalls(in code: String) -> [LoggingHit] {
        let patterns: [(String, String)] = [(#"\bprint\("#, "print("), (#"\bdebugPrint\("#, "debugPrint("),
                                            (#"\bNSLog\("#, "NSLog("), (#"\bos_log\("#, "os_log("),
                                            (#"\bLogger\b"#, "Logger"), (#"\blog\."#, "log."), (#"\bappLog\."#, "appLog.")]
        var hits: [LoggingHit] = []
        for (pattern, what) in patterns {
            for range in matches(of: pattern, in: code) { hits.append(LoggingHit(line: line(of: range.location, in: code), what: what)) }
        }
        return hits
    }

    private struct ViewClass { let name: String; let declaresTag: Bool }

    private static let viewRoots: Set<String> = ["NSView", "NSTextView", "NSTextField", "NSControl", "NSButton", "NSScrollView",
                                                 "NSStackView", "NSClipView", "NSBox", "NSImageView", "NSTableView",
                                                 "NSOutlineView", "NSVisualEffectView", "NSTableCellView"]

    /// The classes of `code` that are NSViews (directly or through another class of the same text), and whether
    /// each declares a property named `tag`.
    private static func viewClasses(in code: String) -> [ViewClass] {
        let ns = code as NSString
        let regex = try! NSRegularExpression(pattern: #"\bclass\s+(\w+)\s*:\s*([^\{]+)\{"#)
        struct Declaration { let name: String; let supers: [String]; let bodyStart: Int }
        let declarations: [Declaration] = regex.matches(in: code, range: NSRange(location: 0, length: ns.length)).map { match in
            let supers = ns.substring(with: match.range(at: 2)).split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            return Declaration(name: ns.substring(with: match.range(at: 1)), supers: supers, bodyStart: match.range.upperBound - 1)
        }
        var views = viewRoots
        var changed = true
        while changed {
            changed = false
            for declaration in declarations where !views.contains(declaration.name) && declaration.supers.contains(where: views.contains) {
                views.insert(declaration.name)
                changed = true
            }
        }
        let units = Array(code.utf16)
        return declarations.filter { views.contains($0.name) }.map { declaration in
            let end = closing(units, from: declaration.bodyStart, open: "{", close: "}") ?? units.count - 1
            let body = String(decoding: units[declaration.bodyStart ... end], as: UTF16.self)
            return ViewClass(name: declaration.name, declaresTag: !matches(of: #"\b(let|var)\s+tag\b"#, in: body).isEmpty)
        }
    }

    /// The text after `class <name>:` up to its `{`, nil when there is no such class.
    private static func inheritance(of name: String, in code: String) -> String? {
        let ns = code as NSString
        let regex = try! NSRegularExpression(pattern: "\\bclass\\s+\(name)\\s*:\\s*([^\\{]+)\\{")
        guard let match = regex.firstMatch(in: code, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    /// The closures handed to `.sink`, `addObserver`, `schedule(` and `Timer` that use `self` without
    /// capturing it weakly (line numbers), and how many closures were looked at.
    private static func closuresMissingWeakSelf(in code: String) -> (lines: [Int], inspected: Int) {
        let units = Array(code.utf16)
        var lines: [Int] = []
        var inspected = 0
        for pattern in [#"\.sink\b"#, #"\baddObserver\b"#, #"\bschedule\b"#, #"\bTimer\b"#, #"\bscheduledTimer\b"#] {
            for range in matches(of: pattern, in: code) {
                var closures: [String] = []
                var index = skippingSpace(units, from: range.upperBound)
                if index < units.count, units[index] == UInt16(ascii: "(") {
                    guard let close = closing(units, from: index, open: "(", close: ")") else { continue }
                    closures += braceGroups(units, in: (index + 1) ..< close)
                    index = skippingSpace(units, from: close + 1)
                }
                if index < units.count, units[index] == UInt16(ascii: "{"), let close = closing(units, from: index, open: "{", close: "}") {
                    closures.append(String(decoding: units[(index + 1) ..< close], as: UTF16.self))
                }
                for body in closures {
                    inspected += 1
                    let capturesWeakly = String(body.prefix(60)).contains("[weak self")
                    if !capturesWeakly, !matches(of: #"\bself\b"#, in: body).isEmpty {
                        lines.append(line(of: range.location, in: code))
                    }
                }
            }
        }
        return (lines.sorted(), inspected)
    }

    // MARK: - Text helpers

    private static func matches(of pattern: String, in text: String) -> [NSRange] {
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range)
    }

    private static func line(of location: Int, in text: String) -> Int {
        let units = Array(text.utf16)
        return units[..<min(location, units.count)].filter { $0 == 0x0A }.count + 1
    }

    private static func skippingSpace(_ units: [UInt16], from start: Int) -> Int {
        var index = start
        while index < units.count, [0x20, 0x09, 0x0A, 0x0D].contains(units[index]) { index += 1 }
        return index
    }

    /// The index of the bracket that closes the one at `start`.
    private static func closing(_ units: [UInt16], from start: Int, open: Character, close: Character) -> Int? {
        let (opener, closer) = (UInt16(ascii: open.unicodeScalars.first!), UInt16(ascii: close.unicodeScalars.first!))
        var depth = 0
        var index = start
        while index < units.count {
            if units[index] == opener {
                depth += 1
            } else if units[index] == closer {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    /// The text inside each top-level `{ ... }` of `range`.
    private static func braceGroups(_ units: [UInt16], in range: Range<Int>) -> [String] {
        var groups: [String] = []
        var index = range.lowerBound
        while index < range.upperBound {
            if units[index] == UInt16(ascii: "{"), let close = closing(units, from: index, open: "{", close: "}"), close < range.upperBound {
                groups.append(String(decoding: units[(index + 1) ..< close], as: UTF16.self))
                index = close
            }
            index += 1
        }
        return groups
    }

    // MARK: - Source

    private static func source(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)     // …/macOS/NostromoTests/TaskWindowFitnessTests.swift
            .deletingLastPathComponent()                // …/macOS/NostromoTests
            .deletingLastPathComponent()                // …/macOS
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// A file's code: comments removed, string literals emptied, line numbers kept.
    private static func code(_ relativePath: String) throws -> String {
        strippingCommentsAndStrings(try source(relativePath))
    }

    private static func strippingCommentsAndStrings(_ source: String) -> String {
        let chars = Array(source)
        let count = chars.count
        var out = ""
        out.reserveCapacity(count)
        var i = 0

        func at(_ offset: Int) -> Character? { i + offset < count ? chars[i + offset] : nil }

        while i < count {
            let c = chars[i]
            if c == "/", at(1) == "/" {
                while i < count, chars[i] != "\n" { i += 1 }
            } else if c == "/", at(1) == "*" {
                var depth = 1
                i += 2
                while i < count, depth > 0 {
                    if chars[i] == "/", at(1) == "*" {
                        depth += 1
                        i += 2
                    } else if chars[i] == "*", at(1) == "/" {
                        depth -= 1
                        i += 2
                    } else {
                        if chars[i] == "\n" { out.append("\n") }
                        i += 1
                    }
                }
            } else if c == "\"", at(1) == "\"", at(2) == "\"" {
                i += 3
                while i < count {
                    if chars[i] == "\\" {
                        i += 2
                    } else if chars[i] == "\"", at(1) == "\"", at(2) == "\"" {
                        i += 3
                        break
                    } else {
                        if chars[i] == "\n" { out.append("\n") }
                        i += 1
                    }
                }
                out.append("\"\"")
            } else if c == "\"" {
                i += 1
                while i < count, chars[i] != "\"", chars[i] != "\n" {
                    if chars[i] == "\\", at(1) == "(" {
                        // An interpolation: skip to its closing parenthesis.
                        var depth = 0
                        i += 1
                        while i < count {
                            if chars[i] == "(" { depth += 1 }
                            if chars[i] == ")" {
                                depth -= 1
                                if depth == 0 { break }
                            }
                            if chars[i] == "\n" { out.append("\n") }
                            i += 1
                        }
                    } else if chars[i] == "\\" {
                        i += 1
                    }
                    i += 1
                }
                i += 1
                out.append("\"\"")
            } else {
                out.append(c)
                i += 1
            }
        }
        return out
    }

    /// Isolates a function's body by counting braces from its first `{` after `signature` to the matching
    /// close (the helper of `PerFocusEvictionWiringTests`, which keeps its own private).
    private static func isolatedFunctionBody(named signature: String, in source: String, sourceFile: String,
                                             file: StaticString = #filePath, line: UInt = #line) throws -> String {
        guard let sigRange = source.range(of: signature) else {
            XCTFail("\(signature) not found in \(sourceFile)", file: file, line: line)
            return ""
        }
        guard let openBrace = source[sigRange.upperBound...].firstIndex(of: "{") else {
            XCTFail("\(signature) has no body in \(sourceFile)", file: file, line: line)
            return ""
        }
        var depth = 0
        var idx = openBrace
        while idx < source.endIndex {
            let ch = source[idx]
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 { return String(source[source.index(after: openBrace)..<idx]) }
            }
            idx = source.index(after: idx)
        }
        XCTFail("could not find a matching closing brace for \(signature) in \(sourceFile)", file: file, line: line)
        return ""
    }
}
