// NostromoKit — ApprovalQuestions.swift
//
// `AskUserQuestion` on the approval card (AP2c): the questions an agent asked,
// the state of a form that answers them, and the answers the daemon is sent.
// Pure value types; the card (macOS) only draws them.
//
// The daemon is the judge. It builds the CLI's reply from the held request's own
// questions and refuses an answer that doesn't fit (`invalid_answer`), so
// whatever this file allows, only a choice among what the agent asked, or typed
// free text, can reach the agent. `parse` mirrors the daemon's
// `approvals::questions::parse_questions`: a request this build can't answer
// shows Deny only.

import Foundation

public struct ApprovalQuestionOption: Equatable {
    public let label: String
    public let description: String

    public init(label: String, description: String) {
        self.label = label
        self.description = description
    }
}

public struct ApprovalQuestion: Equatable {
    public let question: String
    public let header: String
    public let multiSelect: Bool
    public let options: [ApprovalQuestionOption]

    public init(question: String, header: String, multiSelect: Bool, options: [ApprovalQuestionOption]) {
        self.question = question
        self.header = header
        self.multiSelect = multiSelect
        self.options = options
    }
}

public enum ApprovalQuestions {

    /// The longest free-text answer, in characters (the daemon refuses more).
    public static let maxOtherCharacters = 1000
    static let maxQuestions = 4
    static let minOptions = 2
    static let maxOptions = 4

    /// The questions of an `AskUserQuestion` input this build can answer, or nil.
    ///
    /// Answerable: 1 to 4 questions, each with a non-empty `question` text (no two alike) and
    /// 2 to 4 options with non-empty labels (no two alike in a question). A `kind` other than
    /// `"choice"` (the CLI's text and number questions) makes the whole input unanswerable.
    public static func parse(_ input: ApprovalJSON) -> [ApprovalQuestion]? {
        guard case .object(let fields) = input,
              case .array(let rawQuestions)? = fields["questions"],
              (1...maxQuestions).contains(rawQuestions.count) else { return nil }
        var questions: [ApprovalQuestion] = []
        for raw in rawQuestions {
            guard case .object(let q) = raw else { return nil }
            if let kind = q["kind"] {
                guard case .string("choice") = kind else { return nil }
            }
            guard case .string(let text)? = q["question"], !text.isEmpty,
                  !questions.contains(where: { $0.question == text }),
                  case .array(let rawOptions)? = q["options"],
                  (minOptions...maxOptions).contains(rawOptions.count) else { return nil }
            var options: [ApprovalQuestionOption] = []
            for rawOption in rawOptions {
                guard case .object(let o) = rawOption,
                      case .string(let label)? = o["label"], !label.isEmpty,
                      !options.contains(where: { $0.label == label }) else { return nil }
                var description = ""
                if case .string(let d)? = o["description"] { description = d }
                options.append(ApprovalQuestionOption(label: label, description: description))
            }
            var header = ""
            if case .string(let h)? = q["header"] { header = h }
            var multiSelect = false
            if case .bool(let m)? = q["multiSelect"] { multiSelect = m }
            questions.append(ApprovalQuestion(question: text, header: header, multiSelect: multiSelect, options: options))
        }
        return questions
    }

    /// The answers to send: nil unless there is one selection per question and every question is answered.
    public static func answers(for questions: [ApprovalQuestion],
                               selections: [ApprovalQuestionSelection]) -> [ApprovalQuestionAnswer]? {
        guard questions.count == selections.count else { return nil }
        var answers: [ApprovalQuestionAnswer] = []
        for (question, selection) in zip(questions, selections) {
            guard let answer = selection.answer(for: question) else { return nil }
            answers.append(answer)
        }
        return answers
    }
}

/// What a form has chosen for one question.
public struct ApprovalQuestionSelection: Equatable {
    /// The options chosen, by index.
    public var selected: Set<Int> = []
    /// "Other" is chosen (it counts only with text).
    public var otherChosen = false
    public var otherText = ""

    public init() {}

    /// A single-select question picks this option (and drops the others and "Other"); a multi-select one toggles it.
    public mutating func toggle(option: Int, in question: ApprovalQuestion) {
        guard question.options.indices.contains(option) else { return }
        if question.multiSelect {
            if selected.contains(option) { selected.remove(option) } else { selected.insert(option) }
        } else {
            selected = [option]
            otherChosen = false
        }
    }

    /// "Other" chosen or not. In a single-select question choosing it drops the options.
    public mutating func setOther(chosen: Bool, in question: ApprovalQuestion) {
        otherChosen = chosen
        if chosen && !question.multiSelect { selected = [] }
    }

    /// The typed text. Text with something in it chooses "Other"; emptying the text un-chooses it.
    public mutating func setOtherText(_ text: String, in question: ApprovalQuestion) {
        otherText = text
        if Self.trimmed(text).isEmpty {
            otherChosen = false
        } else {
            setOther(chosen: true, in: question)
        }
    }

    /// At least one option is chosen, or "Other" is chosen with text that has something visible in it
    /// and is no longer than `ApprovalQuestions.maxOtherCharacters`.
    public func isAnswered(in question: ApprovalQuestion) -> Bool {
        answer(for: question) != nil
    }

    /// The answer for `question`, or nil while it is unanswered. Labels come in the question's option order.
    public func answer(for question: ApprovalQuestion) -> ApprovalQuestionAnswer? {
        let labels = question.options.indices.filter { selected.contains($0) }.map { question.options[$0].label }
        var other: String?
        if otherChosen {
            let text = Self.trimmed(otherText)
            guard !text.isEmpty, text.unicodeScalars.count <= ApprovalQuestions.maxOtherCharacters else { return nil }
            other = text
        }
        if question.multiSelect {
            guard !labels.isEmpty || other != nil else { return nil }
        } else {
            guard labels.count + (other == nil ? 0 : 1) == 1 else { return nil }
        }
        return ApprovalQuestionAnswer(question: question.question, selected: labels, other: other)
    }

    /// The text with its ends trimmed, and nothing at all when only whitespace and hidden characters are left.
    private static func trimmed(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = ApprovalDisplayModel.contextRuns(for: trimmed, keepingLineFeeds: false).contains {
            $0.kind == .plain && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return visible ? trimmed : ""
    }
}
