import AppKit
import NostromoKit

// AP2c: the form that answers an `AskUserQuestion` request on the approval card.
//
//   DATABASE                                   (header chip)
//   Which database should we use?              (question, wraps)
//   ◉ Postgres                                 (radio, or a checkbox when multi-select)
//       Relational, strong consistency         (the option's description, muted)
//   ○ SQLite
//       Embedded, zero setup
//   ○ [ Other…                              ]  (free text; typing chooses it)
//
// What it is: a draft. It holds what is chosen (`ApprovalQuestionSelection`, one per question)
// and nothing else; the answer is only sent when the card's Submit is pressed by a person.
//
// What keeps it safe and inside its pane:
//   * No control has a key equivalent and none can be a default button.
//   * Choosing an option, or toggling Other, asks `permit` first (the card passes the human-gesture
//     check). A refused click changes nothing: the controls are put back as the model says.
//   * Layout is by frame, top to bottom, from a measured height. A label wraps at the width it is
//     given and a text field scrolls its own text, so no string, however long, can ask for more
//     width than the form has. (Labels also carry a low horizontal compression resistance.)
//   * Every string from the request is drawn with hidden or direction-changing characters as
//     visible tokens (`ApprovalContextText`), like the rest of the card.

/// A radio button or checkbox that can take keyboard focus when enabled and never answers to Return.
final class ApprovalChoiceButton: NSButton {
    override var acceptsFirstResponder: Bool { isEnabled }
    override var keyEquivalent: String {
        get { "" }
        set { /* never */ }
    }
}

/// An option's text. Clicking it presses the option's button (a real click, so the same gesture check applies).
private final class ApprovalChoiceLabel: NSTextField {
    weak var button: ApprovalChoiceButton?

    override func mouseDown(with event: NSEvent) {
        guard let button, button.isEnabled else { return }
        button.performClick(self)
    }
}

final class ApprovalQuestionFormView: NSView, NSTextFieldDelegate {

    /// A selection changed.
    var onChange: (() -> Void)?
    /// Asked before an option or Other toggle changes anything: `(control, name)`. False ignores the click.
    /// Nil allows it.
    var permit: ((NSView, String) -> Bool)?
    /// False disables every control (the answer has been sent, or the request ended).
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            applyEnabled()
        }
    }

    private(set) var selections: [ApprovalQuestionSelection]

    /// Every question has an answer.
    var isComplete: Bool { answers != nil }

    /// The answers to send, or nil until every question is answered.
    var answers: [ApprovalQuestionAnswer]? {
        ApprovalQuestions.answers(for: questions, selections: selections)
    }

    static let indent: CGFloat = 24
    static let controlSize: CGFloat = 18
    static let sectionGap: CGFloat = 14
    static let rowGap: CGFloat = 6
    static let otherFieldHeight: CGFloat = 22

    private let questions: [ApprovalQuestion]

    private struct OptionRow {
        let button: ApprovalChoiceButton
        let label: ApprovalChoiceLabel
        let description: NSTextField
    }

    private struct Section {
        let chip: NSTextField?
        let question: NSTextField
        let options: [OptionRow]
        let otherButton: ApprovalChoiceButton
        let otherField: NSTextField
    }

    private var sections: [Section] = []

    override var isFlipped: Bool { true }

    init(questions: [ApprovalQuestion]) {
        self.questions = questions
        self.selections = Array(repeating: ApprovalQuestionSelection(), count: questions.count)
        super.init(frame: .zero)
        for (index, question) in questions.enumerated() { sections.append(buildSection(question, index: index)) }
        syncControls()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Test seams

    func optionButton(question: Int, option: Int) -> NSButton? {
        guard sections.indices.contains(question), sections[question].options.indices.contains(option) else { return nil }
        return sections[question].options[option].button
    }

    func otherButton(question: Int) -> NSButton? {
        sections.indices.contains(question) ? sections[question].otherButton : nil
    }

    func otherField(question: Int) -> NSTextField? {
        sections.indices.contains(question) ? sections[question].otherField : nil
    }

    func questionLabel(_ i: Int) -> NSTextField { sections[i].question }

    func headerChip(_ i: Int) -> NSTextField? { sections[i].chip }

    func optionLabel(question: Int, option: Int) -> NSTextField { sections[question].options[option].label }

    func descriptionLabel(question: Int, option: Int) -> NSTextField { sections[question].options[option].description }

    // MARK: Layout

    /// The height this form needs at `width`. Exact: `layout()` uses the same arithmetic.
    func contentHeight(forWidth width: CGFloat) -> CGFloat {
        rows(width: width, apply: false)
    }

    override func layout() {
        super.layout()
        _ = rows(width: bounds.width, apply: true)
    }

    private func wrappedHeight(_ label: NSTextField, width: CGFloat) -> CGFloat {
        guard !label.isHidden, let cell = label.cell else { return 0 }
        return ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 100_000)).height)
    }

    @discardableResult
    private func rows(width requested: CGFloat, apply: Bool) -> CGFloat {
        let width = max(60, requested)
        let textWidth = max(40, width - Self.indent)
        var y: CGFloat = 0
        for (i, section) in sections.enumerated() {
            if i > 0 { y += Self.sectionGap }
            if let chip = section.chip {
                let chipWidth = min(width, ceil(chip.cell?.cellSize.width ?? 0) + 12)
                if apply { chip.frame = NSRect(x: 0, y: y, width: chipWidth, height: 16) }
                y += 16 + 4
            }
            let questionHeight = wrappedHeight(section.question, width: width)
            if apply { section.question.frame = NSRect(x: 0, y: y, width: width, height: questionHeight) }
            y += questionHeight + Self.rowGap

            for row in section.options {
                let labelHeight = wrappedHeight(row.label, width: textWidth)
                let descriptionHeight = wrappedHeight(row.description, width: textWidth)
                let rowHeight = max(Self.controlSize + 2, labelHeight + (descriptionHeight > 0 ? descriptionHeight + 2 : 0))
                if apply {
                    row.button.frame = NSRect(x: 0, y: y + 1, width: Self.controlSize, height: Self.controlSize)
                    row.label.frame = NSRect(x: Self.indent, y: y + (labelHeight < Self.controlSize ? 1 : 0),
                                             width: textWidth, height: labelHeight)
                    row.description.frame = NSRect(x: Self.indent, y: y + labelHeight + 2,
                                                   width: textWidth, height: descriptionHeight)
                }
                y += rowHeight + Self.rowGap
            }

            if apply {
                section.otherButton.frame = NSRect(x: 0, y: y + 2, width: Self.controlSize, height: Self.controlSize)
                section.otherField.frame = NSRect(x: Self.indent, y: y, width: textWidth, height: Self.otherFieldHeight)
            }
            y += Self.otherFieldHeight
        }
        return y
    }

    // MARK: Building

    private func buildSection(_ question: ApprovalQuestion, index: Int) -> Section {
        var chip: NSTextField?
        if !question.header.isEmpty {
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.alignment = .center
            label.wantsLayer = true
            label.layer?.backgroundColor = Theme.cornflower.withAlphaComponent(0.16).cgColor
            label.layer?.cornerRadius = 4
            ApprovalContextText.set(label, question.header, wraps: false,
                                    font: .systemFont(ofSize: 10, weight: .semibold), color: Theme.cornflower)
            label.setAccessibilityLabel("Topic: \(ApprovalDisplayModel.contextText(question.header, keepingLineFeeds: false))")
            addSubview(label)
            chip = label
        }

        let questionLabel = wrappingLabel()
        questionLabel.isSelectable = true
        ApprovalContextText.set(questionLabel, question.question, wraps: true,
                                font: .systemFont(ofSize: 13, weight: .medium), color: ApprovalPalette.commandText)
        addSubview(questionLabel)

        var rows: [OptionRow] = []
        for (optionIndex, option) in question.options.enumerated() {
            let button = choiceButton(multi: question.multiSelect, id: "q\(index)_opt\(optionIndex)",
                                      action: #selector(optionPressed(_:)))
            button.setAccessibilityLabel(ApprovalDisplayModel.contextText(option.label, keepingLineFeeds: false))
            if !option.description.isEmpty {
                button.setAccessibilityHelp(ApprovalDisplayModel.contextText(option.description, keepingLineFeeds: false))
            }
            let label = ApprovalChoiceLabel(wrappingLabelWithString: "")
            configureWrapping(label)
            label.isSelectable = false
            label.button = button
            ApprovalContextText.set(label, option.label, wraps: true,
                                    font: .systemFont(ofSize: 12), color: ApprovalPalette.commandText)
            let description = wrappingLabel()
            description.isSelectable = false
            if option.description.isEmpty {
                description.isHidden = true
            } else {
                ApprovalContextText.set(description, option.description, wraps: true,
                                        font: .systemFont(ofSize: 11), color: ApprovalPalette.mutedText)
            }
            for v in [button, label, description] { addSubview(v) }
            rows.append(OptionRow(button: button, label: label, description: description))
        }

        let otherButton = choiceButton(multi: question.multiSelect, id: "q\(index)_other", action: #selector(otherPressed(_:)))
        otherButton.setAccessibilityLabel("Other")
        let field = NSTextField()
        field.identifier = NSUserInterfaceItemIdentifier("q\(index)_other_field")
        field.placeholderString = "Other…"
        field.font = .systemFont(ofSize: 12)
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.setAccessibilityLabel("Other answer: \(ApprovalDisplayModel.contextText(question.question, keepingLineFeeds: false))")
        addSubview(otherButton)
        addSubview(field)
        return Section(chip: chip, question: questionLabel, options: rows, otherButton: otherButton, otherField: field)
    }

    private func wrappingLabel() -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        configureWrapping(label)
        return label
    }

    /// Wraps at any width and never asks for more: a long string grows the label's height, not its width.
    private func configureWrapping(_ label: NSTextField) {
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.cell?.truncatesLastVisibleLine = false
        label.translatesAutoresizingMaskIntoConstraints = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    private func choiceButton(multi: Bool, id: String, action: Selector) -> ApprovalChoiceButton {
        let button = ApprovalChoiceButton()
        button.setButtonType(multi ? .switch : .radio)
        button.title = ""
        button.identifier = NSUserInterfaceItemIdentifier(id)
        button.target = self
        button.action = action
        button.focusRingType = .default
        button.translatesAutoresizingMaskIntoConstraints = true
        return button
    }

    // MARK: Actions

    @objc private func optionPressed(_ sender: ApprovalChoiceButton) {
        defer { syncControls() }
        guard isEnabled, let (q, o) = indices(of: sender, kind: "opt"), questions.indices.contains(q),
              questions[q].options.indices.contains(o), allowed(sender, "answer_option") else { return }
        selections[q].toggle(option: o, in: questions[q])
        onChange?()
    }

    @objc private func otherPressed(_ sender: ApprovalChoiceButton) {
        defer { syncControls() }
        guard isEnabled, let (q, _) = indices(of: sender, kind: "other"), questions.indices.contains(q),
              allowed(sender, "answer_option") else { return }
        selections[q].setOther(chosen: !selections[q].otherChosen, in: questions[q])
        onChange?()
        if selections[q].otherChosen { window?.makeFirstResponder(sections[q].otherField) }
    }

    private func allowed(_ control: NSView, _ name: String) -> Bool {
        permit?(control, name) ?? true
    }

    /// `q1_opt2` → (1, 2); `q1_other` → (1, 0).
    private func indices(of button: ApprovalChoiceButton, kind: String) -> (Int, Int)? {
        guard let id = button.identifier?.rawValue, id.hasPrefix("q") else { return nil }
        let parts = id.dropFirst().components(separatedBy: "_")
        guard parts.count == 2, let q = Int(parts[0]) else { return nil }
        if kind == "other" { return parts[1] == "other" ? (q, 0) : nil }
        guard parts[1].hasPrefix("opt"), let o = Int(parts[1].dropFirst(3)) else { return nil }
        return (q, o)
    }

    // MARK: Typing in Other

    func controlTextDidChange(_ notification: Notification) {
        guard isEnabled, let field = notification.object as? NSTextField,
              let q = sections.firstIndex(where: { $0.otherField === field }) else { return }
        if field.stringValue.unicodeScalars.count > ApprovalQuestions.maxOtherCharacters {
            var scalars = String.UnicodeScalarView()
            scalars.append(contentsOf: field.stringValue.unicodeScalars.prefix(ApprovalQuestions.maxOtherCharacters))
            field.stringValue = String(scalars)
        }
        selections[q].setOtherText(field.stringValue, in: questions[q])
        syncControls()
        onChange?()
    }

    // MARK: State

    /// Put every control back as the model says (also after a refused click).
    private func syncControls() {
        for (q, section) in sections.enumerated() {
            let selection = selections[q]
            for (o, row) in section.options.enumerated() {
                row.button.state = selection.selected.contains(o) ? .on : .off
            }
            section.otherButton.state = selection.otherChosen ? .on : .off
        }
    }

    private func applyEnabled() {
        for section in sections {
            for row in section.options {
                row.button.isEnabled = isEnabled
                row.label.alphaValue = isEnabled ? 1 : 0.6
            }
            section.otherButton.isEnabled = isEnabled
            section.otherField.isEnabled = isEnabled
            section.otherField.isEditable = isEnabled
        }
    }
}
