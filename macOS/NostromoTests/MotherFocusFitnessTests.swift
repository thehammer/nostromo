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

    /// Files that must never declare an `NSView.tag` of their own (#356).
    private static let tagSensitiveSources = planViewerSources + ["UI/Views/MotherJobDetail.swift"]

    private static func source(_ relativePath: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        var root = URL(fileURLWithPath: "\(file)")
        for _ in 0..<3 { root.deleteLastPathComponent() }   // NostromoTests, macOS, repo root
        let url = root.appendingPathComponent("macOS/Nostromo").appendingPathComponent(relativePath)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.isEmpty, "\(relativePath) is empty", file: file, line: line)
        return stripComments(text)
    }

    /// Block comments, then `//` comments (not the `//` of a URL's `://`).
    private static func stripComments(_ text: String) -> String {
        text.replacingOccurrences(of: "/\\*[\\s\\S]*?\\*/", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(?<!:)//[^\\n]*", with: "", options: .regularExpression)
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
        for path in Self.planViewerSources {
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
