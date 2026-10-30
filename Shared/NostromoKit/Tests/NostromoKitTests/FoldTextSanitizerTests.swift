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
