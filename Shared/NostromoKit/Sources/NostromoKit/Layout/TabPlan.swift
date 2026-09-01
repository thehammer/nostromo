// NostromoKit — TabPlan.swift
//
// Flattens a `PaneTree` into the ordered entries `DynamicFocusView`'s
// compact (single-strip) presentation renders (W5 — ios-curated-view-parity,
// D1/D2/D3). Replaces the old `paneIds`-array-plus-`.capitalized` approach:
// `paneIds` discards node boundaries (two `tabs` nodes merge into one
// undifferentiated depth-first walk), and `paneId.capitalized` is the one
// place a raw pane id was user-visible in the whole app.
//
// import Foundation only — pure value types and pure functions, exercised by
// `make kit-test` with no simulator and no device.
import Foundation

/// One leaf in the flattened compact tab strip.
public struct TabPlanEntry: Equatable {
    public let paneId:     String
    public let label:      String
    public let regionPath: String
    /// This entry's position in the strip — always equal to its index in the
    /// array `TabPlan.build` returns.
    public let tabIndex:   Int
}

public enum TabPlan {

    /// Flatten `tree` into ordered strip entries. The `repl` leaf is always
    /// first, regardless of where it sits in the tree — the operator's home
    /// surface stays the anchor of the strip. Every other leaf follows in
    /// tree (depth-first) order, so two `tabs` nodes' children stay
    /// contiguous rather than interleaving. No leaf is dropped and no leaf
    /// is duplicated — guaranteed structurally by a single depth-first walk
    /// over `PaneTree`'s indirect-enum shape (no shared references, no
    /// cycles), not by post-hoc deduplication.
    ///
    /// `content` supplies each pane's current `PaneContentWire`, read only
    /// for the label fallback (`fallbackLabel`) when no data-supplied label
    /// applies. A pane with no entry in `content` yet still gets a valid
    /// label (the neutral "View" fallback).
    public static func build(tree: PaneTree, content: [String: PaneContentWire]) -> [TabPlanEntry] {
        var collected: [(paneId: String, label: String, regionPath: String)] = []

        func walk(_ node: PaneTree, path: String, suppliedLabel: String?) {
            switch node {
            case .leaf(let paneId):
                let label = suppliedLabel ?? fallbackLabel(paneId: paneId, content: content[paneId])
                collected.append((paneId, label, path))
            case .split(_, let children, _):
                for (i, child) in children.enumerated() {
                    walk(child, path: RegionPath.splitChild(path, i), suppliedLabel: nil)
                }
            case .tabs(let children, let labels, _):
                for (i, child) in children.enumerated() {
                    let label = i < labels.count ? labels[i] : nil
                    walk(child, path: RegionPath.tabChild(path, i), suppliedLabel: label)
                }
            }
        }
        walk(tree, path: RegionPath.root, suppliedLabel: nil)

        let replEntries = collected.filter { $0.paneId == "repl" }
        let restEntries = collected.filter { $0.paneId != "repl" }
        let ordered = replEntries + restEntries

        return ordered.enumerated().map { i, e in
            TabPlanEntry(paneId: e.paneId, label: e.label, regionPath: e.regionPath, tabIndex: i)
        }
    }

    /// The pure label-fallback rule (D2): NEVER derived from a pane id or
    /// `paneId.capitalized` — the exact defect this wedge exists to remove.
    /// `"repl"` is a dedicated case (its label, "Repl", coincidentally equals
    /// `"repl".capitalized`, but that's incidental English capitalization,
    /// not a generic scheme — every other case below derives its label from
    /// the pane's *content kind*, never its id).
    public static func fallbackLabel(paneId: String, content: PaneContentWire?) -> String {
        if paneId == "repl" { return "Repl" }
        guard let content else { return "View" }
        switch content {
        case .prList:         return "Queue"
        case .diff:            return "Diff"
        case .code:             return "File"
        case .prConversation:    return "Conversation"
        case .ticket:              return "Ticket"
        case .text, .jsonSnapshot, .loading, .error, .unknown:
            return "View"
        }
    }
}
