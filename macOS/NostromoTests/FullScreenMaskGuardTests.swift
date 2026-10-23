import XCTest

// FS-1 guard. macOS 27 raises NSGenericException ("NSWindowStyleMaskFullScreen cleared on
// a window outside of a full screen transition.") when code clears `.fullScreen` from a
// window's `styleMask` while the window is not in a transition, and the app dies. Clearing
// the bit is legal only DURING a transition, and closing a full-screen window mid-transition
// without clearing it first is the `_NSExitFullScreenTransitionController` crash.
//
// So exactly one place in production code may clear the bit: the body of
// `NostromoWindow.clearFullScreenMaskDuringTransition(logContext:)`, which must guard on
// `isInTransition` itself. Everywhere else a full-screen window is closed, never
// "un-full-screened" by hand.
//
// This is a source-level tripwire, not a behavior test: it reads every Swift file under
// macOS/Nostromo and fails if one reintroduces a way of clearing the mask outside that
// function. (The behavior is covered by FullScreenTeardownLegalityTests and
// RealFullScreenTeardownTests.) It looks only at code: comments and string literals are
// blanked first.

/// Finds the constructs that clear, or can clear, `.fullScreen` from a style mask.
enum FullScreenMaskScanner {

    struct Violation: Equatable {
        let line: Int          // 1-based
        let rule: String
        let code: String       // the offending line, comments and strings blanked, trimmed
    }

    private static let rules: [(name: String, pattern: String)] = [
        ("removes .fullScreen from a mask", #"\.(remove|subtract)\(\s*\[?\s*\.fullScreen\b"#),
        ("mutates styleMask in place", #"\bstyleMask\s*\.\s*(remove|subtract|formIntersection|formSymmetricDifference)\b"#),
        ("assigns styleMask", #"\bstyleMask\s*(=(?!=)|&=|\^=|-=)"#),
    ]

    private static let compiled: [(name: String, regex: NSRegularExpression)] = rules.map {
        (name: $0.name, regex: try! NSRegularExpression(pattern: $0.pattern))
    }

    /// The one function allowed to clear the bit (it guards on `isInTransition` itself).
    static let allowedFunctionName = "clearFullScreenMaskDuringTransition"

    /// Violations in `source`. Lines inside the brace-balanced declaration of a function named
    /// `exemptFunctionName` (if given) are not reported; every other line is.
    static func violations(in source: String, exemptingFunctionNamed exemptFunctionName: String? = nil) -> [Violation] {
        var found: [Violation] = []
        let lines = codeOnly(source)
        let exempt = exemptFunctionName.map { functionSpans(named: $0, in: lines) } ?? []
        for (index, line) in lines.enumerated() {
            if exempt.contains(where: { $0.contains(index) }) { continue }
            let range = NSRange(line.startIndex..., in: line)
            for rule in compiled where rule.regex.firstMatch(in: line, range: range) != nil {
                found.append(Violation(line: index + 1, rule: rule.name,
                                       code: line.trimmingCharacters(in: .whitespaces)))
            }
        }
        return found
    }

    /// The 0-based line ranges of every declaration `func <name>` in `lines` (comment/string-stripped
    /// code, as `codeOnly` returns), from the declaration line through the line of the brace that
    /// closes its body. A call or a longer name (`func <name>AndMore`) is not a declaration.
    static func functionSpans(named name: String, in lines: [String]) -> [Range<Int>] {
        let declaration = try! NSRegularExpression(
            pattern: #"\bfunc\s+"# + NSRegularExpression.escapedPattern(for: name) + #"\b"#)
        var spans: [Range<Int>] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard declaration.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else {
                index += 1
                continue
            }
            var depth = 0
            var opened = false
            var end = lines.count - 1          // an unterminated body runs to the end of the file
            scan: for j in index..<lines.count {
                for ch in lines[j] {
                    if ch == "{" {
                        depth += 1
                        opened = true
                    } else if ch == "}" {
                        depth -= 1
                        if opened, depth == 0 { end = j; break scan }
                    }
                }
            }
            spans.append(index..<(end + 1))
            index = end + 1
        }
        return spans
    }

    /// The source's lines (the count and order preserved) with `//` and nested `/* */`
    /// comments removed and string-literal contents dropped.
    static func codeOnly(_ source: String) -> [String] {
        let chars = Array(source)
        var lines: [String] = []
        var current = ""
        var blockDepth = 0
        var inString = false
        var inMultilineString = false
        var i = 0

        func peek(_ offset: Int) -> Character? { i + offset < chars.count ? chars[i + offset] : nil }

        while i < chars.count {
            let c = chars[i]
            if c == "\n" {
                lines.append(current)
                current = ""
                inString = false                      // a single-line string ends with its line
                i += 1
                continue
            }
            if blockDepth > 0 {
                if c == "*", peek(1) == "/" { blockDepth -= 1; i += 2 }
                else if c == "/", peek(1) == "*" { blockDepth += 1; i += 2 }
                else { i += 1 }
                continue
            }
            if inMultilineString {
                if c == "\\", let next = peek(1), next != "\n" { i += 2 }
                else if c == "\"", peek(1) == "\"", peek(2) == "\"" { inMultilineString = false; i += 3 }
                else { i += 1 }
                continue
            }
            if inString {
                if c == "\\", let next = peek(1), next != "\n" { i += 2; continue }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "/", peek(1) == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", peek(1) == "*" { blockDepth = 1; i += 2; continue }
            if c == "\"" {
                if peek(1) == "\"", peek(2) == "\"" { inMultilineString = true; i += 3 }
                else { inString = true; i += 1 }
                continue
            }
            current.append(c)
            i += 1
        }
        lines.append(current)
        return lines
    }
}

final class FullScreenMaskGuardTests: XCTestCase {

    /// Fails loudly (rather than passing vacuously) when the sources are not where the test expects.
    private static let minimumFilesExpected = 100

    private func productionSourceDirectory() -> URL {
        URL(fileURLWithPath: #filePath)                     // .../macOS/NostromoTests/FullScreenMaskGuardTests.swift
            .deletingLastPathComponent()                    // .../macOS/NostromoTests
            .deletingLastPathComponent()                    // .../macOS
            .appendingPathComponent("Nostromo", isDirectory: true)
    }

    private func swiftFiles(under directory: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    // MARK: - The tripwire

    /// Every production Swift file (path relative to macOS/Nostromo, source text), sorted by path.
    /// Fails loudly (rather than passing vacuously) when the sources are not where the test expects.
    private func productionSources() throws -> [(relativePath: String, source: String)] {
        let directory = productionSourceDirectory()
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
        XCTAssertTrue(exists && isDirectory.boolValue,
                      "macOS/Nostromo sources not found at \(directory.path): this guard would pass vacuously")

        let files = swiftFiles(under: directory).sorted(by: { $0.path < $1.path })
        XCTAssertGreaterThanOrEqual(files.count, Self.minimumFilesExpected,
                                    "only \(files.count) Swift files found under \(directory.path): this guard would pass vacuously")

        return try files.map { file in
            (relativePath: file.path.replacingOccurrences(of: directory.path + "/", with: ""),
             source: try String(contentsOf: file, encoding: .utf8))
        }
    }

    func test_no_production_code_clears_full_screen_from_a_style_mask_except_in_the_transition_only_method() throws {
        var offences: [String] = []
        for (relativePath, source) in try productionSources() {
            let found = FullScreenMaskScanner.violations(
                in: source, exemptingFunctionNamed: FullScreenMaskScanner.allowedFunctionName)
            for v in found {
                offences.append("\(relativePath):\(v.line): \(v.rule): \(v.code)")
            }
        }

        XCTAssertEqual(offences, [],
                       "clearing .fullScreen outside a transition raises NSGenericException on macOS 27 and kills the app; "
                       + "only \(FullScreenMaskScanner.allowedFunctionName) may do it, and only during a transition:\n"
                       + offences.joined(separator: "\n"))
    }

    func test_the_transition_only_method_exists_in_one_place_and_guards_on_isInTransition() throws {
        let name = FullScreenMaskScanner.allowedFunctionName
        var declarations: [(file: String, body: String)] = []
        for (relativePath, source) in try productionSources() {
            let lines = FullScreenMaskScanner.codeOnly(source)
            for span in FullScreenMaskScanner.functionSpans(named: name, in: lines) {
                declarations.append((file: relativePath, body: lines[span].joined(separator: "\n")))
            }
        }

        XCTAssertEqual(declarations.map { $0.file }, ["NostromoWindow.swift"],
                       "\(name) must be declared exactly once, in NostromoWindow.swift: it is the only exemption from the mask guard")
        guard let declaration = declarations.first else { return }

        // The exemption must not be a blanket pass: the method itself refuses to run outside a transition.
        let transitionGuard = try NSRegularExpression(pattern: #"\b(guard|if)\b[^{}]*\bisInTransition\b"#)
        let range = NSRange(declaration.body.startIndex..., in: declaration.body)
        XCTAssertNotNil(transitionGuard.firstMatch(in: declaration.body, range: range),
                        "\(name) must guard on isInTransition itself:\n\(declaration.body)")
    }

    // MARK: - The matcher itself

    func test_the_matcher_flags_the_code_that_crashed_on_macOS_27() {
        let old = """
        guard win.styleMask.contains(.fullScreen) else { return }
        var mask = win.styleMask
        mask.remove(.fullScreen)
        win.styleMask = mask
        """

        let found = FullScreenMaskScanner.violations(in: old)

        XCTAssertEqual(found.map(\.line), [3, 4], "the removal and the assignment, on their own lines")
    }

    func test_the_matcher_flags_each_way_of_clearing_the_bit() {
        let samples = [
            "mask.remove(.fullScreen)",
            "mask.remove([.fullScreen])",
            "mask.subtract(.fullScreen)",
            "win.styleMask.remove(.fullScreen)",
            "win.styleMask.subtract([.fullScreen, .titled])",
            "window.styleMask.formIntersection([.titled])",
            "win.styleMask = [.titled]",
            "win.styleMask = mask",
            "styleMask &= ~.fullScreen",
        ]
        for sample in samples {
            XCTAssertFalse(FullScreenMaskScanner.violations(in: sample).isEmpty, "should flag: \(sample)")
        }
    }

    func test_the_matcher_ignores_reads_and_unrelated_code() {
        let samples = [
            "win.styleMask.contains(.fullScreen)",
            "guard !self.styleMask.contains(.fullScreen), !self.isInTransition else { return }",
            "let isFull = styleMask.contains(.fullScreen)",
            "if a.styleMask == b.styleMask { }",
            "super.init(contentRect: r, styleMask: style, backing: .buffered, defer: flag)",
            "NSWindow(contentRect: r, styleMask: [.titled, .resizable], backing: .buffered, defer: true)",
            "win.collectionBehavior = [.fullScreenPrimary, .managed]",
            "phase = .fullScreen",
            "pending.remove(.titled)",
        ]
        for sample in samples {
            XCTAssertEqual(FullScreenMaskScanner.violations(in: sample), [], "should not flag: \(sample)")
        }
    }

    func test_the_matcher_ignores_comments_and_string_literals() {
        let source = #"""
        // mask.remove(.fullScreen)
        /// win.styleMask = mask
        let a = 1 // win.styleMask = mask
        /* win.styleMask.remove(.fullScreen)
           win.styleMask = mask
           /* nested: mask.subtract(.fullScreen) */
           still a comment: win.styleMask = mask */
        let log = "never write win.styleMask = mask or mask.remove(.fullScreen)"
        let escaped = "quote \" then win.styleMask = mask"
        let multi = """
            win.styleMask = mask
            mask.remove(.fullScreen)
            """
        let url = "https://example.com/win.styleMask = mask"
        """#

        XCTAssertEqual(FullScreenMaskScanner.violations(in: source), [])
    }

    func test_the_matcher_still_flags_code_that_follows_a_comment_or_string_on_the_same_line() {
        let source = """
        let s = "x"; win.styleMask = mask
        /* note */ mask.remove(.fullScreen)
        """

        XCTAssertEqual(FullScreenMaskScanner.violations(in: source).map(\.line), [1, 2])
    }

    func test_line_numbers_stay_correct_across_block_comments_and_multiline_strings() {
        let source = """
        let a = 1
        /* one
           two */
        let text = \"\"\"
            line
            \"\"\"
        win.styleMask = mask
        """

        XCTAssertEqual(FullScreenMaskScanner.violations(in: source).map(\.line), [7])
    }

    // MARK: - The matcher: the one allowed function

    /// (Not `name`: XCTestCase already has one.)
    private let allowed = FullScreenMaskScanner.allowedFunctionName

    func test_a_clear_inside_the_allowed_function_is_not_flagged() {
        let source = """
        final class W {
            private func \(allowed)(logContext: String) {
                guard isInTransition, styleMask.contains(.fullScreen) else { return }
                var mask = styleMask
                mask.remove(.fullScreen)
                styleMask = mask
            }
        }
        """

        XCTAssertEqual(FullScreenMaskScanner.violations(in: source, exemptingFunctionNamed: allowed), [])
        XCTAssertEqual(FullScreenMaskScanner.violations(in: source).map(\.line), [5, 6],
                       "without the exemption the same code is flagged: the exemption is what changes the verdict")
    }

    func test_the_same_clear_in_another_function_of_the_same_file_is_flagged() {
        let source = """
        final class W {
            func before() {
                styleMask = [.titled]
            }
            private func \(allowed)(logContext: String) {
                mask.remove(.fullScreen)
            }
            func after() {
                mask.remove(.fullScreen)
            }
        }
        """

        XCTAssertEqual(FullScreenMaskScanner.violations(in: source, exemptingFunctionNamed: allowed).map(\.line), [3, 9])
    }

    func test_a_nested_brace_body_is_exempt_to_its_closing_brace_and_no_further() {
        let source = """
        func \(allowed)(logContext: String) {
            if isInTransition {
                let apply = { (m: NSWindow.StyleMask) in
                    styleMask = m
                }
                apply(styleMask)
            }
            let s = "a } brace in a string"
            // a } brace in a comment
            /* and } in a block comment */
            mask.remove(.fullScreen)
        }
        mask.remove(.fullScreen)
        """

        XCTAssertEqual(FullScreenMaskScanner.violations(in: source, exemptingFunctionNamed: allowed).map(\.line), [13],
                       "only the clear after the function's closing brace is flagged")
    }

    func test_an_opening_brace_on_a_later_line_than_the_declaration_still_starts_the_body() {
        let source = """
        func \(allowed)(
            logContext: String
        )
        {
            mask.remove(.fullScreen)
        }
        mask.remove(.fullScreen)
        """

        XCTAssertEqual(FullScreenMaskScanner.violations(in: source, exemptingFunctionNamed: allowed).map(\.line), [7])
    }

    func test_the_exemption_applies_only_where_the_function_is_declared() {
        let withoutIt = """
        func somethingElse() {
            mask.remove(.fullScreen)
        }
        let call: () = \(allowed)(logContext: "x")
        """

        XCTAssertEqual(FullScreenMaskScanner.violations(in: withoutIt, exemptingFunctionNamed: allowed).map(\.line), [2],
                       "naming or calling the function is not declaring it")
    }

    func test_a_function_whose_name_merely_starts_with_the_allowed_name_is_not_exempt() {
        let source = """
        func \(allowed)AndMore() {
            mask.remove(.fullScreen)
        }
        """

        XCTAssertEqual(FullScreenMaskScanner.violations(in: source, exemptingFunctionNamed: allowed).map(\.line), [2])
    }

    func test_every_declaration_of_the_allowed_name_is_found_so_a_duplicate_can_be_detected() {
        let lines = FullScreenMaskScanner.codeOnly("""
        func \(allowed)(a: Int) {
            if x { y() }
        }
        func other() { }
        func \(allowed)(b: Int) { }
        """)

        XCTAssertEqual(FullScreenMaskScanner.functionSpans(named: allowed, in: lines), [0..<3, 4..<5])
    }
}
