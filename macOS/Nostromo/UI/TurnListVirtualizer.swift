import CoreGraphics

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
    struct Anchor: Equatable {
        let key: String
        let index: Int
        let offsetWithinTurn: CGFloat
    }

    // MARK: - State

    private(set) var width: CGFloat = 0
    private(set) var count = 0

    private var keys:    [String]  = []
    private var heights: [CGFloat] = []
    private var isExact: [Bool]    = []
    /// Fenwick tree over `heights`, 1-based.
    private var tree: [CGFloat] = []
    /// Measured heights, keyed by `"\(contentKey)|\(width)"`.
    private var measured: [String: CGFloat] = [:]
    /// Index lookup for anchor re-resolution after a splice.
    private var indexByKey: [String: Int] = [:]

    /// Counts every Fenwick node touched, so tests can assert the complexity
    /// claim above rather than trusting a wall-clock measurement.
    private(set) var treeOperations = 0

    var documentHeight: CGFloat { prefixSum(through: count) }

    // MARK: - Population

    /// Replace all geometry. Used on `.cleared` and on the first layout.
    func reset(turns: [ChatTurn], width: CGFloat) {
        self.width = max(width, 1)
        keys    = turns.map { $0.contentKey }
        heights = turns.map { TurnHeightEstimator.estimate($0, width: self.width) }
        isExact = Array(repeating: false, count: turns.count)
        count   = turns.count
        adoptMeasuredHeights()
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
        heights.removeSubrange(floor...)
        isExact.removeSubrange(floor...)
        for turn in turns[floor...] {
            keys.append(turn.contentKey)
            heights.append(TurnHeightEstimator.estimate(turn, width: width))
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
        keys.append(key)
        let cached = measured["\(key)|\(width)"]
        let height = cached ?? TurnHeightEstimator.estimate(turn, width: width)
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
        indexByKey[key] = index

        // A measured height is only reusable for a *completed* turn. `contentKey`
        // is invariant while a text block grows in place, so a turn measured
        // while materialized and then scrolled away would keep being handed its
        // stale height and the document would stop growing.
        let cached = turn.isComplete ? measured["\(key)|\(width)"] : nil
        let height = cached ?? TurnHeightEstimator.estimate(turn, width: width)
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
            keys[i] = key
            if let m = measured["\(key)|\(width)"] {
                heights[i] = m
                isExact[i] = true
            } else {
                heights[i] = TurnHeightEstimator.estimate(turns[i], width: width)
                isExact[i] = false
            }
        }
        rebuildTree()
        reindex()
    }

    // MARK: - Heights

    /// Record the real measured height of a materialized turn.
    /// Returns the document-height delta the caller must absorb.
    @discardableResult
    func recordMeasured(_ height: CGFloat, at index: Int) -> CGFloat {
        guard index >= 0, index < count else { return 0 }
        measured["\(keys[index])|\(width)"] = height
        isExact[index] = true
        return setHeight(height, at: index)
    }

    func height(at index: Int) -> CGFloat {
        guard index >= 0, index < count else { return 0 }
        return heights[index]
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
            range = (range.upperBound - Self.maxMaterialized) ..< range.upperBound
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
    func captureAnchor(viewportTop: CGFloat) -> Anchor? {
        guard count > 0 else { return nil }
        let index = self.index(atY: viewportTop)
        return Anchor(key: keys[index],
                      index: index,
                      offsetWithinTurn: viewportTop - offset(of: index))
    }

    /// Where the viewport top has to move so `anchor` stays where it was.
    ///
    /// Re-resolves the anchor by content key first: a splice reindexes turns,
    /// and following the stale index would move the operator's reading position
    /// by however many turns the splice inserted.
    func restoredTop(for anchor: Anchor) -> CGFloat {
        let index = indexByKey[anchor.key] ?? min(anchor.index, max(0, count - 1))
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
    /// splice or reset does not throw away measurements that are still valid.
    private func adoptMeasuredHeights(from floor: Int = 0) {
        guard !measured.isEmpty else { return }
        for i in floor ..< count {
            if let m = measured["\(keys[i])|\(width)"] {
                heights[i] = m
                isExact[i] = true
            }
        }
    }

    private func highestPowerOfTwo(atMost n: Int) -> Int {
        guard n > 0 else { return 0 }
        var p = 1
        while p << 1 <= n { p <<= 1 }
        return p
    }
}
