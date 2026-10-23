// NostromoKit — ApprovalGuardBarText.swift
//
// AP2b: the one line of the production-shell guard bar: `Blocked: Cody tried to send input to a
// production shell`. Pure: no UI.

import Foundation

public enum ApprovalGuardBarText {

    static let openVerb = "open a production shell"
    static let sendVerb = "send input to a production shell"

    /// What the blocked agent tried to do, from the frame's `summary` (the tool name, then the first
    /// command word: `Bash tmux`, `Bash ecs_connect`; a rule id also reads): `send input to a
    /// production shell` for tmux input, else `open a production shell`.
    public static func verb(summary: String) -> String {
        let words = summary.split(whereSeparator: { $0.isWhitespace }).map { word -> String in
            let name = word.split(separator: "/").last.map(String.init) ?? String(word)
            return name.lowercased()
        }
        return words.contains { $0 == "tmux" || $0 == "tmux_input" } ? sendVerb : openVerb
    }

    /// `Blocked: <agent> tried to <verb>`. A nil or empty agent reads `An agent`.
    public static func line(agent: String?, summary: String) -> String {
        let name = agent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "Blocked: \(name.isEmpty ? "An agent" : name) tried to \(verb(summary: summary))"
    }
}
