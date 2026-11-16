// NostromoKit — TrackerTitleRealBoardTests.swift
//
// Opt-in, read-only check of the title rule against a real board file. Skipped unless
// NOSTROMO_TRACKER_REAL_BOARD names the file:
//
//   NOSTROMO_TRACKER_REAL_BOARD=/path/to/index.md swift test --package-path Shared/NostromoKit \
//       --filter TrackerTitleRealBoardTests
//
// The file is opened for reading only and never written. This repo is public and a real board is
// not, so the test prints COUNTS and nothing else: no item text, and no assertion message that
// carries any (messages name the item by its index among the board's task lines, and the
// invariant checks report only the name of the invariant that broke).

import XCTest
@testable import NostromoKit

final class TrackerTitleRealBoardTests: XCTestCase {

    private static let envKey = "NOSTROMO_TRACKER_REAL_BOARD"

    /// A task line is `- [ ] <text> — <status · owner · hh:mm> <!-- #id ts -->`. The item's text is
    /// what comes BEFORE the final ` — ` tail (mirrors `parse_tail` in `src/tracker/format.rs`: the
    /// last ` — `, and only when a status word is among the tail's ` · ` tokens; otherwise the
    /// whole body is the text). Nil for a line that is not a task line.
    static func itemText(ofTaskLine line: String) throws -> String? {
        let taskLine = try NSRegularExpression(pattern: #"^- \[[ xX]\] "#)
        let marker = try NSRegularExpression(pattern: #"\s*<!--\s*#.*?-->\s*$"#)
        let whole = NSRange(line.startIndex..., in: line)
        guard let prefix = taskLine.firstMatch(in: line, range: whole) else { return nil }
        var body = String(line[Range(prefix.range, in: line)!.upperBound...])
        let rest = NSRange(body.startIndex..., in: body)
        if let found = marker.firstMatch(in: body, range: rest) {
            body = String(body[..<Range(found.range, in: body)!.lowerBound])
        }
        let statuses: Set<String> = ["todo", "in-progress", "blocked", "needs-you", "done"]
        if let dash = body.range(of: " — ", options: .backwards) {
            let tokens = body[dash.upperBound...].components(separatedBy: " · ").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if tokens.contains(where: { statuses.contains($0) }) {
                return String(body[..<dash.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
        }
        return body.trimmingCharacters(in: .whitespaces)
    }

    /// Synthetic lines (always runs): the text is the part before the status tail, not after it.
    func testTheItemTextIsWhatPrecedesTheStatusTailNotTheTail() throws {
        XCTAssertEqual(try Self.itemText(ofTaskLine: "- [ ] Fix the retry test — in-progress · agent-1 · 10:42 <!-- #fix-1 1760540000 -->"),
                       "Fix the retry test")
        XCTAssertEqual(try Self.itemText(ofTaskLine: "- [x] Ship it — then tag — done <!-- #ship-1 1760540000 -->"),
                       "Ship it — then tag")
        XCTAssertEqual(try Self.itemText(ofTaskLine: "- [ ] A text — with a dash but no status <!-- #a-1 1760540000 -->"),
                       "A text — with a dash but no status")
        XCTAssertEqual(try Self.itemText(ofTaskLine: "- [ ] No tail at all"), "No tail at all")
        XCTAssertNil(try Self.itemText(ofTaskLine: "## A section"))
    }

    func testEveryTaskLineOfARealBoardSplitsIntoASaneTitle() throws {
        guard let path = ProcessInfo.processInfo.environment[Self.envKey], !path.isEmpty else {
            throw XCTSkip("\(Self.envKey) is not set")
        }
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return XCTFail("the board named by \(Self.envKey) cannot be opened for reading")
        }
        defer { try? handle.close() }
        let data = try XCTUnwrap(try handle.readToEnd(), "the board is empty")
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")

        var texts: [String] = []
        for line in lines {
            if let text = try Self.itemText(ofTaskLine: line) { texts.append(text) }
        }

        var whole = 0, separator = 0, cut = 0
        var splits: [TrackerTitleSplit] = []
        for (index, text) in texts.enumerated() {
            let split = TrackerTitle.split(text)
            splits.append(split)
            switch split.rule {
            case .whole: whole += 1
            case .separator: separator += 1
            case .cut: cut += 1
            }
            let broken = TrackerTitleInvariants.violations(of: text, split)
            XCTAssertTrue(broken.isEmpty, "task line \(index) breaks: \(broken.joined(separator: ", "))")
        }

        // The failure this guards against: reading the status tail (`in-progress · owner · 10:42`) as the
        // item text. A tail is never an item's text; count them (a number, never the text).
        let tailShaped = try NSRegularExpression(pattern: #"^(todo|in-progress|blocked|needs-you|done)( · .*)?$"#)
        let tails = texts.filter { tailShaped.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }.count
        XCTAssertEqual(tails, 0, "\(tails) item texts look like a status tail: the text was taken from the wrong side of ' — '")

        XCTAssertEqual(splits.count, texts.count, "one split per task line")
        XCTAssertEqual(whole + separator + cut, texts.count, "every task line took exactly one branch")
        print("TrackerTitleRealBoard counts: items=\(texts.count) whole=\(whole) separator=\(separator) cut=\(cut)")
    }
}
