import XCTest
import AppKit
import Combine
import NostromoKit

// AP2c: answering the CLI's `AskUserQuestion` from the approval card.
//
// A question request the daemon can take answers for (`answer_questions` among its options, an
// answerable input) gets a different card: the questions as a form (radio buttons for a
// single-select question, checkboxes for a multi-select one, and a free-text "Other" on each),
// Deny, and Submit. These tests pin that from outside: what the card shows, what it refuses to do,
// and the bytes it sends. They read views the way a person (or `nostromo-app approvals list`)
// sees them, through the test seams the form exposes, and never its private state.
//
// What matters most, because an agent is on the other end:
//   * Only a person answers. Choosing an option, ticking Other and Submit all go through the same
//     human-gesture check as every other card button; a refused gesture changes nothing and is reported
//     (`answer_option`, `answer_questions`). Typing a draft in "Other" needs no gesture: Submit is the act.
//   * Exactly one `approval_answer` goes out, with every question answered, the labels byte for byte,
//     and the free text trimmed. A rebuilt card, a second press, a second window can never send another.
//   * No key answers, nothing takes focus on arrival (the AP2a rules, kept for the form).
//   * 5,000 characters in any text the agent supplies never widen the card or the window.
//
// Contents:
//   * `QuestionTestRequests`: AskUserQuestion requests as the daemon sends them.
//   * `ApprovalQuestionFormViewTests`: the form on its own.
//   * `ApprovalQuestionCardTests`: the card around it.
//   * `ApprovalQuestionLayoutTests`: long text, in the card and in a real, fixed-size window.
//   * `ApprovalQuestionStoreTests`: what the store does with these answers and their refusals.

// MARK: - Requests the daemon would send

enum QuestionTestRequests {

    typealias Obj = [String: Any]

    /// What the daemon lists for an `AskUserQuestion` it can take answers for.
    static let offered = ApprovalTestRequests.allOptions + ["answer_questions"]

    static func option(_ label: String, _ description: String = "") -> Obj {
        ["label": label, "description": description]
    }

    /// An empty `header` leaves the key out.
    static func question(_ text: String, header: String = "", multi: Bool = false, options: [Obj]) -> Obj {
        var q: Obj = ["question": text, "multiSelect": multi, "options": options]
        if !header.isEmpty { q["header"] = header }
        return q
    }

    /// The two questions of `tests/fixtures/approvals/ask_user_question.json`.
    static let database = question("Which database should we use?", header: "Database", options: [
        option("Postgres", "Relational, strong consistency"),
        option("SQLite", "Embedded, zero setup"),
    ])
    static let features = question("Which features do you want to enable?", header: "Features", multi: true, options: [
        option("Caching", "In-memory response cache"),
        option("Metrics", "Prometheus endpoint"),
        option("Tracing", "OpenTelemetry spans"),
    ])
    static var fixture: [Obj] { [database, features] }

    /// `count` distinct questions with three options each; the first is single-select, the second multi-select, and so on.
    static func questions(count: Int) -> [Obj] {
        (0 ..< count).map { i in
            question("Question \(i + 1)?", header: "Q\(i + 1)", multi: i % 2 == 1,
                     options: ["A", "B", "C"].map { option("Q\(i + 1)\($0)", "Described \($0)") })
        }
    }

    /// An `AskUserQuestion` request. The display is the pretty-printed JSON of the input, as the daemon builds it
    /// for a tool it has no special layout for.
    static func ask(_ questions: [Obj] = QuestionTestRequests.fixture, input: Obj? = nil, id: String = "req-1",
                    tag: String = "cody-1", options: [String] = QuestionTestRequests.offered,
                    flags: [String: Bool] = ["requires_user_interaction": true],
                    toolName: String = "AskUserQuestion") throws -> ApprovalRequestWire {
        let toolInput: Obj = input ?? ["questions": questions]
        let data = try JSONSerialization.data(withJSONObject: toolInput, options: [.prettyPrinted, .sortedKeys])
        var d = ApprovalTestRequests.Display()
        for line in String(decoding: data, as: UTF8.self).components(separatedBy: "\n") { d.text("json", line) }
        return try ApprovalTestRequests.request(id: id, tag: tag, toolKind: "other", toolName: toolName, displayName: toolName,
                                                input: toolInput, display: ApprovalTestRequests.display(lines: d.lines),
                                                reasonKind: "other", reasonText: "Claude Code asked for approval",
                                                flags: flags, options: options)
    }

    /// The questions as the app parses them (what a form is built from).
    static func parsed(_ questions: [Obj]) throws -> [ApprovalQuestion] {
        let data = try JSONSerialization.data(withJSONObject: ["questions": questions])
        let json = try JSONDecoder().decode(ApprovalJSON.self, from: data)
        guard let parsed = ApprovalQuestions.parse(json) else {
            throw NSError(domain: "QuestionTestRequests", code: 1, userInfo: [NSLocalizedDescriptionKey: "not answerable"])
        }
        return parsed
    }
}

/// Lets a test change who is pressing mid-test (a person to fill the form in, then something that is not).
final class QuestionPermitBox {
    var permit: ApprovalCardView.GesturePermit = ApprovalCardHarness.humanPermit
}

/// Helpers shared by the question tests.
enum QuestionTestViews {

    /// Every control of `view` a person can operate: buttons and editable text fields.
    static func operableControls(in view: NSView) -> [NSControl] {
        rigAllSubviews(of: view).compactMap { $0 as? NSControl }.filter { control in
            control is NSButton || (control as? NSTextField)?.isEditable == true
        }
    }

    /// An action delivered to a control anyway (an Accessibility press, a stray `sendAction`).
    static func forcePress(_ button: NSButton?, file: StaticString = #filePath, line: UInt = #line) {
        guard let button = button, let action = button.action else { return XCTFail("no such button", file: file, line: line) }
        button.performClick(nil)
        _ = NSApp.sendAction(action, to: button.target, from: button)
    }

    static func press(_ button: NSButton?, file: StaticString = #filePath, line: UInt = #line) {
        guard let button = button else { return XCTFail("no such button", file: file, line: line) }
        button.performClick(nil)
    }

    /// What typing in a text field does: the field editor changes and says so.
    static func enter(_ text: String, into field: NSTextField, in window: NSWindow) {
        _ = window.makeFirstResponder(field)
        if let editor = rigEditor(of: field) {
            editor.string = text
            editor.didChangeText()
        } else {
            field.stringValue = text
            NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
        }
        _ = window.makeFirstResponder(nil)
    }
}

// MARK: - The form on its own

final class ApprovalQuestionFormViewTests: XCTestCase {

    typealias Q = QuestionTestRequests

    private func makeForm(_ questions: [Q.Obj] = Q.fixture, width: CGFloat = 500) throws
        -> (form: ApprovalQuestionFormView, window: NSWindow) {
        let window = makeRigWindow(self, size: NSSize(width: width + 100, height: 900))
        let form = ApprovalQuestionFormView(questions: try Q.parsed(questions))
        form.permit = { _, _ in true }
        form.frame = NSRect(x: 20, y: 20, width: width, height: form.contentHeight(forWidth: width))
        window.contentView!.addSubview(form)
        form.layoutSubtreeIfNeeded()
        return (form, window)
    }

    private func on(_ button: NSButton?) -> Bool { button?.state == .on }

    func testAFreshFormHasNothingChosenAndIsNotComplete() throws {
        let (form, _) = try makeForm()
        XCTAssertTrue(form.isEnabled)
        XCTAssertFalse(form.isComplete)
        XCTAssertNil(form.answers)
        XCTAssertEqual(form.selections, [ApprovalQuestionSelection(), ApprovalQuestionSelection()])
        for (q, count) in [(0, 2), (1, 3)] {
            for o in 0 ..< count { XCTAssertFalse(on(form.optionButton(question: q, option: o)), "q\(q) option \(o)") }
            XCTAssertFalse(on(form.otherButton(question: q)))
            XCTAssertEqual(form.otherField(question: q)?.stringValue, "")
        }
    }

    func testTheFormIsFrameLaidOutAndFlipped() throws {
        let (form, _) = try makeForm()
        XCTAssertTrue(form.isFlipped)
    }

    func testEachQuestionHasItsHeaderChipItsTextAndEveryOptionWithItsDescription() throws {
        let (form, _) = try makeForm()
        XCTAssertEqual(form.questionLabel(0).stringValue, "Which database should we use?")
        XCTAssertEqual(form.questionLabel(1).stringValue, "Which features do you want to enable?")
        XCTAssertEqual(form.headerChip(0)?.stringValue.lowercased(), "database")
        XCTAssertEqual(form.headerChip(1)?.stringValue.lowercased(), "features")
        XCTAssertEqual(form.optionLabel(question: 0, option: 0).stringValue, "Postgres")
        XCTAssertEqual(form.descriptionLabel(question: 0, option: 0).stringValue, "Relational, strong consistency")
        XCTAssertEqual(form.optionLabel(question: 0, option: 1).stringValue, "SQLite")
        XCTAssertEqual(form.descriptionLabel(question: 0, option: 1).stringValue, "Embedded, zero setup")
        XCTAssertEqual((0 ..< 3).map { form.optionLabel(question: 1, option: $0).stringValue }, ["Caching", "Metrics", "Tracing"])
        XCTAssertEqual((0 ..< 3).map { form.descriptionLabel(question: 1, option: $0).stringValue },
                       ["In-memory response cache", "Prometheus endpoint", "OpenTelemetry spans"])
        for label in [form.questionLabel(0), form.optionLabel(question: 0, option: 0), form.descriptionLabel(question: 0, option: 1)] {
            XCTAssertFalse(label.isHiddenOrHasHiddenAncestor, label.stringValue)
        }
    }

    func testAQuestionWithNoHeaderHasNoChip() throws {
        let (form, _) = try makeForm([Q.question("No header?", options: [Q.option("A"), Q.option("B")]), Q.database])
        XCTAssertNil(form.headerChip(0))
        XCTAssertNotNil(form.headerChip(1))
    }

    func testTheSeamsHaveTheirIdentifiers() throws {
        let (form, _) = try makeForm()
        XCTAssertEqual(form.optionButton(question: 0, option: 1)?.identifier?.rawValue, "q0_opt1")
        XCTAssertEqual(form.optionButton(question: 1, option: 2)?.identifier?.rawValue, "q1_opt2")
        XCTAssertEqual(form.otherButton(question: 1)?.identifier?.rawValue, "q1_other")
        XCTAssertEqual(form.otherField(question: 0)?.identifier?.rawValue, "q0_other_field")
    }

    func testTheSeamsAreNilOutOfRange() throws {
        let (form, _) = try makeForm()
        XCTAssertNil(form.optionButton(question: 0, option: 2), "the first question has two options")
        XCTAssertNil(form.optionButton(question: 5, option: 0))
        XCTAssertNil(form.otherButton(question: 2))
        XCTAssertNil(form.otherField(question: 2))
    }

    func testOptionsAreRadioButtonsForASingleSelectQuestionAndCheckboxesForAMultiSelectOne() throws {
        let (form, _) = try makeForm()
        for o in 0 ..< 2 {
            XCTAssertEqual(form.optionButton(question: 0, option: o)?.accessibilityRole(), .radioButton, "single-select option \(o)")
        }
        for o in 0 ..< 3 {
            XCTAssertEqual(form.optionButton(question: 1, option: o)?.accessibilityRole(), .checkBox, "multi-select option \(o)")
        }
    }

    func testEveryOptionAndTheOtherControlIsNamedForVoiceOver() throws {
        let (form, _) = try makeForm()
        // The button has no title (the label and description are text fields beside it), so its name has to say what it picks.
        XCTAssertTrue(form.optionButton(question: 0, option: 0)?.accessibilityLabel()?.contains("Postgres") == true)
        XCTAssertTrue(form.optionButton(question: 0, option: 1)?.accessibilityLabel()?.contains("SQLite") == true)
        XCTAssertTrue(form.optionButton(question: 1, option: 2)?.accessibilityLabel()?.contains("Tracing") == true)
        for q in 0 ..< 2 {
            XCTAssertTrue(form.otherButton(question: q)?.accessibilityLabel()?.localizedCaseInsensitiveContains("other") == true, "q\(q)")
            XCTAssertFalse(form.otherField(question: q)?.accessibilityLabel()?.isEmpty ?? true, "the free-text field is named")
        }
    }

    func testTheOtherFieldCanBeTypedInFromTheStart() throws {
        let (form, _) = try makeForm()
        for q in 0 ..< 2 {
            let field = try XCTUnwrap(form.otherField(question: q))
            XCTAssertTrue(field.isEditable)
            XCTAssertTrue(field.isEnabled)
            XCTAssertFalse(field.isHiddenOrHasHiddenAncestor, "typing is how Other is chosen: the field is always there")
        }
    }

    // MARK: Single-select

    func testPickingAnOptionOfASingleSelectQuestionSelectsOnlyThatOne() throws {
        let (form, _) = try makeForm()
        QuestionTestViews.press(form.optionButton(question: 0, option: 0))
        XCTAssertTrue(on(form.optionButton(question: 0, option: 0)))
        XCTAssertFalse(on(form.optionButton(question: 0, option: 1)))
        XCTAssertEqual(form.selections[0].selected, [0])

        QuestionTestViews.press(form.optionButton(question: 0, option: 1))
        XCTAssertFalse(on(form.optionButton(question: 0, option: 0)), "the radio group has one choice")
        XCTAssertTrue(on(form.optionButton(question: 0, option: 1)))
        XCTAssertEqual(form.selections[0].selected, [1])
        XCTAssertTrue(form.selections[1].selected.isEmpty, "the other question is not touched")
    }

    func testPressingTheChosenRadioButtonAgainKeepsItChosen() throws {
        let (form, _) = try makeForm()
        QuestionTestViews.press(form.optionButton(question: 0, option: 1))
        QuestionTestViews.press(form.optionButton(question: 0, option: 1))
        XCTAssertTrue(on(form.optionButton(question: 0, option: 1)))
        XCTAssertEqual(form.selections[0].selected, [1])
    }

    func testChoosingOtherInASingleSelectQuestionClearsTheOptionAndPickingAnOptionClearsOther() throws {
        let (form, _) = try makeForm()
        QuestionTestViews.press(form.optionButton(question: 0, option: 0))
        QuestionTestViews.press(form.otherButton(question: 0))
        XCTAssertTrue(on(form.otherButton(question: 0)))
        XCTAssertFalse(on(form.optionButton(question: 0, option: 0)))
        XCTAssertEqual(form.selections[0].selected, [])
        XCTAssertTrue(form.selections[0].otherChosen)

        QuestionTestViews.press(form.optionButton(question: 0, option: 1))
        XCTAssertFalse(on(form.otherButton(question: 0)))
        XCTAssertTrue(on(form.optionButton(question: 0, option: 1)))
        XCTAssertFalse(form.selections[0].otherChosen)
    }

    func testTypingInOtherChoosesItAndReplacesTheChosenOptionOfASingleSelectQuestion() throws {
        let (form, window) = try makeForm()
        QuestionTestViews.press(form.optionButton(question: 0, option: 1))
        XCTAssertTrue(on(form.optionButton(question: 0, option: 1)), "precondition")

        QuestionTestViews.enter("Oracle", into: try XCTUnwrap(form.otherField(question: 0)), in: window)

        XCTAssertTrue(on(form.otherButton(question: 0)), "typing selects Other")
        XCTAssertFalse(on(form.optionButton(question: 0, option: 1)), "and the label that was chosen is replaced")
        XCTAssertEqual(form.selections[0].otherText, "Oracle")
        XCTAssertFalse(form.isComplete, "the other question is still open")
    }

    func testClearingTheTypedTextUnchoosesOther() throws {
        let (form, window) = try makeForm()
        let field = try XCTUnwrap(form.otherField(question: 0))
        QuestionTestViews.enter("Oracle", into: field, in: window)
        XCTAssertTrue(on(form.otherButton(question: 0)), "precondition")
        QuestionTestViews.enter("", into: field, in: window)
        XCTAssertFalse(on(form.otherButton(question: 0)))
        XCTAssertFalse(form.selections[0].otherChosen)
    }

    // MARK: Multi-select

    func testMultiSelectOptionsAreToggledOnAndOff() throws {
        let (form, _) = try makeForm()
        QuestionTestViews.press(form.optionButton(question: 1, option: 2))
        QuestionTestViews.press(form.optionButton(question: 1, option: 0))
        XCTAssertEqual((0 ..< 3).map { on(form.optionButton(question: 1, option: $0)) }, [true, false, true])
        XCTAssertEqual(form.selections[1].selected, [0, 2])

        QuestionTestViews.press(form.optionButton(question: 1, option: 2))
        XCTAssertEqual((0 ..< 3).map { on(form.optionButton(question: 1, option: $0)) }, [true, false, false])
        XCTAssertEqual(form.selections[1].selected, [0])
    }

    func testOtherIsAdditiveInAMultiSelectQuestion() throws {
        let (form, window) = try makeForm()
        QuestionTestViews.press(form.optionButton(question: 1, option: 1))
        QuestionTestViews.press(form.otherButton(question: 1))
        XCTAssertTrue(on(form.optionButton(question: 1, option: 1)), "ticking Other keeps the option")
        XCTAssertTrue(on(form.otherButton(question: 1)))

        QuestionTestViews.press(form.optionButton(question: 1, option: 0))
        XCTAssertTrue(on(form.otherButton(question: 1)), "ticking an option keeps Other")

        QuestionTestViews.enter("Logging", into: try XCTUnwrap(form.otherField(question: 1)), in: window)
        XCTAssertEqual(form.selections[1].selected, [0, 1])
        XCTAssertTrue(form.selections[1].otherChosen)
        XCTAssertEqual(form.selections[1].otherText, "Logging")
    }

    func testTypingInOtherOfAMultiSelectQuestionKeepsTheTickedOptions() throws {
        let (form, window) = try makeForm()
        QuestionTestViews.press(form.optionButton(question: 1, option: 2))
        QuestionTestViews.enter("extra", into: try XCTUnwrap(form.otherField(question: 1)), in: window)
        XCTAssertTrue(on(form.optionButton(question: 1, option: 2)))
        XCTAssertTrue(on(form.otherButton(question: 1)))
    }

    // MARK: Complete, and the answers

    func testTheFormIsCompleteOnlyWhenEveryQuestionIsAnsweredAndThenHasTheAnswers() throws {
        let (form, _) = try makeForm()
        QuestionTestViews.press(form.optionButton(question: 0, option: 1))
        XCTAssertFalse(form.isComplete)
        XCTAssertNil(form.answers)

        QuestionTestViews.press(form.optionButton(question: 1, option: 2))
        QuestionTestViews.press(form.optionButton(question: 1, option: 0))
        XCTAssertTrue(form.isComplete)
        XCTAssertEqual(form.answers, [
            ApprovalQuestionAnswer(question: "Which database should we use?", selected: ["SQLite"], other: nil),
            ApprovalQuestionAnswer(question: "Which features do you want to enable?", selected: ["Caching", "Tracing"], other: nil),
        ])

        QuestionTestViews.press(form.optionButton(question: 1, option: 0))
        QuestionTestViews.press(form.optionButton(question: 1, option: 2))
        XCTAssertFalse(form.isComplete, "un-ticking the last option of a multi-select question reopens it")
        XCTAssertNil(form.answers)
    }

    // MARK: Gestures

    func testAClickIsOnlyActedOnWhenThePermitSaysSoAndAskedAboutTheClickedControl() throws {
        let (form, _) = try makeForm()
        var asked: [(view: NSView, control: String)] = []
        var allow = false
        form.permit = { view, control in
            asked.append((view, control))
            return allow
        }
        let button = try XCTUnwrap(form.optionButton(question: 0, option: 0))

        QuestionTestViews.press(button)
        XCTAssertEqual(asked.count, 1)
        XCTAssertTrue(asked.first?.view === button, "the permit sees the control that was clicked")
        XCTAssertEqual(asked.first?.control, "answer_option")
        XCTAssertFalse(on(button), "a refused click leaves the button as it was")
        XCTAssertTrue(form.selections[0].selected.isEmpty)

        allow = true
        QuestionTestViews.press(button)
        XCTAssertTrue(on(button))
        XCTAssertEqual(form.selections[0].selected, [0])
    }

    func testARefusedClickOnAnotherOptionKeepsTheChoiceThatWasThere() throws {
        let (form, _) = try makeForm()
        var allow = true
        form.permit = { _, _ in allow }
        QuestionTestViews.press(form.optionButton(question: 0, option: 0))
        allow = false
        QuestionTestViews.press(form.optionButton(question: 0, option: 1))
        XCTAssertTrue(on(form.optionButton(question: 0, option: 0)), "the choice stands")
        XCTAssertFalse(on(form.optionButton(question: 0, option: 1)))
        XCTAssertEqual(form.selections[0].selected, [0])

        QuestionTestViews.press(form.otherButton(question: 0))
        XCTAssertFalse(on(form.otherButton(question: 0)), "a refused Other toggle does nothing either")
        XCTAssertEqual(form.selections[0].selected, [0])
        XCTAssertFalse(form.selections[0].otherChosen)
    }

    func testARefusedClickOnACheckboxLeavesItsStateAsItWas() throws {
        let (form, _) = try makeForm()
        var allow = true
        form.permit = { _, _ in allow }
        QuestionTestViews.press(form.optionButton(question: 1, option: 1))
        allow = false
        QuestionTestViews.press(form.optionButton(question: 1, option: 1))
        XCTAssertTrue(on(form.optionButton(question: 1, option: 1)), "not un-ticked")
        QuestionTestViews.press(form.optionButton(question: 1, option: 2))
        XCTAssertFalse(on(form.optionButton(question: 1, option: 2)), "not ticked")
        XCTAssertEqual(form.selections[1].selected, [1])
    }

    func testTypingInOtherNeedsNoGesture() throws {
        let (form, window) = try makeForm()
        form.permit = { _, _ in false }
        QuestionTestViews.enter("Oracle", into: try XCTUnwrap(form.otherField(question: 0)), in: window)
        XCTAssertTrue(form.selections[0].otherChosen, "a draft is not an answer: Submit is the gated act")
        XCTAssertEqual(form.selections[0].otherText, "Oracle")
    }

    func testAFormWithNoPermitRefusesEveryClick() throws {
        let (form, _) = try makeForm()
        form.permit = nil
        QuestionTestViews.press(form.optionButton(question: 0, option: 1))
        XCTAssertFalse(on(form.optionButton(question: 0, option: 1)), "fails closed")
    }

    // MARK: onChange

    func testOnChangeFiresForEachChangeOfSelectionAndForTypingButNotForARefusedClick() throws {
        let (form, window) = try makeForm()
        var changes = 0
        form.onChange = { changes += 1 }

        QuestionTestViews.press(form.optionButton(question: 0, option: 0))
        XCTAssertGreaterThanOrEqual(changes, 1, "an option picked")
        var seen = changes

        QuestionTestViews.press(form.optionButton(question: 1, option: 1))
        XCTAssertGreaterThan(changes, seen, "a checkbox ticked")
        seen = changes

        QuestionTestViews.enter("Oracle", into: try XCTUnwrap(form.otherField(question: 0)), in: window)
        XCTAssertGreaterThan(changes, seen, "text typed")
        seen = changes

        form.permit = { _, _ in false }
        QuestionTestViews.press(form.optionButton(question: 1, option: 2))
        XCTAssertEqual(changes, seen, "a refused click changed nothing, so nothing is announced")
    }

    // MARK: Enabled

    func testDisablingTheFormDisablesEveryControlAndEnablingItBringsThemBack() throws {
        let (form, _) = try makeForm()
        let controls = QuestionTestViews.operableControls(in: form)
        XCTAssertGreaterThanOrEqual(controls.count, 2 + 3 + 2 + 2, "every option, both Others and both fields")
        XCTAssertTrue(controls.allSatisfy(\.isEnabled), "precondition")

        form.isEnabled = false
        XCTAssertTrue(controls.allSatisfy { !$0.isEnabled }, "\(controls.filter(\.isEnabled).map { $0.identifier?.rawValue ?? "?" })")
        form.isEnabled = true
        XCTAssertTrue(controls.allSatisfy(\.isEnabled))
    }

    func testADisabledFormIgnoresAnActionDeliveredToAControlAnyway() throws {
        let (form, _) = try makeForm()
        form.isEnabled = false
        QuestionTestViews.forcePress(form.optionButton(question: 0, option: 0))
        QuestionTestViews.forcePress(form.otherButton(question: 1))
        XCTAssertEqual(form.selections, [ApprovalQuestionSelection(), ApprovalQuestionSelection()])
    }

    // MARK: Keys

    func testNoControlOfTheFormHasAKeyEquivalent() throws {
        let (form, window) = try makeForm()
        for button in rigAllSubviews(of: form).compactMap({ $0 as? NSButton }) {
            XCTAssertEqual(button.keyEquivalent, "", "`\(button.identifier?.rawValue ?? button.title)`")
        }
        XCTAssertNil(window.defaultButtonCell)
    }
}

// MARK: - The card around it

final class ApprovalQuestionCardTests: XCTestCase {

    typealias Q = QuestionTestRequests

    // MARK: Helpers

    private func pump(until condition: () -> Bool, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        return condition()
    }

    @discardableResult
    private func harness(_ request: ApprovalRequestWire? = nil, box: QuestionPermitBox = QuestionPermitBox(),
                         window: NSWindow? = nil, width: CGFloat = 560, maxHeight: CGFloat = 520,
                         armDelay: TimeInterval = 0, canSend: @escaping () -> Bool = { true },
                         windowID: String = "w-test", prepare: ((NSWindow) -> Void)? = nil) throws -> ApprovalCardHarness {
        ApprovalCardHarness(self, request: try request ?? Q.ask(), permit: { box.permit($0) }, window: window, width: width,
                            maxHeight: maxHeight, windowID: windowID, armDelay: armDelay, canSend: canSend, prepare: prepare)
    }

    private func form(_ h: ApprovalCardHarness, file: StaticString = #filePath, line: UInt = #line) throws -> ApprovalQuestionFormView {
        try XCTUnwrap(h.card.questionForm, "no question form on the card", file: file, line: line)
    }

    private func submitButton(_ h: ApprovalCardHarness, file: StaticString = #filePath, line: UInt = #line) throws -> ApprovalButton {
        try XCTUnwrap(h.card.submitButton, "no Submit button on the card", file: file, line: line)
    }

    private func press(_ button: NSButton?, file: StaticString = #filePath, line: UInt = #line) {
        QuestionTestViews.press(button, file: file, line: line)
    }

    private func forcePress(_ button: NSButton?, file: StaticString = #filePath, line: UInt = #line) {
        QuestionTestViews.forcePress(button, file: file, line: line)
    }

    private func choose(_ h: ApprovalCardHarness, _ question: Int, _ option: Int,
                        file: StaticString = #filePath, line: UInt = #line) throws {
        press(try form(h, file: file, line: line).optionButton(question: question, option: option), file: file, line: line)
    }

    private func typeText(_ text: String, intoOtherOf question: Int, _ h: ApprovalCardHarness,
                      file: StaticString = #filePath, line: UInt = #line) throws {
        let field = try XCTUnwrap(try form(h, file: file, line: line).otherField(question: question), "no Other field", file: file, line: line)
        QuestionTestViews.enter(text, into: field, in: h.window)
        h.sync()
    }

    /// Answer every question of the fixture: Postgres, and Caching.
    private func fillFixture(_ h: ApprovalCardHarness, file: StaticString = #filePath, line: UInt = #line) throws {
        try choose(h, 0, 0, file: file, line: line)
        try choose(h, 1, 0, file: file, line: line)
    }

    private func fillAll(_ h: ApprovalCardHarness, count: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        for q in 0 ..< count { try choose(h, q, 0, file: file, line: line) }
    }

    private func isOn(_ button: NSButton?) -> Bool { button?.state == .on }

    private func assertChoice(_ h: ApprovalCardHarness, _ q: Int, options: Set<Int>, other: Bool,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let f = try form(h, file: file, line: line)
        let count = h.card.options.questions?[q].options.count ?? 0
        for o in 0 ..< count {
            XCTAssertEqual(isOn(f.optionButton(question: q, option: o)), options.contains(o), "q\(q) option \(o)", file: file, line: line)
        }
        XCTAssertEqual(isOn(f.otherButton(question: q)), other, "q\(q) Other", file: file, line: line)
        XCTAssertEqual(f.selections[q].selected, options, "q\(q) model", file: file, line: line)
        XCTAssertEqual(f.selections[q].otherChosen, other, "q\(q) model Other", file: file, line: line)
    }

    private func visibleTitles(_ card: ApprovalCardView) -> [String] {
        ApprovalTestViews.buttons(in: card, visibleOnly: true).map(\.title).filter { !$0.isEmpty }
    }

    private func answerFrame(_ sent: ApprovalRecorder.Sent) throws -> [String: Any] {
        let frame = ClientApprovalAnswer(requestId: sent.requestID, decision: sent.decision,
                                         windowId: sent.windowID, operatorNonce: nil)
        let data = try JSONEncoder().encode(frame)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decisionObject(of frame: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(frame["decision"] as? [String: Any])
    }

    /// The decision alone, as the daemon receives it: sorted keys, so it compares as text.
    private func decisionJSON(_ sent: ApprovalRecorder.Sent) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(sent.decision), as: UTF8.self)
    }

    private func refuse(_ h: ApprovalCardHarness, code: String) throws {
        h.store.handle(.answerRefused(try ApprovalTestRequests.refused(id: "req-1", code: code)))
        h.sync()
    }

    // MARK: What the card shows (AQ-1)

    func testAQuestionCardShowsEachQuestionWithItsHeaderItsTextAndEveryOptionWithItsDescription() throws {
        let h = try harness()
        let texts = ApprovalTestViews.labelTexts(in: h.card)
        for expected in ["Which database should we use?", "Which features do you want to enable?",
                         "Postgres", "Relational, strong consistency", "SQLite", "Embedded, zero setup",
                         "Caching", "In-memory response cache", "Metrics", "Prometheus endpoint", "Tracing", "OpenTelemetry spans"] {
            XCTAssertTrue(texts.contains(expected), "`\(expected)` is not visible on the card: \(texts)")
        }
        let f = try form(h)
        XCTAssertEqual(f.headerChip(0)?.stringValue.lowercased(), "database")
        XCTAssertEqual(f.headerChip(1)?.stringValue.lowercased(), "features")
        XCTAssertTrue(texts.contains { $0.lowercased() == "database" }, "the header chip is on the card")
        XCTAssertTrue(texts.contains { $0.lowercased() == "features" })
    }

    func testTheHeadlineSaysTheAgentWantsToAskAQuestionAndThereIsNoApologyAboutClaudeCodesInterface() throws {
        let h = try harness()
        XCTAssertEqual(h.card.listing.headline, "Cody wants to ask you a question")
        XCTAssertTrue(ApprovalTestViews.labelTexts(in: h.card).contains("Cody wants to ask you a question"))
        XCTAssertFalse(ApprovalTestViews.labelTexts(in: h.card).contains { $0.contains("Claude Code's own interface") })
        XCTAssertEqual(h.card.accessibilityLabel(), "Approval needed: Cody wants to ask you a question")
    }

    func testAQuestionCardOffersDenyAndSubmitAndNoAllowDenyAndStopOrNoteControl() throws {
        let h = try harness()
        XCTAssertEqual(h.card.denyButton.title, "Deny")
        XCTAssertEqual(h.card.submitButton?.title, "Submit")
        XCTAssertEqual(h.card.submitButton?.identifier?.rawValue, "answer_questions")
        XCTAssertNil(h.card.allowButton, "the daemon listed allow_once; this card must not offer it")
        XCTAssertNil(h.card.denyAndStopButton)
        XCTAssertNil(h.card.denyMoreButton)
        XCTAssertEqual(Set(visibleTitles(h.card)), ["Deny", "Submit", "Details"])
        XCTAssertTrue(rigAllSubviews(of: h.card).filter { $0 is NSPopUpButton || $0 is NSSegmentedControl || $0 is NSSwitch }.isEmpty)
        let words = ApprovalTestViews.buttons(in: h.card).map { [$0.title, $0.accessibilityLabel() ?? "", $0.toolTip ?? ""].joined(separator: " ").lowercased() }
        for forbidden in ["allow", "remember", "always", "session", "persist", "deny & stop", "deny and stop"] {
            XCTAssertFalse(words.contains { $0.contains(forbidden) }, "no control may say `\(forbidden)`: \(words)")
        }
    }

    func testTheOnlyEditableFieldsAreTheOtherFields() throws {
        let h = try harness()
        let editable = rigAllSubviews(of: h.card).compactMap { $0 as? NSTextField }
            .filter { $0.isEditable && !$0.isHiddenOrHasHiddenAncestor }
        XCTAssertEqual(Set(editable.map { $0.identifier?.rawValue ?? "?" }), ["q0_other_field", "q1_other_field"],
                       "no note field on a question card")
    }

    func testNothingIsChosenAtFirstAndSubmitIsDisabledWhileDenyIsEnabled() throws {
        let h = try harness()
        try assertChoice(h, 0, options: [], other: false)
        try assertChoice(h, 1, options: [], other: false)
        XCTAssertFalse(try submitButton(h).isEnabled)
        XCTAssertTrue(h.card.denyButton.isEnabled)
        XCTAssertEqual(h.card.listing.options, [
            ApprovalCardListing.Option(id: "deny", enabled: true, label: "Deny"),
            ApprovalCardListing.Option(id: "answer_questions", enabled: false, label: "Submit"),
        ])
    }

    func testKeyboardFocusNeverLandsOnAHiddenView() throws {
        // The raw input is collapsed behind Details; Tab or a click on the card must not hand focus to the hidden text view.
        let h = try harness()
        if let target = h.card.initialKeyView {
            XCTAssertFalse(target.isHiddenOrHasHiddenAncestor, "initial key view is \(type(of: target)), and it is hidden")
        }
    }

    // MARK: Details

    func testTheRawInputIsBehindACollapsedDetailsDisclosure() throws {
        let h = try harness()
        let details = try XCTUnwrap(h.card.detailsButton)
        XCTAssertEqual(details.title, "Details")
        XCTAssertFalse(h.card.detailsExpanded)
        XCTAssertTrue(h.card.inputView.isHidden)
        XCTAssertTrue(h.card.inputView.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(details.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(details.isEnabled)
    }

    func testPressingDetailsExpandsTheRawInput() throws {
        let h = try harness()
        press(h.card.detailsButton)
        XCTAssertTrue(h.card.detailsExpanded)
        XCTAssertFalse(h.card.inputView.isHidden)
        XCTAssertFalse(h.card.inputView.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(h.recorder.sent.isEmpty, "opening Details answers nothing")
        XCTAssertTrue(h.recorder.reports.isEmpty)
    }

    func testOpeningDetailsAsksTheHostToRemeasureTheCard() throws {
        let h = try harness()
        var asked = 0
        h.card.onNeedsLayout = { asked += 1 }
        press(h.card.detailsButton)
        XCTAssertGreaterThanOrEqual(asked, 1, "the input adds height, so the host must measure again")
    }

    func testDetailsStillShowsTheRequestsInputAsReceived() throws {
        let h = try harness()
        let shown = h.card.inputView.displayedLines.joined(separator: "\n")
        for expected in ["Which database should we use?", "Postgres", "Relational, strong consistency", "multiSelect",
                         "Which features do you want to enable?", "Tracing"] {
            XCTAssertTrue(shown.contains(expected), "`\(expected)` is missing from the Details input: \(shown)")
        }
        XCTAssertFalse(h.card.listing.input.isEmpty)
        XCTAssertTrue(h.card.model.isVerified, "the raw input is the request's input, byte for byte")
    }

    func testChoosingAndSubmittingNeverNeedDetailsToHaveBeenOpened() throws {
        // Unlike Allow once on an ordinary card, there is no read-through gate: the form is the thing being read.
        let h = try harness()
        XCTAssertFalse(h.card.detailsExpanded)
        try fillFixture(h)
        XCTAssertTrue(try submitButton(h).isEnabled)
    }

    // MARK: Other cards are unchanged

    func testABashCardHasNoQuestionFormSubmitOrDetails() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm())
        XCTAssertNil(h.card.questionForm)
        XCTAssertNil(h.card.submitButton)
        XCTAssertNil(h.card.detailsButton)
        XCTAssertFalse(h.card.detailsExpanded)
        XCTAssertFalse(h.card.inputView.isHidden, "the input is always shown on an ordinary card")
        XCTAssertEqual(Set(visibleTitles(h.card)), ["Deny", "▾", "Deny & stop", "Allow once"])
        XCTAssertEqual(h.card.listing.options.map(\.id), ["deny", "deny_with_note", "deny_and_stop", "allow_once"])
        XCTAssertEqual(h.card.listing.headline, "Cody wants to run Bash")
    }

    func testABashCardThatListsAnswerQuestionsStillHasNoQuestionForm() throws {
        let request = try ApprovalTestRequests.bash(ApprovalTestRequests.simpleRmCommand,
                                                    options: Q.offered)
        let h = ApprovalCardHarness(self, request: request)
        XCTAssertNil(h.card.questionForm)
        XCTAssertNil(h.card.submitButton)
        XCTAssertNotNil(h.card.allowButton)
        XCTAssertEqual(h.card.listing.options.map(\.id), ["deny", "deny_with_note", "deny_and_stop", "allow_once"])
    }

    func testAnAskUserQuestionTheCardCannotAnswerStaysDenyOnlyWithTheExplanation() throws {
        let b = Q.option("B"), a = Q.option("A")
        let cases: [(String, ApprovalRequestWire)] = [
            ("answer_questions not offered", try Q.ask(options: ApprovalTestRequests.allOptions)),
            ("a text question", try Q.ask(input: ["questions": [["question": "Name?", "kind": "text", "options": [a, b]] as Q.Obj]])),
            ("five questions", try Q.ask(Q.questions(count: 5))),
            ("one option", try Q.ask([Q.question("Q?", options: [a])])),
            ("the single-question shape", try Q.ask(input: ["question": "Which one?"])),
        ]
        for (name, request) in cases {
            let h = ApprovalCardHarness(self, request: request)
            XCTAssertNil(h.card.questionForm, name)
            XCTAssertNil(h.card.submitButton, name)
            XCTAssertNil(h.card.detailsButton, name)
            XCTAssertNil(h.card.allowButton, name)
            XCTAssertEqual(visibleTitles(h.card), ["Deny"], name)
            XCTAssertEqual(h.card.listing.options.map(\.id), ["deny"], name)
            XCTAssertTrue(ApprovalTestViews.labelTexts(in: h.card).contains("This tool needs Claude Code's own interface; Nostromo can't approve it"), name)
        }
    }

    func testTheCardTheAP2aTestsUseForAClaudeCodeOnlyToolIsStillThatCard() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.requiresUserInteraction())
        XCTAssertNil(h.card.questionForm)
        XCTAssertNil(h.card.submitButton)
        XCTAssertEqual(visibleTitles(h.card), ["Deny"])
    }

    func testDenyOnEveryKindOfCardSendsAPlainDeny() throws {
        // Deny is the one control every card has.
        for request in [try Q.ask(), try ApprovalTestRequests.simpleRm(), try ApprovalTestRequests.requiresUserInteraction()] {
            let h = ApprovalCardHarness(self, request: request)
            press(h.card.denyButton)
            XCTAssertEqual(h.recorder.sent.map(\.decision), [ApprovalDecisionWire(kind: .deny)], request.toolName)
        }
    }

    // MARK: Choosing (AQ-2, AQ-4)

    func testPickingAnOptionOfTheSingleSelectQuestionSelectsOnlyThatRadioButton() throws {
        let h = try harness()
        try choose(h, 0, 1)
        try assertChoice(h, 0, options: [1], other: false)
        try choose(h, 0, 0)
        try assertChoice(h, 0, options: [0], other: false)
        try assertChoice(h, 1, options: [], other: false)
    }

    func testPressingTheChosenRadioButtonAgainKeepsItChosen() throws {
        let h = try harness()
        try choose(h, 0, 1)
        try choose(h, 0, 1)
        try assertChoice(h, 0, options: [1], other: false)
    }

    func testTheMultiSelectQuestionsOptionsAreCheckboxesThatToggle() throws {
        let h = try harness()
        try choose(h, 1, 2)
        try choose(h, 1, 0)
        try assertChoice(h, 1, options: [0, 2], other: false)
        try choose(h, 1, 2)
        try assertChoice(h, 1, options: [0], other: false)
    }

    func testTypingInOtherSelectsOtherAndReplacesTheLabelChosenInASingleSelectQuestion() throws {
        let h = try harness()
        try choose(h, 0, 1)
        try typeText("Oracle", intoOtherOf: 0, h)
        try assertChoice(h, 0, options: [], other: true)
        XCTAssertEqual(try form(h).selections[0].otherText, "Oracle")
        XCTAssertEqual(try form(h).otherField(question: 0)?.stringValue, "Oracle", "what was typed stays in the field")
    }

    func testPickingALabelAfterTypingInOtherUnselectsOtherInASingleSelectQuestion() throws {
        let h = try harness()
        try typeText("Oracle", intoOtherOf: 0, h)
        try assertChoice(h, 0, options: [], other: true)
        try choose(h, 0, 0)
        try assertChoice(h, 0, options: [0], other: false)
    }

    func testOtherAddsToTheTickedOptionsInTheMultiSelectQuestion() throws {
        let h = try harness()
        try choose(h, 1, 1)
        try typeText("Logging", intoOtherOf: 1, h)
        try assertChoice(h, 1, options: [1], other: true)
        try choose(h, 1, 2)
        try assertChoice(h, 1, options: [1, 2], other: true)
    }

    func testClearingTheOtherTextUnselectsOther() throws {
        let h = try harness()
        try typeText("Oracle", intoOtherOf: 0, h)
        try typeText("", intoOtherOf: 0, h)
        try assertChoice(h, 0, options: [], other: false)
    }

    func testTheOtherToggleSelectsOtherWithoutTextButThatIsNotAnAnswer() throws {
        let h = try harness()
        press(try form(h).otherButton(question: 0))
        try assertChoice(h, 0, options: [], other: true)
        try choose(h, 1, 0)
        XCTAssertFalse(try submitButton(h).isEnabled, "Other with no text answers nothing")
        XCTAssertNil(try form(h).answers)
    }

    func testBlankOtherTextIsNotAnAnswer() throws {
        let h = try harness()
        press(try form(h).otherButton(question: 0))
        try typeText("    ", intoOtherOf: 0, h)
        try choose(h, 1, 0)
        XCTAssertFalse(try submitButton(h).isEnabled)
        XCTAssertFalse(try form(h).isComplete)
    }

    func testOtherTextOverAThousandCharactersIsNotAnAnswerAndAThousandIs() throws {
        let h = try harness()
        try choose(h, 1, 0)
        try typeText(String(repeating: "a", count: 1001), intoOtherOf: 0, h)
        XCTAssertFalse(try submitButton(h).isEnabled, "1001 characters")
        XCTAssertNil(try form(h).answers)
        let message = "Answer too long (max 1000)"
        func shown() -> Bool {
            rigAllSubviews(of: h.card).contains { ($0 as? NSTextField)?.stringValue == message }
        }
        XCTAssertTrue(shown(), "a visible reason, not only a tooltip")

        try typeText(String(repeating: "a", count: 1000), intoOtherOf: 0, h)
        XCTAssertFalse(shown(), "the reason goes once the answer fits")
        XCTAssertTrue(try submitButton(h).isEnabled, "1000 characters")
        XCTAssertEqual(try form(h).answers?.first?.other?.count, 1000)
    }

    // MARK: Submit is enabled only for a complete form (AQ-5)

    func testSubmitStaysDisabledUntilEveryQuestionIsAnsweredWithOneTwoThreeAndFourQuestions() throws {
        for count in 1 ... 4 {
            let h = try harness(try Q.ask(Q.questions(count: count)))
            let submit = try submitButton(h)
            XCTAssertFalse(submit.isEnabled, "\(count) question(s): nothing answered")
            for q in 0 ..< count {
                XCTAssertFalse(submit.isEnabled, "\(count) question(s): \(q) answered")
                XCTAssertFalse(try form(h).isComplete, "\(count) question(s): \(q) answered")
                try choose(h, q, 0)
            }
            XCTAssertTrue(submit.isEnabled, "\(count) question(s): all answered")
            XCTAssertTrue(try form(h).isComplete)
            XCTAssertEqual(try form(h).answers?.count, count)
            XCTAssertEqual(h.card.listing.options.last, ApprovalCardListing.Option(id: "answer_questions", enabled: true, label: "Submit"))
        }
    }

    func testTheOrderInWhichTheQuestionsAreAnsweredDoesNotMatter() throws {
        for count in 2 ... 4 {
            let h = try harness(try Q.ask(Q.questions(count: count)))
            let submit = try submitButton(h)
            for q in (0 ..< count).reversed() {
                XCTAssertFalse(submit.isEnabled, "\(count) question(s): answering from the last, \(q) still open")
                try choose(h, q, 1)
            }
            XCTAssertTrue(submit.isEnabled, "\(count) question(s)")
        }
    }

    func testUntickingTheLastOptionOfAMultiSelectQuestionDisablesSubmitAgain() throws {
        let h = try harness(try Q.ask(Q.questions(count: 2)))
        try fillAll(h, count: 2)
        XCTAssertTrue(try submitButton(h).isEnabled, "precondition")
        try choose(h, 1, 0)
        XCTAssertFalse(try submitButton(h).isEnabled, "question 2 is open again")
        try choose(h, 1, 2)
        XCTAssertTrue(try submitButton(h).isEnabled)
    }

    func testSubmitIsDisabledWhileTheCardIsUnarmedEvenWithAFullFormAndNothingSendsAnything() throws {
        let h = try harness(armDelay: 30)
        try fillFixture(h)
        let submit = try submitButton(h)
        XCTAssertFalse(h.card.isArmed)
        XCTAssertTrue(try form(h).isComplete, "precondition: nothing but the delay holds Submit back")
        XCTAssertFalse(submit.isEnabled)
        XCTAssertEqual(h.card.listing.options.last, ApprovalCardListing.Option(id: "answer_questions", enabled: false, label: "Submit"))

        forcePress(submit)

        XCTAssertTrue(h.recorder.sent.isEmpty, "a click aimed at what was under the pointer a moment ago must not answer")
        XCTAssertEqual(h.store.entry(id: "req-1")?.state, ApprovalAnswerState.pending)
    }

    func testSubmitIsEnabledOnceTheDelayHasPassed() throws {
        let h = try harness(armDelay: 0.05)
        try fillFixture(h)
        XCTAssertFalse(try submitButton(h).isEnabled, "precondition: unarmed when it appears")
        XCTAssertTrue(pump(until: { h.card.isArmed }), "the card never armed")
        XCTAssertTrue(try submitButton(h).isEnabled)
        press(try submitButton(h))
        XCTAssertEqual(h.recorder.sent.count, 1)
    }

    func testDenyWorksWhileTheQuestionCardIsUnarmed() throws {
        let h = try harness(armDelay: 30)
        XCTAssertFalse(h.card.isArmed)
        XCTAssertTrue(h.card.denyButton.isEnabled)
        press(h.card.denyButton)
        XCTAssertEqual(h.recorder.sent.map(\.decision), [ApprovalDecisionWire(kind: .deny)])
    }

    func testAnIncompleteFormCanNeverBeSubmittedHoweverTheActionArrives() throws {
        let h = try harness()
        let submit = try submitButton(h)
        forcePress(submit)
        XCTAssertTrue(h.recorder.sent.isEmpty, "nothing answered")

        try choose(h, 0, 0)
        forcePress(submit)
        XCTAssertTrue(h.recorder.sent.isEmpty, "one of two questions answered: a partial answer is never sent")
        XCTAssertEqual(h.store.entry(id: "req-1")?.state, ApprovalAnswerState.pending)
        XCTAssertTrue(h.recorder.reports.isEmpty)
    }

    func testSubmitIsDisabledOnceTheCardHasLeftPendingHoweverItGotThere() throws {
        // Answered here.
        let answered = try harness()
        try fillFixture(answered)
        press(try submitButton(answered))
        answered.sync()
        XCTAssertFalse(try submitButton(answered).isEnabled, "in flight")
        forcePress(try submitButton(answered))
        XCTAssertEqual(answered.recorder.sent.count, 1)

        // Ended without this window's answer (another window answered, or it timed out).
        let ended = try harness()
        try fillFixture(ended)
        ended.store.handle(.resolved(try ApprovalTestRequests.resolved(id: "req-1", outcome: "answered", byWindow: "w-other")))
        ended.sync()
        XCTAssertFalse(try submitButton(ended).isEnabled, "ended")
        forcePress(try submitButton(ended))
        XCTAssertTrue(ended.recorder.sent.isEmpty)

        // Refused by the daemon: the card is `notSent`, and an answer is never re-sent.
        let refused = try harness()
        try fillFixture(refused)
        press(try submitButton(refused))
        refused.sync()
        try refuse(refused, code: "invalid_answer")
        guard case .notSent? = refused.store.entry(id: "req-1")?.state else { return XCTFail("expected not sent") }
        XCTAssertFalse(try submitButton(refused).isEnabled, "not sent")
        forcePress(try submitButton(refused))
        XCTAssertEqual(refused.recorder.sent.count, 1, "the answers are never re-sent")
    }

    // MARK: What goes out

    func testSubmitSendsOneAnswerQuestionsAnswerWithTheChosenLabelsInOptionOrder() throws {
        let h = try harness(windowID: "w-7")
        try choose(h, 0, 1)        // SQLite
        try choose(h, 1, 2)        // Tracing, then Caching: the answer lists them in option order
        try choose(h, 1, 0)

        press(try submitButton(h))

        XCTAssertEqual(h.recorder.sent.count, 1)
        let sent = try XCTUnwrap(h.recorder.sent.first)
        XCTAssertEqual(sent.requestID, "req-1")
        XCTAssertEqual(sent.windowID, "w-7")
        XCTAssertEqual(try decisionJSON(sent),
                       #"{"answers":[{"question":"Which database should we use?","selected":["SQLite"]},"#
                       + #"{"question":"Which features do you want to enable?","selected":["Caching","Tracing"]}],"#
                       + #""kind":"answer_questions"}"#)
        XCTAssertEqual(sent.decision.kind, .answerQuestions)
        XCTAssertNil(sent.decision.note)
        let frame = try answerFrame(sent)
        XCTAssertEqual(frame["type"] as? String, "approval_answer")
        XCTAssertEqual(frame["request_id"] as? String, "req-1")
        XCTAssertEqual(frame["window_id"] as? String, "w-7")
        XCTAssertEqual(Set(try decisionObject(of: frame).keys), ["kind", "answers"])
        XCTAssertEqual(try decisionObject(of: frame)["kind"] as? String, "answer_questions")
    }

    func testTheOtherTextGoesOutTrimmedInTheOtherFieldWithNoLabel() throws {
        let h = try harness()
        try typeText("  Oracle 23ai  ", intoOtherOf: 0, h)
        try choose(h, 1, 1)

        press(try submitButton(h))

        let sent = try XCTUnwrap(h.recorder.sent.first)
        XCTAssertEqual(try decisionJSON(sent),
                       #"{"answers":[{"other":"Oracle 23ai","question":"Which database should we use?","selected":[]},"#
                       + #"{"question":"Which features do you want to enable?","selected":["Metrics"]}],"#
                       + #""kind":"answer_questions"}"#)
    }

    func testALabelChosenAndThenReplacedByTypedTextIsNotSent() throws {
        let h = try harness()
        try choose(h, 0, 0)
        try typeText("Oracle", intoOtherOf: 0, h)
        try choose(h, 1, 0)
        press(try submitButton(h))

        let answers = try XCTUnwrap(h.recorder.sent.first?.decision.answers)
        XCTAssertEqual(answers[0], ApprovalQuestionAnswer(question: "Which database should we use?", selected: [], other: "Oracle"))
    }

    func testAMultiSelectAnswerCanCarryLabelsAndOtherTogether() throws {
        let h = try harness()
        try choose(h, 0, 0)
        try choose(h, 1, 2)
        try choose(h, 1, 1)
        try typeText("Logging", intoOtherOf: 1, h)

        press(try submitButton(h))

        let answers = try XCTUnwrap(h.recorder.sent.first?.decision.answers)
        XCTAssertEqual(answers[1], ApprovalQuestionAnswer(question: "Which features do you want to enable?",
                                                          selected: ["Metrics", "Tracing"], other: "Logging"))
    }

    func testTwoThreeAndFourQuestionsAreAnsweredInQuestionOrderInOneFrame() throws {
        for count in 2 ... 4 {
            let h = try harness(try Q.ask(Q.questions(count: count)))
            for q in (0 ..< count).reversed() { try choose(h, q, q % 3) }
            press(try submitButton(h))

            XCTAssertEqual(h.recorder.sent.count, 1, "\(count) questions")
            let answers = try XCTUnwrap(h.recorder.sent.first?.decision.answers)
            XCTAssertEqual(answers.map(\.question), (1 ... count).map { "Question \($0)?" }, "\(count) questions")
            XCTAssertEqual(answers.map(\.selected), (0 ..< count).map { ["Q\($0 + 1)\(["A", "B", "C"][$0 % 3])"] }, "\(count) questions")
        }
    }

    func testLabelsQuestionsAndTextGoOutByteForByteIncludingHiddenCharactersAndPadding() throws {
        let zw = "\u{200B}", rlo = "\u{202E}"
        let questions = [Q.question(" Pay\(rlo)x?  ", header: "H", options: [Q.option("Yes\(zw)"), Q.option(" Yes "), Q.option("é \u{1F642}")])]
        let h = try harness(try Q.ask(questions))
        try choose(h, 0, 1)
        press(try submitButton(h))
        XCTAssertEqual(h.recorder.sent.first?.decision.answers,
                       [ApprovalQuestionAnswer(question: " Pay\(rlo)x?  ", selected: [" Yes "], other: nil)])

        let second = try harness(try Q.ask(questions))
        try choose(second, 0, 0)
        try choose(second, 0, 2)
        try choose(second, 0, 0)
        press(try submitButton(second))
        XCTAssertEqual(second.recorder.sent.first?.decision.answers?.first?.selected, ["Yes\(zw)"], "the zero-width character is part of the label")
    }

    func testHiddenCharactersInTheQuestionAreShownAsTokensNotDrawn() throws {
        // The AP2a rule for every string the card draws from a request, applied to the form: a hidden or
        // direction-changing character is shown as a visible token. (The answer keeps the exact label: see above.)
        let zw = "\u{200B}", rlo = "\u{202E}"
        let questions = [Q.question("Pay\(rlo)x?", header: "Hd\(zw)r",
                                    options: [Q.option("Yes\(zw)", "d\(rlo)esc"), Q.option("No")])]
        let h = try harness(try Q.ask(questions))
        let f = try form(h)
        let shown: [(String, NSTextField)] = [
            ("question", f.questionLabel(0)), ("header", try XCTUnwrap(f.headerChip(0))),
            ("option label", f.optionLabel(question: 0, option: 0)),
            ("description", f.descriptionLabel(question: 0, option: 0)),
        ]
        for (name, label) in shown {
            XCTAssertFalse(label.stringValue.unicodeScalars.contains(where: ApprovalTestRequests.isInvisible),
                           "\(name) draws a hidden character raw: \(label.stringValue.unicodeScalars.map { String($0.value, radix: 16) })")
            XCTAssertTrue(label.stringValue.contains("\u{27E8}U+"), "\(name) shows a token: \(label.stringValue)")
        }
    }

    func testASecondPressOfSubmitSendsNothing() throws {
        let h = try harness()
        try fillFixture(h)
        press(try submitButton(h))
        press(try submitButton(h))
        h.sync()
        press(try submitButton(h))
        forcePress(try submitButton(h))
        XCTAssertEqual(h.recorder.sent.count, 1)
    }

    func testDenyOnAQuestionCardSendsAPlainDenyEvenWithAFilledForm() throws {
        let h = try harness()
        try fillFixture(h)
        try typeText("Oracle", intoOtherOf: 0, h)
        press(h.card.denyButton)

        XCTAssertEqual(h.recorder.sent, [ApprovalRecorder.Sent(requestID: "req-1", decision: ApprovalDecisionWire(kind: .deny),
                                                                windowID: "w-test")])
        let decision = try decisionObject(of: try answerFrame(try XCTUnwrap(h.recorder.sent.first)))
        XCTAssertEqual(Set(decision.keys), ["kind"], "a denial never carries answers")
        XCTAssertEqual(decision["kind"] as? String, "deny")
    }

    func testDenyOnAQuestionCardSendsOnceAndDisablesTheForm() throws {
        let h = try harness()
        press(h.card.denyButton)
        h.sync()
        XCTAssertFalse(h.card.denyButton.isEnabled)
        XCTAssertFalse(try submitButton(h).isEnabled)
        XCTAssertTrue(QuestionTestViews.operableControls(in: try form(h)).allSatisfy { !$0.isEnabled })
        XCTAssertTrue(ApprovalTestViews.labelTexts(in: h.card).contains("Denying…"))
        press(h.card.denyButton)
        XCTAssertEqual(h.recorder.sent.count, 1)
    }

    // MARK: After Submit

    func testAfterSubmitEveryControlOfTheFormIsDisabledAndTheCardSaysSendingAnswers() throws {
        let h = try harness()
        try fillFixture(h)
        let controls = QuestionTestViews.operableControls(in: try form(h))
        XCTAssertTrue(controls.allSatisfy(\.isEnabled), "precondition")

        press(try submitButton(h))
        h.sync()

        XCTAssertFalse(try form(h).isEnabled)
        XCTAssertTrue(controls.allSatisfy { !$0.isEnabled }, "\(controls.filter(\.isEnabled).map { $0.identifier?.rawValue ?? "?" })")
        XCTAssertFalse(try submitButton(h).isEnabled)
        XCTAssertFalse(h.card.denyButton.isEnabled)
        XCTAssertTrue(ApprovalTestViews.labelTexts(in: h.card).contains("Sending answers…"), "\(ApprovalTestViews.labelTexts(in: h.card))")
        XCTAssertEqual(h.card.listing.state, "sending")
        XCTAssertTrue(h.card.listing.options.allSatisfy { !$0.enabled })
        XCTAssertEqual(h.store.entry(id: "req-1")?.state, ApprovalAnswerState.inFlight(.answerQuestions))
    }

    func testOnceTheDaemonResolvesTheRequestTheCardSaysAnswered() throws {
        let h = try harness()
        try fillFixture(h)
        press(try submitButton(h))
        h.sync()

        h.store.handle(.resolved(try ApprovalTestRequests.resolved(id: "req-1", outcome: "answered", byWindow: "w-test")))
        h.sync()

        XCTAssertTrue(ApprovalTestViews.labelTexts(in: h.card).contains("Answered"), "\(ApprovalTestViews.labelTexts(in: h.card))")
        XCTAssertFalse(ApprovalTestViews.labelTexts(in: h.card).contains("Sending answers…"))
        XCTAssertEqual(h.card.listing.state, "Answered")
        XCTAssertFalse(try form(h).isEnabled)
        XCTAssertFalse(try submitButton(h).isEnabled)
    }

    func testAnAnswerFromAnotherWindowShowsAnsweredHereAndDisablesTheFormWithoutSendingAnything() throws {
        let h = try harness()
        try choose(h, 0, 0)
        h.store.handle(.resolved(try ApprovalTestRequests.resolved(id: "req-1", outcome: "answered", byWindow: "w-other")))
        h.sync()
        XCTAssertTrue(ApprovalTestViews.labelTexts(in: h.card).contains("Answered"))
        XCTAssertFalse(try form(h).isEnabled)
        XCTAssertTrue(QuestionTestViews.operableControls(in: try form(h)).allSatisfy { !$0.isEnabled })
        XCTAssertTrue(h.recorder.sent.isEmpty)
        XCTAssertTrue(h.recorder.reports.isEmpty)
    }

    func testAControlOfTheFormPressedAfterSubmitChangesNothing() throws {
        let h = try harness()
        try fillFixture(h)
        press(try submitButton(h))
        h.sync()
        let before = try form(h).selections
        let answers = try form(h).answers

        forcePress(try form(h).optionButton(question: 0, option: 1))
        forcePress(try form(h).optionButton(question: 1, option: 2))
        forcePress(try form(h).otherButton(question: 0))

        XCTAssertEqual(try form(h).selections, before, "what was sent is what the form still shows")
        XCTAssertEqual(try form(h).answers, answers)
        XCTAssertEqual(h.recorder.sent.count, 1)
    }

    func testAnInvalidAnswerRefusalSaysSoLeavesDenyAndNeverResendsTheAnswers() throws {
        let h = try harness()
        try fillFixture(h)
        press(try submitButton(h))
        h.sync()

        try refuse(h, code: "invalid_answer")

        XCTAssertEqual(h.store.entry(id: "req-1")?.state, ApprovalAnswerState.notSent("Not sent: the daemon refused these answers"))
        XCTAssertTrue(ApprovalTestViews.labelTexts(in: h.card).contains("Not sent: the daemon refused these answers"),
                      "\(ApprovalTestViews.labelTexts(in: h.card))")
        XCTAssertTrue(h.card.denyButton.isEnabled, "Deny is never stranded")
        XCTAssertFalse(try submitButton(h).isEnabled)
        forcePress(try submitButton(h))
        XCTAssertEqual(h.recorder.sent.count, 1, "the answers are not sent again")

        press(h.card.denyButton)
        XCTAssertEqual(h.recorder.sent.map(\.decision.kind), [.answerQuestions, .deny])
        XCTAssertEqual(h.recorder.sent.last?.decision, ApprovalDecisionWire(kind: .deny))
    }

    // MARK: A rebuilt card never answers twice

    func testARebuiltCardNeverSendsASecondAnswerAndShowsItsFormDisabled() throws {
        let h = try harness()
        try fillFixture(h)
        press(try submitButton(h))
        XCTAssertEqual(h.recorder.sent.count, 1, "precondition")

        let entry = try XCTUnwrap(h.store.entry(id: "req-1"))
        let rebuilt = ApprovalCardView(entry: entry, store: h.store, windowID: { "w-test" }, permit: ApprovalCardHarness.humanPermit)
        rebuilt.frame = NSRect(x: 20, y: 20, width: 400, height: rebuilt.preferredHeight(forWidth: 400, maxHeight: 400))
        h.window.contentView?.addSubview(rebuilt)
        rebuilt.layoutSubtreeIfNeeded()

        let rebuiltForm = try XCTUnwrap(rebuilt.questionForm)
        XCTAssertFalse(rebuiltForm.isEnabled)
        XCTAssertTrue(QuestionTestViews.operableControls(in: rebuiltForm).allSatisfy { !$0.isEnabled })
        XCTAssertFalse(try XCTUnwrap(rebuilt.submitButton).isEnabled)
        XCTAssertFalse(rebuilt.denyButton.isEnabled)
        XCTAssertTrue(ApprovalTestViews.labelTexts(in: rebuilt).contains("Sending answers…"))

        for button in ApprovalTestViews.buttons(in: rebuilt) {
            button.performClick(nil)
            if let action = button.action { _ = NSApp.sendAction(action, to: button.target, from: button) }
        }
        XCTAssertEqual(h.recorder.sent.count, 1, "one answer for the life of the process, whatever views come and go")
    }

    func testACardRebuiltFromAStaleWaitingEntryStillCannotAnswerTwice() throws {
        let request = try Q.ask()
        let h = try harness(request)
        try fillFixture(h)
        press(try submitButton(h))
        XCTAssertEqual(h.recorder.sent.count, 1, "precondition")

        let stale = ApprovalEntry(request: request, state: .pending)
        let rebuilt = ApprovalCardView(entry: stale, store: h.store, windowID: { "w-test" }, permit: ApprovalCardHarness.humanPermit)
        rebuilt.frame = NSRect(x: 20, y: 20, width: 400, height: rebuilt.preferredHeight(forWidth: 400, maxHeight: 400))
        h.window.contentView?.addSubview(rebuilt)
        rebuilt.layoutSubtreeIfNeeded()
        let rebuiltForm = try XCTUnwrap(rebuilt.questionForm)
        press(rebuiltForm.optionButton(question: 0, option: 0))
        press(rebuiltForm.optionButton(question: 1, option: 0))
        XCTAssertTrue(try XCTUnwrap(rebuilt.submitButton).isEnabled, "precondition: the stale card offers Submit")

        press(rebuilt.submitButton)
        press(rebuilt.denyButton)

        XCTAssertEqual(h.recorder.sent.count, 1, "the store, not the view, decides")
    }

    // MARK: Through the overlay host: Answered, then gone

    private final class HostRig {
        let recorder: ApprovalRecorder
        let store: ApprovalStore
        let window: NSWindow
        let host: ApprovalOverlayHost

        init(_ testCase: XCTestCase, size: NSSize = NSSize(width: 700, height: 640), windowID: String = "w-test") {
            let recorder = ApprovalRecorder()
            let store = recorder.makeStore()
            let window = makeRigWindow(testCase, size: size)
            let host = ApprovalOverlayHost(tag: "cody-1", store: store, windowID: { windowID }, permit: ApprovalCardHarness.humanPermit,
                                           armDelay: 0, isOnScreen: { true }, reduceMotion: { true })
            host.frame = NSRect(origin: .zero, size: size)
            window.contentView!.addSubview(host)
            self.recorder = recorder
            self.store = store
            self.window = window
            self.host = host
            layout()
        }

        func layout() {
            window.contentView?.layoutSubtreeIfNeeded()
            host.layoutSubtreeIfNeeded()
        }

        func arrive(_ request: ApprovalRequestWire) {
            store.handle(.request(request))
            layout()
        }
    }

    func testAnAnsweredCardShowsAnsweredThenLeavesAfterTwoSecondsLikeAnAllowedOne() throws {
        let rig = HostRig(self, windowID: "w-42")
        rig.arrive(try Q.ask())
        let card = try XCTUnwrap(rig.host.card)
        let f = try XCTUnwrap(card.questionForm)
        press(f.optionButton(question: 0, option: 0))
        press(f.optionButton(question: 1, option: 1))

        press(card.submitButton)

        XCTAssertEqual(rig.recorder.sent.map(\.windowID), ["w-42"])
        XCTAssertEqual(rig.recorder.sent.first?.decision.kind, .answerQuestions)
        XCTAssertFalse(f.isEnabled, "the host showed the card the in-flight state")
        XCTAssertTrue(ApprovalTestViews.labelTexts(in: card).contains("Sending answers…"))

        rig.store.handle(.resolved(try ApprovalTestRequests.resolved(id: "req-1", outcome: "answered", byWindow: "w-42")))

        XCTAssertTrue(rig.host.card === card, "the same card shows the outcome in place")
        XCTAssertTrue(ApprovalTestViews.labelTexts(in: card).contains("Answered"))
        XCTAssertEqual(rig.host.listings.first?.state, "Answered")
        XCTAssertEqual(rig.recorder.scheduled.map { $0.delay }, [2], "the outcome is shown for 2 s")

        rig.recorder.runScheduled()

        XCTAssertNil(rig.host.card, "with Reduce Motion the card is removed with no animation")
        XCTAssertTrue(rig.host.subviews.isEmpty)
        XCTAssertNil(card.superview)
    }

    func testTheHostsQuestionCardTakesTheSameAnswerOnlyOnce() throws {
        let rig = HostRig(self)
        rig.arrive(try Q.ask())
        let card = try XCTUnwrap(rig.host.card)
        let f = try XCTUnwrap(card.questionForm)
        press(f.optionButton(question: 0, option: 0))
        press(f.optionButton(question: 1, option: 1))
        press(card.submitButton)
        press(card.submitButton)
        forcePress(card.submitButton)
        XCTAssertEqual(rig.recorder.sent.count, 1)
    }

    func testTwoWindowsOnOneQuestionSendOneAnswer() throws {
        let recorder = ApprovalRecorder()
        let store = recorder.makeStore()
        func rig(_ id: String) -> (ApprovalOverlayHost, NSWindow) {
            let window = makeRigWindow(self, size: NSSize(width: 700, height: 640))
            let host = ApprovalOverlayHost(tag: "cody-1", store: store, windowID: { id }, permit: ApprovalCardHarness.humanPermit,
                                           armDelay: 0, isOnScreen: { true }, reduceMotion: { true })
            host.frame = NSRect(x: 0, y: 0, width: 700, height: 640)
            window.contentView!.addSubview(host)
            return (host, window)
        }
        let (hostA, windowA) = rig("w-1")
        let (hostB, windowB) = rig("w-2")
        store.handle(.request(try Q.ask()))
        for w in [windowA, windowB] { w.contentView?.layoutSubtreeIfNeeded() }
        let a = try XCTUnwrap(hostA.card), b = try XCTUnwrap(hostB.card)
        for card in [a, b] {
            press(card.questionForm?.optionButton(question: 0, option: 0))
            press(card.questionForm?.optionButton(question: 1, option: 0))
            XCTAssertTrue(card.submitButton?.isEnabled == true, "precondition")
        }

        press(a.submitButton)

        XCTAssertFalse(b.submitButton?.isEnabled ?? true, "the other window's card sees the answer")
        XCTAssertTrue(QuestionTestViews.operableControls(in: try XCTUnwrap(b.questionForm)).allSatisfy { !$0.isEnabled })
        forcePress(b.submitButton)
        XCTAssertEqual(recorder.sent.map(\.windowID), ["w-1"], "one answer, from the window that gave it")
    }

    // MARK: Only a person answers

    func testASyntheticSubmitIsRefusedAndReportedAndTheCardStaysAsItWas() throws {
        let box = QuestionPermitBox()
        let h = try harness(box: box)
        try fillFixture(h)
        let submit = try submitButton(h)
        XCTAssertTrue(submit.isEnabled, "precondition")

        box.permit = { _ in .refused(reason: .appControl) }
        press(submit)

        XCTAssertTrue(h.recorder.sent.isEmpty, "a synthetic Submit must never answer")
        XCTAssertEqual(h.store.entry(id: "req-1")?.state, ApprovalAnswerState.pending)
        XCTAssertEqual(h.card.listing.state, "pending")
        let formStillEnabled = try form(h).isEnabled
        XCTAssertTrue(submit.isEnabled && h.card.denyButton.isEnabled && formStillEnabled, "a person can still answer")
        XCTAssertEqual(h.recorder.reports, [ApprovalRecorder.Report(requestID: "req-1", control: "answer_questions", channel: .appControl)])

        box.permit = ApprovalCardHarness.humanPermit
        press(submit)
        XCTAssertEqual(h.recorder.sent.map(\.decision.kind), [.answerQuestions], "the refusal did not poison the card")
        XCTAssertEqual(h.recorder.reports.count, 1)
    }

    func testTheRealGestureCheckRefusesASubmitDuringAnAppControlRequest() throws {
        // The card's own, real `HumanGesture.permit` once the form has been filled in by a person.
        let box = QuestionPermitBox()
        let h = try harness(box: box)
        try fillFixture(h)
        box.permit = { control in HumanGesture.permit(NSApp.currentEvent, control: control) }

        SyntheticInputGate.begin()
        defer { SyntheticInputGate.end() }
        press(try submitButton(h))

        XCTAssertTrue(h.recorder.sent.isEmpty)
        XCTAssertEqual(h.recorder.reports, [ApprovalRecorder.Report(requestID: "req-1", control: "answer_questions", channel: .appControl)])
        XCTAssertEqual(h.store.entry(id: "req-1")?.state, ApprovalAnswerState.pending)
    }

    func testASyntheticClickOnAnOptionChangesNoSelectionAndIsReported() throws {
        let box = QuestionPermitBox()
        let h = try harness(box: box)
        box.permit = { control in HumanGesture.permit(NSApp.currentEvent, control: control) }
        SyntheticInputGate.begin()
        defer { SyntheticInputGate.end() }

        try choose(h, 0, 0)
        try choose(h, 1, 2)
        press(try form(h).otherButton(question: 0))

        try assertChoice(h, 0, options: [], other: false)
        try assertChoice(h, 1, options: [], other: false)
        XCTAssertFalse(try submitButton(h).isEnabled)
        XCTAssertTrue(h.recorder.sent.isEmpty)
        XCTAssertEqual(h.recorder.reports.map(\.control), ["answer_option", "answer_option", "answer_option"])
        XCTAssertTrue(h.recorder.reports.allSatisfy { $0.channel == .appControl && $0.requestID == "req-1" })
    }

    func testAnAgentCannotFillInAndSubmitTheFormThroughAppControlAtAll() throws {
        let h = try harness(box: {
            let box = QuestionPermitBox()
            box.permit = { control in HumanGesture.permit(NSApp.currentEvent, control: control) }
            return box
        }())
        SyntheticInputGate.begin()
        defer { SyntheticInputGate.end() }

        try choose(h, 0, 0)
        try choose(h, 1, 0)
        forcePress(try submitButton(h))
        forcePress(h.card.denyButton)

        XCTAssertTrue(h.recorder.sent.isEmpty, "not even a Deny: nothing is answered for the person")
        XCTAssertEqual(h.store.entry(id: "req-1")?.state, ApprovalAnswerState.pending)
    }

    func testARefusedClickKeepsTheChoiceThatWasThereAndTypingStillNeedsNoGesture() throws {
        let box = QuestionPermitBox()
        let h = try harness(box: box)
        try choose(h, 0, 0)
        box.permit = { _ in .refused(reason: .appControl) }

        try choose(h, 0, 1)
        try assertChoice(h, 0, options: [0], other: false)

        try typeText("Oracle", intoOtherOf: 0, h)
        try assertChoice(h, 0, options: [], other: true)
        XCTAssertEqual(h.recorder.reports.map(\.control), ["answer_option"], "only the click was reported, not the typing")
    }

    func testTypingInOtherNeedsNoGestureButSubmittingItDoes() throws {
        let box = QuestionPermitBox()
        box.permit = { _ in .refused(reason: .appControl) }
        let h = try harness(box: box)

        try typeText("Oracle", intoOtherOf: 0, h)
        try typeText("Logging", intoOtherOf: 1, h)
        XCTAssertTrue(try submitButton(h).isEnabled, "the draft is complete")
        XCTAssertTrue(h.recorder.reports.isEmpty, "typing is not reported")

        press(try submitButton(h))

        XCTAssertTrue(h.recorder.sent.isEmpty)
        XCTAssertEqual(h.recorder.reports.map(\.control), ["answer_questions"])

        box.permit = ApprovalCardHarness.humanPermit
        press(try submitButton(h))
        XCTAssertEqual(h.recorder.sent.first?.decision.answers, [
            ApprovalQuestionAnswer(question: "Which database should we use?", selected: [], other: "Oracle"),
            ApprovalQuestionAnswer(question: "Which features do you want to enable?", selected: [], other: "Logging"),
        ])
    }

    func testAnAccessibilityPressWithNoEventAndVoiceOverOffIsRefusedAndReportedAsAccessibility() throws {
        let box = QuestionPermitBox()
        let h = try harness(box: box)
        try fillFixture(h)
        box.permit = { control in HumanGesture.permit(nil, control: control, voiceOverEnabled: { false }, allowsSynthetic: { false }) }

        press(try submitButton(h))
        try choose(h, 0, 1)

        XCTAssertTrue(h.recorder.sent.isEmpty)
        try assertChoice(h, 0, options: [0], other: false)
        XCTAssertEqual(h.recorder.reports, [
            ApprovalRecorder.Report(requestID: "req-1", control: "answer_questions", channel: .accessibility),
            ApprovalRecorder.Report(requestID: "req-1", control: "answer_option", channel: .accessibility),
        ])
        XCTAssertEqual(h.store.entry(id: "req-1")?.state, ApprovalAnswerState.pending)
    }

    func testAnAccessibilityPressWithVoiceOverOnChoosesAndSubmits() throws {
        let box = QuestionPermitBox()
        box.permit = { control in HumanGesture.permit(nil, control: control, voiceOverEnabled: { true }, allowsSynthetic: { false }) }
        let h = try harness(box: box)

        try choose(h, 0, 1)
        try choose(h, 1, 2)
        press(try submitButton(h))

        XCTAssertEqual(h.recorder.sent.first?.decision.answers, [
            ApprovalQuestionAnswer(question: "Which database should we use?", selected: ["SQLite"], other: nil),
            ApprovalQuestionAnswer(question: "Which features do you want to enable?", selected: ["Tracing"], other: nil),
        ])
        XCTAssertTrue(h.recorder.reports.isEmpty)
    }

    func testAMarkedEventIsRefusedForAnOptionAndForSubmitAndAFreshHumanEventStillAnswersAfterwards() throws {
        let window = GestureFixtures.offscreenWindow(size: NSSize(width: 700, height: 700))
        addTeardownBlock { window.close() }
        final class EventBox { var event: NSEvent? }
        let events = EventBox()
        let box = QuestionPermitBox()
        box.permit = { control in
            HumanGesture.permit(events.event, control: control, voiceOverEnabled: { false }, allowsSynthetic: { false })
        }
        let h = try harness(box: box, window: window)

        events.event = GestureFixtures.mouse(.leftMouseUp, in: window)
        try fillFixture(h)
        XCTAssertTrue(h.recorder.reports.isEmpty, "precondition: a person's clicks are accepted")

        events.event = try GestureFixtures.marked(GestureFixtures.key(.keyDown, in: window))
        try choose(h, 0, 1)
        press(try submitButton(h))
        XCTAssertTrue(h.recorder.sent.isEmpty, "a marked (app-control) event must not answer")
        try assertChoice(h, 0, options: [0], other: false)
        XCTAssertEqual(h.recorder.reports.map(\.control), ["answer_option", "answer_questions"])
        XCTAssertTrue(h.recorder.reports.allSatisfy { $0.channel == .appControl })

        events.event = GestureFixtures.mouse(.leftMouseUp, in: window)
        press(try submitButton(h))
        XCTAssertEqual(h.recorder.sent.map(\.decision.kind), [.answerQuestions])
        XCTAssertEqual(h.recorder.reports.count, 2)
    }

    func testAStaleEventDoesNotChooseOrSubmitAndIsReported() throws {
        let window = GestureFixtures.offscreenWindow(size: NSSize(width: 700, height: 700))
        addTeardownBlock { window.close() }
        let stale = GestureFixtures.mouse(.leftMouseUp, in: window, timestamp: ProcessInfo.processInfo.systemUptime - 5)
        let box = QuestionPermitBox()
        let h = try harness(box: box, window: window)
        try fillFixture(h)
        box.permit = { control in HumanGesture.permit(stale, control: control, voiceOverEnabled: { false }, allowsSynthetic: { false }) }

        try choose(h, 0, 1)
        press(try submitButton(h))

        XCTAssertTrue(h.recorder.sent.isEmpty, "a left-over click is not the gesture behind this press")
        try assertChoice(h, 0, options: [0], other: false)
        XCTAssertEqual(h.recorder.reports.map(\.control), ["answer_option", "answer_questions"])
    }

    func testDenyOnAQuestionCardGoesThroughTheSameGestureCheck() throws {
        let h = try harness(box: {
            let box = QuestionPermitBox()
            box.permit = { _ in .refused(reason: .appControl) }
            return box
        }())
        press(h.card.denyButton)
        XCTAssertTrue(h.recorder.sent.isEmpty)
        XCTAssertEqual(h.recorder.reports, [ApprovalRecorder.Report(requestID: "req-1", control: "deny", channel: .appControl)])
    }

    // MARK: No key answers, and arrival never takes focus

    private func sendReturnAndSpace(to window: NSWindow) {
        let keys: [(characters: String, code: UInt16)] = [("\r", 36), (" ", 49)]
        for key in keys {
            let down = GestureFixtures.key(.keyDown, in: window, characters: key.characters, keyCode: key.code)
            _ = window.performKeyEquivalent(with: down)
            window.sendEvent(down)
            window.sendEvent(GestureFixtures.key(.keyUp, in: window, characters: key.characters, keyCode: key.code))
        }
    }

    func testNoControlInTheCardOrItsFormHasAKeyEquivalentAndTheWindowHasNoDefaultButton() throws {
        let h = try harness()
        let buttons = ApprovalTestViews.buttons(in: h.card)
        XCTAssertGreaterThanOrEqual(buttons.count, 2 + 3 + 2 + 3, "the options, both Other toggles, Deny, Submit and Details")
        for button in buttons {
            XCTAssertEqual(button.keyEquivalent, "", "`\(button.identifier?.rawValue ?? button.title)` must not answer to any key")
        }
        try fillFixture(h)
        for button in ApprovalTestViews.buttons(in: h.card) { XCTAssertEqual(button.keyEquivalent, "", button.identifier?.rawValue ?? button.title) }
        XCTAssertNil(h.window.defaultButtonCell, "no button is the window's default")
    }

    func testSubmitCannotBeMadeTheDefaultByGivingItAKeyEquivalent() throws {
        let h = try harness()
        try fillFixture(h)
        for button in [h.card.submitButton, h.card.denyButton, h.card.detailsButton] {
            button?.keyEquivalent = "\r"
            XCTAssertEqual(button?.keyEquivalent, "")
        }
        h.window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertNil(h.window.defaultButtonCell)
    }

    func testReturnAndSpaceWithNothingFocusedAnswerNothingChooseNothingAndMoveNoFocus() throws {
        let h = try harness()
        _ = h.window.makeFirstResponder(nil)
        let responder = h.window.firstResponder

        sendReturnAndSpace(to: h.window)

        XCTAssertTrue(h.recorder.sent.isEmpty)
        XCTAssertTrue(h.recorder.reports.isEmpty)
        XCTAssertEqual(h.store.entry(id: "req-1")?.state, ApprovalAnswerState.pending)
        try assertChoice(h, 0, options: [], other: false)
        try assertChoice(h, 1, options: [], other: false)
        XCTAssertTrue(h.window.firstResponder === responder, "and nothing moves focus")
    }

    func testReturnAndSpaceWithACompleteFormAndNothingFocusedDoNotSubmit() throws {
        let h = try harness()
        try fillFixture(h)
        XCTAssertTrue(try submitButton(h).isEnabled, "precondition")
        _ = h.window.makeFirstResponder(nil)

        sendReturnAndSpace(to: h.window)

        XCTAssertTrue(h.recorder.sent.isEmpty, "Submit is a button to press, never a default")
        XCTAssertEqual(h.store.entry(id: "req-1")?.state, ApprovalAnswerState.pending)
    }

    func testReturnInTheOtherFieldDoesNotSubmit() throws {
        let h = try harness()
        try fillFixture(h)
        let field = try XCTUnwrap(try form(h).otherField(question: 0))
        _ = h.window.makeFirstResponder(field)

        let down = GestureFixtures.key(.keyDown, in: h.window, characters: "\r", keyCode: 36)
        _ = h.window.performKeyEquivalent(with: down)
        h.window.sendEvent(down)
        h.window.sendEvent(GestureFixtures.key(.keyUp, in: h.window, characters: "\r", keyCode: 36))
        _ = field.sendAction(field.action, to: field.target)

        XCTAssertTrue(h.recorder.sent.isEmpty, "a draft is finished with Submit, not Return")
        XCTAssertEqual(h.store.entry(id: "req-1")?.state, ApprovalAnswerState.pending)
    }

    func testArrivalLayoutTicksUpdatesChoosingAndAnAnswerNeverMoveFocusOrTouchTheComposer() throws {
        var composer: NSTextView!
        let h = try harness(prepare: { window in
            composer = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
            window.contentView!.addSubview(composer)
            composer.string = "half a thought"
            _ = window.makeFirstResponder(composer)
            composer.setSelectedRange(NSRange(location: 2, length: 4))
        })
        XCTAssertTrue(h.window.firstResponder === composer, "adding the card to the window leaves the composer focused")

        h.relayout()
        for _ in 0 ..< 3 { h.card.countdown.tick() }
        h.card.setMoreCount(2)
        press(h.card.detailsButton)
        try fillFixture(h)
        press(try submitButton(h))
        h.sync()
        h.store.handle(.resolved(try ApprovalTestRequests.resolved(id: "req-1", outcome: "answered")))
        h.sync()

        XCTAssertTrue(h.window.firstResponder === composer, "nothing the card does on its own takes focus")
        XCTAssertEqual(composer.string, "half a thought")
        XCTAssertEqual(composer.selectedRange(), NSRange(location: 2, length: 4))
    }

    func testChoosingAnOptionDoesNotMoveKeyboardFocus() throws {
        var composer: NSTextView!
        let h = try harness(prepare: { window in
            composer = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
            window.contentView!.addSubview(composer)
            _ = window.makeFirstResponder(composer)
        })
        try choose(h, 0, 0)
        try choose(h, 1, 1)
        XCTAssertTrue(h.window.firstResponder === composer, "a click on a radio button or a checkbox is not a request for focus")
    }

    // MARK: Height stability

    func testTheCardsHeightAndRowsDoNotChangeWhenAnOptionIsChosenOrTextIsTypedOrACountdownTicks() throws {
        let h = try harness()
        let preferred = h.card.preferredHeight(forWidth: 560, maxHeight: 520)
        let rows = h.rowGeometry

        try fillFixture(h)
        try typeText("Logging", intoOtherOf: 1, h)
        for _ in 0 ..< 3 { h.card.countdown.tick() }
        h.card.setMoreCount(2)
        h.relayout()

        XCTAssertEqual(h.card.preferredHeight(forWidth: 560, maxHeight: 520), preferred)
        XCTAssertEqual(h.rowGeometry, rows)
    }

    func testTheCardsHeightAndRowsDoNotChangeWhenTheRequestMovesFromPendingToInFlightToEnded() throws {
        let h = try harness()
        try fillFixture(h)
        let preferred = h.card.preferredHeight(forWidth: 560, maxHeight: 520)
        let rows = h.rowGeometry

        press(try submitButton(h))
        h.sync()
        h.relayout()
        XCTAssertEqual(h.card.preferredHeight(forWidth: 560, maxHeight: 520), preferred, "pending to in flight")
        XCTAssertEqual(h.rowGeometry, rows, "pending to in flight")

        h.store.handle(.resolved(try ApprovalTestRequests.resolved(id: "req-1", outcome: "answered", byWindow: "w-test")))
        h.sync()
        h.relayout()
        XCTAssertEqual(h.card.preferredHeight(forWidth: 560, maxHeight: 520), preferred, "in flight to ended")
        XCTAssertEqual(h.rowGeometry, rows, "in flight to ended")
        XCTAssertEqual(h.card.listing.state, "Answered")
    }

    func testTheCardsHeightAndRowsDoNotChangeWhenTheDaemonRefusesTheAnswers() throws {
        let h = try harness()
        try fillFixture(h)
        let preferred = h.card.preferredHeight(forWidth: 560, maxHeight: 520)
        let rows = h.rowGeometry
        press(try submitButton(h))
        h.sync()

        try refuse(h, code: "invalid_answer")
        h.relayout()

        XCTAssertEqual(h.card.preferredHeight(forWidth: 560, maxHeight: 520), preferred)
        XCTAssertEqual(h.rowGeometry, rows)
    }

    func testTheCardsHeightAndRowsDoNotChangeWhenAnOutcomeArrivesWithoutAnyAnswer() throws {
        let h = try harness()
        let preferred = h.card.preferredHeight(forWidth: 560, maxHeight: 520)
        let rows = h.rowGeometry
        h.store.handle(.resolved(try ApprovalTestRequests.resolved(id: "req-1", outcome: "timed_out")))
        h.sync()
        h.relayout()
        XCTAssertEqual(h.card.preferredHeight(forWidth: 560, maxHeight: 520), preferred)
        XCTAssertEqual(h.rowGeometry, rows)
    }

    // MARK: What the listing reports

    func testTheListingHasTheQuestionsWithTheirOptionsAndWhatIsChosen() throws {
        let h = try harness()
        let before = try XCTUnwrap(h.card.listing.jsonObject["questions"] as? [[String: Any]])
        XCTAssertEqual(before.count, 2)
        for q in before {
            XCTAssertEqual(Set(q.keys), ["question", "header", "multi_select", "options", "other_text", "other_selected"])
        }
        XCTAssertEqual(before[0]["question"] as? String, "Which database should we use?")
        XCTAssertEqual(before[0]["header"] as? String, "Database")
        XCTAssertEqual(before[0]["multi_select"] as? Bool, false)
        XCTAssertEqual(before[1]["multi_select"] as? Bool, true)
        XCTAssertEqual(before[0]["other_text"] as? String, "")
        XCTAssertEqual(before[0]["other_selected"] as? Bool, false)
        let options0 = try XCTUnwrap(before[0]["options"] as? [[String: Any]])
        XCTAssertEqual(options0.map { $0["label"] as? String }, ["Postgres", "SQLite"])
        XCTAssertEqual(options0.map { $0["description"] as? String }, ["Relational, strong consistency", "Embedded, zero setup"])
        XCTAssertEqual(options0.map { $0["selected"] as? Bool }, [false, false])
        for option in options0 { XCTAssertEqual(Set(option.keys), ["label", "description", "selected"]) }

        try choose(h, 0, 1)
        try choose(h, 1, 0)
        try choose(h, 1, 2)
        try typeText("Logging", intoOtherOf: 1, h)

        let after = try XCTUnwrap(h.card.listing.jsonObject["questions"] as? [[String: Any]])
        XCTAssertEqual((try XCTUnwrap(after[0]["options"] as? [[String: Any]])).map { $0["selected"] as? Bool }, [false, true])
        XCTAssertEqual((try XCTUnwrap(after[1]["options"] as? [[String: Any]])).map { $0["selected"] as? Bool }, [true, false, true])
        XCTAssertEqual(after[1]["other_text"] as? String, "Logging")
        XCTAssertEqual(after[1]["other_selected"] as? Bool, true)
        XCTAssertEqual(after[0]["other_selected"] as? Bool, false)
    }

    func testTheListingsOptionsOfAQuestionCardAreDenyAndSubmitInsteadOfAllowOnce() throws {
        let h = try harness()
        XCTAssertEqual(h.card.listing.options.map(\.id), ["deny", "answer_questions"])
        XCTAssertFalse(h.card.listing.options.map(\.id).contains("allow_once"))
        try fillFixture(h)
        XCTAssertEqual(h.card.listing.options, [
            ApprovalCardListing.Option(id: "deny", enabled: true, label: "Deny"),
            ApprovalCardListing.Option(id: "answer_questions", enabled: true, label: "Submit"),
        ])
        let json = try XCTUnwrap(h.card.listing.jsonObject["options"] as? [[String: Any]])
        XCTAssertEqual(json.map { $0["id"] as? String }, ["deny", "answer_questions"])
        XCTAssertEqual(json.map { $0["label"] as? String }, ["Deny", "Submit"])
        XCTAssertEqual(json.map { $0["enabled"] as? Bool }, [true, true])
    }

    func testTheListingsQuestionsAreNullForOtherCardsAndTheListingIsSerialisable() throws {
        for request in [try ApprovalTestRequests.simpleRm(), try ApprovalTestRequests.requiresUserInteraction(),
                        try ApprovalTestRequests.edit()] {
            let h = ApprovalCardHarness(self, request: request)
            let json = h.card.listing.jsonObject
            XCTAssertTrue(json["questions"] is NSNull, "\(request.toolName): `questions` is null, not missing")
            XCTAssertTrue(JSONSerialization.isValidJSONObject(json))
        }
        let q = try harness()
        XCTAssertTrue(JSONSerialization.isValidJSONObject(q.card.listing.jsonObject))
        try fillFixture(q)
        try typeText("Oracle", intoOtherOf: 0, q)
        let data = try JSONSerialization.data(withJSONObject: q.card.listing.jsonObject)
        let back = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(back["request_id"] as? String, "req-1")
        XCTAssertEqual((back["questions"] as? [[String: Any]])?.count, 2)
    }

    func testTheOverlayHostsListingMatchesTheQuestionCardOnScreen() throws {
        let rig = HostRig(self)
        rig.arrive(try Q.ask())
        let card = try XCTUnwrap(rig.host.card)
        XCTAssertEqual(rig.host.listings, [card.listing])
        XCTAssertNotNil(rig.host.listings.first?.jsonObject["questions"] as? [[String: Any]])
    }

    // MARK: Accessibility

    func testTheQuestionCardIsAnAccessibilityGroupAndEveryButtonIsNamed() throws {
        let h = try harness()
        XCTAssertTrue(h.card.isAccessibilityElement())
        XCTAssertEqual(h.card.accessibilityRole(), NSAccessibility.Role.group)
        for button in ApprovalTestViews.buttons(in: h.card) {
            XCTAssertFalse((button.accessibilityLabel() ?? button.title).isEmpty, "`\(button.identifier?.rawValue ?? "?")` has no name for VoiceOver")
        }
        XCTAssertTrue(h.card.submitButton?.accessibilityLabel()?.localizedCaseInsensitiveContains("submit") == true)
    }
}

// MARK: - Long text

/// Everything the agent supplies in a question is data: a question, an option label or description, or a header
/// can be thousands of characters, with or without a place to wrap. None of it may widen the card, push a row out of
/// it, make the card taller than the pane lets it be, or (in a window that cannot grow) make the window's content
/// wider than the window.
final class ApprovalQuestionLayoutTests: XCTestCase {

    typealias Q = QuestionTestRequests

    private enum Field: String, CaseIterable {
        case question, optionLabel, optionDescription, header
    }

    private static let noSpaces = String(repeating: "x", count: 5000)
    private static var withSpaces: String { String(String(repeating: "word ", count: 1000).prefix(5000)) }
    private static let short = "short text"

    /// One single-select question whose `fields` hold `text` (the others are short), then a short multi-select one.
    private func questions(_ fields: Set<Field>, _ text: String) -> [Q.Obj] {
        func pick(_ f: Field, _ normal: String) -> String { fields.contains(f) ? text : normal }
        return [
            Q.question(pick(.question, "Which one?"), header: pick(.header, "Header"), options: [
                Q.option(pick(.optionLabel, "First"), pick(.optionDescription, "First description")),
                Q.option("Second", "Second description"),
            ]),
            Q.question("And which others?", header: "More", multi: true, options: [
                Q.option("Alpha", "The first"), Q.option("Beta", "The second"), Q.option("Gamma", "The third"),
            ]),
        ]
    }

    private var cases: [(name: String, fields: Set<Field>, text: String)] {
        var out: [(name: String, fields: Set<Field>, text: String)] = []
        for (kind, text) in [("without spaces", Self.noSpaces), ("with spaces", Self.withSpaces)] {
            for field in Field.allCases {
                out.append((name: "\(field.rawValue), 5000 chars \(kind)", fields: [field], text: text))
            }
            out.append((name: "every field, 5000 chars \(kind)", fields: Set(Field.allCases), text: text))
        }
        return out
    }

    // MARK: Measuring

    /// Views of the card that are visible and stick out of it horizontally.
    private func escapes(_ card: ApprovalCardView) -> [String] {
        var out: [String] = []
        for v in rigAllSubviews(of: card) where !v.isHiddenOrHasHiddenAncestor {
            // The raw input (behind Details) is AP2a's view, with its own rules; its frame is checked, not its insides.
            if v !== card.inputView && v.isDescendant(of: card.inputView) { continue }
            let r = card.convert(v.bounds, from: v)
            if r.minX < -1 || r.maxX > card.bounds.width + 1 {
                out.append("\(type(of: v)) \(v.identifier?.rawValue ?? "") x \(Int(r.minX)) to \(Int(r.maxX)) in a \(Int(card.bounds.width)) wide card")
            }
        }
        return out
    }

    /// Containers whose own demanded width is more than `width`. (A leaf text field's intrinsic width is its text on one
    /// line; it only matters if something is built from it, which is what the containers' sizes and the window test show.)
    private func demandingContainers(in root: NSView, over width: CGFloat) -> [String] {
        var out: [String] = []
        for v in [root] + rigAllSubviews(of: root) {
            let isLeafText = v is NSTextField || v is NSTextView
            let isScrollInternals = v is NSClipView || v is NSScroller
            let isScroll = v is NSScrollView
            guard !isLeafText, !isScrollInternals, !isScroll, !v.isHiddenOrHasHiddenAncestor else { continue }
            if let card = root as? ApprovalCardView, v.isDescendant(of: card.inputView) { continue }
            if v.fittingSize.width > width + 1 { out.append("\(type(of: v)) demands \(Int(v.fittingSize.width)) in \(Int(width))") }
        }
        return out
    }

    private func assertContained(_ h: ApprovalCardHarness, _ name: String, maxHeight: CGFloat,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let form = try XCTUnwrap(h.card.questionForm, "\(name): no form", file: file, line: line)
        XCTAssertEqual(h.card.frame.width, 560, accuracy: 0.5, "\(name): the card keeps the width it was given", file: file, line: line)
        XCTAssertLessThanOrEqual(h.card.frame.height, maxHeight + 0.5, "\(name): the card is taller than the maximum", file: file, line: line)
        XCTAssertTrue(h.card.frame.height.isFinite && h.card.frame.height > 0, "\(name)", file: file, line: line)
        XCTAssertEqual(escapes(h.card), [], "\(name): views outside the card", file: file, line: line)
        XCTAssertEqual(demandingContainers(in: h.card, over: h.card.frame.width), [], "\(name): the card is forced wider", file: file, line: line)
        XCTAssertLessThanOrEqual(form.frame.width, h.card.frame.width + 1, "\(name): the form is wider than the card", file: file, line: line)
        XCTAssertLessThanOrEqual(form.fittingSize.width, h.card.frame.width + 1, "\(name): the form demands more than the card", file: file, line: line)
        XCTAssertLessThanOrEqual(h.card.fittingSize.width, h.card.frame.width + 1, "\(name): the card demands more than its frame", file: file, line: line)
    }

    // MARK: The form

    func testTheContentHeightOfLongTextIsFiniteAndTheLaidOutFormHasNothingWiderOrLowerThanIt() throws {
        var all = cases
        all.append((name: "short control", fields: [], text: Self.short))
        for item in all {
            let parsed = try Q.parsed(questions(item.fields, item.text))
            let window = makeRigWindow(self, size: NSSize(width: 800, height: 600))
            let form = ApprovalQuestionFormView(questions: parsed)
            for width: CGFloat in [520, 320] {
                let height = form.contentHeight(forWidth: width)
                XCTAssertTrue(height.isFinite, "\(item.name) at \(width)")
                XCTAssertGreaterThan(height, 40, "\(item.name) at \(width)")
                XCTAssertLessThan(height, 200_000, "\(item.name) at \(width): 5000 characters wrap to a few thousand points at most")

                form.frame = NSRect(x: 10, y: 10, width: width, height: height)
                if form.superview == nil { window.contentView!.addSubview(form) }
                form.needsLayout = true
                form.layoutSubtreeIfNeeded()

                var lowest: CGFloat = 0
                for v in rigAllSubviews(of: form) where !v.isHiddenOrHasHiddenAncestor {
                    let r = form.convert(v.bounds, from: v)
                    lowest = max(lowest, r.maxY)
                    XCTAssertGreaterThanOrEqual(r.minX, -0.5, "\(item.name) at \(width): \(type(of: v)) starts left of the form")
                    XCTAssertLessThanOrEqual(r.maxX, width + 0.5, "\(item.name) at \(width): \(type(of: v)) is wider than the form (\(r.maxX))")
                }
                XCTAssertLessThanOrEqual(lowest, height + 0.5, "\(item.name) at \(width): content below the height it reported")
                XCTAssertGreaterThanOrEqual(height, lowest - 0.5)
                XCTAssertLessThanOrEqual(height, lowest + 40, "\(item.name) at \(width): contentHeight is not exact: \(height) for content ending at \(lowest)")
            }
        }
    }

    func testNarrowerWidthsNeverNeedLessHeight() throws {
        for text in [Self.noSpaces, Self.withSpaces] {
            let form = ApprovalQuestionFormView(questions: try Q.parsed(questions([.question, .optionLabel, .optionDescription], text)))
            let heights = [800, 600, 400, 300, 200].map { form.contentHeight(forWidth: CGFloat($0)) }
            XCTAssertEqual(heights, heights.sorted(), "text wraps: \(heights)")
            XCTAssertGreaterThan(heights.last!, heights.first!)
        }
    }

    func testTheQuestionOptionAndDescriptionTextWrapsWithNoLineLimitAndIsNeverCut() throws {
        for text in [Self.noSpaces, Self.withSpaces] {
            let parsed = try Q.parsed(questions([.question, .optionLabel, .optionDescription], text))
            let window = makeRigWindow(self, size: NSSize(width: 700, height: 600))
            let form = ApprovalQuestionFormView(questions: parsed)
            form.frame = NSRect(x: 10, y: 10, width: 500, height: form.contentHeight(forWidth: 500))
            window.contentView!.addSubview(form)
            form.layoutSubtreeIfNeeded()

            let labels: [(String, NSTextField)] = [("question", form.questionLabel(0)),
                                                   ("option label", form.optionLabel(question: 0, option: 0)),
                                                   ("description", form.descriptionLabel(question: 0, option: 0))]
            for (name, label) in labels {
                XCTAssertEqual(label.maximumNumberOfLines, 0, "\(name): no line limit")
                XCTAssertFalse([NSLineBreakMode.byTruncatingTail, .byTruncatingHead, .byTruncatingMiddle, .byClipping].contains(label.lineBreakMode),
                               "\(name): wraps instead of cutting (\(label.lineBreakMode.rawValue))")
                XCTAssertEqual(label.stringValue, text, "\(name): every character is there")
                XCTAssertGreaterThan(label.frame.height, 4 * (label.font?.pointSize ?? 12), "\(name): the label is as tall as its wrapped text (\(label.frame.height))")
                XCTAssertLessThanOrEqual(form.convert(label.bounds, from: label).maxX, 500.5, "\(name): wider than the form")
            }
        }
    }

    // MARK: The card

    func testNoLongTextWidensTheCardOrSpillsOutOfItAndTheCardNeverExceedsItsMaximumHeight() throws {
        for item in cases {
            let h = ApprovalCardHarness(self, request: try Q.ask(questions(item.fields, item.text)), maxHeight: 520)
            try assertContained(h, item.name, maxHeight: 520)
        }
    }

    func testTheControlWithShortTextFitsToo() throws {
        let h = ApprovalCardHarness(self, request: try Q.ask(questions([], Self.short)), maxHeight: 520)
        try assertContained(h, "short text", maxHeight: 520)
        XCTAssertGreaterThan(try XCTUnwrap(h.card.questionForm).frame.width, 100, "control: the form is actually laid out in the card")
    }

    func testTheCardNeverExceedsAShorterMaximumHeightEitherAndKeepsDenyAndSubmitInsideIt() throws {
        for maxHeight: CGFloat in [300, 400] {
            let h = ApprovalCardHarness(self, request: try Q.ask(questions(Set(Field.allCases), Self.withSpaces)), maxHeight: maxHeight)
            try assertContained(h, "every field at max \(maxHeight)", maxHeight: maxHeight)
            let buttons: [ApprovalButton] = [h.card.denyButton, try XCTUnwrap(h.card.submitButton)]
            for button in buttons {
                let r = h.card.convert(button.bounds, from: button)
                XCTAssertGreaterThanOrEqual(r.minY, 0, "\(button.title) is inside the card")
                XCTAssertLessThanOrEqual(r.maxY, h.card.bounds.height + 0.5, "\(button.title) is pushed out of the card")
            }
        }
    }

    func testFourQuestionsOfFourOptionsFitTheMaximumHeightToo() throws {
        let many = (1 ... 4).map { q in
            Q.question("Question \(q)?", header: "Q\(q)", multi: q % 2 == 0,
                       options: (1 ... 4).map { Q.option("Option \(q).\($0)", "A description of option \(q).\($0), a little longer than a few words") })
        }
        let h = ApprovalCardHarness(self, request: try Q.ask(many), maxHeight: 520)
        try assertContained(h, "4 x 4", maxHeight: 520)
    }

    func testTheExpandedDetailsStillKeepTheCardWithinItsMaximumHeightAndItsWidth() throws {
        let h = ApprovalCardHarness(self, request: try Q.ask(questions(Set(Field.allCases), Self.noSpaces)), maxHeight: 520)
        h.card.detailsButton?.performClick(nil)
        h.card.layoutSubtreeIfNeeded()
        let height = h.card.preferredHeight(forWidth: 560, maxHeight: 520)
        XCTAssertLessThanOrEqual(height, 520.5)
        XCTAssertEqual(h.card.frame.width, 560, accuracy: 0.5)
        XCTAssertLessThanOrEqual(h.card.fittingSize.width, 560 + 1)
    }

    func testTheCardKeepsItsRoomInANarrowPaneToo() throws {
        let h = ApprovalCardHarness(self, request: try Q.ask(questions(Set(Field.allCases), Self.noSpaces)), width: 320, maxHeight: 420)
        let form = try XCTUnwrap(h.card.questionForm)
        XCTAssertLessThanOrEqual(h.card.frame.height, 420.5)
        XCTAssertEqual(escapes(h.card), [])
        XCTAssertLessThanOrEqual(form.frame.width, 321)
        XCTAssertTrue(form.contentHeight(forWidth: 300).isFinite)
    }

    // MARK: A real window that cannot grow

    private final class FixedWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private static let windowSize = NSSize(width: 1920, height: 1080)
    private let tag = "perri"

    private struct Rig {
        let window: NSWindow
        let layout: MainLayout
    }

    private func settle(_ rig: Rig) {
        for _ in 0 ..< 4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            rig.window.contentView?.layoutSubtreeIfNeeded()
            rig.window.displayIfNeeded()
        }
    }

    /// The real REPL focus in a fixed 1920 x 1080 window, the way `WindowOverflowReproTests` builds it.
    private func makeRig(index: Int) -> Rig {
        let displayUUID = "ap2c-\(UUID().uuidString)"
        let focus = Focus.builtIns.first { $0.id == tag }!
        UserDefaults.standard.set(tag, forKey: DisplayFocusKeys.activeTabKey(displayUUID: displayUUID))
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: DisplayFocusKeys.activeTabKey(displayUUID: displayUUID)) }

        let store = AppStore.shared
        let tree: PaneTree = .split(direction: .horizontal, children: [.leaf(paneId: "repl"), .leaf(paneId: "plans")], ratios: [0.5, 0.5])
        store.applyForTesting(.focusLayout(tag: focus.sessionTag, tree: tree, focusedPane: nil))
        store.applyForTesting(.paneContent(tag: focus.sessionTag, paneId: "plans",
                                           content: .text(Array(repeating: "a line of text in the plans pane", count: 40).joined(separator: "\n")),
                                           freshness: nil, address: nil))

        let size = Self.windowSize
        let window = FixedWindow(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size),
                                 styleMask: [.titled, .resizable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let layout = MainLayout(windowIndex: index, displayUUID: displayUUID)
        layout.overflowCaptureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ap2c-captures-\(UUID().uuidString)", isDirectory: true)
        window.contentView = layout
        window.setContentSize(size)
        window.alphaValue = 0
        window.orderFront(nil)
        addTeardownBlock { window.orderOut(nil); window.contentView = nil }
        let rig = Rig(window: window, layout: layout)
        settle(rig)
        return rig
    }

    private func overlayHost(in rig: Rig) -> ApprovalOverlayHost? {
        rigAllSubviews(of: rig.layout).compactMap { $0 as? ApprovalOverlayHost }.first { $0.focusTag == tag }
    }

    /// A question request arrives for the REPL's focus; returns the card it shows.
    private func arrive(_ questions: [Q.Obj], in rig: Rig) throws -> ApprovalCardView {
        // Nothing left over from another test: what is still waiting is dropped, and an outcome still on its way
        // out (the store's real 2 s timer) is waited for, because a card shows the oldest request of its focus.
        ApprovalStore.shared.handle(.snapshot([]))
        let deadline = Date().addingTimeInterval(3)
        while ApprovalStore.shared.current(tag: tag) != nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertNil(ApprovalStore.shared.current(tag: tag), "precondition: the focus has no request of its own yet")
        let id = "ap2c-\(UUID().uuidString)"
        addTeardownBlock { ApprovalStore.shared.handle(.snapshot([])) }
        ApprovalStore.shared.handle(.request(try Q.ask(questions, id: id, tag: tag)))
        settle(rig)
        let host = try XCTUnwrap(overlayHost(in: rig), "the REPL has no approval overlay")
        let card = try XCTUnwrap(host.card, "no card for the question request")
        XCTAssertEqual(card.request.id, id, "the card shows this test's request")
        return card
    }

    private func assertFits(_ rig: Rig, _ card: ApprovalCardView, _ label: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let content = rig.window.contentRect(forFrameRect: rig.window.frame).size
        let host = try XCTUnwrap(overlayHost(in: rig), file: file, line: line)
        XCTAssertNotNil(card.questionForm, "\(label): the card has no form", file: file, line: line)
        XCTAssertEqual(rig.layout.frame.width, content.width, accuracy: 1, "\(label): MainLayout is \(rig.layout.frame.width) wide in a \(content.width) window", file: file, line: line)
        XCTAssertEqual(rig.layout.frame.height, content.height, accuracy: 1, "\(label): MainLayout is \(rig.layout.frame.height) tall in a \(content.height) window", file: file, line: line)
        XCTAssertLessThanOrEqual(rig.layout.fittingSize.width, content.width + 1, "\(label): the layout demands \(rig.layout.fittingSize.width)", file: file, line: line)
        XCTAssertLessThanOrEqual(rig.layout.fittingSize.height, content.height + 1, "\(label): the layout demands \(rig.layout.fittingSize.height) tall", file: file, line: line)
        XCTAssertEqual(rig.layout.contentOverflow, .zero, "\(label): MainLayout overflows its window", file: file, line: line)
        XCTAssertEqual(rig.window.frame.size, rig.window.frameRect(forContentRect: NSRect(origin: .zero, size: Self.windowSize)).size,
                       "\(label): the window changed size", file: file, line: line)
        XCTAssertLessThanOrEqual(card.frame.maxX, host.bounds.width + 1, "\(label): the card sticks out of the pane", file: file, line: line)
        XCTAssertLessThanOrEqual(card.frame.height, host.bounds.height * ApprovalOverlayHost.maxHeightFraction + 1, "\(label): the card is taller than its share of the pane", file: file, line: line)
        XCTAssertLessThanOrEqual(card.fittingSize.width, card.frame.width + 1, "\(label): the card demands more than its frame", file: file, line: line)
        XCTAssertLessThanOrEqual(try XCTUnwrap(card.questionForm).fittingSize.width, card.frame.width + 1, "\(label): the form demands more than the card", file: file, line: line)
        XCTAssertEqual(escapes(card), [], "\(label): views outside the card", file: file, line: line)
    }

    func testAQuestionWithShortTextFitsTheFixedWindow() throws {
        let rig = makeRig(index: 780)
        let card = try arrive(questions([], Self.short), in: rig)
        try assertFits(rig, card, "short text")
        XCTAssertGreaterThan(card.frame.width, 300, "control: the card is actually laid out in the pane")
    }

    func testA5000CharacterUnbrokenStringInAnyFieldDoesNotWidenTheCardOrTheWindowContent() throws {
        var index = 790
        for field in Field.allCases {
            let rig = makeRig(index: index)
            index += 1
            let card = try arrive(questions([field], Self.noSpaces), in: rig)
            try assertFits(rig, card, "\(field.rawValue), 5000 chars without spaces")
        }
    }

    func testA5000CharacterSentenceInAnyFieldDoesNotWidenTheCardOrTheWindowContent() throws {
        var index = 800
        for field in Field.allCases {
            let rig = makeRig(index: index)
            index += 1
            let card = try arrive(questions([field], Self.withSpaces), in: rig)
            try assertFits(rig, card, "\(field.rawValue), 5000 chars with spaces")
        }
    }

    func testEveryFieldAtOnceFitsWithAndWithoutSpacesAndAfterTheAnswerAndTheDetails() throws {
        for (n, text) in [("no spaces", Self.noSpaces), ("spaces", Self.withSpaces)].enumerated() {
            let rig = makeRig(index: 810 + n)
            let card = try arrive(questions(Set(Field.allCases), text.1), in: rig)
            try assertFits(rig, card, "all fields, 5000 chars, \(text.0)")

            card.detailsButton?.performClick(nil)
            settle(rig)
            try assertFits(rig, card, "all fields, 5000 chars, \(text.0), Details open")

            card.detailsButton?.performClick(nil)
            settle(rig)
            try assertFits(rig, card, "all fields, 5000 chars, \(text.0), Details toggled again")
        }
    }
}

// MARK: - The store

final class ApprovalQuestionStoreTests: XCTestCase {

    private func make() -> (ApprovalStore, ApprovalRecorder) {
        let recorder = ApprovalRecorder()
        return (recorder.makeStore(), recorder)
    }

    private let answer = ApprovalDecisionWire(kind: .answerQuestions, answers: [
        ApprovalQuestionAnswer(question: "Which database should we use?", selected: ["SQLite"], other: nil),
        ApprovalQuestionAnswer(question: "Which features do you want to enable?", selected: ["Caching"], other: "Logging"),
    ])
    private let deny = ApprovalDecisionWire(kind: .deny)

    private func request(_ id: String = "a") throws -> ApprovalRequestWire {
        try QuestionTestRequests.ask(id: id)
    }

    private func refuse(_ store: ApprovalStore, code: String, id: String = "a") throws {
        store.handle(.answerRefused(try ApprovalTestRequests.refused(id: id, code: code)))
    }

    func testTheOutcomeTextForAnAnsweredRequestIsAnswered() {
        XCTAssertEqual(ApprovalStore.outcomeText("answered"), "Answered")
    }

    func testTheExistingOutcomeTextsAreUnchanged() {
        XCTAssertEqual(ApprovalStore.outcomeText("allowed_once"), "Allowed once")
        XCTAssertEqual(ApprovalStore.outcomeText("denied"), "Denied")
        XCTAssertEqual(ApprovalStore.outcomeText("timed_out"), "Denied: no answer in 15 min")
    }

    func testAnAnsweredRequestShowsAnsweredThenIsDroppedAfterTwoSeconds() throws {
        let (store, recorder) = make()
        store.handle(.request(try request()))
        XCTAssertTrue(store.answer("a", answer, windowID: "w1"))

        store.handle(.resolved(try ApprovalTestRequests.resolved(id: "a", outcome: "answered", byWindow: "w1")))

        XCTAssertEqual(store.entry(id: "a")?.state, ApprovalAnswerState.ended("Answered"))
        XCTAssertEqual(store.current(tag: "cody-1")?.request.id, "a", "the outcome stays where the card is")
        XCTAssertEqual(recorder.scheduled.map { $0.delay }, [2])

        recorder.runScheduled()

        XCTAssertNil(store.entry(id: "a"))
        XCTAssertNil(store.current(tag: "cody-1"))
    }

    func testAnAnswerQuestionsDecisionIsSentOnceWithItsAnswersAndTheWindow() throws {
        let (store, recorder) = make()
        store.handle(.request(try request()))

        XCTAssertTrue(store.answer("a", answer, windowID: "w1"))

        XCTAssertEqual(recorder.sent, [ApprovalRecorder.Sent(requestID: "a", decision: answer, windowID: "w1")])
        XCTAssertEqual(store.entry(id: "a")?.state, ApprovalAnswerState.inFlight(.answerQuestions))
        XCTAssertFalse(store.answer("a", answer, windowID: "w1"), "once")
        XCTAssertFalse(store.answer("a", answer, windowID: "w2"), "from any window")
        XCTAssertFalse(store.answer("a", deny, windowID: "w1"), "and not followed by a Deny while it is on its way")
        XCTAssertEqual(recorder.sent.count, 1)
    }

    func testAnAnswerAfterADenyIsRefused() throws {
        let (store, recorder) = make()
        store.handle(.request(try request()))
        XCTAssertTrue(store.answer("a", deny, windowID: "w1"))
        XCTAssertFalse(store.answer("a", answer, windowID: "w1"))
        XCTAssertEqual(recorder.sent.map(\.decision), [deny])
    }

    func testAnAnswerWithNoConnectionIsNotSentAndTheRequestStaysWaiting() throws {
        var online = false
        let recorder = ApprovalRecorder()
        let store = recorder.makeStore(canSend: { online })
        store.handle(.request(try request()))

        XCTAssertFalse(store.answer("a", answer, windowID: "w1"))
        XCTAssertTrue(recorder.sent.isEmpty)
        XCTAssertEqual(store.entry(id: "a")?.state, ApprovalAnswerState.pending)

        online = true
        XCTAssertTrue(store.answer("a", answer, windowID: "w1"))
        XCTAssertEqual(recorder.sent.count, 1)
    }

    func testAnInvalidAnswerRefusalLeavesTheRequestWaitingAsNotSentWithTheDaemonsReason() throws {
        let (store, _) = make()
        store.handle(.request(try request()))
        XCTAssertTrue(store.answer("a", answer, windowID: "w1"))

        try refuse(store, code: "invalid_answer")

        XCTAssertEqual(store.entry(id: "a")?.state, ApprovalAnswerState.notSent("Not sent: the daemon refused these answers"))
        XCTAssertEqual(store.pendingCount(tag: "cody-1"), 1, "the request is still waiting (it will time out)")
    }

    func testARefusedAnswerIsNeverSentAgainButADenyCanBe() throws {
        let (store, recorder) = make()
        store.handle(.request(try request()))
        XCTAssertTrue(store.answer("a", answer, windowID: "w1"))
        try refuse(store, code: "invalid_answer")

        XCTAssertFalse(store.answer("a", answer, windowID: "w1"), "the same answers are not re-sent")
        XCTAssertFalse(store.answer("a", ApprovalDecisionWire(kind: .answerQuestions, answers: []), windowID: "w1"), "nor any other answers")
        XCTAssertFalse(store.answer("a", ApprovalDecisionWire(kind: .allowOnce), windowID: "w1"), "nor an Allow")
        XCTAssertEqual(recorder.sent.count, 1)

        XCTAssertTrue(store.answer("a", deny, windowID: "w2"), "a Deny is accepted after a refusal")
        XCTAssertEqual(recorder.sent.map(\.decision), [answer, deny])
        XCTAssertEqual(store.entry(id: "a")?.state, ApprovalAnswerState.inFlight(.deny))
    }

    func testARefusedQuestionRequestThatTheSnapshotDropsAndListsAgainComesBackRefusedWithDenyStillPossible() throws {
        let (store, recorder) = make()
        let request = try self.request()
        store.handle(.request(request))
        XCTAssertTrue(store.answer("a", answer, windowID: "w1"))
        try refuse(store, code: "invalid_answer")
        let refused = store.entry(id: "a")?.state

        store.handle(.snapshot([]))
        XCTAssertNil(store.entry(id: "a"), "precondition: the daemon no longer held it")
        store.handle(.snapshot([request]))

        XCTAssertEqual(store.entry(id: "a")?.state, refused)
        XCTAssertFalse(store.answer("a", answer, windowID: "w1"), "the answers are still never re-sent")
        XCTAssertTrue(store.answer("a", deny, windowID: "w1"), "Deny is not stranded")
        XCTAssertEqual(recorder.sent.map(\.decision), [answer, deny])
    }

    func testALateInvalidAnswerRefusalDoesNotReopenAnEndedRequest() throws {
        let (store, _) = make()
        store.handle(.request(try request()))
        XCTAssertTrue(store.answer("a", answer, windowID: "w1"))
        store.handle(.resolved(try ApprovalTestRequests.resolved(id: "a", outcome: "answered")))

        try refuse(store, code: "invalid_answer")

        XCTAssertEqual(store.entry(id: "a")?.state, ApprovalAnswerState.ended("Answered"))
    }

    func testAnInvalidAnswerRefusalForAnUnknownRequestChangesNothing() throws {
        let (store, recorder) = make()
        store.handle(.request(try request()))
        try refuse(store, code: "invalid_answer", id: "ghost")
        XCTAssertNil(store.entry(id: "ghost"))
        XCTAssertEqual(store.entry(id: "a")?.state, ApprovalAnswerState.pending)
        XCTAssertTrue(recorder.sent.isEmpty)
    }

    func testTheOtherRefusalTextsAreUnchanged() throws {
        let cases: [(code: String, text: String)] = [
            ("not_operator_app", "Not sent: Nostromo isn't verified as the operator (run make mac-install)"),
            ("requires_secure_connection", "Not sent: this connection can't answer approvals"),
            ("something_new", "Not sent: the daemon refused the answer"),
        ]
        for (code, text) in cases {
            let (store, _) = make()
            store.handle(.request(try request()))
            XCTAssertTrue(store.answer("a", answer, windowID: "w1"), code)
            try refuse(store, code: code)
            XCTAssertEqual(store.entry(id: "a")?.state, ApprovalAnswerState.notSent(text), code)
        }
    }
}
