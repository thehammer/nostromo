// NostromoKit — FocusRegionState.swift
//
// Per-focus, per-region UI state that must survive a `PaneTree` rebuild
// (W5 — ios-curated-view-parity, D6): which pane is frontmost, which panes
// are unread, and an opaque scroll-restore key per pane. Lives in
// `DaemonStore` (a long-lived object), never in a view's `@State` — a
// `.splitTopology` rebuild, a width-class transition (W6), or the view
// simply being torn down and recreated (backgrounding, navigation) would
// otherwise silently reset it.
//
// Keyed by region path (`RegionPath`) rather than being a singleton, even
// though this wedge only ever populates `compactRegion` — W6 needs one
// entry per simultaneously-visible region at regular width, and
// parameterising the key now means W6 fills in a dictionary rather than
// rewriting this type.
//
// import Foundation only — pure value type, exercised by `make kit-test`
// with no simulator and no device.
import Foundation

public struct FocusRegionState: Equatable {

    /// The region path used for the compact, single-strip presentation this
    /// wedge implements. W6 (regular width) introduces real per-region paths;
    /// until then every call site in the app uses this one.
    public static let compactRegion = RegionPath.root

    private var frontmostPane: [String: String] = [:]

    /// A region's read state for one pane. Absent entry (no key in
    /// `readState[regionPath]` for `paneId`) means the region has never
    /// heard of the pane at all — no opinion, not unread. `Int`-valued
    /// tracking alone can't distinguish "known but the operator has never
    /// actually looked at it from here" from "known and caught up to some
    /// version": this enum names the two cases explicitly instead of
    /// encoding the former as a synthetic version number.
    private enum ReadState: Equatable {
        /// A push landed for this pane while it was NOT `regionPath`'s
        /// frontmost pane, and it has never been made frontmost since —
        /// unread regardless of `contentVersion`, since there's no version
        /// the operator is known to have actually seen.
        case knownButNeverViewed
        /// The operator has seen this pane, current as of `version` — either
        /// by tapping it (`select`) or because a push landed while it was
        /// already frontmost (`noteContentVersion`). Unread only once a
        /// strictly later content version arrives.
        case caughtUpTo(version: Int)
    }
    /// Read state, scoped by `(regionPath, paneId)` — nested rather than a
    /// flat `[String: ReadState]` keyed by `paneId` alone, so an unread mark
    /// recorded for a pane under one region path can never leak into
    /// another region path that happens to host a pane of the same id.
    private var readState: [String: [String: ReadState]] = [:]
    /// Scroll-restore keys are deliberately paneId-only, not region-scoped —
    /// a given pane's scroll position doesn't depend on which region is
    /// currently hosting it.
    private var scrollKeys: [String: Int] = [:]

    public init() {}

    // MARK: - Frontmost pane

    /// The frontmost pane for `regionPath`. Falls back to `fallback` when
    /// nothing has been recorded yet, or when the previously-recorded pane
    /// is no longer in `available` (e.g. removed by `reset_panes`) — and
    /// falls back further, to the first available pane, when `fallback`
    /// itself isn't available either.
    public func frontmostPane(for regionPath: String, available: [String], fallback: String) -> String {
        if let current = frontmostPane[regionPath], available.contains(current) {
            return current
        }
        if available.contains(fallback) {
            return fallback
        }
        return available.first ?? fallback
    }

    /// D4's layout-change transition table. `treeActivePaneId` is the single
    /// pane id the incoming tree's own `active` pointer(s) resolve to (see
    /// `PaneTree.resolvedActivePaneId` — nil when ambiguous or when the tree
    /// has no tabs node at all). Only `.activeTabOnly`/`.tabMembership`/
    /// `.splitTopology` ever move the frontmost pane via `treeActivePaneId`;
    /// `.identical`/`.contentOnly` NEVER do — a content-only republish (by
    /// far the most frequent broadcast) must never fight the operator's own
    /// tab choice. `focusedPane`, when non-nil and present in `available`,
    /// always wins afterward, regardless of classification — a deliberate
    /// show takes focus within its own region unconditionally.
    public mutating func apply(
        change: LayoutChange,
        regionPath: String,
        treeActivePaneId: String?,
        focusedPane: String?,
        available: [String]
    ) {
        switch change {
        case .identical, .contentOnly:
            break
        case .activeTabOnly, .tabMembership, .splitTopology:
            if let treeActivePaneId, available.contains(treeActivePaneId) {
                frontmostPane[regionPath] = treeActivePaneId
            }
        }
        if let focusedPane, available.contains(focusedPane) {
            frontmostPane[regionPath] = focusedPane
        }
    }

    /// The operator tapping a tab: `paneId` becomes frontmost for
    /// `regionPath`, and its last-seen version catches up to
    /// `contentVersion` — clearing any unread mark.
    public mutating func select(paneId: String, regionPath: String, contentVersion: Int) {
        frontmostPane[regionPath] = paneId
        readState[regionPath, default: [:]][paneId] = .caughtUpTo(version: contentVersion)
    }

    // MARK: - Unread (D7)

    /// A pane is unread iff it is not `regionPath`'s current frontmost pane
    /// AND `contentVersion` exceeds what was last seen for it under that
    /// region path. A pane `regionPath` has never recorded anything for
    /// (never `select`-ed, never pushed to via `noteContentVersion`) is not
    /// unread — an untouched region has no opinion about a pane it hasn't
    /// been introduced to, rather than defaulting to "very stale."
    public func isUnread(paneId: String, regionPath: String, contentVersion: Int) -> Bool {
        if frontmostPane[regionPath] == paneId { return false }
        switch readState[regionPath]?[paneId] {
        case nil:                        return false
        case .knownButNeverViewed:       return true
        case .caughtUpTo(let version):   return contentVersion > version
        }
    }

    /// Call whenever a content push lands for `paneId`. If it's currently
    /// frontmost for `regionPath`, it's immediately seen — the read state
    /// advances to `.caughtUpTo(contentVersion)` so the push is never marked
    /// unread. Otherwise, records `.knownButNeverViewed` — "known to this
    /// region, and not something the operator has looked at" — so an
    /// immediate `isUnread` check reads true regardless of `contentVersion`,
    /// without disturbing any other region path that has never heard of
    /// this pane at all.
    public mutating func noteContentVersion(paneId: String, regionPath: String, contentVersion: Int) {
        if frontmostPane[regionPath] == paneId {
            readState[regionPath, default: [:]][paneId] = .caughtUpTo(version: contentVersion)
        } else {
            readState[regionPath, default: [:]][paneId] = .knownButNeverViewed
        }
    }

    // MARK: - Scroll restore (forward provision — unread/frontmost only actively consume state this wedge)

    /// An opaque per-pane scroll-restore key — a row index, a character
    /// offset, whatever the surface means by it. Only the transcript and the
    /// queue populate this in later wedges; the slot exists now so W6 (and
    /// W7/W8/W9) fill in a dictionary rather than adding one.
    public func scrollKey(for paneId: String) -> Int? {
        scrollKeys[paneId]
    }

    public mutating func setScrollKey(_ key: Int, for paneId: String) {
        scrollKeys[paneId] = key
    }

    /// What restoring `paneId`'s saved scroll key should do, given what the
    /// surface currently reports visible (W6 — ios-curated-view-parity, D5).
    ///
    /// A width-class change genuinely restructures the view tree — the
    /// container that held a `ScrollView` is gone, so its offset is lost no
    /// matter how stable the `.id()` is. Every other piece of state this
    /// type holds survives a transition by never having been in the view;
    /// scroll position is the one thing that needs an explicit save and an
    /// explicit restore, and this is the restore half.
    ///
    /// The "already visible means don't move" clause is what stops a restore
    /// from producing a visible jump on a transition that happened not to
    /// move anything — the same rule, and the same three lines, as macOS's
    /// `ScrollDecision.decide(anchor:visibleRange:)`
    /// (`macOS/Nostromo/UI/ScrollDecision.swift:37-41`), mirrored here rather
    /// than reinvented because both clients are answering the identical
    /// question.
    public func scrollRestore(for paneId: String, visibleRange: ClosedRange<Int>?) -> ScrollRestore {
        ScrollRestore.decide(savedKey: scrollKeys[paneId], visibleRange: visibleRange)
    }

    // MARK: - Pruning (W6, D5)

    /// Drop every region path not in `livePaths` and every pane not in
    /// `livePanes`.
    ///
    /// Region paths are a pure function of the tree, so a tree rebuild that
    /// removes a split or closes a tab leaves this type holding entries no
    /// presentation can ever reach again. Without this they accumulate for
    /// the lifetime of the connection — and worse, a later rebuild that
    /// happens to reintroduce the same path resurrects a stale frontmost
    /// pane or a stale unread mark from a layout the operator last saw
    /// minutes ago. Call sites pass `LayoutRegions.allPaths(in:)` and
    /// `Set(tree.paneIds)`.
    public mutating func prune(livePaths: Set<String>, livePanes: Set<String>) {
        frontmostPane = frontmostPane.filter { livePaths.contains($0.key) && livePanes.contains($0.value) }
        readState = readState
            .filter { livePaths.contains($0.key) }
            .mapValues { $0.filter { livePanes.contains($0.key) } }
        scrollKeys = scrollKeys.filter { livePanes.contains($0.key) }
    }
}

// MARK: - ScrollRestore

/// Whether restoring a saved scroll key should move the viewport (W6 —
/// ios-curated-view-parity, D5).
///
/// A separate value type for the same reason macOS's `ScrollDecision` is one:
/// "restoring a position already on screen does not move the viewport" is
/// otherwise only observable by watching a real `ScrollView` not move, which
/// is not a thing a device-less test bundle can assert. Extracting the
/// decision is the only form in which that criterion is testable, so the
/// view's job shrinks to obeying whatever this returns.
public enum ScrollRestore: Equatable {
    /// Leave the viewport exactly where it is.
    case none
    /// Bring `target` back into view.
    case scrollTo(target: Int)

    /// The whole rule, in one place so every caller shares it.
    ///
    /// - No saved key: nothing was ever recorded for this surface, so there
    ///   is nothing to restore.
    /// - No `visibleRange`: the surface hasn't been laid out yet and doesn't
    ///   know what it is showing. That is a first paint, and a first paint
    ///   always honours its saved key.
    /// - Key already inside `visibleRange`: do nothing. This clause is what
    ///   stops a restore from producing a visible jump on a transition that
    ///   happened not to move anything.
    public static func decide(savedKey: Int?, visibleRange: ClosedRange<Int>?) -> ScrollRestore {
        guard let savedKey else { return .none }
        guard let visibleRange else { return .scrollTo(target: savedKey) }
        return visibleRange.contains(savedKey) ? .none : .scrollTo(target: savedKey)
    }
}

// MARK: - PaneTree.resolvedActivePaneId

extension PaneTree {

    /// The pane id designated "active" by walking every tabs node in the
    /// tree and resolving its `children[active]` down to a leaf — recursing
    /// through a nested split (whose first child breaks the tie; a split
    /// has no "active" concept of its own) or a nested tabs node (whose own
    /// `active` continues the resolution) until a leaf is reached.
    ///
    /// Returns `nil` when the tree has no tabs node anywhere (nothing for
    /// this to designate), or when more than one tabs node's resolution
    /// disagrees — two simultaneously-visible tabs regions with no
    /// `focused_pane` to disambiguate is genuinely ambiguous, and this
    /// conservatively declines to guess rather than pick one arbitrarily.
    public var resolvedActivePaneId: String? {
        let leaves = Set(activeTabsLeaves)
        return leaves.count == 1 ? leaves.first : nil
    }

    /// Every leaf resolved by some tabs node's own `active` pointer,
    /// anywhere in the tree — see `resolvedActivePaneId`.
    private var activeTabsLeaves: [String] {
        switch self {
        case .leaf:
            return []
        case .split(_, let children, _):
            return children.flatMap { $0.activeTabsLeaves }
        case .tabs(let children, _, let active):
            var results = children.flatMap { $0.activeTabsLeaves }
            if children.indices.contains(active) {
                results.append(Self.firstLeaf(children[active]))
            }
            return results
        }
    }

    /// The first leaf reached by always taking a split's first child and a
    /// tabs node's own active child (defensively falling back to index 0 if
    /// `active` is out of range).
    private static func firstLeaf(_ node: PaneTree) -> String {
        switch node {
        case .leaf(let paneId):
            return paneId
        case .split(_, let children, _):
            return children.first.map(firstLeaf) ?? "unknown"
        case .tabs(let children, _, let active):
            let index = children.indices.contains(active) ? active : 0
            return children.indices.contains(index) ? firstLeaf(children[index]) : "unknown"
        }
    }
}
