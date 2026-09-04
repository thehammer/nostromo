import Foundation

/// Whether the client-composed PR summary may be written into the legacy
/// `diff` pane — decided in one pure, dependency-free place so the decision
/// is testable. `AppStore.pushDetailToDiffPane` reaches `focusLayouts`,
/// `FileWatchers` and `PRDetailCache` and cannot go in the logic test
/// bundle; this can.
///
/// Before this existed, that function wrote `paneContent["diff"]` whenever
/// the pane held `nil` or `.text`. In a `perri-curated` focus there is no
/// pane named `diff` at all, so `nil` meant "does not exist" and the write
/// invented a pane id the daemon never sent — logged by
/// `DynamicFocusView.updateContent` at `.error`, once per pane-content push,
/// every 30 s, forever.
enum DiffPaneSummaryPolicy {

    /// The `perri-standard` layout's fixed summary pane. The one place this
    /// literal is allowed to appear on this path.
    static let paneId = "diff"

    /// - Parameters:
    ///   - tree: the focus's current pane tree, or `nil` when no
    ///     `FocusLayout` has been received for it yet.
    ///   - existing: whatever `paneContent[paneId]` currently holds.
    static func shouldWriteSummary(tree: PaneTree?, existing: PaneContentWire?) -> Bool {
        // Membership (the fix). A known tree without this pane is the
        // curated case: refuse. An unknown tree permits, preserving
        // pre-fix first-paint behaviour — see D3.
        if let tree, !tree.paneIds.contains(paneId) { return false }

        // Ownership (pre-existing, W2 — unchanged). Never clobber a pane the
        // daemon drives with structured content; `nil` and `.text` are the
        // states this summary has always owned.
        switch existing {
        case nil, .text: return true
        default:         return false
        }
    }
}
