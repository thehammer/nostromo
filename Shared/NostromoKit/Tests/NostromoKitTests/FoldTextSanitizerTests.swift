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
