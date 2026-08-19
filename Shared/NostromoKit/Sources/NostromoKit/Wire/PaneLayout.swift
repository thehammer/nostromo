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
/// two or more ordered children with corresponding layout ratios; `tabs`
/// nodes (W1 — curated-agent-views) host several panes with exactly one
/// frontmost, `labels` parallel to `children`.
public indirect enum PaneTree: Equatable {
    case leaf(paneId: String)
    case split(direction: SplitDirection, children: [PaneTree], ratios: [Double])
    case tabs(children: [PaneTree], labels: [String], active: Int)

    /// Convenience: a single `"repl"` leaf (the initial state for every focus).
    public static let replLeaf = PaneTree.leaf(paneId: "repl")

    /// Ordered list of all leaf pane IDs (depth-first).
    public var paneIds: [String] {
        switch self {
        case .leaf(let paneId):
            return [paneId]
        case .split(_, let children, _):
            return children.flatMap { $0.paneIds }
        case .tabs(let children, _, _):
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
        case labels
        case active
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
        case "tabs":
            self = .tabs(
                children: try c.decode([PaneTree].self, forKey: .children),
                labels:   try c.decode([String].self,   forKey: .labels),
                active:   try c.decode(Int.self,        forKey: .active)
            )
        default:
            // An unrecognised kind (a future node type this client version
            // doesn't know about yet) must never throw — that would make the
            // whole `focus_layout` frame undecodable — and must never
            // fabricate a second `.replLeaf` (the pre-existing macOS-side
            // fallback did exactly that, silently creating a duplicate repl
            // pane on the client). Degrade instead: decode the node's first
            // child if it has one (best-effort — something renders), else a
            // harmless non-repl placeholder leaf.
            if let children = try? c.decode([PaneTree].self, forKey: .children), let first = children.first {
                self = first
            } else {
                self = .leaf(paneId: "unknown")
            }
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

// MARK: - Structured diff model (W2 — curated-agent-views)

/// One line within a [DiffHunkModel]. Mirrors `DiffLine` in
/// `src/ipc/protocol.rs`.
///
/// `oldN`/`newN` are the line's number on each side, `nil` where the line
/// doesn't exist on that side. They are what makes a diff line-addressable:
/// resolving `Anchor.line(path:line:)` to a row is a lookup on `newN`, falling
/// back to the removal row carrying that `oldN`.
public struct DiffLineModel: Decodable, Equatable {
    public enum Kind: String, Decodable, Equatable {
        case context, added, removed, meta
    }
    public let kind:  Kind
    public let oldN:  Int?
    public let newN:  Int?
    /// Content with the diff marker stripped. A `.meta` line keeps its raw
    /// text, because there the marker *is* the content.
    public let text:  String

    enum CodingKeys: String, CodingKey {
        case kind, text
        case oldN = "old_n"
        case newN = "new_n"
    }

    public init(kind: Kind, oldN: Int?, newN: Int?, text: String) {
        self.kind = kind
        self.oldN = oldN
        self.newN = newN
        self.text = text
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .context
        oldN = try c.decodeIfPresent(Int.self, forKey: .oldN)
        newN = try c.decodeIfPresent(Int.self, forKey: .newN)
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
    }
}

/// One `@@ ... @@` hunk. Mirrors `DiffHunk` in `src/ipc/protocol.rs`.
public struct DiffHunkModel: Decodable, Equatable {
    /// The verbatim `@@ -a,b +c,d @@ context` line, so the client renders what
    /// git actually said rather than reconstructing it.
    public let header:   String
    public let oldStart: Int
    public let newStart: Int
    public let lines:    [DiffLineModel]

    enum CodingKeys: String, CodingKey {
        case header, lines
        case oldStart = "old_start"
        case newStart = "new_start"
    }

    public init(header: String, oldStart: Int, newStart: Int, lines: [DiffLineModel]) {
        self.header   = header
        self.oldStart = oldStart
        self.newStart = newStart
        self.lines    = lines
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        header   = (try? c.decode(String.self, forKey: .header)) ?? ""
        oldStart = (try? c.decode(Int.self, forKey: .oldStart)) ?? 1
        newStart = (try? c.decode(Int.self, forKey: .newStart)) ?? 1
        lines    = (try? c.decode([DiffLineModel].self, forKey: .lines)) ?? []
    }
}

/// One file's change within a diff. Mirrors `DiffFile` in
/// `src/ipc/protocol.rs`.
public struct DiffFileModel: Decodable, Equatable {
    public enum Status: String, Decodable, Equatable {
        case added, removed, modified, renamed
    }
    /// The path on the new side (or, for a removal, the only path it has).
    public let path:      String
    /// Where a renamed file came from.
    public let oldPath:   String?
    public let status:    Status
    public let additions: Int
    public let deletions: Int
    public let hunks:     [DiffHunkModel]

    enum CodingKeys: String, CodingKey {
        case path, status, additions, deletions, hunks
        case oldPath = "old_path"
    }

    public init(
        path:      String,
        oldPath:   String? = nil,
        status:    Status,
        additions: Int,
        deletions: Int,
        hunks:     [DiffHunkModel]
    ) {
        self.path      = path
        self.oldPath   = oldPath
        self.status    = status
        self.additions = additions
        self.deletions = deletions
        self.hunks     = hunks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path      = (try? c.decode(String.self, forKey: .path)) ?? ""
        oldPath   = try c.decodeIfPresent(String.self, forKey: .oldPath)
        status    = (try? c.decode(Status.self, forKey: .status)) ?? .modified
        additions = (try? c.decode(Int.self, forKey: .additions)) ?? 0
        deletions = (try? c.decode(Int.self, forKey: .deletions)) ?? 0
        hunks     = (try? c.decode([DiffHunkModel].self, forKey: .hunks)) ?? []
    }
}

/// The payload of `PaneContentWire.code`: a file's contents at a revision.
///
/// Carries text plus the line number its first line represents, rather than an
/// array of per-line objects — the client splits and numbers, which keeps a
/// whole-file payload the same size as the `.text` variant it replaces.
public struct CodePayload: Decodable, Equatable {
    public let path:      String
    /// A git SHA/ref, or `"working"` for the on-disk working tree.
    public let revision:  String
    /// The line number `text`'s first line represents.
    public let firstLine: Int
    public let text:      String

    enum CodingKeys: String, CodingKey {
        case path, revision, text
        case firstLine = "first_line"
    }

    public init(path: String, revision: String, firstLine: Int, text: String) {
        self.path      = path
        self.revision  = revision
        self.firstLine = firstLine
        self.text      = text
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path      = (try? c.decode(String.self, forKey: .path)) ?? ""
        revision  = (try? c.decode(String.self, forKey: .revision)) ?? ""
        firstLine = (try? c.decode(Int.self, forKey: .firstLine)) ?? 1
        text      = (try? c.decode(String.self, forKey: .text)) ?? ""
    }
}

/// The payload of `PaneContentWire.diff`: a PR's change, structured per file.
public struct DiffPayload: Decodable, Equatable {
    public let repo:   String
    public let number: Int?
    /// Per-file structure. Empty when `tooLarge` is set.
    public let files:  [DiffFileModel]
    /// True when the daemon's fetch hit its own large-diff gate. The view must
    /// then say so explicitly and name `changedFiles`, rather than render an
    /// empty `files` list as "this PR changes nothing".
    public let tooLarge: Bool
    /// How many files the PR changes — the only thing a `tooLarge` diff can
    /// still say about its own size.
    public let changedFiles: Int

    enum CodingKeys: String, CodingKey {
        case repo, number, files
        case tooLarge     = "too_large"
        case changedFiles = "changed_files"
    }

    public init(
        repo:         String,
        number:       Int?,
        files:        [DiffFileModel],
        tooLarge:     Bool = false,
        changedFiles: Int  = 0
    ) {
        self.repo         = repo
        self.number       = number
        self.files        = files
        self.tooLarge     = tooLarge
        self.changedFiles = changedFiles
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repo         = (try? c.decode(String.self, forKey: .repo)) ?? ""
        number       = try c.decodeIfPresent(Int.self, forKey: .number)
        files        = (try? c.decode([DiffFileModel].self, forKey: .files)) ?? []
        tooLarge     = (try? c.decode(Bool.self, forKey: .tooLarge)) ?? false
        changedFiles = (try? c.decode(Int.self, forKey: .changedFiles)) ?? 0
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
    /// A file's contents at a revision, line-addressable (W2).
    case code(CodePayload)
    /// A PR's change, structured per file/hunk/line (W2).
    case diff(DiffPayload)
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
        case "code":
            // Decoded from the decoder rather than the keyed container: the
            // payload's fields are siblings of `kind`, not nested under it.
            self = .code(try CodePayload(from: d))
        case "diff":
            self = .diff(try DiffPayload(from: d))
        default:
            let raw = try AnyDecodable(from: d)
            self = .unknown(raw.value)
        }
    }
}

extension PaneContentWire: Equatable {
    /// `.text`/`.loading`/`.error`/`.prList` compare structurally. `.jsonSnapshot`
    /// and `.unknown` always compare unequal — even given byte-identical
    /// payloads — a deliberate conservative choice: report "changed" rather
    /// than risk a false "unchanged" for a payload kind this client can't
    /// actually compare (they carry `Any`).
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
        case (.code(let a), .code(let b)):
            return a == b
        case (.diff(let a), .diff(let b)):
            return a == b
        case (.jsonSnapshot, .jsonSnapshot):
            return false
        case (.unknown, .unknown):
            return false
        default:
            return false
        }
    }
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

// MARK: - Anchor / Emphasis / PaneAddress (W1 — curated-agent-views)

/// A single point of interest inside a pane's content — "the one place to
/// land." Mirrors `Anchor` in `src/ipc/protocol.rs`. W1 transports every
/// variant but renders none of them; only `PaneAddress.reason` is rendered
/// (as a tab caption) in this wedge.
public enum Anchor: Equatable {
    case line(path: String?, line: Int)
    case comment(id: String)
    case section(name: String)
    case queueRow(repo: String, number: Int)
}

extension Anchor: Decodable {
    private enum K: String, CodingKey { case kind, path, line, id, name, repo, number }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "line":
            self = .line(
                path: try c.decodeIfPresent(String.self, forKey: .path),
                line: try c.decode(Int.self, forKey: .line)
            )
        case "comment":
            self = .comment(id: try c.decode(String.self, forKey: .id))
        case "section":
            self = .section(name: try c.decode(String.self, forKey: .name))
        case "queue_row":
            self = .queueRow(
                repo:   try c.decode(String.self, forKey: .repo),
                number: try c.decode(Int.self,    forKey: .number)
            )
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c,
                debugDescription: "unknown Anchor kind: \(other)"
            )
        }
    }
}

/// A range to highlight within a pane's content. See `Anchor` for the
/// single-point counterpart. Mirrors `Emphasis` in `src/ipc/protocol.rs`.
public enum Emphasis: Equatable {
    case lineRange(path: String?, start: Int, end: Int)
    case comment(id: String)
    case section(name: String)
    case textRange(start: Int, end: Int)
    case queueRow(repo: String, number: Int)
}

extension Emphasis: Decodable {
    private enum K: String, CodingKey { case kind, path, start, end, id, name, repo, number }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "line_range":
            self = .lineRange(
                path:  try c.decodeIfPresent(String.self, forKey: .path),
                start: try c.decode(Int.self, forKey: .start),
                end:   try c.decode(Int.self, forKey: .end)
            )
        case "comment":
            self = .comment(id: try c.decode(String.self, forKey: .id))
        case "section":
            self = .section(name: try c.decode(String.self, forKey: .name))
        case "text_range":
            self = .textRange(
                start: try c.decode(Int.self, forKey: .start),
                end:   try c.decode(Int.self, forKey: .end)
            )
        case "queue_row":
            self = .queueRow(
                repo:   try c.decode(String.self, forKey: .repo),
                number: try c.decode(Int.self,    forKey: .number)
            )
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c,
                debugDescription: "unknown Emphasis kind: \(other)"
            )
        }
    }
}

/// Where to look inside a pane's content, and why. Mirrors `PaneAddress` in
/// `src/ipc/protocol.rs` — a sibling of `PaneFreshness` on `pane_content`,
/// not folded into `PaneContentWire`, so it can be re-sent cheaply without
/// re-sending content. Every field is optional/defaulted so a frame from a
/// daemon that predates this type — or one with nothing to point at — still
/// decodes.
public struct PaneAddress: Decodable, Equatable {
    public let anchor:   Anchor?
    public let emphasis: [Emphasis]
    /// One short human-readable phrase explaining why this was shown.
    public let reason:   String?

    private enum CodingKeys: String, CodingKey { case anchor, emphasis, reason }

    public init(anchor: Anchor?, emphasis: [Emphasis], reason: String?) {
        self.anchor   = anchor
        self.emphasis = emphasis
        self.reason   = reason
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        // `try?`, not `decodeIfPresent`: a future/unrecognized Anchor kind must
        // drop only the anchor, not throw out of this initializer — which would
        // propagate through ServerMsg.decode's own `try?` and silently discard
        // the whole PaneContent message (content and freshness included), the
        // same hazard class B12 exists to prevent for PaneTree node kinds.
        anchor   = try? c.decodeIfPresent(Anchor.self, forKey: .anchor) ?? nil
        emphasis = (try? c.decode([Emphasis].self, forKey: .emphasis)) ?? []
        reason   = try c.decodeIfPresent(String.self, forKey: .reason)
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
    /// Per-pane address, keyed by `pane_id` (W1 — curated-agent-views).
    /// Absent entry == no addressing concept pushed for that pane yet.
    public var paneAddress: [String: PaneAddress]

    /// Initial state for a focus whose layout hasn't arrived yet.
    public static let initial = FocusLayoutModel(
        tree:        .replLeaf,
        focusedPane: nil,
        paneContent: [:],
        paneFreshness: [:],
        paneAddress: [:]
    )

    public init(
        tree: PaneTree,
        focusedPane: String?,
        paneContent: [String: PaneContentWire],
        paneFreshness: [String: PaneFreshness] = [:],
        paneAddress: [String: PaneAddress] = [:]
    ) {
        self.tree          = tree
        self.focusedPane   = focusedPane
        self.paneContent   = paneContent
        self.paneFreshness = paneFreshness
        self.paneAddress   = paneAddress
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
