// NostromoKit — ClaudeLoginCardModel.swift
//
// What the "Claude needs you to sign in" card says and offers for one session (CL2).
// Pure: a `ClaudeLoginSession` entry plus the `claude` path the daemon runs in, nothing else.

import Foundation

public struct ClaudeLoginCardModel: Equatable {
    public static let title = "Claude needs you to sign in"
    public static let openTerminalTitle = "Open sign-in terminal"
    public static let discardTitle = "Discard message"
    /// Shown instead of the terminal button when the daemon did not say where `claude` is.
    public static let manualCommandText = "Run `claude auth login` in a terminal"
    /// What the Copy button puts on the clipboard.
    public static let manualCommand = "claude auth login"

    public let title: String
    public let body: String
    /// The terminal button is shown (a `claude` path is known).
    public let showsOpenTerminal: Bool
    /// The text and Copy button stand in for the terminal button.
    public let showsManualCommand: Bool
    public let resendTitle: String
    public let resendEnabled: Bool
    /// Discard needs a held message to name, and none is offered once it has been written again
    /// (the message is already on its way).
    public let showsDiscard: Bool
    /// What happens after the person signs in; the card repeats it after opening a terminal.
    public let afterSignIn: String

    /// - Parameter watch: whether the daemon can see the credential change. When it cannot, nothing is
    ///   sent again on its own, so the card says to press the button.
    public init(session: ClaudeLoginSession, claudeBin: String?, watch: ClaudeLoginWatch = .keychain) {
        title = Self.title
        let resend = session.phase == .notResendable ? "Resend anyway" : "Resend now"
        let sendsItself = watch == .keychain
        var text: String
        switch session.phase {
        case .waiting:
            text = "Claude's sign-in expired, so your last message wasn't answered. "
                + (sendsItself ? "It's saved and will be sent again once you sign in."
                               : "It's saved. After you sign in, press \(resend).")
        case .notResendable:
            text = "Your last message may have partly run before sign-in failed, so Nostromo won't send it again on its own. "
                + "After you sign in, press \(resend) if you want it sent."
        case .resending:
            text = "Sending your message again…"
        case .pausedNoHold:
            text = "Messages are waiting until Claude can sign in."
                + (sendsItself ? "" : " Nostromo can't see when you do, so they won't go out on their own.")
        }
        switch session.phase {
        case .waiting where sendsItself, .pausedNoHold where sendsItself, .resending:
            afterSignIn = "Nostromo sends your message once Claude is signed in."
        case .pausedNoHold:
            afterSignIn = "Nostromo can't see when you've signed in."
        default:
            afterSignIn = "After you sign in, press \(resend)."
        }
        if session.queued > 0 {
            text += session.queued == 1 ? " 1 more message is waiting." : " \(session.queued) more messages are waiting."
        }
        body = text
        let hasBin = !(claudeBin ?? "").isEmpty
        showsOpenTerminal = hasBin
        showsManualCommand = !hasBin
        resendTitle = resend
        resendEnabled = session.phase != .resending
        showsDiscard = session.holdId != nil && session.phase != .resending
    }
}
