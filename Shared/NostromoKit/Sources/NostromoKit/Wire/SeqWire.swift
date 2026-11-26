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
    /// A reason a newer daemon sent. Treated as "may have missed updates" like the rest.
    case unknown

    init(wire: String?) {
        switch wire {
        case "replay_window_exceeded": self = .replayWindowExceeded
        case "client_slow":            self = .clientSlow
        case "uplink_reconnect":       self = .uplinkReconnect
        default:                       self = .unknown
        }
    }
}

public enum SeqWire {
    /// The `Welcome.features` entry of a daemon that numbers its topics and honours `resume`.
    public static let feature = "seq"

    /// The topic a frame of wire `type` belongs to, or `nil` for a frame with no topic. Mirrors
    /// `ServerMsg::topic()` in `src/ipc/protocol.rs` (`tests/ios_policy` does not pin it, so change
    /// both together).
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
/// connection. Pure value type: no I/O, so the resume rules are tested without a socket.
public struct SeqTracker: Equatable, Sendable {
    public private(set) var last: [String: UInt64] = [:]

    public init() {}

    /// What to send as `resume`; empty until a numbered frame has been seen.
    public var resume: [String: UInt64] { last }

    /// Folds one inbound frame in: a numbered frame moves its topic's number up; a `gap` that
    /// names a point the client cannot trust (`replay_window_exceeded`) sets it, so a daemon that
    /// restarted (its numbers start again) is followed rather than outrun forever.
    public mutating func observe(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if json["type"] as? String == "gap" {
            guard let topic = json["topic"] as? String,
                  let to = (json["to"] as? NSNumber)?.uint64Value else { return }
            switch GapReason(wire: json["reason"] as? String) {
            case .replayWindowExceeded:
                last[topic] = to
            default:
                last[topic] = max(last[topic] ?? 0, to)
            }
            return
        }
        if let (topic, seq) = SeqWire.topicSeq(json: json) {
            last[topic] = max(last[topic] ?? 0, seq)
        }
    }

    /// Forget everything: the next connection subscribes as a fresh one (snapshots, no replay).
    public mutating func reset() { last = [:] }
}
