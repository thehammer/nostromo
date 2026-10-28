import AppKit

/// Decides what happens to text a person is about to put into a terminal (a paste, dictation, a text
/// replacement), and keeps the confirmation sheet while one is up. No SwiftTerm: `NostromoTerminalView`
/// holds one, and the tests drive it directly.
///
/// Only a terminal KNOWN to be local (the store says `kind == .local`) takes text straight away. For
/// anything else (`ecs`, a kind this app does not know, a terminal the store has no record of, no terminal
/// id at all) text with a newline asks first, naming the target or "REMOTE shell" when it is unknown; with
/// no window to hang the question on it is REFUSED (nothing sent, reported to the daemon). Nothing falls
/// through to a plain send.
final class RemotePasteGate {

    private let store: TerminalSessionStore
    private let clipboardChangeCount: () -> Int
    private var windowClosed: NSObjectProtocol?

    /// The confirmation on screen, if any.
    private(set) var pasteConfirm: PasteConfirmSheet?

    init(store: TerminalSessionStore, clipboardChangeCount: @escaping () -> Int = { NSPasteboard.general.changeCount }) {
        self.store = store
        self.clipboardChangeCount = clipboardChangeCount
    }

    deinit {
        if let windowClosed { NotificationCenter.default.removeObserver(windowClosed) }
    }

    /// Run `send` now, or once a person confirms `text`, or never.
    ///
    /// `refusedOp` is what the daemon is told when `text` is refused (no window, or a Paste click that was
    /// not a person's). `clipboardChanged` is true while `text` came from the pasteboard: when the
    /// clipboard changes while the sheet is up, what was confirmed is gone and nothing is sent.
    func submit(_ text: String, terminalId: String?, window: NSWindow?, refusedOp: TerminalRefusedOp,
                fromClipboard: Bool, send: @escaping () -> Void) {
        let info = terminalId.flatMap { store.terminals[$0] }
        guard case .confirm(let lines) = PastePolicy.decide(kind: info?.kind, text: text) else {
            send()
            return
        }
        guard let window else {
            store.reportRefusal(terminalId: terminalId, op: refusedOp)
            return
        }
        guard pasteConfirm == nil else { return }
        let changeCount = clipboardChangeCount()
        let sheet = PasteConfirmSheet(
            lines: lines, preview: PastePolicy.preview(text), targetText: TerminalChromeModel.pasteTargetText(for: info),
            onPaste: { [weak self] in
                guard let self else { return }
                self.clear()
                if fromClipboard, self.clipboardChangeCount() != changeCount { return }
                send()
            },
            onRefused: { [weak self] in self?.store.reportRefusal(terminalId: terminalId, op: refusedOp) })
        guard let sheetWindow = sheet.window else {
            store.reportRefusal(terminalId: terminalId, op: refusedOp)
            return
        }
        pasteConfirm = sheet
        // The parent can close with the sheet up (the sheet's completion does not always run then):
        // forget it, or every later paste would find a confirmation "on screen" and do nothing.
        windowClosed = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            self?.clear()
        }
        // The completion block keeps the sheet's controller alive while the sheet is up, even if the
        // view that owns this gate goes away: its buttons' targets are weak, and a sheet nobody owns
        // could not be dismissed.
        window.beginSheet(sheetWindow) { [weak self, sheet] _ in
            withExtendedLifetime(sheet) { self?.clear() }
        }
    }

    private func clear() {
        pasteConfirm = nil
        if let windowClosed { NotificationCenter.default.removeObserver(windowClosed) }
        windowClosed = nil
    }
}
