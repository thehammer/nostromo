// NostromoKit — ReasonPhrases.swift
//
// The fixed phrases a satellite ("work") host's row may show, and the only words such a row has
// (Q8, PRD AC53). They are the same words the lock-screen push uses: `ReasonPhrasesTests` asserts
// these tables equal `tests/fixtures/push-vocab/reason_phrases.json`, and W13's `vocab.rs` asserts
// the same file, so the app and the lock screen cannot drift.
//
// Nothing here takes free text. A title, a question, a branch or a repository is not a parameter
// of any function in this file.

import Foundation

public enum ReasonPhrases {
    /// Anything the table does not know.
    public static let defaultReason = "needs you"

    /// `paused_reason` -> phrase.
    public static let pausedReason: [String: String] = [
        "user": "asked a question",
        "adherence_blocked": "blocked after review",
        "operator_hold": "held after a failure",
        "cost_cap": "paused at its spend cap",
    ]

    /// `activity` -> phrase.
    public static let activity: [String: String] = [
        "pipeline_blocked": "pipeline blocked",
    ]

    /// `agent_class` -> name; anything else is `agentFallback`.
    public static let agents: [String: String] = [
        "mother": "Mother", "perri": "Perri", "fred": "Fred", "teri": "Teri", "claudia": "Claudia",
    ]
    public static let agentFallback = "A session"

    /// Why a Mother job needs the operator: the paused reason first, then the activity.
    public static func reason(pausedReason paused: String?, activity act: String?) -> String {
        if let paused, let phrase = pausedReason[paused] { return phrase }
        if let act, let phrase = activity[act] { return phrase }
        return defaultReason
    }

    /// The agent's name from the fixed set, or *A session*.
    public static func agent(_ agentName: String?) -> String {
        guard let agentName else { return agentFallback }
        return agents[agentName.lowercased()] ?? agentFallback
    }

    /// The 8-hex suffix of a Mother job id (`YYYYMMDDTHHMMSSZ-xxxxxxxx`), or `nil` if it has none.
    public static func jobRef(_ id: String) -> String? {
        let suffix = String(id.split(separator: "-", omittingEmptySubsequences: false).last ?? "")
        let hex = Set("0123456789abcdef")
        return suffix.count == 8 && suffix.allSatisfy(hex.contains) ? suffix : nil
    }

    /// `Job 3f9a1c2e · asked a question`; `A job asked a question` when the id has no valid ref.
    /// `status` is the fixed phrase after the dot: a reason when the job needs the operator, else
    /// its state word.
    public static func jobLine(id: String, status: String) -> String {
        guard let ref = jobRef(id) else { return "A job \(status)" }
        return "Job \(ref) · \(status)"
    }

    /// `PR #4821 · small change · 3 waiting`; no size phrase when unknown.
    public static func prLine(number: Int, sizeChangedLines: Int?, waiting: Int) -> String {
        var parts = ["PR #\(number)"]
        if let lines = sizeChangedLines {
            let size = lines < 50 ? "small" : (lines <= 400 ? "medium" : "large")
            parts.append("\(size) change")
        }
        parts.append("\(waiting) waiting")
        return parts.joined(separator: " · ")
    }

    /// `Perri · running`: the agent from the fixed set (or *A session*) and its state word.
    public static func sessionLine(agentName: String?, state: String) -> String {
        "\(agent(agentName)) · \(state)"
    }

    /// A held decision with no question text of its own: the fixed `asked a question` phrase.
    public static var decisionLine: String { "\(agentFallback) \(pausedReason["user"] ?? defaultReason)" }

    /// A focus holding `count` permission requests: a number and fixed words, nothing else.
    public static func approvalLine(count: Int) -> String {
        "\(agentFallback) has \(count) \(count == 1 ? "request" : "requests") waiting"
    }

    /// What a row says when only the Mac can answer it. The phone answers nothing (B10).
    public static let answerOnYourMac = "Answer it on your Mac"

    /// The card's closing line for a row whose content stays on its host.
    public static func detailsStayOn(_ host: String) -> String { "Details stay on \(host)." }
}
