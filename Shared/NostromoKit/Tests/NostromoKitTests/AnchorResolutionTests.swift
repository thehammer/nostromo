import XCTest
@testable import NostromoKit

// L1 coverage for `CodeDocument.resolve(anchor:)` / `resolve(emphasis:)` and
// the three-state `AnchorResolution`/`EmphasisResolution` types
// (ios-curated-view-parity W7, D2/memo B12). This is the PRD's honesty rule
// as tests: a silent fallback must be unrepresentable, not merely avoided.

final class AnchorResolutionTests: XCTestCase {

    private func doc(firstLine: Int = 1, lines: Int = 20, path: String = "a.swift") -> CodeDocument {
        let text = (0..<lines).map { "line \($0)" }.joined(separator: "\n")
        return CodeDocument(path: path, revision: "working", firstLine: firstLine, text: text)
    }

    // MARK: Anchor — absent

    func testNoAnchorIsNotRequestedNotUnresolvedNotResolved() {
        let resolution = doc().resolve(anchor: nil)
        XCTAssertEqual(resolution, .notRequested)
        XCTAssertNotEqual(resolution, .unresolved(reason: ""))
        XCTAssertNotEqual(resolution, .resolved(target: 0))
    }

    // MARK: Anchor — a line within the document

    func testLineWithinTheDocumentResolvesToItsRowGivenFirstLine() {
        let document = doc(firstLine: 100, lines: 5) // lines 100...104
        XCTAssertEqual(document.resolve(anchor: .line(path: nil, line: 102)), .resolved(target: 2))
        XCTAssertEqual(document.resolve(anchor: .line(path: nil, line: 100)), .resolved(target: 0))
    }

    // MARK: Anchor — a line outside the document

    func testLinePastTheEndIsUnresolvedNamingTheRequestedLineAndTheDocumentsActualRange() {
        let document = doc(firstLine: 1, lines: 10) // lines 1...10
        guard case .unresolved(let reason) = document.resolve(anchor: .line(path: nil, line: 9000)) else {
            return XCTFail("expected .unresolved")
        }
        XCTAssertTrue(reason.contains("9000"), "reason must name the requested line: \(reason)")
        XCTAssertTrue(reason.contains("10"), "reason must name the document's actual size: \(reason)")
    }

    func testLineBeforeFirstLineIsUnresolved() {
        let document = doc(firstLine: 100, lines: 10) // lines 100...109
        guard case .unresolved(let reason) = document.resolve(anchor: .line(path: nil, line: 50)) else {
            return XCTFail("expected .unresolved")
        }
        XCTAssertTrue(reason.contains("50"))
    }

    func testLineZeroIsUnresolved() {
        let document = doc(firstLine: 1, lines: 10)
        guard case .unresolved(let reason) = document.resolve(anchor: .line(path: nil, line: 0)) else {
            return XCTFail("expected .unresolved")
        }
        XCTAssertTrue(reason.contains("0"))
    }

    // MARK: Anchor — a line for a different path

    func testLineAnchorForADifferentPathIsUnresolvedNamingTheMismatch() {
        let document = doc(path: "a.swift")
        guard case .unresolved(let reason) = document.resolve(anchor: .line(path: "b.swift", line: 5)) else {
            return XCTFail("expected .unresolved")
        }
        XCTAssertTrue(reason.contains("b.swift"), "reason must name the requested path: \(reason)")
        XCTAssertTrue(reason.contains("a.swift"), "reason must name this document's own path: \(reason)")
    }

    // MARK: Anchor — a kind this surface cannot use

    func testCommentAnchorIsUnresolvedNamingTheKind() {
        guard case .unresolved(let reason) = doc().resolve(anchor: .comment(id: "abc")) else {
            return XCTFail("expected .unresolved")
        }
        // macOS's TicketContentView/CodeContentView (`resolveRows`) silently
        // drops any non-`.line`/`.section` anchor: no scroll, no signal at
        // all. This surface must say so instead.
        XCTAssertTrue(reason.lowercased().contains("comment"), "reason must name the anchor kind: \(reason)")
    }

    func testSectionAnchorIsUnresolvedNamingTheKind() {
        guard case .unresolved(let reason) = doc().resolve(anchor: .section(name: "Intro")) else {
            return XCTFail("expected .unresolved")
        }
        XCTAssertTrue(reason.lowercased().contains("section"), "reason must name the anchor kind: \(reason)")
    }

    func testQueueRowAnchorIsUnresolvedNamingTheKind() {
        guard case .unresolved(let reason) = doc().resolve(anchor: .queueRow(repo: "acme/web", number: 1)) else {
            return XCTFail("expected .unresolved")
        }
        XCTAssertTrue(reason.lowercased().contains("queue"), "reason must name the anchor kind: \(reason)")
    }

    // MARK: Emphasis — absent

    func testNoEmphasisIsNone() {
        XCTAssertEqual(doc().resolve(emphasis: []), .none)
    }

    // MARK: Emphasis — fully in range

    func testFullyInRangeLineRangeResolvesToEveryRowInTheInclusiveRange() {
        let document = doc(firstLine: 1, lines: 20)
        let resolution = document.resolve(emphasis: [.lineRange(path: nil, start: 5, end: 8)])
        XCTAssertEqual(resolution, .rows([4, 5, 6, 7]))
    }

    // MARK: Emphasis — partially in range

    func testPartiallyInRangeLineRangeResolvesToTheIntersectingRowsOnly() {
        let document = doc(firstLine: 1, lines: 10) // lines 1...10
        let resolution = document.resolve(emphasis: [.lineRange(path: nil, start: 8, end: 15)])
        XCTAssertEqual(resolution, .rows([7, 8, 9]), "only rows for lines 8...10 exist in this document")
    }

    // MARK: Emphasis — fully out of range

    func testFullyOutOfRangeLineRangeIsMatchedNothingWithAReasonNotAClampedSpan() {
        let document = doc(firstLine: 1, lines: 10)
        let resolution = document.resolve(emphasis: [.lineRange(path: nil, start: 90000, end: 90010)])
        guard case .matchedNothing(let reason) = resolution else {
            return XCTFail("expected .matchedNothing, got \(resolution)")
        }
        XCTAssertTrue(reason.contains("90000") || reason.contains("90010"))
        // Must never be reported as "the whole document is emphasised."
        XCTAssertNotEqual(resolution, .rows(Array(0..<10)))
    }

    // MARK: Emphasis — inverted range

    func testInvertedRangeIsMatchedNothing() {
        let document = doc(firstLine: 1, lines: 10)
        guard case .matchedNothing = document.resolve(emphasis: [.lineRange(path: nil, start: 8, end: 3)]) else {
            return XCTFail("expected .matchedNothing for an inverted range")
        }
    }

    // MARK: Emphasis — union across multiple entries

    func testMultipleEmphasisEntriesUnionWithoutDuplicatingRows() {
        let document = doc(firstLine: 1, lines: 20)
        let resolution = document.resolve(emphasis: [
            .lineRange(path: nil, start: 1, end: 3),
            .lineRange(path: nil, start: 2, end: 5),
        ])
        XCTAssertEqual(resolution, .rows([0, 1, 2, 3, 4]))
    }
}
