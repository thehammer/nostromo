import XCTest

// FS-1 guard. macOS 27 raises NSGenericException ("NSWindowStyleMaskFullScreen cleared on
// a window outside of a full screen transition.") when code clears `.fullScreen` from a
// window's `styleMask` while the window is not in a transition, and the app dies. The only
// transitions Nostromo ever has are AppKit's own, so no production code should clear the
// bit at all: a full-screen window is closed, never "un-full-screened" by hand.
//
// This is a source-level tripwire, not a behavior test: it reads every Swift file under
// macOS/Nostromo and fails if one reintroduces a way of clearing the mask. (The behavior is
// covered by FullScreenTeardownLegalityTests and RealFullScreenTeardownTests.) It looks
// only at code: comments and string literals are blanked first.

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

    static func violations(in source: String) -> [Violation] {
        var found: [Violation] = []
        for (index, line) in codeOnly(source).enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            for rule in compiled where rule.regex.firstMatch(in: line, range: range) != nil {
                found.append(Violation(line: index + 1, rule: rule.name,
                                       code: line.trimmingCharacters(in: .whitespaces)))
            }
        }
        return found
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

    func test_no_production_code_clears_full_screen_from_a_window_style_mask() throws {
        let directory = productionSourceDirectory()
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
        XCTAssertTrue(exists && isDirectory.boolValue,
                      "macOS/Nostromo sources not found at \(directory.path): this guard would pass vacuously")

        let files = swiftFiles(under: directory)
        XCTAssertGreaterThanOrEqual(files.count, Self.minimumFilesExpected,
                                    "only \(files.count) Swift files found under \(directory.path): this guard would pass vacuously")

        var offences: [String] = []
        for file in files.sorted(by: { $0.path < $1.path }) {
            let source = try String(contentsOf: file, encoding: .utf8)
            for v in FullScreenMaskScanner.violations(in: source) {
                let relative = file.path.replacingOccurrences(of: directory.path + "/", with: "")
                offences.append("\(relative):\(v.line): \(v.rule): \(v.code)")
            }
        }

        XCTAssertEqual(offences, [],
                       "clearing .fullScreen outside a transition raises NSGenericException on macOS 27 and kills the app; close the window instead:\n"
                       + offences.joined(separator: "\n"))
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
}
