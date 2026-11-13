// NostromoKit — FocusActivityModel.swift
//
// What the sidebar's quiet "something happened since you looked" mark says about one focus.
//
// The daemon counts real events per session (`SessionInfo.agentTurns`, `agentMessages`,
// `agentProblems`, named by an `activityEpoch`). The Mac keeps, per focus, the counters it saw the
// last time the operator LOOKED at the focus (`FocusSeenMarks`), and this pure model turns the two
// into one of four states. Nothing here reads a clock, the disk or a window: whether the operator
// is looking is an input (`isSeen`).

import Foundation

// MARK: - Wire helpers

/// The five activity fields of a session entry, decoded without ever failing: a missing key, a
/// `null`, a value of the wrong type or a negative counter is just `nil`.
struct FocusActivityWire {
    var turns: UInt64?
    var messages: UInt64?
    var problems: UInt64?
    var epoch: String?
    var lastProblem: ProblemKind?

    private enum Keys: String, CodingKey {
        case turns       = "agent_turns"
        case messages    = "agent_messages"
        case problems    = "agent_problems"
        case epoch       = "activity_epoch"
        case lastProblem = "last_problem"
    }

    init(decoding decoder: Decoder) {
        guard let c = try? decoder.container(keyedBy: Keys.self) else { return }
        turns       = (try? c.decodeIfPresent(UInt64.self, forKey: .turns)) ?? nil
        messages    = (try? c.decodeIfPresent(UInt64.self, forKey: .messages)) ?? nil
        problems    = (try? c.decodeIfPresent(UInt64.self, forKey: .problems)) ?? nil
        epoch       = (try? c.decodeIfPresent(String.self, forKey: .epoch)) ?? nil
        lastProblem = (try? c.decodeIfPresent(ProblemKind.self, forKey: .lastProblem)) ?? nil
    }
}

// MARK: - Counters

/// One reading of a session's activity counters.
public struct FocusActivityCounters: Equatable {
    public let epoch: String
    public let turns: UInt64
    public let messages: UInt64
    public let problems: UInt64
    public let lastProblem: ProblemKind?

    public init(epoch: String, turns: UInt64, messages: UInt64, problems: UInt64, lastProblem: ProblemKind? = nil) {
        self.epoch = epoch
        self.turns = turns
        self.messages = messages
        self.problems = problems
        self.lastProblem = lastProblem
    }

    /// The counters as one value, or `nil` when the daemon did not send all of them (an older
    /// daemon): "unknown" is never read as zero.
    static func make(epoch: String?, turns: UInt64?, messages: UInt64?, problems: UInt64?,
                     lastProblem: ProblemKind?) -> FocusActivityCounters? {
        guard let epoch, let turns, let messages, let problems else { return nil }
        return FocusActivityCounters(epoch: epoch, turns: turns, messages: messages, problems: problems,
                                     lastProblem: lastProblem)
    }
}

/// What the operator last saw of a focus.
public struct FocusSeenMarks: Equatable {
    public let epoch: String
    public let turns: UInt64
    public let messages: UInt64
    public let problems: UInt64

    public init(epoch: String, turns: UInt64, messages: UInt64, problems: UInt64) {
        self.epoch = epoch
        self.turns = turns
        self.messages = messages
        self.problems = problems
    }

    public init(_ counters: FocusActivityCounters) {
        self.init(epoch: counters.epoch, turns: counters.turns, messages: counters.messages,
                  problems: counters.problems)
    }
}

/// One entry of a `session_list_resp`, read for its activity only. Every other key is ignored, so
/// an entry with a state this client does not know still decodes.
public struct SessionActivityEntry: Decodable, Equatable {
    public let tag: String
    public let activity: FocusActivityCounters?

    public init(tag: String, activity: FocusActivityCounters?) {
        self.tag = tag
        self.activity = activity
    }

    private enum CodingKeys: String, CodingKey { case tag }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tag = try c.decode(String.self, forKey: .tag)
        let wire = FocusActivityWire(decoding: decoder)
        activity = FocusActivityCounters.make(epoch: wire.epoch, turns: wire.turns, messages: wire.messages,
                                              problems: wire.problems, lastProblem: wire.lastProblem)
    }
}

// MARK: - State

/// What a focus's mark says. Precedence when several apply: problem, then unread, then activity.
public enum FocusActivityState: Equatable {
    /// Nothing since the operator last looked.
    case none
    /// Turns happened, but no message and no problem: a hollow ring.
    case activity
    /// The agent wrote `count` messages: a filled dot.
    case unread(count: UInt64)
    /// Something went wrong (`nil`: the daemon did not say what): a filled dot with a warning mark.
    case problem(ProblemKind?)

    /// What VoiceOver adds to the row's label; `nil` when there is no mark.
    public var accessibilityPhrase: String? {
        switch self {
        case .none: return nil
        case .activity: return "activity since you last looked"
        case .unread(let count): return count == 1 ? "unread response" : "\(count) unread responses"
        case .problem(let kind): return "problem: \((kind ?? .unknown).summary)"
        }
    }

    /// The hover text of the mark; `nil` when there is no mark.
    public var toolTip: String? {
        switch self {
        case .none: return nil
        case .activity: return "Activity since you last looked"
        case .unread(let count): return count == 1 ? "1 new message" : "\(count) new messages"
        case .problem(let kind): return "Problem: \((kind ?? .unknown).summary)"
        }
    }
}

// MARK: - Model

public enum FocusActivityModel {
    public struct Result: Equatable {
        public let state: FocusActivityState
        /// What to remember as seen: `nil` only when nothing was ever saved and nothing can be.
        public let saved: FocusSeenMarks?
    }

    /// The state of one focus, and the marks to keep.
    ///
    /// * `current == nil` (the daemon did not send the fields): nothing shows, nothing is saved.
    /// * No saved marks, a different epoch, or a counter lower than the saved one (they only ever
    ///   go up within an epoch): the counters are taken as the baseline, silently. App launch, a
    ///   daemon restart and a session rebuild therefore never light up every focus.
    /// * `isSeen` (the operator is looking at the focus in a key window): the marks catch up, so
    ///   what arrives while he looks never flags.
    /// * Otherwise the difference decides: problems, else messages, else turns, else nothing.
    public static func evaluate(current: FocusActivityCounters?, saved: FocusSeenMarks?, isSeen: Bool) -> Result {
        guard let current else { return Result(state: .none, saved: saved) }
        let baseline = Result(state: .none, saved: FocusSeenMarks(current))
        guard let saved, saved.epoch == current.epoch else { return baseline }
        guard current.turns >= saved.turns, current.messages >= saved.messages,
              current.problems >= saved.problems else { return baseline }
        if isSeen { return baseline }

        let state: FocusActivityState
        if current.problems > saved.problems {
            state = .problem(current.lastProblem)
        } else if current.messages > saved.messages {
            state = .unread(count: current.messages - saved.messages)
        } else if current.turns > saved.turns {
            state = .activity
        } else {
            state = .none
        }
        return Result(state: state, saved: saved)
    }
}
