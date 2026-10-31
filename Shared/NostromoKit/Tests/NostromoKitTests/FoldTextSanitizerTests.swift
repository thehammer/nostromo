import XCTest
import NostromoKit

/// Text drawn on a group row (contract §2.2): no escapes, controls, bidi tricks or tag
/// characters, one line, at most 512 UTF-16 units. Copy Commands is the opposite: verbatim.
final class FoldTextSanitizerTests: XCTestCase {

    private func sanitize(_ text: String) -> String { FoldTextSanitizer.sanitize(text) }

    // MARK: Hostile sweep

    func testNoHostileStringSurvivesWithAnythingUnsafeToDraw() {
        for hostile in HostileContent.all {
            let out = sanitize(hostile)

            XCTAssertNil(out.unicodeScalars.first(where: HostileContent.isForbiddenOnARow),
                         "forbidden scalar survived from a \(hostile.utf8.count)-byte input")
            XCTAssertFalse(out.contains("\n") || out.contains("\r") || out.contains("\t"))
        }
    }

    func testNoHostileStringProducesMoreThan512UTF16Units() {
        for hostile in HostileContent.all {
            XCTAssertLessThanOrEqual(sanitize(hostile).utf16.count, FoldTextSanitizer.maxUTF16)
        }
    }

    func testTheCapIs512UTF16Units() {
        XCTAssertEqual(FoldTextSanitizer.maxUTF16, 512)
    }

    func testTheTenThousandCharacterCommandIsCutToExactly512Units() {
        let out = sanitize(HostileContent.longCommand)

        XCTAssertEqual(HostileContent.longCommand.utf16.count, 10_000)
        XCTAssertEqual(out.utf16.count, 512)
        XCTAssertTrue(out.hasPrefix("echo xxxx"))
    }

    func testTheMegabyteResultIsCutToTheCapAndKeepsItsStart() {
        let out = sanitize(HostileContent.megabyteResult)

        XCTAssertLessThanOrEqual(out.utf16.count, 512)
        XCTAssertTrue(out.hasPrefix("0123456789abcde"))
    }

    // MARK: Stripping

    func testAnsiColourEscapesAreRemovedAndTheTextKept() {
        XCTAssertEqual(sanitize("\u{1B}[31mred\u{1B}[0m"), "red")
        XCTAssertEqual(sanitize(HostileContent.ansiColour), "red text and green")
    }

    func testOSC8HyperlinksReduceToTheirLabel() {
        XCTAssertEqual(sanitize(HostileContent.osc8Hyperlink), "label")
    }

    func testBELTerminatedOSC8HyperlinksReduceToTheirLabel() {
        XCTAssertEqual(sanitize(HostileContent.osc8HyperlinkBEL), "label")
    }

    func testBidiOverridesAndIsolatesAreRemovedAroundTheTextTheyWrap() {
        let out = sanitize(HostileContent.bidi)

        XCTAssertTrue(out.hasPrefix("safe"), out)
        XCTAssertTrue(out.hasSuffix("tail"), out)
        XCTAssertTrue(out.contains("evil") && out.contains("iso") && out.contains("rtl") && out.contains("fsi"), out)
    }

    func testTagCharactersAreRemovedAndTheVisibleTextKept() {
        XCTAssertEqual(sanitize(HostileContent.tagCharacters), "tagged")
    }

    func testNulAndC1ControlsAreRemovedAndTheSurroundingTextKept() {
        let nul = sanitize(HostileContent.nul)
        let c1 = sanitize(HostileContent.c1Controls)

        XCTAssertTrue(nul.hasPrefix("before") && nul.hasSuffix("after"), nul)
        // (An 8-bit string introducer in the C1 run may legitimately swallow what follows it.)
        XCTAssertTrue(c1.hasPrefix("a"), c1)
    }

    func testNewlinesAndTabsBecomeSpaces() {
        XCTAssertEqual(sanitize("a\nb\tc"), "a b c")
    }

    func testAMultiLineCommandBecomesOneLine() {
        let out = sanitize("cargo build \\\n  --release\ncargo test")

        XCTAssertFalse(out.contains("\n"))
        XCTAssertTrue(out.hasPrefix("cargo build"))
        XCTAssertTrue(out.hasSuffix("cargo test"))
    }

    // MARK: Leaving good text alone

    func testPlainTextIsUnchanged() {
        XCTAssertEqual(sanitize("cargo test --workspace"), "cargo test --workspace")
        XCTAssertEqual(sanitize(""), "")
    }

    func testOrdinaryUnicodeIsUnchanged() {
        let text = "résumé — 日本語 🚀 ünïcode · naïve"

        XCTAssertEqual(sanitize(text), text)
    }

    func testTextAtExactlyTheCapIsUnchangedAndOneOverIsCut() {
        let atCap = String(repeating: "a", count: 512)

        XCTAssertEqual(sanitize(atCap), atCap)
        XCTAssertEqual(sanitize(atCap + "b").utf16.count, 512)
    }

    // MARK: Cutting never breaks a character

    func testSixHundredEmojiAreCutOnACharacterBoundaryAndFillTheCap() {
        let out = sanitize(String(repeating: "😀", count: 600))

        XCTAssertEqual(out.utf16.count, 512)
        XCTAssertEqual(out, String(repeating: "😀", count: 256))
        XCTAssertFalse(out.unicodeScalars.contains("\u{FFFD}"))
    }

    func testACutThatLandsMidSurrogatePairDropsTheWholeCharacter() {
        // One ASCII unit, then pairs: the 512th unit would be half of an emoji.
        let out = sanitize("a" + String(repeating: "😀", count: 600))

        XCTAssertLessThanOrEqual(out.utf16.count, 512)
        XCTAssertGreaterThanOrEqual(out.utf16.count, 511)
        XCTAssertFalse(out.unicodeScalars.contains("\u{FFFD}"))
        XCTAssertEqual(out, "a" + String(repeating: "😀", count: (out.utf16.count - 1) / 2))
    }

    // MARK: Copy stays verbatim

    func testCopyCommandsKeepsAHostileBashCommandByteIdenticalWhileTheRowTextIsSanitized() {
        let hostile = HostileContent.kitchenSink
        let input = String(decoding: try! JSONSerialization.data(withJSONObject: ["command": hostile]), as: UTF8.self)
        let blocks: [FoldBlock] = [.toolCall(FoldCall(name: "Bash", toolUseId: "h", inputSummary: hostile, inputFull: input)),
                                   .toolResult(FoldResult(toolUseId: "h"))]
        let items = ToolFoldPlanner.plan(blocks: blocks, outcome: .completedOk, turnKey: "T")
        guard case .group(let g)? = items.first else { return XCTFail("no group") }

        let copied = ToolGroupSummary.commandsText(for: g, payloadAvailable: true)
        let header = ToolGroupSummary.header(for: g.calls[0])

        XCTAssertEqual(Array(copied.utf8), Array(hostile.utf8))
        XCTAssertNil(header.unicodeScalars.first(where: HostileContent.isForbiddenOnARow))
    }
}

/// Review follow-ups (Perri, TF2).
final class FoldTextSanitizerEdgeTests: XCTestCase {

    func testNELBecomesASpaceLikeANewline() {
        XCTAssertEqual(FoldTextSanitizer.sanitize("a\u{85}b"), "a b")
    }

    func testInvisibleFormatCharactersAreDroppedButJoinersStay() {
        XCTAssertEqual(FoldTextSanitizer.sanitize("a\u{200B}b\u{2060}c\u{FEFF}d\u{FFF9}e"), "abcde")
        let family = "👩\u{200D}👩\u{200D}👧"
        XCTAssertEqual(FoldTextSanitizer.sanitize(family), family)
    }

    /// A string control with no terminator is not a sequence: it must not hide the rest
    /// of the command from the row.
    func testAnUnterminatedStringControlCannotHideWhatFollows() {
        XCTAssertEqual(FoldTextSanitizer.sanitize("ls \u{98}; rm -rf /"), "ls ; rm -rf /")
        XCTAssertEqual(FoldTextSanitizer.sanitize("ls \u{1B}]0; rm -rf /"), "ls 0; rm -rf /")
        XCTAssertEqual(FoldTextSanitizer.sanitize("ls \u{1B}P; rm -rf /"), "ls ; rm -rf /")
    }

    func testAnOverlongSequenceIsNotSwallowedWhole() {
        let body = String(repeating: "x", count: FoldTextSanitizer.maxSequenceLength + 10)
        let out = FoldTextSanitizer.sanitize("\u{1B}]" + body + "\u{07}tail")
        XCTAssertTrue(out.hasPrefix("xxxx"), "the would-be body is drawn")
        XCTAssertFalse(out.unicodeScalars.contains { $0.value == 0x1B || $0.value == 0x07 })
    }

    func testAnUnfinishedCSIDrawsItsText() {
        XCTAssertEqual(FoldTextSanitizer.sanitize("a\u{1B}[12;é rest"), "a12;é rest", "é cannot be in a CSI body")
    }

    func testACharsetDesignatorIsDroppedWhole() {
        XCTAssertEqual(FoldTextSanitizer.sanitize("a\u{1B}(Bb"), "ab")
    }

    func testTheCapNeverLeavesHalfAGraphemeCluster() {
        let family = "👩\u{200D}👩\u{200D}👧"   // 8 UTF-16 units, one character
        let text = String(repeating: "x", count: 508) + family
        let out = FoldTextSanitizer.sanitize(text)
        XCTAssertEqual(out, String(repeating: "x", count: 508))
        XCTAssertLessThanOrEqual(out.utf16.count, FoldTextSanitizer.maxUTF16)
    }
}

/// Plan viewer additions: the invisible filler scalars, and the inline / multiline variants
/// (no length cap) used for plan text.
final class FoldTextSanitizerFillerAndModeTests: XCTestCase {

    private static let fillerScalars: [Unicode.Scalar] = [
        "\u{034F}", "\u{115F}", "\u{1160}", "\u{17B4}", "\u{17B5}", "\u{2800}", "\u{3164}", "\u{FFA0}",
    ]

    private func hex(_ scalar: Unicode.Scalar) -> String { "U+" + String(scalar.value, radix: 16, uppercase: true) }

    /// Controls and invisibles that must never survive any mode, with `\n` and `\t` exempt.
    private func hasForbiddenScalarOtherThanNewlineAndTab(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value != 0x0A && $0.value != 0x09 && HostileContent.isForbiddenOnARow($0) }
    }

    // MARK: Fillers

    func testEachFillerScalarIsDroppedByEveryMode() {
        for filler in Self.fillerScalars {
            let input = "a\(filler)b"

            XCTAssertEqual(FoldTextSanitizer.sanitize(input), "ab", "sanitize \(hex(filler))")
            XCTAssertEqual(FoldTextSanitizer.sanitizeInline(input), "ab", "sanitizeInline \(hex(filler))")
            XCTAssertEqual(FoldTextSanitizer.sanitizeMultiline(input), "ab", "sanitizeMultiline \(hex(filler))")
        }
    }

    func testAllFillersTogetherLeaveOnlyTheVisibleText() {
        let out = [FoldTextSanitizer.sanitize(HostileContent.fillers),
                   FoldTextSanitizer.sanitizeInline(HostileContent.fillers),
                   FoldTextSanitizer.sanitizeMultiline(HostileContent.fillers)]

        XCTAssertEqual(out, ["abcdefghi", "abcdefghi", "abcdefghi"])
    }

    func testAStringOfOnlyFillersBecomesEmpty() {
        let only = String(String.UnicodeScalarView(Self.fillerScalars))

        XCTAssertEqual(FoldTextSanitizer.sanitize(only), "")
        XCTAssertEqual(FoldTextSanitizer.sanitizeInline(only), "")
        XCTAssertEqual(FoldTextSanitizer.sanitizeMultiline(only), "")
    }

    // MARK: sanitizeInline

    func testInlineHasNoLengthCap() {
        let long = String(repeating: "a", count: 5_000)

        XCTAssertEqual(FoldTextSanitizer.sanitizeInline(long), long)
        XCTAssertEqual(FoldTextSanitizer.sanitizeInline(long).utf16.count, 5_000)
    }

    func testInlineTurnsEveryLineBreakAndTabIntoASpace() {
        XCTAssertEqual(FoldTextSanitizer.sanitizeInline("a\nb"), "a b")
        XCTAssertEqual(FoldTextSanitizer.sanitizeInline("a\tb"), "a b")
        XCTAssertEqual(FoldTextSanitizer.sanitizeInline("a\u{85}b"), "a b")
        XCTAssertEqual(FoldTextSanitizer.sanitizeInline("a\u{2028}b"), "a b")
        XCTAssertEqual(FoldTextSanitizer.sanitizeInline("a\u{2029}b"), "a b")
        XCTAssertEqual(FoldTextSanitizer.sanitizeInline("a\nb\tc"), "a b c")
    }

    func testInlineOutputIsAlwaysOneLine() {
        for hostile in HostileContent.all {
            let out = FoldTextSanitizer.sanitizeInline(hostile)

            XCTAssertNil(out.unicodeScalars.first(where: HostileContent.isForbiddenOnARow),
                         "forbidden scalar survived from a \(hostile.utf8.count)-byte input")
            XCTAssertFalse(out.contains("\n") || out.contains("\r") || out.contains("\t"))
        }
    }

    func testInlineStripsEscapeSequencesLikeTheRowSanitizer() {
        XCTAssertEqual(FoldTextSanitizer.sanitizeInline(HostileContent.ansiColour), "red text and green")
        XCTAssertEqual(FoldTextSanitizer.sanitizeInline(HostileContent.osc8Hyperlink), "label")
        XCTAssertEqual(FoldTextSanitizer.sanitizeInline(HostileContent.tagCharacters), "tagged")
    }

    func testInlineLeavesOrdinaryAndJoinedUnicodeAlone() {
        let text = "résumé — 日本語 🚀 👩\u{200D}👩\u{200D}👧"

        XCTAssertEqual(FoldTextSanitizer.sanitizeInline(text), text)
        XCTAssertEqual(FoldTextSanitizer.sanitizeInline(""), "")
    }

    // MARK: sanitizeMultiline

    func testMultilineKeepsNewlinesAndTabs() {
        XCTAssertEqual(FoldTextSanitizer.sanitizeMultiline("a\n\tb\nc"), "a\n\tb\nc")
        XCTAssertEqual(FoldTextSanitizer.sanitizeMultiline("\n\n"), "\n\n")
    }

    func testMultilineTurnsCRLFIntoANewlineAndALoneCRIntoASpace() {
        XCTAssertEqual(FoldTextSanitizer.sanitizeMultiline("a\r\nb"), "a\nb")
        XCTAssertEqual(FoldTextSanitizer.sanitizeMultiline("a\rb"), "a b")
        XCTAssertEqual(FoldTextSanitizer.sanitizeMultiline("a\r\nb\rc\r\n"), "a\nb c\n")
    }

    func testMultilineTurnsUnicodeLineSeparatorsAndNELIntoSpaces() {
        XCTAssertEqual(FoldTextSanitizer.sanitizeMultiline("a\u{2028}b"), "a b")
        XCTAssertEqual(FoldTextSanitizer.sanitizeMultiline("a\u{2029}b"), "a b")
        XCTAssertEqual(FoldTextSanitizer.sanitizeMultiline("a\u{85}b"), "a b")
    }

    func testMultilineStripsAnsiAndOSCSequencesAndKeepsTheText() {
        XCTAssertEqual(FoldTextSanitizer.sanitizeMultiline(HostileContent.ansiColour), "red text and green")
        XCTAssertEqual(FoldTextSanitizer.sanitizeMultiline(HostileContent.osc8Hyperlink), "label")
        XCTAssertEqual(FoldTextSanitizer.sanitizeMultiline(HostileContent.osc8HyperlinkBEL), "label")
        XCTAssertEqual(FoldTextSanitizer.sanitizeMultiline("line one\n\u{1B}[31mline two\u{1B}[0m\n"), "line one\nline two\n")
    }

    func testMultilineDropsControlsBidiZeroWidthAndTagsButKeepsTheWordsAround() {
        XCTAssertEqual(FoldTextSanitizer.sanitizeMultiline("a\u{0}b\u{7F}c\u{8}d\u{80}e"), "abcde")
        XCTAssertEqual(FoldTextSanitizer.sanitizeMultiline("a\u{200B}b\u{2060}c\u{FEFF}d\u{FFF9}e"), "abcde")
        XCTAssertEqual(FoldTextSanitizer.sanitizeMultiline(HostileContent.tagCharacters), "tagged")
        let bidi = FoldTextSanitizer.sanitizeMultiline(HostileContent.bidi)
        XCTAssertTrue(bidi.hasPrefix("safe") && bidi.hasSuffix("tail"), bidi)
    }

    func testMultilineOutputOfAnyHostileStringHasNothingButNewlinesAndTabsOfTheControls() {
        for hostile in HostileContent.all {
            let out = FoldTextSanitizer.sanitizeMultiline(hostile)

            XCTAssertFalse(hasForbiddenScalarOtherThanNewlineAndTab(out),
                           "forbidden scalar survived from a \(hostile.utf8.count)-byte input")
            XCTAssertFalse(out.unicodeScalars.contains { $0.value == 0x0D })
        }
    }

    func testMultilineHasNoLengthCapAndKeepsAMegabyteOfLines() {
        let long = String(repeating: "a", count: 5_000)
        XCTAssertEqual(FoldTextSanitizer.sanitizeMultiline(long), long)

        let big = HostileContent.megabyteResult
        let out = FoldTextSanitizer.sanitizeMultiline(big)
        XCTAssertEqual(out.utf8.count, big.utf8.count)
        XCTAssertEqual(out.utf8.filter { $0 == 0x0A }.count, 65_536)
    }

    func testMultilineLeavesOrdinaryAndJoinedUnicodeAlone() {
        let text = "résumé — 日本語 🚀 👩\u{200D}👩\u{200D}👧\n\tindented"

        XCTAssertEqual(FoldTextSanitizer.sanitizeMultiline(text), text)
        XCTAssertEqual(FoldTextSanitizer.sanitizeMultiline(""), "")
    }

    // MARK: The row sanitizer keeps its contract

    func testTheRowSanitizerStillCapsAt512AfterTheFillerChange() {
        let out = FoldTextSanitizer.sanitize(String(repeating: "a\u{3164}", count: 2_000))

        XCTAssertEqual(out, String(repeating: "a", count: 512))
    }
}

// MARK: - Document text is stricter than a row (MF4 fix-up)

/// `sanitizeInline` and `sanitizeMultiline` (a plan's paragraphs, code and checklist) are STRICT; `sanitize`
/// (a row) is not. In document text:
///   - U+00AD, U+180E, U+FE00...FE0D and U+E0100...E01EF are gone;
///   - U+FE0E / U+FE0F stay only straight after an emoji (and after a keycap base before U+20E3);
///   - U+200D / U+200C stay only between two non-ASCII scalars that are not joiners themselves.
/// So no joiner or selector can hide inside a word, a path or a command, while emoji sequences and the
/// scripts that need a joiner still draw.
final class FoldTextSanitizerDocumentTextTests: XCTestCase {

    private let zwj = "\u{200D}"
    private let zwnj = "\u{200C}"
    private let vs16 = "\u{FE0F}"
    private let vs15 = "\u{FE0E}"
    private let eAcute = "\u{00E9}"

    private func inline(_ s: String) -> String { FoldTextSanitizer.sanitizeInline(s) }
    private func multi(_ s: String) -> String { FoldTextSanitizer.sanitizeMultiline(s) }
    private func row(_ s: String) -> String { FoldTextSanitizer.sanitize(s) }

    private func hex(_ s: String) -> String { s.unicodeScalars.map { "U+" + String($0.value, radix: 16, uppercase: true) }.joined(separator: " ") }

    /// Both document modes give `expected` for `input` (the input has no line breaks, so they agree).
    private func assertBoth(_ input: String, _ expected: String, _ why: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(inline(input), expected, "inline: \(hex(input)) \(why)", file: file, line: line)
        XCTAssertEqual(multi(input), expected, "multiline: \(hex(input)) \(why)", file: file, line: line)
    }

    private func isJoiner(_ s: Unicode.Scalar) -> Bool { s.value == 0x200C || s.value == 0x200D }
    private func isAlwaysGone(_ v: UInt32) -> Bool {
        v == 0x00AD || v == 0x180E || (0xFE00 ... 0xFE0D).contains(v) || (0xE0100 ... 0xE01EF).contains(v)
    }

    // MARK: Scalars that draw nothing

    func testSoftHyphenMongolianSeparatorAndVariationSelectorsAreRemovedFromDocumentText() {
        var scalars: [UInt32] = [0x00AD, 0x180E]
        scalars += Array(0xFE00 ... 0xFE0D)
        scalars += Array(0xE0100 ... 0xE01EF)
        for value in scalars {
            let s = String(Unicode.Scalar(value)!)
            assertBoth("a\(s)b", "ab", "between ASCII")
            assertBoth("\(eAcute)\(s)\(eAcute)", "\(eAcute)\(eAcute)", "between non-ASCII")
            assertBoth("\(s)x\(s)", "x", "at both ends")
        }
    }

    func testScalarsJustOutsideTheRemovedRangesAreLeftAlone() {
        for value: UInt32 in [0x00AC, 0x00AE, 0xFE10, 0xE01F0] {
            let s = "a" + String(Unicode.Scalar(value)!) + "b"
            assertBoth(s, s, "U+\(String(value, radix: 16, uppercase: true)) is not one of them")
        }
    }

    func testARowKeepsEverythingDocumentTextDrops() {
        // Row mode did not change: these are what it has always kept.
        let kept = ["a\u{00AD}b", "a\u{180E}b", "a\u{FE00}b", "a\u{E0100}b", "\u{2764}\u{FE0F}", "a\(vs16)", "a\(vs15)b",
                    "a\(zwj)b", "a\(zwnj)b", "\(zwj)\(eAcute)", "\(eAcute)\(zwj)", "\(eAcute)\(zwj)\(zwj)\(eAcute)"]
        for text in kept {
            XCTAssertEqual(row(text), text, "a row keeps \(hex(text))")
        }
        XCTAssertEqual(row("👩\(zwj)👩\(zwj)👧"), "👩\(zwj)👩\(zwj)👧")
    }

    // MARK: U+FE0F and U+FE0E (text and emoji presentation)

    func testASelectorStraightAfterAnEmojiIsKept() {
        for emoji in ["\u{2764}", "\u{2714}", "\u{00A9}", "\u{00AE}", "\u{2122}", "\u{1F441}", "\u{263A}"] {
            assertBoth("\(emoji)\(vs16)", "\(emoji)\(vs16)", "emoji presentation of U+\(String(emoji.unicodeScalars.first!.value, radix: 16, uppercase: true))")
            assertBoth("\(emoji)\(vs15)", "\(emoji)\(vs15)", "text presentation")
        }
        assertBoth("I \u{2764}\(vs16) it", "I \u{2764}\(vs16) it")
        assertBoth("\u{2714}\(vs15) done", "\u{2714}\(vs15) done")
    }

    func testASelectorAfterAnythingElseIsDropped() {
        assertBoth("a\(vs16)", "a", "after an ASCII letter")
        assertBoth("a\(vs15)", "a")
        assertBoth("1\(vs16)", "1", "after an ASCII digit")
        assertBoth("#\(vs16)", "#", "after an ASCII emoji base that is not a keycap")
        assertBoth("x \(vs16)y", "x y", "after a space")
        assertBoth("\(eAcute)\(vs16)", eAcute, "after a letter that is not an emoji")
        assertBoth("\u{65E5}\(vs16)", "\u{65E5}", "after a CJK character")
    }

    func testASelectorAtTheStartOfTheTextIsDropped() {
        assertBoth("\(vs16)", "")
        assertBoth("\(vs15)", "")
        assertBoth("\(vs16)x", "x")
        assertBoth("\(vs15)\u{2764}", "\u{2764}")
    }

    func testASelectorAfterAJoinerIsDropped() {
        // the selector sits right after the joiner (not after an emoji), so it goes; the joiner stays between the emoji
        assertBoth("👩\(zwj)\(vs16)👩", "👩\(zwj)👩")
        assertBoth("a\(zwj)\(vs16)b", "ab")
    }

    func testAKeycapKeepsItsSelector() {
        for base in ["0", "1", "5", "9", "#", "*"] {
            assertBoth("\(base)\(vs16)\u{20E3}", "\(base)\(vs16)\u{20E3}", "keycap \(base)")
        }
        assertBoth("press 1\(vs16)\u{20E3} now", "press 1\(vs16)\u{20E3} now")
        // not a keycap: the selector goes and the combining mark that follows stays
        assertBoth("a\(vs16)\u{20E3}", "a\u{20E3}")
    }

    // MARK: ZWJ and ZWNJ

    func testAJoinerBetweenEmojiIsKept() {
        let family = "👩\(zwj)👩\(zwj)👧"
        let eye = "👁\(vs16)\(zwj)🗨\(vs16)"
        let flag = "🏳\(vs16)\(zwj)🌈"
        for text in [family, eye, flag, "text \(family) text", "👩\(zwnj)👩"] {
            assertBoth(text, text, "an emoji sequence")
        }
    }

    func testAJoinerBetweenTwoNonASCIILettersIsKept() {
        let persian = "\u{0645}\u{06CC}\(zwnj)\u{062E}\u{0648}\u{0627}\u{0647}\u{0645}"   // می‌خواهم
        let hindi = "\u{0915}\u{094D}\(zwj)\u{0937}"                                           // क्‍ष
        assertBoth(persian, persian, "Persian needs its ZWNJ")
        assertBoth(hindi, hindi, "Devanagari needs its ZWJ")
        assertBoth("\(eAcute)\(zwj)\(eAcute)", "\(eAcute)\(zwj)\(eAcute)", "any two non-ASCII scalars")
    }

    func testAJoinerNextToAnASCIIScalarIsDropped() {
        assertBoth("a\(zwj)b", "ab")
        assertBoth("a\(zwnj)b", "ab")
        assertBoth("\(eAcute)\(zwj)b", "\(eAcute)b", "ASCII after")
        assertBoth("a\(zwnj)\(eAcute)", "a\(eAcute)", "ASCII before")
        assertBoth("rm\(zwj)-rf", "rm-rf")
        assertBoth("/usr\(zwnj)/bin", "/usr/bin")
        assertBoth("\(eAcute)\(zwj) \(eAcute)", "\(eAcute) \(eAcute)", "a space is ASCII")
        assertBoth("\(eAcute)\(zwj)1", "\(eAcute)1")
    }

    func testAJoinerAtTheStartOrTheEndIsDropped() {
        for joiner in [zwj, zwnj] {
            assertBoth("\(joiner)\(eAcute)", eAcute, "at the start")
            assertBoth("\(eAcute)\(joiner)", eAcute, "at the end")
            assertBoth(joiner, "", "alone")
            assertBoth("\(joiner)\(joiner)", "", "only joiners")
        }
    }

    func testAJoinerAtALineEdgeIsDropped() {
        // a line break is ASCII: in a code block the joiner at the end of a line is next to it
        XCTAssertEqual(multi("\(eAcute)\(zwj)\n\(eAcute)"), "\(eAcute)\n\(eAcute)")
        XCTAssertEqual(multi("\(eAcute)\n\(zwj)\(eAcute)"), "\(eAcute)\n\(eAcute)")
        XCTAssertEqual(multi("\(eAcute)\(zwj)\t\(eAcute)"), "\(eAcute)\t\(eAcute)")
        // inline: the break becomes a space first, and a space is ASCII too
        XCTAssertEqual(inline("\(eAcute)\(zwj)\n\(eAcute)"), "\(eAcute) \(eAcute)")
    }

    func testTwoJoinersInARowNeverBothSurvive() {
        // Between two non-ASCII scalars one of the pair may stay (the first); never two, and never one at an edge.
        for pair in ["\(zwj)\(zwj)", "\(zwj)\(zwnj)", "\(zwnj)\(zwj)", "\(zwnj)\(zwnj)", "\(zwj)\(zwj)\(zwj)"] {
            for text in [inline("\(eAcute)\(pair)\(eAcute)"), multi("\(eAcute)\(pair)\(eAcute)")] {
                XCTAssertLessThanOrEqual(text.unicodeScalars.filter(isJoiner).count, 1, "\(hex(pair)) between letters: \(hex(text))")
                XCTAssertTrue(text.hasPrefix(eAcute) && text.hasSuffix(eAcute), hex(text))
            }
            assertBoth("\(eAcute)\(pair)", eAcute, "joiners at the end")
            assertBoth("\(eAcute)\(pair)b", "\(eAcute)b", "joiners before ASCII")
            assertBoth("a\(pair)\(eAcute)", "a\(eAcute)", "joiners after ASCII")
        }
    }

    func testAJoinerFollowedByTextThatIsDroppedIsJudgedByWhatSurvives() {
        // U+200B is dropped by every mode before the joiner rule looks: the joiner then meets the ASCII
        assertBoth("\(eAcute)\(zwj)\u{200B}x", "\(eAcute)x")
        assertBoth("\(eAcute)\(zwj)\u{3164}x", "\(eAcute)x")
        // a soft hyphen is skipped over: what the joiner sits between is what is left
        assertBoth("\(eAcute)\(zwj)\u{00AD}x", "\(eAcute)x", "ASCII follows the soft hyphen")
        assertBoth("a\u{00AD}\(zwj)\(eAcute)", "a\(eAcute)", "ASCII precedes the soft hyphen")
        assertBoth("\(eAcute)\(zwj)\u{00AD}\(eAcute)", "\(eAcute)\(zwj)\(eAcute)", "non-ASCII on both sides of what was dropped")
        assertBoth("\(eAcute)\u{00AD}\(zwj)\(eAcute)", "\(eAcute)\(zwj)\(eAcute)")
    }

    // MARK: Whole-text properties

    private struct SplitMix {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private static let alphabet: [String] = [
        "a", "b", "1", "#", " ", "\n", "\u{00E9}", "\u{65E5}", "\u{0645}", "👩", "👧", "\u{2764}", "\u{1F441}",
        "\u{FE0F}", "\u{FE0E}", "\u{200D}", "\u{200C}", "\u{00AD}", "\u{180E}", "\u{20E3}", "\u{200B}", "\u{3164}",
        "\u{FE00}", "\u{FE0D}", "\u{E0100}", "\u{E01EF}",
    ]

    /// A few thousand strings over the alphabet above, the same ones every run.
    private func corpus() -> [String] {
        var rng = SplitMix(state: 0xC0FFEE)
        var out: [String] = []
        for _ in 0 ..< 4_000 {
            let length = 1 + Int(rng.next() % 10)
            out.append((0 ..< length).map { _ in Self.alphabet[Int(rng.next() % UInt64(Self.alphabet.count))] }.joined())
        }
        out += HostileContent.all.filter { $0.utf8.count < 100_000 }
        return out
    }

    func testSanitizingTwiceChangesNothing() {
        for text in corpus() {
            let i = inline(text)
            XCTAssertEqual(inline(i), i, "inline is not idempotent for \(hex(text))")
            let m = multi(text)
            XCTAssertEqual(multi(m), m, "multiline is not idempotent for \(hex(text))")
        }
    }

    func testEverySurvivingJoinerAndSelectorIsInItsPlace() {
        for text in corpus() {
            for out in [inline(text), multi(text)] {
                let scalars = Array(out.unicodeScalars)
                for (i, s) in scalars.enumerated() {
                    XCTAssertFalse(isAlwaysGone(s.value), "U+\(String(s.value, radix: 16, uppercase: true)) survived from \(hex(text))")
                    let before = i > 0 ? scalars[i - 1] : nil
                    let after = i + 1 < scalars.count ? scalars[i + 1] : nil
                    switch s.value {
                    case 0x200C, 0x200D:
                        XCTAssertTrue(before.map { $0.value > 0x7F && !isJoiner($0) } == true, "a joiner with no non-ASCII scalar before it in \(hex(out)) (from \(hex(text)))")
                        XCTAssertTrue(after.map { $0.value > 0x7F && !isJoiner($0) } == true, "a joiner with no non-ASCII scalar after it in \(hex(out)) (from \(hex(text)))")
                    case 0xFE0E, 0xFE0F:
                        let afterEmoji = before.map { $0.value > 0x7F && $0.properties.isEmoji } == true
                        let keycap = s.value == 0xFE0F && before.map { $0.value < 0x80 && $0.properties.isEmoji } == true && after?.value == 0x20E3
                        XCTAssertTrue(afterEmoji || keycap, "a selector that follows no emoji in \(hex(out)) (from \(hex(text)))")
                    default:
                        break
                    }
                }
            }
        }
    }

    func testTheRulesAgreeBetweenInlineAndMultilineOnTextWithoutLineBreaks() {
        for text in corpus() where !text.contains("\n") && !text.contains("\t") {
            XCTAssertEqual(inline(text), multi(text), hex(text))
        }
    }

    // MARK: Text of no interest, and a lot of text

    func testTextWithNothingOfInterestComesBackUnchanged() {
        let plain = "r\u{00E9}sum\u{00E9} \u{2014} \u{65E5}\u{672C}\u{8A9E} \u{1F680} caf\u{00E9} 100% done. plain ASCII, tabs\tand lines\nstay in code"
        XCTAssertEqual(multi(plain), plain)
        XCTAssertEqual(inline(plain), plain.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " "))
        XCTAssertEqual(inline(""), "")
        XCTAssertEqual(multi(""), "")
        let big = String(repeating: "plain text and \u{00E9}\u{65E5} \u{1F680}\n", count: 40_000)
        XCTAssertGreaterThan(big.utf8.count, 900_000)
        XCTAssertEqual(multi(big), big)
    }

    func testAMegabyteOfMixedHostileAndOrdinaryScalarsIsDoneQuickly() {
        let unit = "plain \u{00E9}\(zwj)\u{65E5} a\(zwj)b \u{2764}\(vs16) a\(vs16)\u{00AD}\(zwnj) 👩\(zwj)👩 x\u{200B}y\u{3164}z \u{FE00}\u{E0100}\n"
        var mixed = ""
        while mixed.utf8.count < 1_048_576 { mixed += unit }
        let onlyJoiners = String(repeating: "\(eAcute)\(zwj)", count: 524_288)
        let onlySelectors = String(repeating: "\u{2764}\(vs16)a\(vs16)", count: 150_000)

        // A failure bound for quadratic behaviour, not a benchmark: an ordinary run is a fraction of it.
        var outputs: [String: String] = [:]
        for (name, text) in [("mixed", mixed), ("joiners", onlyJoiners), ("selectors", onlySelectors)] {
            let start = Date()
            let i = inline(text)
            let m = multi(text)
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, 10, "\(name): both modes took \(elapsed) s on \(text.utf8.count) bytes")
            XCTAssertFalse(i.isEmpty)
            XCTAssertFalse(m.isEmpty)
            outputs[name] = i
        }

        // and what came out is still right (searched by scalars: a joiner joins characters)
        func has(_ text: String, _ part: String) -> Bool { (text as NSString).range(of: part, options: .literal).location != NSNotFound }
        let mixedOut = outputs["mixed"] ?? ""
        XCTAssertFalse(has(mixedOut, "a\(zwj)b"), "a joiner between ASCII letters is gone")
        XCTAssertFalse(has(mixedOut, "x\u{200B}y"), "a zero-width space is gone")
        XCTAssertTrue(has(mixedOut, "👩\(zwj)👩"), "an emoji sequence stays")
        XCTAssertTrue(has(mixedOut, "\(eAcute)\(zwj)\u{65E5}"), "a joiner between two non-ASCII scalars stays")
        // every joiner but the last sits between two letters; the last is at the end and goes
        XCTAssertEqual(outputs["joiners"]?.unicodeScalars.count, 524_288 * 2 - 1)
        // heart, selector, letter, selector: the selector after the heart stays, the one after the letter goes
        XCTAssertEqual(outputs["selectors"]?.unicodeScalars.count, 150_000 * 3)
    }
}
