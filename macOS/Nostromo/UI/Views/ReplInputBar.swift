import AppKit
import Combine
import NostromoKit

// The transcript pane's input bar, moved out of `ReplView.swift` so it can be compiled into
// the logic test bundle (`ReplView` itself pulls in `AppStore` and the whole daemon client
// stack, so nothing declared inside it was reachable from a test) — the same move
// `ChatTurnView.swift` made. The model chip's tests drive real input bars from it.

// MARK: - ReplInputBar

class ReplInputBar: NSView, NSTextViewDelegate, NSMenuItemValidation, ModelShortcutTarget, BackgroundShortcutTarget {

    var onSend:        ((String, [URL]) -> Void)?
    /// The Stop button / ⌘. — interrupt the running turn. Only reachable while one is running.
    var onInterrupt:   (() -> Void)?
    /// Fired whenever the text grows/shrinks; passes the ideal total bar height.
    var onHeightChange: ((CGFloat) -> Void)?

    static let minHeight: CGFloat = 46

    private var pendingImages: [URL] = []

    private let textScroll   = NSScrollView()
    let textView             = ChatTextView()
    private let placeholder  = NSTextField(labelWithString: "Message…")
    private let button       = NSButton()
    private let stopButton   = NSButton()
    /// The model chip, left of Send/Stop. Hidden for a session with no model state.
    let modelChip            = ModelChip()
    /// The popup the chip (or ⇧⌘M) opens, while it is open.
    private(set) var modelPopover: ModelPopover?
    private(set) var agentDefaultsPopover: ModelDefaultsPopover?
    private var textTopConstraint: NSLayoutConstraint!
    /// Extra height the image tray takes above the text while chips are attached.
    private static let trayExtra: CGFloat = 54
    /// The chip sits left of Send, or of Stop too while it shows. Exactly one of these two
    /// is active at a time; the text view stops short of the chip, whatever the chip's width.
    private var chipTrailingToSend: NSLayoutConstraint!
    private var chipTrailingToStop: NSLayoutConstraint!
    private var chipWidth: NSLayoutConstraint!
    private var modelStore: ModelStore?
    private var modelTag: String?
    private var modelAgentName: String?
    private var modelBinding: AnyCancellable?
    private var modelNoticeBinding: AnyCancellable?
    private var modelNoticePopover: ModelNoticePopover?
    private var modelNoticeId: Int?
    /// The Background activity chip (BA3), right-aligned in `backgroundSlot`, left of the model chip.
    let backgroundChip       = BackgroundChip()
    /// The space the chip lives in. `BackgroundChip.slotWidth` wide once the bar is bound to a session,
    /// whatever the chip shows, so the chip appearing, changing or going never changes the composer's
    /// width (and so never rewraps typed text or changes the bar's height). Only a narrow bar makes
    /// it give way (see `composerMinimumWidth`), and then by the bar's width alone.
    let backgroundSlot       = NSView()
    /// The Background activity popover, while it is open.
    private(set) var backgroundPopover: BackgroundPopover?
    /// Open, Stop, Show in Transcript: none until later slices provide them.
    var backgroundActions: BackgroundTaskActions = BackgroundTaskWindowActions.shared
    private var backgroundStore: BackgroundTaskStore?
    private var backgroundTag: String?
    private var backgroundDisplayName: String?
    private var backgroundBinding: AnyCancellable?
    private var backgroundSlotWidth: NSLayoutConstraint!
    private var backgroundSlotGap: NSLayoutConstraint!

    /// The composer never gets narrower than this, or than `composerMinimumFraction` of the bar,
    /// whichever is more, while the bar is wide enough for it at all. What gives way for it: the
    /// background slot first (its chip shows the icon alone, then nothing), then the model chip.
    static let composerMinimumWidth: CGFloat = 120
    static let composerMinimumFraction: CGFloat = 0.35
    /// Priorities of what gives way, weakest first. All stay under `NSLayoutConstraint.Priority.windowSizeStayPut`
    /// (750): a bar too narrow for its parts must squeeze them, never widen its window.
    private static let slotPriority = NSLayoutConstraint.Priority(600)
    private static let modelChipPriority = NSLayoutConstraint.Priority(700)
    private static let composerPriority = NSLayoutConstraint.Priority(740)
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

        // Stop button — shown only while a turn is running. ⌘. is the macOS
        // "cancel" shortcut; a hidden button's key equivalent never fires, so
        // it can't interrupt an idle session by accident.
        stopButton.bezelStyle = .inline
        stopButton.isBordered = false
        stopButton.wantsLayer = true
        stopButton.layer?.backgroundColor = Theme.redSweater.withAlphaComponent(0.30).cgColor
        stopButton.layer?.cornerRadius    = 5
        stopButton.attributedTitle = NSAttributedString(string: "■ Stop", attributes: btnAttrs)
        stopButton.toolTip        = "Interrupt Perri's current turn (⌘.)"
        stopButton.keyEquivalent  = "."
        stopButton.keyEquivalentModifierMask = .command
        stopButton.target = self
        stopButton.action = #selector(stopButtonAction)
        stopButton.isHidden = true
        stopButton.setAccessibilityLabel("Stop")
        stopButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stopButton)

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

        // Model chip — hidden (and zero-width, so the text view keeps its old extent) until the
        // daemon has a model state for this focus.
        modelChip.isHidden = true
        modelChip.target = self
        modelChip.action = #selector(showModelPopover(_:))
        addSubview(modelChip)
        chipWidth = modelChip.widthAnchor.constraint(equalToConstant: 0)
        chipWidth.priority = Self.modelChipPriority
        // Its width is `chipWidth`, which gives way (below the composer's minimum); the button's own
        // 750 resistance to compression would outrank that and the window's size.
        modelChip.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(500), for: .horizontal)
        chipTrailingToSend = modelChip.trailingAnchor.constraint(equalTo: button.leadingAnchor)
        chipTrailingToStop = modelChip.trailingAnchor.constraint(equalTo: stopButton.leadingAnchor)

        // Background activity slot: zero-width until the bar is bound to a session (so a bar with
        // no session keeps its old extent), then fixed. The chip is right-aligned inside it.
        backgroundSlot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backgroundSlot)
        backgroundChip.target = self
        backgroundChip.action = #selector(backgroundChipClicked(_:))
        backgroundSlot.addSubview(backgroundChip)
        backgroundSlotWidth = backgroundSlot.widthAnchor.constraint(equalToConstant: 0)
        backgroundSlotWidth.priority = Self.slotPriority
        let composerMinimum = textScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.composerMinimumWidth)
        let composerFraction = textScroll.widthAnchor.constraint(greaterThanOrEqualTo: widthAnchor,
                                                                 multiplier: Self.composerMinimumFraction)
        composerMinimum.priority = Self.composerPriority
        composerFraction.priority = Self.composerPriority
        // The gap between the slot and the model chip (or Send/Stop while the model chip is
        // hidden: it is zero-wide then and sits flush against them).
        backgroundSlotGap = backgroundSlot.trailingAnchor.constraint(equalTo: modelChip.leadingAnchor, constant: 0)

        textTopConstraint = textScroll.topAnchor.constraint(equalTo: border.bottomAnchor, constant: 9)

        NSLayoutConstraint.activate([
            // Image tray sits above the text scroll view when visible
            imageTray.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            imageTray.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -8),
            imageTray.topAnchor.constraint(equalTo: border.bottomAnchor, constant: 6),
            imageTray.heightAnchor.constraint(equalToConstant: 48),

            textScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            textTopConstraint,
            textScroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),

            // Placeholder anchored to the text inset area
            placeholder.leadingAnchor.constraint(equalTo: textScroll.leadingAnchor, constant: 4),
            placeholder.topAnchor.constraint(equalTo: textScroll.topAnchor, constant: 6),

            // The text view stops short of the background slot, which sits left of the model chip.
            // FV4: TranscriptModeChip goes between the background slot and modelChip.
            textScroll.trailingAnchor.constraint(equalTo: backgroundSlot.leadingAnchor, constant: -8),
            backgroundSlotGap,
            backgroundSlotWidth,
            backgroundSlot.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            modelChip.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            composerMinimum,
            composerFraction,
            backgroundSlot.heightAnchor.constraint(equalToConstant: BackgroundChip.height),
            backgroundSlot.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            backgroundChip.trailingAnchor.constraint(equalTo: backgroundSlot.trailingAnchor),
            backgroundChip.leadingAnchor.constraint(greaterThanOrEqualTo: backgroundSlot.leadingAnchor),
            backgroundChip.topAnchor.constraint(equalTo: backgroundSlot.topAnchor),
            backgroundChip.bottomAnchor.constraint(equalTo: backgroundSlot.bottomAnchor),
            chipTrailingToSend,
            chipWidth,
            modelChip.heightAnchor.constraint(equalToConstant: ModelChip.height),
            modelChip.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),

            stopButton.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -6),
            stopButton.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            stopButton.widthAnchor.constraint(equalToConstant: 64),
            stopButton.heightAnchor.constraint(equalToConstant: 26),

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
        registerForDraggedTypes(ImagePasteboard.draggedTypes)
        // NSTextView would otherwise swallow the drop (inserting a path) before the bar sees it.
        textView.onImageDrop = { [weak self] pb in self?.attachImages(from: pb) ?? false }
        textView.onDragHighlight = { [weak self] on in self?.setDropHighlight(on) }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Model chip

    /// How long a "Couldn't switch" message stays up.
    static let modelNoticeDuration: TimeInterval = 6

    /// The message about a failed switch of this bar's focus that is up now, if any.
    private(set) var modelNoticeText: String?

    /// Runs `work` after the notice's duration. A seam: tests capture the closure instead of
    /// waiting for it.
    var scheduleModelNoticeDismissal: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Tells VoiceOver about a new notice. A seam, like the one above.
    lazy var announceModelNotice: (String) -> Void = { [weak self] text in
        guard let self else { return }
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    /// Take the notice down now (it also goes by itself after `modelNoticeDuration`).
    func dismissModelNotice() {
        closeModelNoticePopover()
        modelNoticeText = nil
        if let tag = modelTag, let id = modelNoticeId { modelStore?.dismissFailure(tag: tag, id: id) }
        modelNoticeId = nil
    }

    private func closeModelNoticePopover() {
        modelNoticePopover?.close()
        modelNoticePopover = nil
    }

    /// Show `tag`'s model in the chip, live from `store`. Every bar bound to the same store
    /// updates from the same frame, which is what keeps two windows in step.
    func bindModel(tag: String, agentName: String?, store: ModelStore) {
        modelTag = tag
        modelAgentName = agentName
        modelStore = store
        modelBinding = Publishers.CombineLatest(store.$states.map { $0[tag] }.removeDuplicates(),
                                                store.$isConnected.removeDuplicates())
            .sink { [weak self] state, connected in
                self?.showModel(ModelPresentation.chip(state: state, isConnected: connected))
            }
        // A failure already held when the bar binds is old news; only a new one is shown.
        modelNoticeBinding = store.$failures.map { $0[tag] }.removeDuplicates().dropFirst().compactMap { $0 }
            .sink { [weak self] in self?.showModelNotice($0) }
    }

    /// Say that a switch of this focus failed: next to the chip, and to VoiceOver. Never takes
    /// the keyboard, never blocks the chip; it goes by itself.
    private func showModelNotice(_ failure: ModelSwitchFailure) {
        closeModelNoticePopover()
        modelNoticeId = failure.id
        modelNoticeText = failure.message
        announceModelNotice(failure.message)
        // The popup is the user's focus when it is open, and it shows the real state.
        if !modelChip.isHidden, modelPopover?.isShown != true {
            let notice = ModelNoticePopover(text: failure.message)
            modelNoticePopover = notice
            notice.show(relativeTo: modelChip)
        }
        scheduleModelNoticeDismissal(Self.modelNoticeDuration) { [weak self] in
            // A newer failure has its own timer.
            guard let self, self.modelNoticeId == failure.id else { return }
            self.dismissModelNotice()
        }
    }

    /// `nil` hides the chip: this session has no model state (restricted, hidden, or the
    /// daemon has said nothing). Hidden, it takes no width and cannot open a popup.
    private func showModel(_ chip: ModelPresentation.Chip?) {
        guard let chip else {
            modelChip.isHidden = true
            chipWidth.constant = 0
            setChipGap(0)
            modelPopover?.close()
            return
        }
        modelChip.apply(chip)
        modelChip.isHidden = false
        chipWidth.constant = modelChip.intrinsicContentSize.width
        setChipGap(-6)
        if !chip.isEnabled { modelPopover?.close() }
    }

    private func setChipGap(_ gap: CGFloat) {
        chipTrailingToSend.constant = gap
        chipTrailingToStop.constant = gap
    }

    // MARK: Background activity chip

    override func layout() {
        super.layout()
        fitBackgroundChipToSlot()
    }

    /// The chip shows what its slot has room for: the text, the icon alone, or nothing. Reads the
    /// slot's laid-out width (set by the bar's width, never by the chip), so it settles at once.
    private func fitBackgroundChipToSlot() {
        guard backgroundTag != nil else { return }
        let room = backgroundSlot.frame.width + 0.5
        backgroundChip.setFit(room >= BackgroundChip.slotWidth ? .full
                              : room >= BackgroundChip.iconWidth ? .iconOnly : .hidden)
    }

    /// Show `tag`'s background tasks in the chip, live from `store`. Every bar bound to the same
    /// store updates from the same delivery, which keeps two windows in step. Reserves the slot.
    func bindBackground(tag: String, store: BackgroundTaskStore, displayName: String? = nil) {
        backgroundTag = tag
        backgroundStore = store
        backgroundDisplayName = displayName
        backgroundSlotWidth.constant = BackgroundChip.slotWidth
        backgroundSlotGap.constant = -6
        backgroundBinding = store.changes
            .filter { $0 == tag }
            .sink { [weak self] _ in self?.refreshBackgroundChip() }
        refreshBackgroundChip()
    }

    /// Read the store and show its chip state. Changes only the chip's text and visibility, inside
    /// the fixed slot: no layout outside it, no first-responder change.
    private func refreshBackgroundChip() {
        guard let store = backgroundStore, let tag = backgroundTag else { return }
        let list = store.list(for: tag)
        backgroundChip.apply(list.chip, tooltip: list.chipTooltip)
    }

    /// A click on the chip (or Space on it with Full Keyboard Access, which is a keyboard intent).
    @objc private func backgroundChipClicked(_ sender: Any?) {
        toggleBackgroundPopover(takeKeyboard: NSApp.currentEvent?.type == .keyDown)
    }

    /// ⇧⌘B: open (or close) the Background activity popover, with the keyboard in it.
    @objc func showBackgroundPopover(_ sender: Any?) {
        toggleBackgroundPopover(takeKeyboard: true)
    }

    var canShowBackgroundPopover: Bool {
        backgroundTag != nil && backgroundStore?.tasksSupported == true
    }

    func toggleBackgroundPopover(takeKeyboard: Bool) {
        if let open = backgroundPopover, open.isShown {
            open.close()
            return
        }
        guard let store = backgroundStore, let tag = backgroundTag else { return }
        let popover = BackgroundPopover(tag: tag, displayName: backgroundDisplayName ?? tag, store: store,
                                        actions: backgroundActions)
        popover.onDidClose = { [weak self, weak popover] in
            if self?.backgroundPopover === popover { self?.backgroundPopover = nil }
        }
        backgroundPopover = popover
        // Anchored to the chip; to the slot while the chip is hidden (⇧⌘B with nothing to show).
        popover.show(relativeTo: backgroundChip.isHidden ? backgroundSlot : backgroundChip, takeKeyboard: takeKeyboard)
    }

    // MARK: Actions

    @objc private func sendButtonAction() { submitAction() }

    @objc private func stopButtonAction() { onInterrupt?() }

    /// ⇧⌘M, or a click on the chip: open (or close) the model popup.
    @objc func showModelPopover(_ sender: Any?) {
        if let open = modelPopover, open.isShown {
            open.close()
            return
        }
        guard let store = modelStore, let tag = modelTag, canShowModelPopover else { return }
        let popover = ModelPopover(tag: tag, agentName: modelAgentName, store: store)
        popover.onDidClose = { [weak self, weak popover] in
            if self?.modelPopover === popover { self?.modelPopover = nil }
        }
        popover.onShowAgentDefaults = { [weak self] in
            // After the model popup has finished closing.
            DispatchQueue.main.async { self?.showAgentDefaults(store: store) }
        }
        modelPopover = popover
        popover.show(relativeTo: modelChip)
    }

    /// "Agent defaults…": the per-agent defaults list, in a popover on the chip.
    func showAgentDefaults(store: ModelStore) {
        agentDefaultsPopover?.close()
        let popover = ModelDefaultsPopover(store: store)
        popover.onDidClose = { [weak self, weak popover] in
            if self?.agentDefaultsPopover === popover { self?.agentDefaultsPopover = nil }
        }
        agentDefaultsPopover = popover
        popover.show(relativeTo: modelChip)
    }

    var canShowModelPopover: Bool { !modelChip.isHidden && modelChip.isEnabled }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == ModelShortcut.action { return canShowModelPopover }
        if menuItem.action == BackgroundShortcut.action { return canShowBackgroundPopover }
        return true
    }

    private func submitAction() {
        var text         = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let imagesToSend = pendingImages
        // Allow send when images are present even with no text — synthesise a
        // description from filenames so Claude gets a non-empty message.
        if text.isEmpty && !imagesToSend.isEmpty {
            text = ChatSession.imageOnlyText
        }
        guard !text.isEmpty else { return }
        textView.string  = ""
        pendingImages    = []
        placeholder.isHidden = false
        // Hiding the tray does not release its chips. Each one holds a decoded
        // image, and they stayed retained for the lifetime of the pane —
        // `removeImageChip` got this right and the send path did not.
        clearImageTray()
        onHeightChange?(Self.minHeight)
        onSend?(text, imagesToSend)
    }

    // MARK: State

    func setRunning(_ running: Bool) {
        stopButton.isHidden = !running
        chipTrailingToSend.isActive = !running
        chipTrailingToStop.isActive = running
        button.alphaValue = running ? 0.5 : 1.0
        running ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
    }

    func setPendingCount(_ count: Int) {
        placeholder.stringValue = count > 0 ? "Message… (\(count) queued)" : "Message…"
    }

    // MARK: Drag-and-drop (images)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard ImagePasteboard.hasImages(sender.draggingPasteboard) else { return [] }
        setDropHighlight(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDropHighlight(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setDropHighlight(false)
        return attachImages(from: sender.draggingPasteboard)
    }

    func setDropHighlight(_ on: Bool) {
        layer?.borderWidth = on ? 1 : 0
        layer?.borderColor = Theme.cornflower.withAlphaComponent(0.6).cgColor
    }

    /// Attach every image on `pb` (file URLs or raw image data). False when none.
    @discardableResult
    func attachImages(from pb: NSPasteboard) -> Bool {
        let urls = ImagePasteboard.imageURLs(from: pb)
        guard !urls.isEmpty else { return false }
        urls.forEach { addImage($0) }
        return true
    }

    private func addImage(_ url: URL) {
        guard !pendingImages.contains(url) else { return }
        pendingImages.append(url)

        // Build a small thumbnail chip
        // An NSStackView, not a hand-wired container: the hand-built chain of
        // sibling constraints was found (via `nostromo-app layout-issues`) to
        // leave the thumbnail and ✕ zero-sized and the name pinned to a corner.
        let chip = NSStackView()
        chip.orientation = .horizontal
        chip.alignment   = .centerY
        chip.spacing     = 4
        chip.edgeInsets  = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        chip.wantsLayer  = true
        chip.layer?.cornerRadius = 4
        chip.layer?.backgroundColor = NSColor(white: 0.18, alpha: 1).cgColor
        chip.translatesAutoresizingMaskIntoConstraints = false

        let img = NSImageView()
        // Decoded to chip size, never to source size — see ThumbnailLoader.
        img.imageScaling = .scaleProportionallyUpOrDown
        let scale = window?.backingScaleFactor ?? 2
        ThumbnailLoader.load(url, scale: max(2, scale)) { [weak img] thumbnail in
            img?.image = thumbnail
        }
        img.translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = NSTextField(labelWithString: url.lastPathComponent)
        nameLabel.font          = .systemFont(ofSize: 9)
        nameLabel.textColor     = Theme.fgMuted
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

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

        [img, nameLabel, removeBtn].forEach { chip.addArrangedSubview($0) }
        NSLayoutConstraint.activate([
            img.widthAnchor.constraint(equalToConstant: 36),
            img.heightAnchor.constraint(equalToConstant: 36),
            nameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 90),
            chip.heightAnchor.constraint(equalToConstant: 44),
        ])

        imageTray.addArrangedSubview(chip)
        updateTrayLayout()
    }

    private static var urlKey = 0

    /// Show the tray and push the text down below it (or hide it and give the
    /// space back), then resize the bar. The tray is an overlay-free row above
    /// the text: without moving the text, the chips sat on top of what you typed.
    private func updateTrayLayout() {
        let hasImages = !pendingImages.isEmpty
        imageTray.isHidden = !hasImages
        textTopConstraint.constant = hasImages ? 9 + Self.trayExtra : 9
        onHeightChange?(idealBarHeight())
    }

    /// Tear the tray down to nothing. `NSStackView.removeArrangedSubview` only
    /// stops managing a view; releasing it needs `removeFromSuperview` too.
    private func clearImageTray() {
        for chip in imageTray.arrangedSubviews {
            imageTray.removeArrangedSubview(chip)
            chip.removeFromSuperview()
        }
        updateTrayLayout()
    }

    @objc private func removeImageChip(_ sender: NSButton) {
        guard let chip = sender.superview else { return }
        if let url = objc_getAssociatedObject(sender, &ReplInputBar.urlKey) as? URL {
            pendingImages.removeAll { $0 == url }
        }
        imageTray.removeArrangedSubview(chip)
        chip.removeFromSuperview()
        updateTrayLayout()
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        placeholder.isHidden = !textView.string.isEmpty
        onHeightChange?(idealBarHeight())
    }

    // MARK: Height calculation

    private func idealBarHeight() -> CGFloat {
        let insets  = textView.textContainerInset.height * 2
        let margins: CGFloat = 9 + 9 + 1 + (pendingImages.isEmpty ? 0 : Self.trayExtra)

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

// MARK: - ChatTextView

/// NSTextView subclass that fires `onSubmit` on Return (send) and passes
/// Shift+Return through as a regular newline.
/// Also blocks raw image data reads from the pasteboard to avoid triggering
/// the macOS Photos permission prompt — image files come via drag-and-drop instead.
class ChatTextView: NSTextView {
    var onSubmit: (() -> Void)?
    /// Attach images from a drop/paste; returns false when the pasteboard had none.
    var onImageDrop: ((NSPasteboard) -> Bool)?
    var onDragHighlight: ((Bool) -> Void)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if ImagePasteboard.hasImages(sender.draggingPasteboard) {
            onDragHighlight?(true)
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragHighlight?(false)
        super.draggingExited(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDragHighlight?(false)
        if ImagePasteboard.hasImages(sender.draggingPasteboard),
           onImageDrop?(sender.draggingPasteboard) == true { return true }
        return super.performDragOperation(sender)
    }

    /// ⌘V with an image on the clipboard attaches it; text pastes as before.
    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if pb.string(forType: .string) == nil,
           ImagePasteboard.hasImages(pb), onImageDrop?(pb) == true { return }
        super.paste(sender)
    }

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
