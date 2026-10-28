import AppKit
import SwiftTerm

/// SwiftTerm's `TerminalView` wired to the daemon-owned shell: keystrokes go to
/// `TerminalSessionStore.sendInput`, the grid size to `resize`, and the store feeds bytes back in.
/// SwiftTerm is imported only here and in `TerminalPaneHostView`; everything else is in the test
/// target too.
///
/// Nothing a person did not do reaches the shell. Every path that sends bytes (`send`, `insertText`,
/// `paste`) asks `TerminalInputGuard` first; a refused one sends nothing and tells the daemon, which
/// audits it (`terminal_refusal_report`, at most one a second per terminal).
///
/// A paste, dictation or text replacement that contains a newline asks first unless the pane is KNOWN
/// to be local (`PastePolicy`): an `ecs` pane, a pane of a kind this app does not know, and a pane the
/// store has no record of all ask, and with no window to hang the confirmation on the text is refused,
/// never sent. Nothing falls through to a plain paste.
///
/// Typed input and the emulator's own replies are told apart by the SwiftTerm path they take, not by
/// `NSApp.currentEvent`. In SwiftTerm 1.18 (pinned exactly) every byte reaches `send(source:data:)`
/// of the delegate by one of two routes: `TerminalView.send(data:)`, which keys, `insertText` and
/// paste use, and `Terminal`'s own `send(source: Terminal, ...)`, which the cursor-position and
/// device-attributes replies, focus reports and mouse reports use. The second is overridden below;
/// bytes that arrive through it are marked `auto_reply` so they never count as a keystroke (the
/// daemon's remote idle rule, 2e). `keyDown` and friends are `public override` in SwiftTerm and
/// cannot be overridden here, which is why the reply route is the one marked.
final class NostromoTerminalView: TerminalView, TerminalViewDelegate {

    /// Lines of history kept (criterion 2).
    static let scrollbackLines = 10_000

    /// The terminal this view shows (the host sets it as the daemon describes the pane).
    var terminalId: String?
    let windowId: String
    private let store: TerminalSessionStore
    /// > 0 while SwiftTerm is sending something the emulator generated (see the type's comment).
    private var emulatorReplyDepth = 0
    /// False while this view is a mirror: it is held at the daemon's grid (`pinGrid`) and never
    /// reports its own size.
    private(set) var isDriver = true
    private var pendingResize: DispatchWorkItem?
    /// Decides whether a paste or dictated text goes straight in, asks first or is refused.
    private let pasteGate: RemotePasteGate
    /// The paste confirmation on screen, if any.
    var pasteConfirm: PasteConfirmSheet? { pasteGate.pasteConfirm }
    /// The wait before a driver's new grid goes to the daemon, so dragging a divider sends one frame.
    static let resizeDebounce: TimeInterval = 0.05

    init(windowId: String, store: TerminalSessionStore) {
        self.windowId = windowId
        self.store = store
        self.pasteGate = RemotePasteGate(store: store)
        super.init(frame: .zero, font: Theme.codeFont(size: 13), options: TerminalOptions(scrollback: Self.scrollbackLines))
        terminalDelegate = self
        nativeBackgroundColor = Theme.bg
        nativeForegroundColor = Theme.fg
    }

    required init?(coder: NSCoder) {
        fatalError("NostromoTerminalView is created in code")
    }

    /// The grid this view currently has.
    var gridSize: (cols: Int, rows: Int) {
        let terminal = getTerminal()
        return (terminal.cols, terminal.rows)
    }

    /// Become the driver (the frame is the pane's again, set by the host) or a mirror.
    func setDriver(_ driver: Bool) {
        guard driver != isDriver else { return }
        isDriver = driver
        pendingResize?.cancel()
        pendingResize = nil
    }

    /// Hold this view at exactly `cols` x `rows` of cells, top-left in a container `containerHeight`
    /// tall, whatever the pane's size: the grid is set directly (SwiftTerm's own resize would soft-reset
    /// the terminal), and the frame is the size that grid needs, so SwiftTerm's `setFrameSize` finds
    /// nothing to recompute and no reflow happens. The extra quarter point keeps floating-point rounding
    /// from losing the last column or row.
    func pinGrid(cols: Int, rows: Int, containerHeight: CGFloat) {
        let terminal = getTerminal()
        if terminal.cols != cols || terminal.rows != rows {
            terminal.resize(cols: cols, rows: rows)
            needsDisplay = true
        }
        let optimal = getOptimalFrameSize()
        let size = NSSize(width: optimal.width + 0.25, height: optimal.height + 0.25)
        let frame = NSRect(x: 0, y: containerHeight - size.height, width: size.width, height: size.height)
        if self.frame != frame { self.frame = frame }
    }

    /// Draw bytes from the daemon.
    func display(_ bytes: [UInt8]) {
        feed(byteArray: bytes[...])
    }

    /// Match the daemon's size for this terminal (a replay's `cols` x `rows`). SwiftTerm sizes its
    /// grid from the frame, so the frame is nudged afterwards to let it settle back to the pane's
    /// own size (which the delegate then reports to the daemon).
    func applyGrid(cols: Int, rows: Int) {
        guard gridSize.cols != cols || gridSize.rows != rows else { return }
        resize(cols: cols, rows: rows)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.setFrameSize(self.frame.size)
        }
    }

    /// Clear the screen and every mode (a full reset) before a replay is drawn.
    func resetScreen() {
        feed(text: "\u{1b}c")
    }

    // MARK: - Accessibility

    /// The terminal is a text area; its screen text is exposed only in a QA build (see `accessibilityValue`).
    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }

    override func accessibilityLabel() -> String? { "Terminal" }

    /// No screen text in the real app: `AppControlServer` reads accessibility values, and an agent may
    /// read a terminal only through `nostromo_read_terminal_screen`. A QA build that allows synthetic
    /// input (`SyntheticInputGate.allowsSynthetic`) still returns it for `terminal-local.sh`.
    override func accessibilityValue() -> Any? {
        TerminalScreenAccess.accessibilityValue(screenText: { self.screenText(limit: 20_000) })
    }

    /// The active buffer as text, newest `limit` characters.
    func screenText(limit: Int) -> String {
        let text = String(data: getTerminal().getBufferAsData(kind: .active), encoding: .utf8) ?? ""
        return String(text.suffix(limit))
    }

    // MARK: - Driving

    /// A click in the terminal makes this window the one that sizes it. A click app-control made does not.
    override func mouseDown(with event: NSEvent) {
        claimDriver(event: event)
        super.mouseDown(with: event)
    }

    /// A person clicked (or is about to type) in this view: it drives the terminal.
    func claimDriver(event: NSEvent?) {
        guard let terminalId,
              TerminalInputGuard.verdict(origin: .typed, event: event) != .refused else { return }
        store.claimDriver(terminalId: terminalId, fromWindow: windowId)
    }

    // MARK: - Input (every path asks the guard first)

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard TerminalInputGuard.verdict(origin: .typed, event: NSApp.currentEvent) != .refused else {
            refuse(.input)
            return
        }
        // Dictation and text replacement can carry a newline: into a remote shell that asks too.
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        let target = terminalId
        pasteGate.submit(text, terminalId: target, window: window, refusedOp: .input, fromClipboard: false) { [weak self] in
            // The sheet named `target`: if the view was rebound while it was up, nothing is sent.
            guard let self, self.terminalId == target else { return }
            self.insertTextConfirmed(string, replacementRange: replacementRange)
        }
    }

    override func paste(_ sender: Any) {
        guard TerminalInputGuard.verdict(origin: .typed, event: NSApp.currentEvent) != .refused else {
            refuse(.paste)
            return
        }
        // SwiftTerm's paste reads the general pasteboard (and honours bracketed paste), so read the same.
        let pasteboard = NSPasteboard.general
        let target = terminalId
        pasteGate.submit(pasteboard.string(forType: .string) ?? "", terminalId: target, window: window,
                         refusedOp: .paste, fromClipboard: true) { [weak self] in
            // The sheet named `target`: if the view was rebound while it was up, nothing is sent.
            guard let self, self.terminalId == target else { return }
            self.pasteConfirmed(sender)
        }
    }

    /// The emulator answering on its own (cursor position, device attributes, focus and mouse
    /// reports). Everything sent while this runs is an auto-reply.
    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        guard TerminalInputGuard.verdict(origin: .emulatorReply, event: NSApp.currentEvent) != .refused else {
            refuse(.input)
            return
        }
        emulatorReplyDepth += 1
        defer { emulatorReplyDepth -= 1 }
        super.send(source: source, data: data)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard let terminalId else { return }
        let origin: TerminalInputOrigin = emulatorReplyDepth > 0 ? .emulatorReply : .typed
        switch TerminalInputGuard.verdict(origin: origin, event: NSApp.currentEvent) {
        case .refused:
            refuse(.input)
        case .keystroke:
            store.sendInput(terminalId: terminalId, bytes: Array(data), fromWindow: windowId, autoReply: false)
        case .autoReply:
            store.sendInput(terminalId: terminalId, bytes: Array(data), fromWindow: windowId, autoReply: true)
        }
    }

    // MARK: - TerminalViewDelegate

    /// Only the driver tells the daemon its size, after a short pause (50 ms) so a drag sends one.
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard isDriver, terminalId != nil else { return }
        pendingResize?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isDriver, let id = self.terminalId else { return }
            let grid = self.gridSize
            self.store.resize(terminalId: id, cols: grid.cols, rows: grid.rows, fromWindow: self.windowId)
        }
        pendingResize = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resizeDebounce, execute: work)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    // MARK: - Private

    // `super` cannot be named inside a closure that captures self.

    /// SwiftTerm's own paste, after a person confirmed it.
    private func pasteConfirmed(_ sender: Any) {
        super.paste(sender)
    }

    private func insertTextConfirmed(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
    }

    private func refuse(_ op: TerminalRefusedOp) {
        store.reportRefusal(terminalId: terminalId, op: op)
    }
}
