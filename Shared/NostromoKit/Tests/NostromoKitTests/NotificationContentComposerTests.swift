// NotificationContentComposerTests.swift
//
// What the notification shows once the extension has (or has not) fetched a detail line (W16).
//
//   - with a detail line, the line becomes the body and the original body moves to the subtitle; a
//     decision's body ends " · answer on your Mac"; the title never changes;
//   - in every other case the contract content comes back EXACTLY: no detail, an item that no longer
//     waits, a withheld or blank text, an answer for another item, a replacement, a Summary;
//   - the text is what a repository's people wrote, so it is flattened to one printable line of at
//     most 140 characters;
//   - and no input, however odd, makes the notification say anything but the contract or the
//     supplied text: never a placeholder, an error, or an ellipsis of our own (W16-4, W16-11, W16-12).

import XCTest
@testable import NostromoKit

final class NotificationContentComposerTests: XCTestCase {

    private let contract = NotificationContent(title: "Mother · sendai", body: "Job 3f9a1c2e asked a question")
    private let suffix = " · answer on your Mac"

    private func payload(_ kind: PushPayload.Kind = .mother, resolved: Bool = false) -> PushPayload {
        PushPayload(item: "item-1", kind: kind, host: "sendai", ref: nil, resolved: resolved)
    }

    private func detail(_ text: String?, waiting: Bool = true, itemRef: String = "item-1") -> PushDetailWire {
        PushDetailWire(itemRef: itemRef, waiting: waiting, text: text, host: "sendai")
    }

    private func compose(_ kind: PushPayload.Kind = .mother, resolved: Bool = false,
                         detail: PushDetailWire?) -> NotificationContent {
        NotificationContentComposer.compose(contract: contract, payload: payload(kind, resolved: resolved),
                                            detail: detail)
    }

    // MARK: - Enriched

    func testADetailLineBecomesTheBodyAndTheContractBodyBecomesTheSubtitle() {
        for kind in [PushPayload.Kind.mother, .review] {
            let out = compose(kind, detail: detail("Rename the helper before merging?"))
            XCTAssertEqual(out.title, "Mother · sendai", "\(kind): the title is unchanged")
            XCTAssertEqual(out.subtitle, "Job 3f9a1c2e asked a question", "\(kind)")
            XCTAssertEqual(out.body, "Rename the helper before merging?", "\(kind)")
        }
    }

    func testADecisionsBodyEndsAnswerOnYourMac() {
        let out = compose(.decision, detail: detail("Which database should the migration use?"))
        XCTAssertEqual(out.body, "Which database should the migration use? · answer on your Mac")
        XCTAssertEqual(out.subtitle, "Job 3f9a1c2e asked a question")
        XCTAssertEqual(out.title, "Mother · sendai")
    }

    // MARK: - The contract, exactly

    func testWithoutAUsableDetailTheContractComesBackUnchanged() {
        let cases: [(String, PushDetailWire?)] = [
            ("no detail", nil),
            ("the item no longer waits", detail("Still a good line", waiting: false)),
            ("the text is withheld", detail(nil)),
            ("the text is empty", detail("")),
            ("the text is whitespace only", detail("  \t ")),
            ("the text is newlines only", detail("\n\r\n\n")),
            ("the text is control characters only", detail("\u{0}\u{7}\u{1B}")),
            ("the answer is for another item", detail("A line for someone else", itemRef: "item-2")),
        ]
        for kind in [PushPayload.Kind.mother, .decision, .review] {
            for (label, answer) in cases {
                XCTAssertEqual(compose(kind, detail: answer), contract, "\(kind): \(label)")
            }
        }
    }

    func testAReplacementKeepsTheContractEvenWithAUsableDetail() {
        for kind in [PushPayload.Kind.mother, .decision, .review] {
            XCTAssertEqual(compose(kind, resolved: true, detail: detail("A usable line")), contract, "\(kind)")
        }
    }

    func testASummaryKeepsTheContractEvenWithAUsableDetail() {
        XCTAssertEqual(compose(.summary, detail: detail("A usable line")), contract)
    }

    func testAContractIsReturnedAsIsWhateverItsFieldsWhenThereIsNothingToAdd() {
        let odd = NotificationContent(title: "T", subtitle: "S", body: "")
        let out = NotificationContentComposer.compose(contract: odd, payload: payload(), detail: nil)
        XCTAssertEqual(out, odd)
    }

    // MARK: - One printable line, at most 140 characters

    func testNewlinesAndTabsFlattenToSingleSpaces() {
        XCTAssertEqual(compose(detail: detail("line one\nline two")).body, "line one line two")
        XCTAssertEqual(compose(detail: detail("a\r\nb")).body, "a b")
        XCTAssertEqual(compose(detail: detail("a\tb")).body, "a b")
        XCTAssertEqual(compose(detail: detail("\n\n  padded line \n")).body, "padded line")
    }

    func testControlCharactersNeverReachTheBody() {
        let out = compose(detail: detail("ab\u{0}cd\u{7}ef\u{1B}[31mgh\u{7F}ij"))
        let forbidden = CharacterSet.controlCharacters.union(.newlines)
        let offending = out.body.unicodeScalars.first(where: { forbidden.contains($0) })
        XCTAssertNil(offending, out.body)
        for piece in ["ab", "cd", "ef", "gh", "ij"] {
            XCTAssertTrue(out.body.contains(piece), "\(piece) is still there: \(out.body)")
        }
    }

    func testALongLineIsCutAtOneHundredAndFortyCharacters() {
        XCTAssertEqual(compose(detail: detail(String(repeating: "x", count: 300))).body.count, 140)
        XCTAssertEqual(compose(detail: detail(String(repeating: "x", count: 140))).body.count, 140)
        XCTAssertEqual(compose(detail: detail(String(repeating: "x", count: 139))).body.count, 139)
    }

    func testTheDecisionSuffixIsAddedAfterTheCap() {
        let out = compose(.decision, detail: detail(String(repeating: "x", count: 300)))
        XCTAssertEqual(out.body, String(repeating: "x", count: 140) + suffix)
    }

    // MARK: - Never anything of ours

    /// The words of `text`, split at whitespace, line breaks and control characters (category Cc).
    private func words(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for scalar in text.unicodeScalars {
            let isBreak = scalar.properties.generalCategory == .control
                || CharacterSet.whitespacesAndNewlines.contains(scalar)
            if isBreak {
                if !current.isEmpty { out.append(current) }
                current = ""
            } else {
                current.unicodeScalars.append(scalar)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// The body is the contract's, or (minus a decision's suffix) a trimmed prefix of the supplied
    /// text with its whitespace and control characters collapsed.
    private func assertNothingButContractOrSuppliedText(_ text: String, _ label: String, kind: PushPayload.Kind) {
        let out = compose(kind, detail: detail(text))
        if out == contract { return }

        XCTAssertEqual(out.title, contract.title, "\(label) \(kind): title")
        XCTAssertEqual(out.subtitle, contract.body, "\(label) \(kind): the contract body moved to the subtitle")
        var body = out.body
        if kind == .decision {
            XCTAssertTrue(body.hasSuffix(suffix), "\(label) \(kind): suffix")
            body = String(body.dropLast(suffix.count))
        } else {
            // Text a person wrote may itself end that way; only the composer adds the suffix, to decisions.
            if !text.hasSuffix(suffix) {
                XCTAssertFalse(body.hasSuffix(suffix), "\(label) \(kind): only a decision has a suffix")
            }
        }
        XCTAssertFalse(body.isEmpty, "\(label) \(kind): an empty body is never shown")
        XCTAssertLessThanOrEqual(body.count, 140, "\(label) \(kind)")
        XCTAssertEqual(body, body.trimmingCharacters(in: .whitespacesAndNewlines), "\(label) \(kind): trimmed")
        XCTAssertTrue(words(text).joined(separator: " ").hasPrefix(body),
                      "\(label) \(kind): the body is the supplied text and nothing else")
    }

    func testOddInputsGiveTheContractOrASuppliedPrefixAndNothingElse() {
        let table: [(String, String)] = [
            ("empty", ""),
            ("one space", " "),
            ("newlines only", "\n\r\n\n"),
            ("controls only", "\t\u{0}\u{7}\u{1B}"),
            ("leading whitespace", "   \n  hello there"),
            ("huge", String(repeating: "a", count: 10_000)),
            ("huge with spaces", String(repeating: "word ", count: 5_000)),
            ("emoji", "🚀🔥 shipped"),
            ("many emoji", String(repeating: "🚀🔥", count: 100)),
            ("right to left", "שלום עולם, האם לאשר?"),
            ("right to left with punctuation", "(שלום) - \"עולם\": 12:30"),
            ("combining marks", String(repeating: "e\u{301}", count: 300)),
            ("lone middle dot", "·"),
            ("looks like our own suffix", "Which one? · answer on your Mac"),
        ]
        for (label, text) in table {
            for kind in [PushPayload.Kind.mother, .decision, .review] {
                assertNothingButContractOrSuppliedText(text, label, kind: kind)
            }
        }
    }

    func testACutThatLandsOnASpaceDoesNotLeaveATrailingSpace() {
        // 139 characters, a space, then more: the 140-character cut ends on the space.
        let text = String(repeating: "a", count: 139) + " tail"
        for kind in [PushPayload.Kind.mother, .decision, .review] {
            assertNothingButContractOrSuppliedText(text, "cut on a space", kind: kind)
        }
        let decision = compose(.decision, detail: detail(text)).body
        XCTAssertFalse(decision.contains("  "), "no doubled space before the suffix: \(decision)")
    }

    func testCharactersThatJoinTextAreNotTurnedIntoSpaces() {
        // A family emoji is emoji joined by U+200D; Persian writes U+200C inside a word. Flattening
        // a line must not split either (only line breaks and C0/C1 controls become spaces).
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        XCTAssertEqual(compose(detail: detail(family)).body, family)
        let persian = "\u{0645}\u{06CC}\u{200C}\u{062E}\u{0648}\u{0627}\u{0647}\u{0645}"
        XCTAssertEqual(compose(detail: detail(persian)).body, persian)
    }
}
