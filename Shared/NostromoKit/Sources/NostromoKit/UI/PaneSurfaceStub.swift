// NostromoKit — PaneSurfaceStub.swift
//
// The stub message table for `PaneContentWire` kinds iOS doesn't render yet
// (W2 — ios-curated-view-parity).
//
// The PRD's organizing rule: "A surface may be absent, and a surface may be
// simplified. A surface may never look complete when it isn't." A stub that
// says only "not available" is an absence; a stub that names the specific
// addressing it cannot show is a legible deferral. This type is the single
// source of that wording, so:
//   - the L1 suite (PaneSurfaceStubTests) can assert every deferred kind has
//     a non-empty message and no rendered kind has one, and
//   - W7/W8/W9 delete a table entry instead of hunting a string in a view.
public enum PaneSurfaceStub {
    /// The stub headline + detail for a `PaneContentWire` case iOS defers
    /// rendering on, or `nil` for a case iOS actually renders (or degrades
    /// generically, e.g. `.unknown`).
    ///
    /// `detail` always names the specific addressing this content kind's
    /// stub cannot show — never just "isn't available."
    public static func message(for content: PaneContentWire) -> (headline: String, detail: String)? {
        switch content {
        case .prConversation:
            return (
                headline: "PR conversation isn't available on iOS yet.",
                detail: "It can't show which comment the agent pointed at."
            )
        case .ticket:
            return (
                headline: "Ticket view isn't available on iOS yet.",
                detail: "It can't show which section the agent pointed at."
            )
        // `.code` (W7) and `.diff` (W8) are real renderers now — neither is
        // a deferred kind any longer, and this table's exhaustive switch
        // forces this file to be updated the moment each stopped being one,
        // rather than leaving a stale stub message nobody ever renders.
        case .text, .jsonSnapshot, .prList, .loading, .error, .unknown, .code, .diff:
            return nil
        }
    }
}
