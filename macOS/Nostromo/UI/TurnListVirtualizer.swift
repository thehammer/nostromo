import CoreGraphics
import Foundation

/// Owns transcript geometry: how tall every turn is, where each one sits, which
/// ones intersect the viewport, and the anchor that keeps the operator's scroll
/// position still while those answers change underneath them.
///
/// Knows nothing about `NSView`. That is deliberate — it is the part of view
/// virtualization that can be tested exhaustively without a window, and getting
/// it right before any of it is wired to AppKit is the difference between a
/// bounded transcript and a jittery one.
///
/// ## Heights are two-tier
///
/// Every turn starts with a cheap arithmetic **estimate** from
/// `TurnHeightEstimator`. When a turn materializes, its real measured height
/// replaces the estimate and is cached against `(contentKey, width)`. The
/// document height shifts when that happens — which is exactly what the anchor
/// exists to absorb.
///
/// ## Offsets are a Fenwick tree, not a prefix-sum array
///
/// A plain running-sum array makes `offset(of:)` O(1) but every height
/// correction O(n), and a materialization pass performs up to 60 of them. At
/// five thousand turns that is a quarter-million writes per scroll tick, on the
/// main thread, for a change nobody can see. A binary indexed tree makes both
/// the correction and the offset query O(log n), and `index(atY:)` — asked on
/// every scroll event — an O(log n) descent rather than a linear scan.
final class TurnListVirtualizer {

    /// Hard maximum number of materialized turn views. A backstop, not the
    /// policy: the window is expressed in viewport heights so a tall pane full
    /// of diffs behaves like a short one. If this clamp is ever the binding
    /// constraint, the overscan is too generous for that pane.
    static let maxMaterialized = 60

    /// Overscan above and below the viewport, in viewport heights.
    static let overscanScreens: CGFloat = 1.0

    /// A scroll position expressed against content rather than against pixels.
    ///
    /// Absolute scroll offsets are meaningless the moment any height above the
    /// viewport changes. This names the turn at the top of the viewport and how
    /// far into it we are, so the position can be restored after a height
    /// correction, a live append above the viewport, or a resize.
    ///
    /// When the turn is materialized it also names the **item** inside it (a block or a
    /// tool group, `TurnIsland.anchorItem`) and how far into that item. A height change
    /// inside the turn but above the viewport top (a group opening off screen) moves
    /// everything below it, including the turn offset that a turn-only anchor would keep.
    struct Anchor: Equatable {
        let key: String
        let index: Int
        let offsetWithinTurn: CGFloat
        var itemKey: String? = nil
        var offsetInItem: CGFloat = 0
    }

    // MARK: - State

    private(set) var width: CGFloat = 0
    private(set) var count = 0

    private var keys:    [String]  = []
    /// Each turn's `ChatTurn.id`, so an index this geometry hands out names the turn it meant
    /// even while the pane's turn array is momentarily ahead of it (an index into that array
    /// can name a different turn until the change event arrives).
    private var ids:     [UUID]    = []
    private var heights: [CGFloat] = []
    private var isExact: [Bool]    = []
    /// Fenwick tree over `heights`, 1-based.
    private var tree: [CGFloat] = []
    /// Fold digest (`ToolFoldAdapter.foldDigest`) each turn's height was last estimated or
    /// measured with. Parallel to `keys`.
    private var digests: [String] = []
    /// Measured heights, keyed by `"\(contentKey)|\(foldDigest)|\(width)"`.
    ///
    /// The fold digest is in the key because fold state changes a turn's height without
    /// changing its content: keyed by content alone, a turn measured with a group open
    /// would be handed that height back after the group closed (on a splice, a width
    /// round trip or a refresh), and the geometry would disagree with the view.
    ///
    /// Bounded, because a streaming turn's `contentKey` changes on every durable
    /// block append and each key is a ~250-character string: left to grow, a long
    /// session leaves tens of thousands of dead entries — order tens of megabytes
    /// — inside the component whose job is bounding memory. Entries are worth
    /// keeping only for turns near the viewport, so a simple capacity bound with
    /// wholesale eviction is enough; a miss costs one re-measure.
    private var measured: [String: CGFloat] = [:]
    private static let measuredCapacity = 4_000
    /// Index lookup for anchor re-resolution after a splice.
    private var indexByKey: [String: Int] = [:]

    /// The fold state each turn renders with: its explicit group and activity-row choices,
    /// expanded results and held roll-ins. Feeds both the estimate and the height-cache key
    /// (`ToolFoldAdapter.foldDigest`).
    var foldState: (ChatTurn) -> TurnInteractionState = { _ in TurnInteractionState() }
    /// Groups and activity rows without an explicit choice open (harness
    /// `NOSTROMO_LOAD_FOLD_DEFAULT=expanded`: Show All).
    var foldsExpandedByDefault = false

    /// Completed turns' fold shapes, by turn id, with the signature they were planned from.
    /// Grouping does not depend on width, so a resize, reset or splice re-estimates from
    /// these instead of re-planning every turn. Bounded like `measured`.
    private var shapes: [UUID: (signature: String, shape: FoldShape)] = [:]
    private static let shapesCapacity = 20_000

    /// Counts every Fenwick node touched, so tests can assert the complexity
    /// claim above rather than trusting a wall-clock measurement.
    private(set) var treeOperations = 0

    var documentHeight: CGFloat { prefixSum(through: count) }

    // MARK: - Population

    /// Replace all geometry, discarding every measurement. Used on `.cleared` and
    /// on the first layout.
    ///
    /// Discarding is deliberate — New Session goes through here, and heights
    /// measured for a transcript that no longer exists are dead weight. Which is
    /// why there is no `adoptMeasuredHeights()` call: there used to be one, two
    /// lines after `measured.removeAll()`, so it was unconditionally a no-op
    /// (`adoptMeasuredHeights` opens with `guard !measured.isEmpty`) and `isExact`
    /// was unconditionally all-false. Dead code that read as a safeguard.
    func reset(turns: [ChatTurn], width: CGFloat) {
        measured.removeAll(keepingCapacity: true)
        self.width = max(width, 1)
        keys    = turns.map { $0.contentKey }
        ids     = turns.map(\.id)
        digests = turns.map { foldDigest(for: $0) }
        heights = turns.map { estimate($0) }
        isExact = Array(repeating: false, count: turns.count)
        count   = turns.count
        rebuildTree()
        reindex()
    }

    /// Re-derive geometry from `index` onward, preserving everything before it.
    /// This is the splice path: turns before `index` kept their identity, their
    /// measured heights, and their views.
    func splice(turns: [ChatTurn], from index: Int) {
        // Clamp to both the old and the new length. Clamping only to the old
        // one lets `turns[floor...]` index past the end of a shorter list.
        let floor = max(0, min(index, count, turns.count))
        keys.removeSubrange(floor...)
        ids.removeSubrange(floor...)
        digests.removeSubrange(floor...)
        heights.removeSubrange(floor...)
        isExact.removeSubrange(floor...)
        for turn in turns[floor...] {
            keys.append(turn.contentKey)
            ids.append(turn.id)
            digests.append(foldDigest(for: turn))
            heights.append(estimate(turn))
            isExact.append(false)
        }
        count = turns.count
        adoptMeasuredHeights(from: floor)
        rebuildTree()
        reindex()
    }

    /// One turn appended at the end.
    ///
    /// Extends the Fenwick tree in place rather than rebuilding it. A rebuild is
    /// O(n) and this runs once per arriving turn, so rebuilding here would make
    /// a session's total append cost quadratic in its own length — the exact
    /// shape being removed elsewhere.
    func append(_ turn: ChatTurn) {
        let key = turn.contentKey
        let digest = foldDigest(for: turn)
        keys.append(key)
        ids.append(turn.id)
        digests.append(digest)
        let cached = measured[cacheKey(key, digest)]
        let height = cached ?? estimate(turn)
        heights.append(height)
        isExact.append(cached != nil)
        indexByKey[key] = count
        count += 1

        // A Fenwick node at 1-based position i covers the half-open range ending
        // at i of length lsb(i), and its children sit at i-1, i-2, i-4, … down to
        // i - lsb/2. Summing those gives the new node in O(log n) worst case and
        // O(1) amortised.
        tree.append(height)
        let i = count
        var step = 1
        let lsb = i & (-i)
        while step < lsb {
            tree[i] += tree[i - step]
            treeOperations += 1
            step <<= 1
        }
    }

    /// A turn's content changed in place (blocks appended while streaming).
    /// Returns how much the document grew or shrank.
    @discardableResult
    func refresh(_ turn: ChatTurn, at index: Int) -> CGFloat {
        guard index >= 0, index < count else { return 0 }
        let key = turn.contentKey
        // Retire the superseded key. A streaming turn changes key on every block
        // append, and each abandoned entry holds a ~300-byte string
        // (`identityKey` embeds 256 characters of user input) until the next
        // full reindex — tens of megabytes over a long session, inside the
        // change whose whole point is bounding memory.
        let oldKey = keys[index]
        if oldKey != key, indexByKey[oldKey] == index { indexByKey.removeValue(forKey: oldKey) }
        keys[index] = key
        ids[index] = turn.id
        indexByKey[key] = index
        let digest = foldDigest(for: turn)
        digests[index] = digest

        // A measured height is only reusable for a *completed* turn. `contentKey`
        // is invariant while a text block grows in place, so a turn measured
        // while materialized and then scrolled away would keep being handed its
        // stale height and the document would stop growing.
        let cached = turn.isComplete ? measured[cacheKey(key, digest)] : nil
        let height = cached ?? estimate(turn)
        isExact[index] = cached != nil
        return setHeight(height, at: index)
    }

    /// Width changed: every estimate is stale, and every measured height was
    /// measured at the old width.
    func invalidateWidth(_ newWidth: CGFloat, turns: [ChatTurn]) {
        // Diverging silently here would leave heights and keys for turns the
        // caller no longer has, with `count` still claiming they exist.
        guard turns.count == count else {
            reset(turns: turns, width: newWidth)
            return
        }
        width = max(newWidth, 1)
        for i in 0 ..< min(count, turns.count) {
            let key = turns[i].contentKey
            let digest = foldDigest(for: turns[i])
            keys[i] = key
            ids[i] = turns[i].id
            digests[i] = digest
            if let m = measured[cacheKey(key, digest)] {
                heights[i] = m
                isExact[i] = true
            } else {
                heights[i] = estimate(turns[i])
                isExact[i] = false
            }
        }
        rebuildTree()
        reindex()
    }

    // MARK: - Heights

    /// Record the real measured height of a materialized turn.
    /// Returns the document-height delta the caller must absorb.
    ///
    /// Only a **completed** turn's height is cached. `contentKey` is invariant
    /// while a text block grows in place, so a height measured mid-stream and
    /// cached under that key would be handed back once the turn completed — and
    /// `refresh`'s `isComplete` guard would wave it through, marking an
    /// off-screen turn exact at a height hundreds of points short of the truth.
    ///
    /// `foldDigest` is the fold state the view was measured with; it becomes the turn's
    /// current digest.
    @discardableResult
    func recordMeasured(_ height: CGFloat, at index: Int, isComplete: Bool = true,
                        foldDigest: String = "") -> CGFloat {
        guard index >= 0, index < count else { return 0 }
        digests[index] = foldDigest
        if isComplete {
            if measured.count >= Self.measuredCapacity {
                measured.removeAll(keepingCapacity: true)
            }
            measured[cacheKey(keys[index], foldDigest)] = height
        }
        isExact[index] = isComplete
        return setHeight(height, at: index)
    }

    func height(at index: Int) -> CGFloat {
        guard index >= 0, index < count else { return 0 }
        return heights[index]
    }

    /// The content key of the turn at `index` (what an `Anchor` names it by).
    func contentKey(at index: Int) -> String? {
        guard index >= 0, index < count else { return nil }
        return keys[index]
    }

    /// The `ChatTurn.id` of the turn at `index`.
    func turnID(at index: Int) -> UUID? {
        guard index >= 0, index < count else { return nil }
        return ids[index]
    }

    /// Where the turn `id` is in this geometry. O(turns): for clicks, not for passes.
    func index(ofTurnID id: UUID) -> Int? {
        ids.lastIndex(of: id)
    }

    func isHeightExact(at index: Int) -> Bool {
        guard index >= 0, index < count else { return false }
        return isExact[index]
    }

    /// Y coordinate of the top of the turn at `index`.
    func offset(of index: Int) -> CGFloat {
        prefixSum(through: max(0, min(index, count)))
    }

    // MARK: - Windowing

    /// Indices of the turns to materialize for `viewport`, inflated by the
    /// overscan and clamped to `maxMaterialized`.
    ///
    /// The clamp keeps the newest end of the window when it bites, because that
    /// is where a reader who is following a stream is looking.
    func visibleWindow(viewport: CGRect) -> Range<Int> {
        guard count > 0 else { return 0 ..< 0 }
        let overscan = max(viewport.height, 1) * Self.overscanScreens
        let top      = viewport.minY - overscan
        let bottom   = viewport.maxY + overscan

        let first = index(atY: top)
        var last  = index(atY: bottom)
        // `index(atY:)` names the turn containing `bottom`; include it.
        last = min(count - 1, last)
        guard first <= last else { return 0 ..< 0 }

        var range = first ..< (last + 1)
        if range.count > Self.maxMaterialized {
            // Two constraints, and the clamp has to honour both.
            //
            // The viewport must be covered. `upperBound` sits a whole viewport
            // height BELOW what is on screen, so simply keeping the last N
            // spends the budget on turns nobody can see and leaves a blank band
            // at the top of the viewport — or, on a tall pane of short turns, a
            // blank viewport.
            //
            // Whatever is left over belongs to the bottom. A reader following a
            // stream is at the newest end, and that is the direction new content
            // arrives from.
            let visibleFirst = index(atY: viewport.minY)
            let visibleLast  = min(count - 1, index(atY: viewport.maxY))
            let visibleCount = visibleLast - visibleFirst + 1

            var upper = min(range.upperBound,
                            visibleLast + 1 + max(0, Self.maxMaterialized - visibleCount))
            var lower = max(range.lowerBound, upper - Self.maxMaterialized)
            if lower > visibleFirst {
                // The viewport itself is wider than the budget: keep its top,
                // which is where reading starts.
                lower = visibleFirst
                upper = min(range.upperBound, lower + Self.maxMaterialized)
            }
            range = lower ..< upper
        }
        return range
    }

    /// Index of the turn whose vertical extent contains `y`, clamped to the list.
    func index(atY y: CGFloat) -> Int {
        guard count > 0 else { return 0 }
        guard y > 0 else { return 0 }
        return min(count - 1, searchTree(for: y))
    }

    // MARK: - Anchoring

    /// Name the position currently at the top of the viewport, so it can be put
    /// back after the geometry underneath it changes.
    ///
    /// `item` names the item at `offsetWithinTurn` inside the turn at `index` and the offset
    /// into it, when the turn is materialized (nil: anchor on the turn alone).
    func captureAnchor(viewportTop: CGFloat,
                       item: ((_ index: Int, _ offsetWithinTurn: CGFloat) -> (key: String, offset: CGFloat)?)? = nil)
        -> Anchor? {
        guard count > 0 else { return nil }
        let index = self.index(atY: viewportTop)
        let offsetWithinTurn = viewportTop - offset(of: index)
        var anchor = Anchor(key: keys[index], index: index, offsetWithinTurn: offsetWithinTurn)
        if let found = item?(index, offsetWithinTurn) {
            anchor.itemKey = found.key
            anchor.offsetInItem = found.offset
        }
        return anchor
    }

    /// Where the viewport top has to move so `anchor` stays where it was.
    ///
    /// Re-resolves the anchor by content key first: a splice reindexes turns,
    /// and following the stale index would move the operator's reading position
    /// by however many turns the splice inserted.
    ///
    /// `itemOffset` finds the anchor's item inside the (materialized) turn at an index; when
    /// it does, the item is what stays put. Otherwise the turn-level offset is used.
    func restoredTop(for anchor: Anchor,
                     itemOffset: ((_ index: Int, _ itemKey: String) -> CGFloat?)? = nil) -> CGFloat {
        let index = indexByKey[anchor.key] ?? min(anchor.index, max(0, count - 1))
        if let itemKey = anchor.itemKey, let top = itemOffset?(index, itemKey) {
            return offset(of: index) + top + anchor.offsetInItem
        }
        return offset(of: index) + anchor.offsetWithinTurn
    }

    // MARK: - Fenwick tree

    private func setHeight(_ height: CGFloat, at index: Int) -> CGFloat {
        let delta = height - heights[index]
        guard delta != 0 else { return 0 }
        heights[index] = height
        var i = index + 1
        while i <= count {
            tree[i] += delta
            treeOperations += 1
            i += i & (-i)
        }
        return delta
    }

    /// Sum of `heights[0 ..< n]`.
    private func prefixSum(through n: Int) -> CGFloat {
        var sum: CGFloat = 0
        var i = max(0, min(n, count))
        while i > 0 {
            sum += tree[i]
            treeOperations += 1
            i -= i & (-i)
        }
        return sum
    }

    /// Largest `i` with `prefixSum(through: i) <= y`, as an O(log n) descent.
    private func searchTree(for y: CGFloat) -> Int {
        var position = 0
        var remaining = y
        var step = highestPowerOfTwo(atMost: count)
        while step > 0 {
            let next = position + step
            if next <= count, tree[next] <= remaining {
                position = next
                remaining -= tree[next]
                treeOperations += 1
            }
            step >>= 1
        }
        return position
    }

    private func rebuildTree() {
        // Counted, so `treeOperations` can tell an O(log n) incremental update
        // apart from an O(n) rebuild. Uncounted, a rebuild reads as zero work
        // and the complexity assertions pass for the wrong reason.
        treeOperations += count
        tree = Array(repeating: 0, count: count + 1)
        for i in 0 ..< count { tree[i + 1] = heights[i] }
        var i = 1
        while i <= count {
            let parent = i + (i & (-i))
            if parent <= count { tree[parent] += tree[i] }
            i += 1
        }
    }

    private func reindex() {
        indexByKey.removeAll(keepingCapacity: true)
        for (i, key) in keys.enumerated() { indexByKey[key] = i }
    }

    /// Adopt any already-measured height for turns from `floor` onward, so a
    /// **splice** does not throw away measurements that are still valid.
    ///
    /// Only splice. `reset` discards measurements on purpose — see its comment —
    /// and this doc used to claim it covered reset too, which was the opposite of
    /// what the code did. `ReplView.materialize()` re-syncs stale geometry through
    /// `splice` rather than `reset` precisely so that this keeps every measured
    /// height across the re-sync; do not "simplify" that away.
    private func adoptMeasuredHeights(from floor: Int = 0) {
        guard !measured.isEmpty else { return }
        for i in floor ..< count {
            if let m = measured[cacheKey(keys[i], digests[i])] {
                heights[i] = m
                isExact[i] = true
            }
        }
    }

    // MARK: - Folds

    private func foldDigest(for turn: ChatTurn) -> String {
        ToolFoldAdapter.foldDigest(turn: turn, state: foldState(turn), expandedByDefault: foldsExpandedByDefault)
    }

    private func estimate(_ turn: ChatTurn) -> CGFloat {
        TurnHeightEstimator.estimate(turn, width: width,
                                     folds: FoldResolver(state: foldState(turn), expandedByDefault: foldsExpandedByDefault),
                                     shape: foldShape(for: turn))
    }

    /// The turn's Focus shape: cached for a completed turn, planned afresh for a streaming one
    /// or one whose roll-ins the pane holds back (a hold is transient).
    func foldShape(for turn: ChatTurn) -> FoldShape? {
        let held = foldState(turn).heldOrdinals
        guard turn.isComplete, held.isEmpty else { return FoldShape(turn, held: held) }
        let signature = FoldShape.signature(of: turn)
        if let cached = shapes[turn.id], cached.signature == signature { return cached.shape }
        let shape = FoldShape(turn)
        if shapes.count >= Self.shapesCapacity { shapes.removeAll(keepingCapacity: true) }
        shapes[turn.id] = (signature, shape)
        return shape
    }

    private func cacheKey(_ contentKey: String, _ digest: String) -> String {
        "\(contentKey)|\(digest)|\(width)"
    }

    private func highestPowerOfTwo(atMost n: Int) -> Int {
        guard n > 0 else { return 0 }
        var p = 1
        while p << 1 <= n { p <<= 1 }
        return p
    }
}
