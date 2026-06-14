// NostromoKit — PaneLayout.swift
//
// Wire types for the agent-authored pane layout protocol.
// Mirrors the Rust types in src/ipc/protocol.rs.
//
// These types are consumed by DaemonStore on both iOS and macOS.
// The macOS app additionally defines its own AppKit-coupled variants
// in Models.swift; those shadow these types within the macOS module.

import Foundation

// MARK: - SplitDirection

/// Axis of a split node in a pane tree.
/// `.horizontal` means a vertical divider (left | right),
/// `.vertical` means a horizontal divider (top | bottom).
public enum SplitDirection: String, Decodable, Equatable {
    case horizontal
    case vertical
}

// MARK: - PaneTree

/// Recursive pane tree. Leaf nodes hold a `pane_id`; split nodes contain
/// two or more ordered children with corresponding layout ratios.
public indirect enum PaneTree: Equatable {
    case leaf(paneId: String)
    case split(direction: SplitDirection, children: [PaneTree], ratios: [Double])

    /// Convenience: a single `"repl"` leaf (the initial state for every focus).
    public static let replLeaf = PaneTree.leaf(paneId: "repl")

    /// Ordered list of all leaf pane IDs (depth-first).
    public var paneIds: [String] {
        switch self {
        case .leaf(let paneId):
            return [paneId]
        case .split(_, let children, _):
            return children.flatMap { $0.paneIds }
        }
    }
}

extension PaneTree: Decodable {
    private enum K: String, CodingKey {
        case kind
        case paneId    = "pane_id"
        case direction
        case children
        case ratios
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "leaf":
            self = .leaf(paneId: try c.decode(String.self, forKey: .paneId))
        case "split":
            self = .split(
                direction: try c.decode(SplitDirection.self, forKey: .direction),
                children:  try c.decode([PaneTree].self,     forKey: .children),
                ratios:    try c.decode([Double].self,       forKey: .ratios)
            )
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c,
                debugDescription: "unknown PaneTree kind: \(other)"
            )
        }
    }
}

// MARK: - PaneContentWire

/// Content pushed to a pane via `set_pane_content`. Not Equatable because
/// the `jsonSnapshot` case carries `Any`.
public enum PaneContentWire {
    case text(String)
    case jsonSnapshot(Any)
}

extension PaneContentWire: Decodable {
    // The Rust daemon serializes with #[serde(tag = "kind")], so the
    // discriminator key on the wire is "kind", not "type".
    private enum K: String, CodingKey { case kind, text, value }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "text":
            self = .text(try c.decode(String.self, forKey: .text))
        case "json_snapshot":
            let raw = try c.decode(AnyDecodable.self, forKey: .value)
            self = .jsonSnapshot(raw.value)
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c,
                debugDescription: "unknown PaneContentWire kind: \(other)"
            )
        }
    }
}

// MARK: - FocusLayoutModel

/// In-memory model of a focus's layout state, rebuilt entirely from daemon
/// broadcasts. Not persisted — the daemon is the source of truth.
public struct FocusLayoutModel {
    public var tree:        PaneTree
    public var focusedPane: String?
    public var paneContent: [String: PaneContentWire]

    /// Initial state for a focus whose layout hasn't arrived yet.
    public static let initial = FocusLayoutModel(
        tree:        .replLeaf,
        focusedPane: nil,
        paneContent: [:]
    )

    public init(tree: PaneTree, focusedPane: String?, paneContent: [String: PaneContentWire]) {
        self.tree        = tree
        self.focusedPane = focusedPane
        self.paneContent = paneContent
    }
}

// MARK: - FocusCreatedMeta

/// Payload carried by a `focus_created` broadcast from the daemon.
public struct FocusCreatedMeta: Decodable {
    public let tag:         String
    public let displayName: String
    public let agentName:   String
    public let projectName: String?
    public let org:         String?
    public let isBuiltIn:   Bool

    enum CodingKeys: String, CodingKey {
        case tag
        case displayName = "display_name"
        case agentName   = "agent_name"
        case projectName = "project_name"
        case org
        case isBuiltIn   = "is_built_in"
    }

    /// Convert to the focus registry type used by `DaemonStore.focuses`.
    public func toFocusMeta() -> FocusMeta {
        FocusMeta(
            tag:            tag,
            displayName:    displayName,
            agentName:      agentName,
            projectName:    projectName,
            org:            org,
            isBuiltIn:      isBuiltIn,
            sessionSummary: nil
        )
    }
}

// MARK: - Private JSON helper

private struct AnyDecodable: Decodable {
    let value: Any

    init(from d: Decoder) throws {
        if let c = try? d.singleValueContainer() {
            if let s = try? c.decode(String.self)  { value = s; return }
            if let b = try? c.decode(Bool.self)    { value = b; return }
            if let i = try? c.decode(Int.self)     { value = i; return }
            if let f = try? c.decode(Double.self)  { value = f; return }
        }
        if var c = try? d.unkeyedContainer() {
            var arr: [Any] = []
            while !c.isAtEnd {
                let elem = try c.decode(AnyDecodable.self)
                arr.append(elem.value)
            }
            value = arr
            return
        }
        let c = try d.container(keyedBy: DynamicKey.self)
        var dict: [String: Any] = [:]
        for k in c.allKeys {
            dict[k.stringValue] = try c.decode(AnyDecodable.self, forKey: k).value
        }
        value = dict
    }

    private struct DynamicKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}
