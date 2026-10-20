// NostromoKit — ApprovalDisplayModelTests.swift
//
// Behavioural tests for `ApprovalDisplayModel(request:)` (AP2a): what the approval
// card draws for a request, and the round-trip check (T-INV-2) that decides whether
// Allow may be enabled. The displays are hand-built the way the daemon's builder
// (`src/approvals/display.rs`) produces them; see ApprovalFixtures.swift.
//
// PRD criteria covered: 23 (every character of the input, invisible ones as
// tokens, nothing dropped), 24 (compound and 300-line fixtures), 26 (bidi and
// Cyrillic), 30 (Edit, Write, MCP, no markdown), 31 (no escape bytes).

import XCTest
@testable import NostromoKit

final class ApprovalDisplayModelTests: XCTestCase {

    // MARK: - Faithful displays verify

    func testEveryFaithfulBashDisplayIsVerified() throws {
        for fixture in Fx.bashCases {
            let request = try fixture.request()
            let model = ApprovalDisplayModel(request: request)
            XCTAssertEqual(model.roundTrip, .verified, fixture.name)
            XCTAssertTrue(model.isVerified, fixture.name)
        }
    }

    func testEveryFaithfulEditWriteNotebookMcpAndOtherDisplayIsVerified() throws {
        for fixture in try Fx.structuredFixtures() {
            let model = ApprovalDisplayModel(request: fixture.request)
            XCTAssertEqual(model.roundTrip, .verified, fixture.name)
            XCTAssertTrue(model.isVerified, fixture.name)
        }
    }

    // MARK: - Bash shapes

    func testASingleCommandIsOneNumberedLine() throws {
        let model = ApprovalDisplayModel(request: try Fx.bashCase("simple_rm").request())
        XCTAssertEqual(model.lines.count, 1)
        XCTAssertEqual(model.lines[0].number, 1)
        XCTAssertEqual(model.lines[0].kind, .command)
        XCTAssertFalse(model.lines[0].cont)
        XCTAssertEqual(model.lines[0].text, "rm -rf build/")
        XCTAssertEqual(model.commandCount, 1)
    }

    func testACompoundCommandIsTwoNumberedLinesAndTheSecondContinuesTheFirst() throws {
        let model = ApprovalDisplayModel(request: try Fx.bashCase("compound").request())
        XCTAssertEqual(model.lines.map(\.number), [1, 2])
        XCTAssertEqual(model.lines.map(\.cont), [false, true])
        XCTAssertEqual(model.lines.map(\.kind), [.command, .command])
        XCTAssertEqual(model.commandCount, 2)
        XCTAssertEqual(model.lines[0].separators, ["&&"])
        XCTAssertEqual(model.lines[1].separators, [])
        XCTAssertEqual(model.lines[0].runs.last?.kind, .separator)
        XCTAssertEqual(model.lines[0].runs.last?.text, "&&")
        XCTAssertEqual(model.lines[1].text, " rm -rf target/debug/incremental")
    }

    func testTheCompoundFixtureWithAPipeIsThreeLinesAndThreeCommands() throws {
        let model = ApprovalDisplayModel(request: try Fx.bashCase("compound_fixture").request())
        XCTAssertEqual(model.lines.map(\.number), [1, 2, 3])
        XCTAssertEqual(model.commandCount, 3)
        XCTAssertEqual(model.lines[0].separators, ["&&"])
        XCTAssertEqual(model.lines[1].separators, ["|"])
        XCTAssertEqual(model.lines[2].separators, [])
    }

    func testAPipeIsCutAtTheBarIntoTwoCommands() throws {
        let model = ApprovalDisplayModel(request: try Fx.bashCase("pipe").request())
        XCTAssertEqual(model.lines.count, 2)
        XCTAssertEqual(model.lines[0].separators, ["|"])
        XCTAssertTrue(model.lines[1].cont)
        XCTAssertEqual(model.commandCount, 2)
        XCTAssertEqual(model.summary, "a")
    }

    func testOnlyASeparatorCutIsContinuedNotARealNewline() throws {
        let model = ApprovalDisplayModel(request: try Fx.bashCase("semicolon_then_newline").request())
        XCTAssertEqual(model.lines.map(\.cont), [false, true, false])
        XCTAssertEqual(model.shownText, "cd /tmp; ls\nrm x")
    }

    func testASeparatorAtTheEndOfALineStartsNoContinuationLine() throws {
        let model = ApprovalDisplayModel(request: try Fx.bashCase("trailing_ampersand").request())
        XCTAssertEqual(model.lines.count, 1)
        XCTAssertEqual(model.lines[0].separators, ["&"])
        XCTAssertEqual(model.summary, "sleep 1")
    }

    func testAHeredocShowsItsCommandItsBodyAndItsTerminatorEachOnALine() throws {
        let model = ApprovalDisplayModel(request: try Fx.bashCase("heredoc_small").request())
        XCTAssertEqual(model.lines.map(\.kind), [.command, .heredocBody, .heredocEnd])
        XCTAssertEqual(model.lines[1].text, "rm -rf / && echo hi")
        XCTAssertEqual(model.lines[1].separators, [], "text inside a here-doc body is not a command separator")
        XCTAssertEqual(model.lines[2].text, "EOF")
        XCTAssertTrue(model.isVerified)
    }

    func testA300LineCommandShowsAll300LinesWithTheSecondCommandOnLine287() throws {
        let model = ApprovalDisplayModel(request: try Fx.bashCase("heredoc_300").request())
        XCTAssertEqual(model.lines.count, 300)
        XCTAssertEqual(model.lines.map(\.number), Array(1...300))
        XCTAssertEqual(model.lines[286].number, 287)
        XCTAssertEqual(model.lines[286].kind, .command)
        XCTAssertEqual(model.lines[286].text, "rm -rf /tmp/notes.txt")
        XCTAssertEqual(model.lines[285].kind, .heredocEnd)
        XCTAssertEqual(model.lines[285].text, "EOF")
        XCTAssertTrue(model.lines[1...284].allSatisfy { $0.kind == .heredocBody })
        XCTAssertEqual(model.commandCount, 15)
        XCTAssertTrue(model.isVerified)
    }

    // MARK: - Invisible and non-ASCII characters shown, not dropped

    func testBidiControlsAreShownAsTokensAtTheirPosition() throws {
        let model = ApprovalDisplayModel(request: try Fx.bashCase("bidi").request())
        XCTAssertEqual(model.lines.count, 1)
        XCTAssertEqual(model.lines[0].text,
                       "echo ⟨U+202E RLO⟩txt.exe⟨U+2069 PDI⟩ ok ⟨U+2066 LRI⟩x⟨U+2067 RLI⟩y⟨U+2068 FSI⟩z⟨U+2069 PDI⟩")
        let invisible = model.lines[0].runs.filter { $0.kind == .invisible }
        XCTAssertEqual(invisible.map(\.codePoint), [0x202E, 0x2069, 0x2066, 0x2067, 0x2068, 0x2069])
        XCTAssertEqual(model.invisibleCount, 6)
        XCTAssertTrue(model.isVerified)
    }

    func testTabAndCarriageReturnAreShownAsTheirTokens() throws {
        let model = ApprovalDisplayModel(request: try Fx.bashCase("tab_and_cr").request())
        XCTAssertEqual(model.shownText, "a⟨tab⟩b⟨CR⟩c")
        XCTAssertEqual(model.lines[0].runs.filter { $0.kind == .invisible }.map(\.codePoint), [0x09, 0x0D])
        XCTAssertEqual(model.invisibleCount, 2)
        XCTAssertTrue(model.isVerified)
    }

    func testACarriageReturnBeforeANewlineIsShownAndTheLinesStaySplit() throws {
        let model = ApprovalDisplayModel(request: try Fx.bashCase("crlf").request())
        XCTAssertEqual(model.lines.map(\.text), ["echo hi⟨CR⟩", "ls"])
        XCTAssertTrue(model.isVerified)
    }

    func testZeroWidthCharactersHiddenInACommandAreAllShown() throws {
        let model = ApprovalDisplayModel(request: try Fx.bashCase("zero_width").request())
        XCTAssertEqual(model.shownText,
                       "r⟨U+200B ZWSP⟩m -rf⟨U+200C ZWNJ⟩ ⟨U+200D ZWJ⟩x⟨U+2060 WJ⟩⟨U+FEFF BOM⟩")
        XCTAssertEqual(model.invisibleCount, 5)
        XCTAssertTrue(model.isVerified)
    }

    func testUnicodeTagCharactersAreShownByCodePoint() throws {
        let model = ApprovalDisplayModel(request: try Fx.bashCase("tags").request())
        XCTAssertEqual(model.shownText, "echo hi⟨U+E0041⟩⟨U+E0042⟩⟨U+E0043⟩⟨U+E007F⟩ there")
        XCTAssertEqual(model.invisibleCount, 4)
        XCTAssertTrue(model.isVerified)
    }

    func testAnEscapeCharacterInTheInputIsShownAsATokenNeverRaw() throws {
        let model = ApprovalDisplayModel(request: try Fx.bashCase("escape_sequence").request())
        XCTAssertEqual(model.shownText, "echo ⟨U+001B⟩[31mred⟨U+001B⟩[0m")
        XCTAssertFalse(model.shownText.unicodeScalars.contains("\u{1B}"))
        XCTAssertEqual(model.invisibleCount, 2)
        XCTAssertTrue(model.isVerified)
    }

    func testACyrillicLookAlikeIsItsOwnNonAsciiRunWithItsCodePoint() throws {
        let model = ApprovalDisplayModel(request: try Fx.bashCase("cyrillic").request())
        let runs = model.lines[0].runs
        XCTAssertEqual(runs.map(\.kind), [.plain, .nonAscii, .plain])
        XCTAssertEqual(runs[1].text, "\u{043C}")
        XCTAssertEqual(runs[1].codePoint, 0x043C)
        XCTAssertEqual(model.nonAsciiCount, 1)
        XCTAssertEqual(model.invisibleCount, 0)
        XCTAssertTrue(model.isVerified)
    }

    // MARK: - Edit, Write, NotebookEdit, MCP, other

    func testAnEditShowsThePathThenTheDiffWithContextDeletionsAndAdditions() throws {
        let model = ApprovalDisplayModel(request: try Fx.editRequest())
        XCTAssertEqual(model.lines[0].kind, .fileHeader)
        XCTAssertEqual(model.lines[0].text, Fx.editPath)
        let kinds = Set(model.lines.map(\.kind))
        XCTAssertTrue(kinds.isSuperset(of: [.fileHeader, .diffCtx, .diffDel, .diffAdd]))
        XCTAssertNil(model.commandCount)
        XCTAssertTrue(model.isVerified)
    }

    func testAnEditsOtherFieldsAreShownAsJsonLinesAndVerified() throws {
        let model = ApprovalDisplayModel(request: try Fx.editRequest(replaceAll: true))
        XCTAssertTrue(model.lines.contains { $0.kind == .json && $0.text.contains("replace_all") })
        XCTAssertTrue(model.isVerified)
    }

    func testAWriteShowsThePathThenEveryLineOfTheContentAsAdditions() throws {
        let model = ApprovalDisplayModel(request: try Fx.writeRequest())
        XCTAssertEqual(model.lines[0].kind, .fileHeader)
        XCTAssertEqual(model.lines[0].text, Fx.writePath)
        XCTAssertEqual(model.lines.dropFirst().map(\.kind), Array(repeating: ApprovalLineKind.diffAdd, count: 6))
        XCTAssertEqual(model.lines.dropFirst().map(\.text),
                       ["# Notes", "", "first line", "second line", "third line", ""])
        XCTAssertTrue(model.isVerified)
    }

    func testAWritesInvisibleCharactersAreTokensAndPutBackGivePathAndContentExactly() throws {
        let content = "a\u{202E}b\nc"
        let model = ApprovalDisplayModel(request: try Fx.writeRequest(content: content))
        XCTAssertEqual(model.shownText, "\(Fx.writePath)\na⟨U+202E RLO⟩b\nc")
        let restored = Fx.original(of: model)
        XCTAssertTrue(restored.utf8.elementsEqual("\(Fx.writePath)\n\(content)".utf8))
        XCTAssertEqual(model.invisibleCount, 1)
        XCTAssertTrue(model.isVerified)
    }

    func testANotebookEditShowsThePathTheNewSourceAndItsOtherFields() throws {
        let model = ApprovalDisplayModel(request: try Fx.notebookEditRequest())
        XCTAssertEqual(model.lines[0].kind, .fileHeader)
        XCTAssertEqual(model.lines[0].text, Fx.notebookPath)
        XCTAssertTrue(model.lines.contains { $0.kind == .diffAdd && $0.text == "import pandas as pd" })
        XCTAssertTrue(model.lines.contains { $0.kind == .json && $0.text.contains("cell-3") })
        XCTAssertTrue(model.isVerified)
    }

    func testAnMcpInputIsPrettyJsonLinesInAnyKeyOrder() throws {
        let reversed = "{\n  \"text\": \"hello team\",\n  \"channel\": \"#general\"\n}"
        let model = ApprovalDisplayModel(request: try Fx.mcpRequest(pretty: reversed))
        XCTAssertTrue(model.lines.allSatisfy { $0.kind == .json })
        XCTAssertEqual(model.lines.map(\.text), ["{", "  \"text\": \"hello team\",", "  \"channel\": \"#general\"", "}"])
        XCTAssertTrue(model.isVerified)
    }

    func testAnMcpInputWithNestingArraysAndNullIsVerified() throws {
        let model = ApprovalDisplayModel(request: try Fx.mcpNestedRequest())
        XCTAssertTrue(model.isVerified)
        XCTAssertNil(model.commandCount)
    }

    func testAnInvisibleCharacterInsideAnMcpStringValueIsShownAndCounted() throws {
        let model = ApprovalDisplayModel(request: try Fx.mcpWithRLORequest())
        XCTAssertTrue(model.lines.contains { $0.text.contains("⟨U+202E RLO⟩") })
        XCTAssertEqual(model.invisibleCount, 1)
        XCTAssertTrue(model.isVerified)
    }

    func testAnyOtherToolIsShownAsPrettyJson() throws {
        let model = ApprovalDisplayModel(request: try Fx.otherToolRequest())
        XCTAssertTrue(model.lines.allSatisfy { $0.kind == .json })
        XCTAssertTrue(model.isVerified)
    }

    func testMarkdownIsNeverInterpretedTheTextStaysLiteralInOnePlainRun() throws {
        let content = "**bold** and [link](http://x)"
        let model = ApprovalDisplayModel(request: try Fx.writeRequest(content: content))
        XCTAssertEqual(model.lines[1].runs, [ApprovalRenderRun(text: content, kind: .plain, codePoint: nil)])
        XCTAssertEqual(model.lines[1].text, content)
        XCTAssertTrue(model.isVerified)
    }

    // MARK: - Criterion 23: every character, in order, nothing dropped

    func testEveryBashFixtureWithItsTokensPutBackIsTheCommandByteForByte() throws {
        for fixture in Fx.bashCases {
            let model = ApprovalDisplayModel(request: try fixture.request())
            let restored = Fx.original(of: model)
            XCTAssertTrue(restored.utf8.elementsEqual(fixture.command.utf8), fixture.name)
        }
    }

    func testNoInvisibleCharacterSurvivesRawInTheShownTextOfAnyBashFixture() throws {
        for fixture in Fx.bashCases {
            let model = ApprovalDisplayModel(request: try fixture.request())
            let raw = model.shownText.unicodeScalars.filter { Fx.isInvisible($0) && $0 != "\n" }
            XCTAssertTrue(raw.isEmpty, "\(fixture.name) shows a raw invisible character: \(raw.map(\.value))")
        }
    }

    func testTheShownTextOfASimpleCommandIsTheCommand() throws {
        for name in ["simple_rm", "compound", "compound_fixture", "pipe", "semicolon_then_newline",
                     "trailing_ampersand", "heredoc_small", "cyrillic"] {
            let fixture = Fx.bashCase(name)
            let model = ApprovalDisplayModel(request: try fixture.request())
            XCTAssertTrue(model.shownText.utf8.elementsEqual(fixture.command.utf8), name)
        }
    }

    func testRandomCommandsRoundTripExactlyAndShowNoRawInvisibleCharacter() throws {
        var rng = ApprovalSeededGenerator(seed: 20_241_019)
        for i in 0..<400 {
            let text = randomText(&rng)
            let request = try Fx.bashRequest(text)
            let model = ApprovalDisplayModel(request: request)
            let note = "case \(i): \(text.unicodeScalars.map { String($0.value, radix: 16) })"
            XCTAssertEqual(model.roundTrip, .verified, note)
            XCTAssertTrue(Fx.original(of: model).utf8.elementsEqual(text.utf8), note)
            let raw = model.shownText.unicodeScalars.filter { Fx.isInvisible($0) && $0 != "\n" }
            XCTAssertTrue(raw.isEmpty, note)
        }
    }

    func testDroppingAnyOneCharacterFromARandomDisplayIsAlwaysCaught() throws {
        var rng = ApprovalSeededGenerator(seed: 7_777)
        for i in 0..<200 {
            let text = randomText(&rng, minLength: 1)
            var scalars = Array(text.unicodeScalars)
            scalars.remove(at: Int.random(in: 0..<scalars.count, using: &rng))
            var shorter = ""
            shorter.unicodeScalars.append(contentsOf: scalars)
            let request = try Fx.bashRequest(text, lines: Fx.plainBashLines(shorter))
            assertMismatch(request, "case \(i): \(text.unicodeScalars.map { String($0.value, radix: 16) })")
        }
    }

    // MARK: - A display that is not the request's text is a mismatch

    func testADisplayThatDropsACharacterIsAMismatch() throws {
        let request = try Fx.bashRequest("rm -rf build/",
                                         lines: [Fx.line(1, "command", [Fx.plain("rm -rf build")])])
        assertMismatch(request)
    }

    func testADisplayThatDropsAnInvisibleCharacterIsAMismatch() throws {
        let request = try Fx.bashRequest("echo \u{202E}txt",
                                         lines: [Fx.line(1, "command", [Fx.plain("echo "), Fx.plain("txt")])])
        assertMismatch(request)
    }

    func testADisplayThatAddsACharacterIsAMismatch() throws {
        let request = try Fx.bashRequest("rm -rf build/",
                                         lines: [Fx.line(1, "command", [Fx.plain("rm -rf build//")])])
        assertMismatch(request)
    }

    func testADisplayThatReordersLinesIsAMismatch() throws {
        let request = try Fx.bashRequest("echo one\necho two", lines: [
            Fx.line(1, "command", [Fx.plain("echo two")]),
            Fx.line(2, "command", [Fx.plain("echo one")]),
        ])
        assertMismatch(request)
    }

    func testADisplayThatCutsALineWithoutSayingSoIsAMismatch() throws {
        let request = try Fx.bashRequest("a | b", lines: [
            Fx.line(1, "command", [Fx.plain("a "), Fx.separator("|")]),
            Fx.line(2, "command", [Fx.plain(" b")]),
        ], commandCount: 2)
        assertMismatch(request, "the second line is not marked as continuing the first, so it reads as a newline")
    }

    func testADisplayThatClaimsACutWhereTheOriginalHadANewlineIsAMismatch() throws {
        let request = try Fx.bashRequest("echo one\necho two", lines: [
            Fx.line(1, "command", [Fx.plain("echo one")]),
            Fx.line(2, "command", cont: true, [Fx.plain("echo two")]),
        ])
        assertMismatch(request)
    }

    func testAnInvisibleCharacterLeftInsideAPlainSegmentIsAMismatch() throws {
        let hidden: [UInt32] = [0x202E, 0x200B, 0x09, 0x0D, 0x1B, 0xFEFF, 0xE0041, 0x2028,
                                0x00AD, 0xFE0F, 0x3164, 0x2800, 0x7F]
        for cp in hidden {
            let scalar = try XCTUnwrap(Unicode.Scalar(cp))
            var command = "echo "
            command.unicodeScalars.append(scalar)
            command += "x"
            let request = try Fx.bashRequest(command, lines: [Fx.line(1, "command", [Fx.plain(command)])])
            assertMismatch(request, "U+\(String(cp, radix: 16, uppercase: true)) hidden in a plain segment")
        }
    }

    func testAnInvisibleCharacterLeftInsideANonAsciiSegmentIsAMismatch() throws {
        let hiddenRun: Fx.Obj = ["text": "\u{202E}", "kind": "non_ascii", "cp": 0x202E]
        let request = try Fx.bashRequest("echo \u{202E}x", lines: [
            Fx.line(1, "command", [Fx.plain("echo "), hiddenRun, Fx.plain("x")]),
        ])
        assertMismatch(request)
    }

    func testAnInvisibleCharacterLeftInsideASegmentOfAnUnknownKindIsAMismatch() throws {
        let unknownRun: Fx.Obj = ["text": "echo \u{202E}x", "kind": "future_kind"]
        let request = try Fx.bashRequest("echo \u{202E}x", lines: [Fx.line(1, "command", [unknownRun])])
        assertMismatch(request)
    }

    func testAnInvisibleSegmentWithTheWrongCodePointIsAMismatch() throws {
        let wrong = Fx.invisible(token: "⟨U+202E RLO⟩", cp: 0x202D)
        let request = try Fx.bashRequest("echo \u{202E}x", lines: [
            Fx.line(1, "command", [Fx.plain("echo "), wrong, Fx.plain("x")]),
        ])
        assertMismatch(request, "the token says RLO but the code point is LRO")
    }

    func testAnInvisibleSegmentWithAnImpossibleCodePointIsAMismatch() throws {
        let surrogate = Fx.invisible(token: "⟨U+D800⟩", cp: 0xD800)
        let request = try Fx.bashRequest("echo \u{202E}x", lines: [
            Fx.line(1, "command", [Fx.plain("echo "), surrogate, Fx.plain("x")]),
        ])
        assertMismatch(request)
    }

    func testAnInvisibleSegmentWithNoCodePointIsAMismatch() throws {
        let noCodePoint = Fx.invisible(token: "⟨U+202E RLO⟩", cp: nil)
        let request = try Fx.bashRequest("echo \u{202E}x", lines: [
            Fx.line(1, "command", [Fx.plain("echo "), noCodePoint, Fx.plain("x")]),
        ])
        assertMismatch(request)
    }

    func testLineNumbersThatDoNotRunOneTwoThreeAreAMismatch() throws {
        let one = [Fx.plain("echo one")]
        let two = [Fx.plain("echo two")]
        let numberings: [[Int]] = [[1, 3], [2, 3], [0, 1], [1, 1], [2, 1]]
        for numbers in numberings {
            let request = try Fx.bashRequest("echo one\necho two", lines: [
                Fx.line(numbers[0], "command", one),
                Fx.line(numbers[1], "command", two),
            ])
            assertMismatch(request, "numbers \(numbers)")
        }
    }

    func testTheTooLargeToDisplayPlaceholderIsNeverVerifiedAsTheCommand() throws {
        let command = String(repeating: "a", count: 32 * 1024 + 1)
        let placeholder = Fx.line(1, "command", [Fx.plain("(command too large to display)")])
        let request = try Fx.bashRequest(command, lines: [placeholder], commandCount: nil, unparsed: true)
        let model = ApprovalDisplayModel(request: request)
        XCTAssertFalse(model.isVerified)
        XCTAssertEqual(model.lines.first?.text, "(command too large to display)")
        XCTAssertTrue(model.unparsed)
        assertMismatch(request)
    }

    func testAnEmptyDisplayForANonEmptyCommandIsAMismatch() throws {
        assertMismatch(try Fx.bashRequest("rm -rf x", lines: []))
    }

    func testACanonicallyEquivalentButDifferentStringIsAMismatch() throws {
        let precomposed = "caf\u{00E9}"
        let decomposed = "cafe\u{0301}"
        XCTAssertEqual(precomposed, decomposed, "precondition: Swift's == calls these equal")
        XCTAssertFalse(precomposed.utf8.elementsEqual(decomposed.utf8), "precondition: the bytes differ")

        assertMismatch(try Fx.bashRequest(precomposed, lines: Fx.plainBashLines(decomposed)),
                       "request is precomposed, display decomposed")
        assertMismatch(try Fx.bashRequest(decomposed, lines: Fx.plainBashLines(precomposed)),
                       "request is decomposed, display precomposed")
    }

    func testEachSpellingOfAnAccentIsVerifiedAgainstItself() throws {
        for text in ["caf\u{00E9}", "cafe\u{0301}"] {
            let model = ApprovalDisplayModel(request: try Fx.bashRequest(text))
            XCTAssertTrue(model.isVerified)
            XCTAssertTrue(Fx.original(of: model).utf8.elementsEqual(text.utf8))
        }
    }

    func testAnEditWhoseHeaderPathDiffersIsAMismatch() throws {
        assertMismatch(try Fx.editRequest(header: "/tmp/x/src/other.rs"))
    }

    func testAnEditWhoseHeaderUsesALookAlikeLetterIsAMismatch() throws {
        assertMismatch(try Fx.editRequest(header: "/tmp/x/src/m\u{0430}in.rs"), "Cyrillic a in main.rs")
    }

    func testAnEditWhoseOldTextDiffersIsAMismatch() throws {
        var diff = Fx.editDiff
        diff[2] = (kind: "diff_del", text: "    let b = 9;")
        assertMismatch(try Fx.editRequest(diff: diff))
    }

    func testAnEditWhoseNewTextDiffersIsAMismatch() throws {
        var diff = Fx.editDiff
        diff[5] = (kind: "diff_add", text: "    let c = 5;")
        assertMismatch(try Fx.editRequest(diff: diff))
    }

    func testAnEditThatHidesAFieldOfTheInputIsAMismatch() throws {
        assertMismatch(try Fx.editRequest(replaceAll: true, showExtras: false))
    }

    func testAnEditThatShowsAFieldTheInputDoesNotHaveIsAMismatch() throws {
        assertMismatch(try Fx.editRequest(extraJSON: "{\n  \"replace_all\": true\n}"))
    }

    func testAWriteWhoseContentDiffersIsAMismatch() throws {
        let changed = Fx.writeContent.replacingOccurrences(of: "second", with: "secoNd")
        assertMismatch(try Fx.writeRequest(shown: changed))
    }

    func testAWriteThatDropsTheTrailingNewlineIsAMismatch() throws {
        assertMismatch(try Fx.writeRequest(shown: "# Notes\n\nfirst line\nsecond line\nthird line"))
    }

    func testAWriteWhoseHeaderPathDiffersIsAMismatch() throws {
        assertMismatch(try Fx.writeRequest(header: "/tmp/x/notes.txt"))
    }

    func testAnMcpDisplayThatParsesToDifferentJsonIsAMismatch() throws {
        let changed = "{\n  \"channel\": \"#general\",\n  \"text\": \"hello tea\"\n}"
        assertMismatch(try Fx.mcpRequest(pretty: changed))
    }

    func testAnMcpDisplayThatShowsAnExtraKeyIsAMismatch() throws {
        let extra = "{\n  \"channel\": \"#general\",\n  \"text\": \"hello team\",\n  \"urgent\": true\n}"
        assertMismatch(try Fx.mcpRequest(pretty: extra))
    }

    func testAnMcpDisplayThatHidesAKeyIsAMismatch() throws {
        assertMismatch(try Fx.mcpRequest(pretty: "{\n  \"channel\": \"#general\"\n}"))
    }

    func testAnMcpDisplayThatIsNotJsonIsAMismatch() throws {
        assertMismatch(try Fx.mcpRequest(pretty: "channel: #general\ntext: hello team"))
    }

    func testWhatAllowSaysWhileTheCheckFailsIsThatTheTextCouldNotBeVerified() {
        XCTAssertEqual(ApprovalDisplayModel.roundTripFailureLabel,
                       "Nostromo couldn't verify this text matches the request")
    }

    // MARK: - Counts come from the segments

    func testInvisibleCharactersAreCountedFromTheSegmentsNotTheFrame() throws {
        let lines = Fx.plainBashLines("echo \u{202E}x")
        let request = try Fx.request(input: ["command": "echo \u{202E}x"],
                                     display: Fx.display(lines: lines, commandCount: 1, invisibleCount: 0))
        XCTAssertEqual(request.display.invisibleCount, 0, "precondition: the frame says none")
        XCTAssertEqual(ApprovalDisplayModel(request: request).invisibleCount, 1)
    }

    func testAFrameThatOverReportsInvisibleCharactersIsNotBelieved() throws {
        let request = try Fx.request(input: ["command": "ls"],
                                     display: Fx.display(lines: Fx.plainBashLines("ls"), commandCount: 1, invisibleCount: 7))
        XCTAssertEqual(ApprovalDisplayModel(request: request).invisibleCount, 0)
    }

    func testNonAsciiCharactersAreCountedFromTheSegmentsNotTheFrame() throws {
        let command = Fx.cyrillicCommand
        let request = try Fx.request(input: ["command": command],
                                     display: Fx.display(lines: Fx.plainBashLines(command), commandCount: 1,
                                                         nonAsciiCount: 0))
        XCTAssertEqual(request.display.nonAsciiCount, 0, "precondition: the frame says none")
        XCTAssertEqual(ApprovalDisplayModel(request: request).nonAsciiCount, 1)
    }

    func testInvisibleCharactersAreCountedAcrossEveryLine() throws {
        let model = ApprovalDisplayModel(request: try Fx.bashRequest("a\u{200B}\nb\u{200B}\u{200B}"))
        XCTAssertEqual(model.invisibleCount, 3)
    }

    func testTheCommandCountIsTheFramesAndAbsentWhereTheFrameHasNone() throws {
        XCTAssertEqual(ApprovalDisplayModel(request: try Fx.bashCase("compound").request()).commandCount, 2)
        XCTAssertNil(ApprovalDisplayModel(request: try Fx.mcpRequest()).commandCount)
    }

    func testTheUnparsedFlagIsCarriedThrough() throws {
        XCTAssertTrue(ApprovalDisplayModel(request: try Fx.bashRequest("echo $(", unparsed: true)).unparsed)
        XCTAssertFalse(ApprovalDisplayModel(request: try Fx.bashRequest("echo hi")).unparsed)
    }

    func testASegmentKindThisBuildDoesNotKnowIsDrawnAsPlainText() throws {
        let unknownRun: Fx.Obj = ["text": "ls -la", "kind": "future_kind"]
        let request = try Fx.bashRequest("ls -la", lines: [Fx.line(1, "command", [unknownRun])])
        let model = ApprovalDisplayModel(request: request)
        XCTAssertEqual(model.lines[0].runs, [ApprovalRenderRun(text: "ls -la", kind: .plain, codePoint: nil)])
        XCTAssertTrue(model.isVerified)
    }

    // MARK: - The banner

    func testNoBannerWhenThereAreNoInvisibleCharacters() throws {
        let model = ApprovalDisplayModel(request: try Fx.bashCase("simple_rm").request())
        XCTAssertNil(model.banner(toolKind: .bash))
        XCTAssertNil(model.banner(toolKind: .mcp))
    }

    func testTheBannerCountsFiveInvisibleCharactersInACommand() throws {
        let model = ApprovalDisplayModel(request: try Fx.bashCase("zero_width").request())
        XCTAssertEqual(model.banner(toolKind: .bash),
                       "This command contains 5 invisible or direction-changing characters.")
    }

    func testTheBannerSaysCharacterInTheSingularForOne() throws {
        let model = ApprovalDisplayModel(request: try Fx.bashRequest("echo \u{202E}x"))
        XCTAssertEqual(model.banner(toolKind: .bash),
                       "This command contains 1 invisible or direction-changing character.")
    }

    func testTheBannerSaysInputRatherThanCommandForOtherTools() throws {
        let write = ApprovalDisplayModel(request: try Fx.writeRequest(content: "a\u{202E}b"))
        XCTAssertEqual(write.banner(toolKind: .write),
                       "This input contains 1 invisible or direction-changing character.")
        let mcp = ApprovalDisplayModel(request: try Fx.mcpWithRLORequest())
        XCTAssertEqual(mcp.banner(toolKind: .mcp),
                       "This input contains 1 invisible or direction-changing character.")
    }

    // MARK: - Names for hover and VoiceOver

    func testHoveringTheCyrillicLookAlikeGivesItsCodePointAndName() throws {
        let model = ApprovalDisplayModel(request: try Fx.bashCase("cyrillic").request())
        let tooltip = try XCTUnwrap(model.lines[0].runs[1].tooltip)
        XCTAssertTrue(tooltip.contains("U+043C"), tooltip)
        XCTAssertTrue(tooltip.contains("CYRILLIC SMALL LETTER EM"), tooltip)
    }

    func testOnlyANonAsciiRunHasATooltip() throws {
        let model = ApprovalDisplayModel(request: try Fx.bashCase("cyrillic").request())
        XCTAssertNil(model.lines[0].runs[0].tooltip)
        XCTAssertNil(model.lines[0].runs[2].tooltip)
        let bidi = ApprovalDisplayModel(request: try Fx.bashCase("bidi").request())
        for run in bidi.lines[0].runs where run.kind == .invisible {
            XCTAssertNil(run.tooltip, "an invisible run is described by its token, not a hover")
        }
    }

    func testDescribeGivesTheCodePointAndTheUnicodeName() {
        XCTAssertEqual(ApprovalDisplayModel.describe(codePoint: 0x043C), "U+043C CYRILLIC SMALL LETTER EM")
        XCTAssertEqual(ApprovalDisplayModel.describe(codePoint: 0x202E), "U+202E RIGHT-TO-LEFT OVERRIDE")
        XCTAssertEqual(ApprovalDisplayModel.describe(codePoint: 0x043C, nameFirst: true),
                       "CYRILLIC SMALL LETTER EM (U+043C)")
    }

    func testDescribeFallsBackToTheBareCodePointWhereThereIsNoScalar() {
        XCTAssertEqual(ApprovalDisplayModel.describe(codePoint: 0xD800), "U+D800")
        XCTAssertEqual(ApprovalDisplayModel.describe(codePoint: 0x110000), "U+110000")
    }

    func testVoiceOverReadsARightToLeftOverrideByNameAndCodePoint() throws {
        let model = ApprovalDisplayModel(request: try Fx.bashCase("bidi").request())
        let rlo = try XCTUnwrap(model.lines[0].runs.first { $0.kind == .invisible })
        XCTAssertTrue(rlo.spoken.contains("RIGHT-TO-LEFT OVERRIDE"), rlo.spoken)
        XCTAssertTrue(rlo.spoken.contains("U+202E"), rlo.spoken)
    }

    func testVoiceOverReadsATabAsTabAndACarriageReturnAsCarriageReturn() throws {
        let model = ApprovalDisplayModel(request: try Fx.bashCase("tab_and_cr").request())
        let invisible = model.lines[0].runs.filter { $0.kind == .invisible }
        XCTAssertEqual(invisible.map(\.spoken), ["tab", "carriage return"])
    }

    func testVoiceOverReadsPlainTextAsWritten() throws {
        let model = ApprovalDisplayModel(request: try Fx.bashCase("simple_rm").request())
        XCTAssertEqual(model.lines[0].spokenText, "rm -rf build/")
    }

    func testASpokenLineNamesInvisibleCharactersInsteadOfReadingTheTokenGlyphs() throws {
        let model = ApprovalDisplayModel(request: try Fx.bashCase("bidi").request())
        let spoken = model.lines[0].spokenText
        XCTAssertTrue(spoken.hasPrefix("echo "), spoken)
        XCTAssertTrue(spoken.contains("RIGHT-TO-LEFT OVERRIDE"), spoken)
        XCTAssertFalse(spoken.contains("\u{27E8}"), spoken)
    }

    // MARK: - Summary, marked text, separators

    func testTheSummaryIsTheFirstCommandBeforeTheFirstSeparator() throws {
        XCTAssertEqual(ApprovalDisplayModel(request: try Fx.bashCase("compound").request()).summary, "rm -rf build/")
        XCTAssertEqual(ApprovalDisplayModel(request: try Fx.bashCase("simple_rm").request()).summary, "rm -rf build/")
        XCTAssertEqual(ApprovalDisplayModel(request: try Fx.bashCase("heredoc_small").request()).summary, "cat <<'EOF'")
    }

    func testTheSummaryOfAnEmptyDisplayIsEmpty() throws {
        XCTAssertEqual(ApprovalDisplayModel(request: try Fx.bashRequest("", lines: [])).summary, "")
    }

    func testMarkedTextWrapsEachSeparatorInAngleBrackets() throws {
        let model = ApprovalDisplayModel(request: try Fx.bashCase("compound").request())
        XCTAssertEqual(model.lines[0].markedText, "rm -rf build/ ⟨&&⟩")
        XCTAssertEqual(model.lines[1].markedText, " rm -rf target/debug/incremental")
        let three = ApprovalDisplayModel(request: try Fx.bashCase("compound_fixture").request())
        XCTAssertEqual(three.lines[1].markedText, " curl -s https://x ⟨|⟩")
    }

    func testALineWithNoSeparatorIsItsMarkedText() throws {
        let model = ApprovalDisplayModel(request: try Fx.bashCase("simple_rm").request())
        XCTAssertEqual(model.lines[0].markedText, model.lines[0].text)
        XCTAssertEqual(model.lines[0].separators, [])
    }

    // MARK: - No escape bytes anywhere (criterion 31)

    func testNoRunCarriesAnEscapeByteWhenTheInputAndReasonAreClean() throws {
        let fixture = Fx.bashCase("simple_rm")
        let request = try Fx.request(input: ["command": fixture.command, "description": "remove build"],
                                     display: fixture.display(),
                                     reasonText: "your rule Bash(rm:*) in ~/.claude/settings.json",
                                     description: "remove build")
        let model = ApprovalDisplayModel(request: request)
        assertNoEscapeByte(model)
    }

    func testAnEscapeByteInTheReasonOrDescriptionNeverReachesTheInputRuns() throws {
        let fixture = Fx.bashCase("simple_rm")
        let request = try Fx.request(input: ["command": fixture.command],
                                     display: fixture.display(),
                                     reasonText: "\u{1B}[1mDangerous removal\u{1B}[0m\u{1B}]0;title\u{07}",
                                     description: "\u{1B}[1mremove\u{1B}[0m build")
        let model = ApprovalDisplayModel(request: request)
        assertNoEscapeByte(model)
        XCTAssertEqual(model.shownText, "rm -rf build/")
    }

    func testAnEscapeByteInTheInputIsATokenInEveryRun() throws {
        let model = ApprovalDisplayModel(request: try Fx.bashCase("escape_sequence").request())
        assertNoEscapeByte(model)
    }

    func testARawEscapeByteInAPlainRunIsAMismatch() throws {
        let command = "echo \u{1B}[31mred"
        let request = try Fx.bashRequest(command, lines: [Fx.line(1, "command", [Fx.plain(command)])])
        assertMismatch(request)
    }

    // MARK: - An invisible run must carry its canonical token

    func testTheCanonicalTokenIsTheDaemonsInvisibleToken() {
        let expected: [(UInt32, String)] = [
            (0x09, "⟨tab⟩"), (0x0D, "⟨CR⟩"), (0x202E, "⟨U+202E RLO⟩"), (0x200B, "⟨U+200B ZWSP⟩"),
            (0xFEFF, "⟨U+FEFF BOM⟩"), (0x00AD, "⟨U+00AD SHY⟩"), (0xE0041, "⟨U+E0041⟩"), (0x0000, "⟨U+0000⟩"),
        ]
        for (cp, token) in expected {
            XCTAssertEqual(ApprovalDisplayModel.canonicalToken(forCodePoint: cp), token, "U+\(String(cp, radix: 16))")
        }
    }

    func testTheCanonicalTokenAgreesWithEveryTokenTheFixturesBuild() {
        let scalars: [UInt32] = [0x09, 0x0D, 0x1B, 0x7F, 0x85, 0xAD, 0x200B, 0x200C, 0x200D, 0x200E, 0x200F,
                                 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2060, 0x2066, 0x2067, 0x2068, 0x2069,
                                 0x061C, 0xFEFF, 0xE0041, 0xE007F]
        for cp in scalars {
            guard let scalar = Unicode.Scalar(cp) else { return XCTFail("U+\(cp)") }
            XCTAssertEqual(ApprovalDisplayModel.canonicalToken(forCodePoint: cp), Fx.invisibleToken(scalar),
                           "U+\(String(cp, radix: 16))")
        }
    }

    func testAnInvisibleRunWithItsCanonicalTokenIsVerified() throws {
        let request = try requestWithInvisibleRun(scalar: 0x202E, token: "⟨U+202E RLO⟩", cp: 0x202E)
        XCTAssertTrue(ApprovalDisplayModel(request: request).isVerified)
    }

    func testAnInvisibleRunWhoseTextIsNotItsCanonicalTokenIsAMismatch() throws {
        let cases: [(scalar: UInt32, token: String, cp: Int)] = [
            (0x202E, "ok", 0x202E),
            (0x2066, "⟨U+202E RLO⟩", 0x2066),
            (0x202E, "⟨U+202E LRO⟩", 0x202E),
            (0x202E, "⟨U+202E⟩", 0x202E),
            (0x202E, "⟨U+202e RLO⟩", 0x202E),
            (0x202E, "", 0x202E),
            (0x09, "⟨TAB⟩", 0x09),
            (0x09, "\t", 0x09),
            (0x0D, "⟨U+000D⟩", 0x0D),
            (0xE0041, "⟨U+E0041 TAG⟩", 0xE0041),
        ]
        for c in cases {
            let request = try requestWithInvisibleRun(scalar: c.scalar, token: c.token, cp: c.cp)
            assertMismatch(request, "text \(c.token.debugDescription) for U+\(String(c.cp, radix: 16))")
        }
    }

    // MARK: - A non-ASCII run must be the single scalar of its code point

    func testANonAsciiRunThatIsNotTheSingleScalarOfItsCodePointIsAMismatch() throws {
        let cases: [(command: String, text: String, cp: Int?)] = [
            ("rmx", "m", 0x043C),
            ("r\u{043C}x", "\u{043C}", nil),
            ("r\u{043C}x", "\u{043C}", 0x0430),
            ("r\u{043C}\u{043C}x", "\u{043C}\u{043C}", 0x043C),
            ("r\u{0430}x", "\u{0430}", 0x043C),
            ("rmx", "m", 0x6D),
        ]
        for c in cases {
            var run: Fx.Obj = ["text": c.text, "kind": "non_ascii"]
            if let cp = c.cp { run["cp"] = cp }
            let request = try Fx.bashRequest(c.command, lines: [
                Fx.line(1, "command", [Fx.plain("r"), run, Fx.plain("x")]),
            ])
            assertMismatch(request, "text \(c.text.debugDescription) cp \(String(describing: c.cp))")
        }
    }

    func testAFaithfulNonAsciiRunIsStillVerified() throws {
        let request = try Fx.bashRequest("r\u{043C}x", lines: [
            Fx.line(1, "command", [Fx.plain("r"), Fx.nonAscii("\u{043C}"), Fx.plain("x")]),
        ])
        XCTAssertTrue(ApprovalDisplayModel(request: request).isVerified)
    }

    // MARK: - Each tool's display holds only that tool's kinds of line

    func testABashDisplayWithALineThatIsNotPartOfACommandIsAMismatch() throws {
        for kind in ["file_header", "diff_del", "diff_add", "diff_ctx", "json", "future_kind"] {
            let request = try Fx.bashRequest("echo one\necho two", lines: [
                Fx.line(1, "command", [Fx.plain("echo one")]),
                Fx.line(2, kind, [Fx.plain("echo two")]),
            ])
            assertMismatch(request, "a \(kind) line in a Bash display")
        }
    }

    func testABashCommandShownEntirelyAsOtherKindsOfLineIsAMismatch() throws {
        for kind in ["file_header", "diff_del", "diff_add", "json"] {
            let request = try Fx.bashRequest("echo hi", lines: [Fx.line(1, kind, [Fx.plain("echo hi")])])
            assertMismatch(request, kind)
        }
    }

    func testAnMcpOrOtherToolDisplayWithAnyLineThatIsNotJsonIsAMismatch() throws {
        for toolKind in ["mcp", "other"] {
            let control = try jsonToolRequest(toolKind: toolKind, lines: Fx.jsonDisplayLines(Fx.mcpPretty))
            XCTAssertTrue(ApprovalDisplayModel(request: control).isVerified, "control for \(toolKind)")
            for kind in ["command", "file_header", "diff_add", "heredoc_body", "future_kind"] {
                var lines = Fx.jsonDisplayLines(Fx.mcpPretty)
                lines[1]["kind"] = kind
                assertMismatch(try jsonToolRequest(toolKind: toolKind, lines: lines), "\(toolKind) with a \(kind) line")
            }
        }
    }

    func testAFileToolDisplayThatIsFaithfulIsVerified() throws {
        for name in ["edit", "write", "notebook"] {
            XCTAssertTrue(ApprovalDisplayModel(request: try fileRequest(name)).isVerified, name)
        }
    }

    func testAFileToolDisplayWhoseFirstLineIsNotTheHeaderIsAMismatch() throws {
        for name in ["edit", "write", "notebook"] {
            assertMismatch(try fileRequest(name, headerFirst: false), name)
        }
    }

    func testAFileToolDisplayWithTwoHeadersIsAMismatch() throws {
        for name in ["edit", "write", "notebook"] {
            assertMismatch(try fileRequest(name, headers: 2), name)
        }
    }

    func testAFileToolDisplayWithNoHeaderIsAMismatch() throws {
        for name in ["edit", "write", "notebook"] {
            assertMismatch(try fileRequest(name, headers: 0), name)
        }
    }

    func testAWriteDisplayWithADeletionOrContextLineIsAMismatch() throws {
        for kind in ["diff_del", "diff_ctx"] {
            var body = fileTool("write").body
            body[2].kind = kind
            assertMismatch(try fileRequest("write", body: body), "a \(kind) line in a Write")
        }
    }

    func testAWriteDisplayWithAnExtraDeletionLineIsAMismatch() throws {
        var body = fileTool("write").body
        body.insert((kind: "diff_del", text: "removed"), at: 1)
        assertMismatch(try fileRequest("write", body: body))
    }

    // MARK: - NotebookEdit's new_source

    func testANotebookEditWithAStringNewSourceAndAFaithfulDisplayIsVerified() throws {
        XCTAssertTrue(ApprovalDisplayModel(request: try Fx.notebookEditRequest()).isVerified)
        let request = try Fx.request(
            toolKind: "notebook_edit", toolName: "NotebookEdit", displayName: "NotebookEdit",
            input: ["notebook_path": Fx.notebookPath, "new_source": "x = 1"],
            display: Fx.display(lines: Fx.fileDisplayLines(header: Fx.notebookPath,
                                                           body: [(kind: "diff_add", text: "x = 1")])))
        XCTAssertTrue(ApprovalDisplayModel(request: request).isVerified)
    }

    func testANotebookEditWhoseNewSourceIsNotAStringAndIsNotShownIsAMismatch() throws {
        let values: [Any] = [5, ["a", "b"] as [Any], true]
        for value in values {
            let request = try Fx.request(
                toolKind: "notebook_edit", toolName: "NotebookEdit", displayName: "NotebookEdit",
                input: ["notebook_path": Fx.notebookPath, "new_source": value],
                display: Fx.display(lines: Fx.fileDisplayLines(header: Fx.notebookPath, body: [])))
            assertMismatch(request, "new_source \(value)")
        }
    }

    // MARK: - A repeated key in the shown JSON is a mismatch

    func testShownJsonWithARepeatedKeyIsAMismatchInAnyObject() throws {
        let cases: [(name: String, input: Fx.Obj, pretty: String)] = [
            ("top level, last value is the input's", ["a": 2],
             "{\n  \"a\": 1,\n  \"a\": 2\n}"),
            ("top level, same value twice", ["a": 1],
             "{\n  \"a\": 1,\n  \"a\": 1\n}"),
            ("nested object", ["o": ["a": 2]],
             "{\n  \"o\": {\n    \"a\": 1,\n    \"a\": 2\n  }\n}"),
            ("object inside an array", ["l": [["a": 2]]],
             "{\n  \"l\": [\n    {\n      \"a\": 1,\n      \"a\": 2\n    }\n  ]\n}"),
            ("same key once unescaped", ["a": 2],
             "{\n  \"a\": 1,\n  \"\\u0061\": 2\n}"),
        ]
        for toolKind in ["mcp", "other"] {
            for c in cases {
                let request = try jsonToolRequest(toolKind: toolKind, input: c.input,
                                                  lines: Fx.jsonDisplayLines(c.pretty))
                assertMismatch(request, "\(toolKind): \(c.name)")
            }
        }
    }

    func testShownJsonThatReusesAKeyNameInDifferentObjectsIsStillVerified() throws {
        let input: Fx.Obj = ["a": ["a": 1], "b": ["a": 2], "l": [["a": 1], ["a": 2]]]
        let pretty = "{\n  \"a\": {\n    \"a\": 1\n  },\n  \"b\": {\n    \"a\": 2\n  },\n"
            + "  \"l\": [\n    {\n      \"a\": 1\n    },\n    {\n      \"a\": 2\n    }\n  ]\n}"
        for toolKind in ["mcp", "other"] {
            let request = try jsonToolRequest(toolKind: toolKind, input: input, lines: Fx.jsonDisplayLines(pretty))
            XCTAssertTrue(ApprovalDisplayModel(request: request).isVerified, toolKind)
        }
    }

    func testAKeyLookingTextInsideAStringValueIsNotARepeatedKey() throws {
        let input: Fx.Obj = ["text": "\"a\": 1, \"a\": 2", "a": 1]
        let pretty = "{\n  \"a\": 1,\n  \"text\": \"\\\"a\\\": 1, \\\"a\\\": 2\"\n}"
        let request = try jsonToolRequest(toolKind: "mcp", input: input, lines: Fx.jsonDisplayLines(pretty))
        XCTAssertTrue(ApprovalDisplayModel(request: request).isVerified)
    }

    func testFaithfulNestedJsonStaysVerified() throws {
        XCTAssertTrue(ApprovalDisplayModel(request: try Fx.mcpNestedRequest()).isVerified)
    }

    func testAnEditsExtrasWithARepeatedKeyAreAMismatch() throws {
        XCTAssertTrue(ApprovalDisplayModel(request: try Fx.editRequest(replaceAll: true)).isVerified, "control")
        assertMismatch(try Fx.editRequest(replaceAll: true,
                                          extraJSON: "{\n  \"replace_all\": false,\n  \"replace_all\": true\n}"))
    }

    func testAWritesExtrasWithARepeatedKeyAreAMismatch() throws {
        let faithful = "{\n  \"meta\": {\n    \"a\": 2\n  }\n}"
        XCTAssertTrue(ApprovalDisplayModel(request: try writeWithExtras(faithful)).isVerified, "control")
        assertMismatch(try writeWithExtras("{\n  \"meta\": {\n    \"a\": 1,\n    \"a\": 2\n  }\n}"),
                       "repeated inside a nested object")
        assertMismatch(try writeWithExtras("{\n  \"meta\": {\n    \"a\": 2\n  },\n  \"meta\": {\n    \"a\": 2\n  }\n}"),
                       "repeated at the top")
    }

    // MARK: - Helpers

    private func requestWithInvisibleRun(scalar: UInt32, token: String, cp: Int?) throws -> ApprovalRequestWire {
        let character = try XCTUnwrap(Unicode.Scalar(scalar))
        var command = "echo "
        command.unicodeScalars.append(character)
        command += "x"
        return try Fx.bashRequest(command, lines: [
            Fx.line(1, "command", [Fx.plain("echo "), Fx.invisible(token: token, cp: cp), Fx.plain("x")]),
        ])
    }

    private func jsonToolRequest(toolKind: String, input: Fx.Obj = ["channel": "#general", "text": "hello team"],
                                 lines: [Fx.Obj]) throws -> ApprovalRequestWire {
        try Fx.request(toolKind: toolKind,
                       toolName: toolKind == "mcp" ? "mcp__slack__send_message" : "WebFetch",
                       displayName: "Tool", input: input, display: Fx.display(lines: lines))
    }

    private typealias BodyLine = (kind: String, text: String)

    /// What each file tool's input, header and diff body look like when the display is faithful.
    private func fileTool(_ name: String) -> (toolKind: String, toolName: String, input: Fx.Obj,
                                              header: String, body: [BodyLine]) {
        switch name {
        case "edit":
            return ("edit", "Edit",
                    ["file_path": Fx.editPath, "old_string": Fx.editOld, "new_string": Fx.editNew],
                    Fx.editPath, Fx.editDiff)
        case "write":
            return ("write", "Write", ["file_path": Fx.writePath, "content": Fx.writeContent],
                    Fx.writePath, Fx.splitLines(Fx.writeContent).map { (kind: "diff_add", text: $0) })
        default:
            return ("notebook_edit", "NotebookEdit",
                    ["notebook_path": Fx.notebookPath, "new_source": Fx.notebookSource],
                    Fx.notebookPath, Fx.splitLines(Fx.notebookSource).map { (kind: "diff_add", text: $0) })
        }
    }

    /// A file-tool request; the defaults are faithful, the parameters bend the display.
    private func fileRequest(_ name: String, headerFirst: Bool = true, headers: Int = 1,
                             body: [BodyLine]? = nil) throws -> ApprovalRequestWire {
        let tool = fileTool(name)
        var b = Fx.DisplayBuilder()
        if headerFirst { for _ in 0..<headers { b.text("file_header", tool.header) } }
        for item in body ?? tool.body { b.text(item.kind, item.text) }
        if !headerFirst { for _ in 0..<headers { b.text("file_header", tool.header) } }
        return try Fx.request(toolKind: tool.toolKind, toolName: tool.toolName, displayName: tool.toolName,
                              input: tool.input, display: Fx.display(lines: b.lines))
    }

    /// A Write whose input also has `meta: {"a": 2}`; `extraJSON` is what the display shows for it.
    private func writeWithExtras(_ extraJSON: String) throws -> ApprovalRequestWire {
        let body = Fx.splitLines(Fx.writeContent).map { (kind: "diff_add", text: $0) }
        return try Fx.request(
            toolKind: "write", toolName: "Write", displayName: "Write",
            input: ["file_path": Fx.writePath, "content": Fx.writeContent, "meta": ["a": 2]],
            display: Fx.display(lines: Fx.fileDisplayLines(header: Fx.writePath, body: body, extraJSON: extraJSON)))
    }

    private func assertMismatch(_ request: ApprovalRequestWire, _ message: String = "",
                                file: StaticString = #filePath, line: UInt = #line) {
        let model = ApprovalDisplayModel(request: request)
        XCTAssertFalse(model.isVerified, "isVerified should be false. \(message)", file: file, line: line)
        if case .mismatch = model.roundTrip { return }
        XCTFail("expected .mismatch, got \(model.roundTrip). \(message)", file: file, line: line)
    }

    private func assertNoEscapeByte(_ model: ApprovalDisplayModel,
                                    file: StaticString = #filePath, line: UInt = #line) {
        for l in model.lines {
            for run in l.runs {
                XCTAssertFalse(run.text.unicodeScalars.contains("\u{1B}"), "run text: \(run.text)", file: file, line: line)
            }
        }
        XCTAssertFalse(model.shownText.unicodeScalars.contains("\u{1B}"), file: file, line: line)
        for l in model.lines {
            XCTAssertFalse(l.spokenText.unicodeScalars.contains("\u{1B}"), file: file, line: line)
        }
    }

    /// Everything the daemon's `is_invisible` covers and the bytes a command can carry, plus
    /// ASCII, newlines, combining and precomposed accents and Cyrillic.
    private static let randomAlphabet: [String] = [
        "a", "b", "z", "0", "9", " ", "-", "/", ".", "_", "x",
        "\n", "\n", "\t", "\r",
        "\u{202E}", "\u{2066}", "\u{2069}", "\u{200B}", "\u{200D}", "\u{FEFF}", "\u{00AD}", "\u{2028}",
        "\u{E0041}", "\u{E007F}", "\u{FE0F}", "\u{3164}", "\u{1B}", "\u{7F}", "\u{85}",
        "\u{00E9}", "e\u{0301}", "e", "\u{043C}", "\u{0430}", "\u{4E2D}", "\u{1F600}",
    ]

    private func randomText(_ rng: inout ApprovalSeededGenerator, minLength: Int = 0) -> String {
        let length = Int.random(in: minLength...40, using: &rng)
        var text = ""
        for _ in 0..<length {
            text += Self.randomAlphabet[Int.random(in: 0..<Self.randomAlphabet.count, using: &rng)]
        }
        return text
    }
}

/// SplitMix64: deterministic, no clock, so a failing case reproduces.
private struct ApprovalSeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
