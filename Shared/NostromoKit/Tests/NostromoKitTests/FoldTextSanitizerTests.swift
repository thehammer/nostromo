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

    func testUnassignedInvisibleCodePointsAreDroppedLikeTheDaemonsSet() {
        XCTAssertEqual(
            FoldTextSanitizer.sanitize("a\u{2065}b\u{FFF0}c\u{FFF8}d\u{E01F0}e\u{E0FFF}f"), "abcdef")
        XCTAssertEqual(FoldTextSanitizer.sanitize("a\u{FFFC}b"), "a\u{FFFC}b")
    }

    /// The daemon drops all of U+E0000...E0FFF (tags and the variation selectors supplement). The gap
    /// between the tags (E0000-E007F) and the old upper range (E01F0-E0FFF) held E0100...E01EF, which can
    /// carry one byte per character and draw as nothing.
    func testTheWholeTagAndVariationSelectorSupplementBlockIsDroppedWithNoGap() {
        for value: UInt32 in [0xE0000, 0xE0001, 0xE007F, 0xE0080, 0xE00FF, 0xE0100, 0xE0101, 0xE017F,
                              0xE01EE, 0xE01EF, 0xE01F0, 0xE0FFE, 0xE0FFF] {
            let scalar = Unicode.Scalar(value)!
            XCTAssertEqual(FoldTextSanitizer.sanitize("a\(scalar)b"), "ab", "U+\(String(value, radix: 16, uppercase: true)) survived")
        }
        // Every code point of the block, in one run.
        let block = String(String.UnicodeScalarView((UInt32(0xE0000)...UInt32(0xE0FFF)).compactMap { Unicode.Scalar($0) }))
        XCTAssertEqual(FoldTextSanitizer.sanitize("a" + block + "b"), "ab")
        XCTAssertEqual(FoldTextSanitizer.sanitize("a" + block + "b").unicodeScalars.count, 2)
    }

    func testABytePerCharacterPayloadInVariationSelectorsSupplementLeavesNothingBehind() {
        // "hi" hidden as variation selectors E0100 + byte, after a visible base character.
        let payload = [UInt8]("hi".utf8).map { Unicode.Scalar(0xE0100 + UInt32($0))! }
        let text = "ok" + String(String.UnicodeScalarView(payload))
        XCTAssertEqual(FoldTextSanitizer.sanitize(text), "ok")
    }

    func testTheCodePointsOfTheDaemonsInvisibleSetThatWereMissingAreDropped() {
        let dropped: [(String, UInt32)] = [
            ("soft hyphen", 0x00AD), ("combining grapheme joiner", 0x034F), ("Arabic number sign", 0x0600),
            ("Arabic end of ayah", 0x06DD), ("Syriac abbreviation mark", 0x070F), ("Arabic pound mark above", 0x0890),
            ("Arabic disputed end of ayah", 0x08E2), ("Hangul choseong filler", 0x115F),
            ("Hangul jungseong filler", 0x1160), ("Khmer inherent vowel Aq", 0x17B4),
            ("Mongolian free variation selector one", 0x180B), ("Mongolian vowel separator", 0x180E),
            ("inhibit symmetric swapping", 0x206A), ("nominal digit shapes", 0x206F), ("braille pattern blank", 0x2800),
            ("Hangul filler", 0x3164), ("halfwidth Hangul filler", 0xFFA0), ("Kaithi number sign above", 0x110BD),
            ("Kaithi number sign", 0x110CD), ("Egyptian hieroglyph format", 0x13430),
            ("Egyptian hieroglyph format end", 0x1343F), ("shorthand format letter overlap", 0x1BCA0),
            ("shorthand format up step", 0x1BCA3), ("musical symbol begin beam", 0x1D173),
            ("musical symbol end phrase", 0x1D17A),
        ]
        for (name, value) in dropped {
            let scalar = Unicode.Scalar(value)!
            XCTAssertEqual(FoldTextSanitizer.sanitize("a\(scalar)b"), "ab", "\(name) U+\(String(value, radix: 16, uppercase: true)) survived")
        }
    }

    func testTheCodePointsNextToTheDroppedRangesAreStillDrawn() {
        // Neighbours of the daemon's set that it does not list: they stay.
        for value: UInt32 in [0x00AC, 0x00AE, 0x0606, 0x06DE, 0x0710, 0x0892, 0x115E, 0x1161, 0x17B3, 0x17B6,
                              0x1810, 0x2070, 0x2801, 0x3165, 0xFF9F, 0xFFA1, 0x110BE, 0x13440, 0x1BCA4,
                              0x1D172, 0x1D17B, 0xE1000] {
            let scalar = Unicode.Scalar(value)!
            XCTAssertEqual(FoldTextSanitizer.sanitize("a\(scalar)b"), "a\(scalar)b", "U+\(String(value, radix: 16, uppercase: true)) was dropped")
        }
    }

    func testJoinersAndEmojiVariationSelectorsStayOnPurpose() {
        let family = "👩\u{200D}👩"
        XCTAssertEqual(FoldTextSanitizer.sanitize(family), family, "ZWJ keeps an emoji sequence together")
        XCTAssertEqual(FoldTextSanitizer.sanitize("❤\u{FE0F}"), "❤\u{FE0F}", "VS16 keeps the emoji presentation")
        XCTAssertEqual(FoldTextSanitizer.sanitize("a\u{200C}b"), "a\u{200C}b", "ZWNJ is needed by some scripts")
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
