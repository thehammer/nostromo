import XCTest
import Foundation

// `AgentDisplayText`: how text an agent chose is shown (names, notes, labels) and whether a staged
// command may be placed at a prompt.
//
//   * `plain`: one plain line. Format characters (bidi overrides, zero-width, BOM) and the invisible
//     fillers (Hangul fillers, braille blank, combining grapheme joiner) are dropped; controls, newlines,
//     U+2028, U+2029 and U+0085 become spaces; runs of spaces collapse; the ends are trimmed; text past the
//     limit is cut with "…" as its last character; nil when nothing is left.
//   * `isInsertable`: the app's own last check at the moment of the click. The daemon already refuses
//     such text (`tests/fixtures/terminal_staging/hostile.json`: `invalid_text`, `entry_too_long`); secrets
//     and remote-shell commands are the daemon's business and are not asserted here.
//   * The remote-shell sheet uses the same sanitiser (RemoteShellStoreTests keep covering that, unchanged).

final class AgentDisplayTextTests: XCTestCase {

    private let invisibles: [(name: String, scalar: String)] = [
        ("Hangul filler U+3164", "\u{3164}"), ("braille blank U+2800", "\u{2800}"), ("halfwidth Hangul filler U+FFA0", "\u{FFA0}"),
        ("combining grapheme joiner U+034F", "\u{034F}"), ("Hangul choseong filler U+115F", "\u{115F}"),
        ("Hangul jungseong filler U+1160", "\u{1160}"), ("right-to-left override U+202E", "\u{202E}"),
        ("zero-width space U+200B", "\u{200B}"), ("byte order mark U+FEFF", "\u{FEFF}"),
        ("zero-width joiner U+200D", "\u{200D}"), ("left-to-right isolate U+2066", "\u{2066}"),
        ("soft hyphen U+00AD", "\u{00AD}"), ("tag character U+E0041", "\u{E0041}"),
    ]

    // MARK: plain

    func testPlainDropsEveryFormatCharacterAndInvisibleFiller() {
        for (name, scalar) in invisibles {
            XCTAssertEqual(AgentDisplayText.plain("ab\(scalar)cd", limit: 100), "abcd", name)
            XCTAssertEqual(AgentDisplayText.plain("\(scalar)ab\(scalar)", limit: 100), "ab", "\(name) at the ends")
        }
    }

    func testPlainTurnsControlsAndEveryLineBreakIntoASpace() {
        let breaks: [(String, String)] = [("LF", "\n"), ("CR", "\r"), ("CRLF", "\r\n"), ("tab", "\t"), ("NUL", "\u{0}"),
                                          ("ESC", "\u{1B}"), ("DEL", "\u{7F}"), ("VT", "\u{0B}"), ("FF", "\u{0C}"),
                                          ("U+2028", "\u{2028}"), ("U+2029", "\u{2029}"), ("U+0085", "\u{0085}"), ("C1", "\u{009B}")]
        for (name, scalar) in breaks {
            XCTAssertEqual(AgentDisplayText.plain("a\(scalar)b", limit: 100), "a b", name)
        }
    }

    func testPlainCollapsesRunsOfSpacesAndTrims() {
        XCTAssertEqual(AgentDisplayText.plain("  a   b \n\n c  ", limit: 100), "a b c")
        XCTAssertEqual(AgentDisplayText.plain("a \u{200B} b", limit: 100), "a b", "a dropped character leaves its neighbours' spaces to collapse")
    }

    func testPlainLeavesOrdinaryTextAlone() {
        XCTAssertEqual(AgentDisplayText.plain("Claudia", limit: 40), "Claudia")
        XCTAssertEqual(AgentDisplayText.plain("café – 日本語 – Привет", limit: 40), "café – 日本語 – Привет")
    }

    func testPlainCutsPastTheLimitWithAnEllipsisAsTheLastCharacter() {
        let cut = AgentDisplayText.plain("abcdefghij", limit: 5)
        XCTAssertEqual(cut, "abcd\u{2026}")
        XCTAssertEqual(cut?.count, 5, "the result is exactly `limit` characters")
    }

    func testPlainDoesNotCutTextThatFitsExactly() {
        XCTAssertEqual(AgentDisplayText.plain("abcde", limit: 5), "abcde")
        XCTAssertEqual(AgentDisplayText.plain("abcdef", limit: 5), "abcd\u{2026}")
    }

    func testPlainMeasuresTheLimitAfterCleaning() {
        XCTAssertEqual(AgentDisplayText.plain("a\u{200B}b\u{200B}c\u{200B}d\u{200B}e", limit: 5), "abcde")
    }

    func testPlainIsNilWhenNothingVisibleIsLeft() {
        XCTAssertNil(AgentDisplayText.plain(nil, limit: 10))
        XCTAssertNil(AgentDisplayText.plain("", limit: 10))
        XCTAssertNil(AgentDisplayText.plain("   ", limit: 10))
        XCTAssertNil(AgentDisplayText.plain("\n\t\r", limit: 10))
        XCTAssertNil(AgentDisplayText.plain("\u{200B}\u{FEFF}\u{3164}\u{2800}\u{FFA0}\u{034F}\u{202E}", limit: 10))
    }

    func testPlainOfAnAgentNameWithABidiOverrideCannotReorderWhatFollows() {
        let hostile = "Cla\u{202E}udia"
        let shown = AgentDisplayText.plain(hostile, limit: 40)
        XCTAssertEqual(shown, "Claudia")
        XCTAssertFalse(shown?.unicodeScalars.contains { $0.value == 0x202E } ?? true)
    }

    // MARK: hasVisibleContent

    func testHasVisibleContentIgnoresWhitespaceFormatCharactersAndFillers() {
        XCTAssertFalse(AgentDisplayText.hasVisibleContent(nil))
        XCTAssertFalse(AgentDisplayText.hasVisibleContent(""))
        XCTAssertFalse(AgentDisplayText.hasVisibleContent(" \n\t"))
        for (name, scalar) in invisibles {
            XCTAssertFalse(AgentDisplayText.hasVisibleContent(scalar), name)
        }
        XCTAssertTrue(AgentDisplayText.hasVisibleContent("\u{200B}a"))
        XCTAssertTrue(AgentDisplayText.hasVisibleContent("a"))
    }

    // MARK: isInsertable: what the daemon accepts

    func testEveryCommandInTheGoldenListIsInsertable() throws {
        let commands = try StagingFixtures.commands()
        XCTAssertGreaterThan(commands.count, 20)
        for command in commands {
            XCTAssertTrue(AgentDisplayText.isInsertable(command), command)
        }
    }

    func testACommandOfExactlyOneThousandScalarsIsInsertableAndOneMoreIsNot() {
        XCTAssertEqual(AgentDisplayText.maxCommandScalars, 1_000)
        XCTAssertTrue(AgentDisplayText.isInsertable(String(repeating: "a", count: 1_000)))
        XCTAssertFalse(AgentDisplayText.isInsertable(String(repeating: "a", count: 1_001)), "entry_too_long")
    }

    func testTheLengthLimitCountsScalarsNotCharacters() {
        // 600 characters of two scalars each: 1,200 scalars.
        XCTAssertFalse(AgentDisplayText.isInsertable(String(repeating: "e\u{0301}", count: 600)))
        XCTAssertTrue(AgentDisplayText.isInsertable(String(repeating: "e\u{0301}", count: 500)))
    }

    func testAnEmptyCommandIsNotInsertable() {
        XCTAssertFalse(AgentDisplayText.isInsertable(""))
    }

    // MARK: isInsertable: what the daemon refuses as invalid_text

    private func hostileTexts() throws -> [(name: String, code: String, text: String)] {
        let object = try JSONSerialization.jsonObject(with: try StagingFixtures.fixtureData("hostile.json"))
        let entries = try XCTUnwrap(object as? [[String: Any]], "hostile.json should be an array of objects")
        return entries.map { entry -> (name: String, code: String, text: String) in
            // A remote-shell entry is stored in `parts` (so this file never holds the phrase whole).
            let text = (entry["text"] as? String) ?? ((entry["parts"] as? [String]) ?? []).joined()
            return (name: entry["name"] as? String ?? "?", code: entry["code"] as? String ?? "?", text: text)
        }
    }

    /// The entries the app is asked to refuse itself: `invalid_text`, except the one that is about markup
    /// (`<nostromo-…>` is the daemon's business) and the whitespace rules (their own test).
    private func isWhitespaceRule(_ name: String) -> Bool {
        ["spaces_only", "leading_", "trailing_", "run_of_", "zs_"].contains { name.hasPrefix($0) }
    }

    func testNoControlInvisibleOrLineBreakHostileTextIsInsertable() throws {
        let all = try hostileTexts()
        XCTAssertGreaterThan(all.count, 50, "hostile.json should be found")
        var checked = 0
        // `bom` is checked below from escapes: Foundation's JSON reader drops a literal U+FEFF at the very start
        // of a string, so the fixture's text arrives here without it.
        for entry in all where entry.code == "invalid_text" && !entry.name.hasPrefix("nostromo_markup")
            && !isWhitespaceRule(entry.name) && entry.name != "bom" {
            checked += 1
            XCTAssertFalse(AgentDisplayText.isInsertable(entry.text), "\(entry.name): \(entry.text.debugDescription) must not be placed at a prompt")
        }
        XCTAssertGreaterThan(checked, 25)
        XCTAssertFalse(AgentDisplayText.isInsertable("\u{FEFF}ls"), "bom: a leading byte order mark")
        XCTAssertFalse(AgentDisplayText.isInsertable("l\u{FEFF}s"), "bom: a byte order mark inside")
    }

    func testNoWhitespaceThatCouldHideTextIsInsertable() throws {
        // The daemon refuses leading and trailing whitespace, every space separator but U+0020 and runs of
        // more than four spaces (a command that looks like `ls` and ends in `rm -rf x` far to the right).
        // A drawer that placed them anyway would be the last line of defence missing.
        var checked = 0
        for entry in try hostileTexts() where entry.code == "invalid_text" && isWhitespaceRule(entry.name) {
            checked += 1
            XCTAssertFalse(AgentDisplayText.isInsertable(entry.text), "\(entry.name): \(entry.text.debugDescription) must not be placed at a prompt")
        }
        XCTAssertGreaterThan(checked, 15)
    }

    func testEveryKindOfControlCharacterIsRefusedEvenAmongOrdinaryText() {
        let controls = ["\u{0}", "\u{7}", "\u{9}", "\u{A}", "\u{B}", "\u{C}", "\u{D}", "\u{1B}", "\u{7F}", "\u{80}", "\u{85}", "\u{9B}",
                        "\u{2028}", "\u{2029}"]
        for control in controls {
            XCTAssertFalse(AgentDisplayText.isInsertable("ls\(control)-la"), control.debugDescription)
        }
    }

    func testEveryInvisibleOrFormatCharacterIsRefused() {
        for (name, scalar) in invisibles {
            XCTAssertFalse(AgentDisplayText.isInsertable("ls\(scalar)-la"), name)
        }
    }
}
