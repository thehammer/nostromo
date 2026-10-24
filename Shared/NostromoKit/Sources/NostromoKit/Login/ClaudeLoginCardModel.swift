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
    /// Discard needs a held message to name.
    public let showsDiscard: Bool

    public init(session: ClaudeLoginSession, claudeBin: String?) {
        title = Self.title
        var text: String
        switch session.phase {
        case .waiting:
            text = "Claude's sign-in expired, so your last message wasn't answered. It's saved and will be sent again once you sign in."
        case .notResendable:
            text = "Your last message may have partly run before sign-in failed, so Nostromo won't send it again on its own."
        case .resending:
            text = "Sending your message again…"
        case .pausedNoHold:
            text = "Messages are waiting until Claude can sign in."
        }
        if session.queued > 0 {
            text += session.queued == 1 ? " 1 more message is waiting." : " \(session.queued) more messages are waiting."
        }
        body = text
        let hasBin = !(claudeBin ?? "").isEmpty
        showsOpenTerminal = hasBin
        showsManualCommand = !hasBin
        resendTitle = session.phase == .notResendable ? "Resend anyway" : "Resend now"
        resendEnabled = session.phase != .resending
        showsDiscard = session.holdId != nil
    }
}
