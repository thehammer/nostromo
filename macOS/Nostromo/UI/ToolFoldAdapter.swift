import Foundation
import NostromoKit

/// How a turn's tool groups resolve open or closed. In TF2: the operator's explicit choice,
/// else the default (collapsed, or expanded under `NOSTROMO_LOAD_FOLD_DEFAULT=expanded`).
struct FoldResolver: Equatable {
    /// `ToolGroup.key` → explicit choice.
    var groupStates: [String: Bool] = [:]
    var expandedByDefault = false

    init(groupStates: [String: Bool] = [:], expandedByDefault: Bool = false) {
        self.groupStates = groupStates
        self.expandedByDefault = expandedByDefault
    }

    init(state: TurnInteractionState, expandedByDefault: Bool = false) {
        self.init(groupStates: state.groupStates, expandedByDefault: expandedByDefault)
    }

    func isExpanded(_ group: ToolGroup) -> Bool {
        isExpanded(key: group.key)
    }

    func isExpanded(key: String) -> Bool {
        groupStates[key] ?? expandedByDefault
    }
}

/// What folding makes of a turn, without its text: the items, and for each group its key,
/// members and agent rows. Enough to estimate the turn at any width, and small enough to
/// cache, so a resize or a reset does not re-run the planner over every turn.
struct FoldShape: Equatable {
    enum Item: Equatable {
        case block(Int)
        case group(key: String, members: [Int], agentRows: Int)
    }

    let items: [Item]

    init(_ turn: ChatTurn) {
        items = ToolFoldAdapter.plan(turn).map { item in
            switch item {
            case .block(let i): return .block(i)
            case .group(let g): return .group(key: g.key, members: g.memberIndices, agentRows: g.subagentBlocks.count)
            }
        }
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
    /// Empty when the turn carries no explicit group choice and no expanded result.
    ///
    /// Built from the state alone (sorted, so dictionary order cannot change it): the
    /// resolver is "explicit choice, else the default", so the explicit choices and the
    /// default are everything that decides which groups and results are open.
    static func foldDigest(turn: ChatTurn, state: TurnInteractionState, expandedByDefault: Bool = false) -> String {
        guard !state.groupStates.isEmpty || !state.expandedBlocks.isEmpty || expandedByDefault else { return "" }
        var text = expandedByDefault ? "E" : "C"
        for key in state.groupStates.keys.sorted() {
            text += "|\(key)=\(state.groupStates[key]! ? 1 : 0)"
        }
        text += "|b" + state.expandedBlocks.sorted().map(String.init).joined(separator: ",")
        return fnv1a(text)
    }

    /// Rows a pane shows with folding (an item each; an expanded group adds its members) and
    /// the number of tool groups, for `TranscriptDiagnostics`.
    ///
    /// `shape` supplies a turn's (cached) fold shape; nil plans the turn afresh.
    static func rowCounts(turns: [ChatTurn], resolver: (ChatTurn) -> FoldResolver,
                          shape: ((ChatTurn) -> FoldShape?)? = nil) -> (rows: Int, groups: Int) {
        var rows = 0
        var groups = 0
        for turn in turns {
            guard hasToolBlocks(turn) else {
                rows += turn.blocks.count
                continue
            }
            let folds = resolver(turn)
            for item in (shape?(turn) ?? FoldShape(turn)).items {
                switch item {
                case .block:
                    rows += 1
                case .group(let key, let members, _):
                    groups += 1
                    rows += 1 + (folds.isExpanded(key: key) ? members.count : 0)
                }
            }
        }
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
