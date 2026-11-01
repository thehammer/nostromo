import Foundation
import NostromoKit

/// A pane's read-only window onto the persisted fold choices of its focus (`TranscriptFoldStore`,
/// namespace = the focus's session tag). Entries live in the store, which every window of the
/// focus shares; writing them is the pane's job (`ReplView`), so a toggle reaches the other
/// windows through the store's `changes`.
final class FoldChoices: Equatable {
    let tag: String
    let store: TranscriptFoldStore

    init(tag: String, store: TranscriptFoldStore) {
        self.tag = tag
        self.store = store
    }

    /// The operator's own choice for an activity row or tool group (`a:…` / `g:…`).
    func explicit(_ key: String) -> Bool? {
        guard let state = store.foldState(tag: tag, key: key), state.origin == .user else { return nil }
        return state.open
    }

    /// The stuck-turn rule opened this group.
    func isAuto(_ key: String) -> Bool {
        guard let state = store.foldState(tag: tag, key: key) else { return false }
        return state.origin == .auto && state.open
    }

    /// A result fold's explicit state (`r:…`).
    func result(_ key: String) -> Bool? {
        store.resultState(tag: tag, key: key)
    }

    static func == (a: FoldChoices, b: FoldChoices) -> Bool {
        a === b || (a.tag == b.tag && a.store === b.store)
    }
}

/// Durable keys of folds that are not tool groups or activity rows (contract §2.3).
enum FoldKey {
    /// A tool result's fold: `r:` + its `tool_use_id`. An Agent call's subagent-activity fold:
    /// `r:agent:` + the call's id (the call's own result has the same id). Without an id (an old
    /// daemon, a terminal delivery item): `r:<turn identity>#b<block index>`.
    static func result(block: TurnBlock?, index: Int, turnKey: String) -> String {
        switch block {
        case .toolResult(let data)? where data.toolUseId != nil:
            return "r:\(data.toolUseId!)"
        case .toolCall(let data)? where data.toolUseId != nil:
            return "r:agent:\(data.toolUseId!)"
        default:
            return "r:\(turnKey)#b\(index)"
        }
    }
}

/// How a turn's foldables resolve open or closed (FV contract §2.2, `FocusFoldResolver`), first
/// match wins:
/// 1. the operator's explicit choice;
/// 2. (tool groups only) the stuck-turn auto-open: a recorded auto entry, or the derived
///    `ToolGroup.isStuck`. Activity rows never auto-open;
/// 3. the mode: Focus closes, All activity opens.
///
/// The choices live in the focus's `TranscriptFoldStore` (`choices`). The dictionaries below only
/// mirror what the operator did in the view that holds this resolver since it was built, for
/// items the view rebuilds (a roll-in) and for a view with no store behind it; the pane records
/// the same toggles in the store. A resolver made afresh (`ReplView.foldResolver(for:)`) starts
/// with empty mirrors.
struct FoldResolver: Equatable {
    var mode: TranscriptViewMode = .focus
    /// The turn's identity (`ChatTurn.identityKey`): the fallback result keys use it.
    var turnKey: String = ""
    var choices: FoldChoices?
    /// `ToolGroup.key` → explicit choice made in this view.
    var groupStates: [String: Bool] = [:]
    /// Keys the stuck-turn rule opened in this view.
    var groupAuto: Set<String> = []
    /// `ActivitySegment.key` → explicit choice made in this view.
    var activityStates: [String: Bool] = [:]
    /// Block index → result fold state chosen in this view.
    var resultStates: [Int: Bool] = [:]

    /// Everything starts open: All activity.
    var expandedByDefault: Bool {
        get { mode == .allActivity }
        set { mode = newValue ? .allActivity : .focus }
    }

    init(mode: TranscriptViewMode, turnKey: String, choices: FoldChoices?) {
        self.mode = mode
        self.turnKey = turnKey
        self.choices = choices
    }

    init(groupStates: [String: Bool] = [:], groupAuto: Set<String> = [],
         activityStates: [String: Bool] = [:], expandedByDefault: Bool = false, turnKey: String = "") {
        self.groupStates = groupStates
        self.groupAuto = groupAuto
        self.activityStates = activityStates
        self.mode = expandedByDefault ? .allActivity : .focus
        self.turnKey = turnKey
    }

    // MARK: Explicit choices

    func explicitGroup(_ key: String) -> Bool? { groupStates[key] ?? choices?.explicit(key) }

    func isAuto(_ key: String) -> Bool { groupAuto.contains(key) || choices?.isAuto(key) == true }

    func explicitActivity(_ key: String) -> Bool? { activityStates[key] ?? choices?.explicit(key) }

    /// The operator's choice for the result fold (or subagent-activity fold) of `block`, the
    /// block at `index` of the turn. Nil: it follows the default (open when the call failed).
    func explicitResult(block: TurnBlock?, index: Int) -> Bool? {
        resultStates[index] ?? choices?.result(FoldKey.result(block: block, index: index, turnKey: turnKey))
    }

    // MARK: Resolution

    func isExpanded(_ group: ToolGroup) -> Bool {
        isExpanded(key: group.key, isStuck: group.isStuck)
    }

    func isExpanded(key: String, isStuck: Bool = false) -> Bool {
        FocusFoldResolver.isOpen(.toolGroup, mode: mode, explicit: explicitGroup(key),
                                 auto: isAuto(key), derivedStuck: isStuck)
    }

    /// Whether the activity row `key` (`ActivitySegment.key`) is open.
    func isActivityExpanded(key: String) -> Bool {
        FocusFoldResolver.isOpen(.activityRow, mode: mode, explicit: explicitActivity(key),
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
    /// Empty when the turn is in Focus with no explicit choice, no expanded result and no hold.
    ///
    /// Built from what decides what is open: the mode, the explicit choices for the turn's own
    /// groups, activity rows (found through `shape`, in its order; nil skips them) and result
    /// folds (through the blocks), the recorded auto-opens and the holds.
    static func foldDigest(turn: ChatTurn, shape: FoldShape?, folds: FoldResolver, held: Set<Int>) -> String {
        var text = ""
        var any = false
        func note(_ kind: String, _ key: String, _ state: Bool?) {
            guard let state else { return }
            any = true
            text += "|\(kind)\(key)=\(state ? 1 : 0)"
        }
        func visit(_ item: FoldShape.Item) {
            switch item {
            case .group(let group):
                note("g", group.key, folds.explicitGroup(group.key))
                if folds.isAuto(group.key) { any = true; text += "|a\(group.key)" }
            case .activity(let key, let members):
                note("A", key, folds.explicitActivity(key))
                members.forEach(visit)
            case .block, .message:
                break
            }
        }
        shape?.items.forEach(visit)
        for (index, block) in turn.blocks.enumerated() {
            switch block {
            case .toolResult, .toolCall: note("r", "\(index)", folds.explicitResult(block: block, index: index))
            default: break
            }
        }
        for item in turn.terminalOriginItems.indices {
            let index = TerminalDeliveryBlockKey.blockIndex(item: item)
            note("t", "\(index)", folds.explicitResult(block: nil, index: index))
        }
        if !held.isEmpty {
            any = true
            text += "|h" + held.sorted().map(String.init).joined(separator: ",")
        }
        guard any || folds.mode == .allActivity else { return "" }
        return fnv1a((folds.mode == .allActivity ? "E" : "C") + text)
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
