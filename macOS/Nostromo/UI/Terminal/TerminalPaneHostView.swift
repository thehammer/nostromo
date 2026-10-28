import AppKit
import Combine
import SwiftTerm

/// One terminal pane: a 24 pt header band (the shell and its directory, and a close x; shorter only in a
/// pane that is itself shorter), the
/// terminal below it, and, once the process has ended, an overlay with its exit code and
/// Restart / Close. Routed from `DynamicFocusView.makeLeafView` for pane ids `terminal-*`.
///
/// The view is a `TerminalByteSink`: it registers with `TerminalSessionStore` once it is in a
/// window and has a size, and unregisters when it leaves (so a hidden pane costs no output).
/// A refused attach is never silent: the daemon audits what the store reports.
///
/// The same terminal can be open in more than one window. The window a person last typed or clicked in
/// is the driver: its view fills the pane and its size is the terminal's (`TerminalSessionStore`
/// decides which). Any other window is a mirror: the view is held at exactly the daemon's cols x rows
/// in a clipping container, so it never reflows and never sends a resize (a pane smaller than the
/// terminal shows its top-left corner). The header says so, and a click or key makes it the driver.
///
/// A remote shell that is still `connecting` shows "Connecting to production · admin-portal · scheduler…"
/// with a spinner and no terminal view at all, so there is never a prompt, local or otherwise, before the
/// session begins; the terminal view appears when the daemon says `running`.
///
/// While the daemon is unreachable the pane says its shell ended and cannot be restarted; when the
/// daemon is back it shows what the daemon says (a shell that died with it is `ended`, with Restart).
///
/// A remote (`ecs`) pane is unmistakable in every state: a 3 pt hazard-red frame drawn by the host's
/// own layer (the content is inset by it), and a red header, pinned to the top of the pane, that always
/// names the environment, project, service and shell type (`TerminalChromeModel`). The environment is
/// its own fixed label on the left (never truncated, its font shrinks before it clips); the rest of the
/// header truncates, the mirror hint first. A pane of a kind this app does not know, or an `ecs` one the
/// daemon sent no target for, is red too and says REMOTE. From the daemon's
/// idle warning (13 minutes without a keystroke) a yellow banner under the header counts down to the
/// close, with Keep open.
///
/// Every pane has a Follow badge in its header (`FollowModel`: "Not shared", "Followed by Claudia",
/// "Paused, too much output"), in every window that shows the pane. Clicking it opens `FollowControlView`
/// in a popover: invite, stop, move or resume. Agent follow is invitation-only, so none of that happens
/// without a person's gesture.
///
/// Every control that changes a terminal (the x, Restart, Close, Keep open, and Terminal > Close Terminal
/// Pane) asks `TerminalInputGuard.allowsControl` first. A synthetic click does nothing, and the
/// refusal is reported to the daemon.
final class TerminalPaneHostView: NSView, TerminalByteSink, TerminalPaneLeaf, TerminalPixelSource {

    static let headerHeight = TerminalPaneHeaderView.height
    private static let overlayHeight: CGFloat = 40
    private static let bannerHeight = IdleBannerView.height

    /// The focus tag (named so it does not collide with `NSView.tag`, an `Int`).
    let focusTag: String
    let paneId: String
    let windowId: String

    private let store: TerminalSessionStore
    private let latency: TerminalLatencyStats
    private let header = TerminalPaneHeaderView()
    private let terminalView: NostromoTerminalView
    /// Holds the terminal view and clips it: a mirror can be larger than the pane.
    private let terminalContainer = ClickableClipView()
    /// Someone asked for the keyboard (or had it) while the pane was still connecting.
    private var focusWhenConnected = false
    /// Shown instead of the terminal while a remote shell connects.
    private let connectingView = NSView()
    private let connectingLabel = NSTextField(labelWithString: "")
    private let connectingSpinner = NSProgressIndicator()
    private let overlay = NSView()
    private let overlayLabel = NSTextField(labelWithString: "")
    private let restartButton = NSButton()
    private let overlayCloseButton = NSButton()
    /// Under a remote header, from the daemon's idle warning until a keystroke or Keep open.
    private let idleBanner = IdleBannerView()

    private var info: TerminalInfo?
    /// This view is not the one that sizes the terminal.
    private var isMirror = false
    /// The daemon's grid for the terminal, from its last replay or state.
    private var daemonGrid: (cols: Int, rows: Int)?
    private var changes: AnyCancellable?
    /// A rename or a new focus changes what the badge and the popover call things.
    private var focusChanges: AnyCancellable?
    private var registered = false
    /// The Follow popover on screen, and the state it was opened for (it closes when that changes).
    private var followPopover: NSPopover?
    private var followStateWhenOpened: (state: FollowModel.State, actions: [FollowAction])?
    /// A replay is being fed: its bytes are not an echo of a key.
    private var feedingReplay = false
    private var keyMonitor: Any?
    /// Restart was clicked: the new shell takes the keyboard when it appears.
    private var focusAfterRestart = false
    /// Shown in the overlay for a few seconds after the daemon refused input (a paste it could not take).
    private var inputNotice: String?
    private var inputNoticeToken = 0
    private static let inputNoticeLifetime: TimeInterval = 8

    init(tag: String, paneId: String, windowId: String,
         store: TerminalSessionStore = .shared, latency: TerminalLatencyStats = .shared) {
        self.focusTag = tag
        self.paneId = paneId
        self.windowId = windowId
        self.store = store
        self.latency = latency
        self.terminalView = NostromoTerminalView(windowId: windowId, store: store)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg.cgColor
        setAccessibilityIdentifier("terminal-pane")
        setAccessibilityLabel("Terminal")
        buildHeader()
        buildIdleBanner()
        buildOverlay()
        buildConnecting()
        terminalContainer.addSubview(terminalView)
        // A click on the pane (the terminal, the empty part beside a mirror, the header) takes the keyboard
        // and, in a mirror, the size.
        let claim: (NSEvent) -> Void = { [weak self] event in
            self?.terminalView.claimDriver(event: event)
            self?.focusTerminal()
        }
        terminalContainer.onMouseDown = claim
        header.onMouseDown = claim
        addSubview(terminalContainer)
        addSubview(connectingView)
        addSubview(header)
        addSubview(idleBanner)
        addSubview(overlay)
        info = store.info(forPane: paneId, tag: focusTag)
        terminalView.terminalId = info?.terminalId
        changes = store.changes.sink { [weak self] change in self?.handle(change) }
        // `@Published` announces before it changes: look again on the next turn of the main queue.
        focusChanges = FocusStore.shared.$focuses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.render() }
        render()
    }

    required init?(coder: NSCoder) {
        fatalError("TerminalPaneHostView is created in code")
    }

    deinit {
        store.unregister(self)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    // MARK: - TerminalPixelSource

    /// The whole body under the header: the terminal (a mirror's view can be larger than the pane and is
    /// clipped to this), the connecting message and, along the bottom, the ended overlay (translucent, so
    /// the terminal shows through it). An app-control screenshot paints over all of it.
    var terminalPixelArea: NSView { terminalContainer }

    // MARK: - Lookup (menus)

    /// The terminal pane that holds `responder` (a view inside it), if any.
    static func containing(_ responder: NSResponder?) -> TerminalPaneHostView? {
        var view = responder as? NSView
        while let current = view {
            if let host = current as? TerminalPaneHostView { return host }
            view = current.superview
        }
        return nil
    }

    /// Terminal > Close Terminal Pane. Does nothing unless a person chose it.
    func closeFromMenu() {
        guard let id = info?.terminalId else { return }
        guard TerminalInputGuard.allowsControl(event: NSApp.currentEvent, control: self, fromMenu: true) else {
            store.reportRefusal(terminalId: id, op: .close)
            return
        }
        store.close(terminalId: id)
    }

    /// Whether the terminal has selected text (Terminal > Send Selection to…).
    var hasSelection: Bool { terminalView.selectionActive }

    /// Terminal > Send Selection to…: the same list of focuses as the context menu, at the pane's
    /// top-left. Choosing one asks `TerminalInputGuard` (`NostromoTerminalView.sendSelectionTapped`).
    func showSendSelectionMenu() {
        terminalView.showSendSelectionMenu()
    }

    /// Edit > Find / Find Next: SwiftTerm's find bar (`sender` is the menu item; its tag says which).
    func performFind(_ sender: Any?) {
        terminalView.performFindPanelAction(sender)
    }

    /// The terminal view takes the keyboard.
    func focusTerminal() {
        // A pane still connecting shows its overlay; the hidden terminal view must not take the keyboard.
        guard info?.status != .connecting else {
            focusWhenConnected = true
            return
        }
        window?.makeFirstResponder(terminalView)
    }

    // MARK: - TerminalByteSink

    /// The grid the pane's own size gives (read for the driver only, so the view fills the pane).
    var preferredSize: (cols: Int, rows: Int)? {
        guard terminalView.frame.width > 1, terminalView.frame.height > 1 else { return nil }
        return terminalView.gridSize
    }

    func feed(_ bytes: [UInt8]) {
        terminalView.display(bytes)
        if feedingReplay {
            feedingReplay = false
        } else {
            latency.noteOutputFed()
        }
    }

    func reset() {
        terminalView.resetScreen()
        feedingReplay = true
    }

    func apply(cols: Int, rows: Int) {
        daemonGrid = (cols, rows)
        if isMirror {
            layoutTerminal()
            render()
        } else {
            terminalView.applyGrid(cols: cols, rows: rows)
        }
    }

    func setDriver(_ isDriver: Bool) {
        guard isMirror == isDriver else { return }
        isMirror = !isDriver
        terminalView.setDriver(isDriver)
        // Synchronously: the store reads `preferredSize` right after, and a driver's grid is the pane's.
        layoutTerminal()
        render()
    }

    func takeKeyboardFocus() {
        focusTerminal()
    }

    // MARK: - Layout and lifecycle

    override func layout() {
        super.layout()
        // The red frame is the host layer's border; the content sits inside it. The header is pinned to
        // the top edge, 24 pt tall or the whole content when the pane is shorter (the host clips a remote
        // pane, so nothing spills into a neighbour).
        let inset = isRemote ? TerminalChromeModel.frameWidth : 0
        let content = bounds.insetBy(dx: inset, dy: inset)
        let h = min(Self.headerHeight, max(0, content.height))
        header.frame = NSRect(x: content.minX, y: content.maxY - h, width: content.width, height: h)
        let bannerH = idleBanner.isHidden ? 0 : Self.bannerHeight
        idleBanner.frame = NSRect(x: content.minX, y: content.maxY - h - bannerH, width: content.width, height: bannerH)
        let bodyTop = content.maxY - h - bannerH
        let body = NSRect(x: content.minX, y: content.minY, width: content.width, height: max(0, bodyTop - content.minY))
        terminalContainer.frame = body
        connectingView.frame = body
        layoutConnecting()
        layoutTerminal()
        let overlayH = min(Self.overlayHeight, body.height)
        overlay.frame = NSRect(x: body.minX, y: body.minY, width: body.width, height: overlayH)
        layoutOverlay()
        registerIfReady()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installKeyMonitor()
            needsLayout = true
            registerIfReady()
        } else {
            // A layout rebuild detaches and re-adds a pane in one go: only a view still without a
            // window afterwards is really gone (hidden focus, closed window).
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window == nil else { return }
                self.unregisterFromStore()
            }
        }
    }

    /// The driver's view fills the pane; a mirror's is pinned to the daemon's grid.
    private func layoutTerminal() {
        let body = terminalContainer.bounds
        if isMirror, let grid = daemonGrid {
            terminalView.pinGrid(cols: grid.cols, rows: grid.rows, containerHeight: body.height)
        } else if terminalView.frame != body {
            terminalView.frame = body
        }
    }

    // MARK: - Private: store

    private func registerIfReady() {
        guard !registered, window != nil, preferredSize != nil else { return }
        registered = true
        store.register(self, tag: focusTag, paneId: paneId)
    }

    private func unregisterFromStore() {
        guard registered else { return }
        registered = false
        store.unregister(self)
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func handle(_ change: TerminalChange) {
        if case .refused(let frame) = change {
            showInputNotice(for: frame)
            return
        }
        if case .availability = change {
            render()
            return
        }
        guard case .info(let updated) = change, updated.paneId == paneId, updated.tag == focusTag else { return }
        let restarted = info.map { $0.terminalId != updated.terminalId } ?? false
        info = updated
        terminalView.terminalId = updated.terminalId
        render()
        if restarted && focusAfterRestart {
            focusAfterRestart = false
            focusTerminal()
        }
    }

    /// The daemon refused input for this terminal (too large a frame, or the program is not reading):
    /// say so in the overlay, so a paste that did not arrive is never silent.
    private func showInputNotice(for frame: TerminalRefusedFrame) {
        guard let id = info?.terminalId, frame.terminalId == id, let notice = frame.overlayNotice else { return }
        inputNotice = notice
        inputNoticeToken += 1
        let token = inputNoticeToken
        render()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.inputNoticeLifetime) { [weak self] in
            guard let self, self.inputNoticeToken == token else { return }
            self.inputNotice = nil
            self.render()
        }
    }

    /// Time a key down in this terminal view, for `TerminalLatencyStats`.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if let self, let window = self.window, event.window === window,
               window.firstResponder === self.terminalView {
                self.latency.noteKeyDown()
            }
            return event
        }
    }

    // MARK: - Private: header and overlay

    private func render() {
        applyChrome()
        idleBanner.update(info: info)
        let daemonStopped = info.map { store.isDaemonUnavailable(terminalId: $0.terminalId) } ?? false
        let ended = info?.status == .ended
        let notice = (ended || daemonStopped) ? nil : inputNotice
        overlay.isHidden = !ended && !daemonStopped && notice == nil
        restartButton.isEnabled = !daemonStopped
        restartButton.alphaValue = daemonStopped ? 0.4 : 1
        if daemonStopped {
            // Never a silent dead prompt: the shell is gone or unknown. Nothing here can act until the
            // daemon answers again.
            overlayLabel.stringValue = "Nostromo daemon stopped. This shell has ended."
            restartButton.isHidden = info?.kind != .local
        } else if ended {
            if info?.endedReason == "daemon_stopped" {
                overlayLabel.stringValue = "[process ended: Nostromo daemon restarted]"
            } else if let code = info?.exitCode {
                overlayLabel.stringValue = "[process exited with code \(code)]"
            } else {
                overlayLabel.stringValue = "[process ended]"
            }
            restartButton.isHidden = info?.kind != .local
        } else if let notice {
            overlayLabel.stringValue = notice
            restartButton.isHidden = true
        }
        overlayCloseButton.isHidden = notice != nil || daemonStopped
        var hint = ""
        if let grid = daemonGrid, isMirror, !daemonStopped, !ended {
            hint = "Mirroring at \(grid.cols)\u{00D7}\(grid.rows), type here to drive"
        }
        let follow = followModel()
        header.apply(info: info, mirrorHint: hint, follow: follow)
        closeFollowPopoverIfStale(follow)
        renderConnecting()
        overlayLabel.toolTip = overlayLabel.stringValue
        needsLayout = true
    }

    private var isRemote: Bool { info.map { TerminalChromeModel.isRemote($0) } ?? false }

    /// The red frame (the layer's border) of a remote pane. Only a remote pane needs the host to clip
    /// (a local pane's children are all inside it).
    private func applyChrome() {
        let remote = isRemote
        layer?.borderWidth = remote ? TerminalChromeModel.frameWidth : 0
        layer?.borderColor = info.flatMap(TerminalChromeModel.frameColor(for:))?.cgColor
        layer?.masksToBounds = remote
        needsLayout = true
    }

    private func buildIdleBanner() {
        idleBanner.keepOpenButton.target = self
        idleBanner.keepOpenButton.action = #selector(keepOpenTapped(_:))
        idleBanner.onVisibilityChange = { [weak self] in self?.needsLayout = true }
    }

    private func buildHeader() {
        header.closeButton.target = self
        header.closeButton.action = #selector(closeTapped(_:))
        header.followButton.target = self
        header.followButton.action = #selector(followBadgeTapped(_:))
    }

    /// What the Follow badge and its popover say: nil until the daemon has described the pane.
    private func followModel() -> FollowModel? {
        info.map { FollowModel(info: $0, focuses: FollowModel.options(from: FocusStore.shared.focuses)) }
    }

    /// The popover is for the state (and the buttons) it was opened with: once the daemon changes them (an
    /// invite landed, the agent paused, the shell ended), the popover goes away rather than offer buttons that no longer apply.
    private func closeFollowPopoverIfStale(_ model: FollowModel?) {
        guard let popover = followPopover else { return }
        guard popover.isShown else {
            followPopover = nil
            return
        }
        if model?.state != followStateWhenOpened?.state || model?.actions != followStateWhenOpened?.actions {
            popover.close()
            followPopover = nil
        }
    }

    /// The terminal view gives way to the connecting message until the shell is running.
    private func renderConnecting() {
        let connecting = info?.status == .connecting
        terminalContainer.isHidden = connecting
        connectingView.isHidden = !connecting
        if connecting {
            // Hiding a view does not take the keyboard from it: let go, so nothing is typed into a
            // shell that is not there yet (the store drops that input too).
            if let window, window.firstResponder === terminalView {
                window.makeFirstResponder(nil)
                focusWhenConnected = true
            }
            if let target = info?.target {
                connectingLabel.stringValue = RemoteShellStore.connectingMessage(for: target)
            } else {
                connectingLabel.stringValue = "Connecting\u{2026}"
            }
            connectingSpinner.startAnimation(nil)
        } else {
            connectingSpinner.stopAnimation(nil)
            // The keyboard was held back while connecting: hand it over now the shell is there.
            if focusWhenConnected, info?.status == .running {
                focusWhenConnected = false
                window?.makeFirstResponder(terminalView)
            }
        }
    }

    private func buildConnecting() {
        connectingView.wantsLayer = true
        connectingView.layer?.backgroundColor = Theme.bg.cgColor
        connectingView.isHidden = true
        connectingView.setAccessibilityIdentifier("terminal-connecting")
        connectingLabel.font = Theme.statusFont
        connectingLabel.textColor = Theme.fg
        connectingLabel.lineBreakMode = .byTruncatingMiddle
        connectingLabel.alignment = .center
        connectingLabel.setAccessibilityIdentifier("terminal-connecting-label")
        connectingSpinner.style = .spinning
        connectingSpinner.controlSize = .small
        connectingSpinner.isIndeterminate = true
        connectingView.addSubview(connectingSpinner)
        connectingView.addSubview(connectingLabel)
    }

    /// The spinner above the message, both centred in the pane.
    private func layoutConnecting() {
        let bounds = connectingView.bounds
        let spinnerSize: CGFloat = 16
        let labelSize = connectingLabel.intrinsicContentSize
        let labelWidth = min(labelSize.width, max(0, bounds.width - 20))
        let totalHeight = spinnerSize + 8 + labelSize.height
        let top = (bounds.height + totalHeight) / 2
        connectingSpinner.frame = NSRect(x: (bounds.width - spinnerSize) / 2, y: top - spinnerSize,
                                         width: spinnerSize, height: spinnerSize)
        connectingLabel.frame = NSRect(x: (bounds.width - labelWidth) / 2, y: top - totalHeight,
                                       width: labelWidth, height: labelSize.height)
    }

    private func buildOverlay() {
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.96).cgColor
        overlay.isHidden = true
        overlayLabel.font = Theme.statusFont
        overlayLabel.textColor = Theme.fg
        // A narrow pane must not clip the message at an edge: keep both ends and drop the middle.
        overlayLabel.lineBreakMode = .byTruncatingMiddle
        overlayLabel.setAccessibilityIdentifier("terminal-ended")
        style(restartButton, title: "Restart", identifier: "terminal-restart", label: "Restart terminal",
              action: #selector(restartTapped(_:)), filled: true)
        style(overlayCloseButton, title: "Close", identifier: "terminal-close", label: "Close terminal pane",
              action: #selector(overlayCloseTapped(_:)), filled: true)
        overlay.addSubview(overlayLabel)
        overlay.addSubview(restartButton)
        overlay.addSubview(overlayCloseButton)
    }

    /// Borderless with explicit colours: a system bezel's title follows the Mac's light/dark setting
    /// and vanishes on this always-dark UI (see `ModelChip`).
    private func style(_ button: NSButton, title: String, identifier: String, label: String,
                       action: Selector, filled: Bool) {
        button.isBordered = false
        button.target = self
        button.action = action
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: filled ? Theme.statusFont : NSFont.systemFont(ofSize: 16, weight: .regular),
            .foregroundColor: filled ? Theme.fg : Theme.fgMuted,
        ])
        button.wantsLayer = true
        if filled {
            button.layer?.backgroundColor = NSColor(white: 0.24, alpha: 1).cgColor
            button.layer?.cornerRadius = 4
        }
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(label)
    }

    private func layoutOverlay() {
        let h = overlay.bounds.height
        let buttonH: CGFloat = 24
        let closeW: CGFloat = overlayCloseButton.isHidden ? 0 : 60
        let restartW: CGFloat = restartButton.isHidden ? 0 : 72
        let gap: CGFloat = restartButton.isHidden ? 0 : 8
        var x = overlay.bounds.width - 10 - closeW
        overlayCloseButton.frame = NSRect(x: x, y: (h - buttonH) / 2, width: closeW, height: buttonH)
        x -= gap + restartW
        restartButton.frame = NSRect(x: x, y: (h - buttonH) / 2, width: restartW, height: buttonH)
        let labelSize = overlayLabel.intrinsicContentSize
        overlayLabel.frame = NSRect(x: 10, y: (h - labelSize.height) / 2,
                                    width: max(0, x - 20), height: labelSize.height)
    }

    // MARK: - Actions (each asks the guard first)

    /// Opens (or closes) the Follow popover. Harmless: it only shows the choices; Invite, Stop following
    /// and Resume are in the popover and each of them asks `TerminalInputGuard`.
    @objc private func followBadgeTapped(_ sender: NSButton) {
        if let popover = followPopover, popover.isShown {
            popover.close()
            followPopover = nil
            return
        }
        guard let model = followModel() else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        let content = FollowControlView(model: model, store: store) { [weak popover] in popover?.close() }
        content.onSizeChange = { [weak popover] size in popover?.contentSize = size }
        let controller = NSViewController()
        controller.view = content
        popover.contentSize = content.frame.size
        popover.contentViewController = controller
        followPopover = popover
        followStateWhenOpened = (model.state, model.actions)
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    @objc private func closeTapped(_ sender: NSButton) {
        guard let id = info?.terminalId else { return }
        guard TerminalInputGuard.allowsControl(event: NSApp.currentEvent, control: sender) else {
            store.reportRefusal(terminalId: id, op: .close)
            return
        }
        store.close(terminalId: id)
    }

    @objc private func overlayCloseTapped(_ sender: NSButton) {
        guard let id = info?.terminalId else { return }
        guard TerminalInputGuard.allowsControl(event: NSApp.currentEvent, control: sender) else {
            store.reportRefusal(terminalId: id, op: .close)
            return
        }
        store.close(terminalId: id)
    }

    @objc private func keepOpenTapped(_ sender: NSButton) {
        guard let id = info?.terminalId else { return }
        guard TerminalInputGuard.allowsControl(event: NSApp.currentEvent, control: sender) else {
            store.reportRefusal(terminalId: id, op: .keepAlive)
            return
        }
        store.keepAlive(terminalId: id)
    }

    @objc private func restartTapped(_ sender: NSButton) {
        guard let id = info?.terminalId else { return }
        guard TerminalInputGuard.allowsControl(event: NSApp.currentEvent, control: sender) else {
            store.reportRefusal(terminalId: id, op: .restart)
            return
        }
        focusAfterRestart = true
        store.restart(terminalId: id)
    }
}

/// Clips its subviews to its bounds (a mirrored terminal can be larger than the pane) and reports a
/// click anywhere in it, including the part the terminal view does not cover. Subviews that take clicks
/// themselves (the terminal, the header's buttons) still do.
private final class ClickableClipView: NSView {
    var onMouseDown: ((NSEvent) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("ClickableClipView is created in code")
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?(event)
    }
}
