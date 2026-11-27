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

    /// One printable line of at most `PushDetailWire.maxTextCharacters` characters, or `nil`. Line breaks
    /// (LF, VT, FF, CR, NEL, U+2028, U+2029) and tabs become spaces, so no two words are glued together;
    /// control characters and invisible format characters are dropped (see `isInvisibleFormat`); runs
    /// of spaces collapse. Joiners stay: they are part of emoji sequences and of Persian words.
    ///
    /// The daemon sends one line already (`first_line` in `src/push/detail.rs`); `tests/fixtures/
    /// push-detail/text_cases.json` holds the inputs both implementations are tested against.
    static func flattened(_ text: String?) -> String? {
        guard let text else { return nil }
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if isLineBreak(scalar) || scalar == "\t" {
                out.append(" ")
            } else if scalar.properties.generalCategory != .control && !isInvisibleFormat(scalar) {
                out.append(scalar)
            }
        }
        let collapsed = String(out).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        let cut = String(collapsed.prefix(PushDetailWire.maxTextCharacters))
        let trimmed = cut.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isLineBreak(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029: return true
        default: return false
        }
    }

    /// Every Unicode format character (category Cf) except the joiners (U+200C, U+200D), the tag block
    /// (a known way to hide ASCII text), the Mongolian vowel separator and the Hangul fillers. The same
    /// ranges as `is_invisible_format` in `src/push/detail.rs`; `NotificationContentComposerTests` fails if
    /// this platform's Unicode database knows a format character this list does not.
    static func isInvisibleFormat(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00AD, 0x0600...0x0605, 0x061C, 0x06DD, 0x070F, 0x0890...0x0891, 0x08E2, 0x115F...0x1160,
             0x180E, 0x200B, 0x200E...0x200F, 0x2028...0x202E, 0x2060...0x206F, 0x3164, 0xFEFF, 0xFFA0,
             0xFFF9...0xFFFB, 0x110BD, 0x110CD, 0x13430...0x1343F, 0x1BCA0...0x1BCA3, 0x1D173...0x1D17A,
             0xE0001, 0xE0020...0xE007F:
            return true
        default:
            return false
        }
    }
}
