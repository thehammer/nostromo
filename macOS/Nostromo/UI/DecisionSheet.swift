import AppKit

/// A daemon-driven decision modal: an agent poses a question with a fixed set
/// of choices, and this sheet returns the operator's pick (or an explicit
/// dismissal) back to the caller.
///
/// Presented via `window.beginSheet(_:)` from `MainLayout`, never via
/// `alert.runModal()` / `NSApp.runModal(for:)`. A free-floating modal has no
/// window association, so it can end up stranded on another Space/display
/// with no visible way to dismiss it — which blocks the whole app's main
/// thread indefinitely (it looks exactly like a hang). A sheet is always
/// anchored to its parent window and resolves asynchronously, so it can't
/// wander off or block the app. (Same rationale as the three existing sites:
/// `ReplView.newSessionTapped`, `MotherView`, and `CreateFocusSheet` — see
/// their comments.)
final class DecisionSheet: NSWindowController, NSWindowDelegate {

    /// One offered choice. `id` is what travels back over the wire; `label`
    /// (and optional `detail`) is what the operator reads.
    struct Choice {
        let id: String
        let label: String
        let detail: String?
    }

    private let requestId: String
    private let store: DecisionStore
    private let onAnswer: (_ choiceId: String?) -> Void

    /// Guards every resolution path (a choice tap, the dismiss button, and the
    /// titlebar close box all fire through `resolve(choiceId:)`) so exactly one
    /// of them can ever call `onAnswer`, no matter which one the operator uses
    /// or how many times AppKit re-delivers a close notification.
    private var answered = false

    private var choiceButtons: [(id: String, button: NSButton)] = []

    /// - Parameters:
    ///   - answeredChoiceId: the choice already recorded for `requestId` in
    ///     `store`, if any. Non-nil means this sheet renders the chosen state
    ///     and is inert: it never calls `onAnswer`. Deliberately has no
    ///     default value, so the compiler is the wiring check for every
    ///     construction site — the same trick `AskQuestionView.init` uses for
    ///     exactly the bug class this guards against.
    init(requestId: String, prompt: String, detail: String?, choices: [Choice],
         store: DecisionStore, answeredChoiceId: String?,
         onAnswer: @escaping (_ choiceId: String?) -> Void) {
        self.requestId = requestId
        self.store = store
        self.onAnswer = onAnswer

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Decision"
        win.isReleasedWhenClosed = false
        win.appearance = NSAppearance(named: .darkAqua)

        super.init(window: win)
        win.delegate = self
        buildContent(prompt: prompt, detail: detail, choices: choices)

        if let answeredChoiceId {
            // Rebuilt for an already-resolved request (e.g. a stray duplicate
            // broadcast). Render the recorded choice and go inert — never arm
            // the buttons for a request that is already done.
            answered = true
            applyAnswered(choiceId: answeredChoiceId)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Build UI

    private func buildContent(prompt: String, detail: String?, choices: [Choice]) {
        guard let contentView = window?.contentView else { return }

        let promptLabel = NSTextField(labelWithString: prompt)
        promptLabel.font = .systemFont(ofSize: 14, weight: .medium)
        promptLabel.textColor = .white
        promptLabel.lineBreakMode = .byWordWrapping
        promptLabel.maximumNumberOfLines = 0
        promptLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(promptLabel)

        var prevAnchor = promptLabel.bottomAnchor
        var topConstant: CGFloat = 12

        if let detail, !detail.isEmpty {
            let detailLabel = NSTextField(labelWithString: detail)
            detailLabel.font = .systemFont(ofSize: 11)
            detailLabel.textColor = .secondaryLabelColor
            detailLabel.lineBreakMode = .byWordWrapping
            detailLabel.maximumNumberOfLines = 0
            detailLabel.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(detailLabel)
            NSLayoutConstraint.activate([
                detailLabel.topAnchor.constraint(equalTo: prevAnchor, constant: 6),
                detailLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
                detailLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            ])
            prevAnchor = detailLabel.bottomAnchor
            topConstant = 14
        }

        for choice in choices {
            let btn = NSButton(title: choice.label, target: self, action: #selector(choiceTapped(_:)))
            btn.identifier = NSUserInterfaceItemIdentifier(choice.id)
            btn.bezelStyle = .rounded
            btn.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(btn)
            NSLayoutConstraint.activate([
                btn.topAnchor.constraint(equalTo: prevAnchor, constant: topConstant),
                btn.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
                btn.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            ])
            prevAnchor = btn.bottomAnchor
            topConstant = 8
            choiceButtons.append((choice.id, btn))
        }

        let dismissBtn = NSButton()
        dismissBtn.title = "Dismiss"
        dismissBtn.bezelStyle = .rounded
        dismissBtn.keyEquivalent = "\u{1b}"
        dismissBtn.target = self
        dismissBtn.action = #selector(dismissTapped)
        dismissBtn.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(dismissBtn)

        NSLayoutConstraint.activate([
            promptLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            promptLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            promptLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            dismissBtn.topAnchor.constraint(equalTo: prevAnchor, constant: 14),
            dismissBtn.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            dismissBtn.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
        ])
    }

    // MARK: - Resolution

    @objc private func choiceTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        resolve(choiceId: id)
    }

    @objc private func dismissTapped() {
        resolve(choiceId: nil)
    }

    /// Closed via the titlebar close box without picking an option. Routes
    /// through the same single resolution path as a choice tap or the Dismiss
    /// button, so whichever one the operator actually used, `onAnswer` fires
    /// at most once.
    func windowWillClose(_ notification: Notification) {
        resolve(choiceId: nil)
    }

    /// The one path every dismissal/choice routes through. Records the answer
    /// in `store` **before** calling `onAnswer` — mirroring `ReplView`'s
    /// "record before sending" rule at `ReplView.swift:1362-1370`: if the send
    /// path is ever torn down mid-flight, the fact that this request is done
    /// is already outside this view.
    private func resolve(choiceId: String?) {
        guard !answered else { return }
        answered = true

        let record: DecisionAnswerRecord = choiceId.map { .choice($0) } ?? .dismissed
        store.recordAnswer(requestId: requestId, record: record)
        onAnswer(choiceId)

        disableAllButtons()
        if let window, let sheetParent = window.sheetParent {
            sheetParent.endSheet(window)
        }
    }

    // MARK: - Rendering an already-answered request

    private func applyAnswered(choiceId: String) {
        disableAllButtons()
        for (id, btn) in choiceButtons where id == choiceId {
            btn.contentTintColor = Theme.sage
        }
    }

    private func disableAllButtons() {
        for (_, btn) in choiceButtons { btn.isEnabled = false }
    }
}
