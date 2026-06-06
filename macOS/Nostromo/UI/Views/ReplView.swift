import AppKit
import Combine

// MARK: - ReplView

/// Chat-style REPL pane backed by a ChatSession (Claude Code JSON streaming).
///
/// Layout: scrolling turn history (top) + input bar (bottom).
/// Turn views accumulate live blocks as Claude streams output.
class ReplView: NSView {

    private let session:    ChatSession
    private let scrollView = NSScrollView()
    private let stackView  = NSStackView()
    private let inputBar   = ReplInputBar()

    private var inputBarHeightConstraint: NSLayoutConstraint!
    private let quickActions: [QuickAction]
    private var quickActionStrip: QuickActionStripView?

    private var turnViews:   [UUID: ChatTurnView] = [:]
    private var cancellables = Set<AnyCancellable>()

    init(tag: String, agentName: String? = nil, displayName: String? = nil,
         workingDirectory: String? = nil, quickActions: [QuickAction] = []) {
        self.quickActions = quickActions
        // Use the shared registry so multiple windows showing the same tag
        // observe the same session and stay in sync (mirrored).
        session = AppStore.shared.session(for: tag, agentName: agentName, displayName: displayName, workingDirectory: workingDirectory)
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Setup

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = Theme.bg.cgColor

        // Top border (visual separator from HUD above)
        let topBorder = NSView()
        topBorder.wantsLayer = true
        topBorder.layer?.backgroundColor = Theme.borderInactive.cgColor
        topBorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topBorder)
        NSLayoutConstraint.activate([
            topBorder.topAnchor.constraint(equalTo: topAnchor),
            topBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBorder.heightAnchor.constraint(equalToConstant: 1),
        ])

        // Thin toolbar strip: "new session" button on the right
        let toolbar = NSView()
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor(white: 0.07, alpha: 1).cgColor
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toolbar)

        let newSessionBtn = NSButton()
        newSessionBtn.title            = "⌧ New session"
        newSessionBtn.font             = .systemFont(ofSize: 9)
        newSessionBtn.isBordered       = false
        newSessionBtn.contentTintColor = Theme.fgMuted
        newSessionBtn.target           = self
        newSessionBtn.action           = #selector(newSessionTapped)
        newSessionBtn.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(newSessionBtn)

        let toolbarBottomBorder = NSView()
        toolbarBottomBorder.wantsLayer = true
        toolbarBottomBorder.layer?.backgroundColor = Theme.borderInactive.cgColor
        toolbarBottomBorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toolbarBottomBorder)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topBorder.bottomAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 22),
            newSessionBtn.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -8),
            newSessionBtn.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            toolbarBottomBorder.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            toolbarBottomBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbarBottomBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbarBottomBorder.heightAnchor.constraint(equalToConstant: 1),
        ])

        // Scroll view with flipped clip — content anchors to top.
        // Don't set drawsBackground on the clip view directly — per NSClipView docs,
        // doing so sets copiesOnScroll=false causing scroll trails. Set it on scrollView instead.
        let clip = ReplClipView()
        scrollView.contentView          = clip
        scrollView.drawsBackground      = false
        scrollView.hasVerticalScroller  = true
        scrollView.hasHorizontalScroller = false   // forces doc view to match scroll view width
        scrollView.autohidesScrollers   = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        // Stack — turns stacked vertically, full width
        stackView.orientation = .vertical
        stackView.spacing     = 0
        stackView.alignment   = .width
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = stackView
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            // Pin leading AND trailing to the clip view rather than binding
            // stackView.width == clipView.width. The clip view's width is frame-driven
            // by the scroll view (tile()), so pinning both edges clamps the stack to the
            // visible width and lets the scroll view ABSORB long content (wrap/truncate)
            // instead of propagating its required width up and ballooning the window.
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            // Ensure document view height is at least the visible area when empty,
            // preventing ambiguous height that causes scroll flicker on first layout.
            stackView.bottomAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.bottomAnchor),
        ])

        // Input bar — fixed at bottom
        inputBar.translatesAutoresizingMaskIntoConstraints = false
        inputBar.onSend = { [weak self] text, images in self?.session.send(text, images: images) }
        addSubview(inputBar)

        inputBarHeightConstraint = inputBar.heightAnchor.constraint(equalToConstant: ReplInputBar.minHeight)

        // Optional quick-action strip — sits between scroll view and input bar
        if !quickActions.isEmpty {
            let strip = QuickActionStripView(actions: quickActions) { [weak self] action in
                self?.runQuickAction(action)
            }
            strip.translatesAutoresizingMaskIntoConstraints = false
            addSubview(strip)
            quickActionStrip = strip
        }

        // Scroll view's bottom connects to the strip (if present) or directly to the input bar.
        let scrollBottomTarget = quickActionStrip?.topAnchor ?? inputBar.topAnchor

        var constraints: [NSLayoutConstraint] = [
            inputBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            inputBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            inputBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            inputBarHeightConstraint,

            scrollView.topAnchor.constraint(equalTo: toolbarBottomBorder.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: scrollBottomTarget),
        ]

        if let strip = quickActionStrip {
            constraints += [
                strip.leadingAnchor.constraint(equalTo: leadingAnchor),
                strip.trailingAnchor.constraint(equalTo: trailingAnchor),
                strip.bottomAnchor.constraint(equalTo: inputBar.topAnchor),
                strip.heightAnchor.constraint(equalToConstant: 40),
            ]
        }

        NSLayoutConstraint.activate(constraints)

        inputBar.onHeightChange = { [weak self] ideal in
            guard let self else { return }
            // Cap at 1/3 of the pane's current height (fallback to 200 if not yet laid out).
            let cap = self.bounds.height > 0 ? self.bounds.height / 3 : 200
            let clamped = max(ReplInputBar.minHeight, min(ideal, cap))
            guard abs(self.inputBarHeightConstraint.constant - clamped) > 0.5 else { return }
            self.inputBarHeightConstraint.constant = clamped
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration     = 0.08
                ctx.allowsImplicitAnimation = true
                self.layoutSubtreeIfNeeded()
            }
        }

        // Combine
        session.$turns
            .receive(on: DispatchQueue.main)
            .sink { [weak self] turns in self?.turnsDidUpdate(turns) }
            .store(in: &cancellables)

        session.$isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] r in self?.inputBar.setRunning(r) }
            .store(in: &cancellables)

        session.$pendingCount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in self?.inputBar.setPendingCount(count) }
            .store(in: &cancellables)
    }

    // MARK: Turn management

    private func turnsDidUpdate(_ turns: [ChatTurn]) {
        for turn in turns {
            if let existing = turnViews[turn.id] {
                existing.update(turn: turn)
            } else {
                let v = ChatTurnView(turn: turn)
                v.translatesAutoresizingMaskIntoConstraints = false
                v.onSend = { [weak self] text in self?.session.send(text) }
                turnViews[turn.id] = v
                stackView.addArrangedSubview(v)
                // Explicit width — NSStackView alignment=.width doesn't reliably
                // constrain custom views with no intrinsic size
                v.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
            }
        }
        // Scroll to bottom after layout settles
        DispatchQueue.main.async { [weak self] in self?.scrollToBottom() }
    }

    private func scrollToBottom() {
        guard let doc = scrollView.documentView else { return }
        // Force pending layout so a just-appended turn (e.g. the optimistic echo)
        // has its real height before we compute the offset — otherwise we scroll
        // short and the newest message hides behind the input bar.
        doc.layoutSubtreeIfNeeded()
        let bottom = NSPoint(x: 0, y: max(0, doc.frame.height - scrollView.contentView.bounds.height))
        scrollView.contentView.scroll(to: bottom)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self.inputBar.textView)
        }
    }

    @objc private func newSessionTapped() {
        // Confirm before wiping history
        let alert = NSAlert()
        alert.messageText     = "Start new session?"
        alert.informativeText = "This clears the local display and disconnects from the current Claude session. Claude's memory of this conversation will be lost."
        alert.alertStyle      = .warning
        alert.addButton(withTitle: "New Session")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Clear turn views
        turnViews.values.forEach { $0.removeFromSuperview() }
        turnViews = [:]
        session.newSession()
    }

    private func runQuickAction(_ action: QuickAction) {
        if action.clearFirst {
            // Mirror newSessionTapped's local-history clear so the transcript
            // empties immediately, then start a fresh daemon session.
            // No confirmation dialog — quick actions are intentional one-tap affordances.
            turnViews.values.forEach { $0.removeFromSuperview() }
            turnViews = [:]
            session.newSession()
        }
        let prompt = action.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty {
            session.send(prompt)
        }
    }
}

// MARK: - ReplClipView

private class ReplClipView: NSClipView {
    override var isFlipped: Bool { true }
}

// MARK: - ReplInputBar

private class ReplInputBar: NSView, NSTextViewDelegate {

    var onSend:        ((String, [URL]) -> Void)?
    /// Fired whenever the text grows/shrinks; passes the ideal total bar height.
    var onHeightChange: ((CGFloat) -> Void)?

    static let minHeight: CGFloat = 46

    private var pendingImages: [URL] = []

    private let textScroll   = NSScrollView()
    let textView             = ChatTextView()
    private let placeholder  = NSTextField(labelWithString: "Message…")
    private let button       = NSButton()
    private let spinner      = NSProgressIndicator()
    /// Horizontal strip of image thumbnails shown above the text field when images are attached.
    private let imageTray    = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = Theme.bgBar.cgColor

        // Top border
        let border = NSView()
        border.wantsLayer = true
        border.layer?.backgroundColor = Theme.borderInactive.cgColor
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)
        NSLayoutConstraint.activate([
            border.topAnchor.constraint(equalTo: topAnchor),
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.heightAnchor.constraint(equalToConstant: 1),
        ])

        // NSTextView — multi-line, grows with content
        textView.isRichText              = false
        textView.font                    = Theme.firaCode(size: 13)
        textView.textColor               = Theme.fg
        // Enable all ligatures so Fira Code's OpenType features (→ => != etc.) render.
        textView.typingAttributes[.ligature] = 2
        textView.backgroundColor         = NSColor(white: 0.14, alpha: 1)
        textView.drawsBackground         = true
        textView.isEditable              = true
        textView.isSelectable            = true
        textView.allowsUndo              = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable   = true
        textView.textContainerInset      = NSSize(width: 4, height: 6)
        textView.textContainer?.widthTracksTextView  = true
        textView.textContainer?.heightTracksTextView = false
        textView.appearance = NSAppearance(named: .darkAqua)
        textView.delegate   = self
        textView.onSubmit   = { [weak self] in self?.submitAction() }

        // Scroll wrapper — no border; we style the layer instead
        textScroll.documentView          = textView
        textScroll.borderType            = .noBorder
        textScroll.drawsBackground       = false
        textScroll.hasVerticalScroller   = true
        textScroll.autohidesScrollers    = true
        textScroll.hasHorizontalScroller = false
        textScroll.wantsLayer            = true
        textScroll.layer?.backgroundColor = NSColor(white: 0.14, alpha: 1).cgColor
        textScroll.layer?.cornerRadius   = 6
        textScroll.layer?.borderWidth    = 0.5
        textScroll.layer?.borderColor    = NSColor(white: 0.35, alpha: 1).cgColor
        textScroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textScroll)

        // Placeholder label — visible when text is empty
        placeholder.font      = Theme.firaCode(size: 13)
        placeholder.textColor = Theme.fgMuted
        placeholder.isEnabled = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        textScroll.addSubview(placeholder)

        // Send button
        button.bezelStyle = .inline
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = Theme.cornflower.withAlphaComponent(0.25).cgColor
        button.layer?.cornerRadius    = 5
        let btnAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: Theme.fg,
        ]
        button.attributedTitle = NSAttributedString(string: "Send", attributes: btnAttrs)
        button.target = self
        button.action = #selector(sendButtonAction)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)

        // Spinner
        spinner.style                   = .spinning
        spinner.controlSize             = .small
        spinner.isDisplayedWhenStopped  = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)

        // Image tray — hidden until images are dropped
        imageTray.orientation    = .horizontal
        imageTray.spacing        = 6
        imageTray.alignment      = .centerY
        imageTray.isHidden       = true
        imageTray.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageTray)

        NSLayoutConstraint.activate([
            // Image tray sits above the text scroll view when visible
            imageTray.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            imageTray.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -8),
            imageTray.topAnchor.constraint(equalTo: border.bottomAnchor, constant: 6),
            imageTray.heightAnchor.constraint(equalToConstant: 48),

            textScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            textScroll.topAnchor.constraint(equalTo: border.bottomAnchor, constant: 9),
            textScroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            textScroll.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -8),

            // Placeholder anchored to the text inset area
            placeholder.leadingAnchor.constraint(equalTo: textScroll.leadingAnchor, constant: 4),
            placeholder.topAnchor.constraint(equalTo: textScroll.topAnchor, constant: 6),

            button.trailingAnchor.constraint(equalTo: spinner.leadingAnchor, constant: -8),
            button.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            button.widthAnchor.constraint(equalToConstant: 54),
            button.heightAnchor.constraint(equalToConstant: 26),

            spinner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            spinner.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -15),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),
        ])

        // Register for image drag-and-drop
        registerForDraggedTypes([.fileURL, .tiff, .png])
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Actions

    @objc private func sendButtonAction() { submitAction() }

    private func submitAction() {
        var text         = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let imagesToSend = pendingImages
        // Allow send when images are present even with no text — synthesise a
        // description from filenames so Claude gets a non-empty message.
        if text.isEmpty && !imagesToSend.isEmpty {
            text = imagesToSend.map { "[\($0.lastPathComponent)]" }.joined(separator: " ")
        }
        guard !text.isEmpty else { return }
        textView.string  = ""
        pendingImages    = []
        placeholder.isHidden = false
        imageTray.isHidden   = true
        onHeightChange?(Self.minHeight)
        onSend?(text, imagesToSend)
    }

    // MARK: State

    func setRunning(_ running: Bool) {
        button.alphaValue = running ? 0.5 : 1.0
        running ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
    }

    func setPendingCount(_ count: Int) {
        placeholder.stringValue = count > 0 ? "Message… (\(count) queued)" : "Message…"
    }

    // MARK: Drag-and-drop (images)

    private static let imageUTIs: Set<String> = ["public.image", "public.png", "public.jpeg",
                                                  "public.tiff", "public.gif", "public.heic",
                                                  "public.webp"]

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = imageURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return [] }
        layer?.borderWidth = 1
        layer?.borderColor = Theme.cornflower.withAlphaComponent(0.6).cgColor
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        layer?.borderWidth = 0
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = imageURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        layer?.borderWidth = 0
        urls.forEach { addImage($0) }
        return true
    }

    private func imageURLs(from pb: NSPasteboard) -> [URL] {
        guard let items = pb.readObjects(forClasses: [NSURL.self],
                                         options: [.urlReadingFileURLsOnly: true]) as? [URL]
        else { return [] }
        return items.filter { url in
            guard let uti = try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier
            else { return false }
            return Self.imageUTIs.contains(where: { UTTypeConformsTo(uti as CFString, $0 as CFString) })
        }
    }

    private func addImage(_ url: URL) {
        guard !pendingImages.contains(url) else { return }
        pendingImages.append(url)

        // Build a small thumbnail chip
        let chip = NSView()
        chip.wantsLayer  = true
        chip.layer?.cornerRadius = 4
        chip.layer?.backgroundColor = NSColor(white: 0.18, alpha: 1).cgColor
        chip.translatesAutoresizingMaskIntoConstraints = false

        let img = NSImageView()
        img.image = NSImage(contentsOf: url)
        img.imageScaling = .scaleProportionallyUpOrDown
        img.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(img)

        let nameLabel = NSTextField(labelWithString: url.lastPathComponent + " (name only)")
        nameLabel.font          = .systemFont(ofSize: 9)
        nameLabel.textColor     = Theme.fgMuted
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(nameLabel)

        let removeBtn = NSButton()
        removeBtn.title     = "✕"
        removeBtn.font      = .systemFont(ofSize: 9)
        removeBtn.isBordered = false
        removeBtn.contentTintColor = Theme.fgMuted
        // Capture url directly in the action closure via a helper wrapper
        removeBtn.target    = self
        removeBtn.action    = #selector(removeImageChip(_:))
        // Store the URL via associated object so the selector can find it
        objc_setAssociatedObject(removeBtn, &ReplInputBar.urlKey, url, .OBJC_ASSOCIATION_RETAIN)
        removeBtn.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(removeBtn)

        NSLayoutConstraint.activate([
            img.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 4),
            img.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            img.widthAnchor.constraint(equalToConstant: 36),
            img.heightAnchor.constraint(equalToConstant: 36),

            nameLabel.leadingAnchor.constraint(equalTo: img.trailingAnchor, constant: 4),
            nameLabel.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            nameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 90),

            removeBtn.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 2),
            removeBtn.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -4),
            removeBtn.centerYAnchor.constraint(equalTo: chip.centerYAnchor),

            chip.heightAnchor.constraint(equalToConstant: 44),
        ])

        imageTray.addArrangedSubview(chip)
        imageTray.isHidden = false
        // Bump bar height for the tray
        onHeightChange?(idealBarHeight() + 54)
    }

    private static var urlKey = 0

    @objc private func removeImageChip(_ sender: NSButton) {
        guard let chip = sender.superview else { return }
        if let url = objc_getAssociatedObject(sender, &ReplInputBar.urlKey) as? URL {
            pendingImages.removeAll { $0 == url }
        }
        imageTray.removeArrangedSubview(chip)
        chip.removeFromSuperview()
        if pendingImages.isEmpty {
            imageTray.isHidden = true
            onHeightChange?(idealBarHeight())
        }
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        placeholder.isHidden = !textView.string.isEmpty
        onHeightChange?(idealBarHeight())
    }

    // MARK: Height calculation

    private func idealBarHeight() -> CGFloat {
        let insets  = textView.textContainerInset.height * 2
        let margins: CGFloat = 9 + 9 + 1

        // Use NSTextLayoutManager (macOS 12+) to avoid forcing NSLayoutManager
        // compatibility mode. Accessing textView.layoutManager on macOS 12+ downgrades
        // the text view to the legacy layout engine for its lifetime.
        if let tlm = textView.textLayoutManager {
            tlm.ensureLayout(for: tlm.documentRange)
            var maxY: CGFloat = 0
            tlm.enumerateTextLayoutFragments(
                from: tlm.documentRange.location,
                options: [.ensuresLayout, .ensuresExtraLineFragment]
            ) { frag in
                maxY = frag.layoutFragmentFrame.maxY
                return true
            }
            return max(Self.minHeight, ceil(maxY + insets + margins))
        }

        // Legacy fallback (pre-macOS 12 or if textLayoutManager is nil)
        guard let lm = textView.layoutManager, let tc = textView.textContainer
        else { return Self.minHeight }
        lm.ensureLayout(for: tc)
        let textH = lm.usedRect(for: tc).height
        return max(Self.minHeight, ceil(textH + insets + margins))
    }
}

// MARK: - ChatTurnView

private class ChatTurnView: NSView {

    private let blocksStack   = NSStackView()
    private var renderedCount = 0

    /// Reply text injected by the confirm card — suppress its bubble so the card
    /// itself serves as the only visible acknowledgement of the user's choice.
    private static let confirmReplySentinel = "(This answers your question:"

    /// Called when the user answers an in-turn `AskUserQuestion` card.
    /// Wired by `ReplView` to `session.send(_:)`.
    var onSend: ((String) -> Void)?

    init(turn: ChatTurn) {
        super.init(frame: .zero)
        wantsLayer = true

        // Blocks container — AI response, left-aligned at 82% width
        blocksStack.orientation = .vertical
        blocksStack.spacing     = 6
        blocksStack.alignment   = .width
        blocksStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(blocksStack)

        // Suppress the bubble when the reply was injected by the confirm card — the
        // card's own chosen-state visuals already acknowledge the selection.
        let suppressBubble = turn.userInput.contains(Self.confirmReplySentinel)

        if suppressBubble {
            // Pin blocksStack directly to the top so there is no gap where the bubble
            // would have been.
            NSLayoutConstraint.activate([
                blocksStack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
                blocksStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
                blocksStack.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.82, constant: -14),
                blocksStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            ])
        } else {
            // User bubble — trailing-pinned, width driven by intrinsicContentSize capped at 75%.
            // No spacer/NSStackView needed: trailing anchor right-aligns it, intrinsicContentSize
            // gives AutoLayout the natural width, and the ≤ constraint caps long messages.
            let bubble = UserBubbleView(text: turn.userInput)
            bubble.translatesAutoresizingMaskIntoConstraints = false
            addSubview(bubble)

            NSLayoutConstraint.activate([
                bubble.topAnchor.constraint(equalTo: topAnchor, constant: 12),
                bubble.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                // Fixed 75 % width so AutoLayout never needs intrinsicContentSize — the
                // unconstrained single-line NSTextField width overflowed the right edge.
                bubble.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.75),

                blocksStack.topAnchor.constraint(equalTo: bubble.bottomAnchor, constant: 8),
                blocksStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
                blocksStack.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.82, constant: -14),
                blocksStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            ])
        }

        renderNewBlocks(turn.blocks)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Called as the turn's blocks array grows during live streaming.
    func update(turn: ChatTurn) {
        let newBlocks = Array(turn.blocks.dropFirst(renderedCount))
        renderNewBlocks(newBlocks)
    }

    private func renderNewBlocks(_ blocks: [TurnBlock]) {
        for block in blocks {
            let v = makeBlockView(block)
            v.translatesAutoresizingMaskIntoConstraints = false
            blocksStack.addArrangedSubview(v)
            // Explicitly match width — NSStackView alignment=.width doesn't reliably
            // propagate width to custom views with no intrinsic size (e.g. TextBlockView)
            v.widthAnchor.constraint(equalTo: blocksStack.widthAnchor).isActive = true
            renderedCount += 1
        }
    }

    private func makeBlockView(_ block: TurnBlock) -> NSView {
        switch block {
        case .text(let t):           return TextBlockView(text: t)
        case .toolCall(let d):       return ToolCallView(data: d)
        case .toolResult(let d):     return ToolResultView(data: d)
        case .resultSummary(let d):  return ResultChipView(data: d)
        case .errorMessage(let m):   return ErrorBlockView(message: m)
        case .askQuestion(let d):
            let v = AskQuestionView(data: d)
            v.onAnswer = { [weak self] answer in self?.onSend?(answer) }
            return v
        }
    }
}

// MARK: - UserBubbleView

/// Right-floating chat bubble for user messages.
/// Overrides intrinsicContentSize so NSStackView (bubbleRow) can determine height.
private class UserBubbleView: NSView {

    private let label: NSTextField

    init(text: String) {
        label = NSTextField(labelWithString: text)
        label.font                 = .systemFont(ofSize: 13)
        label.textColor            = Theme.fg
        label.lineBreakMode        = .byWordWrapping
        label.maximumNumberOfLines = 0
        // Yield horizontally so the label wraps to the available width instead of
        // demanding its full single-line width (which would balloon the scroll view
        // and, ultimately, the whole window past the screen edge).
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.cornflower.withAlphaComponent(0.18).cgColor
        layer?.cornerRadius    = 12
        layer?.borderWidth     = 1
        layer?.borderColor     = Theme.cornflower.withAlphaComponent(0.35).cgColor

        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - TextBlockView

/// Renders text with markdown table detection. Tables become native grid views;
/// paragraphs stay as labels.
///
/// Uses explicit leading/trailing constraints (not NSStackView alignment) so
/// MarkdownTableView — which has no intrinsic content size — fills the full width.
private class TextBlockView: NSView {

    init(text: String) {
        super.init(frame: .zero)

        let segments = Self.parseSegments(text)
        var prevAnchor: NSLayoutYAxisAnchor? = nil

        for segment in segments {
            let view: NSView
            switch segment {
            case .paragraph(let txt):
                let label = NSTextField(labelWithString: Self.stripMarkdown(txt))
                label.font                 = .systemFont(ofSize: 13)
                label.textColor            = Theme.fg
                label.lineBreakMode        = .byWordWrapping
                label.maximumNumberOfLines = 0
                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                view = label
            case .table(let headers, let rows):
                view = MarkdownTableView(headers: headers, rows: rows)
            }

            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: prevAnchor ?? topAnchor,
                                          constant: prevAnchor == nil ? 0 : 8),
            ])
            prevAnchor = view.bottomAnchor
        }

        // Close off the view's intrinsic height
        if let last = prevAnchor {
            last.constraint(equalTo: bottomAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Segment model & parser

    private enum Segment {
        case paragraph(String)
        case table(headers: [String], rows: [[String]])
    }

    private static func parseSegments(_ text: String) -> [Segment] {
        let lines = text.components(separatedBy: "\n")
        var segments: [Segment] = []
        var pending: [String]   = []
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let next = i + 1 < lines.count ? lines[i + 1] : ""

            // Markdown table: current line starts with |, next line is |---|
            if line.hasPrefix("|"), next.hasPrefix("|"), next.contains("---") {
                // Flush pending paragraph
                let txt = pending.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !txt.isEmpty { segments.append(.paragraph(txt)) }
                pending = []

                let headers = parseCells(line)
                i += 2  // skip header row + separator row
                var rows: [[String]] = []
                while i < lines.count && lines[i].hasPrefix("|") {
                    rows.append(parseCells(lines[i]))
                    i += 1
                }
                if !headers.isEmpty { segments.append(.table(headers: headers, rows: rows)) }
            } else {
                pending.append(line)
                i += 1
            }
        }

        let tail = pending.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { segments.append(.paragraph(tail)) }

        return segments
    }

    private static func parseCells(_ line: String) -> [String] {
        line.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { stripMarkdownLinks($0) }
    }

    /// Converts `[label](url)` → `label` so URLs don't blow up column widths.
    private static let linkRegex = try? NSRegularExpression(pattern: #"\[([^\]]*)\]\([^)]*\)"#)
    private static let boldRegex = try? NSRegularExpression(pattern: #"\*\*([^*]+)\*\*"#)
    private static let italRegex = try? NSRegularExpression(pattern: #"\*([^*]+)\*"#)

    private static func stripMarkdownLinks(_ text: String) -> String {
        guard text.contains("](") else { return text }
        let ns    = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return linkRegex?.stringByReplacingMatches(in: text, range: range, withTemplate: "$1") ?? text
    }

    /// Strip `**bold**`, `*italic*`, and `[text](url)` so they don't appear raw in paragraph text.
    static func stripMarkdown(_ text: String) -> String {
        var s = text
        for (regex, template) in [(boldRegex, "$1"), (italRegex, "$1"), (linkRegex, "$1")] {
            guard let rx = regex else { continue }
            let ns = s as NSString
            s = rx.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: template)
        }
        return s
    }
}

// MARK: - MarkdownTableView

/// Native grid renderer for markdown pipe tables.
///
/// Rows are pinned with explicit leading/trailing constraints (not NSStackView alignment)
/// so column widths are computed correctly from the table's actual width.
private class MarkdownTableView: NSView {

    init(headers: [String], rows: [[String]]) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth  = 1
        layer?.borderColor  = Theme.borderInactive.withAlphaComponent(0.5).cgColor

        let colCount = max(headers.count, rows.map { $0.count }.max() ?? 1)
        guard colCount > 0 else { return }

        let allRows: [[String]] = [headers] + rows
        var prevAnchor: NSLayoutYAxisAnchor? = nil

        for (rowIdx, rowData) in allRows.enumerated() {
            let isHeader   = rowIdx == 0
            let isLast     = rowIdx == allRows.count - 1
            let bgAlpha: CGFloat = isHeader ? 0.14 : (rowIdx % 2 == 0 ? 0.09 : 0.105)
            let rowHeight: CGFloat = isHeader ? 30 : 26

            let rowView = NSView()
            rowView.wantsLayer = true
            rowView.layer?.backgroundColor = NSColor(white: bgAlpha, alpha: 1).cgColor
            rowView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(rowView)

            // Pin row to full table width — this is what determines column widths
            NSLayoutConstraint.activate([
                rowView.leadingAnchor.constraint(equalTo: leadingAnchor),
                rowView.trailingAnchor.constraint(equalTo: trailingAnchor),
                rowView.topAnchor.constraint(equalTo: prevAnchor ?? topAnchor),
                rowView.heightAnchor.constraint(equalToConstant: rowHeight),
            ])
            prevAnchor = rowView.bottomAnchor

            // Build equal-width columns
            var labels: [NSTextField] = []
            for colIdx in 0..<colCount {
                let text  = colIdx < rowData.count ? rowData[colIdx] : ""
                let label = NSTextField(labelWithString: text)
                label.font                 = isHeader
                    ? .systemFont(ofSize: 11, weight: .semibold)
                    : .systemFont(ofSize: 11)
                label.textColor            = isHeader ? Theme.cornflower : Theme.fg
                label.lineBreakMode        = .byTruncatingTail
                label.maximumNumberOfLines = 1
                label.translatesAutoresizingMaskIntoConstraints = false
                label.setContentHuggingPriority(.defaultLow, for: .horizontal)
                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                rowView.addSubview(label)
                labels.append(label)
            }

            for (colIdx, label) in labels.enumerated() {
                label.centerYAnchor.constraint(equalTo: rowView.centerYAnchor).isActive = true
                if colIdx == 0 {
                    label.leadingAnchor.constraint(equalTo: rowView.leadingAnchor, constant: 10).isActive = true
                } else {
                    label.leadingAnchor.constraint(equalTo: labels[colIdx - 1].trailingAnchor, constant: 12).isActive = true
                    label.widthAnchor.constraint(equalTo: labels[0].widthAnchor).isActive = true
                }
                if colIdx == colCount - 1 {
                    label.trailingAnchor.constraint(equalTo: rowView.trailingAnchor, constant: -10).isActive = true
                }
            }

            // Row separator
            if !isLast {
                let sep = NSView()
                sep.wantsLayer = true
                sep.layer?.backgroundColor = Theme.borderInactive.withAlphaComponent(0.35).cgColor
                sep.translatesAutoresizingMaskIntoConstraints = false
                rowView.addSubview(sep)
                NSLayoutConstraint.activate([
                    sep.leadingAnchor.constraint(equalTo: rowView.leadingAnchor),
                    sep.trailingAnchor.constraint(equalTo: rowView.trailingAnchor),
                    sep.bottomAnchor.constraint(equalTo: rowView.bottomAnchor),
                    sep.heightAnchor.constraint(equalToConstant: 1),
                ])
            }
        }

        if let last = prevAnchor {
            last.constraint(equalTo: bottomAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - ToolCallView

private class ToolCallView: NSView {

    init(data: ToolCallData) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.10, alpha: 1).cgColor
        layer?.cornerRadius    = 6

        let iconLabel = NSTextField(labelWithString: icon(for: data.toolName))
        iconLabel.font      = .systemFont(ofSize: 12)
        iconLabel.textColor = Theme.fgMuted
        iconLabel.setContentHuggingPriority(.required, for: .horizontal)

        let nameLabel = NSTextField(labelWithString: data.toolName)
        nameLabel.font      = .systemFont(ofSize: 11, weight: .semibold)
        nameLabel.textColor = Theme.fgMuted
        nameLabel.setContentHuggingPriority(.required, for: .horizontal)

        let dotLabel = NSTextField(labelWithString: "·")
        dotLabel.font      = .systemFont(ofSize: 11)
        dotLabel.textColor = Theme.borderInactive
        dotLabel.setContentHuggingPriority(.required, for: .horizontal)

        let summaryLabel = NSTextField(labelWithString: data.inputSummary)
        summaryLabel.font          = Theme.monoFont
        summaryLabel.textColor     = Theme.fg
        summaryLabel.lineBreakMode = .byTruncatingMiddle
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [iconLabel, nameLabel, dotLabel, summaryLabel])
        row.orientation = .horizontal
        row.spacing     = 5
        row.alignment   = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func icon(for name: String) -> String {
        switch name {
        case "Read":                         return "📄"
        case "Write":                        return "📝"
        case "Edit", "MultiEdit":            return "✏️"
        case "Bash":                         return "$"
        case "Grep", "Glob":                 return "🔍"
        case "WebFetch", "WebSearch":        return "🌐"
        case "Agent":                        return "🤖"
        case "TodoWrite":                    return "✅"
        case "NotebookRead", "NotebookEdit": return "📓"
        default:                             return "⚙️"
        }
    }
}

// MARK: - ToolResultView

/// Tool result block — collapsed by default showing a line count chip.
/// Click to expand/collapse. Errors always start expanded.
private class ToolResultView: NSView {

    private var isExpanded  = false
    private let disclosure  = NSButton()
    private let contentWrap = NSView()
    private let lineCount:  Int

    init(data: ToolResultData) {
        let nonEmpty = data.content.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        lineCount  = max(nonEmpty.count, 1)
        isExpanded = data.isError   // errors always open

        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.07, alpha: 1).cgColor
        layer?.cornerRadius    = 6
        layer?.borderWidth     = 1
        layer?.borderColor     = data.isError
            ? Theme.redSweater.withAlphaComponent(0.5).cgColor
            : Theme.borderInactive.withAlphaComponent(0.6).cgColor

        // Disclosure button (always visible)
        disclosure.isBordered = false
        disclosure.target     = self
        disclosure.action     = #selector(toggleExpand)
        disclosure.translatesAutoresizingMaskIntoConstraints = false

        // Content label inside a wrapper so NSStackView can collapse it
        let label = NSTextField(labelWithString: data.content)
        label.font                 = Theme.monoFont
        label.textColor            = data.isError ? Theme.redSweater : Theme.fgMuted
        label.lineBreakMode        = .byCharWrapping
        label.maximumNumberOfLines = 0
        // Biggest balloon driver: long single-line tool output (JSON, git status) had
        // an intrinsic width of ~8600pt. Yield horizontally so it wraps to the pane.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        contentWrap.addSubview(label)
        contentWrap.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: contentWrap.topAnchor),
            label.leadingAnchor.constraint(equalTo: contentWrap.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: contentWrap.trailingAnchor),
            label.bottomAnchor.constraint(equalTo: contentWrap.bottomAnchor),
        ])

        // NSStackView collapses hidden arranged subviews automatically
        let vStack = NSStackView(views: [disclosure, contentWrap])
        vStack.orientation = .vertical
        vStack.spacing     = 4
        vStack.alignment   = .width
        vStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(vStack)
        NSLayoutConstraint.activate([
            vStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            vStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            vStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            vStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            // alignment=.width doesn't reliably fill arranged subviews to stack width
            disclosure.widthAnchor.constraint(equalTo: vStack.widthAnchor),
            contentWrap.widthAnchor.constraint(equalTo: vStack.widthAnchor),
        ])

        applyState()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggleExpand() {
        isExpanded.toggle()
        applyState()
        // Walk up to nudge the scroll stack to re-measure
        var v: NSView? = superview
        while let sv = v {
            sv.needsLayout = true
            if sv is NSScrollView { break }
            v = sv.superview
        }
    }

    private func applyState() {
        let arrow = isExpanded ? "▼" : "▶"
        let count = "\(lineCount) line\(lineCount == 1 ? "" : "s")"
        let attrs: [NSAttributedString.Key: Any] = [
            .font:            NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: Theme.fgMuted,
        ]
        disclosure.attributedTitle = NSAttributedString(string: "\(arrow)  \(count)", attributes: attrs)
        contentWrap.isHidden = !isExpanded
    }
}

// MARK: - ResultChipView

private class ResultChipView: NSView {

    init(data: ResultSummaryData) {
        super.init(frame: .zero)

        let symbol = data.isError ? "✗" : "✓"
        let color  = data.isError ? Theme.redSweater : Theme.sage

        let durationStr = data.durationMs >= 1000
            ? String(format: "%.1fs", Double(data.durationMs) / 1000)
            : "\(data.durationMs)ms"
        let costStr = data.costUSD > 0
            ? String(format: " · $%.4f", data.costUSD)
            : ""
        let labelStr = "\(symbol)  \(durationStr)\(costStr)"

        let label = NSTextField(labelWithString: labelStr)
        label.font      = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - AskQuestionView

/// Native card rendered when an agent calls `AskUserQuestion`.
///
/// The claude CLI can't surface interactive UI in non-interactive (streaming) mode —
/// it returns "Answer questions?" as a tool error. We intercept the tool_use input
/// JSON in ChatModels and render it here instead. Tapping an option sends it as a
/// new user message, so the agent gets the answer and continues naturally.
private class AskQuestionView: NSView {

    var onAnswer: ((String) -> Void)?

    private let data: AskQuestionData
    private var answered = false
    private var headerChip: NSTextField?

    init(data: AskQuestionData) {
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
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func optionTapped(_ sender: OptionButton) {
        guard !answered else { return }
        answered = true
        // Dim all buttons to show selection; disable all to prevent re-tapping.
        subviews.compactMap { $0 as? OptionButton }.forEach { btn in
            btn.alphaValue = btn === sender ? 1.0 : 0.35
            btn.isEnabled  = false
        }
        // Animate the chosen-state visuals: checkmark, row tint, chip label/color, card border.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration    = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            sender.markChosen()
            headerChip?.stringValue = "APPROVED"
            headerChip?.textColor   = Theme.sage
            layer?.borderColor      = Theme.sage.withAlphaComponent(0.5).cgColor
        }
        // Claude's AskUserQuestion call always errors in -p mode ("Answer questions?").
        // The user's answer arrives as a new user turn, not a proper tool result.
        // Send rich context so claude can't miss the connection.
        let reply: String
        if data.question.isEmpty {
            reply = sender.optionLabel
        } else {
            reply = "\(sender.optionLabel)\n\n(This answers your question: \"\(data.question)\" — please proceed.)"
        }
        onAnswer?(reply)
    }

    // MARK: - OptionButton

    private class OptionButton: NSButton {

        let optionLabel: String

        private var chosen = false
        private let checkmark: NSImageView
        private let label: NSTextField

        init(option: AskQuestionData.Option, tag: Int) {
            optionLabel = option.label

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

            let lbl = NSTextField(labelWithString: option.label)
            lbl.font      = .systemFont(ofSize: 12, weight: .medium)
            lbl.textColor = Theme.fg
            lbl.translatesAutoresizingMaskIntoConstraints = false
            label = lbl

            super.init(frame: .zero)
            self.tag      = tag
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

        /// Applies chosen-state visuals: checkmark fade-in, semibold label, green row tint.
        /// Must be called from within an `NSAnimationContext.runAnimationGroup` block.
        func markChosen() {
            chosen = true
            checkmark.isHidden = false
            checkmark.animator().alphaValue = 1
            label.font = .systemFont(ofSize: 12, weight: .semibold)
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

// MARK: - ChatTextView

/// NSTextView subclass that fires `onSubmit` on Return (send) and passes
/// Shift+Return through as a regular newline.
/// Also blocks raw image data reads from the pasteboard to avoid triggering
/// the macOS Photos permission prompt — image files come via drag-and-drop instead.
private class ChatTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // keyCode 36 = Return; Shift+Return inserts a newline normally
        if event.keyCode == 36, !event.modifierFlags.contains(.shift) {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }

    /// Exclude raw image types so NSTextView never reads pixel data from the clipboard.
    /// This prevents the Photos permission prompt that fires even for non-Photos images.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes.filter { $0 != .tiff && $0 != .png }
    }
}

// MARK: - ErrorBlockView

private class ErrorBlockView: NSView {

    init(message: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.redSweater.withAlphaComponent(0.08).cgColor
        layer?.cornerRadius    = 6
        layer?.borderWidth     = 1
        layer?.borderColor     = Theme.redSweater.withAlphaComponent(0.4).cgColor

        let label = NSTextField(labelWithString: message)
        label.font                = Theme.monoFont
        label.textColor           = Theme.redSweater
        label.lineBreakMode       = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}
