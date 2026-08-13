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

// MARK: - PrListItemModel

/// One item in a `pr_list` pane payload.
/// Mirrors `PrListItem` from `src/ipc/protocol.rs`.
public struct PrListItemModel: Decodable, Identifiable, Equatable {
    /// Stable identity: `"owner/name#number"` — matching `PrQueueItem.id`.
    public var id: String { "\(repo)#\(number)" }
    public let repo:        String
    public let number:      Int
    public let title:       String
    public let author:      String
    public let bucket:      String
    public let ciState:     CiState
    public let newActivity: Bool
    public let url:         String
    public let headSha:     String

    enum CodingKeys: String, CodingKey {
        case repo, number, title, author, bucket, url
        case ciState     = "ci_state"
        case newActivity = "new_activity"
        case headSha     = "head_sha"
    }

    /// Memberwise init — used directly in tests and by callers building models in memory.
    public init(
        repo:        String,
        number:      Int,
        title:       String,
        author:      String,
        bucket:      String,
        ciState:     CiState,
        newActivity: Bool,
        url:         String,
        headSha:     String
    ) {
        self.repo        = repo
        self.number      = number
        self.title       = title
        self.author      = author
        self.bucket      = bucket
        self.ciState     = ciState
        self.newActivity = newActivity
        self.url         = url
        self.headSha     = headSha
    }

    public init(from decoder: Decoder) throws {
        let c    = try decoder.container(keyedBy: CodingKeys.self)
        repo        = try  c.decode(String.self, forKey: .repo)
        number      = try  c.decode(Int.self,    forKey: .number)
        title       = try  c.decode(String.self, forKey: .title)
        author      = try  c.decode(String.self, forKey: .author)
        bucket      = try  c.decode(String.self, forKey: .bucket)
        ciState     = (try? c.decode(CiState.self, forKey: .ciState))     ?? .unknown
        newActivity = (try? c.decode(Bool.self,    forKey: .newActivity))  ?? false
        url         = (try? c.decode(String.self,  forKey: .url))          ?? ""
        headSha     = (try? c.decode(String.self,  forKey: .headSha))      ?? ""
    }

    /// Map to the shared `PerriPRRowModel` used by `PerriPRRow`.
    /// `id` is `"\(repo)#\(number)"` — matching `PrQueueItem.id`.
    public func toRowModel() -> PerriPRRowModel {
        PerriPRRowModel(
            id:          "\(repo)#\(number)",
            number:      number,
            title:       title,
            repo:        repo,
            author:      author,
            bucket:      bucket,
            ciState:     ciState,
            newActivity: newActivity
        )
    }
}

// MARK: - PaneContentWire

/// Content pushed to a pane via `set_pane_content`. `Equatable` is implemented
/// by hand below (the `jsonSnapshot`/`unknown` cases carry `Any`, so they
/// can't be synthesized).
public enum PaneContentWire {
    case text(String)
    case jsonSnapshot(Any)
    /// Typed list of PR queue items, rendered by `PerriPRRow`.
    case prList([PrListItemModel])
    /// Transient loading indicator — agent signals it is refreshing this pane.
    case loading
    /// Agent encountered an error fetching this pane's data.
    case error(String)
    /// A future content kind not yet known to this client version.
    case unknown(Any)
}

extension PaneContentWire: Decodable {
    // The Rust daemon serializes with #[serde(tag = "kind")], so the
    // discriminator key on the wire is "kind", not "type".
    private enum K: String, CodingKey { case kind, text, value, items, message }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "text":
            self = .text(try c.decode(String.self, forKey: .text))
        case "json_snapshot":
            let raw = try c.decode(AnyDecodable.self, forKey: .value)
            self = .jsonSnapshot(raw.value)
        case "pr_list":
            let items = try c.decode([PrListItemModel].self, forKey: .items)
            self = .prList(items)
        case "loading":
            self = .loading
        case "error":
            let msg = (try? c.decodeIfPresent(String.self, forKey: .message)) ?? "An error occurred"
            self = .error(msg)
        default:
            let raw = try AnyDecodable(from: d)
            self = .unknown(raw.value)
        }
    }
}

extension PaneContentWire: Equatable {
    /// `.text`/`.loading`/`.error`/`.prList` compare structurally. `.jsonSnapshot`
    /// and `.unknown` carry an `Any` payload, so they compare via
    /// `jsonPayloadsEqual` — structural equality through Foundation bridging.
    /// Note this means `1` and `1.0` compare equal (NSNumber bridging); for a
    /// "did this pane's content change" test that's the correct answer.
    public static func == (lhs: PaneContentWire, rhs: PaneContentWire) -> Bool {
        switch (lhs, rhs) {
        case (.text(let a), .text(let b)):
            return a == b
        case (.loading, .loading):
            return true
        case (.error(let a), .error(let b)):
            return a == b
        case (.prList(let a), .prList(let b)):
            return a == b
        case (.jsonSnapshot(let a), .jsonSnapshot(let b)):
            return jsonPayloadsEqual(a, b)
        case (.unknown(let a), .unknown(let b)):
            return jsonPayloadsEqual(a, b)
        default:
            return false
        }
    }
}

/// Structural comparison for the `Any` payloads carried by
/// `.jsonSnapshot`/`.unknown`. Every value these cases can actually hold
/// comes from `AnyDecodable`, which only ever produces `String`, `Bool`,
/// `Int`, `Double`, `[Any]`, or `[String: Any]` — all of which bridge to
/// Foundation objects with structural `isEqual`, including nested
/// containers. A payload that somehow doesn't bridge boxes to a distinct
/// opaque object and compares unequal, preserving the original
/// conservative "report changed rather than a false unchanged" bias for
/// anything we genuinely cannot compare.
private func jsonPayloadsEqual(_ lhs: Any, _ rhs: Any) -> Bool {
    (lhs as AnyObject).isEqual(rhs as AnyObject)
}

// MARK: - PaneFreshness

/// How trustworthy the content in a `pane_content` push is. Mirrors
/// `PaneFreshness` in `src/ipc/protocol.rs`. `stale` is the source's own
/// transient flag and must NOT be rendered — a single missed poll is normal.
/// `badlyStale` is the daemon's verdict that the source hasn't produced good
/// data in a while; it is the only flag a client renders.
public struct PaneFreshness: Decodable, Equatable {
    public let asOf: Date?
    public let stale: Bool
    public let badlyStale: Bool

    private enum CodingKeys: String, CodingKey {
        case asOf = "as_of"
        case stale
        case badlyStale = "badly_stale"
    }

    public init(asOf: Date?, stale: Bool, badlyStale: Bool) {
        self.asOf = asOf
        self.stale = stale
        self.badlyStale = badlyStale
    }
}

// MARK: - FocusLayoutModel

/// In-memory model of a focus's layout state, rebuilt entirely from daemon
/// broadcasts. Not persisted — the daemon is the source of truth.
public struct FocusLayoutModel {
    public var tree:        PaneTree
    public var focusedPane: String?
    public var paneContent: [String: PaneContentWire]
    /// Per-pane freshness, keyed by `pane_id`. Absent entry == no freshness
    /// concept for that pane (e.g. agent-authored content via `set_pane_content`).
    public var paneFreshness: [String: PaneFreshness]

    /// Initial state for a focus whose layout hasn't arrived yet.
    public static let initial = FocusLayoutModel(
        tree:        .replLeaf,
        focusedPane: nil,
        paneContent: [:],
        paneFreshness: [:]
    )

    public init(
        tree: PaneTree,
        focusedPane: String?,
        paneContent: [String: PaneContentWire],
        paneFreshness: [String: PaneFreshness] = [:]
    ) {
        self.tree          = tree
        self.focusedPane   = focusedPane
        self.paneContent   = paneContent
        self.paneFreshness = paneFreshness
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
