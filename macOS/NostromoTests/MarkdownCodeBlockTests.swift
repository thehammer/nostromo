import XCTest
import AppKit
import NostromoKit

// Contract: a fenced code block in an assistant message renders as a code block, and nothing else does.
//
// The bug (2026-10-14): `MarkdownRenderer` was line-based with no notion of fences, so the ``` lines
// of a message showed as stray backticks, underscores inside code italicised, and a `# comment` in a
// shell snippet became a 20 pt heading. The contract:
//
//  - fence lines never appear; the code is shown verbatim, in a monospaced face, never italic or bold,
//    with no inline markup or block syntax interpreted inside it, on its own surface (one block per fence);
//  - the prose around it keeps today's rendering (inline code, bold, italics, headings, lists);
//  - a message with no fence renders exactly as it did before fences were understood;
//  - the card's height is knowable before it is attached (the transcript virtualiser positions turns
//    from `measuredHeight`), and long code lines wrap rather than widening the card;
//  - the code can be selected, copied, and read by VoiceOver as exactly the code;
//  - the code surface is legible in a key and a non-key window, and the selection highlight stays
//    visible on it.
//
// Hermetic: nothing here touches the general pasteboard or needs a real key window.
//
// Monospace is decided by advance widths, not `NSFont.isFixedPitch`: Fira Code Nerd Font Regular (what
// `Theme.firaCode` returns) reports `isFixedPitch == false` although every glyph has the same advance.

private final class NotKeyWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var isKeyWindow: Bool { false }
}

final class MarkdownCodeBlockTests: XCTestCase {

    private let fixture = MarkdownFenceFixtures.reportedMessage
    private let base13 = NSFont.systemFont(ofSize: 13)

    private let sqlLine = #"SELECT REPLACE(job_class,'App\\Modules\\Referrals\\Jobs\\','') job, status, outcome_quality, LEFT(COALESCE(error_message,'-'),60) err, COALESCE(completed_at,updated_at) at FROM pipeline_job_runs WHERE referral_id = 14464 ORDER BY id DESC LIMIT 20"#
    private let phpLines = [
        #"$referral = \App\Modules\Referrals\Models\Referral::findOrFail(14464);"#,
        #"$result = app(\App\Modules\Referrals\Services\ReprocessReferralPipelineService::class)->reprocess($referral);"#,
        #"$result->documentCount;"#,
    ]

    // MARK: Helpers

    private func render(_ markdown: String) -> NSAttributedString {
        MarkdownRenderer.render(markdown, baseFont: base13)
    }

    private func isMonospaced(_ font: NSFont) -> Bool {
        let widths = ["i", "W", "m", "."].map { ($0 as NSString).size(withAttributes: [.font: font]).width }
        return widths.allSatisfy { abs($0 - widths[0]) < 0.001 }
    }

    private func traits(_ font: NSFont) -> NSFontTraitMask { NSFontManager.shared.traits(of: font) }

    private func isItalic(_ font: NSFont) -> Bool { traits(font).contains(.italicFontMask) }
    private func isBold(_ font: NSFont) -> Bool { traits(font).contains(.boldFontMask) }

    private func range(of needle: String, in s: NSAttributedString, file: StaticString = #filePath, line: UInt = #line) -> NSRange {
        let r = (s.string as NSString).range(of: needle)
        XCTAssertNotEqual(r.location, NSNotFound, "\(needle.debugDescription) is not in the rendered text: \(s.string.prefix(200).debugDescription)", file: file, line: line)
        return r
    }

    private func fonts(in s: NSAttributedString, _ r: NSRange) -> [NSFont?] {
        var out: [NSFont?] = []
        s.enumerateAttribute(.font, in: r) { v, _, _ in out.append(v as? NSFont) }
        return out
    }

    private func assertMonospacedUpright(_ s: NSAttributedString, _ r: NSRange, _ what: String,
                                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(r.length, 0, what, file: file, line: line)
        for font in fonts(in: s, r) {
            guard let font else { XCTFail("\(what): a character has no font", file: file, line: line); continue }
            XCTAssertTrue(isMonospaced(font), "\(what): \(font.fontName) is not monospaced", file: file, line: line)
            XCTAssertFalse(isItalic(font), "\(what): \(font.fontName) is italic", file: file, line: line)
            XCTAssertFalse(isBold(font), "\(what): \(font.fontName) is bold", file: file, line: line)
        }
    }

    /// The text blocks of each paragraph-style run over `r` (an array per run).
    private func textBlocks(in s: NSAttributedString, _ r: NSRange) -> [[NSTextBlock]] {
        var out: [[NSTextBlock]] = []
        s.enumerateAttribute(.paragraphStyle, in: r) { v, _, _ in
            out.append((v as? NSParagraphStyle)?.textBlocks ?? [])
        }
        return out
    }

    private func assertOneSharedBlock(_ s: NSAttributedString, _ r: NSRange, _ what: String,
                                      file: StaticString = #filePath, line: UInt = #line) -> NSTextBlock? {
        let runs = textBlocks(in: s, r)
        XCTAssertFalse(runs.isEmpty, what, file: file, line: line)
        for blocks in runs { XCTAssertEqual(blocks.count, 1, "\(what): every paragraph in the code has exactly one text block", file: file, line: line) }
        guard let first = runs.first?.first else { return nil }
        for blocks in runs { XCTAssertTrue(blocks.first === first, "\(what): one block for the whole code, not one per line or run", file: file, line: line) }
        return first
    }

    private func fenceFreeLines(_ s: NSAttributedString) -> Bool {
        !s.string.contains("```") && !s.string.contains("~~~")
    }

    private func codeBlocks(_ text: String) -> [MarkdownFences.CodeBlock] {
        MarkdownFences.segments(of: text).compactMap { if case .code(let b) = $0 { return b } else { return nil } }
    }

    private func textView(of card: MarkdownCardView) -> NSTextView? {
        card.subviews.compactMap { $0 as? NSTextView }.first
    }

    private func notKeyWindow(size: NSSize, appearance: NSAppearance?) -> NSWindow {
        let window = NotKeyWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        addTeardownBlock { window.close() }
        return window
    }

    /// A card for `markdown` laid out at `width` in `window`, as the transcript does it: preset width,
    /// the measured height, then a layout pass.
    private func attachedCard(_ markdown: String, width: CGFloat, in window: NSWindow) -> MarkdownCardView {
        let card = MarkdownCardView(markdown: markdown)
        card.presetWidth = width
        card.frame = NSRect(x: 0, y: 0, width: width, height: MarkdownCardView.measuredHeight(markdown: markdown, width: width))
        window.contentView!.addSubview(card)
        card.layoutSubtreeIfNeeded()
        window.contentView!.layoutSubtreeIfNeeded()
        rigSettle()
        return card
    }

    // MARK: - Renderer: the reported message

    func testTheReportedMessageShowsNoFenceLines() {
        let s = render(fixture)
        XCTAssertFalse(s.string.contains("```"), "a fence leaked into the text")
        for line in s.string.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            XCTAssertFalse(["`", "``", "```", "```php", "```sql", "php", "sql"].contains(t), "stray fence or info line: \(line.debugDescription)")
        }
        XCTAssertFalse(s.string.contains("`"), "no backtick survives: fences are gone and inline code lost its markers")
    }

    func testTheReportedMessageShowsEveryCodeBlockVerbatim() {
        let s = render(fixture).string
        XCTAssertTrue(s.contains(sqlLine), "the SELECT line, byte for byte")
        for line in phpLines { XCTAssertTrue(s.contains(line), "php line missing or altered: \(line)") }
        XCTAssertTrue(s.contains(phpLines.joined(separator: "\n")), "the three PHP lines stay three lines in order")
        for needle in ["pipeline_job_runs", "job_class", "error_message", #"App\\Modules\\Referrals\\Jobs\\"#] {
            XCTAssertTrue(s.contains(needle), "\(needle) was altered")
        }
        for block in codeBlocks(fixture) { XCTAssertTrue(s.contains(block.code)) }
    }

    func testEveryCharacterOfEveryCodeBlockIsMonospacedAndUpright() {
        let s = render(fixture)
        for block in codeBlocks(fixture) {
            assertMonospacedUpright(s, range(of: block.code, in: s), "code block \(block.info.debugDescription)")
        }
    }

    func testEachFenceIsItsOwnTextBlockAndTheThreeBlocksAreDistinct() throws {
        let s = render(fixture)
        let blocks = codeBlocks(fixture)
        XCTAssertEqual(blocks.count, 3)
        var seen: [NSTextBlock] = []
        for block in blocks {
            let r = range(of: block.code, in: s)
            if let tb = assertOneSharedBlock(s, r, "code block \(block.info.debugDescription)") { seen.append(tb) }
        }
        XCTAssertEqual(seen.count, 3)
        for i in 0..<seen.count { for j in (i + 1)..<seen.count {
            XCTAssertFalse(seen[i] === seen[j], "blocks \(i) and \(j) share one text block, so they would merge into a single surface")
        } }
    }

    func testTheCodeBlocksSitOnTheThemesCodeSurface() {
        let s = render(fixture)
        for block in codeBlocks(fixture) {
            let tb = assertOneSharedBlock(s, range(of: block.code, in: s), "code block \(block.info.debugDescription)")
            XCTAssertEqual(tb?.backgroundColor, Theme.codeBlockBackground)
        }
    }

    func testLigaturesAreOffInsideCode() {
        let s = render(fixture)
        for block in codeBlocks(fixture) {
            let r = range(of: block.code, in: s)
            s.enumerateAttribute(.ligature, in: r) { v, _, _ in
                XCTAssertEqual(v as? Int, 0, "ligatures must be off in code (`->`, `=>`, `!=` stay as typed)")
            }
        }
    }

    func testTheProseAroundTheCodeStillGetsInlineCodeAndBold() throws {
        let s = render(fixture)
        let inline = range(of: "PORTAL_DEV-1Q0", in: s)
        assertMonospacedUpright(s, inline, "inline code in prose")
        let font = try XCTUnwrap(fonts(in: s, inline).first ?? nil)
        XCTAssertEqual(font.pointSize, 12, "inline code keeps its 12 pt face")

        let bold = range(of: "Staged command", in: s)
        for f in fonts(in: s, bold) { XCTAssertTrue(f.map(isBold) ?? false, "bold prose lost its bold") }
        XCTAssertFalse(s.string.contains("**"))
    }

    func testNothingInTheReportedMessageIsItalicOrHeadingSized() {
        // The message has no italic text and no headings: underscores in `job_class`, `outcome_quality`,
        // `error_message` and the `#` in `#5274` must not be read as markup.
        let s = render(fixture)
        s.enumerateAttribute(.font, in: NSRange(location: 0, length: s.length)) { v, r, _ in
            guard let font = v as? NSFont else { return }
            let text = (s.string as NSString).substring(with: r)
            XCTAssertFalse(isItalic(font), "italic text: \(text.debugDescription)")
            XCTAssertLessThanOrEqual(font.pointSize, 13, "heading-sized text: \(text.debugDescription)")
        }
    }

    // MARK: - Renderer: small cases

    func testAHashLineInsideACodeBlockStaysAMonospacedCodeLineNotAHeading() {
        let s = render("```bash\n# comment\necho hi\n```")
        let r = range(of: "# comment", in: s)
        assertMonospacedUpright(s, r, "# comment")
        for font in fonts(in: s, r) { XCTAssertEqual(font?.pointSize, 12) }
        XCTAssertTrue(fenceFreeLines(s))
    }

    func testListMarkersAndEmphasisInsideCodeStayLiteral() {
        let s = render("```\n- item\n* star\n1. one\n**x**\n_y_ and *z*\n`tick`\n```")
        for literal in ["- item", "* star", "1. one", "**x**", "_y_ and *z*", "`tick`"] {
            XCTAssertTrue(s.string.contains(literal), "\(literal) was interpreted as markup: \(s.string.prefix(200).debugDescription)")
            assertMonospacedUpright(s, range(of: literal, in: s), literal)
        }
        XCTAssertFalse(s.string.contains("•"), "a code line became a bullet")
    }

    func testEmphasisOutsideCodeStillItalicisesAndCodeBesideItDoesNot() throws {
        let s = render("an *alpha* and _beta_ here\n```\nunder_score_name\n```\ntail *gamma*")
        for word in ["alpha", "beta", "gamma"] {
            let font = try XCTUnwrap(fonts(in: s, range(of: word, in: s)).first ?? nil)
            XCTAssertTrue(isItalic(font), "\(word) lost its italics")
        }
        XCTAssertFalse(s.string.contains("*alpha*") || s.string.contains("_beta_"))
        XCTAssertTrue(s.string.contains("under_score_name"))
        assertMonospacedUpright(s, range(of: "under_score_name", in: s), "code between italic prose")
    }

    func testMarkupOpenedInProseDoesNotReachAcrossAFenceIntoTheCode() {
        // The old whole-text pass let `*alpha ... code*` match across the fence lines.
        let s = render("start *alpha\n```\ncode*\n```\nend _omega and `tail")
        XCTAssertTrue(s.string.contains("*alpha"), "an unclosed * in prose stays literal")
        XCTAssertTrue(s.string.contains("code*"))
        s.enumerateAttribute(.font, in: NSRange(location: 0, length: s.length)) { v, r, _ in
            if let font = v as? NSFont, isItalic(font) {
                XCTFail("italic text appeared: \((s.string as NSString).substring(with: r).debugDescription)")
            }
        }
        assertMonospacedUpright(s, range(of: "code*", in: s), "code")
    }

    func testAnUnterminatedFenceRendersAsACodeBlockToTheEnd() {
        let s = render("intro\n```sh\nline one\nline two")
        XCTAssertTrue(fenceFreeLines(s))
        let r = range(of: "line one\nline two", in: s)
        assertMonospacedUpright(s, r, "unterminated block")
        XCTAssertNotNil(assertOneSharedBlock(s, r, "unterminated block"))
        XCTAssertTrue(s.string.hasPrefix("intro"))
    }

    func testATildeFenceRendersAsACodeBlock() {
        let s = render("before\n~~~\n```\nstill code _x_\n~~~\nafter")
        XCTAssertTrue(s.string.contains("```\nstill code _x_"), "backticks inside a tilde fence are content")
        XCTAssertFalse(s.string.contains("~~~"))
        let r = range(of: "```\nstill code _x_", in: s)
        assertMonospacedUpright(s, r, "tilde block")
        XCTAssertNotNil(assertOneSharedBlock(s, r, "tilde block"))
    }

    func testAnEmptyBlockStaysVisibleAsOneLine() {
        let s = render("before\n```\n```\nafter")
        XCTAssertTrue(fenceFreeLines(s))
        XCTAssertTrue(s.string.contains("before") && s.string.contains("after"))
        var hasBlock = false
        s.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: s.length)) { v, _, _ in
            if !((v as? NSParagraphStyle)?.textBlocks.isEmpty ?? true) { hasBlock = true }
        }
        XCTAssertTrue(hasBlock, "an empty fence leaves no block to draw")

        let empty = MarkdownCardView.measuredHeight(markdown: "```\n```", width: 400)
        let oneLine = MarkdownCardView.measuredHeight(markdown: "```\nx\n```", width: 400)
        XCTAssertEqual(empty, oneLine, accuracy: 1.0, "an empty block is as tall as a block with one line")
    }

    func testABlockWithABlankLineInsideKeepsTheBlankLine() {
        let s = render("```\nfirst\n\nthird\n```")
        XCTAssertTrue(s.string.contains("first\n\nthird"), "blank lines in code are content, not paragraph spacing: \(s.string.prefix(200).debugDescription)")
    }

    // MARK: - Renderer: messages with no fence are untouched

    /// One line per attribute run: the text, its font (size and traits; monospace by advance widths),
    /// the paragraph geometry, and whether it carries a background. Captured from the renderer as it was
    /// before fences, on the same machine; `main` renders these byte-for-byte.
    private func dump(_ s: NSAttributedString) -> String {
        var out: [String] = []
        s.enumerateAttributes(in: NSRange(location: 0, length: s.length)) { attrs, range, _ in
            let text = (s.string as NSString).substring(with: range)
            let font = attrs[.font] as? NSFont
            let ps = attrs[.paragraphStyle] as? NSParagraphStyle
            let t = font.map { traits($0) } ?? []
            out.append("\(text.debugDescription) | size \(font?.pointSize ?? -1) mono \(font.map(isMonospaced) ?? false) bold \(t.contains(.boldFontMask)) italic \(t.contains(.italicFontMask)) | spacing \(ps?.paragraphSpacing ?? -1) head \(ps?.headIndent ?? -1) first \(ps?.firstLineHeadIndent ?? -1) | bg \(attrs[.backgroundColor] != nil)")
        }
        return out.joined(separator: "\n")
    }

    private static let longBullet: String = {
        let unit = "the quick brown fox jumps over the lazy dog and keeps going "
        var s = ""
        while s.count < 400 { s += unit }
        return "## Findings\n\n- " + String(s.prefix(400))
    }()

    private struct Golden {
        let name: String
        let markdown: String
        let dump: String
        /// Card heights at 300, 520 and 737.25 pt.
        let heights: [CGFloat]
    }

    private var goldens: [Golden] {
        [
            Golden(name: "headers, bullets and numbered list",
                   markdown: "# Release notes\n\nSome intro text.\n\n## Changes\n\n- first item\n- second item with more words\n* star bullet\n1. numbered one\n2. numbered two\n\n### Details\nPlain closing line.",
                   dump: #"""
"Release note" | size 20.0 mono false bold true italic false | spacing 6.0 head 0.0 first 0.0 | bg false
"s" | size 20.0 mono false bold true italic false | spacing 8.0 head 0.0 first 0.0 | bg false
"\n" | size -1.0 mono false bold false italic false | spacing -1.0 head -1.0 first -1.0 | bg false
"Some intro text" | size 13.0 mono false bold false italic false | spacing 0.0 head 0.0 first 0.0 | bg false
"." | size 13.0 mono false bold false italic false | spacing 8.0 head 0.0 first 0.0 | bg false
"\n" | size -1.0 mono false bold false italic false | spacing -1.0 head -1.0 first -1.0 | bg false
"Change" | size 16.0 mono false bold true italic false | spacing 4.0 head 0.0 first 0.0 | bg false
"s" | size 16.0 mono false bold true italic false | spacing 8.0 head 0.0 first 0.0 | bg false
"\n" | size -1.0 mono false bold false italic false | spacing -1.0 head -1.0 first -1.0 | bg false
"•  first item" | size 13.0 mono false bold false italic false | spacing 2.0 head 14.0 first 0.0 | bg false
"\n" | size -1.0 mono false bold false italic false | spacing -1.0 head -1.0 first -1.0 | bg false
"•  second item with more words" | size 13.0 mono false bold false italic false | spacing 2.0 head 14.0 first 0.0 | bg false
"\n" | size -1.0 mono false bold false italic false | spacing -1.0 head -1.0 first -1.0 | bg false
"•  star bullet" | size 13.0 mono false bold false italic false | spacing 2.0 head 14.0 first 0.0 | bg false
"\n" | size -1.0 mono false bold false italic false | spacing -1.0 head -1.0 first -1.0 | bg false
"1. numbered one" | size 13.0 mono false bold false italic false | spacing 2.0 head 14.0 first 0.0 | bg false
"\n" | size -1.0 mono false bold false italic false | spacing -1.0 head -1.0 first -1.0 | bg false
"2. numbered tw" | size 13.0 mono false bold false italic false | spacing 2.0 head 14.0 first 0.0 | bg false
"o" | size 13.0 mono false bold false italic false | spacing 8.0 head 0.0 first 0.0 | bg false
"\n" | size -1.0 mono false bold false italic false | spacing -1.0 head -1.0 first -1.0 | bg false
"Details" | size 14.0 mono false bold true italic false | spacing 2.0 head 0.0 first 0.0 | bg false
"\n" | size -1.0 mono false bold false italic false | spacing -1.0 head -1.0 first -1.0 | bg false
"Plain closing line." | size 13.0 mono false bold false italic false | spacing 0.0 head 0.0 first 0.0 | bg false
"""#, heights: [216, 216, 216]),
            Golden(name: "inline code, bold and italics",
                   markdown: "Use `swift test` to run **everything**, or *just one* with _filter_.\n\nSecond paragraph with `code` and **bold** together.",
                   dump: #"""
"Use " | size 13.0 mono false bold false italic false | spacing 0.0 head 0.0 first 0.0 | bg false
"swift test" | size 12.0 mono true bold false italic false | spacing -1.0 head -1.0 first -1.0 | bg true
" to run " | size 13.0 mono false bold false italic false | spacing 0.0 head 0.0 first 0.0 | bg false
"everything" | size 13.0 mono false bold true italic false | spacing -1.0 head -1.0 first -1.0 | bg false
", or " | size 13.0 mono false bold false italic false | spacing 0.0 head 0.0 first 0.0 | bg false
"just one" | size 13.0 mono false bold false italic true | spacing -1.0 head -1.0 first -1.0 | bg false
" with " | size 13.0 mono false bold false italic false | spacing 0.0 head 0.0 first 0.0 | bg false
"filter" | size 13.0 mono false bold false italic true | spacing -1.0 head -1.0 first -1.0 | bg false
"." | size 13.0 mono false bold false italic false | spacing 8.0 head 0.0 first 0.0 | bg false
"\n" | size -1.0 mono false bold false italic false | spacing -1.0 head -1.0 first -1.0 | bg false
"Second paragraph with " | size 13.0 mono false bold false italic false | spacing 0.0 head 0.0 first 0.0 | bg false
"code" | size 12.0 mono true bold false italic false | spacing -1.0 head -1.0 first -1.0 | bg true
" and " | size 13.0 mono false bold false italic false | spacing 0.0 head 0.0 first 0.0 | bg false
"bold" | size 13.0 mono false bold true italic false | spacing -1.0 head -1.0 first -1.0 | bg false
" together." | size 13.0 mono false bold false italic false | spacing 0.0 head 0.0 first 0.0 | bg false
"""#, heights: [92, 60, 60]),
            Golden(name: "the findings message from ChatTurnViewLayoutTests",
                   markdown: Self.longBullet,
                   dump: #"""
"Finding" | size 16.0 mono false bold true italic false | spacing 4.0 head 0.0 first 0.0 | bg false
"s" | size 16.0 mono false bold true italic false | spacing 8.0 head 0.0 first 0.0 | bg false
"\n" | size -1.0 mono false bold false italic false | spacing -1.0 head -1.0 first -1.0 | bg false
"•  the quick brown fox jumps over the lazy dog and keeps going the quick brown fox jumps over the lazy dog and keeps going the quick brown fox jumps over the lazy dog and keeps going the quick brown fox jumps over the lazy dog and keeps going the quick brown fox jumps over the lazy dog and keeps going the quick brown fox jumps over the lazy dog and keeps going the quick brown fox jumps over the lazy" | size 13.0 mono false bold false italic false | spacing 2.0 head 14.0 first 0.0 | bg false
"""#, heights: [206, 142, 110]),
            Golden(name: "inline triple backticks and snake_case are not a fence",
                   markdown: "Write ```x``` inline, not as a block.\n\nAnd a `lone` span with a_b_c snake_case word.",
                   dump: #"""
"Write " | size 13.0 mono false bold false italic false | spacing 0.0 head 0.0 first 0.0 | bg false
"`" | size 12.0 mono true bold false italic false | spacing -1.0 head -1.0 first -1.0 | bg true
"x" | size 13.0 mono false bold false italic false | spacing 0.0 head 0.0 first 0.0 | bg false
"`" | size 12.0 mono true bold false italic false | spacing -1.0 head -1.0 first -1.0 | bg true
" inline, not as a block" | size 13.0 mono false bold false italic false | spacing 0.0 head 0.0 first 0.0 | bg false
"." | size 13.0 mono false bold false italic false | spacing 8.0 head 0.0 first 0.0 | bg false
"\n" | size -1.0 mono false bold false italic false | spacing -1.0 head -1.0 first -1.0 | bg false
"And a " | size 13.0 mono false bold false italic false | spacing 0.0 head 0.0 first 0.0 | bg false
"lone" | size 12.0 mono true bold false italic false | spacing -1.0 head -1.0 first -1.0 | bg true
" span with a" | size 13.0 mono false bold false italic false | spacing 0.0 head 0.0 first 0.0 | bg false
"b" | size 13.0 mono false bold false italic true | spacing -1.0 head -1.0 first -1.0 | bg false
"c snake_case word." | size 13.0 mono false bold false italic false | spacing 0.0 head 0.0 first 0.0 | bg false
"""#, heights: [60, 60, 60]),
        ]
    }

    func testMessagesWithoutAFenceRenderExactlyAsBefore() {
        for g in goldens {
            XCTAssertFalse(MarkdownFences.containsFence(g.markdown), "\(g.name): not a no-fence message")
            XCTAssertEqual(dump(render(g.markdown)), g.dump, "\(g.name): rendering changed")
        }
    }

    func testMessagesWithoutAFenceMeasureExactlyAsBefore() {
        for g in goldens {
            for (width, expected) in zip([300, 520, 737.25] as [CGFloat], g.heights) {
                XCTAssertEqual(MarkdownCardView.measuredHeight(markdown: g.markdown, width: width), expected, accuracy: 0.01,
                               "\(g.name) at \(width) pt")
            }
        }
    }

    // MARK: - Height parity (the scroll-safety contract)

    private let parityWidths: [CGFloat] = [300, 420.5, 520, 737.25, 900]

    func testMeasuredHeightEqualsTheAttachedCardsLaidOutTextPlusPaddingAtEveryWidth() throws {
        let window = makeRigWindow(self, size: NSSize(width: 1500, height: 1200))
        for width in parityWidths {
            let card = attachedCard(fixture, width: width, in: window)
            defer { card.removeFromSuperview() }
            let tv = try XCTUnwrap(textView(of: card))
            let lm = try XCTUnwrap(tv.layoutManager, "the card's text view must stay on TextKit 1")
            let tc = try XCTUnwrap(tv.textContainer)
            lm.ensureLayout(for: tc)
            let measured = MarkdownCardView.measuredHeight(markdown: fixture, width: width)
            XCTAssertEqual(lm.usedRect(for: tc).height + 24, measured, accuracy: 0.5,
                           "width \(width): the height the transcript positions turns by is not the height the card lays out to")
            XCTAssertEqual(card.frame.height, measured, accuracy: 0.01)
        }
    }

    func testTheCardIsAsTallAsItsFencedContentNeedsInTheRealPane() throws {
        for paneWidth in [520, 740.5, 1000] as [CGFloat] {
            let rig = ReplRig(self, blocks: [.text(fixture)], paneWidth: paneWidth)
            rig.converge()
            let cards = rigAllSubviews(of: rig.turn).compactMap { $0 as? MarkdownCardView }
            XCTAssertEqual(cards.count, 1, "pane \(paneWidth): a message with fences and no pipe table or --- is one card")
            let card = try XCTUnwrap(cards.first)
            XCTAssertEqual(card.frame.width, ChatTurnView.blockWidth(paneWidth: rig.contentWidth), accuracy: 0.5,
                           "pane \(paneWidth): the card is as wide as its block column")
            XCTAssertEqual(card.frame.height, MarkdownCardView.measuredHeight(markdown: fixture, width: card.frame.width), accuracy: 0.5,
                           "pane \(paneWidth): the laid-out card is not the measured height")
        }
    }

    func testReconvergingTheRealPaneChangesNoHeight() throws {
        let rig = ReplRig(self, blocks: [.text(fixture)], paneWidth: 740.5)
        rig.converge()
        let island = rig.turn.islandHeight()
        let card = try XCTUnwrap(rigAllSubviews(of: rig.turn).compactMap { $0 as? MarkdownCardView }.first)
        let cardHeight = card.frame.height

        rig.converge()
        rigSettle()
        rig.measure()
        rig.converge()
        XCTAssertEqual(rig.turn.islandHeight(), island, accuracy: 0.01, "the turn's height moved on a second layout")
        XCTAssertEqual(card.frame.height, cardHeight, accuracy: 0.01, "the card's height moved on a second layout")
    }

    // MARK: - Long lines wrap; the card never widens

    private func longLineMarkdown(_ n: Int) -> String { "```\n" + String(repeating: "a", count: n) + "\n```" }

    func testALongCodeLineWrapsAndMakesTheCardTallerThanAShortOne() {
        let long = MarkdownCardView.measuredHeight(markdown: longLineMarkdown(600), width: 520)
        let short = MarkdownCardView.measuredHeight(markdown: longLineMarkdown(60), width: 520)
        XCTAssertGreaterThan(long, short + 40, "600 characters with no spaces must wrap onto many lines, not run off one")
    }

    func testALongCodeLineNeverWidensTheCardOrOverflowsItsTextView() throws {
        let rig = ReplRig(self, blocks: [.text("before\n" + longLineMarkdown(600) + "\nafter")], paneWidth: 900)
        rig.converge()
        let card = try XCTUnwrap(rigAllSubviews(of: rig.turn).compactMap { $0 as? MarkdownCardView }.first)
        XCTAssertEqual(card.frame.width, ChatTurnView.blockWidth(paneWidth: rig.contentWidth), accuracy: 0.5, "the card is the block column's width")
        XCTAssertEqual(card.intrinsicContentSize.width, NSView.noIntrinsicMetric, "the card must not ask for the width of its longest line")

        let tv = try XCTUnwrap(textView(of: card))
        let lm = try XCTUnwrap(tv.layoutManager)
        let tc = try XCTUnwrap(tv.textContainer)
        lm.ensureLayout(for: tc)
        XCTAssertLessThanOrEqual(lm.usedRect(for: tc).width, tv.frame.width + 0.5, "the text overflows its view instead of wrapping")
        var lines = 0
        lm.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: lm.numberOfGlyphs)) { _, _, _, _, _ in lines += 1 }
        XCTAssertGreaterThanOrEqual(lines, 8, "600 characters in a ~600 pt column wrap onto many lines")
    }

    // MARK: - Routing through TextBlockView

    private let table = "| a | b |\n|---|---|\n| 1 | 2 |"
    private let sqlFence = "```sql\nSELECT 1\n```"

    private func cardsAndTables(_ block: TextBlockView) -> [NSView] {
        block.subviews.filter { $0 is MarkdownCardView || $0 is MarkdownTableView }
    }

    private func isCode(_ card: NSView, containing needle: String) -> Bool {
        guard let card = card as? MarkdownCardView, let tv = textView(of: card) else { return false }
        return tv.string.contains(needle)
    }

    private func allText(in view: NSView) -> String {
        rigAllSubviews(of: view).map { v -> String in
            if let tf = v as? NSTextField { return tf.stringValue }
            if let tv = v as? NSTextView { return tv.string }
            return ""
        }.joined(separator: "\n")
    }

    func testAPipeTableBeforeAFenceGivesATableThenACodeCard() {
        let block = TextBlockView(text: "Intro line.\n\n" + table + "\n\n" + sqlFence)
        let views = cardsAndTables(block)
        guard let tableAt = views.firstIndex(where: { $0 is MarkdownTableView }),
              let codeAt = views.firstIndex(where: { isCode($0, containing: "SELECT 1") })
        else { return XCTFail("expected a table and a card with the SELECT: \(views.map { String(describing: type(of: $0)) })") }
        XCTAssertLessThan(tableAt, codeAt, "source order: the table comes first")
        XCTAssertEqual(views.filter { $0 is MarkdownTableView }.count, 1)
        XCTAssertFalse(allText(in: block).contains("```"), "a fence leaked into a label or card")
    }

    func testAFenceBeforeAPipeTableGivesACodeCardThenATable() {
        let block = TextBlockView(text: sqlFence + "\n\n" + table + "\n\nOutro.")
        let views = cardsAndTables(block)
        guard let tableAt = views.firstIndex(where: { $0 is MarkdownTableView }),
              let codeAt = views.firstIndex(where: { isCode($0, containing: "SELECT 1") })
        else { return XCTFail("expected a table and a card with the SELECT: \(views.map { String(describing: type(of: $0)) })") }
        XCTAssertLessThan(codeAt, tableAt, "source order: the code comes first")
        XCTAssertFalse(allText(in: block).contains("```"), "a fence leaked into a label or card")
    }

    func testTheCodeCardBesideATableIsGivenItsWidthAndHasItsMeasuredHeight() throws {
        let block = TextBlockView(text: table + "\n\n" + sqlFence)
        block.presetLayoutWidth(520)
        let card = try XCTUnwrap(cardsAndTables(block).first { isCode($0, containing: "SELECT 1") } as? MarkdownCardView,
                                 "no code card beside the table")
        XCTAssertEqual(card.presetWidth, 520, "the code card was not told the width it will be laid out at")
        // Guess: the card is built from the fence's own lines (its `source`), nothing else.
        XCTAssertEqual(card.intrinsicContentSize.height, MarkdownCardView.measuredHeight(markdown: sqlFence, width: 520), accuracy: 0.5)
    }

    func testAFenceHoldingAPipeTableAndADashLineIsOneCardWithNoTable() throws {
        let text = "Here is the file:\n```md\n| a | b |\n|---|---|\n---\n| 1 | 2 |\n```\nDone."
        let block = TextBlockView(text: text)
        let cards = block.subviews.compactMap { $0 as? MarkdownCardView }
        XCTAssertEqual(cards.count, 1, "a --- inside a fence must not split the card: \(block.subviews.map { String(describing: type(of: $0)) })")
        XCTAssertFalse(block.subviews.contains { $0 is MarkdownTableView }, "a pipe table inside a fence is code, not a table")
        let tv = try XCTUnwrap(cards.first.flatMap(textView(of:)))
        XCTAssertTrue(tv.string.contains("| a | b |\n|---|---|\n---\n| 1 | 2 |"), tv.string)
        XCTAssertFalse(tv.string.contains("```"))
    }

    func testADashLineInsideAFenceDoesNotSplitTheCard() {
        let block = TextBlockView(text: "```yaml\n---\nkey: value\n---\n```")
        XCTAssertEqual(block.subviews.compactMap { $0 as? MarkdownCardView }.count, 1)
    }

    func testADashLineOutsideAFenceStillSplitsCardsAroundTheCode() {
        let block = TextBlockView(text: "first `a`\n---\nsecond\n```\ncode\n```")
        let cards = block.subviews.compactMap { $0 as? MarkdownCardView }
        XCTAssertEqual(cards.count, 2, "a --- in prose still starts a new card")
        XCTAssertEqual(cards.filter { textView(of: $0)?.string.contains("code") ?? false }.count, 1)
    }

    // MARK: - Copy and VoiceOver

    private func fixtureCard(width: CGFloat = 520, in window: NSWindow) throws -> (card: MarkdownCardView, tv: NSTextView) {
        let card = attachedCard(fixture, width: width, in: window)
        return (card, try XCTUnwrap(textView(of: card)))
    }

    private func newPasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("test-\(UUID())"))
        addTeardownBlock { pb.releaseGlobally() }
        return pb
    }

    func testCopyingTheSelectedCodePutsExactlyThatCodeOnThePasteboard() throws {
        let window = makeRigWindow(self, size: NSSize(width: 900, height: 1200))
        let (_, tv) = try fixtureCard(in: window)
        let sqlRange = (tv.string as NSString).range(of: sqlLine)
        XCTAssertNotEqual(sqlRange.location, NSNotFound, "the SELECT line is not in the card's text")
        tv.setSelectedRange(sqlRange)
        let pb = newPasteboard()
        pb.clearContents()
        XCTAssertTrue(tv.writeSelection(to: pb, types: tv.writablePasteboardTypes))
        XCTAssertEqual(pb.string(forType: .string), sqlLine, "copy must give the SELECT byte for byte (no fence, no indent, no padding)")
    }

    func testCopyingEverythingHasEachCodeBlockVerbatimAndNoFenceLine() throws {
        let window = makeRigWindow(self, size: NSSize(width: 900, height: 1200))
        let (_, tv) = try fixtureCard(in: window)
        tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
        let pb = newPasteboard()
        pb.clearContents()
        XCTAssertTrue(tv.writeSelection(to: pb, types: tv.writablePasteboardTypes))
        let copied = try XCTUnwrap(pb.string(forType: .string))
        for block in codeBlocks(fixture) { XCTAssertTrue(copied.contains(block.code), "copied text lost or altered \(block.code.prefix(40))") }
        XCTAssertFalse(copied.contains("```"))
    }

    func testVoiceOverReadsEachCodeBlockVerbatimAndNoFence() throws {
        let window = makeRigWindow(self, size: NSSize(width: 900, height: 1200))
        let (_, tv) = try fixtureCard(in: window)
        let value = try XCTUnwrap(tv.accessibilityValue() as? String)
        for block in codeBlocks(fixture) { XCTAssertTrue(value.contains(block.code), "VoiceOver text lost or altered \(block.code.prefix(40))") }
        XCTAssertFalse(value.contains("```"))
    }

    func testVoiceOverKnowsTheCodeIsInAMonospacedFace() throws {
        let window = makeRigWindow(self, size: NSSize(width: 900, height: 1200))
        let (_, tv) = try fixtureCard(in: window)
        let r = (tv.string as NSString).range(of: sqlLine)
        XCTAssertNotEqual(r.location, NSNotFound)
        let ax = try XCTUnwrap(tv.accessibilityAttributedString(for: r))
        XCTAssertEqual(ax.string, sqlLine)

        var font = ax.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        if font == nil, let d = ax.attribute(NSAttributedString.Key("AXFont"), at: 0, effectiveRange: nil) as? [String: Any],
           let name = d["AXFontName"] as? String {
            font = NSFont(name: name, size: 12)
        }
        if font == nil {
            // AppKit does not populate the accessibility string's font host-less: assert the storage instead.
            font = tv.textStorage?.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont
        }
        XCTAssertTrue(font.map(isMonospaced) ?? false, "the SQL is not in a monospaced face: \(String(describing: font?.fontName))")
    }

    // MARK: - Legibility (pixels, as ToolGroupAppearanceTests)

    private func luminance(_ color: NSColor) -> Double {
        let c = color.usingColorSpace(.sRGB) ?? color
        func linear(_ v: CGFloat) -> Double {
            let s = Double(v)
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private func name(_ c: NSColor) -> String {
        let s = c.usingColorSpace(.sRGB) ?? c
        return String(format: "rgb(%.0f,%.0f,%.0f)", s.redComponent * 255, s.greenComponent * 255, s.blueComponent * 255)
    }

    private struct Sample {
        var codeBase: NSColor
        var codeText: NSColor
        var cardBase: NSColor
    }

    private static let legibilityWidth: CGFloat = 520

    private func renderCard(keyWindow: Bool, file: StaticString = #filePath, line: UInt = #line) -> Sample? {
        _ = NSApplication.shared
        let dark = NSAppearance(named: .darkAqua)
        let height = MarkdownCardView.measuredHeight(markdown: fixture, width: Self.legibilityWidth)
        let size = NSSize(width: Self.legibilityWidth, height: height)
        let window: NSWindow = keyWindow ? makeRigWindow(self, size: size, appearance: dark) : notKeyWindow(size: size, appearance: dark)
        XCTAssertEqual(window.isKeyWindow, keyWindow, file: file, line: line)

        let host = NSView(frame: NSRect(origin: .zero, size: size))
        host.wantsLayer = true
        host.layer?.backgroundColor = Theme.bg.cgColor
        window.contentView = host
        let card = MarkdownCardView(markdown: fixture)
        card.presetWidth = Self.legibilityWidth
        card.frame = host.bounds
        host.addSubview(card)
        host.layoutSubtreeIfNeeded()
        card.layoutSubtreeIfNeeded()
        rigSettle()

        guard let tv = textView(of: card), let lm = tv.layoutManager, let tc = tv.textContainer else {
            XCTFail("no text view in the card", file: file, line: line); return nil
        }
        lm.ensureLayout(for: tc)
        let sqlChars = (tv.string as NSString).range(of: sqlLine)
        guard sqlChars.location != NSNotFound else { XCTFail("the SELECT line is not in the card", file: file, line: line); return nil }
        let sqlGlyphs = lm.glyphRange(forCharacterRange: sqlChars, actualCharacterRange: nil)
        let local = lm.boundingRect(forGlyphRange: sqlGlyphs, in: tc)
        let origin = tv.textContainerOrigin
        let sqlRect = tv.convert(local.offsetBy(dx: origin.x, dy: origin.y), to: host)

        host.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            XCTFail("could not render the card", file: file, line: line); return nil
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width

        func pixels(in rect: NSRect) -> [NSColor] {
            let r = rect.intersection(host.bounds)
            guard !r.isNull, r.width > 0, r.height > 0 else { return [] }
            let xs = Int((r.minX * scale).rounded(.down)) ..< Int((r.maxX * scale).rounded(.up))
            let ys = Int(((host.bounds.height - r.maxY) * scale).rounded(.down)) ..< Int(((host.bounds.height - r.minY) * scale).rounded(.up))
            var out: [NSColor] = []
            for y in ys where y >= 0 && y < rep.pixelsHigh {
                for x in xs where x >= 0 && x < rep.pixelsWide {
                    if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) { out.append(c) }
                }
            }
            return out
        }
        func median(_ colors: [NSColor]) -> NSColor? {
            let sorted = colors.sorted { luminance($0) < luminance($1) }
            return sorted.isEmpty ? nil : sorted[sorted.count / 2]
        }

        // The glyph rect lies inside the block, so its median pixel is the block's fill (glyphs are sparse).
        let inBlock = pixels(in: sqlRect.insetBy(dx: 1, dy: 1))
        // The card's own padding ring, left of the text view: outside every block.
        let ring = pixels(in: NSRect(x: 3, y: 14, width: 7, height: max(host.bounds.height - 28, 1)))
        guard let codeBase = median(inBlock), let codeText = inBlock.max(by: { luminance($0) < luminance($1) }), let cardBase = median(ring) else {
            XCTFail("nothing drawn: \(inBlock.count) pixels in \(sqlRect), \(ring.count) in the card ring", file: file, line: line)
            return nil
        }
        return Sample(codeBase: codeBase, codeText: codeText, cardBase: cardBase)
    }

    private func assertLegible(keyWindow: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let label = keyWindow ? "key window" : "non-key window"
        guard let s = renderCard(keyWindow: keyWindow, file: file, line: line) else { return }
        let textOnCode = contrast(s.codeText, s.codeBase)
        let codeVsCard = contrast(s.codeBase, s.cardBase)
        print("[MarkdownCodeBlock \(label)] code base \(name(s.codeBase)) code text \(name(s.codeText)) card base \(name(s.cardBase)) text/code \(String(format: "%.2f", textOnCode)) code/card \(String(format: "%.2f", codeVsCard))")
        XCTAssertGreaterThanOrEqual(textOnCode, 4.5, "\(label): code text on the code surface", file: file, line: line)
        XCTAssertGreaterThanOrEqual(codeVsCard, 1.2, "\(label): the code surface must be visible against the card", file: file, line: line)
    }

    func testTheCodeIsLegibleAndSetApartInTheKeyWindow() { assertLegible(keyWindow: true) }

    func testTheCodeIsLegibleAndSetApartInAWindowThatIsNotKey() { assertLegible(keyWindow: false) }

    func testTheCodeLooksTheSameWhetherOrNotItsWindowIsKey() throws {
        let key = try XCTUnwrap(renderCard(keyWindow: true))
        let notKey = try XCTUnwrap(renderCard(keyWindow: false))
        XCTAssertEqual(contrast(key.codeBase, notKey.codeBase), 1.0, accuracy: 0.05, "the code surface dims in an inactive window")
        XCTAssertEqual(contrast(key.codeText, notKey.codeText), 1.0, accuracy: 0.05, "the code text dims in an inactive window")
    }

    func testTheCodeSurfaceIsAnExplicitColourSoItCannotFollowTheSystemAppearance() {
        XCTAssertEqual(Theme.codeBlockBackground.type, .componentBased)
    }

    func testTheSelectionHighlightStaysVisibleOnTheCodeSurface() {
        XCTAssertGreaterThanOrEqual(contrast(Theme.selectionBackground, Theme.codeBlockBackground), 3.0, "selected code must stand out from the code surface")
    }
}
