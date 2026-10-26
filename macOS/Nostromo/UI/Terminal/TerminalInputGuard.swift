import AppKit

/// Where bytes bound for a terminal came from.
enum TerminalInputOrigin: Equatable {
    /// A key, IME text or paste a person made.
    case typed
    /// The terminal emulator answering on its own (cursor position, device attributes, focus and
    /// mouse reports). Never a person's keystroke.
    case emulatorReply
}

/// `TerminalInputGuard.verdict`.
enum TerminalInputVerdict: Equatable {
    /// Send as a person's typing or paste (it counts as activity for the remote idle rule).
    case keystroke
    /// Send marked `auto_reply` (it does not).
    case autoReply
    /// Send nothing; the view reports the refusal.
    case refused
}

/// What a terminal view shows to accessibility clients, and therefore to `AppControlServer`
/// (`tree`, `find`, `ax` read accessibility values). An agent may read a terminal's screen only
/// through `nostromo_read_terminal_screen` (follow plus redaction), so the real app exposes none of
/// it. A QA build that relaxes the synthetic-input gate keeps the text for the live QA script.
enum TerminalScreenAccess {
    static func accessibilityValue(screenText: () -> String,
                                   allowsSynthetic: () -> Bool = { SyntheticInputGate.allowsSynthetic }) -> String? {
        allowsSynthetic() ? screenText() : nil
    }
}

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

    /// What to do with bytes the terminal view is about to send, given where they came from.
    ///
    /// `origin` is decided by the view from which SwiftTerm path produced the bytes, never from
    /// `NSApp.currentEvent` (which is nil or stale outside event dispatch): only the typed path can
    /// ever be a `.keystroke`, so a reply the emulator makes on its own (`ESC[6n` answered while output
    /// is being fed, a focus report, a mouse report) is always an `.autoReply` however fresh or stale
    /// the current event is. On top of that, either origin is refused when app-control produced it.
    static func verdict(origin: TerminalInputOrigin, event: NSEvent?,
                        isSynthetic: (NSEvent?) -> Bool = { SyntheticInputGate.isSynthetic($0) },
                        allowsSynthetic: () -> Bool = { SyntheticInputGate.allowsSynthetic }) -> TerminalInputVerdict {
        guard allowsKeystroke(event: event, isSynthetic: isSynthetic, allowsSynthetic: allowsSynthetic) else {
            return .refused
        }
        switch origin {
        case .typed:         return .keystroke
        case .emulatorReply: return .autoReply
        }
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
