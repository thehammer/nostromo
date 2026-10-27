import AppKit
import Combine
import SwiftTerm

/// One terminal pane: a 24 pt header band (the shell and its directory, and a close x), the
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
/// Every control that changes a terminal (the x, Restart, Close, and Terminal > Close Terminal
/// Pane) asks `TerminalInputGuard.allowsControl` first. A synthetic click does nothing, and the
/// refusal is reported to the daemon.
final class TerminalPaneHostView: NSView, TerminalByteSink, TerminalPaneLeaf {

    static let headerHeight: CGFloat = 24
    private static let overlayHeight: CGFloat = 40

    /// The focus tag (named so it does not collide with `NSView.tag`, an `Int`).
    let focusTag: String
    let paneId: String
    let windowId: String

    private let store: TerminalSessionStore
    private let latency: TerminalLatencyStats
    private let header = ClickableClipView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let terminalView: NostromoTerminalView
    /// Holds the terminal view and clips it: a mirror can be larger than the pane.
    private let terminalContainer = ClickableClipView()
    private let mirrorHint = NSTextField(labelWithString: "")
    /// Shown instead of the terminal while a remote shell connects.
    private let connectingView = NSView()
    private let connectingLabel = NSTextField(labelWithString: "")
    private let connectingSpinner = NSProgressIndicator()
    private let overlay = NSView()
    private let overlayLabel = NSTextField(labelWithString: "")
    private let restartButton = NSButton()
    private let overlayCloseButton = NSButton()

    private var info: TerminalInfo?
    /// This view is not the one that sizes the terminal.
    private var isMirror = false
    /// The daemon's grid for the terminal, from its last replay or state.
    private var daemonGrid: (cols: Int, rows: Int)?
    private var changes: AnyCancellable?
    private var registered = false
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
        addSubview(overlay)
        info = store.info(forPane: paneId, tag: focusTag)
        terminalView.terminalId = info?.terminalId
        changes = store.changes.sink { [weak self] change in self?.handle(change) }
        render()
    }

    required init?(coder: NSCoder) {
        fatalError("TerminalPaneHostView is created in code")
    }

    deinit {
        store.unregister(self)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

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

    /// Edit > Find / Find Next: SwiftTerm's find bar (`sender` is the menu item; its tag says which).
    func performFind(_ sender: Any?) {
        terminalView.performFindPanelAction(sender)
    }

    /// The terminal view takes the keyboard.
    func focusTerminal() {
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
        let h = Self.headerHeight
        header.frame = NSRect(x: 0, y: bounds.height - h, width: bounds.width, height: h)
        let body = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - h))
        terminalContainer.frame = body
        connectingView.frame = body
        layoutConnecting()
        layoutTerminal()
        let overlayH = min(Self.overlayHeight, body.height)
        overlay.frame = NSRect(x: 0, y: 0, width: body.width, height: overlayH)
        layoutHeader()
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
        titleLabel.stringValue = info?.headerTitle() ?? "Terminal"
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
        if let grid = daemonGrid, isMirror, !daemonStopped, !ended {
            mirrorHint.stringValue = "Mirroring at \(grid.cols)\u{00D7}\(grid.rows), type here to drive"
        } else {
            mirrorHint.stringValue = ""
        }
        mirrorHint.isHidden = mirrorHint.stringValue.isEmpty
        renderConnecting()
        overlayLabel.toolTip = overlayLabel.stringValue
        needsLayout = true
    }

    private func buildHeader() {
        header.wantsLayer = true
        header.layer?.backgroundColor = Theme.bgBar.cgColor
        titleLabel.font = Theme.statusFont
        titleLabel.textColor = Theme.fgMuted
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setAccessibilityIdentifier("terminal-title")
        style(closeButton, title: "\u{00D7}", identifier: "terminal-close-x", label: "Close terminal",
              action: #selector(closeTapped(_:)), filled: false)
        mirrorHint.font = Theme.statusFont
        mirrorHint.textColor = Theme.fgMuted
        mirrorHint.lineBreakMode = .byTruncatingHead
        mirrorHint.isHidden = true
        mirrorHint.setAccessibilityIdentifier("terminal-mirror-hint")
        header.addSubview(titleLabel)
        header.addSubview(mirrorHint)
        header.addSubview(closeButton)
    }

    /// The terminal view gives way to the connecting message until the shell is running.
    private func renderConnecting() {
        let connecting = info?.status == .connecting
        terminalContainer.isHidden = connecting
        connectingView.isHidden = !connecting
        if connecting {
            if let target = info?.target {
                connectingLabel.stringValue = RemoteShellStore.connectingMessage(for: target)
            } else {
                connectingLabel.stringValue = "Connecting\u{2026}"
            }
            connectingSpinner.startAnimation(nil)
        } else {
            connectingSpinner.stopAnimation(nil)
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

    private func layoutHeader() {
        let h = Self.headerHeight
        let closeWidth: CGFloat = 28
        closeButton.frame = NSRect(x: header.bounds.width - closeWidth - 2, y: 0, width: closeWidth, height: h)
        let labelSize = titleLabel.intrinsicContentSize
        let available = max(0, header.bounds.width - closeWidth - 20)
        // The hint keeps its width unless the pane is very narrow; the title gives way to it.
        let hintW = mirrorHint.isHidden ? 0 : min(mirrorHint.intrinsicContentSize.width, available * 0.6)
        let hintGap: CGFloat = mirrorHint.isHidden ? 0 : 8
        mirrorHint.frame = NSRect(x: 10 + available - hintW, y: (h - labelSize.height) / 2,
                                  width: hintW, height: labelSize.height)
        titleLabel.frame = NSRect(x: 10, y: (h - labelSize.height) / 2,
                                  width: max(0, available - hintW - hintGap), height: labelSize.height)
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
