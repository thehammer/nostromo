import Foundation

/// Folds a turn's blocks into tool groups (PRD "What forms a group"), incrementally.
///
/// Feed it a turn's blocks in order, one at a time, then `turnEnded(outcome:)`. Each call
/// returns the ops that bring a consumer's item list up to date. `plan(blocks:outcome:turnKey:)`
/// is the batch answer; replaying every op gives the same items (the property test holds the
/// planner to that: a state change it forgets to emit shows up as a difference).
///
/// The rule:
/// - a group is a maximal run of top-level calls and their results inside one turn;
/// - non-empty prose and every boundary end a group; hidden blocks and whitespace-only prose
///   do not;
/// - a single call is a group of one;
/// - a block with a `parentId` (a subagent's) is never a top-level member and never ends a
///   group. It attaches to the Agent/Task call whose `toolUseId` is its `parentId`; `"?"` or
///   an unknown parent attaches to the most recent unfinished Agent/Task call of the open
///   group. With nowhere to attach, it is treated as a top-level block, as before folding.
///
/// The planner is per turn by construction: it is given one turn's blocks, so no group can
/// cross turns.
///
/// Cost: each `feed` is O(1) amortized. `.extend` hands out a copy of the group; a consumer
/// that keeps the previous copy makes the next append copy the group's arrays (O(group size)),
/// which for realistic groups (tens to hundreds of calls) is a few microseconds.
public struct ToolFoldPlanner {

    /// One rendered item of a turn.
    public enum Item: Equatable, Sendable {
        /// A block rendered as itself.
        case block(Int)
        case group(ToolGroup)
    }

    /// A change to the item list.
    public enum Op: Equatable, Sendable {
        /// Append a block item.
        case block(Int)
        /// Append a new group item.
        case group(ToolGroup)
        /// Replace the group item with this group's `id`.
        case extend(ToolGroup)
    }

    private enum Ref: Equatable {
        case block(Int)
        case group(Int)
    }

    /// Per-group bookkeeping the public `ToolGroup` does not carry.
    private struct Track {
        /// Per call slot: finished (by a result, `finishedAt`, or the turn ending).
        var finished: [Bool] = []
        /// Per call slot: a result was paired with it.
        var paired: [Bool] = []
        /// Per call slot: its end time is known.
        var endKnown: [Bool] = []
        /// Call slots of Agent/Task calls, in order.
        var agentSlots: [Int] = []
        /// Calls whose end time is not known (unfinished, or finished without a time).
        var unknownEnds = 0
        var latestEnd: Date?
        /// The turn was stopped while a call of this group had no result.
        var stopped = false
        /// Call slots before this one are all paired, for positional pairing.
        var pairHead = 0
    }

    private struct CallRef {
        let group: Int
        let slot: Int
    }

    private let turnKey: String
    private var fed = 0
    private var layout: [Ref] = []
    private var groups: [ToolGroup] = []
    private var tracks: [Track] = []
    /// The group still accepting members.
    private var openGroup: Int?
    private var outcome: FoldOutcome?
    /// Top-level calls so far, for the ordinal in a fallback key.
    private var topLevelCalls = 0
    /// `toolUseId` → the top-level call carrying it.
    private var callsById: [String: CallRef] = [:]
    /// Groups changed by the current `feed`, in first-change order.
    private var dirty: [Int] = []
    private var dirtySet: Set<Int> = []
    /// A group created by the current `feed`: it goes out as `.group`, not `.extend`.
    private var created: Int?

    /// - Parameter turnKey: the turn's durable identity, for keys of groups without ids.
    public init(turnKey: String) {
        self.turnKey = turnKey
    }

    /// Blocks fed so far; the next block's index.
    public var blockCount: Int { fed }

    // MARK: - Feeding

    /// Add the next block of the turn.
    public mutating func feed(_ block: FoldBlock) -> [Op] {
        let index = fed
        fed += 1
        if let parentId = block.parentId, let agent = attachTarget(for: parentId) {
            attach(index, to: agent)
            return drainOps(appended: nil)
        }

        var appended: Ref?
        switch block {
        case .hidden:
            break
        case .prose(let nonEmpty, _):
            // Whitespace inside a group is absorbed; outside one it renders as it always has.
            if nonEmpty || openGroup == nil { appended = appendBlock(index) }
        case .boundary:
            appended = appendBlock(index)
        case .toolCall(let call):
            appended = addCall(call, at: index)
        case .toolResult(let result):
            appended = addResult(result, at: index)
        }
        return drainOps(appended: appended)
    }

    /// The turn ended. Unfinished calls count as finished, except when the operator stopped
    /// the turn: then they stay unfinished and their group reads as stopped.
    public mutating func turnEnded(outcome: FoldOutcome) -> [Op] {
        guard self.outcome == nil, outcome != .open else { return [] }
        self.outcome = outcome
        openGroup = nil
        for id in groups.indices where groups[id].finishedCount < groups[id].callCount {
            if outcome == .interrupted {
                tracks[id].stopped = true
            } else {
                for slot in tracks[id].finished.indices where !tracks[id].finished[slot] {
                    tracks[id].finished[slot] = true
                    groups[id].finishedCount += 1
                }
            }
            markDirty(id)
        }
        if outcome == .completedError || outcome == .errored,
           let last = groups.indices.last, groups[last].failedCount > 0 {
            groups[last].isStuck = true
            markDirty(last)
        }
        for id in groups.indices { refresh(id) }
        return drainOps(appended: nil)
    }

    /// A call fed earlier finished quietly afterwards: its empty successful result was folded
    /// into it in place (`finishedAt`/`finishedQuietly`), so no block arrived to say so. The
    /// result is what feeding the call already finished would have given. Unknown or already
    /// finished calls change nothing.
    public mutating func callFinished(toolUseId: String, at: Date?) -> [Op] {
        guard let ref = callsById[toolUseId] else { return [] }
        let (g, s) = (ref.group, ref.slot)
        guard !tracks[g].finished[s] else { return [] }
        tracks[g].finished[s] = true
        groups[g].finishedCount += 1
        groups[g].calls[s].finishedQuietly = true
        groups[g].calls[s].finishedAt = at
        if let at {
            tracks[g].endKnown[s] = true
            tracks[g].unknownEnds -= 1
            tracks[g].latestEnd = max(tracks[g].latestEnd ?? at, at)
        }
        markDirty(g)
        refresh(g)
        return drainOps(appended: nil)
    }

    // MARK: - Reading

    /// The group with this id as it stands, or nil.
    public func group(id: Int) -> ToolGroup? {
        groups.indices.contains(id) ? groups[id] : nil
    }

    /// The items as they stand.
    public func items() -> [Item] {
        layout.map { ref in
            switch ref {
            case .block(let i): return .block(i)
            case .group(let id): return .group(groups[id])
            }
        }
    }

    /// Batch: the items of a turn of `blocks` that ended with `outcome` (`.open`: still open).
    public static func plan(blocks: [FoldBlock], outcome: FoldOutcome, turnKey: String) -> [Item] {
        var planner = ToolFoldPlanner(turnKey: turnKey)
        for block in blocks { _ = planner.feed(block) }
        _ = planner.turnEnded(outcome: outcome)
        return planner.items()
    }

    /// Apply ops to an item list, as a consumer would.
    public static func replay(_ ops: [Op], onto items: [Item] = []) -> [Item] {
        var items = items
        var position: [Int: Int] = [:]
        for (i, item) in items.enumerated() {
            if case .group(let g) = item { position[g.id] = i }
        }
        for op in ops {
            switch op {
            case .block(let i):
                items.append(.block(i))
            case .group(let g):
                position[g.id] = items.count
                items.append(.group(g))
            case .extend(let g):
                if let p = position[g.id] { items[p] = .group(g) }
            }
        }
        return items
    }

    // MARK: - Items

    /// A block rendered as itself. Ends the open group.
    private mutating func appendBlock(_ index: Int) -> Ref {
        let previousLast = layout.last
        openGroup = nil
        layout.append(.block(index))
        // The group that was last is no longer "the last thing in the turn".
        if case .group(let id)? = previousLast { refresh(id) }
        return .block(index)
    }

    private mutating func addCall(_ call: FoldCall, at index: Int) -> Ref? {
        var appended: Ref?
        let id: Int
        if let open = openGroup {
            id = open
        } else {
            id = startGroup(with: call)
            appended = .group(id)
        }
        let slot = groups[id].calls.count
        groups[id].calls.append(call)
        groups[id].callIndices.append(index)
        groups[id].memberIndices.append(index)
        topLevelCalls += 1

        let ref = CallRef(group: id, slot: slot)
        if let toolUseId = call.toolUseId { callsById[toolUseId] = ref }
        if Self.isAgent(call.name) { tracks[id].agentSlots.append(slot) }

        // A quiet call (its empty result folded into it) is finished already; its end is
        // known only if that result carried a time.
        let finished = call.finishedQuietly || call.finishedAt != nil
        tracks[id].finished.append(finished)
        tracks[id].paired.append(false)
        tracks[id].endKnown.append(call.finishedAt != nil)
        if finished { groups[id].finishedCount += 1 }
        if let end = call.finishedAt {
            tracks[id].latestEnd = max(tracks[id].latestEnd ?? end, end)
        } else {
            tracks[id].unknownEnds += 1
        }
        markDirty(id)
        refresh(id)
        return appended
    }

    /// Open a new group at the end of the layout, started by its first call.
    private mutating func startGroup(with call: FoldCall) -> Int {
        let id = groups.count
        let key = call.toolUseId.map { "g:\($0)" } ?? "g:\(turnKey)#c\(topLevelCalls)"
        var group = ToolGroup(id: id, key: key)
        group.startedAt = call.startedAt
        groups.append(group)
        tracks.append(Track())
        layout.append(.group(id))
        openGroup = id
        created = id
        return id
    }

    private mutating func addResult(_ result: FoldResult, at index: Int) -> Ref? {
        // A result goes with its call: by id when it has one; otherwise (an older daemon)
        // positionally, the n-th result to the n-th unpaired call of the open group.
        let call: CallRef?
        if let toolUseId = result.toolUseId, let known = callsById[toolUseId] {
            call = known
        } else if result.toolUseId == nil, let open = openGroup {
            call = nextUnpairedCall(in: open)
        } else {
            call = nil
        }
        guard let owner = call?.group ?? openGroup else {
            // Nothing to belong to (older blocks shed, say): rendered as itself.
            return appendBlock(index)
        }
        groups[owner].memberIndices.append(index)
        if result.isError { groups[owner].failedCount += 1 }
        markDirty(owner)
        if let call { pair(call, with: result) }
        refresh(owner)
        return nil
    }

    // MARK: - Calls

    private mutating func nextUnpairedCall(in group: Int) -> CallRef? {
        while tracks[group].pairHead < tracks[group].paired.count {
            let slot = tracks[group].pairHead
            if !tracks[group].paired[slot] { return CallRef(group: group, slot: slot) }
            tracks[group].pairHead += 1
        }
        return nil
    }

    private mutating func pair(_ call: CallRef, with result: FoldResult) {
        let (g, s) = (call.group, call.slot)
        guard !tracks[g].paired[s] else { return }
        tracks[g].paired[s] = true
        if !tracks[g].finished[s] {
            tracks[g].finished[s] = true
            groups[g].finishedCount += 1
        }
        if let at = result.at, !tracks[g].endKnown[s] {
            tracks[g].endKnown[s] = true
            tracks[g].unknownEnds -= 1
            tracks[g].latestEnd = max(tracks[g].latestEnd ?? at, at)
        }
        markDirty(g)
        refresh(g)
    }

    // MARK: - Subagents

    private static func isAgent(_ name: String) -> Bool { name == "Agent" || name == "Task" }

    /// The Agent/Task call a subagent block belongs to, or nil when it has nowhere to go.
    private func attachTarget(for parentId: String) -> CallRef? {
        if parentId != "?", let ref = callsById[parentId],
           Self.isAgent(groups[ref.group].calls[ref.slot].name) {
            return ref
        }
        guard let open = openGroup else { return nil }
        let track = tracks[open]
        guard let slot = track.agentSlots.last(where: { !track.finished[$0] })
        else { return nil }
        return CallRef(group: open, slot: slot)
    }

    private mutating func attach(_ index: Int, to agent: CallRef) {
        let callIndex = groups[agent.group].callIndices[agent.slot]
        groups[agent.group].subagentBlocks[callIndex, default: []].append(index)
        markDirty(agent.group)
    }

    // MARK: - Derived state

    /// Recompute the fields that depend on where the group sits and how the turn stands.
    private mutating func refresh(_ id: Int) {
        let track = tracks[id]
        let group = groups[id]
        let unfinished = group.callCount - group.finishedCount

        let state: ToolGroup.State
        var running: Int?
        if outcome != nil {
            state = track.stopped ? .stopped : .settled
        } else if unfinished > 0, layout.last == .group(id) {
            state = .running
            if let slot = track.finished.lastIndex(of: false) { running = group.callIndices[slot] }
        } else {
            state = .settled
        }
        let ended = track.unknownEnds == 0 ? track.latestEnd : nil

        guard state != group.state || running != group.runningCall || ended != group.endedAt else { return }
        groups[id].state = state
        groups[id].runningCall = running
        groups[id].endedAt = ended
        markDirty(id)
    }

    private mutating func markDirty(_ id: Int) {
        if dirtySet.insert(id).inserted { dirty.append(id) }
    }

    /// The ops for everything this feed changed: extends for groups that already existed,
    /// then the appended item.
    private mutating func drainOps(appended: Ref?) -> [Op] {
        var ops: [Op] = []
        for id in dirty where id != created { ops.append(.extend(groups[id])) }
        switch appended {
        case .block(let i)?: ops.append(.block(i))
        case .group(let id)?: ops.append(.group(groups[id]))
        case nil: break
        }
        dirty.removeAll(keepingCapacity: true)
        dirtySet.removeAll(keepingCapacity: true)
        created = nil
        return ops
    }
}

private extension FoldBlock {
    /// The Agent/Task call a subagent made this block under, when it is a subagent's.
    var parentId: String? {
        switch self {
        case .prose(_, let parentId): return parentId
        case .toolCall(let call):     return call.parentId
        case .toolResult(let result): return result.parentId
        case .boundary, .hidden:      return nil
        }
    }
}
