import AppKit

/// The one place terminal code asks "was that a person?". A thin wrapper over the approvals gate
/// (`SyntheticInputGate`, `HumanGesture`) so every keystroke, paste, button and menu item in a
/// terminal pane has a single call site. There is no second gate here: both answers come from
/// AP1's API, and the seams below are the ones AP1 already exposes, passed through for tests.
///
/// - `allowsKeystroke`: typing, IME text, paste and the terminal's own replies. Refused when the
///   app-control socket produced the event, unless this is a QA build that relaxes the gate.
/// - `allowsControl`: a button or menu item that changes a terminal (close, restart). Needs a human
///   gesture in the control's own window (`HumanGesture.permit`), so a synthetic click, a
///   marked key, an Accessibility press and an event from another window are all refused.
enum TerminalInputGuard {

    /// A keystroke, `insertText` or paste is allowed unless app-control synthesised it. The terminal's
    /// own replies (device attributes, focus reports) arrive with no event of their own and pass too,
    /// except while app-control is running a command.
    static func allowsKeystroke(event: NSEvent?,
                                isSynthetic: (NSEvent?) -> Bool = { SyntheticInputGate.isSynthetic($0) },
                                allowsSynthetic: () -> Bool = { SyntheticInputGate.allowsSynthetic }) -> Bool {
        !isSynthetic(event) || allowsSynthetic()
    }

    /// A control may act when `event` is a human gesture on it. `fromMenu`: the control is a main-menu
    /// item (its mouse event belongs to the menu; see `HumanGesture.permit`).
    static func allowsControl(event: NSEvent?, control: NSView, fromMenu: Bool = false,
                              voiceOverEnabled: () -> Bool = { NSWorkspace.shared.isVoiceOverEnabled },
                              allowsSynthetic: () -> Bool = { SyntheticInputGate.allowsSynthetic },
                              now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) -> Bool {
        let verdict = HumanGesture.permit(event, control: control, menuSelection: fromMenu,
                                          voiceOverEnabled: voiceOverEnabled,
                                          allowsSynthetic: allowsSynthetic, now: now)
        if case .human = verdict { return true }
        return false
    }
}
