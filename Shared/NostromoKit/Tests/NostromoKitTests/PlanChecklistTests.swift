import XCTest
import NostromoKit

/// The checklist parser keeps the semantics of the old Mac regex `^\s*- \[([ xX])\]\s+(.+)$`
/// applied to each newline-separated line. It does not know about markdown structure.
final class PlanChecklistTests: XCTestCase {

    /// `[ ] text` / `[x] text`, one string per item, so tests read as the old results did.
    private func rendered(_ text: String) -> [String] {
        PlanChecklist.parse(text).map { "[\($0.done ? "x" : " ")] \($0.text)" }
    }

    // MARK: The old inputs

    func testTwoItemsOneDoneComeBackInOrder() {
        let items = PlanChecklist.parse("- [ ] first\n- [x] second\n")

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map(\.done), [false, true])
        XCTAssertEqual(items.map(\.text), ["first", "second"])
    }

    func testASingleItemIsOneItem() {
        let items = PlanChecklist.parse("- [ ] only one\n")

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.done, false)
        XCTAssertEqual(items.first?.text, "only one")
    }

    func testAFinalLineWithoutANewlineStillCounts() {
        XCTAssertEqual(rendered("- [ ] a\n- [x] last"), ["[ ] a", "[x] last"])
    }

    // MARK: Marker and spacing

    func testUppercaseXIsDone() {
        XCTAssertEqual(rendered("- [X] shouting"), ["[x] shouting"])
    }

    func testIndentedAndNestedItemsMatch() {
        let text = "- [ ] top\n  - [x] two spaces\n    - [ ] four spaces\n\t- [X] a tab\n"

        XCTAssertEqual(rendered(text), ["[ ] top", "[x] two spaces", "[ ] four spaces", "[x] a tab"])
    }

    func testAnyWhitespaceRunAfterTheBracketIsDropped() {
        XCTAssertEqual(rendered("- [ ]\ttabbed"), ["[ ] tabbed"])
        XCTAssertEqual(rendered("- [x]    padded"), ["[x] padded"])
        XCTAssertEqual(rendered("- [ ] \t mixed"), ["[ ] mixed"])
    }

    func testBracketsInsideTheTextAreKept() {
        XCTAssertEqual(rendered("- [ ] fix [bug] in x"), ["[ ] fix [bug] in x"])
    }

    func testCRLFLineEndingsDoNotLeakACarriageReturnIntoTheText() {
        let items = PlanChecklist.parse("- [ ] first\r\n- [x] second\r\n")

        XCTAssertEqual(items.map(\.text), ["first", "second"])
        XCTAssertEqual(items.map(\.done), [false, true])
        XCTAssertFalse(items.contains { $0.text.contains("\r") })
    }

    // MARK: Lines that are not checklist items

    func testLinesThatDoNotMatchTheOldRegexAreIgnored() {
        let nonMatching = [
            "- [ ]",          // no text
            "* [ ] star bullet",
            "-[ ] no space after the dash",
            "- [y] unknown marker",
            "- [] empty marker",
            "- [  ] two spaces in the marker",
            "- [ ]no space after the bracket",
            "[ ] no dash",
            "text before - [ ] item",
            "- plain bullet",
            "1. [ ] ordered",
            "",
            "   ",
        ]
        for line in nonMatching {
            XCTAssertEqual(PlanChecklist.parse(line + "\n"), [], "matched: \(line.debugDescription)")
        }
    }

    func testOnlyMatchingLinesCountInAMixedDocument() {
        let text = """
        # Plan

        Some prose.
        - [ ] real one
        * [ ] star
        - [x] real two
        -[ ] glued
        - [y] odd
        """

        XCTAssertEqual(rendered(text), ["[ ] real one", "[x] real two"])
    }

    func testAnEmptyStringHasNoItems() {
        XCTAssertEqual(PlanChecklist.parse(""), [])
    }

    // MARK: Text content

    func testUnicodeTextIsKeptExactly() {
        let items = PlanChecklist.parse("- [x] résumé — 日本語 🚀\n- [ ] 👩\u{200D}👩\u{200D}👧 family\n")

        XCTAssertEqual(items.map(\.text), ["résumé — 日本語 🚀", "👩\u{200D}👩\u{200D}👧 family"])
        XCTAssertEqual(items.map(\.done), [true, false])
    }

    // MARK: Structure-blindness (old behaviour)

    func testALineInsideAFencedCodeBlockStillMatches() {
        let text = "```\n- [ ] inside the fence\n```\n- [x] outside\n"

        XCTAssertEqual(rendered(text), ["[ ] inside the fence", "[x] outside"])
    }

    // MARK: Scale

    func testATwoThousandLineFileIsParsedInFullAndInOrder() {
        var lines: [String] = []
        for i in 0 ..< 2_000 {
            if i % 2 == 0 {
                lines.append("- [\(i % 4 == 0 ? "x" : " ")] item \(i)")
            } else {
                lines.append("prose line \(i)")
            }
        }
        let items = PlanChecklist.parse(lines.joined(separator: "\n") + "\n")

        XCTAssertEqual(items.count, 1_000)
        XCTAssertEqual(items.filter(\.done).count, 500)
        XCTAssertEqual(items.first?.text, "item 0")
        XCTAssertEqual(items.last?.text, "item 1998")
        XCTAssertEqual(items.map(\.text), (0 ..< 1_000).map { "item \($0 * 2)" })
    }

    // MARK: Fixtures

    func testPlanFullHasSevenItemsOfWhichThreeAreChecked() throws {
        let items = PlanChecklist.parse(try PlanFixtures.text("plan-full.md"))

        XCTAssertEqual(items.count, 7)
        XCTAssertEqual(items.filter(\.done).count, 3)
        XCTAssertEqual(items.map(\.text), ["Write the parser", "Write the fixtures", "Wire the sidebar",
                                           "Review the sanitiser", "Add the outline", "Ship it", "Celebrate"])
        XCTAssertEqual(items.map(\.done), [false, true, false, true, false, false, true])
    }

    func testThePlan2000LinesFixtureHas320ItemsOf107Checked() throws {
        let text = try PlanFixtures.text("plan-2000-lines.md")
        let items = PlanChecklist.parse(text)

        XCTAssertEqual(items.count, 320)
        XCTAssertEqual(items.filter(\.done).count, 107)
    }

    func testThePlanHostileFixtureHasNoItems() throws {
        XCTAssertEqual(PlanChecklist.parse(try PlanFixtures.text("plan-hostile.md")), [])
    }
}
