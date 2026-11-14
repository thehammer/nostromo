// NostromoKit — TrackerTitleTests.swift
//
// The display rule that turns an item's text into a one-line title and what goes under the fold
// (`TrackerTitle.split`). Every branch of the rule, its boundaries (80 and 81 characters, offsets
// 2, 3, 79, 80 and 81), bracket handling, and counting in Characters rather than bytes.
//
// All strings here are synthetic: they have the shape of a real board (name, progress bar, double
// space, then a detail list) without being copied from one. Expected titles and rests are built
// from the same pieces as the input, so a case reads as "this text splits into these two parts".

import XCTest
@testable import NostromoKit

// MARK: - Invariants (shared with TrackerTitleRealBoardTests)

/// What must hold for every split, whatever the text. Reports the NAMES of broken invariants and
/// never the text, so the opt-in real-board test can use it without leaking an item into output.
enum TrackerTitleInvariants {

    static func violations(of text: String, _ split: TrackerTitleSplit) -> [String] {
        var broken: [String] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = split.title

        if title.isEmpty && !trimmed.isEmpty { broken.append("title is empty") }
        if title.contains(where: \.isNewline) { broken.append("title spans more than one line") }
        if title.count > TrackerTitle.maxChars + 1 { broken.append("title longer than the limit plus the ellipsis") }
        if title != title.trimmingCharacters(in: .whitespacesAndNewlines) { broken.append("title is not trimmed") }
        if let rest = split.rest, rest != rest.trimmingCharacters(in: .whitespacesAndNewlines) {
            broken.append("rest is not trimmed")
        }
        if split.rest?.isEmpty == true { broken.append("rest is empty instead of nil") }

        switch split.rule {
        case .whole:
            if trimmed.count > TrackerTitle.maxChars { broken.append("whole, but longer than the limit") }
            if title != trimmed { broken.append("whole, but title differs from the text") }
            if split.rest != nil { broken.append("whole, but has a rest") }

        case .separator:
            if trimmed.count <= TrackerTitle.maxChars { broken.append("split a text that fits") }
            let squashed = squash(trimmed)
            let rebuilt = squash(title)
            let tail = squash(split.rest ?? "")
            let joined = ["", ":", ";", "\u{2014}", "."].contains { squashed == rebuilt + $0 + tail }
            if !joined { broken.append("separator split loses or invents text") }

        case .cut:
            if trimmed.count <= TrackerTitle.maxChars { broken.append("cut a text that fits") }
            guard title.hasSuffix("…") else { broken.append("cut title lacks its ellipsis"); break }
            guard let rest = split.rest, rest.hasPrefix("…") else {
                broken.append("cut rest lacks its ellipsis")
                break
            }
            let head = squash(String(title.dropLast()))
            let tail = squash(String(rest.dropFirst()))
            if squash(trimmed) != head + tail { broken.append("cut loses or invents text") }
        }
        return broken
    }

    private static func squash(_ s: String) -> String {
        s.filter { !$0.isWhitespace }
    }
}

// MARK: - Building blocks

private enum TitleFx {
    /// `n` nine-letter words separated by single spaces: 10n - 1 characters, a space at offsets
    /// 9, 19, 29 and so on.
    static func run(_ n: Int) -> String {
        Array(repeating: "abcdefghi", count: n).joined(separator: " ")
    }

    static func rep(_ s: String, _ n: Int) -> String {
        String(repeating: s, count: n)
    }

    static let bar = "■■■□□"
    static let widgetDetails = (1...10).map { "W\($0) #\(9 + $0)" }.joined(separator: ", ")

    static let emoji = "😀"
    /// One Character made of two scalars (a letter and a combining accent).
    static let accented = "e\u{301}"
    /// One Character made of seven scalars (four people joined by zero-width joiners).
    static let family = "👨‍👩‍👧‍👦"
}

private struct Case {
    let name: String
    let text: String
    let rule: TrackerTitleRule
    let title: String
    let rest: String?
    let line: UInt

    init(_ name: String, _ text: String, _ rule: TrackerTitleRule, title: String, rest: String? = nil,
         line: UInt = #line) {
        self.name = name
        self.text = text
        self.rule = rule
        self.title = title
        self.rest = rest
        self.line = line
    }
}

// MARK: - Tests

final class TrackerTitleTests: XCTestCase {

    private func check(_ cases: [Case], file: StaticString = #filePath) {
        for c in cases {
            let split = TrackerTitle.split(c.text)
            XCTAssertEqual(split.rule, c.rule, "\(c.name): which rule applied", file: file, line: c.line)
            XCTAssertEqual(split.title, c.title, "\(c.name): title", file: file, line: c.line)
            XCTAssertEqual(split.rest, c.rest, "\(c.name): rest", file: file, line: c.line)
            XCTAssertEqual(TrackerTitleInvariants.violations(of: c.text, split), [], c.name,
                           file: file, line: c.line)
            // The table itself is honest about which side of the limit each case sits on.
            let fits = c.text.trimmingCharacters(in: .whitespacesAndNewlines).count <= TrackerTitle.maxChars
            XCTAssertEqual(fits, c.rule == .whole, "\(c.name): the case is on the wrong side of the limit",
                           file: file, line: c.line)
        }
    }

    func testTheLimitIsEightyCharacters() {
        XCTAssertEqual(TrackerTitle.maxChars, 80)
    }

    // MARK: Whole

    func testATextThatFitsIsItsOwnTitleWithNothingUnderTheFold() {
        let eighty = "Label: " + TitleFx.rep("x", 73)
        let barAtEighty = "Widget pane \(TitleFx.bar)  " + TitleFx.rep("y", 80 - 19)
        check([
            Case("a short text", "Fix the flaky retry test", .whole, title: "Fix the flaky retry test"),
            Case("80 characters with a colon", eighty, .whole, title: eighty),
            Case("80 characters with a double space", barAtEighty, .whole, title: barAtEighty),
            Case("80 characters with a period and a dash", "One. Two — " + TitleFx.rep("z", 69), .whole,
                 title: "One. Two — " + TitleFx.rep("z", 69)),
            Case("surrounding whitespace is trimmed", "   Fix the flaky retry test \n", .whole,
                 title: "Fix the flaky retry test"),
            Case("padding past 80 does not count once trimmed", TitleFx.rep("a", 75) + TitleFx.rep(" ", 10), .whole,
                 title: TitleFx.rep("a", 75)),
        ])
    }

    // MARK: Separator

    func testALongTextSplitsAtTheFirstSeparatorOutsideBrackets() {
        let details = TitleFx.widgetDetails
        check([
            Case("a name, a progress bar and a double space",
                 "Widget pane \(TitleFx.bar)  \(details)", .separator,
                 title: "Widget pane \(TitleFx.bar)", rest: details),
            Case("a label and a colon",
                 "Deploy pipeline: waiting on the vendor to confirm the window, then roll out to every region",
                 .separator, title: "Deploy pipeline",
                 rest: "waiting on the vendor to confirm the window, then roll out to every region"),
            Case("a semicolon",
                 "Rotate the signing keys; then verify every consumer picked up the new certificate bundle",
                 .separator, title: "Rotate the signing keys",
                 rest: "then verify every consumer picked up the new certificate bundle"),
            Case("a spaced em dash",
                 "Ship the release notes — then tag the build and announce it to the whole team in the channel",
                 .separator, title: "Ship the release notes",
                 rest: "then tag the build and announce it to the whole team in the channel"),
            Case("a sentence end",
                 "Rebuild the index. Then compare the counts against the previous run and report the delta here",
                 .separator, title: "Rebuild the index",
                 rest: "Then compare the counts against the previous run and report the delta here"),
        ])
    }

    func testTheEarliestSeparatorWinsWhateverItsKind() {
        let tail = "and then a good deal more text so the whole thing runs well past the eighty character limit"
        check([
            Case("a semicolon before a colon, a period and a dash",
                 "Alpha; beta: gamma. delta — \(tail)", .separator,
                 title: "Alpha", rest: "beta: gamma. delta — \(tail)"),
            Case("a colon before a semicolon",
                 "Alpha: beta; gamma \(tail)", .separator, title: "Alpha", rest: "beta; gamma \(tail)"),
        ])
    }

    func testSeparatorsInsideBracketsAreIgnoredAndTheOneAfterTheyCloseIsUsed() {
        let tail = "the rest of the story runs on well past the eighty character limit of a title"
        check([
            Case("a closed parenthesis, then a colon",
                 "Merged (#12, Perri: fine; CI green): \(tail)", .separator,
                 title: "Merged (#12, Perri: fine; CI green)", rest: tail),
            Case("square and curly brackets, then a double space",
                 "Thing [#12: ok; fine] {a: b; c}  \(tail)", .separator,
                 title: "Thing [#12: ok; fine] {a: b; c}", rest: tail),
            Case("brackets are counted by depth, whatever their kind",
                 "Thing (a [b: c) d: e]: \(tail)", .separator,
                 title: "Thing (a [b: c) d: e]", rest: tail),
            Case("a closing bracket with nothing open does not go below zero",
                 "Fix) the thing: \(tail)", .separator, title: "Fix) the thing", rest: tail),
        ])
    }

    func testASeparatorBelowTheThirdCharacterIsIgnoredAndTheThirdIsUsed() {
        check([
            Case("a colon at offset 2 is not a split",
                 "Ab: " + TitleFx.run(9), .cut,
                 title: "Ab: " + TitleFx.run(7) + "…", rest: "…" + TitleFx.run(2)),
            Case("a colon at offset 3 splits",
                 "Abc: " + TitleFx.rep("x", 80), .separator, title: "Abc", rest: TitleFx.rep("x", 80)),
        ])
    }

    func testASeparatorAtOffsetEightyIsUsedAndAtEightyOneIsNot() {
        let eighty = TitleFx.run(7) + " " + "abcdefghij"
        let eightyOne = TitleFx.run(7) + " " + "abcdefghijk"
        XCTAssertEqual(eighty.count, 80)
        XCTAssertEqual(eightyOne.count, 81)
        check([
            Case("a colon right after 80 characters", eighty + ": the tail of the line", .separator,
                 title: eighty, rest: "the tail of the line"),
            Case("a colon right after 81 characters", eightyOne + ": tail", .cut,
                 title: TitleFx.run(7) + "…", rest: "…abcdefghijk: tail"),
        ])
    }

    // MARK: Cut

    func testWithoutAUsableSeparatorTheTextIsCutAtAWordWithAnEllipsisOnBothSides() {
        check([
            Case("a separator only inside parentheses",
                 "Gizmo merged (#12, Perri: fine, CI green, docs updated, follow-up filed for the flaky retry test)",
                 .cut,
                 title: "Gizmo merged (#12, Perri: fine, CI green, docs updated, follow-up filed for the…",
                 rest: "…flaky retry test)"),
            Case("the first separator is past the first 80 characters",
                 TitleFx.run(9) + ". tail", .cut,
                 title: TitleFx.run(8) + "…", rest: "…abcdefghi. tail"),
            Case("81 characters, a space as the 80th",
                 TitleFx.run(8) + " x", .cut, title: TitleFx.run(8) + "…", rest: "…x"),
            Case("no word break before offset 3 counts",
                 "ab " + TitleFx.rep("x", 100), .cut,
                 title: "ab " + TitleFx.rep("x", 76) + "…", rest: "…" + TitleFx.rep("x", 24)),
        ])
    }

    func testATextWithNoSpacesAtAllIsCutAtCharacter79() {
        check([
            Case("500 characters", TitleFx.rep("x", 500), .cut,
                 title: TitleFx.rep("x", 79) + "…", rest: "…" + TitleFx.rep("x", 421)),
            Case("81 characters", TitleFx.rep("x", 81), .cut,
                 title: TitleFx.rep("x", 79) + "…", rest: "…xx"),
        ])
    }

    // MARK: Characters, not bytes

    func testLengthAndOffsetsAreCountedInCharactersNotScalarsOrBytes() {
        let emoji = TitleFx.emoji, accented = TitleFx.accented, family = TitleFx.family
        check([
            Case("80 emoji fit", TitleFx.rep(emoji, 80), .whole, title: TitleFx.rep(emoji, 80)),
            Case("80 letters with combining accents fit", TitleFx.rep(accented, 80), .whole,
                 title: TitleFx.rep(accented, 80)),
            Case("80 family emoji fit", TitleFx.rep(family, 80), .whole, title: TitleFx.rep(family, 80)),
            Case("81 emoji are cut at the 79th", TitleFx.rep(emoji, 81), .cut,
                 title: TitleFx.rep(emoji, 79) + "…", rest: "…" + TitleFx.rep(emoji, 2)),
            Case("81 accented letters are cut at the 79th", TitleFx.rep(accented, 81), .cut,
                 title: TitleFx.rep(accented, 79) + "…", rest: "…" + TitleFx.rep(accented, 2)),
            Case("81 family emoji are cut at the 79th", TitleFx.rep(family, 81), .cut,
                 title: TitleFx.rep(family, 79) + "…", rest: "…" + TitleFx.rep(family, 2)),
            Case("a colon after 79 emoji is at offset 79 and splits",
                 TitleFx.rep(emoji, 79) + ": the tail of the line goes on", .separator,
                 title: TitleFx.rep(emoji, 79), rest: "the tail of the line goes on"),
            Case("a colon after 40 accented letters splits there",
                 TitleFx.rep(accented, 40) + ": " + TitleFx.rep("x", 60), .separator,
                 title: TitleFx.rep(accented, 40), rest: TitleFx.rep("x", 60)),
        ])
    }

    // MARK: Whatever the text

    func testEveryLengthKeepsTheInvariantsAndOnlyTextsOverTheLimitAreSplit() {
        for n in 1...300 {
            for (shape, text) in [("unbroken", TitleFx.rep("x", n)),
                                  ("words", String(TitleFx.run(40).prefix(n))),
                                  ("emoji", TitleFx.rep(TitleFx.emoji, n))] {
                let split = TrackerTitle.split(text)
                XCTAssertEqual(TrackerTitleInvariants.violations(of: text, split), [], "\(shape) of \(n)")
                let fits = text.trimmingCharacters(in: .whitespacesAndNewlines).count <= TrackerTitle.maxChars
                XCTAssertEqual(split.rule == .whole, fits, "\(shape) of \(n)")
            }
        }
    }
}
