// NostromoKit — RegionPath.swift
//
// The root-relative dotted path convention for addressing a node inside a
// `PaneTree` (W5 — ios-curated-view-parity): `"root"`, `"root.0"`,
// `"root.tab0"`, … Ported verbatim from
// `macOS/Nostromo/UI/LayoutChangeClassifier.swift:95-133`'s ad hoc string
// interpolation, so both clients describe the same tree the same way and a
// bug report naming a path (e.g. "root.tab1") means one thing regardless of
// platform.
//
// A split child is addressed by its index (`"root.0"`); a tabs child is
// addressed by its index prefixed `tab` (`"root.tab0"`) — the two node kinds
// share no numbering space, so a tabs node and a split node at the same tree
// position never collide on path text.
public enum RegionPath {
    /// The tree's own root.
    public static let root = "root"

    /// The path of `parent`'s `index`-th child, when `parent` is a `split` node.
    public static func splitChild(_ parent: String, _ index: Int) -> String {
        "\(parent).\(index)"
    }

    /// The path of `parent`'s `index`-th child, when `parent` is a `tabs` node.
    public static func tabChild(_ parent: String, _ index: Int) -> String {
        "\(parent).tab\(index)"
    }
}
