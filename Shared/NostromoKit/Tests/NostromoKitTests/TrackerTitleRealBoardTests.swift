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

        let taskLine = try NSRegularExpression(pattern: #"^- \[[ xX]\] "#)
        let marker = try NSRegularExpression(pattern: #"\s*<!--\s*#.*?-->\s*$"#)

        var texts: [String] = []
        for line in lines {
            let whole = NSRange(line.startIndex..., in: line)
            guard let prefix = taskLine.firstMatch(in: line, range: whole) else { continue }
            var text = String(line[Range(prefix.range, in: line)!.upperBound...])
            let rest = NSRange(text.startIndex..., in: text)
            if let found = marker.firstMatch(in: text, range: rest) {
                text = String(text[..<Range(found.range, in: text)!.lowerBound])
            }
            if let dash = text.range(of: " — ", options: .backwards) {
                text = String(text[dash.upperBound...])
            }
            texts.append(text)
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

        XCTAssertEqual(splits.count, texts.count, "one split per task line")
        XCTAssertEqual(whole + separator + cut, texts.count, "every task line took exactly one branch")
        print("TrackerTitleRealBoard counts: items=\(texts.count) whole=\(whole) separator=\(separator) cut=\(cut)")
    }
}
