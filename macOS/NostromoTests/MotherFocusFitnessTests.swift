import XCTest
import Foundation

// Fitness functions for the in-pane plan viewer (R12/R13, SR2, SR7), read from the source text.
//
// A plan is untrusted text from disk. The viewer must therefore log nothing about it, run nothing,
// fetch nothing, open nothing but a web link on a click, and only read what the loader's rules allow.
// These scans keep that true as later slices add files: add a new source file to `planViewerSources`.
//
// Comments are stripped before scanning so documentation can say what the code must not do.

final class MotherFocusFitnessTests: XCTestCase {

    // MARK: - What is scanned

    /// Paths under `macOS/Nostromo/`. Later slices extend this list.
    private static let planViewerSources = [
        "UI/Mother/PlanDocumentView.swift",
        "UI/Mother/PlanFileLoader.swift",
    ]

    /// The job detail the plan views live in. It has its own `Logger` and its own host calls, so the scans
    /// that make sense for a plan's text (nothing fetched, nothing run, nothing logged about a plan,
    /// no way to open a file) apply to it, and the logging scan is the narrower one in
    /// `testTheJobDetailLogsNothingAboutAPlan`.
    private static let jobDetailSources = ["UI/Views/MotherJobDetail.swift"]

    /// Files that must never declare an `NSView.tag` of their own (#356).
    private static let tagSensitiveSources = planViewerSources + jobDetailSources

    private static func source(_ relativePath: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        var root = URL(fileURLWithPath: "\(file)")
        for _ in 0..<3 { root.deleteLastPathComponent() }   // NostromoTests, macOS, repo root
        let url = root.appendingPathComponent("macOS/Nostromo").appendingPathComponent(relativePath)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.isEmpty, "\(relativePath) is empty", file: file, line: line)
        return stripComments(text)
    }

    /// `text` without its comments: block comments (nested, as Swift has them) and `//` comments, but a
    /// `//` inside a string literal (a URL, a path, a pattern) is text, not a comment. Line breaks stay,
    /// so line numbers and "first line that contains" scans still mean something.
    static func stripComments(_ text: String) -> String {
        let chars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        var blockDepth = 0
        var inString = false
        var inMultilineString = false

        func at(_ k: Int) -> Unicode.Scalar? { k < chars.count ? chars[k] : nil }

        while i < chars.count {
            let c = chars[i]
            let next = at(i + 1)
            if blockDepth > 0 {
                if c == "/", next == "*" { blockDepth += 1; i += 2 }
                else if c == "*", next == "/" { blockDepth -= 1; i += 2 }
                else { if c == "\n" { out.append(c) }; i += 1 }
                continue
            }
            if inMultilineString {
                if c == "\\", let next { out.append(c); out.append(next); i += 2; continue }
                if c == "\"", next == "\"", at(i + 2) == "\"" {
                    out.append(contentsOf: [c, c, c])
                    inMultilineString = false
                    i += 3
                    continue
                }
                out.append(c)
                i += 1
                continue
            }
            if inString {
                if c == "\\", let next { out.append(c); out.append(next); i += 2; continue }
                if c == "\"" || c == "\n" { inString = false }   // a line break ends a string that was never closed
                out.append(c)
                i += 1
                continue
            }
            if c == "/", next == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", next == "*" { blockDepth = 1; i += 2; continue }
            if c == "\"" {
                if next == "\"", at(i + 2) == "\"" {
                    out.append(contentsOf: [c, c, c])
                    inMultilineString = true
                    i += 3
                    continue
                }
                inString = true
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }

    private func matches(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    // MARK: - Tests

    func testThePlanViewerSourcesLogNothing() throws {
        let forbidden = ["\\bprint\\(", "\\bNSLog\\(", "\\bos_log\\(", "\\bLogger\\("]
        for path in Self.planViewerSources {
            let text = try Self.source(path)
            for pattern in forbidden {
                XCTAssertFalse(matches(pattern, in: text), "\(path) logs (\(pattern)): a plan's path and text are not for logs")
            }
        }
    }

    func testTheJobDetailLogsNothingAboutAPlanAndOpensNothing() throws {
        for path in Self.jobDetailSources {
            let text = try Self.source(path)
            for pattern in ["\\bprint\\(", "\\bNSLog\\(", "\\bos_log\\("] {
                XCTAssertFalse(matches(pattern, in: text), "\(path) logs (\(pattern))")
            }
            // Each `log.<level>(...)` statement as a whole (it may span lines), one level of parentheses inside.
            let statement = try NSRegularExpression(pattern: "\\blog\\.(debug|info|notice|error|warning|fault|log)\\((?:[^()]|\\([^()]*\\))*\\)")
            for match in statement.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                let call = (text as NSString).substring(with: match.range)
                XCTAssertFalse(call.lowercased().contains("plan") || call.contains("checklist"),
                               "\(path) logs something about a plan: \(call)")
            }
            XCTAssertEqual(occurrences(of: "NSWorkspace.shared.open(", in: text), 0, "\(path) opens nothing itself: the host does")
        }
    }

    func testTheCommentStripperKeepsAStringThatLooksLikeAComment() {
        let code = "let url = \"https://example.com/a//b\" // trailing\nlet s = \"// not a comment\" /* gone */ let t = 1\n"
            + "/* outer /* nested */ still a comment */ let u = \"x\"\n"
        let stripped = Self.stripComments(code)
        XCTAssertTrue(stripped.contains("\"https://example.com/a//b\""), "a URL in a string stays")
        XCTAssertTrue(stripped.contains("\"// not a comment\""), "a `//` in a string stays")
        XCTAssertFalse(stripped.contains("trailing"))
        XCTAssertFalse(stripped.contains("gone"))
        XCTAssertFalse(stripped.contains("nested"))
        XCTAssertFalse(stripped.contains("still a comment"))
        XCTAssertTrue(stripped.contains("let t = 1") && stripped.contains("let u = \"x\""), "the code around comments stays")
    }

    func testTheJobDetailIsAmongTheScannedSourcesAndTheStripperKeepsItsUrlLiterals() throws {
        XCTAssertTrue(Self.jobDetailSources.contains("UI/Views/MotherJobDetail.swift"))
        for path in Self.jobDetailSources {
            XCTAssertTrue(Self.tagSensitiveSources.contains(path), "\(path) is scanned for view tags")
        }
        XCTAssertFalse(Self.planViewerSources.isEmpty)

        // Every string literal in the real sources that holds "://" and is not inside a comment must come out
        // of the stripper whole. (If a source has none, this checks only that the sources are read.)
        for path in Self.planViewerSources + Self.jobDetailSources {
            var root = URL(fileURLWithPath: "\(#filePath)")
            for _ in 0..<3 { root.deleteLastPathComponent() }
            let raw = try String(contentsOf: root.appendingPathComponent("macOS/Nostromo").appendingPathComponent(path), encoding: .utf8)
            let stripped = try Self.source(path)
            XCTAssertLessThan(stripped.utf8.count, raw.utf8.count, "\(path) has comments, and they are gone")
            for line in raw.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                guard let literal = line.range(of: "\"[^\"\\n]*://[^\"\\n]*\"", options: .regularExpression) else { continue }
                if let comment = line.range(of: "(?<!:)//", options: .regularExpression), comment.lowerBound < literal.lowerBound { continue }
                XCTAssertTrue(stripped.contains(String(line[literal])), "\(path): the literal \(line[literal]) did not survive stripping")
            }
        }
    }

    func testTheCommentStripperHandlesEscapesAndMultilineStrings() {
        let code = "let a = \"x \\\" // still in the string\" // gone\n"
            + "let b = \"\"\"\n// inside a multiline string\n\"\"\" // gone too\n"
            + "let c = \"://\" // gone as well\n"
        let stripped = Self.stripComments(code)
        XCTAssertTrue(stripped.contains("// still in the string"), "an escaped quote does not end the string")
        XCTAssertTrue(stripped.contains("// inside a multiline string"), "a multiline string keeps its lines")
        XCTAssertTrue(stripped.contains("\"://\""), "a bare ://  literal stays")
        for gone in ["gone\n", "gone too", "gone as well"] {
            XCTAssertFalse(stripped.contains(gone), "'\(gone)' was a comment")
        }
        XCTAssertEqual(stripped.components(separatedBy: "\n").count, code.components(separatedBy: "\n").count, "line numbers are kept")
    }

    func testNothingDeclaresAViewTag() throws {
        for path in Self.tagSensitiveSources {
            let text = try Self.source(path)
            XCTAssertFalse(matches("\\b(var|let)\\s+tag\\s*:", in: text), "\(path) declares a `tag`, which collides with NSView.tag (#356)")
        }
    }

    func testThePlanViewerFetchesNothingAndRunsNothing() throws {
        let literal = ["NSImage(contentsOf:", "URLSession", "WKWebView", "Data(contentsOf: URL(string:",
                       "NSAppleScript", "posix_spawn"]
        let patterns = ["\\bProcess\\(", "\\bsystem\\("]
        for path in Self.planViewerSources + Self.jobDetailSources {
            let text = try Self.source(path)
            for needle in literal {
                XCTAssertFalse(text.contains(needle), "\(path) uses \(needle)")
            }
            for pattern in patterns {
                XCTAssertFalse(matches(pattern, in: text), "\(path) runs a program (\(pattern))")
            }
            XCTAssertFalse(text.contains("URL(string:") && text.contains("String(contentsOf:"),
                           "\(path) builds a URL from text and reads text from a URL: that is a fetch")
        }
    }

    func testTheOnlyThingTheViewOpensIsAWebLinkThroughTheOpenURLAction() throws {
        let view = try Self.source("UI/Mother/PlanDocumentView.swift")
        XCTAssertEqual(occurrences(of: "NSWorkspace.shared.open(", in: view), 1,
                       "exactly one place may open anything: the default `openURL` action")
        if let line = view.components(separatedBy: "\n").first(where: { $0.contains("NSWorkspace.shared.open(") }) {
            XCTAssertTrue(line.contains("openURL"), "that call is the default `openURL` closure, not something else: \(line)")
        }
        let loader = try Self.source("UI/Mother/PlanFileLoader.swift")
        XCTAssertEqual(occurrences(of: "NSWorkspace.shared.open(", in: loader), 0, "the loader opens nothing")
    }

    func testTheLoaderStatesItsExtensionsAndSizeCapExactlyOnce() throws {
        let loader = try Self.source("UI/Mother/PlanFileLoader.swift")
        for ext in ["md", "markdown", "mdown"] {
            XCTAssertEqual(occurrences(of: "\"\(ext)\"", in: loader), 1, "the extension \"\(ext)\" is listed once")
        }
        XCTAssertEqual(occurrences(of: "1_048_576", in: loader), 1, "the 1 MiB cap is one constant")
    }
}

// MARK: - MF3: the origin line, the From: filter and Show My Jobs
//
// A focus name, a job title, a name snapshot and a tag are agent- and shell-controlled text (and a focus
// name is something the user typed). The origin display and the filter must log nothing about them, hold
// no `tag` property that would collide with `NSView.tag` (#356), and "Show My Jobs" is a view action: it
// must not ask whether the click was a human gesture (that gate is for controls that answer an agent).

extension MotherFocusFitnessTests {

    /// Files that must hold no logging at all: pure presentation, nothing to say.
    private static let originPureSources = [
        "macOS/Nostromo/UI/Mother/MotherJobFilter.swift",
        "Shared/NostromoKit/Sources/NostromoKit/Mother/MotherOriginDisplay.swift",
    ]

    /// Files this slice changed that do log: no log line may interpolate a name, title, snapshot or tag.
    private static let originChangedSources = [
        "macOS/Nostromo/UI/Views/MotherView.swift",
        "macOS/Nostromo/UI/Views/MotherJobDetail.swift",
        "Shared/NostromoKit/Sources/NostromoKit/UI/MotherJobRow.swift",
    ]

    /// A path from the repository root (the Kit lives outside `macOS/Nostromo`).
    private static func repoSource(_ relativePath: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        var root = URL(fileURLWithPath: "\(file)")
        for _ in 0..<3 { root.deleteLastPathComponent() }   // NostromoTests, macOS, repo root
        let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        XCTAssertFalse(text.isEmpty, "\(relativePath) is empty", file: file, line: line)
        return stripComments(text)
    }

    /// The text from the first `start` to the first `end` after it (inclusive), or fails the test.
    private func block(from start: String, to end: String, in text: String, _ what: String,
                       file: StaticString = #filePath, line: UInt = #line) -> String {
        guard let s = text.range(of: start), let e = text.range(of: end, range: s.upperBound ..< text.endIndex) else {
            XCTFail("could not find \(what) in the source (looked for \(start))", file: file, line: line)
            return ""
        }
        return String(text[s.lowerBound ..< e.upperBound])
    }

    /// Each `log.<level>(...)` / `Logger` call as a whole statement.
    private func logStatements(in text: String) throws -> [String] {
        let statement = try NSRegularExpression(
            pattern: "\\b(?:log|layoutLog)\\.(debug|info|notice|error|warning|fault|log|trace)\\((?:[^()]|\\((?:[^()]|\\([^()]*\\))*\\))*\\)")
        let ns = text as NSString
        return statement.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    func testTheOriginDisplayAndTheFilterLogNothingAtAll() throws {
        for path in Self.originPureSources {
            let text = try Self.repoSource(path)
            for pattern in ["\\blog\\.", "\\blayoutLog\\.", "\\bLogger\\b", "\\bprint\\(", "\\bNSLog\\(", "\\bos_log\\(", "\\bdebugPrint\\("] {
                XCTAssertFalse(matches(pattern, in: text), "\(path) logs (\(pattern)): a focus name is not for logs")
            }
        }
    }

    func testNoLogLineInTheChangedFilesInterpolatesAFocusNameATitleASnapshotOrATag() throws {
        let namey = "(?i)\\\\\\([^)]*(name|title|snapshot|tag|label|origin|annotation|summary)"
        for path in Self.originChangedSources {
            let text = try Self.repoSource(path)
            for pattern in ["\\bprint\\(", "\\bNSLog\\(", "\\bos_log\\("] {
                XCTAssertFalse(matches(pattern, in: text), "\(path) logs (\(pattern))")
            }
            for call in try logStatements(in: text) {
                XCTAssertFalse(matches(namey, in: call), "\(path) logs a name, title, snapshot or tag: \(call)")
            }
        }
    }

    func testTheLogStatementScanActuallySeesInterpolatedNames() throws {
        // Guard the scan itself: it must flag the shapes it exists to forbid.
        let bad = [
            "log.debug(\"queued by \\(focus.displayName)\")",
            "log.info(\"origin \\(origin.text, privacy: .public)\")",
            "log.error(\"tag \\(tag)\")",
            "log.debug(\"job \\(job.title)\")",
        ]
        let namey = "(?i)\\\\\\([^)]*(name|title|snapshot|tag|label|origin|annotation|summary)"
        for source in bad {
            let calls = try logStatements(in: source)
            XCTAssertEqual(calls.count, 1, "the scan did not find the call in: \(source)")
            XCTAssertTrue(calls.allSatisfy { matches(namey, in: $0) }, "the scan did not flag: \(source)")
        }
        let fine = try logStatements(in: "log.debug(\"live jobs: \\(jobs.count, privacy: .public)\")")
        XCTAssertEqual(fine.count, 1)
        XCTAssertFalse(matches(namey, in: fine[0]), "a count is fine to log")
    }

    func testTheOriginDisplayHoldsAFocusTagAndNoPropertyNamedTag() throws {
        let display = try Self.repoSource("Shared/NostromoKit/Sources/NostromoKit/Mother/MotherOriginDisplay.swift")
        XCTAssertFalse(matches("\\b(var|let)\\s+tag\\s*:", in: display),
                       "MotherOriginDisplay declares a `tag`, which collides with NSView.tag (#356): it holds `focusTag`")
        XCTAssertTrue(matches("\\b(var|let)\\s+focusTag\\s*:", in: display), "MotherOriginDisplay holds `focusTag`")

        for path in ["UI/Mother/MotherJobFilter.swift", "UI/Views/MotherJobDetail.swift"] {
            let text = try Self.source(path)
            XCTAssertFalse(matches("\\b(var|let)\\s+tag\\s*:", in: text), "\(path) declares a `tag` (#356)")
        }
        let originLine = block(from: "final class MotherOriginLine", to: "\n}\n",
                               in: try Self.source("UI/Views/MotherJobDetail.swift"), "MotherOriginLine")
        XCTAssertFalse(originLine.isEmpty)
        XCTAssertFalse(matches("\\b(var|let)\\s+tag\\b", in: originLine), "MotherOriginLine declares a `tag`")
    }

    func testTheOriginLineLogsNothingAndOpensNothingItself() throws {
        let originLine = block(from: "final class MotherOriginLine", to: "\n}\n",
                               in: try Self.source("UI/Views/MotherJobDetail.swift"), "MotherOriginLine")
        XCTAssertFalse(originLine.isEmpty)
        for pattern in ["\\blog\\.", "\\bprint\\(", "\\bNSLog\\(", "\\bos_log\\(", "\\bLogger\\b"] {
            XCTAssertFalse(matches(pattern, in: originLine), "MotherOriginLine logs (\(pattern))")
        }
        XCTAssertEqual(occurrences(of: "NSWorkspace.shared.open(", in: originLine), 0, "the line reports a tap; the host acts on it")
    }

    func testShowMyJobsIsAViewActionAndAsksNothingOfTheGestureGate() throws {
        let gate = ["SyntheticInputGate", "isSynthetic", "allowsSynthetic", "TerminalInputGuard"]

        let tabBar = try Self.source("UI/TabBarView.swift")
        let layout = try Self.source("UI/MainLayout.swift")
        let handler = block(from: "@objc private func showJobsTapped", to: "\n    }\n", in: tabBar, "showJobsTapped")
        let action = block(from: "private func showJobs(of focus: Focus)", to: "\n    }\n", in: layout, "MainLayout.showJobs")
        XCTAssertTrue(handler.contains("onShowJobs"), "the menu item reports through onShowJobs")
        XCTAssertTrue(action.contains("requestShowJobs"), "showJobs sets the filter request")

        for (what, text) in [("TabBarView", tabBar), ("MainLayout", layout), ("showJobsTapped", handler), ("showJobs", action)] {
            for needle in gate {
                XCTAssertFalse(text.contains(needle), "\(what) references \(needle): Show My Jobs is a view action, not gesture-gated")
            }
        }
        for text in [handler, action] {
            for pattern in ["\\blog\\.", "\\blayoutLog\\.", "\\bprint\\(", "\\bNSLog\\("] {
                XCTAssertFalse(matches(pattern, in: text), "Show My Jobs logs (\(pattern)): it handles a focus tag")
            }
        }
    }

    func testTheMotherViewsOriginPartsAskNothingOfTheGestureGateEither() throws {
        let view = try Self.source("UI/Views/MotherView.swift")
        let filter = try Self.source("UI/Mother/MotherJobFilter.swift")
        for needle in ["SyntheticInputGate", "isSynthetic", "allowsSynthetic"] {
            XCTAssertFalse(view.contains(needle), "MotherView references \(needle): jumping to a focus is a view action")
            XCTAssertFalse(filter.contains(needle), "MotherJobFilter references \(needle)")
        }
        let originLine = block(from: "final class MotherOriginLine", to: "\n}\n",
                               in: try Self.source("UI/Views/MotherJobDetail.swift"), "MotherOriginLine")
        for needle in ["SyntheticInputGate", "isSynthetic", "allowsSynthetic"] {
            XCTAssertFalse(originLine.contains(needle), "MotherOriginLine references \(needle)")
        }
    }
}

// MARK: - MF5: the condensed row and the resizable list column
//
// Line two carries an origin, a repo, a failure reason and a question: all agent- or shell-controlled
// text. The new files hold no logging at all (they are presentation), and none declares a `tag` that
// would collide with NSView.tag (#356).

extension MotherFocusFitnessTests {

    private static let rowAndDividerSources = [
        "macOS/Nostromo/UI/Mother/MotherListDivider.swift",
        "Shared/NostromoKit/Sources/NostromoKit/Mother/MotherRowLineTwo.swift",
        "Shared/NostromoKit/Sources/NostromoKit/UI/CondensedMotherJobRowContent.swift",
    ]

    func testTheCondensedRowAndTheDividerLogNothingAtAll() throws {
        for path in Self.rowAndDividerSources {
            let text = try Self.repoSource(path)
            for pattern in ["\\blog\\.", "\\blayoutLog\\.", "\\bLogger\\b", "\\bprint\\(", "\\bNSLog\\(", "\\bos_log\\(", "\\bdebugPrint\\("] {
                XCTAssertFalse(matches(pattern, in: text), "\(path) logs (\(pattern)): a row's text is not for logs")
            }
        }
    }

    func testTheCondensedRowAndTheDividerDeclareNoViewTag() throws {
        for path in Self.rowAndDividerSources {
            let text = try Self.repoSource(path)
            XCTAssertFalse(matches("\\b(var|let)\\s+tag\\b", in: text),
                           "\(path) declares a `tag`, which collides with NSView.tag (#356)")
        }
    }

    func testTheCondensedRowAndTheDividerFetchNothingAndRunNothing() throws {
        for path in Self.rowAndDividerSources {
            let text = try Self.repoSource(path)
            for needle in ["URLSession", "NSWorkspace.shared.open(", "NSAppleScript", "posix_spawn"] {
                XCTAssertFalse(text.contains(needle), "\(path) uses \(needle)")
            }
            XCTAssertFalse(matches("\\bProcess\\(", in: text), "\(path) runs a program")
        }
    }
}
