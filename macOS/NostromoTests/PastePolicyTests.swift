import XCTest

// What a paste into a terminal does before it reaches the shell. Only a pane KNOWN to be local sends a
// multi-line paste straight through: a remote pane, a pane of a kind this app does not know and a pane
// with no record at all (`kind` nil) all ask first. A single line without a newline is always sent.

final class PastePolicyTests: XCTestCase {

    // MARK: decide

    func testSingleLineWithoutANewlineGoesStraightThroughEverywhere() {
        for kind in [TerminalKind.ecs, .unknown, .local, nil] {
            XCTAssertEqual(PastePolicy.decide(kind: kind, text: "ls -la"), .send, "kind \(String(describing: kind))")
            XCTAssertEqual(PastePolicy.decide(kind: kind, text: ""), .send, "kind \(String(describing: kind))")
        }
    }

    func testASingleLineWithATrailingNewlineAsksInARemoteShellBecauseItRunsTheMomentItLands() {
        XCTAssertEqual(PastePolicy.decide(kind: .ecs, text: "rm -rf x\n"), .confirm(lines: 1))
        XCTAssertEqual(PastePolicy.decide(kind: .ecs, text: "ls\r\n"), .confirm(lines: 1))
        XCTAssertEqual(PastePolicy.decide(kind: .ecs, text: "ls\r"), .confirm(lines: 1))
    }

    func testTwoLinesAsk() {
        XCTAssertEqual(PastePolicy.decide(kind: .ecs, text: "a\nb"), .confirm(lines: 2))
        XCTAssertEqual(PastePolicy.decide(kind: .ecs, text: "a\nb\n"), .confirm(lines: 2))
    }

    func testWindowsAndOldMacLineEndingsAreNormalised() {
        XCTAssertEqual(PastePolicy.decide(kind: .ecs, text: "a\r\nb\r\nc"), .confirm(lines: 3))
        XCTAssertEqual(PastePolicy.decide(kind: .ecs, text: "a\rb\rc"), .confirm(lines: 3))
    }

    func testOnlyOneTrailingNewlineIsIgnoredWhenCountingLines() {
        XCTAssertEqual(PastePolicy.decide(kind: .ecs, text: "a\n\n"), .confirm(lines: 2))
        XCTAssertEqual(PastePolicy.lineCount("rm -rf x\n"), 1)
    }

    func testAPaneOfAnUnknownKindOrNoKnownKindAsksLikeARemoteOne() {
        for kind in [TerminalKind.unknown, nil] {
            XCTAssertEqual(PastePolicy.decide(kind: kind, text: "a\nb\nc"), .confirm(lines: 3), "kind \(String(describing: kind))")
            XCTAssertEqual(PastePolicy.decide(kind: kind, text: "rm -rf x\n"), .confirm(lines: 1), "kind \(String(describing: kind))")
        }
    }

    func testLocalTerminalsNeverAsk() {
        XCTAssertEqual(PastePolicy.decide(kind: .local, text: "a\nb\nc"), .send)
        XCTAssertEqual(PastePolicy.decide(kind: .local, text: "rm -rf x\n"), .send)
        XCTAssertEqual(PastePolicy.decide(kind: .local, text: "a\r\nb"), .send)
    }

    // MARK: preview

    func testPreviewShowsAShortTextAsItIs() {
        XCTAssertEqual(PastePolicy.preview("ls\npwd"), "ls\npwd")
        XCTAssertEqual(PastePolicy.preview("rm -rf x\n"), "rm -rf x")
    }

    func testPreviewShowsTheFirstThreeLinesAndSaysThereIsMore() {
        XCTAssertEqual(PastePolicy.preview("1\n2\n3\n4\n5"), "1\n2\n3\u{2026}")
        XCTAssertEqual(PastePolicy.preview("1\n2\n3\n"), "1\n2\n3", "exactly three lines and a trailing newline: nothing was cut")
        XCTAssertEqual(PastePolicy.preview("1\n2\n3\n4"), "1\n2\n3\u{2026}")
    }

    func testPreviewNormalisesWindowsAndOldMacLineEndings() {
        XCTAssertEqual(PastePolicy.preview("a\r\nb\rc"), "a\nb\nc")
    }

    func testPreviewMakesControlCharactersVisible() {
        XCTAssertEqual(PastePolicy.preview("ls\u{1b}[31m"), "ls\u{FFFD}[31m")
        XCTAssertEqual(PastePolicy.preview("a\u{07}b\u{00}c\u{7F}d"), "a\u{FFFD}b\u{FFFD}c\u{FFFD}d")
    }

    func testPreviewMakesC1ControlsAndInvisibleFormatCharactersVisible() {
        XCTAssertEqual(PastePolicy.preview("a\u{85}b\u{9B}c"), "a\u{FFFD}b\u{FFFD}c")
        // A right-to-left override can make `rm -rf` read as something else; zero-width characters hide text.
        XCTAssertEqual(PastePolicy.preview("echo \u{202E}evil"), "echo \u{FFFD}evil")
        XCTAssertEqual(PastePolicy.preview("a\u{200B}b\u{200D}c\u{FEFF}d"), "a\u{FFFD}b\u{FFFD}c\u{FFFD}d")
    }

    func testPreviewTurnsATabIntoASpaceAndKeepsNewlines() {
        XCTAssertEqual(PastePolicy.preview("a\tb\nc"), "a b\nc")
    }

    func testPreviewIsCappedAtTwoHundredCharactersWithAnEllipsis() {
        let long = String(repeating: "x", count: 500)
        let preview = PastePolicy.preview(long + "\nsecond")
        XCTAssertEqual(preview, String(repeating: "x", count: 200) + "\u{2026}")
        XCTAssertEqual(PastePolicy.preview(String(repeating: "y", count: 200) + "\nz"),
                       String(repeating: "y", count: 200) + "\u{2026}",
                       "the cap counts the newline too, so the second line does not fit")
    }

    func testAPreviewExactlyAtTheCapIsNotMarkedAsCut() {
        let exact = String(repeating: "x", count: 200)
        XCTAssertEqual(PastePolicy.preview(exact), exact)
    }

    // A single line that carries a control or invisible character is not "just text" for a shell that is
    // not known to be local: an escape sequence can end a bracketed paste early, Ctrl-O / Ctrl-D act on
    // their own, and some programs treat U+2028, U+0085, VT and FF as line breaks.

    func testControlAndInvisibleCharactersAskInAPaneThatIsNotKnownToBeLocal() {
        let texts = ["ls\u{1b}[201~rm -rf x", "a\u{0F}b", "a\u{04}", "a\u{0B}b", "a\u{0C}b", "a\u{2028}b", "a\u{2029}b",
                     "a\u{85}b", "a\u{7F}b", "a\u{202E}b"]
        for kind in [TerminalKind.ecs, .unknown, nil] {
            for text in texts {
                XCTAssertEqual(PastePolicy.decide(kind: kind, text: text), .confirm(lines: PastePolicy.lineCount(text)),
                               "kind \(String(describing: kind)), text \(text.debugDescription)")
            }
        }
    }

    func testATabAloneDoesNotAskAndALocalShellNeverAsksForControlCharacters() {
        XCTAssertEqual(PastePolicy.decide(kind: .ecs, text: "a\tb"), .send)
        XCTAssertEqual(PastePolicy.decide(kind: .local, text: "a\u{1b}[31mb\u{2028}c"), .send)
    }
}
