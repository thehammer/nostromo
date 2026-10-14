import Foundation

// MARK: - FoldBlock

/// What separates two runs of tool calls without being folded itself.
public enum FoldBoundaryKind: String, Equatable, Sendable {
    case askQuestion
    case errorMessage
    case note
    case resultSummary
    case other
}

/// One tool call, as the fold rule sees it.
public struct FoldCall: Equatable, Sendable {
    public var name: String
    /// The CLI's `tool_use.id`. Nil from an older daemon.
    public var toolUseId: String?
    /// The Agent/Task call a subagent made this call under (`"?"` when unknown whose).
    public var parentId: String?
    /// The file a file tool works on. Nil when the daemon did not say.
    public var target: String?
    public var startedAt: Date?
    /// When the call finished quietly (an empty successful result folded into it), if that
    /// result carried a time.
    public var finishedAt: Date?
    /// The call finished quietly, with or without a time.
    public var finishedQuietly: Bool
    /// The one-line input the call row shows.
    public var inputSummary: String
    /// The complete input as the daemon sent it. Empty when the payload was dropped.
    public var inputFull: String

    public init(name: String, toolUseId: String? = nil, parentId: String? = nil, target: String? = nil,
                startedAt: Date? = nil, finishedAt: Date? = nil, finishedQuietly: Bool = false,
                inputSummary: String = "", inputFull: String = "") {
        self.name = name
        self.toolUseId = toolUseId
        self.parentId = parentId
        self.target = target
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.finishedQuietly = finishedQuietly || finishedAt != nil
        self.inputSummary = inputSummary
        self.inputFull = inputFull
    }
}

/// One tool result, as the fold rule sees it.
public struct FoldResult: Equatable, Sendable {
    public var toolUseId: String?
    public var parentId: String?
    public var isError: Bool
    /// When the result arrived. Nil when unknown.
    public var at: Date?

    public init(toolUseId: String? = nil, parentId: String? = nil, isError: Bool = false, at: Date? = nil) {
        self.toolUseId = toolUseId
        self.parentId = parentId
        self.isError = isError
        self.at = at
    }
}

/// The fold rule's input: one per turn block, built by a platform adapter.
public enum FoldBlock: Equatable, Sendable {
    /// Agent text. `nonEmpty` is false for whitespace-only text. `parentId` is set when a
    /// subagent said it.
    case prose(nonEmpty: Bool, parentId: String? = nil)
    case toolCall(FoldCall)
    case toolResult(FoldResult)
    /// A visible block that is never folded and ends a group.
    case boundary(FoldBoundaryKind)
    /// Anything the transcript does not display.
    case hidden
}

/// How a turn ended, as far as the fold rule cares.
public enum FoldOutcome: Equatable, Sendable {
    /// Still streaming.
    case open
    case completedOk
    /// The result chip reports an error.
    case completedError
    /// The operator pressed Stop.
    case interrupted
    /// The turn carries an error message block.
    case errored
}

// MARK: - From the daemon wire

extension FoldBlock {

    /// A daemon turn's blocks as fold input, for a client that renders the wire blocks as
    /// they come (iOS, and the benchmark tests). An empty successful result is the daemon's
    /// "this call finished quietly": it finishes its call (`finishedAt`) and maps to
    /// `.hidden`, so indices stay parallel to `blocks`.
    public static func blocks(from blocks: [DaemonTurnBlock]) -> [FoldBlock] {
        var out: [FoldBlock] = []
        out.reserveCapacity(blocks.count)
        var callIndex: [String: Int] = [:]
        for block in blocks {
            switch block {
            case .text(let text, let parentId):
                out.append(.prose(nonEmpty: text.contains { !$0.isWhitespace }, parentId: parentId))
            case .toolCall(let name, let summary, let full, let meta):
                if let id = meta.toolUseId { callIndex[id] = out.count }
                out.append(.toolCall(FoldCall(name: name, toolUseId: meta.toolUseId,
                                              parentId: meta.parentToolUseId, target: meta.target,
                                              startedAt: meta.ts, inputSummary: summary, inputFull: full)))
            case .toolResult(let content, let isError, let meta):
                if content.isEmpty && !isError {
                    if let id = meta.toolUseId, let i = callIndex[id], case .toolCall(var call) = out[i] {
                        call.finishedAt = meta.ts
                        call.finishedQuietly = true
                        out[i] = .toolCall(call)
                    }
                    out.append(.hidden)
                } else {
                    out.append(.toolResult(FoldResult(toolUseId: meta.toolUseId, parentId: meta.parentToolUseId,
                                                      isError: isError, at: meta.ts)))
                }
            case .resultSummary: out.append(.boundary(.resultSummary))
            case .errorMessage:  out.append(.boundary(.errorMessage))
            case .askQuestion:   out.append(.boundary(.askQuestion))
            case .note:          out.append(.boundary(.note))
            }
        }
        return out
    }
}

extension FoldOutcome {

    /// How a daemon turn ended: open until `isComplete`; then interrupted, an error result,
    /// an error message, or fine.
    public static func of(_ turn: DaemonTurn) -> FoldOutcome {
        guard turn.isComplete else { return .open }
        var errored = false
        for block in turn.blocks {
            switch block {
            case .resultSummary(_, _, let isError, let interrupted):
                if interrupted { return .interrupted }
                if isError { return .completedError }
            case .errorMessage:
                errored = true
            default:
                break
            }
        }
        return errored ? .errored : .completedOk
    }
}
