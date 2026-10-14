import Foundation
import NostromoKit

/// How a turn's foldables resolve open or closed (FV contract §2.2, `FocusFoldResolver`), first
/// match wins:
/// 1. the operator's explicit choice;
/// 2. (tool groups only) the stuck-turn auto-open: a recorded auto entry, or the derived
///    `ToolGroup.isStuck`. Activity rows never auto-open;
/// 3. the mode: Focus closes, All activity opens (`NOSTROMO_LOAD_FOLD_DEFAULT=expanded` in the
///    load harness). Every pane is in Focus until FV4 adds the toggle.
struct FoldResolver: Equatable {
    /// `ToolGroup.key` → explicit choice.
    var groupStates: [String: Bool] = [:]
    /// Keys the stuck-turn rule opened.
    var groupAuto: Set<String> = []
    /// `ActivitySegment.key` → explicit choice.
    var activityStates: [String: Bool] = [:]
    var mode: TranscriptViewMode = .focus

    /// Everything starts open: All activity (the harness's "Show All").
    var expandedByDefault: Bool {
        get { mode == .allActivity }
        set { mode = newValue ? .allActivity : .focus }
    }

    init(groupStates: [String: Bool] = [:], groupAuto: Set<String> = [],
         activityStates: [String: Bool] = [:], expandedByDefault: Bool = false) {
        self.groupStates = groupStates
        self.groupAuto = groupAuto
        self.activityStates = activityStates
        self.mode = expandedByDefault ? .allActivity : .focus
    }

    init(state: TurnInteractionState, expandedByDefault: Bool = false) {
        self.init(groupStates: state.groupStates, groupAuto: state.groupAuto,
                  activityStates: state.activityStates, expandedByDefault: expandedByDefault)
    }

    func isExpanded(_ group: ToolGroup) -> Bool {
        isExpanded(key: group.key, isStuck: group.isStuck)
    }

    func isExpanded(key: String, isStuck: Bool = false) -> Bool {
        FocusFoldResolver.isOpen(.toolGroup, mode: mode, explicit: groupStates[key],
                                 auto: groupAuto.contains(key), derivedStuck: isStuck)
    }

    /// Whether the activity row `key` (`ActivitySegment.key`) is open.
    func isActivityExpanded(key: String) -> Bool {
        FocusFoldResolver.isOpen(.activityRow, mode: mode, explicit: activityStates[key],
                                 auto: nil, derivedStuck: false)
    }
}

/// What the Focus view makes of a turn, without its text: the items, and for each group and
/// activity row its key and members. Enough to estimate the turn at any width, and small
/// enough to cache, so a resize or a reset does not re-run the planner over every turn.
struct FoldShape: Equatable {
    struct Group: Equatable {
        let key: String
        let members: [Int]
        let agentRows: Int
        let isStuck: Bool
    }

    enum Item: Equatable {
        /// A block rendered as itself: a boundary (chip, card, error, note, orphan).
        case block(Int)
        /// The latest message: one text block view per block index.
        case message([Int])
        case group(Group)
        /// An activity row; when expanded its lane shows `memberShapes` (`.message` with the
        /// message's non-empty text blocks, `.group`).
        case activity(key: String, memberShapes: [Item])
    }

    let items: [Item]

    /// `held`: messages whose roll-in the pane holds back (`FocusPlanner.items(holding:)`).
    init(_ turn: ChatTurn, held: Set<Int> = []) {
        var planner = FocusPlanner(turnKey: turn.identityKey)
        for block in ToolFoldAdapter.foldBlocks(of: turn) { _ = planner.feed(block) }
        _ = planner.turnEnded(outcome: ToolFoldAdapter.outcome(of: turn))
        items = planner.items(holding: held).map { Self.item($0, turn: turn) }
    }

    private static func item(_ item: FocusItem, turn: ChatTurn) -> Item {
        switch item {
        case .boundary(let i):  return .block(i)
        case .message(let m):   return .message(m.blockIndices)
        case .group(let g):     return .group(group(g))
        case .activity(let segment):
            return .activity(key: segment.key, memberShapes: segment.members.map { member in
                switch member {
                case .group(let g):
                    return .group(group(g))
                case .message(let m):
                    // The lane shows a folded message's visible text only (`ActivityRowView`).
                    return .message(m.blockIndices.filter { i in
                        turn.blocks.indices.contains(i) && ActivityRowView.showsInLane(turn.blocks[i])
                    })
                }
            })
        }
    }

    private static func group(_ g: ToolGroup) -> Group {
        Group(key: g.key, members: g.memberIndices, agentRows: g.subagentBlocks.count, isStuck: g.isStuck)
    }

    /// Whether a cached shape still describes `turn`: same block kinds, same subagent prose.
    /// Only a completed turn's shape is cached; a streaming one changes in place.
    static func signature(of turn: ChatTurn) -> String {
        "\(turn.identityKey)|\(turn.subagentTextParents.count)|" + turn.blocks.map(\.kindCode).joined()
    }
}

/// The Mac's side of the fold rule: `TurnBlock` → `FoldBlock`, `ChatTurn` → `FoldOutcome`.
enum ToolFoldAdapter {

    /// One block as fold input. An exhaustive switch with no `default`: a new `TurnBlock`
    /// case does not compile until it is classified.
    static func foldBlock(_ block: TurnBlock, at index: Int, in turn: ChatTurn) -> FoldBlock {
        foldBlock(block, parentId: turn.subagentTextParents[index])
    }

    /// `textParentId`: who said a `.text` block (`ChatTurn.subagentTextParents`).
    static func foldBlock(_ block: TurnBlock, parentId textParentId: String?) -> FoldBlock {
        switch block {
        case .text(let s):
            // Stops at the first visible character, so prose costs O(1) here.
            return .prose(nonEmpty: s.contains { !$0.isWhitespace }, parentId: textParentId)
        case .toolCall(let d):
            return .toolCall(FoldCall(name: d.toolName, toolUseId: d.toolUseId, parentId: d.parentToolUseId,
                                      target: d.target, startedAt: d.startedAt, finishedAt: d.finishedAt,
                                      finishedQuietly: d.finishedQuietly,
                                      inputSummary: d.inputSummary, inputFull: d.inputFull))
        case .toolResult(let d):
            return .toolResult(FoldResult(toolUseId: d.toolUseId, parentId: d.parentToolUseId,
                                          isError: d.isError, at: d.at))
        case .resultSummary: return .boundary(.resultSummary)
        case .errorMessage:  return .boundary(.errorMessage)
        case .askQuestion:   return .boundary(.askQuestion)
        case .note:          return .boundary(.note)
        }
    }

    static func foldBlocks(of turn: ChatTurn) -> [FoldBlock] {
        turn.blocks.enumerated().map { foldBlock($1, at: $0, in: turn) }
    }

    /// Open until the turn completes; then interrupted, an error chip, an error message, or ok.
    static func outcome(of turn: ChatTurn) -> FoldOutcome {
        guard turn.isComplete else { return .open }
        var errored = false
        for block in turn.blocks {
            switch block {
            case .resultSummary(let d):
                if d.interrupted { return .interrupted }
                if d.isError { return .completedError }
            case .errorMessage:
                errored = true
            default:
                break
            }
        }
        return errored ? .errored : .completedOk
    }

    /// The turn's items, batch.
    static func plan(_ turn: ChatTurn) -> [ToolFoldPlanner.Item] {
        ToolFoldPlanner.plan(blocks: foldBlocks(of: turn), outcome: outcome(of: turn), turnKey: turn.identityKey)
    }

    /// Whether any block of `turn` is a tool call or result, i.e. whether folding can change it.
    static func hasToolBlocks(_ turn: ChatTurn) -> Bool {
        turn.blocks.contains { block in
            switch block {
            case .toolCall, .toolResult: return true
            default: return false
            }
        }
    }

    /// Stable digest of the fold state a turn renders with, for the height-cache key.
    /// Empty when the turn carries no explicit choice, no expanded result and no hold.
    ///
    /// Built from the state alone (sorted, so dictionary order cannot change it): the
    /// resolver is "explicit choice, else the default", so the explicit choices, the holds and
    /// the default are everything that decides what is open.
    static func foldDigest(turn: ChatTurn, state: TurnInteractionState, expandedByDefault: Bool = false) -> String {
        guard !state.groupStates.isEmpty || !state.expandedBlocks.isEmpty || !state.groupAuto.isEmpty
                || !state.activityStates.isEmpty || !state.heldOrdinals.isEmpty
                || expandedByDefault else { return "" }
        var text = expandedByDefault ? "E" : "C"
        for key in state.groupStates.keys.sorted() {
            text += "|\(key)=\(state.groupStates[key]! ? 1 : 0)"
        }
        if !state.groupAuto.isEmpty { text += "|a" + state.groupAuto.sorted().joined(separator: ",") }
        text += "|b" + state.expandedBlocks.sorted().map(String.init).joined(separator: ",")
        if !state.activityStates.isEmpty {
            text += "|A" + state.activityStates.keys.sorted()
                .map { "\($0)=\(state.activityStates[$0]! ? 1 : 0)" }.joined(separator: ",")
        }
        if !state.heldOrdinals.isEmpty {
            text += "|h" + state.heldOrdinals.sorted().map(String.init).joined(separator: ",")
        }
        return fnv1a(text)
    }

    /// Rows a pane shows in the Focus view, and its tool groups (every group, also those
    /// folded into activity rows), for `TranscriptDiagnostics`. See `focusRowCount`.
    ///
    /// `shape` supplies a turn's (cached) fold shape; nil plans the turn afresh.
    static func rowCounts(turns: [ChatTurn], resolver: (ChatTurn) -> FoldResolver,
                          shape: ((ChatTurn) -> FoldShape?)? = nil) -> (rows: Int, groups: Int) {
        var rows = 0
        var groups = 0
        for turn in turns {
            let counts = focusRows(shape?(turn) ?? FoldShape(turn), resolver: resolver(turn))
            rows += counts.rows
            groups += counts.groups
        }
        return (rows, groups)
    }

    /// Rows `turn` shows in the Focus view: a boundary 1; the latest message 1 per text block; a
    /// group 1, plus its members when open; an activity row 1, plus, when open, its lane (1 per
    /// folded text block, and each group as above).
    static func focusRowCount(of turn: ChatTurn, resolver: FoldResolver) -> Int {
        focusRows(FoldShape(turn), resolver: resolver).rows
    }

    /// Rows `turn` showed under TF2's tool folds alone (every planner item one row, an open
    /// group adds its members): the baseline the Focus view is measured against.
    static func toolFoldRowCount(of turn: ChatTurn, resolver: FoldResolver) -> Int {
        guard hasToolBlocks(turn) else { return turn.blocks.count }
        return plan(turn).reduce(0) { rows, item in
            switch item {
            case .block: return rows + 1
            case .group(let g): return rows + 1 + (resolver.isExpanded(g) ? g.memberIndices.count : 0)
            }
        }
    }

    private static func focusRows(_ shape: FoldShape, resolver: FoldResolver) -> (rows: Int, groups: Int) {
        var rows = 0
        var groups = 0
        func count(_ item: FoldShape.Item) {
            switch item {
            case .block:
                rows += 1
            case .message(let indices):
                rows += indices.count
            case .group(let g):
                groups += 1
                rows += 1 + (resolver.isExpanded(key: g.key, isStuck: g.isStuck) ? g.members.count : 0)
            case .activity(let key, let members):
                rows += 1
                if resolver.isActivityExpanded(key: key) {
                    members.forEach(count)
                } else {
                    groups += members.reduce(0) { if case .group = $1 { return $0 + 1 } else { return $0 } }
                }
            }
        }
        shape.items.forEach(count)
        return (rows, groups)
    }

    /// 64-bit FNV-1a, hex. Short and stable across launches (unlike `Hasher`).
    private static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}
