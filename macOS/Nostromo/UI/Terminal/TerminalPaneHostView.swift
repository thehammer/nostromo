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
/// Every control that changes a terminal (the x, Restart, Close, and Terminal > Close Terminal
/// Pane) asks `TerminalInputGuard.allowsControl` first. A synthetic click does nothing, and the
/// refusal is reported to the daemon.
final class TerminalPaneHostView: NSView, TerminalByteSink {

    static let headerHeight: CGFloat = 24
    private static let overlayHeight: CGFloat = 40

    let tag: String
    let paneId: String
    let windowId: String

    private let store: TerminalSessionStore
    private let latency: TerminalLatencyStats
    private let header = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let terminalView: NostromoTerminalView
    private let overlay = NSView()
    private let overlayLabel = NSTextField(labelWithString: "")
    private let restartButton = NSButton()
    private let overlayCloseButton = NSButton()

    private var info: TerminalInfo?
    private var changes: AnyCancellable?
    private var registered = false
    /// A replay is being fed: its bytes are not an echo of a key.
    private var feedingReplay = false
    private var keyMonitor: Any?
    /// Restart was clicked: the new shell takes the keyboard when it appears.
    private var focusAfterRestart = false

    init(tag: String, paneId: String, windowId: String,
         store: TerminalSessionStore = .shared, latency: TerminalLatencyStats = .shared) {
        self.tag = tag
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
        addSubview(terminalView)
        addSubview(header)
        addSubview(overlay)
        info = store.info(forPane: paneId, tag: tag)
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

    /// The terminal view takes the keyboard.
    func focusTerminal() {
        window?.makeFirstResponder(terminalView)
    }

    // MARK: - TerminalByteSink

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
        terminalView.applyGrid(cols: cols, rows: rows)
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
        terminalView.frame = body
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

    // MARK: - Private: store

    private func registerIfReady() {
        guard !registered, window != nil, preferredSize != nil else { return }
        registered = true
        store.register(self, tag: tag, paneId: paneId)
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
        guard case .info(let updated) = change, updated.paneId == paneId, updated.tag == tag else { return }
        let restarted = info.map { $0.terminalId != updated.terminalId } ?? false
        info = updated
        terminalView.terminalId = updated.terminalId
        render()
        if restarted && focusAfterRestart {
            focusAfterRestart = false
            focusTerminal()
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
        let ended = info?.status == .ended
        overlay.isHidden = !ended
        if ended {
            if let code = info?.exitCode {
                overlayLabel.stringValue = "[process exited with code \(code)]"
            } else {
                overlayLabel.stringValue = "[process ended]"
            }
            restartButton.isHidden = info?.kind != .local
        }
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
        header.addSubview(titleLabel)
        header.addSubview(closeButton)
    }

    private func buildOverlay() {
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.96).cgColor
        overlay.isHidden = true
        overlayLabel.font = Theme.statusFont
        overlayLabel.textColor = Theme.fg
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
        titleLabel.frame = NSRect(x: 10, y: (h - labelSize.height) / 2,
                                  width: max(0, header.bounds.width - closeWidth - 20), height: labelSize.height)
    }

    private func layoutOverlay() {
        let h = overlay.bounds.height
        let buttonH: CGFloat = 24
        let closeW: CGFloat = 60
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
