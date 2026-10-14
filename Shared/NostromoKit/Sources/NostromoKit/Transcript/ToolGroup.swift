import Foundation

/// One run of top-level tool calls (and their results) inside one turn.
public struct ToolGroup: Equatable, Sendable {

    public enum State: Equatable, Sendable {
        /// The turn is open, this group is the last thing in it, and a call has no result yet.
        case running
        case settled
        /// The operator stopped the turn while a call in this group had no result.
        case stopped
    }

    /// The group's ordinal in its turn (0, 1, …). Identifies it within the planner's ops.
    public let id: Int
    /// Fold-state key (contract §2.4): `g:` + the first call's `toolUseId`, else
    /// `g:` + turn key + `#c` + the first call's ordinal among the turn's top-level calls.
    public let key: String
    /// Block indices of the top-level calls and results, in block order.
    public internal(set) var memberIndices: [Int] = []
    /// Block indices of the top-level calls, in order. Parallel to `calls`.
    public internal(set) var callIndices: [Int] = []
    /// The top-level calls, in order.
    public internal(set) var calls: [FoldCall] = []
    /// Agent/Task call block index → the subagent blocks attached to it, in block order.
    public internal(set) var subagentBlocks: [Int: [Int]] = [:]
    /// Top-level error results among the members.
    public internal(set) var failedCount = 0
    /// Top-level calls that are finished.
    public internal(set) var finishedCount = 0
    /// Block index of the call running now: the last unfinished call, while `state == .running`.
    public internal(set) var runningCall: Int?
    /// When the first call started. Nil when unknown.
    public internal(set) var startedAt: Date?
    /// When the last call finished. Nil when any call's end is unknown, or a call is unfinished.
    public internal(set) var endedAt: Date?
    public internal(set) var state: State = .running
    /// The turn ended in error (not interrupted) and this is its last group, with a failure.
    public internal(set) var isStuck = false

    public init(id: Int, key: String) {
        self.id = id
        self.key = key
    }

    public var callCount: Int { calls.count }
}
