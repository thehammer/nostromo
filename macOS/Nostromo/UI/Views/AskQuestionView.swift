import AppKit

// MARK: - AskQuestionView

/// Native card rendered when an agent calls `AskUserQuestion`.
///
/// The claude CLI can't surface interactive UI in non-interactive (streaming) mode —
/// it returns "Answer questions?" as a tool error. We intercept the tool_use input
/// JSON in ChatModels and render it here instead. Tapping an option sends it as a
/// new user message, so the agent gets the answer and continues naturally.
///
/// ## Why this lives outside `ReplView.swift`
///
/// Turn views are destroyed routinely now: evicted when they leave the
/// materialized window, and released wholesale on any pane width change over
/// 0.5 pt. Before virtualization they were never released, so this view's own
/// `answered` flag was sufficient. It is not any more — a re-materialized card
/// was rebuilt with `answered == false`, full-opacity enabled buttons, and a live
/// `onAnswer` → `onSend` → `session.send(_:)` path. One stray click on a card the
/// operator had already answered sent a **second message into a live agent
/// session**.
///
/// So the answer is held by `TurnInteractionStore`, outside every view, and
/// handed back in at construction. Extracting the class here is what lets that
/// restore path be tested: it depends only on `Theme`, `AskQuestionData` and
/// AppKit, all of which are already compiled into the logic test bundle.
final class AskQuestionView: NSView {

    /// Fired when the operator answers. Carries the chosen option's **index** as
    /// well as the reply, so the caller can persist which option was chosen.
    /// Identifying by index rather than label matters: two options can carry the
    /// same label, and `OptionButton` is already tagged with its index.
    var onAnswer: ((_ reply: String, _ optionIndex: Int) -> Void)?

    private let data: AskQuestionData
    private var answered = false
    private var headerChip: NSTextField?

    /// - Parameter answeredOptionIndex: the option the operator already chose,
    ///   restored from `TurnInteractionState`. Non-nil means this card is
    ///   answered: it renders chosen and is inert, and **never** calls
    ///   `onAnswer`. Deliberately has no default value, so the compiler is the
    ///   wiring check for the single construction site in `ChatTurnView`.
    init(data: AskQuestionData, answeredOptionIndex: Int?) {
        self.data = data
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        layer?.cornerRadius    = 8
        layer?.borderWidth     = 1
        layer?.borderColor     = Theme.cornflower.withAlphaComponent(0.3).cgColor

        // Header chip (e.g. "Action")
        var prevAnchor: NSLayoutYAxisAnchor? = nil
        var topConstant: CGFloat = 12

        if !data.header.isEmpty {
            let chip = NSTextField(labelWithString: data.header.uppercased())
            chip.font      = .systemFont(ofSize: 9, weight: .semibold)
            chip.textColor = Theme.cornflower
            chip.translatesAutoresizingMaskIntoConstraints = false
            addSubview(chip)
            NSLayoutConstraint.activate([
                chip.topAnchor.constraint(equalTo: topAnchor, constant: topConstant),
                chip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            ])
            headerChip  = chip
            prevAnchor  = chip.bottomAnchor
            topConstant = 6
        }

        // Question text
        let qLabel = NSTextField(labelWithString: data.question)
        qLabel.font                 = .systemFont(ofSize: 13)
        qLabel.textColor            = Theme.fg
        qLabel.lineBreakMode        = .byWordWrapping
        qLabel.maximumNumberOfLines = 0
        qLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        qLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(qLabel)
        NSLayoutConstraint.activate([
            qLabel.topAnchor.constraint(equalTo: prevAnchor ?? topAnchor, constant: topConstant),
            qLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            qLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
        prevAnchor = qLabel.bottomAnchor

        // Option buttons
        if data.options.isEmpty {
            // No options — render a plain text input affordance hint
            let hint = NSTextField(labelWithString: "Reply below ↓")
            hint.font      = .systemFont(ofSize: 11)
            hint.textColor = Theme.fgMuted
            hint.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hint)
            NSLayoutConstraint.activate([
                hint.topAnchor.constraint(equalTo: prevAnchor!, constant: 10),
                hint.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
                hint.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            ])
        } else {
            // Divider
            let divider = NSView()
            divider.wantsLayer = true
            divider.layer?.backgroundColor = Theme.borderInactive.withAlphaComponent(0.4).cgColor
            divider.translatesAutoresizingMaskIntoConstraints = false
            addSubview(divider)
            NSLayoutConstraint.activate([
                divider.topAnchor.constraint(equalTo: prevAnchor!, constant: 10),
                divider.leadingAnchor.constraint(equalTo: leadingAnchor),
                divider.trailingAnchor.constraint(equalTo: trailingAnchor),
                divider.heightAnchor.constraint(equalToConstant: 1),
            ])
            prevAnchor = divider.bottomAnchor

            for (idx, option) in data.options.enumerated() {
                let btn = OptionButton(option: option, tag: idx)
                btn.target = self
                btn.action = #selector(optionTapped(_:))
                btn.translatesAutoresizingMaskIntoConstraints = false
                addSubview(btn)
                NSLayoutConstraint.activate([
                    btn.topAnchor.constraint(equalTo: prevAnchor!, constant: idx == 0 ? 0 : 0),
                    btn.leadingAnchor.constraint(equalTo: leadingAnchor),
                    btn.trailingAnchor.constraint(equalTo: trailingAnchor),
                ])
                prevAnchor = btn.bottomAnchor

                // Row separator between options
                if idx < data.options.count - 1 {
                    let sep = NSView()
                    sep.wantsLayer = true
                    sep.layer?.backgroundColor = Theme.borderInactive.withAlphaComponent(0.25).cgColor
                    sep.translatesAutoresizingMaskIntoConstraints = false
                    addSubview(sep)
                    NSLayoutConstraint.activate([
                        sep.topAnchor.constraint(equalTo: prevAnchor!),
                        sep.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
                        sep.trailingAnchor.constraint(equalTo: trailingAnchor),
                        sep.heightAnchor.constraint(equalToConstant: 1),
                    ])
                    prevAnchor = sep.bottomAnchor
                }
            }

            prevAnchor?.constraint(equalTo: bottomAnchor).isActive = true
        }

        if let index = answeredOptionIndex { restoreAnswered(optionIndex: index) }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Answering

    @objc private func optionTapped(_ sender: OptionButton) {
        guard !answered else { return }
        answered = true
        applyChosen(sender, animated: true)
        // Claude's AskUserQuestion call always errors in -p mode ("Answer questions?").
        // The user's answer arrives as a new user turn, not a proper tool result.
        // Send rich context so claude can't miss the connection.
        let reply: String
        if data.question.isEmpty {
            reply = sender.optionLabel
        } else {
            reply = "\(sender.optionLabel)\n\n(This answers your question: \"\(data.question)\" — please proceed.)"
        }
        onAnswer?(reply, sender.tag)
    }

    /// Re-arm nothing. Put the card back into the state the operator left it in,
    /// without sending anything and without animating: this runs during
    /// `init`, from a materialization pass, and must be a synchronous,
    /// side-effect-free operation.
    private func restoreAnswered(optionIndex: Int) {
        answered = true
        let buttons = subviews.compactMap { $0 as? OptionButton }
        guard let chosen = buttons.first(where: { $0.tag == optionIndex }) else {
            // The recorded index no longer names an option (the card's content
            // changed underneath it). Inert is still the right direction — an
            // armed already-answered card is the failure this whole mechanism
            // exists to prevent — so disable without claiming a choice.
            buttons.forEach { $0.isEnabled = false }
            return
        }
        applyChosen(chosen, animated: false)
    }

    /// The chosen-state visuals: every option dimmed and disabled except the
    /// chosen one, its checkmark and row tint applied, the header chip flipped to
    /// APPROVED, and the card border turned sage.
    private func applyChosen(_ sender: OptionButton, animated: Bool) {
        // Dim all buttons to show selection; disable all to prevent re-tapping.
        subviews.compactMap { $0 as? OptionButton }.forEach { btn in
            btn.alphaValue = btn === sender ? 1.0 : 0.35
            btn.isEnabled  = false
        }
        let paint = { [weak self] in
            guard let self else { return }
            sender.markChosen(animated: animated)
            self.headerChip?.stringValue = "APPROVED"
            self.headerChip?.textColor   = Theme.sage
            self.layer?.borderColor      = Theme.sage.withAlphaComponent(0.5).cgColor
        }
        guard animated else { paint(); return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration       = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            paint()
        }
    }

    // MARK: - OptionButton

    private class OptionButton: NSButton {

        let optionLabel: String

        private var chosen = false
        private let checkmark: NSImageView
        private let label: NSTextField
        /// Whether this option carries the "(recommended)" suffix — tracked so
        /// `markChosen()` can rebuild the attributed string instead of clobbering
        /// its mixed fonts with a uniform `.font` assignment.
        private let recommended: Bool

        init(option: AskQuestionData.Option, tag: Int) {
            optionLabel = option.label
            recommended = option.recommended

            // Checkmark — hidden by default; space is always reserved so revealing
            // it causes no layout shift (label leading is anchored to checkmark.trailing).
            let check = NSImageView()
            check.image = NSImage(systemSymbolName: "checkmark.circle.fill",
                                  accessibilityDescription: "chosen")
            check.contentTintColor = Theme.sage
            check.isHidden  = true
            check.alphaValue = 0
            check.translatesAutoresizingMaskIntoConstraints = false
            checkmark = check

            let labelFont = NSFont.systemFont(ofSize: 12, weight: .medium)
            let lbl: NSTextField
            if option.recommended {
                // Append a muted "(recommended)" suffix so Perri's pick stands out
                // without implying the other options are wrong.
                let attributed = NSMutableAttributedString(
                    string: option.label,
                    attributes: [.font: labelFont, .foregroundColor: Theme.fg])
                attributed.append(NSAttributedString(
                    string: " (recommended)",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                        .foregroundColor: Theme.fgMuted,
                    ]))
                lbl = NSTextField(labelWithAttributedString: attributed)
            } else {
                lbl = NSTextField(labelWithString: option.label)
                lbl.font      = labelFont
                lbl.textColor = Theme.fg
            }
            lbl.translatesAutoresizingMaskIntoConstraints = false
            label = lbl

            super.init(frame: .zero)
            self.tag      = tag
            title         = ""   // NSButton defaults to "Button" — we render our own label/description subviews
            isBordered    = false
            wantsLayer    = true

            var subs: [NSView] = [checkmark, label]
            var constraints: [NSLayoutConstraint] = [
                // Checkmark — leading edge, vertically centred, fixed 14×14
                checkmark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
                checkmark.centerYAnchor.constraint(equalTo: centerYAnchor),
                checkmark.widthAnchor.constraint(equalToConstant: 14),
                checkmark.heightAnchor.constraint(equalToConstant: 14),
                // Label anchored to checkmark trailing so its position is stable
                // regardless of checkmark visibility.
                label.leadingAnchor.constraint(equalTo: checkmark.trailingAnchor, constant: 8),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
            ]

            if !option.description.isEmpty {
                let desc = NSTextField(labelWithString: option.description)
                desc.font                 = .systemFont(ofSize: 11)
                desc.textColor            = Theme.fgMuted
                desc.lineBreakMode        = .byTruncatingTail
                desc.maximumNumberOfLines = 1
                desc.translatesAutoresizingMaskIntoConstraints = false
                subs.append(desc)
                constraints += [
                    desc.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
                    desc.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                    desc.centerYAnchor.constraint(equalTo: centerYAnchor),
                ]
            } else {
                constraints.append(label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14))
            }

            for sub in subs { addSubview(sub) }
            NSLayoutConstraint.activate(constraints + [
                heightAnchor.constraint(equalToConstant: 36),
            ])
        }

        required init?(coder: NSCoder) { fatalError() }

        /// Applies chosen-state visuals: checkmark, semibold label, green row tint.
        ///
        /// - Parameter animated: when true this must be called from within an
        ///   `NSAnimationContext.runAnimationGroup` block. When false — the
        ///   restore path — it touches neither `animator()` nor
        ///   `NSAnimationContext`, so rebuilding an answered card is synchronous
        ///   and has no side effects to wait on.
        func markChosen(animated: Bool) {
            chosen = true
            checkmark.isHidden = false
            if animated {
                checkmark.animator().alphaValue = 1
            } else {
                checkmark.alphaValue = 1
            }
            let chosenFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
            if recommended {
                // Setting `.font` directly on an attributed NSTextField flattens
                // all runs to one style, which would swallow the muted
                // "(recommended)" suffix — rebuild the attributed string instead.
                let attributed = NSMutableAttributedString(
                    string: optionLabel,
                    attributes: [.font: chosenFont, .foregroundColor: Theme.fg])
                attributed.append(NSAttributedString(
                    string: " (recommended)",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                        .foregroundColor: Theme.fgMuted,
                    ]))
                label.attributedStringValue = attributed
            } else {
                label.font = chosenFont
            }
            layer?.backgroundColor = Theme.sage.withAlphaComponent(0.12).cgColor
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach { removeTrackingArea($0) }
            // .inVisibleRect restricts tracking to the visible portion of the view
            // and re-evaluates on scroll — prevents spurious events for off-screen rows.
            // rect is ignored when .inVisibleRect is set.
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self, userInfo: nil
            ))
        }

        override func mouseEntered(with event: NSEvent) {
            guard isEnabled, !chosen else { return }
            layer?.backgroundColor = Theme.cornflower.withAlphaComponent(0.12).cgColor
        }

        override func mouseExited(with event: NSEvent) {
            guard !chosen else { return }
            layer?.backgroundColor = nil
        }
    }
}
