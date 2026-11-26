// NostromoKit — NotificationContentComposer.swift
//
// What the Notification Service Extension shows once it has (or has not) fetched a detail line
// (W16). Pure, so the app's tests prove the contract before any extension host is involved.
//
//   - no detail, a detail that withholds its text, an item that no longer waits, a replacement
//     (`resolved`) or a Summary: the contract content, unchanged. There is no code path that
//     produces a placeholder, an error or a spinner (W16-4);
//   - a detail line: it becomes the body and the contract body moves to the subtitle; for a decision
//     the body ends " · answer on your Mac" and the notification still has no choice actions (S8, B10).
//
// The text is what a repository's own people wrote, so it is flattened to one printable line first.

import Foundation

/// The visible parts of a notification: the contract the push carried, or the enriched version.
public struct NotificationContent: Equatable, Sendable {
    public var title: String
    public var subtitle: String
    public var body: String

    public init(title: String, subtitle: String = "", body: String) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
    }
}

public enum NotificationContentComposer {
    /// What a decision's body ends with: the phone only reads it.
    public static let decisionSuffix = " · answer on your Mac"

    public static func compose(contract: NotificationContent, payload: PushPayload,
                               detail: PushDetailWire?) -> NotificationContent {
        guard !payload.resolved, payload.kind != .summary,
              let detail, detail.waiting, detail.itemRef == payload.item,
              let line = flattened(detail.text)
        else { return contract }
        var out = contract
        out.subtitle = contract.body
        out.body = payload.kind == .decision ? line + decisionSuffix : line
        return out
    }

    /// One printable line of at most `PushDetailWire.maxTextCharacters` characters, or `nil`. Control
    /// characters and line breaks become spaces; characters that only reorder or hide text (bidirectional
    /// controls, zero-width space, the byte-order mark) are dropped. Joiners stay: they are part of
    /// emoji sequences and of Persian words.
    static func flattened(_ text: String?) -> String? {
        guard let text else { return nil }
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.properties.generalCategory == .control || CharacterSet.newlines.contains(scalar) {
                out.append(" ")
            } else if !isInvisibleFormat(scalar) {
                out.append(scalar)
            }
        }
        let collapsed = String(out).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        let cut = String(collapsed.prefix(PushDetailWire.maxTextCharacters))
        let trimmed = cut.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isInvisibleFormat(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x061C, 0x200B, 0x200E, 0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x2069, 0xFEFF:
            return true
        default:
            return false
        }
    }
}
