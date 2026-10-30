import XCTest
import NostromoKit

/// The plan viewer's document model: a lossy-safe, sanitised, URL-preserving (links) and
/// URL-free (images) reading of a markdown plan. Policy about which links may be opened is the
/// view's job; the model only carries what was written.
final class PlanMarkdownTests: XCTestCase {

    // MARK: Helpers (read the model from the outside)

    private func parse(_ name: String) throws -> PlanDocument {
        PlanMarkdown.parse(try PlanFixtures.text(name))
    }

    /// Every block in the document in pre-order: a container comes before its children.
    private func flatten(_ blocks: [PlanBlock]) -> [PlanBlock] {
        var out: [PlanBlock] = []
        func visit(_ block: PlanBlock) {
            out.append(block)
            switch block.kind {
            case .list(_, _, let items):
                for item in items { item.blocks.forEach(visit) }
            case .quote(let children):
                children.forEach(visit)
            default:
                break
            }
        }
        blocks.forEach(visit)
        return out
    }

    private func allBlocks(_ doc: PlanDocument) -> [PlanBlock] { flatten(doc.blocks) }

    private func kindName(_ block: PlanBlock) -> String {
        switch block.kind {
        case .heading: return "heading"
        case .paragraph: return "paragraph"
        case .list: return "list"
        case .codeBlock: return "codeBlock"
        case .table: return "table"
        case .quote: return "quote"
        case .rule: return "rule"
        }
    }

    /// The span lists directly owned by one block (not its child blocks').
    private func spanLists(_ block: PlanBlock) -> [[PlanSpan]] {
        switch block.kind {
        case .heading(_, let spans): return [spans]
        case .paragraph(let spans): return [spans]
        case .table(let header, let rows): return header + rows.flatMap { $0 }
        default: return []
        }
    }

    /// Spans and all their descendants, containers first.
    private func descend(_ spans: [PlanSpan]) -> [PlanSpan] {
        var out: [PlanSpan] = []
        for span in spans {
            out.append(span)
            switch span {
            case .emph(let inner), .strong(let inner), .strike(let inner), .link(let inner, _):
                out += descend(inner)
            case .text, .code, .image:
                break
            }
        }
        return out
    }

    private func allSpans(_ doc: PlanDocument) -> [PlanSpan] {
        allBlocks(doc).flatMap { spanLists($0) }.flatMap { descend($0) }
    }

    private func headings(_ doc: PlanDocument) -> [(index: Int, level: Int, text: String)] {
        allBlocks(doc).compactMap { block in
            if case .heading(let level, let spans) = block.kind { return (block.index, level, spans.plainText) }
            return nil
        }
    }

    private func codeBlocks(_ doc: PlanDocument) -> [(lang: String?, text: String)] {
        allBlocks(doc).compactMap { block in
            if case .codeBlock(let lang, let text) = block.kind { return (lang, text) }
            return nil
        }
    }

    private func paragraphTexts(_ doc: PlanDocument) -> [String] {
        allBlocks(doc).compactMap { block in
            if case .paragraph(let spans) = block.kind { return spans.plainText }
            return nil
        }
    }

    private func lists(_ doc: PlanDocument) -> [(ordered: Bool, start: Int, items: [PlanListItem])] {
        allBlocks(doc).compactMap { block in
            if case .list(let ordered, let start, let items) = block.kind { return (ordered, start, items) }
            return nil
        }
    }

    /// Every list item in document order: an item, then the items nested inside it, then its next sibling.
    private func listItems(_ doc: PlanDocument) -> [PlanListItem] {
        func walk(_ items: [PlanListItem]) -> [PlanListItem] {
            items.flatMap { item in
                [item] + item.blocks.flatMap { block -> [PlanListItem] in
                    if case .list(_, _, let inner) = block.kind { return walk(inner) }
                    return []
                }
            }
        }
        func walkBlocks(_ blocks: [PlanBlock]) -> [PlanListItem] {
            blocks.flatMap { block -> [PlanListItem] in
                switch block.kind {
                case .list(_, _, let items): return walk(items)
                case .quote(let inner): return walkBlocks(inner)
                default: return []
                }
            }
        }
        return walkBlocks(doc.blocks)
    }

    /// The first paragraph of a list item: its own text, not its nested content.
    private func itemText(_ item: PlanListItem) -> String? {
        for block in item.blocks {
            if case .paragraph(let spans) = block.kind { return spans.plainText }
        }
        return nil
    }

    private func nestedItems(_ item: PlanListItem) -> [PlanListItem]? {
        for block in item.blocks {
            if case .list(_, _, let items) = block.kind { return items }
        }
        return nil
    }

    private func taskItems(_ doc: PlanDocument) -> [PlanListItem] { listItems(doc).filter { $0.task != nil } }

    private func links(_ doc: PlanDocument) -> [(text: String, url: String)] {
        allSpans(doc).compactMap { span in
            if case .link(let inner, let url) = span { return (inner.plainText, url) }
            return nil
        }
    }

    private func dumped(_ value: Any) -> String {
        var out = ""
        dump(value, to: &out)
        return out
    }

    /// Plain text a person would read, for "does the word survive" assertions.
    private func everything(_ doc: PlanDocument) -> String {
        var parts: [String] = []
        for block in allBlocks(doc) {
            parts += spanLists(block).map { $0.plainText }
            if case .codeBlock(_, let text) = block.kind { parts.append(text) }
        }
        return parts.joined(separator: "\n")
    }

    // MARK: Empty and trivial input

    func testEmptyInputGivesAnEmptyDocument() {
        let doc = PlanMarkdown.parse("")

        XCTAssertTrue(doc.blocks.isEmpty)
        XCTAssertTrue(doc.outline.isEmpty)
    }

    func testWhitespaceOnlyInputShowsNothing() {
        for text in ["   ", "\n\n\n", " \t \n  \n", "\r\n\r\n"] {
            let doc = PlanMarkdown.parse(text)

            XCTAssertTrue(doc.outline.isEmpty, text.debugDescription)
            XCTAssertTrue(everything(doc).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          "visible content from \(text.debugDescription)")
        }
    }

    func testAHeadingAndAParagraphAreTwoBlocks() {
        let doc = PlanMarkdown.parse("# Title\n\nbody text\n")

        XCTAssertEqual(doc.blocks.count, 2)
        XCTAssertEqual(headings(doc).map { $0.level }, [1])
        XCTAssertEqual(headings(doc).map { $0.text }, ["Title"])
        XCTAssertEqual(paragraphTexts(doc), ["body text"])
    }

    func testHeadingLevelsOneToSixAreReported() {
        for level in 1 ... 6 {
            let doc = PlanMarkdown.parse(String(repeating: "#", count: level) + " Heading\n")

            XCTAssertEqual(headings(doc).map { $0.level }, [level])
        }
    }

    func testAThematicBreakIsARule() {
        let doc = PlanMarkdown.parse("above\n\n---\n\nbelow\n")

        XCTAssertEqual(doc.blocks.map(kindName), ["paragraph", "rule", "paragraph"])
    }

    func testASoftLineBreakInAParagraphReadsAsASpace() {
        XCTAssertEqual(paragraphTexts(PlanMarkdown.parse("one\ntwo\n")), ["one two"])
    }

    func testInlineHTMLIsShownAsLiteralText() {
        let text = paragraphTexts(PlanMarkdown.parse("a <b>bold</b> c\n")).joined()

        XCTAssertTrue(text.contains("<b>"), text)
    }

    // MARK: plan-full: block kinds, headings, outline

    func testPlanFullContainsEveryBlockKind() throws {
        let kinds = Set(allBlocks(try parse("plan-full.md")).map(kindName))

        XCTAssertEqual(kinds, ["heading", "paragraph", "list", "codeBlock", "table", "quote", "rule"])
    }

    func testPlanFullHasHeadingsAtLevelsOneToFour() throws {
        let levels = Set(headings(try parse("plan-full.md")).map { $0.level })

        XCTAssertTrue(levels.isSuperset(of: [1, 2, 3, 4]), "\(levels)")
    }

    func testPlanFullOutlineHasEveryHeadingInDocumentOrderWithPlainTextTitles() throws {
        let outline = try parse("plan-full.md").outline

        let expected: [(Int, String)] = [
            (1, "Plan: Ship the plan viewer"),
            (2, "Background"),
            (2, "Goals"),
            (3, "Scope"),
            (4, "Out of scope"),
            (2, "Tasks"),
            (2, "Data"),
            (2, "Config"),
            (2, "References"),
            (3, "Links"),
            (3, "Notes"),
            (2, "Rollout v2 plan"),
        ]
        XCTAssertEqual(outline.map { $0.level }, expected.map { $0.0 })
        XCTAssertEqual(outline.map { $0.title }, expected.map { $0.1 })
    }

    func testOutlineEntriesPointAtTheirHeadingBlocksInIncreasingOrder() throws {
        for name in PlanFixtures.all {
            let doc = try parse(name)
            let byIndex = Dictionary(uniqueKeysWithValues: allBlocks(doc).map { ($0.index, $0) })

            XCTAssertEqual(doc.outline.count, headings(doc).count, name)
            XCTAssertEqual(doc.outline.map { $0.blockIndex }, doc.outline.map { $0.blockIndex }.sorted(), name)
            for entry in doc.outline {
                guard let block = byIndex[entry.blockIndex], case .heading(let level, let spans) = block.kind else {
                    XCTFail("\(name): outline entry \(entry.title) does not point at a heading block")
                    continue
                }
                XCTAssertEqual(level, entry.level, name)
                XCTAssertEqual(spans.plainText, entry.title, name)
            }
        }
    }

    func testHeadingsInsideAQuoteAreInTheOutlineInDocumentOrder() {
        let doc = PlanMarkdown.parse("> ## Quoted heading\n>\n> words\n\n# Top\n")

        XCTAssertEqual(doc.outline.map { $0.title }, ["Quoted heading", "Top"])
        XCTAssertEqual(doc.outline.map { $0.level }, [2, 1])
        XCTAssertEqual(Set(doc.outline.map { $0.blockIndex }).count, 2)
    }

    // MARK: plan-full: lists

    func testNestedListsThreeDeepKeepTheirStructure() throws {
        let doc = try parse("plan-full.md")
        guard let top = lists(doc).first(where: { $0.items.first.flatMap(itemText) == "Level one alpha" }) else {
            return XCTFail("no list starting with 'Level one alpha'")
        }

        XCTAssertFalse(top.ordered)
        XCTAssertEqual(top.items.compactMap(itemText), ["Level one alpha", "Level one epsilon"])
        XCTAssertNil(nestedItems(top.items[1]), "the second top-level item has no children")

        guard let second = nestedItems(top.items[0]) else { return XCTFail("level one alpha has no nested list") }
        XCTAssertEqual(second.compactMap(itemText), ["Level two beta", "Level two delta"])
        XCTAssertNil(nestedItems(second[1]))

        guard let third = nestedItems(second[0]) else { return XCTFail("level two beta has no nested list") }
        XCTAssertEqual(third.compactMap(itemText), ["Level three gamma"])
        XCTAssertNil(nestedItems(third[0]))
    }

    func testOrderedAndUnorderedListsAreToldApart() throws {
        let all = lists(try parse("plan-full.md"))
        let ordered = all.filter { $0.ordered }

        XCTAssertTrue(all.contains { !$0.ordered })
        XCTAssertEqual(ordered.count, 1)
        XCTAssertEqual(ordered.first?.items.compactMap(itemText),
                       ["First ordered step", "Second ordered step", "Third ordered step"])
        XCTAssertEqual(ordered.first?.start, 1)
    }

    // MARK: plan-full: table, code, quote

    func testTheTwelveColumnTableKeepsEveryColumn() throws {
        let tables = allBlocks(try parse("plan-full.md")).compactMap { block -> ([[PlanSpan]], [[[PlanSpan]]])? in
            if case .table(let header, let rows) = block.kind { return (header, rows) }
            return nil
        }

        XCTAssertEqual(tables.count, 1)
        guard let (header, rows) = tables.first else { return }
        XCTAssertEqual(header.count, 12)
        XCTAssertEqual(header.map { $0.plainText }, (1 ... 12).map { "col\($0)" })
        XCTAssertEqual(rows.count, 3)
        for (r, row) in rows.enumerated() {
            XCTAssertEqual(row.count, 12, "row \(r + 1)")
            XCTAssertEqual(row.map { $0.plainText }, (1 ... 12).map { "r\(r + 1)c\($0)" })
        }
    }

    func testTheYamlBlockHasItsLanguageAndKeepsA300CharacterLineIntact() throws {
        let yaml = codeBlocks(try parse("plan-full.md")).filter { $0.lang == "yaml" }

        XCTAssertEqual(yaml.count, 1)
        guard let block = yaml.first else { return }
        let lines = block.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let long = lines.first { $0.hasPrefix("description: ") }
        let expectedLong = "description: " + String(String(repeating: "0123456789", count: 29).prefix(287))
        XCTAssertEqual(long?.count, 300)
        XCTAssertEqual(long, expectedLong)
        XCTAssertTrue(lines.contains("name: plan-viewer"))
        XCTAssertTrue(lines.contains("  - render"), "indentation is kept")
    }

    func testTheBlockQuoteHoldsItsParagraph() throws {
        let doc = try parse("plan-full.md")
        let quotes = allBlocks(doc).compactMap { block -> [PlanBlock]? in
            if case .quote(let children) = block.kind { return children }
            return nil
        }

        XCTAssertEqual(quotes.count, 1)
        let texts = flatten(quotes.first ?? []).compactMap { block -> String? in
            if case .paragraph(let spans) = block.kind { return spans.plainText }
            return nil
        }
        XCTAssertEqual(texts, ["Measure twice, cut once."])
    }

    // MARK: plan-full: inline spans

    func testEmphasisStrongStrikethroughAndCodeSpansAreModelled() throws {
        let spans = allSpans(try parse("plan-full.md"))

        XCTAssertTrue(spans.contains { if case .emph(let s) = $0 { return s.plainText == "emph-word" } else { return false } })
        XCTAssertTrue(spans.contains { if case .strong(let s) = $0 { return s.plainText == "strong-word" } else { return false } })
        XCTAssertTrue(spans.contains { if case .strike(let s) = $0 { return s.plainText == "strike-word" } else { return false } })
        XCTAssertTrue(spans.contains { if case .code(let s) = $0 { return s == "code-word" } else { return false } })
    }

    func testAHeadingWithInlineCodeHasThePlainTextOfItsSpans() throws {
        let rollout = headings(try parse("plan-full.md")).first { $0.text.hasPrefix("Rollout") }

        XCTAssertEqual(rollout?.text, "Rollout v2 plan")
    }

    func testPlainTextConcatenatesVisibleTextWithoutURLs() {
        let spans: [PlanSpan] = [
            .text("a"),
            .strong([.text("b"), .emph([.text("c")])]),
            .strike([.text("d")]),
            .code("e"),
            .link([.text("f")], url: "https://hidden.invalid/path"),
            .image(alt: "g"),
        ]

        XCTAssertEqual(spans.plainText, "abcdefg")
        XCTAssertFalse(spans.plainText.contains("hidden.invalid"))
        XCTAssertEqual([PlanSpan]().plainText, "")
    }

    // MARK: Links and images

    func testEveryLinkURLIsKeptVerbatimAsWritten() throws {
        let found = links(try parse("plan-full.md")).map { "\($0.text) -> \($0.url)" }

        XCTAssertTrue(found.contains("the spec -> https://example.invalid/spec"), "\(found)")
        XCTAssertTrue(found.contains("local notes -> file:///tmp/notes.md"), "\(found)")
        XCTAssertTrue(found.contains("relative spec -> docs/spec.md"), "\(found)")
        XCTAssertTrue(found.contains("click me -> javascript:alert(1)"), "\(found)")
    }

    func testARemoteImageBecomesItsAltTextAndItsURLIsNowhereInTheModel() throws {
        let doc = try parse("plan-full.md")

        XCTAssertTrue(allSpans(doc).contains { if case .image(let alt) = $0 { return alt == "diagram" } else { return false } })
        for rendering in [dumped(doc), String(describing: doc), String(reflecting: doc)] {
            XCTAssertFalse(rendering.contains("diagram.png"))
            XCTAssertFalse(rendering.contains("example.invalid/diagram"))
        }
        // The links' own URLs are in the model, so the check above is not vacuous.
        XCTAssertTrue(dumped(doc).contains("example.invalid/spec"))
    }

    func testAnImageWithQueryStringLeavesNoTraceOfItsURL() {
        let doc = PlanMarkdown.parse("before ![alt text](https://secret.invalid/pixel.gif?token=abc123) after\n")

        XCTAssertTrue(allSpans(doc).contains { if case .image(let alt) = $0 { return alt == "alt text" } else { return false } })
        let rendering = dumped(doc)
        XCTAssertFalse(rendering.contains("secret.invalid"))
        XCTAssertFalse(rendering.contains("abc123"))
        XCTAssertFalse(rendering.contains("pixel.gif"))
    }

    func testAnImageInsideALinkKeepsTheLinkAndDropsTheImageURL() {
        let doc = PlanMarkdown.parse("[![badge](https://img.invalid/b.svg)](https://target.invalid/x)\n")

        // Foundation hands an image inside a link over as the link's text: the label survives, the image URL does not.
        XCTAssertEqual(links(doc).map { $0.url }, ["https://target.invalid/x"])
        XCTAssertEqual(links(doc).map { $0.text }, ["badge"])
        XCTAssertFalse(dumped(doc).contains("img.invalid"))
    }

    // MARK: Task items

    func testPlanFullHasSevenTaskItemsOfWhichThreeAreDone() throws {
        let tasks = taskItems(try parse("plan-full.md"))

        XCTAssertEqual(tasks.count, 7)
        XCTAssertEqual(tasks.compactMap { $0.task }, [false, true, false, true, false, false, true])
        XCTAssertEqual(tasks.filter { $0.task == true }.count, 3)
        XCTAssertEqual(tasks.compactMap(itemText), ["Write the parser", "Write the fixtures", "Wire the sidebar",
                                                    "Review the sanitiser", "Add the outline", "Ship it", "Celebrate"])
    }

    func testTheTaskMarkerIsRemovedFromTheSpans() {
        let doc = PlanMarkdown.parse("- [ ] open item\n- [x] closed item\n- [X] shouted item\n")
        let tasks = taskItems(doc)

        XCTAssertEqual(tasks.compactMap { $0.task }, [false, true, true])
        XCTAssertEqual(tasks.compactMap(itemText), ["open item", "closed item", "shouted item"])
        XCTAssertFalse(everything(doc).contains("["))
    }

    func testListItemsWithoutAMarkerAreNotTasks() {
        let doc = PlanMarkdown.parse("- [ ] a\n- plain\n- [y] odd\n")
        let items = listItems(doc)

        XCTAssertEqual(items.map { $0.task }, [false, nil, nil])
        XCTAssertEqual(items.compactMap(itemText).dropFirst().first, "plain")
        XCTAssertEqual(items.compactMap(itemText).last, "[y] odd")
    }

    func testTaskItemsAgreeWithTheChecklistParserForEveryFixture() throws {
        for name in PlanFixtures.all {
            let text = try PlanFixtures.text(name)
            let tasks = taskItems(PlanMarkdown.parse(text))
            let checklist = PlanChecklist.parse(text)

            XCTAssertEqual(tasks.count, checklist.count, "\(name): task count")
            XCTAssertEqual(tasks.filter { $0.task == true }.count, checklist.filter { $0.done }.count, "\(name): done count")
            XCTAssertEqual(tasks.compactMap { $0.task }, checklist.map { $0.done }, "\(name): order and state")
        }
    }

    func testATaskItemWithNestedContentStillCountsAndKeepsItsChildren() throws {
        let doc = try parse("plan-task-nested.md")
        let tasks = taskItems(doc)

        XCTAssertEqual(tasks.count, 5)
        XCTAssertEqual(tasks.filter { $0.task == true }.count, 3)
        XCTAssertEqual(tasks.compactMap(itemText), ["parent task", "child task one", "child task two",
                                                    "grandchild task", "sibling"])

        guard let top = lists(doc).first else { return XCTFail("no list") }
        XCTAssertEqual(top.items.count, 3, "parent, sibling, and the item that is not a task")
        XCTAssertEqual(top.items.map { $0.task }, [false, true, nil])
        XCTAssertEqual(nestedItems(top.items[0])?.compactMap(itemText), ["child task one", "child task two"])
        XCTAssertEqual(nestedItems(top.items[0])?.compactMap { $0.task }, [true, false])
    }

    func testAnEmptyTaskMarkerIsNotATaskJustLikeTheChecklist() {
        let text = "- [ ]\n- [x]\n"

        XCTAssertEqual(PlanChecklist.parse(text).count, 0)
        XCTAssertEqual(taskItems(PlanMarkdown.parse(text)).count, 0)
    }

    // MARK: Block indexes

    func testBlockIndexesAreUniqueAndFollowDocumentOrderForEveryFixture() throws {
        for name in PlanFixtures.all {
            let indexes = allBlocks(try parse(name)).map { $0.index }

            XCTAssertEqual(Set(indexes).count, indexes.count, "\(name): duplicate block index")
            XCTAssertEqual(indexes, indexes.sorted(), "\(name): indexes must be pre-order (container before children)")
        }
    }

    func testAContainerGetsItsIndexBeforeItsChildren() {
        let doc = PlanMarkdown.parse("> quoted one\n>\n> - nested item\n\nafter\n")
        guard case .quote(let children)? = doc.blocks.first?.kind, let outer = doc.blocks.first else {
            return XCTFail("first block is not a quote")
        }

        XCTAssertTrue(flatten(children).allSatisfy { $0.index > outer.index })
        XCTAssertTrue(doc.blocks.dropFirst().allSatisfy { $0.index > flatten(children).map { $0.index }.max()! })
    }

    func testParsingTheSameInputTwiceGivesTheSameDocumentAndIndexes() throws {
        for name in PlanFixtures.all {
            let text = try PlanFixtures.text(name)
            let first = PlanMarkdown.parse(text)
            let second = PlanMarkdown.parse(text)

            XCTAssertEqual(first, second, name)
            XCTAssertEqual(allBlocks(first).map { $0.index }, allBlocks(second).map { $0.index }, name)
            XCTAssertEqual(first.outline, second.outline, name)
        }
    }

    // MARK: Robustness

    func testAOneMebibyteDocumentIsParsedWithoutCrashing() {
        var text = ""
        text.reserveCapacity(1_100_000)
        var i = 0
        while text.utf8.count < 1_048_576 {
            if i % 50 == 0 { text += "## Heading \(i)\n\n" }
            text += "Paragraph \(i) with *emphasis* and `code` and a [link](https://example.invalid/\(i)).\n\n"
            i += 1
        }
        let doc = PlanMarkdown.parse(text)

        XCTAssertFalse(doc.blocks.isEmpty)
        XCTAssertEqual(doc.outline.first?.title, "Heading 0")
    }

    func testTwoHundredNestedQuotesReturnADocument() {
        let doc = PlanMarkdown.parse(String(repeating: ">", count: 200) + " deep-word\n")

        XCTAssertFalse(doc.blocks.isEmpty)
        let indexes = allBlocks(doc).map { $0.index }
        XCTAssertEqual(Set(indexes).count, indexes.count)
    }

    func testTwoHundredNestedListLevelsReturnADocument() {
        let text = (0 ..< 200).map { String(repeating: "  ", count: $0) + "- level \($0)" }.joined(separator: "\n") + "\n"
        let doc = PlanMarkdown.parse(text)

        XCTAssertFalse(doc.blocks.isEmpty)
        let indexes = allBlocks(doc).map { $0.index }
        XCTAssertEqual(Set(indexes).count, indexes.count)
    }

    func testAnUnterminatedFenceKeepsItsContentAndReturns() {
        for text in ["```swift\nlet x = 1\nstill code", "~~~\nlet x = 1\n", "```"] {
            let doc = PlanMarkdown.parse(text)

            if text.contains("let x = 1") {
                XCTAssertTrue(everything(doc).contains("let x = 1"), text.debugDescription)
            }
        }
    }

    func testMarkdownShapedGarbageNeverBreaksTheModelsInvariants() {
        let alphabet: [Character] = Array("#*_`[]()<>|~-+=!\\\n\n  \t0123456789abcXYZ>:.é日🚀") + ["\u{0}", "\u{1B}", "\u{202E}", "\r"]
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(state >> 33)
        }
        for round in 0 ..< 25 {
            var text = ""
            for _ in 0 ..< 4_000 { text.append(alphabet[next() % alphabet.count]) }
            let doc = PlanMarkdown.parse(text)

            let blocks = allBlocks(doc)
            let indexes = blocks.map { $0.index }
            XCTAssertEqual(Set(indexes).count, indexes.count, "round \(round): duplicate index")
            XCTAssertEqual(indexes, indexes.sorted(), "round \(round): not pre-order")
            XCTAssertEqual(doc.outline.count, headings(doc).count, "round \(round): outline and headings disagree")
        }
    }

    // MARK: Hostile content

    /// Scalars that must not survive anywhere in the model. `\n` and `\t` are allowed in code only.
    private func isForbidden(_ scalar: Unicode.Scalar, inCode: Bool) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A:
            return !inCode
        case 0x00 ... 0x1F, 0x7F, 0x80 ... 0x9F,
             0x061C, 0x200B ... 0x200F, 0x2028 ... 0x202E, 0x2060 ... 0x2064, 0x2066 ... 0x2069,
             0xFEFF, 0xFFF9 ... 0xFFFB, 0xE0000 ... 0xE007F,
             0x034F, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x2800, 0x3164, 0xFFA0:
            return true
        default:
            return false
        }
    }

    private func forbiddenScalars(in doc: PlanDocument) -> [String] {
        var found: [String] = []
        func check(_ text: String, inCode: Bool, where place: String) {
            for scalar in text.unicodeScalars where isForbidden(scalar, inCode: inCode) {
                found.append("U+\(String(scalar.value, radix: 16, uppercase: true)) in \(place): \(text.prefix(40).debugDescription)")
            }
        }
        for block in allBlocks(doc) {
            for spans in spanLists(block) {
                for span in descend(spans) {
                    switch span {
                    case .text(let s): check(s, inCode: false, where: "text span")
                    case .code(let s): check(s, inCode: false, where: "code span")
                    case .image(let alt): check(alt, inCode: false, where: "image alt")
                    default: break
                    }
                }
            }
            if case .codeBlock(_, let text) = block.kind { check(text, inCode: true, where: "code block") }
        }
        for entry in doc.outline { check(entry.title, inCode: false, where: "outline title") }
        return found
    }

    func testTheHostileFixtureReallyContainsEveryKindOfHostileScalar() throws {
        let scalars = Set(try PlanFixtures.text("plan-hostile.md").unicodeScalars.map { $0.value })
        let expected: [UInt32] = [0x202E, 0x2066, 0x2067, 0x2068, 0x2069, 0x200B, 0x2060, 0xFEFF,
                                  0x034F, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x2800, 0x3164, 0xFFA0,
                                  0x1B, 0x00, 0x2028, 0x2029, 0x09]

        for value in expected {
            XCTAssertTrue(scalars.contains(value), "fixture lacks U+\(String(value, radix: 16, uppercase: true))")
        }
    }

    func testNoForbiddenScalarSurvivesAnywhereInTheHostileModel() throws {
        let doc = try parse("plan-hostile.md")

        XCTAssertEqual(forbiddenScalars(in: doc), [])
    }

    func testNoEscapeSequenceDebrisOrHiddenLinkTargetSurvivesFromTheHostileFixture() throws {
        let rendering = dumped(try parse("plan-hostile.md"))

        XCTAssertFalse(rendering.contains("evil.invalid"), "the OSC 8 target must go with its sequence")
        XCTAssertFalse(rendering.contains("[31m"))
        XCTAssertFalse(rendering.contains("[0m"))
    }

    func testTheWordsAroundHostileScalarsSurviveInEveryBlockKind() throws {
        let doc = try parse("plan-hostile.md")

        // heading
        XCTAssertEqual(doc.outline.count, 1)
        let title = doc.outline.first?.title ?? ""
        XCTAssertTrue(title.contains("safe-heading"), title)
        XCTAssertTrue(title.contains("end-heading"), title)

        // paragraph
        let para = paragraphTexts(doc).first { $0.contains("safe-para") } ?? ""
        for word in ["safe-para", "red-para", "link-para", "nul-para", "sep-para", "end-para", "fill-para", "zw-para"] {
            XCTAssertTrue(para.contains(word), "\(word) missing from \(para.debugDescription)")
        }
        XCTAssertTrue(paragraphTexts(doc).contains { $0.contains("tail-para") })

        // list items
        let items = listItems(doc).compactMap(itemText)
        XCTAssertEqual(items.count, 2, "\(items)")
        for word in ["safe-item", "zw-item", "fill-item"] {
            XCTAssertTrue(items.first?.contains(word) == true, "\(word) missing from \(items)")
        }
        XCTAssertTrue(items.last?.contains("second-item") == true && items.last?.contains("ansi-item") == true, "\(items)")

        // table
        let cells = allBlocks(doc).compactMap { block -> [String]? in
            if case .table(let header, let rows) = block.kind {
                return (header + rows.flatMap { $0 }).map { $0.plainText }
            }
            return nil
        }.first ?? []
        XCTAssertEqual(cells.count, 4, "\(cells)")
        XCTAssertTrue(cells.contains("head-a") && cells.contains("head-b"), "\(cells)")
        XCTAssertTrue(cells.contains { $0.contains("safe-cell") }, "\(cells)")
        XCTAssertTrue(cells.contains("cell-two"), "\(cells)")
    }

    func testAHostileCodeBlockStillHasItsLinesAndItsTab() throws {
        let doc = try parse("plan-hostile.md")
        let blocks = codeBlocks(doc)

        XCTAssertEqual(blocks.count, 1)
        guard let code = blocks.first?.text else { return }
        XCTAssertTrue(code.contains("\n"), "newlines survive in code")
        XCTAssertTrue(code.split(separator: "\n").count >= 5, code.debugDescription)
        XCTAssertTrue(code.contains("\tindented-line-zw"), "the tab survives: \(code.debugDescription)")
        for word in ["line-one", "line-three", "ansi-code", "fill-line", "code-two"] {
            XCTAssertTrue(code.contains(word), "\(word) missing from \(code.debugDescription)")
        }
    }

    // MARK: Scale (no wall clock)

    func testPlan2000LinesHasTheExpectedShape() throws {
        let doc = try parse("plan-2000-lines.md")

        // Per section: heading, 3 paragraphs, and 3 lists (bullets, steps, tasks).
        XCTAssertEqual(doc.blocks.count, 80 * 7)
        XCTAssertEqual(doc.outline.count, 80)
        XCTAssertEqual(lists(doc).count, 80 * 3)
        XCTAssertEqual(taskItems(doc).count, 320)
        XCTAssertEqual(taskItems(doc).filter { $0.task == true }.count, 107)
        XCTAssertEqual(doc.outline.first?.level, 1)
        XCTAssertEqual(doc.outline.first?.title, "Plan")
    }

    func testPlan2000LinesOutlineFindsEverySectionAtItsLevel() throws {
        let outline = try parse("plan-2000-lines.md").outline

        XCTAssertEqual(Set(outline.map { $0.title }).count, outline.count, "titles are unique")
        for i in 1 ..< 80 {
            let expectedLevel = i % 10 == 0 ? 1 : (i % 2 == 0 ? 2 : 3)
            let matches = outline.filter { $0.title.hasPrefix("Section \(i):") }

            XCTAssertEqual(matches.count, 1, "Section \(i)")
            XCTAssertEqual(matches.first?.level, expectedLevel, "Section \(i)")
        }
        XCTAssertEqual(outline.filter { $0.title.hasPrefix("Section 17:") }.first?.level, 3)
        XCTAssertEqual(outline.filter { $0.title.hasPrefix("Section 40:") }.first?.level, 1)
    }

    func testDoublingTheInputExactlyDoublesTheBlocksNotMore() throws {
        let text = try PlanFixtures.text("plan-2000-lines.md")
        let one = PlanMarkdown.parse(text)
        let two = PlanMarkdown.parse(text + "\n" + text)

        XCTAssertEqual(two.blocks.count, 2 * one.blocks.count)
        XCTAssertEqual(two.outline.count, 2 * one.outline.count)
        XCTAssertEqual(allBlocks(two).count, 2 * allBlocks(one).count)
        XCTAssertEqual(taskItems(two).count, 2 * taskItems(one).count)
        let indexes = allBlocks(two).map { $0.index }
        XCTAssertEqual(Set(indexes).count, indexes.count)
    }
}
