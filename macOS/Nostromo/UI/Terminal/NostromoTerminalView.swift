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

    init(windowId: String, store: TerminalSessionStore) {
        self.windowId = windowId
        self.store = store
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

    // MARK: - Input (every path asks the guard first)

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard TerminalInputGuard.verdict(origin: .typed, event: NSApp.currentEvent) != .refused else {
            refuse(.input)
            return
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func paste(_ sender: Any) {
        guard TerminalInputGuard.verdict(origin: .typed, event: NSApp.currentEvent) != .refused else {
            refuse(.paste)
            return
        }
        super.paste(sender)
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

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard let terminalId else { return }
        store.resize(terminalId: terminalId, cols: newCols, rows: newRows, fromWindow: windowId)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    // MARK: - Private

    private func refuse(_ op: TerminalRefusedOp) {
        store.reportRefusal(terminalId: terminalId, op: op)
    }
}
