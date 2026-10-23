import AppKit
import os
import NostromoKit

private let cardLog = Logger(subsystem: "com.hammer.nostromo", category: "approvals")

// AP2a: the approval card: one permission request, shown exactly, with the human's answers.
//
//   ┌─ Cody wants to run Bash ───────────── +1 more  denies in 14:32 ─┐
//   │ Why: your rule Bash(rm:*) in ~/.claude/settings.json            │
//   │ In:  ~/Code/nostromo-wt/ba3                                      │
//   │ This command contains 1 invisible or direction-changing character│
//   │ 2 commands                                                       │
//   │  1 │ rm -rf build/ ⟨&&⟩                                          │
//   │  2 │ rm -rf target/debug/incremental                             │
//   │ Agent says: "Clean build outputs before the release build"       │
//   │ [Deny][▾][Deny & stop]                        [Allow once]       │
//   └──────────────────────────────────────────────────────────────────┘
//
// What keeps it safe:
//   * No button has a key equivalent and none is the default: Return and Space do
//     nothing unless a button has keyboard focus. Arrival never takes focus.
//   * Allow once stays disabled until the input has shown every one of its lines, and while
//     `ApprovalDisplayModel` can't prove the shown text is the request's text.
//   * Every string the card draws from the request (the input, the headline, Why, In, Agent
//     says) shows a hidden or direction-changing character as a visible token.
//   * After a refused answer nothing can be allowed, but Deny stays available (one attempt at
//     a time, through the same human-gesture check).
//   * A click on the card's own padding (not a button or the input) makes the card first
//     responder, and the card hands focus on to `initialKeyView` (Deny, or the input). The
//     plan says "Tab into it, or click": this is that. It sends nothing, and it never runs
//     on arrival.
//   * Every answer goes through `HumanGesture.permit` first. On a refusal nothing is
//     answered, the card stays, and the app reports the refusal to the daemon.
//   * The card holds no answered state. `ApprovalStore` does, so a rebuilt card can't
//     answer twice.
//   * Its height depends only on its content and the width it is given. A tick of the
//     countdown, an outcome appearing, or a status change never moves any row.
//
// Layout is by frame (top to bottom), not Auto Layout, so the height is exact.
//
// AskUserQuestion (AP2c): when the daemon lists `answer_questions` for the request, the input is
// replaced by a form (`ApprovalQuestionFormView`, in a vertical scroll view) and Allow once by
// Submit. Submit goes through the same gesture check and needs every question answered; the raw
// input stays behind a collapsed "Details" row. Nothing else about the card changes.

/// Text from a request, drawn with every hidden or direction-changing character as a visible token in
/// the warning colour (the input's tokens), always left to right so nothing reorders on screen.
enum ApprovalContextText {

    /// A line feed is kept as a line break only where the label `wraps`; in a one-row label it is a token.
    static func attributed(_ text: String, prefix: String = "", suffix: String = "", wraps: Bool = true,
                           lineBreakMode: NSLineBreakMode, font: NSFont, color: NSColor) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = lineBreakMode
        style.baseWritingDirection = .leftToRight
        let direction = [NSWritingDirection.leftToRight.rawValue | NSWritingDirectionFormatType.override.rawValue]
        func attrs(_ extra: [NSAttributedString.Key: Any] = [:]) -> [NSAttributedString.Key: Any] {
            var base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style,
                                                       .writingDirection: direction]
            base.merge(extra) { _, new in new }
            return base
        }
        let out = NSMutableAttributedString(string: prefix, attributes: attrs())
        for run in ApprovalDisplayModel.contextRuns(for: text, keepingLineFeeds: wraps) {
            if run.kind == .invisible {
                out.append(NSAttributedString(string: run.text, attributes: attrs([
                    .foregroundColor: ApprovalPalette.warning,
                    .backgroundColor: ApprovalPalette.warningFill,
                ])))
            } else {
                out.append(NSAttributedString(string: run.text, attributes: attrs()))
            }
        }
        out.append(NSAttributedString(string: suffix, attributes: attrs()))
        return out
    }

    static func set(_ label: NSTextField, _ text: String, prefix: String = "", suffix: String = "",
                    wraps: Bool = true, font: NSFont, color: NSColor) {
        label.attributedStringValue = attributed(text, prefix: prefix, suffix: suffix, wraps: wraps,
                                                 lineBreakMode: label.lineBreakMode, font: font, color: color)
    }
}

/// A button that can take keyboard focus (AppKit refuses it unless Full Keyboard Access is
/// on) and can never be a default button.
final class ApprovalButton: NSButton {
    override var acceptsFirstResponder: Bool { isEnabled }
    override var keyEquivalent: String {
        get { "" }
        set { /* never: no button on the card answers to Return or Esc */ }
    }
}

/// What `nostromo-app approvals list` reports for one card, read from the card's own views.
struct ApprovalCardListing: Equatable {
    struct Line: Equatable {
        let number: Int
        let text: String
        let kind: String
        let separators: [String]
    }
    struct Option: Equatable {
        let id: String
        let enabled: Bool
        let label: String
    }
    /// One question of an `AskUserQuestion` card, as the form shows it.
    struct Question: Equatable {
        struct Choice: Equatable {
            let label: String
            let description: String
            let selected: Bool
        }
        let question: String
        let header: String
        let multiSelect: Bool
        let options: [Choice]
        let otherText: String
        let otherSelected: Bool

        var jsonObject: [String: Any] {
            ["question": question, "header": header, "multi_select": multiSelect,
             "options": options.map { ["label": $0.label, "description": $0.description, "selected": $0.selected] as [String: Any] },
             "other_text": otherText, "other_selected": otherSelected]
        }
    }

    let requestID: String
    let focus: String
    let agent: String
    let tool: String
    let headline: String
    /// The input as displayed: the view's lines with invisible characters as tokens.
    let input: String
    let lines: [Line]
    let commandCount: Int?
    let invisibleCount: Int
    let nonAsciiCount: Int
    let banner: String?
    let reasonLine: String
    let options: [Option]
    let defaultToNoKind: Bool
    let secondsLeft: Int
    let state: String
    /// The input's text could not be laid out, so Allow once is withheld (additive: `display_failed`).
    let displayFailed: Bool
    /// For an `AskUserQuestion` card: what the form shows and has chosen (additive: `questions`, null otherwise).
    let questions: [Question]?

    var jsonObject: [String: Any] {
        var json: [String: Any] = [
            "request_id": requestID,
            "focus": focus,
            "agent": agent,
            "tool": tool,
            "headline": headline,
            "input": input,
            "lines": lines.map { ["number": $0.number, "text": $0.text, "kind": $0.kind, "separators": $0.separators] as [String: Any] },
            "invisible_count": invisibleCount,
            "non_ascii_count": nonAsciiCount,
            "reason_line": reasonLine,
            "options": options.map { ["id": $0.id, "enabled": $0.enabled, "label": $0.label] as [String: Any] },
            "default_to_no_kind": defaultToNoKind,
            "seconds_left": secondsLeft,
            "state": state,
            "display_failed": displayFailed,
        ]
        json["questions"] = questions.map { $0.map(\.jsonObject) } ?? NSNull()
        json["command_count"] = commandCount ?? NSNull()
        json["banner"] = banner ?? NSNull()
        return json
    }
}

final class ApprovalCardView: NSView {

    typealias GesturePermit = (NSView) -> HumanGestureVerdict

    /// The card's own geometry.
    static let padding: CGFloat = 10
    static let rowGap: CGFloat = 6
    static let buttonHeight: CGFloat = 26
    static let allowButtonWidth: CGFloat = 196
    static let submitButtonWidth: CGFloat = 96
    static let minimumInputHeight: CGFloat = 44
    /// A question card's form never gets less than this unless the pane is shorter, and its expanded raw input never more than `detailsInputHeight`.
    static let minimumFormHeight: CGFloat = 96
    static let detailsInputHeight: CGFloat = 140
    /// Room on the form's right for the scroll view's scroller.
    static let formScrollerGutter: CGFloat = 12

    let request: ApprovalRequestWire
    let model: ApprovalDisplayModel
    let options: ApprovalCardOptions
    let inputView: ApprovalInputView
    let countdown: ApprovalCountdownLabel

    private(set) var denyButton: ApprovalButton!
    private(set) var denyMoreButton: ApprovalButton?
    private(set) var denyAndStopButton: ApprovalButton?
    private(set) var allowButton: ApprovalButton?
    /// AskUserQuestion: the form, Submit and the Details disclosure (nil for every other request).
    private(set) var questionForm: ApprovalQuestionFormView?
    private(set) var submitButton: ApprovalButton?
    private(set) var detailsButton: ApprovalButton?
    /// The raw input is shown (a question card starts with it collapsed).
    private(set) var detailsExpanded = false

    /// Asked to re-measure the card (its content changed height: the note row opened).
    var onNeedsLayout: (() -> Void)?

    private let store: ApprovalStore
    private let windowID: () -> String
    private let permit: GesturePermit

    private let headlineLabel = NSTextField(labelWithString: "")
    private let moreLabel = NSTextField(labelWithString: "")
    private let whyLabel = NSTextField(wrappingLabelWithString: "")
    private let inLabel = NSTextField(labelWithString: "")
    private let bannerLabel = NSTextField(wrappingLabelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let agentSaysLabel = NSTextField(wrappingLabelWithString: "")
    private let noticeLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let noteField = NSTextField()
    private let noteSend = ApprovalButton(title: "Send", target: nil, action: nil)
    private let noteCancel = ApprovalButton(title: "Cancel", target: nil, action: nil)
    private let noteRow = NSView()
    private let buttonRow = NSView()
    private let formScroll = NSScrollView()

    private var state: ApprovalAnswerState
    /// False for a moment after the card appears: Allow once can't be pressed yet.
    private(set) var isArmed = true
    private var armDelay: TimeInterval = 0
    private var armGeneration = 0
    private var inputHeight: CGFloat = 0
    /// The form's scroll view height, and the form's natural height at `formWidth` (cached per width).
    private var formHeight: CGFloat = 0
    private var formNatural: (width: CGFloat, height: CGFloat)?

    // Layout is top-down.
    override var isFlipped: Bool { true }

    /// - Parameter armDelay: how long after it appears Allow once stays disabled (see
    ///   `ApprovalOverlayHost.armDelay`). Zero arms it at once.
    /// - Parameter isOnScreen: replaces "the window is visible and not occluded" for the input's
    ///   coverage (a test's window is never ordered in). Nil asks the window. Ignored in release builds.
    init(entry: ApprovalEntry, store: ApprovalStore, windowID: @escaping () -> String,
         permit: GesturePermit? = nil, armDelay: TimeInterval = 0, isOnScreen: (() -> Bool)? = nil) {
        request = entry.request
        state = entry.state
        model = ApprovalDisplayModel(request: entry.request)
        options = ApprovalCardOptions(request: entry.request)
        inputView = ApprovalInputView(model: model)
        #if DEBUG
        inputView.isWindowShowing = isOnScreen
        #endif
        countdown = ApprovalCountdownLabel(deadlineAtMs: entry.request.deadlineAtMs)
        self.store = store
        self.windowID = windowID
        self.permit = permit ?? { HumanGesture.permit(NSApp.currentEvent, control: $0) }
        super.init(frame: .zero)

        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = ApprovalPalette.cardBackground.cgColor
        layer?.borderColor = ApprovalPalette.border.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 8
        focusRingType = .none

        buildContent()
        self.armDelay = armDelay
        isArmed = armDelay <= 0
        refresh()

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(ApprovalDisplayModel.contextText(ApprovalKinds.announcement(for: request), keepingLineFeeds: false))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { countdown.stop() }

    // MARK: Keyboard focus

    /// Where keyboard focus lands when it enters the card (Tab into it, or a click on it):
    /// Deny when the CLI said `default_to_no` or the input has invisible characters,
    /// otherwise the input, so Space and the arrow keys scroll it.
    var initialKeyView: NSView? {
        if options.defaultsToDeny { return denyButton }
        if let form = questionForm { return form.optionButton(question: 0, option: 0) ?? denyButton }
        return inputView.textView
    }

    /// Move keyboard focus into the card. Never called on arrival: only by the person.
    func focusCard() {
        guard let window, let target = initialKeyView else { return }
        window.makeFirstResponder(target)
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        DispatchQueue.main.async { [weak self] in self?.focusCard() }
        return true
    }

    // MARK: State

    /// The request's state changed (answered, ended, refused). Only text and enabled flags change.
    func update(entry: ApprovalEntry) {
        guard entry.request.id == request.id, entry.state != state else { return }
        state = entry.state
        refresh()
    }

    var canAllow: Bool {
        isArmed && options.offersAllowOnce && model.isVerified && !inputView.displayFailed && inputView.hasShownEveryLine
    }

    /// What Allow once says: the reason it can't be pressed yet, or `Allow once`.
    var allowLabel: String {
        if !model.isVerified { return ApprovalDisplayModel.roundTripFailureLabel }
        if inputView.displayFailed { return "Can't display this input" }
        if !inputView.hasShownEveryLine { return "Scroll to the end to allow" }
        return "Allow once"
    }

    /// Submit can be pressed: the request is waiting, the card is armed and every question is answered.
    var canSubmit: Bool {
        state == .pending && isArmed && (questionForm?.isComplete ?? false)
    }

    // MARK: Measuring and layout

    /// The card's height at `width`, and the height it gives the input (up to 60% of the pane,
    /// via `maxHeight`). Sets what `layout()` will use.
    func preferredHeight(forWidth width: CGFloat, maxHeight: CGFloat, hardMaxHeight: CGFloat = .infinity) -> CGFloat {
        let inner = max(40, width - 2 * Self.padding)
        if questionForm != nil {
            // The raw input (when expanded) keeps a modest height; the form takes what is left, up
            // to its natural height, and scrolls beyond that. Neither pushes another row out of the pane.
            let detailsHeight = detailsExpanded ? min(inputView.contentHeight(forWidth: inner), Self.detailsInputHeight) : 0
            let chrome = rows(width: width, inputHeight: detailsHeight, formHeight: 0)
            let natural = naturalFormHeight(forWidth: inner)
            let floorHeight = min(Self.minimumFormHeight, max(0, hardMaxHeight - chrome))
            inputHeight = detailsHeight
            formHeight = min(natural, max(floorHeight, maxHeight - chrome))
            return rows(width: width, inputHeight: inputHeight, formHeight: formHeight)
        }
        let chrome = rows(width: width, inputHeight: 0)
        let natural = inputView.contentHeight(forWidth: inner)
        // The input keeps at least a few lines unless the pane itself is too short for that:
        // then it gives way before any other row is pushed out of the pane.
        let floorHeight = min(Self.minimumInputHeight, max(0, hardMaxHeight - chrome))
        inputHeight = min(natural, max(floorHeight, maxHeight - chrome))
        return rows(width: width, inputHeight: inputHeight)
    }

    /// The form's height at the width its scroll view gives it (cached: measuring long text is not free).
    private func naturalFormHeight(forWidth inner: CGFloat) -> CGFloat {
        guard let form = questionForm else { return 0 }
        let width = max(40, inner - Self.formScrollerGutter)
        if let cached = formNatural, cached.width == width { return cached.height }
        let height = form.contentHeight(forWidth: width)
        formNatural = (width, height)
        return height
    }

    override func layout() {
        super.layout()
        _ = rows(width: bounds.width, inputHeight: inputHeight, formHeight: formHeight, apply: true)
    }

    // MARK: Listing

    var listing: ApprovalCardListing {
        let texts = inputView.displayedLines
        let lines = model.allLines.enumerated().map { i, line in
            ApprovalCardListing.Line(number: line.number,
                                     text: texts.indices.contains(i) ? texts[i] : "",
                                     kind: line.kind.rawValue,
                                     separators: line.separators)
        }
        var options: [ApprovalCardListing.Option] = []
        for control in self.options.controls {
            switch control {
            case .deny:
                options.append(.init(id: control.rawValue, enabled: denyButton.isEnabled, label: denyButton.title))
            case .denyWithNote:
                options.append(.init(id: control.rawValue, enabled: denyMoreButton?.isEnabled ?? false, label: "Deny with a note…"))
            case .denyAndStop:
                options.append(.init(id: control.rawValue, enabled: denyAndStopButton?.isEnabled ?? false, label: denyAndStopButton?.title ?? ""))
            case .allowOnce:
                options.append(.init(id: control.rawValue, enabled: allowButton?.isEnabled ?? false, label: allowButton?.title ?? ""))
            case .answerQuestions:
                options.append(.init(id: control.rawValue, enabled: submitButton?.isEnabled ?? false, label: submitButton?.title ?? ""))
            }
        }
        return ApprovalCardListing(
            requestID: request.id, focus: request.tag,
            agent: ApprovalDisplayModel.contextText(ApprovalKinds.asker(for: request), keepingLineFeeds: false),
            tool: request.toolName, headline: headlineLabel.stringValue,
            input: shownInput(from: texts), lines: lines,
            commandCount: model.commandCount, invisibleCount: model.invisibleCount,
            nonAsciiCount: model.nonAsciiCount,
            banner: bannerLabel.isHidden ? nil : bannerLabel.stringValue,
            reasonLine: ApprovalDisplayModel.contextText(request.reason.text), options: options,
            defaultToNoKind: self.options.defaultsToDeny,
            secondsLeft: countdown.secondsLeft, state: stateDescription,
            displayFailed: inputView.displayFailed, questions: questionListing)
    }

    /// What the form shows and has chosen, for `approvals list`.
    private var questionListing: [ApprovalCardListing.Question]? {
        guard let questions = options.questions, let form = questionForm else { return nil }
        return questions.enumerated().map { q, question in
            let selection = form.selections[q]
            return ApprovalCardListing.Question(
                question: question.question, header: question.header, multiSelect: question.multiSelect,
                options: question.options.enumerated().map { o, option in
                    .init(label: option.label, description: option.description, selected: selection.selected.contains(o))
                },
                otherText: selection.otherText, otherSelected: selection.otherChosen)
        }
    }

    /// The input as the views hold it: the display lines' text from the text view, joined as in
    /// the original (no newline at a separator cut). Extra fields are not part of it.
    private func shownInput(from texts: [String]) -> String {
        var out = ""
        for (i, line) in model.lines.enumerated() where texts.indices.contains(i) {
            if i > 0 && !line.cont { out += "\n" }
            out += texts[i]
        }
        return out
    }

    // MARK: Window

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { countdown.stop() } else { countdown.start() }
        startArming()
    }

    /// The delay runs from the moment the card is on screen, not from when it was built; leaving
    /// the window disarms it again.
    private func startArming() {
        guard armDelay > 0 else { return }
        armGeneration += 1
        let generation = armGeneration
        isArmed = false
        refresh()
        guard window != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + armDelay) { [weak self] in
            guard let self, self.armGeneration == generation, self.window != nil else { return }
            self.isArmed = true
            self.refresh()
        }
    }

    // MARK: Actions

    @objc private func controlPressed(_ sender: ApprovalButton) {
        guard let control = ApprovalControl(rawValue: sender.identifier?.rawValue ?? "") else { return }
        guard isHuman(on: sender, control: control.rawValue) else { return }
        switch control {
        case .deny: submit(ApprovalDecisionWire(kind: .deny))
        case .denyAndStop: submit(ApprovalDecisionWire(kind: .denyAndStop))
        case .allowOnce:
            // Disabled controls don't fire, but the rule is checked where it matters.
            guard canAllow else { return }
            submit(ApprovalDecisionWire(kind: .allowOnce))
        case .denyWithNote: sendNote(from: sender)
        case .answerQuestions:
            // Disabled controls don't fire, but the rule is checked where it matters.
            guard canSubmit, let answers = questionForm?.answers else { return }
            submit(ApprovalDecisionWire(kind: .answerQuestions, answers: answers))
        }
    }

    @objc private func detailsPressed(_ sender: ApprovalButton) {
        guard isHuman(on: sender, control: "details") else { return }
        detailsExpanded.toggle()
        applyDetails()
        needsLayout = true
        onNeedsLayout?()
    }

    /// Show or hide the raw input of a question card (and say which, for VoiceOver).
    private func applyDetails() {
        inputView.isHidden = questionForm != nil && !detailsExpanded
        detailsButton?.setAccessibilityValue(detailsExpanded ? "expanded" : "collapsed")
        detailsButton?.toolTip = detailsExpanded ? "Hide the raw request" : "Show the raw request"
    }

    @objc private func showMoreDenyOptions(_ sender: ApprovalButton) {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Deny with a note…", action: #selector(openNoteRow), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func openNoteRow() {
        guard state == .pending else { return }
        noteRow.isHidden = false
        needsLayout = true
        onNeedsLayout?()
        window?.makeFirstResponder(noteField)
    }

    @objc private func cancelNote() {
        noteField.stringValue = ""
        noteRow.isHidden = true
        needsLayout = true
        onNeedsLayout?()
    }

    @objc private func noteSendPressed(_ sender: NSControl) {
        guard isHuman(on: sender, control: ApprovalControl.denyWithNote.rawValue) else { return }
        sendNote(from: sender)
    }

    private func sendNote(from sender: NSControl) {
        let note = noteField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        submit(ApprovalDecisionWire(kind: .deny, note: note.isEmpty ? nil : String(note.prefix(500))))
    }

    private func submit(_ decision: ApprovalDecisionWire) {
        store.answer(request.id, decision, windowID: windowID())
    }

    /// Only a person may answer an agent. A refused gesture does nothing here (the card
    /// stays) and is reported to the daemon, which logs it.
    private func isHuman(on control: NSView, control name: String) -> Bool {
        switch permit(control) {
        case .human(let pid, let src):
            cardLog.notice("approval \(self.request.id, privacy: .public) \(name, privacy: .public) pressed by a user gesture (event source pid \(pid.map(String.init) ?? "none", privacy: .public), state \(src.map(String.init) ?? "none", privacy: .public))")
            return true
        case .refused(let reason):
            cardLog.notice("synthetic input refused: \(reason.rawValue, privacy: .public) on approval \(self.request.id, privacy: .public) control \(name, privacy: .public)")
            let channel: ApprovalRefusalChannel
            switch reason {
            case .appControl: channel = .appControl
            case .accessibilityPress: channel = .accessibility
            default: channel = .unknown
            }
            store.reportRefusal(requestId: request.id, control: name, channel: channel)
            return false
        }
    }

    // MARK: Building

    private func buildContent() {
        // Header
        headlineLabel.lineBreakMode = .byTruncatingTail
        let headline = ApprovalKinds.headline(for: request)
        setContext(headlineLabel, headline, wraps: false, font: .systemFont(ofSize: 13, weight: .semibold), color: ApprovalPalette.commandText)
        headlineLabel.toolTip = ApprovalDisplayModel.contextText(headline, keepingLineFeeds: false)

        moreLabel.font = .systemFont(ofSize: 11)
        moreLabel.textColor = ApprovalPalette.mutedText
        moreLabel.alignment = .right

        configureWrapping(whyLabel, lines: 2)
        setContext(whyLabel, request.reason.text, prefix: "Why: ", font: .systemFont(ofSize: 11), color: ApprovalPalette.mutedText)
        whyLabel.toolTip = ApprovalDisplayModel.contextText(request.reason.text)

        inLabel.font = .systemFont(ofSize: 11)
        inLabel.textColor = ApprovalPalette.mutedText
        inLabel.lineBreakMode = .byTruncatingMiddle
        if let cwd = request.cwd, !cwd.isEmpty {
            let shown = ApprovalKinds.homeAbbreviated(cwd, home: NSHomeDirectory())
            setContext(inLabel, shown, prefix: "In: ", wraps: false, font: .systemFont(ofSize: 11), color: ApprovalPalette.mutedText)
            inLabel.toolTip = ApprovalDisplayModel.contextText(cwd, keepingLineFeeds: false)
        } else {
            inLabel.isHidden = true
        }

        // Never cut, however many warnings are stacked: a warning is the point of the banner. It wraps and grows.
        configureWrapping(bannerLabel, lines: 0)
        bannerLabel.lineBreakMode = .byWordWrapping
        bannerLabel.cell?.truncatesLastVisibleLine = false
        bannerLabel.textColor = ApprovalPalette.warning
        bannerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        if let banner = model.banner(toolKind: request.toolKind) {
            bannerLabel.stringValue = banner
        } else {
            bannerLabel.isHidden = true
        }

        countLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        countLabel.textColor = ApprovalPalette.commandText
        if let line = ApprovalKinds.commandCountLine(for: request) {
            countLabel.stringValue = line
        } else {
            countLabel.isHidden = true
        }

        // The agent's claim: below the exact input, muted and labelled.
        configureWrapping(agentSaysLabel, lines: 4)
        if let description = request.description, !description.isEmpty {
            setContext(agentSaysLabel, description, prefix: "Agent says: “", suffix: "”",
                       font: .systemFont(ofSize: 11), color: ApprovalPalette.mutedText)
            agentSaysLabel.toolTip = ApprovalDisplayModel.contextText(description)
        } else {
            agentSaysLabel.isHidden = true
        }

        configureWrapping(noticeLabel, lines: 2)
        noticeLabel.textColor = ApprovalPalette.commandText
        if let notice = options.notice {
            noticeLabel.stringValue = notice
        } else {
            noticeLabel.isHidden = true
        }

        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingTail

        // Note row (Deny with a note…)
        noteField.placeholderString = "Tell the agent why (one line)"
        noteField.font = .systemFont(ofSize: 12)
        noteField.target = self
        noteField.action = #selector(noteSendPressed(_:))
        noteField.setAccessibilityLabel("Note for the agent")
        configure(noteSend, id: ApprovalControl.denyWithNote.rawValue, action: #selector(noteSendPressed(_:)))
        noteSend.setAccessibilityLabel("Deny and send the note")
        configure(noteCancel, id: "cancel_note", action: #selector(cancelNote))
        for v in [noteField, noteSend, noteCancel] { noteRow.addSubview(v) }
        noteRow.isHidden = true

        // AskUserQuestion: the form replaces the input (Why is about a rule, not a question).
        if let questions = options.questions {
            let form = ApprovalQuestionFormView(questions: questions)
            form.permit = { [weak self] control, name in self?.isHuman(on: control, control: name) ?? false }
            form.onChange = { [weak self] in self?.refresh() }
            questionForm = form
            formScroll.documentView = form
            formScroll.hasVerticalScroller = true
            formScroll.hasHorizontalScroller = false
            formScroll.horizontalScrollElasticity = .none
            formScroll.scrollerStyle = .overlay
            formScroll.autohidesScrollers = true
            formScroll.drawsBackground = false
            formScroll.borderType = .noBorder
            whyLabel.isHidden = true
            let details = ApprovalButton(title: "Details", target: self, action: #selector(detailsPressed(_:)))
            configure(details, id: "details", action: #selector(detailsPressed(_:)))
            details.title = "Details"
            details.controlSize = .small
            details.font = .systemFont(ofSize: 11)
            details.setAccessibilityLabel("Details: the raw request")
            detailsButton = details
            addSubview(details)
        }

        // Buttons: Deny, ▾, Deny & stop, ... Allow once
        denyButton = makeButton(title: "Deny", control: .deny, label: "Deny",
                                tip: "Don't run it. The agent is told and carries on.")
        if options.controls.contains(.denyWithNote) {
            let more = ApprovalButton(title: "▾", target: self, action: #selector(showMoreDenyOptions(_:)))
            configure(more, id: ApprovalControl.denyWithNote.rawValue, action: #selector(showMoreDenyOptions(_:)))
            more.title = "▾"
            more.setAccessibilityLabel("More ways to deny")
            more.toolTip = "Deny with a note…"
            denyMoreButton = more
            buttonRow.addSubview(more)
        }
        if options.controls.contains(.denyAndStop) {
            denyAndStopButton = makeButton(title: "Deny & stop", control: .denyAndStop, label: "Deny and stop",
                                           tip: "Don't run it and end the agent's turn.")
        }
        if options.controls.contains(.answerQuestions) {
            submitButton = makeButton(title: "Submit", control: .answerQuestions, label: "Submit answers",
                                      tip: "Send your answers to the agent.")
        }
        if options.offersAllowOnce {
            allowButton = makeButton(title: "Allow once", control: .allowOnce,
                                     label: ApprovalKinds.allowOnceAccessibilityLabel(summary: model.summary,
                                                                                      commandCount: model.commandCount),
                                     tip: "Run this one call only.")
            allowButton?.lineBreakMode = .byTruncatingTail
        }

        for v in [headlineLabel, moreLabel, countdown.label, whyLabel, inLabel, bannerLabel, countLabel,
                  formScroll, inputView, agentSaysLabel, noticeLabel, noteRow, statusLabel, buttonRow] {
            v.translatesAutoresizingMaskIntoConstraints = true
            addSubview(v)
        }
        formScroll.isHidden = questionForm == nil
        applyDetails()
        inputView.onShownEveryLine = { [weak self] in self?.refresh() }
        inputView.onDisplayFailed = { [weak self] in self?.showDisplayFailed() }
    }

    static let displayFailedBanner = "Can't display this input safely. Deny it."

    /// The input could not be laid out: say so, keep Allow once off (`canAllow`), keep every Deny.
    private func showDisplayFailed() {
        // Say it first, and keep every warning the card already had (invisible characters, non-ASCII,
        // unverified input): the failure line is added to the banner, never put in its place.
        let existing = model.banner(toolKind: request.toolKind)
        bannerLabel.stringValue = [Self.displayFailedBanner, existing].compactMap { $0 }.joined(separator: "\n")
        bannerLabel.maximumNumberOfLines = 0   // grows with the stacked warnings; `preferredHeight` re-measures
        bannerLabel.isHidden = false
        refresh()
        needsLayout = true
        onNeedsLayout?()
    }

    private func makeButton(title: String, control: ApprovalControl, label: String, tip: String) -> ApprovalButton {
        let b = ApprovalButton(title: title, target: self, action: #selector(controlPressed(_:)))
        configure(b, id: control.rawValue, action: #selector(controlPressed(_:)))
        b.title = title
        b.setAccessibilityLabel(label)
        b.toolTip = tip
        buttonRow.addSubview(b)
        return b
    }

    private func configure(_ button: ApprovalButton, id: String, action: Selector) {
        button.identifier = NSUserInterfaceItemIdentifier(id)
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = .systemFont(ofSize: 12)
        button.isBordered = true
        button.focusRingType = .default
        button.setButtonType(.momentaryPushIn)
    }

    /// Show `text` in `label` with every hidden or direction-changing character as a visible token
    /// (`ApprovalContextText`). A line feed is kept as a line break only where the label `wraps`.
    private func setContext(_ label: NSTextField, _ text: String, prefix: String = "", suffix: String = "",
                            wraps: Bool = true, font: NSFont, color: NSColor) {
        ApprovalContextText.set(label, text, prefix: prefix, suffix: suffix, wraps: wraps, font: font, color: color)
    }

    private func configureWrapping(_ label: NSTextField, lines: Int) {
        label.font = .systemFont(ofSize: 11)
        label.textColor = ApprovalPalette.mutedText
        label.maximumNumberOfLines = lines
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.isSelectable = true
    }

    // MARK: Refresh (text and enabled flags only)

    private func refresh() {
        let pending = state == .pending
        // After a refused answer Deny stays available (a retry, one at a time, by a person's press):
        // otherwise the agent waits out the 15 minutes. Nothing else is: Allow is never re-sent.
        var denyable = pending
        if case .notSent = state { denyable = true }
        denyButton.isEnabled = denyable
        denyMoreButton?.isEnabled = pending
        denyAndStopButton?.isEnabled = pending
        if let allow = allowButton {
            allow.title = allowLabel
            allow.isEnabled = pending && canAllow
            allow.setAccessibilityHelp(canAllow ? nil : inputView.displayFailed
                ? "This input can't be displayed safely. Deny it."
                : "Scroll the input to its end before allowing")
        }
        submitButton?.isEnabled = canSubmit
        submitButton?.setAccessibilityHelp(canSubmit ? nil : "Answer every question to submit")
        questionForm?.isEnabled = pending
        switch state {
        case .pending:
            if !model.isVerified {
                statusLabel.stringValue = ApprovalDisplayModel.roundTripFailureLabel
                statusLabel.textColor = ApprovalPalette.warning
            } else if questionForm?.hasOverLimitOther == true {
                statusLabel.stringValue = "Answer too long (max \(ApprovalQuestions.maxOtherCharacters))"
                statusLabel.textColor = ApprovalPalette.warning
            } else {
                statusLabel.stringValue = ""
            }
        case .inFlight(let kind):
            switch kind {
            case .allowOnce: statusLabel.stringValue = "Allowing…"
            case .answerQuestions: statusLabel.stringValue = "Sending answers…"
            default: statusLabel.stringValue = "Denying…"
            }
            statusLabel.textColor = ApprovalPalette.mutedText
        case .notSent(let text):
            statusLabel.stringValue = text
            statusLabel.textColor = ApprovalPalette.warning
        case .ended(let text):
            statusLabel.stringValue = text
            statusLabel.textColor = ApprovalPalette.commandText
        }
    }

    /// `+2 more` (the other requests this focus holds). Only the label's text changes.
    func setMoreCount(_ count: Int) {
        let text = count > 0 ? "+\(count) more" : ""
        guard moreLabel.stringValue != text else { return }
        moreLabel.stringValue = text
        moreLabel.setAccessibilityLabel(count > 0 ? "\(count) more approval request\(count == 1 ? "" : "s") waiting" : nil)
        needsLayout = true
    }

    private var stateDescription: String {
        switch state {
        case .pending: return "pending"
        case .inFlight: return "sending"
        case .notSent(let text): return text
        case .ended(let text): return text
        }
    }

    // MARK: Rows

    private func wrappedHeight(_ label: NSTextField, width: CGFloat) -> CGFloat {
        guard !label.isHidden, let cell = label.cell else { return 0 }
        let size = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000))
        return ceil(size.height)
    }

    /// Lay the rows out top to bottom for `width`; with `apply` set their frames. Returns the total height.
    @discardableResult
    private func rows(width: CGFloat, inputHeight: CGFloat, formHeight: CGFloat = 0, apply: Bool = false) -> CGFloat {
        let pad = Self.padding
        let inner = max(40, width - 2 * pad)
        var y = pad

        func place(_ view: NSView, height: CGFloat, x: CGFloat = pad, width w: CGFloat? = nil) {
            if apply { view.frame = NSRect(x: x, y: y, width: w ?? inner, height: height) }
            y += height + Self.rowGap
        }

        // Header: headline, "+N more", countdown (fixed width).
        let headerHeight: CGFloat = 18
        if apply {
            let countdownWidth = ApprovalCountdownLabel.width
            let moreWidth: CGFloat = moreLabel.stringValue.isEmpty ? 0 : 64
            countdown.label.frame = NSRect(x: pad + inner - countdownWidth, y: y + 1, width: countdownWidth, height: 16)
            moreLabel.frame = NSRect(x: pad + inner - countdownWidth - moreWidth - 4, y: y + 1, width: moreWidth, height: 16)
            moreLabel.isHidden = moreWidth == 0
            let headlineWidth = max(40, inner - countdownWidth - (moreWidth > 0 ? moreWidth + 4 : 0) - 8)
            headlineLabel.frame = NSRect(x: pad, y: y, width: headlineWidth, height: headerHeight)
        }
        y += headerHeight + Self.rowGap

        if !whyLabel.isHidden { place(whyLabel, height: wrappedHeight(whyLabel, width: inner)) }
        if !inLabel.isHidden { place(inLabel, height: 14) }
        if !bannerLabel.isHidden { place(bannerLabel, height: wrappedHeight(bannerLabel, width: inner)) }
        if !countLabel.isHidden { place(countLabel, height: 14) }
        if let form = questionForm {
            if apply {
                form.frame = NSRect(x: 0, y: 0, width: max(40, inner - Self.formScrollerGutter),
                                    height: naturalFormHeight(forWidth: inner))
            }
            place(formScroll, height: formHeight)
            if !agentSaysLabel.isHidden { place(agentSaysLabel, height: wrappedHeight(agentSaysLabel, width: inner)) }
            if let details = detailsButton { place(details, height: 20, width: 72) }
            if detailsExpanded { place(inputView, height: inputHeight) }
        } else {
            place(inputView, height: inputHeight)
            if !agentSaysLabel.isHidden { place(agentSaysLabel, height: wrappedHeight(agentSaysLabel, width: inner)) }
        }
        if !noticeLabel.isHidden { place(noticeLabel, height: wrappedHeight(noticeLabel, width: inner)) }
        if !noteRow.isHidden {
            if apply { layoutNoteRow(width: inner) }
            place(noteRow, height: 24)
        }
        place(statusLabel, height: 16)   // always reserved: an outcome appears here without moving anything

        if apply { layoutButtons(width: inner) }
        place(buttonRow, height: Self.buttonHeight)

        return y - Self.rowGap + pad
    }

    private func layoutNoteRow(width: CGFloat) {
        let sendWidth: CGFloat = 56, cancelWidth: CGFloat = 64
        noteSend.frame = NSRect(x: width - sendWidth, y: 0, width: sendWidth, height: 24)
        noteCancel.frame = NSRect(x: width - sendWidth - cancelWidth - 4, y: 0, width: cancelWidth, height: 24)
        noteField.frame = NSRect(x: 0, y: 1, width: max(40, width - sendWidth - cancelWidth - 12), height: 22)
    }

    private func layoutButtons(width: CGFloat) {
        var x: CGFloat = 0
        denyButton.frame = NSRect(x: x, y: 0, width: 64, height: Self.buttonHeight)
        x += 64
        if let more = denyMoreButton {
            more.frame = NSRect(x: x, y: 0, width: 28, height: Self.buttonHeight)
            x += 28
        }
        if let stop = denyAndStopButton {
            x += 8
            stop.frame = NSRect(x: x, y: 0, width: 104, height: Self.buttonHeight)
            x += 104
        }
        if let allow = allowButton {
            let w = min(Self.allowButtonWidth, max(100, width - x - 16))
            allow.frame = NSRect(x: width - w, y: 0, width: w, height: Self.buttonHeight)
        }
        if let submit = submitButton {
            let w = min(Self.submitButtonWidth, max(72, width - x - 16))
            submit.frame = NSRect(x: width - w, y: 0, width: w, height: Self.buttonHeight)
        }
    }
}
