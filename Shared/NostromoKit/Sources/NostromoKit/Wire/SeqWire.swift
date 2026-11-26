// NostromoKit — SeqWire.swift
//
// Per-topic sequence numbers and `Gap` (W12, `docs/plans/backplane-sequencing.md`).
//
// A daemon that lists `"seq"` in `Welcome.features` numbers every frame that belongs to a topic
// (strictly increasing per topic, from 1, for the daemon's lifetime) and, when asked with
// `Subscribe.resume`, replays what a topic published after the number the client last saw, or says
// it cannot with a `Gap`. The number is a top-level `"seq"` key; `activity` frames already have a
// per-stream `seq` of their own, so their topic number is `"topic_seq"`. Frames with no topic
// (session frames, `hosts`, approvals, ...) carry none.
//
// `SeqTracker` is the client's side: what it last saw per topic, to send as `resume`.

import Foundation

/// Why the daemon sent a `Gap` (`GapReason` in `src/ipc/protocol.rs`).
public enum GapReason: Equatable, Sendable {
    /// The client resumed from a point the daemon's replay ring no longer reaches (or from before
    /// the daemon restarted).
    case replayWindowExceeded
    /// This client read too slowly and frames were dropped for it.
    case clientSlow
    /// A satellite's uplink was down for longer than its ring window.
    case uplinkReconnect
    /// The client resumed under another daemon run's numbers (`Subscribe.seq_epoch` did not match
    /// `Welcome.seq_epoch`): the retained snapshots were just sent, so nothing was missed that the
    /// snapshots do not already show. Never a "may have missed updates" notice.
    case daemonRestarted
    /// The daemon's own sequencer fell behind its producers and lost frames before numbering them.
    case lagged
    /// Made by the client, never on the wire: a number was skipped on a topic whose numbers are
    /// contiguous for every client (`SeqWire.contiguousTopics`) with no `gap` in between.
    case numberJump
    /// A reason a newer daemon sent. Treated as "may have missed updates" like the rest.
    case unknown

    init(wire: String?) {
        switch wire {
        case "replay_window_exceeded": self = .replayWindowExceeded
        case "client_slow":            self = .clientSlow
        case "uplink_reconnect":       self = .uplinkReconnect
        case "daemon_restarted":       self = .daemonRestarted
        case "lagged":                 self = .lagged
        default:                       self = .unknown
        }
    }

    /// Does this reason mean the topic's list on screen may be stale? (`daemonRestarted` does not:
    /// the snapshot that came with it replaced the list.)
    public var mayHaveMissedUpdates: Bool { self != .daemonRestarted }
}

public enum SeqWire {
    /// The `Welcome.features` entry of a daemon that numbers its topics and honours `resume`.
    public static let feature = "seq"

    /// Topics whose numbers a network peer sees without a hole: no frame of the topic is ever
    /// withheld from or trimmed away for a paired device (every variant is `ServerClass::Open`).
    /// On any other topic a skipped number is usual (the daemon numbers once for every trust level
    /// and the phone is not sent every frame), so a skip there is not a loss.
    static let contiguousTopics: Set<String> = ["focuses", "mother_statusline"]

    /// The topic a frame of wire `type` belongs to, or `nil` for a frame with no topic. Mirrors
    /// `ServerMsg::topic()` in `src/ipc/protocol.rs`; `SeqWireTests.testTheTopicTableMatchesTheDaemons`
    /// parses that source and fails when the two differ.
    static func topic(ofFrameType type: String) -> String? {
        switch type {
        case "activity", "activity_snapshot", "activity_health":
            return "activity"
        case "mother_jobs", "mother_await_detected", "mother_notice_state":
            return "mother_jobs"
        case "mother_statusline":   return "mother_statusline"
        case "mother_peek":         return "mother_peek"
        case "teri_state":          return "teri"
        case "work_source_status", "work_snapshot", "teri_picks":
            return "work"
        case "focus_registry_updated": return "focuses"
        case "perri_state":         return "perri"
        case "fred_state":          return "fred"
        case "focus_layout", "pane_content", "focus_created", "notification":
            return "layout"
        case "decision_request", "decision_resolved", "approval_pending":
            return "decision"
        case "model_catalog", "model_defaults", "session_model_state":
            return "model"
        default:
            return nil
        }
    }

    /// The topic and number a frame carries, or `nil` when it has none.
    public static func topicSeq(from data: Data) -> (topic: String, seq: UInt64)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return topicSeq(json: json)
    }

    static func topicSeq(json: [String: Any]) -> (topic: String, seq: UInt64)? {
        guard let type = json["type"] as? String, let topic = topic(ofFrameType: type) else { return nil }
        let key = type == "activity" ? "topic_seq" : "seq"
        guard let number = json[key] as? NSNumber else { return nil }
        return (topic, number.uint64Value)
    }
}

/// The last number the client saw on each topic, to send as `Subscribe.resume` on the next
/// connection, and the daemon run (`Welcome.seq_epoch`) those numbers belong to. Pure value type:
/// no I/O, so the resume rules are tested without a socket.
public struct SeqTracker: Equatable, Sendable {
    public private(set) var last: [String: UInt64] = [:]
    /// The daemon run the numbers in `last` were given by; `nil` until a `Welcome` named one.
    public private(set) var epoch: UInt64?

    public init() {}

    /// What to send as `resume`; empty until a numbered frame has been seen.
    public var resume: [String: UInt64] { last }

    /// What folding a frame in found out.
    public enum Observation: Equatable, Sendable {
        case none
        /// A `Welcome` named another daemon run than the numbers belong to: they were dropped.
        case epochChanged
        /// A number was skipped on a contiguous topic with no `gap` in between.
        case jumped(topic: String, from: UInt64, to: UInt64)
    }

    /// Folds one inbound frame in: a numbered frame moves its topic's number up; a `gap` that
    /// names a point the client cannot trust (`replay_window_exceeded`, `daemon_restarted`) sets it;
    /// a `welcome` that names another daemon run than the numbers belong to drops them (a restarted
    /// daemon numbers from 1 again, so the old numbers mean nothing).
    @discardableResult
    public mutating func observe(_ data: Data) -> Observation {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .none }
        switch json["type"] as? String {
        case "welcome":
            return noteEpoch((json["seq_epoch"] as? NSNumber)?.uint64Value)
        case "gap":
            guard let topic = json["topic"] as? String,
                  let to = (json["to"] as? NSNumber)?.uint64Value else { return .none }
            switch GapReason(wire: json["reason"] as? String) {
            case .replayWindowExceeded, .daemonRestarted:
                last[topic] = to
            default:
                last[topic] = max(last[topic] ?? 0, to)
            }
            return .none
        default:
            break
        }
        guard let (topic, seq) = SeqWire.topicSeq(json: json) else { return .none }
        let previous = last[topic] ?? 0
        last[topic] = max(previous, seq)
        if previous > 0, seq > previous + 1, SeqWire.contiguousTopics.contains(topic) {
            return .jumped(topic: topic, from: previous + 1, to: seq - 1)
        }
        return .none
    }

    /// The `Welcome` of a daemon run: the numbers held belong to it or are forgotten. A `Welcome`
    /// with no epoch (a daemon that predates it) leaves everything as it is.
    @discardableResult
    public mutating func noteEpoch(_ new: UInt64?) -> Observation {
        guard let new else { return .none }
        defer { epoch = new }
        guard let old = epoch, old != new else { return .none }
        last = [:]
        return .epochChanged
    }

    /// Forget everything: the next connection subscribes as a fresh one (snapshots, no replay).
    public mutating func reset() {
        last = [:]
        epoch = nil
    }
}
