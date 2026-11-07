import AppKit
import NostromoKit

// AP2c: the form that answers an `AskUserQuestion` request on the approval card.
//
//   DATABASE                                          (header chip)
//   Which database should we use?                     (question, wraps)
//   ─────────────────────────────────────────────
//   ✓ Postgres      Relational, strong consistency    (option rows: label left, description muted)
//   ─────────────────────────────────────────────
//     SQLite        Embedded, zero setup
//   ─────────────────────────────────────────────
//     [ Other…                                  ]     (free text; typing chooses it)
//
// The rows look like the transcript card's (`OptionRowStyle`). A row is a radio button (a checkbox when
// the question is multi-select) to assistive technology; each question keeps its own selection. The rows
// are toggle buttons, not radio-type buttons, so AppKit never groups the rows of two questions.
//
// What it is: a draft. It holds what is chosen (`ApprovalQuestionSelection`, one per question)
// and nothing else; the answer is only sent when the card's Submit is pressed by a person. Choosing a
// row never submits.
//
// What keeps it safe and inside its pane:
//   * No control has a key equivalent and none can be a default button.
//   * Choosing an option, or toggling Other, asks `permit` first (the card passes the human-gesture
//     check). A refused click changes nothing: the rows are put back as the model says.
//   * Layout is by frame, top to bottom, from a measured height. A label wraps at the width it is
//     given and a text field scrolls its own text, so no string, however long, can ask for more
//     width than the form has. (Labels also carry a low horizontal compression resistance.)
//   * Selecting never changes a row's height or width (the label's weight does not change).
//   * Every string from the request is drawn with hidden or direction-changing characters as
//     visible tokens (`ApprovalContextText`), like the rest of the card.

/// One option row (or the Other row): a full-width toggle button that draws its own selected and hover
/// look, takes keyboard focus when enabled, and never answers to Return. Space toggles it; the arrow keys
/// only move focus to the neighbouring row.
final class ApprovalChoiceButton: NSButton {
    let checkmark = OptionRowStyle.checkmarkImage()
    private var hovering = false

    init(multi: Bool) {
        super.init(frame: .zero)
        setButtonType(.toggle)
        isBordered = false
        title = ""
        imagePosition = .noImage
        wantsLayer = true
        layer?.cornerRadius = 0
        focusRingType = .default
        translatesAutoresizingMaskIntoConstraints = true
        // Said outright: a titleless button would otherwise report an unknown role.
        setAccessibilityRole(multi ? .checkBox : .radioButton)
        // The row's texts are its label and help; they are not separate elements.
        setAccessibilityChildren([])
        checkmark.translatesAutoresizingMaskIntoConstraints = true
        addSubview(checkmark)
        refreshLook()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var keyEquivalent: String {
        get { "" }
        set { /* never */ }
    }

    override var state: NSControl.StateValue {
        didSet { refreshLook() }
    }

    override var isEnabled: Bool {
        didSet { if !isEnabled { hovering = false }; refreshLook() }
    }

    override func accessibilityValue() -> Any? { NSNumber(value: state == .on ? 1 : 0) }

    /// A click anywhere in the row is a click on the row, whatever text is drawn there.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125, 124: window?.selectKeyView(following: self)   // down, right
        case 126, 123: window?.selectKeyView(preceding: self)   // up, left
        default: super.keyDown(with: event)
        }
    }

    override func drawFocusRingMask() { NSBezierPath(rect: bounds).fill() }
    override var focusRingMaskBounds: NSRect { bounds }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        hovering = true
        refreshLook()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        refreshLook()
    }

    /// Selected: sage tint and the check. Hover: a quiet tint, only when not selected. Never changes the row's size.
    private func refreshLook() {
        let selected = state == .on
        checkmark.isHidden = !selected
        layer?.backgroundColor = selected ? OptionRowStyle.chosenTint : (hovering ? OptionRowStyle.hoverTint : nil)
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

    /// An Other answer is chosen and longer than the limit (so Submit stays off).
    var hasOverLimitOther: Bool {
        selections.contains { $0.otherChosen && $0.otherText.count > ApprovalQuestions.maxOtherCharacters }
    }

    /// Every question has an answer.
    var isComplete: Bool { answers != nil }

    /// The answers to send, or nil until every question is answered.
    var answers: [ApprovalQuestionAnswer]? {
        ApprovalQuestions.answers(for: questions, selections: selections)
    }

    static let textLeading = OptionRowStyle.inset + OptionRowStyle.checkSize + OptionRowStyle.checkGap
    static let sectionGap: CGFloat = 14
    static let questionGap: CGFloat = 8
    static let verticalPad: CGFloat = 9
    static let dividerHeight: CGFloat = 1
    static let otherFieldHeight: CGFloat = 22

    private let questions: [ApprovalQuestion]

    private struct OptionRow {
        let button: ApprovalChoiceButton
        let label: NSTextField
        let description: NSTextField
    }

    private struct Section {
        let chip: NSTextField?
        let question: NSTextField
        let options: [OptionRow]
        let otherButton: ApprovalChoiceButton
        let otherField: NSTextField
        /// One above each row, the Other row last: `options.count + 1`.
        let dividers: [NSView]
    }

    private var sections: [Section] = []

    override var isFlipped: Bool { true }

    /// - Parameter draft: what was chosen and typed before this form was rebuilt (the person paged
    ///   away and back). Used only if it fits `questions`; it is a draft, never sent by itself.
    init(questions: [ApprovalQuestion], draft: [ApprovalQuestionSelection]? = nil) {
        self.questions = questions
        let fits = draft.map { $0.count == questions.count } ?? false
        self.selections = fits ? draft! : Array(repeating: ApprovalQuestionSelection(), count: questions.count)
        super.init(frame: .zero)
        for (index, question) in questions.enumerated() { sections.append(buildSection(question, index: index)) }
        if fits { for (q, section) in sections.enumerated() { section.otherField.stringValue = selections[q].otherText } }
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

    /// Natural single-line width of a label's text (0 when hidden or empty).
    private func naturalWidth(_ label: NSTextField) -> CGFloat {
        guard !label.isHidden, let cell = label.cell else { return 0 }
        return ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: 100_000, height: 100_000)).width) + 1
    }

    /// Where a row's texts go, relative to the row: label and description side by side when both fit on
    /// one line, otherwise the label wrapped over the description wrapped.
    private struct RowMetrics {
        var height: CGFloat
        var label: NSRect
        var description: NSRect
    }

    private func metrics(of row: OptionRow, width: CGFloat) -> RowMetrics {
        let textWidth = max(40, width - Self.textLeading - OptionRowStyle.inset)
        let descriptionVisible = !row.description.isHidden
        let labelNatural = naturalWidth(row.label)
        let descriptionNatural = naturalWidth(row.description)
        let singleLines = !row.label.stringValue.contains("\n") && !row.description.stringValue.contains("\n")
        if descriptionVisible, singleLines,
           labelNatural + OptionRowStyle.descriptionGap + descriptionNatural <= textWidth {
            let labelHeight = wrappedHeight(row.label, width: labelNatural)
            let descriptionHeight = wrappedHeight(row.description, width: descriptionNatural)
            let x = Self.textLeading
            return RowMetrics(
                height: OptionRowStyle.rowHeight,
                label: NSRect(x: x, y: floor((OptionRowStyle.rowHeight - labelHeight) / 2), width: labelNatural, height: labelHeight),
                description: NSRect(x: x + labelNatural + OptionRowStyle.descriptionGap,
                                    y: floor((OptionRowStyle.rowHeight - descriptionHeight) / 2),
                                    width: descriptionNatural, height: descriptionHeight))
        }
        let labelHeight = wrappedHeight(row.label, width: textWidth)
        let descriptionHeight = wrappedHeight(row.description, width: textWidth)
        let stacked = Self.verticalPad * 2 + labelHeight + (descriptionHeight > 0 ? descriptionHeight + 2 : 0)
        let height = max(OptionRowStyle.rowHeight, stacked)
        let top = descriptionVisible || labelHeight > 20 ? Self.verticalPad : floor((height - labelHeight) / 2)
        return RowMetrics(
            height: height,
            label: NSRect(x: Self.textLeading, y: top, width: textWidth, height: labelHeight),
            description: NSRect(x: Self.textLeading, y: top + labelHeight + 2, width: textWidth, height: descriptionHeight))
    }

    @discardableResult
    private func rows(width requested: CGFloat, apply: Bool) -> CGFloat {
        let width = max(60, requested)
        let textWidth = max(40, width - Self.textLeading - OptionRowStyle.inset)
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
            y += questionHeight + Self.questionGap

            func placeDivider(_ index: Int) {
                if apply {
                    let inset = index == 0 ? 0 : OptionRowStyle.inset
                    section.dividers[index].frame = NSRect(x: inset, y: y, width: width - inset, height: Self.dividerHeight)
                }
                y += Self.dividerHeight
            }

            for (o, row) in section.options.enumerated() {
                placeDivider(o)
                let m = metrics(of: row, width: width)
                if apply {
                    row.button.frame = NSRect(x: 0, y: y, width: width, height: m.height)
                    row.button.checkmark.frame = NSRect(x: OptionRowStyle.inset, y: 10, width: OptionRowStyle.checkSize,
                                                        height: OptionRowStyle.checkSize)
                    row.label.frame = m.label
                    row.description.frame = m.description
                }
                y += m.height
            }

            placeDivider(section.options.count)
            let otherHeight = OptionRowStyle.rowHeight
            if apply {
                section.otherButton.frame = NSRect(x: 0, y: y, width: width, height: otherHeight)
                section.otherButton.checkmark.frame = NSRect(x: OptionRowStyle.inset, y: 10, width: OptionRowStyle.checkSize,
                                                             height: OptionRowStyle.checkSize)
                section.otherField.frame = NSRect(x: Self.textLeading, y: y + (otherHeight - Self.otherFieldHeight) / 2,
                                                  width: textWidth, height: Self.otherFieldHeight)
            }
            y += otherHeight
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
        var dividers: [NSView] = []
        func divider() {
            let line = NSView()
            line.wantsLayer = true
            line.layer?.backgroundColor = dividers.isEmpty ? OptionRowStyle.topDivider : OptionRowStyle.rowDivider
            addSubview(line)
            dividers.append(line)
        }
        for (optionIndex, option) in question.options.enumerated() {
            divider()
            let button = choiceButton(multi: question.multiSelect, id: "q\(index)_opt\(optionIndex)",
                                      action: #selector(optionPressed(_:)))
            button.setAccessibilityLabel(ApprovalDisplayModel.contextText(option.label, keepingLineFeeds: false))
            if !option.description.isEmpty {
                button.setAccessibilityHelp(ApprovalDisplayModel.contextText(option.description, keepingLineFeeds: false))
            }
            let label = NSTextField(wrappingLabelWithString: "")
            configureWrapping(label)
            label.isSelectable = false
            ApprovalContextText.set(label, option.label, wraps: true,
                                    font: OptionRowStyle.labelFont, color: ApprovalPalette.commandText)
            let description = wrappingLabel()
            description.isSelectable = false
            if option.description.isEmpty {
                description.isHidden = true
            } else {
                ApprovalContextText.set(description, option.description, wraps: true,
                                        font: OptionRowStyle.descriptionFont, color: ApprovalPalette.mutedText)
            }
            addSubview(button)
            button.addSubview(label)
            button.addSubview(description)
            rows.append(OptionRow(button: button, label: label, description: description))
        }
        divider()

        let otherButton = choiceButton(multi: question.multiSelect, id: "q\(index)_other", action: #selector(otherPressed(_:)))
        otherButton.setAccessibilityLabel("Other")
        addSubview(otherButton)
        let field = NSTextField()
        field.identifier = NSUserInterfaceItemIdentifier("q\(index)_other_field")
        field.placeholderString = "Other…"
        // Longer text is not an answer (Submit stays off); the form never cuts what was typed.
        field.toolTip = "At most \(ApprovalQuestions.maxOtherCharacters) characters"
        field.font = .systemFont(ofSize: 12)
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.setAccessibilityLabel("Other answer: \(ApprovalDisplayModel.contextText(question.question, keepingLineFeeds: false))")
        addSubview(field)   // above the Other row, so a click in the field reaches the field
        return Section(chip: chip, question: questionLabel, options: rows, otherButton: otherButton, otherField: field,
                       dividers: dividers)
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
        let button = ApprovalChoiceButton(multi: multi)
        button.identifier = NSUserInterfaceItemIdentifier(id)
        button.target = self
        button.action = action
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
        permit?(control, name) ?? false
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
