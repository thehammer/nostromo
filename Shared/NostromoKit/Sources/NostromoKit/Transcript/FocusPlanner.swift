import Foundation

// MARK: - Items

/// One agent message: a maximal run of non-empty top-level prose blocks (PRD "Conversation
/// versus activity").
public struct MessageRef: Equatable, Sendable {
    /// The message's 0-based position among the turn's messages. Durable: the same live, after
    /// a reload and in every window.
    public let ordinal: Int
    /// Block indices of the message's text blocks, plus the transparent blocks (hidden,
    /// whitespace-only prose) that sit between them. Never a subagent's prose: attached, it
    /// renders inside its call; unattached, it is a boundary.
    public internal(set) var blockIndices: [Int]

    public init(ordinal: Int, blockIndices: [Int]) {
        self.ordinal = ordinal
        self.blockIndices = blockIndices
    }
}

/// One thing inside an activity row.
public enum ActivityMember: Equatable, Sendable {
    case message(MessageRef)
    case group(ToolGroup)
}

/// A run of activity between two conversation items: the folded messages and the TF2 groups,
/// in original order.
public struct ActivitySegment: Equatable, Sendable {
    /// Fold-state key (contract §2.3): `a:` + the first member's durable id. `a:m:<turnKey>#<ordinal>`
    /// when the segment starts with a message, `a:` + the group's key (`a:g:<toolu>`) when it
    /// starts with a group.
    public let key: String
    /// In original order. Never empty.
    public internal(set) var members: [ActivityMember]
    /// The turn is open and this is the turn's last activity item.
    public internal(set) var isLive: Bool

    public init(key: String, members: [ActivityMember], isLive: Bool = false) {
        self.key = key
        self.members = members
        self.isLive = isLive
    }

    /// The folded messages.
    public var messageCount: Int {
        members.reduce(0) { count, member in
            if case .message = member { return count + 1 } else { return count }
        }
    }

    /// Every top-level call across the segment's groups, in order.
    public var calls: [FoldCall] { groups.flatMap(\.calls) }

    /// The sum of the groups' top-level failures (subagent failures excluded, as in TF2).
    public var failedCount: Int { groups.reduce(0) { $0 + $1.failedCount } }

    /// The first group's `startedAt` (X1: tool work only; nil when unknown).
    public var startedAt: Date? { groups.first?.startedAt }

    /// The latest `endedAt` among the groups that know theirs (X1; nil when none does).
    public var endedAt: Date? { groups.compactMap(\.endedAt).max() }

    /// A group in the segment is TF3's stuck group.
    public var containsStuckGroup: Bool { groups.contains { $0.isStuck } }

    private var groups: [ToolGroup] {
        members.compactMap { if case .group(let group) = $0 { return group } else { return nil } }
    }
}

/// One rendered item of a turn in the Focus layout.
public enum FocusItem: Equatable, Sendable {
    /// Activity folded into one row.
    case activity(ActivitySegment)
    /// The turn's latest message (conversation).
    case message(MessageRef)
    /// A block that is never folded and splits activity: ask card, error, note, result chip,
    /// other, and any block TF2 renders as itself that is not a message (an orphaned result).
    case boundary(Int)
    /// A TF2 group that sits after the latest message (or any group while the turn has no
    /// message yet). Rendered exactly as TF2/TF3 do.
    case group(ToolGroup)
}

/// A change to the item list.
public enum FocusOp: Equatable, Sendable {
    /// Append an item.
    case item(FocusItem)
    /// Replace `items[from...]` with `items`. Emitted when a new message rolls the previous
    /// latest message and the trailing groups into activity. `items` never contains the new
    /// latest message: `.latestChanged` follows and appends it.
    case rollIn(from: Int, items: [FocusItem])
    /// The latest message is this one: replace the last `.message` item when it has the same
    /// ordinal (a message that grew), else append it.
    case latestChanged(MessageRef)
    /// Replace the `.activity` item with this segment's key.
    case segmentChanged(ActivitySegment)
    /// A forwarded TF2 `.extend`: replace the group with this group's `id`, wherever it
    /// sits (a trailing `.group` item or a member of a segment).
    case groupChanged(ToolGroup)
}

// MARK: - Planner

/// Plans a turn in the Focus layout (PRD "How a turn is laid out"), incrementally. Owns a
/// `ToolFoldPlanner`, so groups are computed once.
///
/// The rule (contract §2.1):
/// - a message is a maximal run of non-empty top-level prose with no top-level call, result
///   or boundary between; hidden blocks, whitespace-only prose and subagent prose attached to
///   a call do not split it;
/// - a subagent's non-empty prose that TF2 cannot attach to a call is a boundary, like an
///   unattachable subagent result: it splits a message and is never folded, so it is never
///   lost;
/// - the latest message, every boundary and the trailing groups after the latest message are
///   conversation-level items; every other message and every group before the latest message
///   is activity, folded into one segment per run between two boundaries.
///
/// Feed a turn's blocks in order, then `turnEnded(outcome:)`. Each call returns the ops that
/// bring a consumer's item list up to date; `replay` applies them. `plan(blocks:outcome:turnKey:)`
/// derives the same items from scratch, which is what the property test holds the ops to.
///
/// Cost: a block is O(1) amortized, excluding the forwarded group work. A roll-in rebuilds the
/// range it absorbs (the latest message, the trailing groups and the boundaries between them)
/// and extends the adjacent segment in place: it takes the segment out of `shown` first, so
/// the append does not copy the segment's members, and it rehomes only the new members.
public struct FocusPlanner {

    /// Counts the elements the planner visits while folding, rehoming and holding, so a test can
    /// bound the work without a clock. A class so the non-mutating readers can count too.
    final class WorkMeter {
        var visits = 0
    }

    /// What the turn is made of, in order, before it is laid out.
    private enum Atom: Equatable {
        /// A message, by ordinal.
        case message(Int)
        /// A TF2 group, by id.
        case group(Int)
        /// A block that is never folded, by block index.
        case boundary(Int)
    }

    /// Where a group sits in `shown`.
    private enum GroupHome {
        case item(Int)
        case member(item: Int, slot: Int)
    }

    private let turnKey: String
    private var folds: ToolFoldPlanner
    private var atoms: [Atom] = []
    private var messages: [MessageRef] = []
    /// Transparent blocks seen since the open message's last text block.
    private var pending: [Int] = []
    /// Nothing has split the latest message since it was last extended.
    private var messageOpen = false
    private var turnOpen = true
    /// Index in `atoms` of the latest message.
    private var latestAtom: Int?

    /// The item list a consumer holds after applying every op so far. It exists to place ops
    /// (positions, the segment a group moved into); `items()` derives the plan from the atoms.
    private var shown: [FocusItem] = []
    private var latestItem: Int?
    private var lastActivityItem: Int?
    private var groupHome: [Int: GroupHome] = [:]

    /// Test instrumentation (see `WorkMeter`). Copies of a planner share it.
    let meter = WorkMeter()

    /// - Parameter turnKey: the turn's durable identity, for the keys of segments that start
    ///   with a message and of groups without ids.
    public init(turnKey: String) {
        self.turnKey = turnKey
        folds = ToolFoldPlanner(turnKey: turnKey)
    }

    /// Blocks fed so far; the next block's index.
    public var blockCount: Int { folds.blockCount }

    // MARK: Feeding

    /// Add the next block of the turn.
    public mutating func feed(_ block: FoldBlock) -> [FocusOp] {
        let index = folds.blockCount
        let foldOps = folds.feed(block)
        var ops = forward(foldOps)

        switch block {
        case .hidden:
            noteTransparent(index)
        case .prose(let nonEmpty, let parentId):
            if parentId == nil {
                // Whitespace is not a message and does not split one.
                if nonEmpty { ops += addText(index) } else { noteTransparent(index) }
            } else if foldOps.contains(.block(index)) {
                // A subagent's prose TF2 could not attach. Whitespace has nothing to lose;
                // text is a boundary (as an unattachable subagent result is), so it stays
                // visible. Attached subagent blocks render inside their call.
                if nonEmpty {
                    closeMessage()
                    ops.append(addBoundary(index))
                } else {
                    noteTransparent(index)
                }
            }
        case .boundary:
            closeMessage()
            ops.append(addBoundary(index))
        case .toolCall, .toolResult:
            if let group = Self.startedGroup(in: foldOps) {
                closeMessage()
                ops.append(addGroup(group))
            } else if foldOps.contains(.block(index)) {
                closeMessage()
                ops.append(addBoundary(index))
            } else if block.subagentParent == nil {
                closeMessage()
            }
        }
        return ops
    }

    /// The turn ended (forwarded to TF2). Clears `isLive` on the last segment.
    public mutating func turnEnded(outcome: FoldOutcome) -> [FocusOp] {
        var ops = forward(folds.turnEnded(outcome: outcome))
        guard turnOpen, outcome != .open else { return ops }
        turnOpen = false
        closeMessage()
        if let last = lastActivityItem, let op = endLive(at: last) { ops.append(op) }
        return ops
    }

    /// A call finished quietly after it was fed (forwarded to TF2's `callFinished`).
    public mutating func callFinished(toolUseId: String, at: Date?) -> [FocusOp] {
        forward(folds.callFinished(toolUseId: toolUseId, at: at))
    }

    // MARK: Reading

    /// The items as they stand, derived from the atoms.
    public func items() -> [FocusItem] {
        var items: [FocusItem] = []
        var trailing = atoms[...]
        if let latest = atoms.lastIndex(where: { if case .message = $0 { return true } else { return false } }),
           case .message(let ordinal) = atoms[latest] {
            var noSeed: ActivitySegment?
            items = fold(atoms[..<latest], seed: &noSeed)
            items.append(.message(messages[ordinal]))
            trailing = atoms[(latest + 1)...]
        }
        for atom in trailing {
            switch atom {
            case .group(let id): items.append(.group(folds.group(id: id)!))
            case .boundary(let index): items.append(.boundary(index))
            case .message: break
            }
        }
        Self.markLive(&items, turnOpen: turnOpen)
        return items
    }

    /// The items with each held message presented as `.message` at its chronological place
    /// instead of inside its segment (contract §2.1 "Presentation hold"). A pure function of
    /// the plan.
    ///
    /// A segment with held messages is split at each of them. What comes before the first held
    /// message stays a segment under the same key; what comes after a held message is shown as
    /// TF2 `.group` items, or, if it contains a message that is not held, as a segment under
    /// the key of its own first member. Holding a message that has not rolled in does nothing.
    public func items(holding ordinals: Set<Int>) -> [FocusItem] {
        let plan = items()
        guard !ordinals.isEmpty else { return plan }
        var out: [FocusItem] = []
        for item in plan {
            guard case .activity(let segment) = item, segment.holds(ordinals) else {
                out.append(item)
                continue
            }
            meter.visits += 2 * segment.members.count
            var stretch: [ActivityMember] = []
            var isPrefix = true
            func flush() {
                defer { stretch = [] }
                guard let first = stretch.first else { return }
                if isPrefix {
                    out.append(.activity(ActivitySegment(key: segment.key, members: stretch, isLive: segment.isLive)))
                } else if stretch.allSatisfy({ if case .group = $0 { return true } else { return false } }) {
                    for case .group(let group) in stretch { out.append(.group(group)) }
                } else {
                    out.append(.activity(ActivitySegment(key: key(of: first), members: stretch)))
                }
            }
            for member in segment.members {
                if case .message(let message) = member, ordinals.contains(message.ordinal) {
                    flush()
                    isPrefix = false
                    out.append(.message(message))
                } else {
                    stretch.append(member)
                }
            }
            flush()
        }
        return out
    }

    /// Batch: the items of a turn of `blocks` that ended with `outcome` (`.open`: still open).
    public static func plan(blocks: [FoldBlock], outcome: FoldOutcome, turnKey: String) -> [FocusItem] {
        var planner = FocusPlanner(turnKey: turnKey)
        for block in blocks { _ = planner.feed(block) }
        _ = planner.turnEnded(outcome: outcome)
        return planner.items()
    }

    /// Apply ops to an item list, as a consumer would.
    public static func replay(_ ops: [FocusOp], onto items: [FocusItem] = []) -> [FocusItem] {
        var items = items
        for op in ops {
            switch op {
            case .item(let item):
                items.append(item)
            case .rollIn(let from, let rolled):
                items.replaceSubrange(from..., with: rolled)
            case .latestChanged(let message):
                if case .message(let current)? = items.last, current.ordinal == message.ordinal {
                    items[items.count - 1] = .message(message)
                } else {
                    items.append(.message(message))
                }
            case .segmentChanged(let segment):
                if let i = items.lastIndex(where: { $0.activityKey == segment.key }) {
                    items[i] = .activity(segment)
                }
            case .groupChanged(let group):
                replace(group, in: &items)
            }
        }
        return items
    }

    // MARK: - Messages and boundaries

    private mutating func noteTransparent(_ index: Int) {
        if messageOpen { pending.append(index) }
    }

    private mutating func closeMessage() {
        messageOpen = false
        pending = []
    }

    private mutating func addText(_ index: Int) -> [FocusOp] {
        guard messageOpen, var message = messages.last, let item = latestItem else {
            return startMessage(at: index)
        }
        message.blockIndices += pending
        message.blockIndices.append(index)
        pending = []
        messages[messages.count - 1] = message
        shown[item] = .message(message)
        return [.latestChanged(message)]
    }

    /// A new message begins: the previous latest message, and the groups after it, roll into
    /// activity. With no previous message the groups so far (none, or those before the first
    /// message) roll in the same way.
    private mutating func startMessage(at index: Int) -> [FocusOp] {
        var ops: [FocusOp] = []
        let message = MessageRef(ordinal: messages.count, blockIndices: [index])

        // The range that is rebuilt: `atoms[firstAtom...]` replaces `shown[from...]`.
        var firstAtom: Int?
        var from = 0
        var seed: ActivitySegment?
        if let atom = latestAtom, let item = latestItem {
            firstAtom = atom
            from = item
            if item > 0, let adjacent = takeSegment(at: item - 1) {
                // The segment just before the latest message takes it as its next member.
                seed = adjacent
                from = item - 1
            }
        } else if let atom = atoms.firstIndex(where: { if case .group = $0 { return true } else { return false } }),
                  let item = shown.firstIndex(where: { if case .group = $0 { return true } else { return false } }) {
            firstAtom = atom
            from = item
        }

        if let firstAtom {
            // An earlier segment stops being the last one.
            if let last = lastActivityItem, last < from, let op = endLive(at: last) { ops.append(op) }
            let seededMembers = seed?.members.count ?? 0
            var rolled = fold(atoms[firstAtom...], seed: &seed)
            Self.markLive(&rolled, turnOpen: turnOpen)
            shown.replaceSubrange(from..., with: rolled)
            for (offset, item) in rolled.enumerated() {
                // The seed's members are already homed in the same slots.
                rehome(item, at: from + offset, fromSlot: offset == 0 ? seededMembers : 0)
            }
            lastActivityItem = shown.lastIndex { $0.activityKey != nil }
            ops.append(.rollIn(from: from, items: rolled))
        }

        messages.append(message)
        atoms.append(.message(message.ordinal))
        latestAtom = atoms.count - 1
        shown.append(.message(message))
        latestItem = shown.count - 1
        messageOpen = true
        pending = []
        ops.append(.latestChanged(message))
        return ops
    }

    private mutating func addBoundary(_ index: Int) -> FocusOp {
        atoms.append(.boundary(index))
        shown.append(.boundary(index))
        return .item(.boundary(index))
    }

    private mutating func addGroup(_ group: ToolGroup) -> FocusOp {
        atoms.append(.group(group.id))
        shown.append(.group(group))
        groupHome[group.id] = .item(shown.count - 1)
        return .item(.group(group))
    }

    // MARK: - Groups

    /// The TF2 `.extend`s as `.groupChanged` ops, applied to `shown`.
    private mutating func forward(_ foldOps: [ToolFoldPlanner.Op]) -> [FocusOp] {
        var ops: [FocusOp] = []
        for case .extend(let group) in foldOps {
            switch groupHome[group.id] {
            case .item(let item)?:
                shown[item] = .group(group)
            case .member(let item, let slot)?:
                if case .activity = shown[item] {
                    _ = updateSegment(at: item) { $0.members[slot] = .group(group) }
                }
            case nil:
                break
            }
            ops.append(.groupChanged(group))
        }
        return ops
    }

    private static func startedGroup(in foldOps: [ToolFoldPlanner.Op]) -> ToolGroup? {
        for case .group(let group) in foldOps { return group }
        return nil
    }

    /// `fromSlot`: the segment's members before it are already homed.
    private mutating func rehome(_ item: FocusItem, at position: Int, fromSlot: Int = 0) {
        switch item {
        case .group(let group):
            groupHome[group.id] = .item(position)
        case .activity(let segment):
            meter.visits += segment.members.count - fromSlot
            for slot in fromSlot ..< segment.members.count {
                if case .group(let group) = segment.members[slot] { groupHome[group.id] = .member(item: position, slot: slot) }
            }
        case .message, .boundary:
            break
        }
    }

    // MARK: - Segments in `shown`

    /// Moves the segment out of `shown[index]`, leaving a placeholder, so the caller holds the
    /// only reference to its members and can append in place. The caller puts it back.
    private mutating func takeSegment(at index: Int) -> ActivitySegment? {
        guard case .activity(let segment) = shown[index] else { return nil }
        shown[index] = .boundary(-1)
        return segment
    }

    /// Clears `isLive` on the segment at `index`; nil if it was not live.
    private mutating func endLive(at index: Int) -> FocusOp? {
        guard case .activity(let segment) = shown[index], segment.isLive else { return nil }
        return .segmentChanged(updateSegment(at: index) { $0.isLive = false })
    }

    /// Changes the segment in `shown[index]` without copying its members.
    private mutating func updateSegment(at index: Int, _ change: (inout ActivitySegment) -> Void) -> ActivitySegment {
        guard var segment = takeSegment(at: index) else { preconditionFailure("not a segment") }
        change(&segment)
        shown[index] = .activity(segment)
        return segment
    }

    // MARK: - Folding atoms into items

    /// `atoms` as items: messages and groups fold into segments, split at boundaries. `seed`
    /// is a segment the first run continues; it is moved into the result, not copied, so the
    /// caller must not hold another reference to its members.
    private func fold(_ atoms: ArraySlice<Atom>, seed: inout ActivitySegment?) -> [FocusItem] {
        var items: [FocusItem] = []
        var current: ActivitySegment?
        swap(&current, &seed)
        func add(_ member: ActivityMember) {
            if current == nil {
                current = ActivitySegment(key: key(of: member), members: [member])
            } else {
                current?.members.append(member)
            }
        }
        for atom in atoms {
            meter.visits += 1
            switch atom {
            case .message(let ordinal):
                add(.message(messages[ordinal]))
            case .group(let id):
                add(.group(folds.group(id: id)!))
            case .boundary(let index):
                if let segment = current { items.append(.activity(segment)) }
                current = nil
                items.append(.boundary(index))
            }
        }
        if let segment = current { items.append(.activity(segment)) }
        return items
    }

    private func key(of member: ActivityMember) -> String {
        switch member {
        case .message(let message): return "a:m:\(turnKey)#\(message.ordinal)"
        case .group(let group): return "a:\(group.key)"
        }
    }

    /// Only the last segment is live, and only while the turn is open.
    private static func markLive(_ items: inout [FocusItem], turnOpen: Bool) {
        let last = items.lastIndex { $0.activityKey != nil }
        for (i, item) in items.enumerated() {
            if case .activity(var segment) = item, segment.isLive != (turnOpen && i == last) {
                segment.isLive = turnOpen && i == last
                items[i] = .activity(segment)
            }
        }
    }

    private static func replace(_ group: ToolGroup, in items: inout [FocusItem]) {
        for i in items.indices.reversed() {
            switch items[i] {
            case .group(let held) where held.id == group.id:
                items[i] = .group(group)
                return
            case .activity(var segment):
                let slot = segment.members.firstIndex {
                    if case .group(let held) = $0 { return held.id == group.id } else { return false }
                }
                if let slot {
                    segment.members[slot] = .group(group)
                    items[i] = .activity(segment)
                    return
                }
            default:
                break
            }
        }
    }
}

private extension FocusItem {
    var activityKey: String? {
        if case .activity(let segment) = self { return segment.key } else { return nil }
    }
}

private extension ActivitySegment {
    func holds(_ ordinals: Set<Int>) -> Bool {
        members.contains { if case .message(let m) = $0 { return ordinals.contains(m.ordinal) } else { return false } }
    }
}

private extension FoldBlock {
    /// The Agent/Task call a subagent made this block under, when it is a subagent's.
    var subagentParent: String? {
        switch self {
        case .prose(_, let parentId): return parentId
        case .toolCall(let call):     return call.parentId
        case .toolResult(let result): return result.parentId
        case .boundary, .hidden:      return nil
        }
    }
}

