// NostromoKit — ApprovalQuestionsTests.swift
//
// AP2c: answering the CLI's `AskUserQuestion` from the approval card. These tests pin what the
// card may treat as an answerable set of questions (`ApprovalQuestions.parse`: the same rules as
// the daemon's `parse_questions` in `src/approvals/questions.rs`) and how the form's selection
// for one question behaves (`ApprovalQuestionSelection`), including exactly what goes on the
// wire (`answer(for:)`, `ApprovalQuestions.answers`).
//
// The daemon refuses an answer that does not fit the questions (and then the request stays held,
// so the person is stuck with Deny). The invariant that matters most here: whenever the form says
// a question is answered, the answer it builds is one the daemon accepts.

import XCTest
@testable import NostromoKit

final class ApprovalQuestionsTests: XCTestCase {

    // MARK: - Builders

    private static func option(_ label: String, description: String? = nil,
                               extra: [String: ApprovalJSON] = [:]) -> ApprovalJSON {
        var o: [String: ApprovalJSON] = ["label": .string(label)]
        if let description = description { o["description"] = .string(description) }
        for (key, value) in extra { o[key] = value }
        return .object(o)
    }

    private static let twoOptions: [ApprovalJSON] = [option("A"), option("B")]

    /// A question object. A nil `text` leaves `question` out; a nil `options` leaves `options` out.
    private static func question(_ text: String?, header: String? = nil, multiSelect: ApprovalJSON? = nil,
                                 kind: ApprovalJSON? = nil, options: [ApprovalJSON]? = ApprovalQuestionsTests.twoOptions,
                                 extra: [String: ApprovalJSON] = [:]) -> ApprovalJSON {
        var q: [String: ApprovalJSON] = [:]
        if let text = text { q["question"] = .string(text) }
        if let header = header { q["header"] = .string(header) }
        if let multiSelect = multiSelect { q["multiSelect"] = multiSelect }
        if let kind = kind { q["kind"] = kind }
        if let options = options { q["options"] = .array(options) }
        for (key, value) in extra { q[key] = value }
        return .object(q)
    }

    private static func input(_ questions: [ApprovalJSON]) -> ApprovalJSON {
        .object(["questions": .array(questions)])
    }

    private func parse(_ questions: [ApprovalJSON]) -> [ApprovalQuestion]? {
        ApprovalQuestions.parse(Self.input(questions))
    }

    /// `n` distinct questions, each with two options.
    private static func questions(count: Int) -> [ApprovalJSON] {
        (0 ..< count).map { question("Question \($0 + 1)?") }
    }

    private static func options(count: Int) -> [ApprovalJSON] {
        (0 ..< count).map { option("Option \($0)") }
    }

    // MARK: - Parse: what is answerable

    func testTheFixtureTheDaemonTestsUseParsesToItsTwoQuestions() throws {
        let root = URL(fileURLWithPath: #filePath)            // …/Shared/NostromoKit/Tests/NostromoKitTests/<this file>
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("tests/fixtures/approvals/ask_user_question.json"))
        struct Fixture: Decodable {
            struct Entry: Decodable {
                struct Req: Decodable { let input: ApprovalJSON }
                let request: Req
            }
            let requests: [Entry]
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        let parsed = try XCTUnwrap(ApprovalQuestions.parse(try XCTUnwrap(fixture.requests.first).request.input))

        XCTAssertEqual(parsed.map(\.question), ["Which database should we use?", "Which features do you want to enable?"])
        XCTAssertEqual(parsed.map(\.header), ["Database", "Features"])
        XCTAssertEqual(parsed.map(\.multiSelect), [false, true])
        XCTAssertEqual(parsed[0].options.map(\.label), ["Postgres", "SQLite"])
        XCTAssertEqual(parsed[0].options.map(\.description), ["Relational, strong consistency", "Embedded, zero setup"])
        XCTAssertEqual(parsed[1].options.map(\.label), ["Caching", "Metrics", "Tracing"])
        XCTAssertEqual(parsed[1].options.map(\.description),
                       ["In-memory response cache", "Prometheus endpoint", "OpenTelemetry spans"])
    }

    func testTheFixtureBuilderInTheTestsMatchesTheFixtureFile() throws {
        let request = try Fx.askUserQuestionRequest()
        let parsed = try XCTUnwrap(ApprovalQuestions.parse(request.input))
        XCTAssertEqual(parsed.map(\.question), ["Which database should we use?", "Which features do you want to enable?"])
        XCTAssertEqual(parsed.map(\.options.count), [2, 3])
    }

    func testBetweenOneAndFourQuestionsAreAnswerable() {
        for count in 1 ... 4 {
            XCTAssertEqual(parse(Self.questions(count: count))?.count, count, "\(count) question(s)")
        }
    }

    func testNoQuestionsAndMoreThanFourAreNotAnswerable() {
        XCTAssertNil(parse([]), "zero questions")
        XCTAssertNil(parse(Self.questions(count: 5)), "five questions")
        XCTAssertNil(parse(Self.questions(count: 6)), "six questions")
    }

    func testBetweenTwoAndFourOptionsAreAnswerable() {
        for count in 2 ... 4 {
            let parsed = parse([Self.question("Q?", options: Self.options(count: count))])
            XCTAssertEqual(parsed?.first?.options.count, count, "\(count) options")
        }
    }

    func testOneOptionAndMoreThanFourAreNotAnswerable() {
        XCTAssertNil(parse([Self.question("Q?", options: Self.options(count: 1))]), "one option")
        XCTAssertNil(parse([Self.question("Q?", options: Self.options(count: 0))]), "no options")
        XCTAssertNil(parse([Self.question("Q?", options: Self.options(count: 5))]), "five options")
    }

    func testOneBadQuestionMakesTheWholeInputNotAnswerable() {
        XCTAssertNil(parse([Self.question("Fine?"), Self.question("One option only?", options: Self.options(count: 1))]))
    }

    func testAQuestionWithoutOptionsIsNotAnswerable() {
        XCTAssertNil(parse([Self.question("Q?", options: nil)]))
    }

    func testAnEmptyOrMissingOrNonTextLabelIsNotAnswerable() {
        XCTAssertNil(parse([Self.question("Q?", options: [Self.option(""), Self.option("B")])]), "empty label")
        XCTAssertNil(parse([Self.question("Q?", options: [.object(["description": .string("no label")]), Self.option("B")])]),
                     "missing label")
        XCTAssertNil(parse([Self.question("Q?", options: [.object(["label": .int(1)]), Self.option("B")])]),
                     "a label that is not text")
        XCTAssertNil(parse([Self.question("Q?", options: [.object(["label": .null]), Self.option("B")])]), "a null label")
    }

    func testTwoOptionsWithTheSameLabelInOneQuestionAreNotAnswerable() {
        XCTAssertNil(parse([Self.question("Q?", options: [Self.option("A"), Self.option("A")])]))
        XCTAssertNil(parse([Self.question("Q?", options: [Self.option("A"), Self.option("B"), Self.option("A")])]))
    }

    func testTheSameLabelInDifferentQuestionsIsFine() {
        XCTAssertEqual(parse([Self.question("First?", options: [Self.option("Yes"), Self.option("No")]),
                              Self.question("Second?", options: [Self.option("Yes"), Self.option("No")])])?.count, 2)
    }

    func testLabelsThatDifferOnlyInCaseOrSpacingAreDistinctAndKeptExactly() throws {
        let parsed = try XCTUnwrap(parse([Self.question("Q?", options: [Self.option("a"), Self.option("A"), Self.option(" A ")])]))
        XCTAssertEqual(parsed[0].options.map(\.label), ["a", "A", " A "],
                       "the daemon matches labels byte for byte: they are never trimmed or folded")
    }

    func testAnEmptyOrMissingOrNonTextQuestionIsNotAnswerable() {
        XCTAssertNil(parse([Self.question("")]), "empty question text")
        XCTAssertNil(parse([Self.question(nil)]), "missing `question`")
        XCTAssertNil(parse([Self.question(nil, extra: ["question": .int(7)])]), "a question that is not text")
        XCTAssertNil(parse([Self.question(nil, extra: ["question": .null])]), "a null question")
    }

    func testTwoQuestionsWithTheSameTextAreNotAnswerable() {
        XCTAssertNil(parse([Self.question("Same?"), Self.question("Same?")]),
                     "answers are keyed by the question text, so two of the same text cannot be told apart")
        XCTAssertNil(parse([Self.question("Same?", header: "One"), Self.question("Other?"), Self.question("Same?", header: "Two")]))
    }

    func testEntriesThatAreNotObjectsAreNotAnswerable() {
        XCTAssertNil(parse([.string("Which one?")]), "a question that is a string")
        XCTAssertNil(parse([.null]), "a null question")
        XCTAssertNil(parse([.array([])]), "a question that is an array")
        XCTAssertNil(parse([Self.question("Fine?"), .int(3)]), "one good question and one number")
        XCTAssertNil(parse([Self.question("Q?", options: [.string("A"), .string("B")])]), "options that are strings")
        XCTAssertNil(parse([Self.question("Q?", options: [.null, Self.option("B")])]), "a null option")
    }

    func testOnlyAChoiceKindIsAnswerable() {
        XCTAssertNotNil(parse([Self.question("Q?", kind: .string("choice"))]), "`choice` is a choice")
        XCTAssertNil(parse([Self.question("Q?", kind: .string("text"))]), "text")
        XCTAssertNil(parse([Self.question("Q?", kind: .string("number"))]), "number")
        XCTAssertNil(parse([Self.question("Q?", kind: .string(""))]), "an empty kind")
        XCTAssertNil(parse([Self.question("Q?", kind: .string("Choice"))]), "the kind is matched exactly")
        XCTAssertNil(parse([Self.question("Q?", kind: .int(1))]), "a kind that is not text")
    }

    func testOneNonChoiceQuestionMakesTheWholeInputNotAnswerable() {
        XCTAssertNil(parse([Self.question("First?", kind: .string("choice")), Self.question("Second?", kind: .string("text"))]),
                     "an extended form we do not answer is never half-answered")
    }

    func testAnInputWithoutAQuestionsListIsNotAnswerable() {
        XCTAssertNil(ApprovalQuestions.parse(.object([:])))
        XCTAssertNil(ApprovalQuestions.parse(.object(["question": .string("Which one?")])), "the extended single-question shape")
        XCTAssertNil(ApprovalQuestions.parse(.object(["questions": .string("nope")])))
        XCTAssertNil(ApprovalQuestions.parse(.object(["questions": .object([:])])))
        XCTAssertNil(ApprovalQuestions.parse(.object(["questions": .null])))
        XCTAssertNil(ApprovalQuestions.parse(.array([])))
        XCTAssertNil(ApprovalQuestions.parse(.string("questions")))
        XCTAssertNil(ApprovalQuestions.parse(.null))
    }

    func testAMissingHeaderDescriptionAndMultiSelectTakeTheirDefaults() throws {
        let parsed = try XCTUnwrap(parse([.object([
            "question": .string("Bare?"),
            "options": .array([.object(["label": .string("A")]), .object(["label": .string("B")])]),
        ])]))
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].question, "Bare?")
        XCTAssertEqual(parsed[0].header, "")
        XCTAssertFalse(parsed[0].multiSelect)
        XCTAssertEqual(parsed[0].options.map(\.label), ["A", "B"])
        XCTAssertEqual(parsed[0].options.map(\.description), ["", ""])
    }

    func testHeaderDescriptionAndMultiSelectAreKeptWhenPresent() throws {
        let parsed = try XCTUnwrap(parse([Self.question("Pick?", header: "Pick one", multiSelect: .bool(true),
                                                        options: [Self.option("A", description: "first"),
                                                                  Self.option("B", description: "second")])]))
        XCTAssertEqual(parsed[0].header, "Pick one")
        XCTAssertTrue(parsed[0].multiSelect)
        XCTAssertEqual(parsed[0].options.map(\.description), ["first", "second"])
        let single = try XCTUnwrap(parse([Self.question("Pick?", multiSelect: .bool(false))]))
        XCTAssertFalse(single[0].multiSelect)
    }

    func testFieldsThisBuildDoesNotKnowAreIgnored() throws {
        let parsed = try XCTUnwrap(parse([Self.question(
            "Q?", options: [Self.option("A", extra: ["preview": .string("```\ncode\n```")]), Self.option("B")],
            extra: ["annotations": .object(["x": .int(1)])])]))
        XCTAssertEqual(parsed[0].options.map(\.label), ["A", "B"])
    }

    func testQuestionsAndOptionsKeepTheirOrderAndTheirTextExactly() throws {
        let text = "  Which \"one\"?\n(second line) é \u{1F642}  "
        let parsed = try XCTUnwrap(parse([Self.question("Z?"), Self.question(text), Self.question("A?")]))
        XCTAssertEqual(parsed.map(\.question), ["Z?", text, "A?"])
    }

    // MARK: - Selection: single-select

    private func single(options count: Int = 3) throws -> ApprovalQuestion {
        let q = try XCTUnwrap(parse([Self.question("Single?", header: "S", multiSelect: .bool(false),
                                                   options: (0 ..< count).map { Self.option("S\($0)") })])?.first)
        XCTAssertFalse(q.multiSelect, "precondition")
        return q
    }

    private func multi(options count: Int = 3) throws -> ApprovalQuestion {
        let q = try XCTUnwrap(parse([Self.question("Multi?", header: "M", multiSelect: .bool(true),
                                                   options: (0 ..< count).map { Self.option("M\($0)") })])?.first)
        XCTAssertTrue(q.multiSelect, "precondition")
        return q
    }

    func testAFreshSelectionHasNothingChosenAndIsNotAnAnswer() throws {
        for q in [try single(), try multi()] {
            let s = ApprovalQuestionSelection()
            XCTAssertTrue(s.selected.isEmpty)
            XCTAssertFalse(s.otherChosen)
            XCTAssertEqual(s.otherText, "")
            XCTAssertFalse(s.isAnswered(in: q))
            XCTAssertNil(s.answer(for: q))
            XCTAssertEqual(s, ApprovalQuestionSelection())
        }
    }

    func testPickingAnOptionInASingleSelectQuestionReplacesTheOneBefore() throws {
        let q = try single()
        var s = ApprovalQuestionSelection()
        s.toggle(option: 0, in: q)
        XCTAssertEqual(s.selected, [0])
        s.toggle(option: 2, in: q)
        XCTAssertEqual(s.selected, [2], "a radio group has one choice")
        s.toggle(option: 1, in: q)
        XCTAssertEqual(s.selected, [1])
    }

    func testPickingTheChosenOptionAgainInASingleSelectQuestionKeepsItChosen() throws {
        let q = try single()
        var s = ApprovalQuestionSelection()
        s.toggle(option: 1, in: q)
        s.toggle(option: 1, in: q)
        XCTAssertEqual(s.selected, [1], "a radio button does not switch itself off")
        XCTAssertTrue(s.isAnswered(in: q))
    }

    func testChoosingOtherInASingleSelectQuestionClearsTheOptionsAndPickingAnOptionClearsOther() throws {
        let q = try single()
        var s = ApprovalQuestionSelection()
        s.toggle(option: 0, in: q)
        s.setOther(chosen: true, in: q)
        XCTAssertTrue(s.otherChosen)
        XCTAssertTrue(s.selected.isEmpty, "Other replaces the option")

        s.toggle(option: 2, in: q)
        XCTAssertEqual(s.selected, [2])
        XCTAssertFalse(s.otherChosen, "an option replaces Other")
    }

    func testUnchoosingOtherLeavesNothingChosen() throws {
        for q in [try single(), try multi()] {
            var s = ApprovalQuestionSelection()
            s.setOther(chosen: true, in: q)
            s.setOther(chosen: false, in: q)
            XCTAssertFalse(s.otherChosen)
            XCTAssertTrue(s.selected.isEmpty)
            XCTAssertFalse(s.isAnswered(in: q))
        }
    }

    func testOtherChosenWithNoTextIsNotAnAnswer() throws {
        for q in [try single(), try multi()] {
            var s = ApprovalQuestionSelection()
            s.setOther(chosen: true, in: q)
            XCTAssertTrue(s.otherChosen, "precondition")
            XCTAssertFalse(s.isAnswered(in: q))
            XCTAssertNil(s.answer(for: q))
        }
    }

    func testTypingTextChoosesOtherAndInASingleSelectQuestionReplacesTheOption() throws {
        let q = try single()
        var s = ApprovalQuestionSelection()
        s.toggle(option: 1, in: q)
        s.setOtherText("Oracle", in: q)
        XCTAssertTrue(s.otherChosen, "typing selects Other")
        XCTAssertEqual(s.otherText, "Oracle")
        XCTAssertTrue(s.selected.isEmpty, "and replaces the chosen option")
        XCTAssertTrue(s.isAnswered(in: q))
    }

    func testTypingTextWithNothingChosenChoosesOther() throws {
        for q in [try single(), try multi()] {
            var s = ApprovalQuestionSelection()
            s.setOtherText("x", in: q)
            XCTAssertTrue(s.otherChosen)
            XCTAssertTrue(s.isAnswered(in: q))
        }
    }

    func testClearingTheTextUnchoosesOther() throws {
        for q in [try single(), try multi()] {
            var s = ApprovalQuestionSelection()
            s.setOtherText("typed", in: q)
            XCTAssertTrue(s.otherChosen, "precondition")
            s.setOtherText("", in: q)
            XCTAssertFalse(s.otherChosen, "no text, no Other")
            XCTAssertEqual(s.otherText, "")
            XCTAssertFalse(s.isAnswered(in: q))
        }
    }

    func testWhitespaceOnlyTextDoesNotChooseOtherAndLeavesTheChosenOptionAlone() throws {
        let q = try single()
        var s = ApprovalQuestionSelection()
        s.toggle(option: 1, in: q)
        s.setOtherText("   \t ", in: q)
        XCTAssertFalse(s.otherChosen)
        XCTAssertEqual(s.selected, [1], "blank typing never clears the choice")
        XCTAssertTrue(s.isAnswered(in: q))
        XCTAssertEqual(s.answer(for: q)?.selected, ["S1"])
        XCTAssertNil(s.answer(for: q)?.other)
    }

    func testWhitespaceOnlyOtherIsNotAnAnswer() throws {
        for q in [try single(), try multi()] {
            var s = ApprovalQuestionSelection()
            s.setOther(chosen: true, in: q)
            s.setOtherText("   \n\t  ", in: q)
            XCTAssertFalse(s.isAnswered(in: q), "blanks are not an answer")
            XCTAssertNil(s.answer(for: q))
        }
    }

    func testTheTypedTextIsKeptAsTyped() throws {
        let q = try single()
        var s = ApprovalQuestionSelection()
        s.setOtherText("  padded  ", in: q)
        XCTAssertEqual(s.otherText, "  padded  ", "the field shows what the person typed; trimming is for the answer")
    }

    func testOtherTextOverTheLimitIsNotAnAnswerAndTheLimitItselfIs() throws {
        XCTAssertEqual(ApprovalQuestions.maxOtherCharacters, 1000)
        for q in [try single(), try multi()] {
            var atLimit = ApprovalQuestionSelection()
            atLimit.setOtherText(String(repeating: "a", count: 1000), in: q)
            XCTAssertTrue(atLimit.isAnswered(in: q), "1000 characters")
            XCTAssertEqual(atLimit.answer(for: q)?.other?.count, 1000)

            var over = ApprovalQuestionSelection()
            over.setOtherText(String(repeating: "a", count: 1001), in: q)
            XCTAssertFalse(over.isAnswered(in: q), "1001 characters")
            XCTAssertNil(over.answer(for: q))
        }
    }

    func testASingleSelectAnswerNamesTheChosenLabelAndNoOther() throws {
        let q = try single()
        var s = ApprovalQuestionSelection()
        s.toggle(option: 2, in: q)
        XCTAssertEqual(s.answer(for: q), ApprovalQuestionAnswer(question: "Single?", selected: ["S2"], other: nil))
    }

    func testAnOtherAnswerHasNoLabelsAndTheTrimmedText() throws {
        let q = try single()
        var s = ApprovalQuestionSelection()
        s.setOtherText("  Oracle 23ai \n", in: q)
        XCTAssertEqual(s.answer(for: q), ApprovalQuestionAnswer(question: "Single?", selected: [], other: "Oracle 23ai"))
    }

    func testTheAnswerIsKeyedByTheQuestionTextExactly() throws {
        let text = "  Which \"one\"?\n"
        let q = try XCTUnwrap(parse([Self.question(text)])?.first)
        var s = ApprovalQuestionSelection()
        s.toggle(option: 0, in: q)
        XCTAssertEqual(s.answer(for: q)?.question, text)
    }

    // MARK: - Selection: multi-select

    func testAMultiSelectOptionIsToggledOnAndOff() throws {
        let q = try multi()
        var s = ApprovalQuestionSelection()
        s.toggle(option: 1, in: q)
        XCTAssertEqual(s.selected, [1])
        s.toggle(option: 2, in: q)
        XCTAssertEqual(s.selected, [1, 2], "checkboxes add up")
        s.toggle(option: 1, in: q)
        XCTAssertEqual(s.selected, [2])
        s.toggle(option: 2, in: q)
        XCTAssertTrue(s.selected.isEmpty)
        XCTAssertFalse(s.isAnswered(in: q), "nothing chosen is not an answer")
    }

    func testOtherIsAdditiveInAMultiSelectQuestion() throws {
        let q = try multi()
        var s = ApprovalQuestionSelection()
        s.toggle(option: 0, in: q)
        s.setOther(chosen: true, in: q)
        XCTAssertEqual(s.selected, [0], "choosing Other keeps the options")
        XCTAssertTrue(s.otherChosen)

        s.toggle(option: 2, in: q)
        XCTAssertTrue(s.otherChosen, "choosing an option keeps Other")
        XCTAssertEqual(s.selected, [0, 2])

        s.setOtherText("more", in: q)
        XCTAssertEqual(s.selected, [0, 2], "typing keeps the options")
        XCTAssertTrue(s.otherChosen)
    }

    func testTypingInAMultiSelectQuestionChoosesOtherWithoutClearingOptions() throws {
        let q = try multi()
        var s = ApprovalQuestionSelection()
        s.toggle(option: 1, in: q)
        s.setOtherText("extra", in: q)
        XCTAssertTrue(s.otherChosen)
        XCTAssertEqual(s.selected, [1])
        s.setOtherText("", in: q)
        XCTAssertFalse(s.otherChosen)
        XCTAssertEqual(s.selected, [1], "clearing the text does not clear the options")
    }

    func testAMultiSelectAnswerListsTheLabelsInOptionOrderWhateverOrderTheyWerePicked() throws {
        let q = try multi(options: 4)
        var s = ApprovalQuestionSelection()
        for index in [3, 0, 2] { s.toggle(option: index, in: q) }
        XCTAssertEqual(s.answer(for: q), ApprovalQuestionAnswer(question: "Multi?", selected: ["M0", "M2", "M3"], other: nil))
    }

    func testAMultiSelectAnswerCanCarryLabelsAndTheTrimmedOtherText() throws {
        let q = try multi()
        var s = ApprovalQuestionSelection()
        s.toggle(option: 2, in: q)
        s.toggle(option: 0, in: q)
        s.setOtherText("  and this too ", in: q)
        XCTAssertEqual(s.answer(for: q), ApprovalQuestionAnswer(question: "Multi?", selected: ["M0", "M2"], other: "and this too"))
    }

    func testAMultiSelectAnswerCanBeOtherAlone() throws {
        let q = try multi()
        var s = ApprovalQuestionSelection()
        s.setOtherText("only this", in: q)
        XCTAssertEqual(s.answer(for: q), ApprovalQuestionAnswer(question: "Multi?", selected: [], other: "only this"))
    }

    func testAnAnswerTheDaemonWouldRefuseIsNeverBuilt() throws {
        // Options chosen, and Other ticked with text that is empty, blank or too long. Whatever the form
        // decides (answer without the Other text, or no answer yet), it never sends `other` the daemon refuses.
        let q = try multi()
        for text in ["", "   ", String(repeating: "a", count: 1001)] {
            var s = ApprovalQuestionSelection()
            s.toggle(option: 1, in: q)
            s.setOther(chosen: true, in: q)
            s.setOtherText(text, in: q)
            if let answer = s.answer(for: q) {
                XCTAssertEqual(answer.selected, ["M1"], "text of \(text.count) characters")
                if let other = answer.other {
                    XCTAssertFalse(other.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "empty `other` sent")
                    XCTAssertLessThanOrEqual(other.count, ApprovalQuestions.maxOtherCharacters, "oversize `other` sent")
                }
            } else {
                XCTAssertFalse(s.isAnswered(in: q), "answered, but no answer can be built")
            }
            XCTAssertEqual(s.isAnswered(in: q), s.answer(for: q) != nil, "isAnswered and answer(for:) agree")
        }
    }

    func testIsAnsweredAndAnswerAgreeForEveryStateOfASmallQuestion() throws {
        for q in [try single(options: 2), try multi(options: 2)] {
            for texts in ["", "  ", "t"] {
                for chosen in [false, true] {
                    for first in [false, true] {
                        var s = ApprovalQuestionSelection()
                        if first { s.toggle(option: 0, in: q) }
                        s.setOther(chosen: chosen, in: q)
                        s.setOtherText(texts, in: q)
                        XCTAssertEqual(s.isAnswered(in: q), s.answer(for: q) != nil,
                                       "multi \(q.multiSelect) option \(first) other \(chosen) text '\(texts)'")
                    }
                }
            }
        }
    }

    // MARK: - Whole form

    private func answered(_ q: ApprovalQuestion, option: Int = 0) -> ApprovalQuestionSelection {
        var s = ApprovalQuestionSelection()
        s.toggle(option: option, in: q)
        return s
    }

    func testTheAnswersAreInQuestionOrderOnceEveryQuestionIsAnswered() throws {
        let questions = try XCTUnwrap(parse([Self.question("One?"), Self.question("Two?", multiSelect: .bool(true)),
                                             Self.question("Three?")]))
        var second = ApprovalQuestionSelection()
        second.toggle(option: 1, in: questions[1])
        second.toggle(option: 0, in: questions[1])
        var third = ApprovalQuestionSelection()
        third.setOtherText("free", in: questions[2])

        let answers = ApprovalQuestions.answers(for: questions, selections: [answered(questions[0], option: 1), second, third])

        XCTAssertEqual(answers, [
            ApprovalQuestionAnswer(question: "One?", selected: ["B"], other: nil),
            ApprovalQuestionAnswer(question: "Two?", selected: ["A", "B"], other: nil),
            ApprovalQuestionAnswer(question: "Three?", selected: [], other: "free"),
        ])
    }

    func testThereAreNoAnswersWhileAnyQuestionIsUnanswered() throws {
        let questions = try XCTUnwrap(parse(Self.questions(count: 3)))
        let ready = questions.map { answered($0) }
        XCTAssertNotNil(ApprovalQuestions.answers(for: questions, selections: ready), "precondition")
        for hole in 0 ..< 3 {
            var selections = ready
            selections[hole] = ApprovalQuestionSelection()
            XCTAssertNil(ApprovalQuestions.answers(for: questions, selections: selections), "question \(hole) unanswered")
        }
        XCTAssertNil(ApprovalQuestions.answers(for: questions, selections: [ApprovalQuestionSelection(), ApprovalQuestionSelection(),
                                                                            ApprovalQuestionSelection()]))
    }

    func testThereAreNoAnswersWhenTheSelectionsDoNotMatchTheQuestions() throws {
        let questions = try XCTUnwrap(parse(Self.questions(count: 3)))
        let ready = questions.map { answered($0) }
        XCTAssertNil(ApprovalQuestions.answers(for: questions, selections: Array(ready.prefix(2))), "too few")
        XCTAssertNil(ApprovalQuestions.answers(for: questions, selections: ready + [answered(questions[0])]), "too many")
        XCTAssertNil(ApprovalQuestions.answers(for: questions, selections: []), "none")
    }

    func testAnUnansweredQuestionIsNotFilledInFromAnotherQuestionsSelection() throws {
        let questions = try XCTUnwrap(parse([Self.question("One?"), Self.question("Two?")]))
        let onlyFirst = [answered(questions[0]), ApprovalQuestionSelection()]
        XCTAssertNil(ApprovalQuestions.answers(for: questions, selections: onlyFirst))
    }
}
