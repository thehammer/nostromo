import Foundation

/// Formats `CodePayload.revision` for display, so `"working"` and a PR head
/// SHA are distinguishable at a glance (ios-curated-view-parity W7, D6).
///
/// `revision` is a git SHA or ref, or the literal `"working"` for the on-disk
/// working tree (`PaneLayout.swift`'s `CodePayload` doc comment). Rendering a
/// 40-character SHA inline at phone width is unreadable, and rendering
/// `"working"` as though it were a hash invites reading it as one. This is a
/// pure formatting function — Foundation-only, no view code — precisely so
/// "working and a PR head SHA are distinguishable" is an L1 test rather than
/// something only checkable by looking at a phone.
public enum RevisionLabel {

    /// The short label a header shows inline. For a SHA, this is a prefix —
    /// never the input itself — so the caller can offer the full value via
    /// tap-and-hold or text selection without ever putting all 40 characters
    /// on screen inline.
    public static func short(_ revision: String) -> String {
        if revision.isEmpty { return "unknown revision" }
        if revision == "working" { return "working tree" }
        if isLikelySHA(revision) { return String(revision.prefix(8)) }
        return revision
    }

    /// A hex string of plausible git-SHA length. Short hex-looking refs (a
    /// short SHA the daemon already abbreviated, or a branch/tag name that
    /// happens to be hex) are left alone — abbreviating an already-short
    /// value would just be a second, redundant truncation, and a branch/tag
    /// name is not a hash no matter how it's spelled.
    private static func isLikelySHA(_ revision: String) -> Bool {
        revision.count >= 20 && revision.allSatisfy(\.isHexDigit)
    }
}
