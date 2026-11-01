// NostromoKit — MotherNoticeMark.swift
//
// What the Mother list says about whether a job's focus was told (Mother focus v2, R11/R13):
// the row's notified mark, the Overview's "Notices" section, the held-bar text and the Debug
// stats copy. All pure, with an injected `now`, so none of it depends on a clock.
//
// The marks (`✓`, `⏸`) are app-computed. A name is sanitised, capped and stripped of the mark
// glyphs before it goes into any string here, so nothing an agent wrote can draw one.

import Foundation

/// Words for the daemon's notice vocabulary.
public enum MotherNoticeText {
    public static let nameCap = 24
    /// Glyphs only the app draws as marks.
    static let markGlyphs: Set<Character> = ["✓", "✔", "⏸", "⟲", "⚑"]

    /// A focus name for a mark: sanitised, without mark glyphs, capped at `nameCap`.
    public static func cleanName(_ raw: String?) -> String {
        let stripped = String((raw ?? "").filter { !markGlyphs.contains($0) })
        return MotherOriginDisplay.clean(stripped, cap: nameCap)
    }

    /// `pr_opened` → `PR opened`. Anything unknown is sanitised and capped.
    public static func stateWords(_ raw: String) -> String {
        switch raw {
        case "pr_opened":      return "PR opened"
        case "pr_merged":      return "PR merged"
        case "pr_closed":      return "PR closed"
        case "retry_started":  return "retry started"
        default:
            return MotherOriginDisplay.clean(raw.replacingOccurrences(of: "_", with: " "), cap: 20)
        }
    }

    /// Why a notice is held, dropped or unsent, as a short phrase.
    public static func reasonWords(_ raw: String?) -> String {
        switch raw {
        case "batching":             return "batching updates"
        case "busy":                 return "the session is busy"
        case "cap":                  return "wake cap reached"
        case "loop_guard":           return "loop guard"
        case "session_not_running":  return "session not running"
        case "quiet":                return "quiet mode"
        case "focus_off":            return "notices off for this focus"
        case "global_off":           return "session notices off"
        case "focus_closed":         return "the focus is closed"
        case "not_notifiable":       return "not notifiable"
        default:                     return "no reason given"
        }
    }

    /// The text of the held bar in a focus.
    public static func heldBarText(_ reason: MotherHeldBarReason) -> String {
        switch reason {
        case .loopGuard:
            return "Mother notices held: 3 automatic wakes in a row. Your next message here releases them."
        case .cap:
            return "Mother notices held: 6 wakes this hour. They resume when the hour rolls or after your next message."
        }
    }

    /// `4m ago` (short) or `4 minutes ago` (long). Under a minute reads `just now` / `under a minute ago`.
    public static func ago(atMs: Int64, now: Date, long: Bool) -> String {
        let secs = max(0, Int(now.timeIntervalSince1970 - Double(atMs) / 1000))
        if secs < 60 { return long ? "under a minute ago" : "just now" }
        let n: Int, short: String, word: String
        if secs < 3600 {
            n = secs / 60; short = "m"; word = "minute"
        } else if secs < 86400 {
            n = secs / 3600; short = "h"; word = "hour"
        } else {
            n = secs / 86400; short = "d"; word = "day"
        }
        return long ? "\(n) \(word)\(n == 1 ? "" : "s") ago" : "\(n)\(short) ago"
    }
}

/// The row's notified mark.
public struct MotherNoticeMark: Equatable, Sendable {
    /// `✓ told Claudia` / `⏸ held`.
    public let wide: String
    /// `✓` / `⏸`.
    public let narrow: String
    public let tooltip: String
    /// Appended to the row's spoken label.
    public let accessibilitySentence: String

    /// - Parameter originName: the verified origin focus's name; nil when the origin is not notifiable
    ///   (unverified, you, unknown): no mark then. Nothing for `dropped`, `not_sent` or `none` either.
    public static func make(notice: MotherNoticeAnnotation?, originName: String?, now: Date) -> MotherNoticeMark? {
        guard let notice, originName != nil else { return nil }
        let name = MotherNoticeText.cleanName(originName)
        switch notice.status {
        case .told:
            let who = name.isEmpty ? "the focus" : name
            let when = notice.atMs.map { MotherNoticeText.ago(atMs: $0, now: now, long: true) }
            let state = notice.lastState.map(MotherNoticeText.stateWords)
            var tip = "\(who) was told"
            if let state, !state.isEmpty { tip += " '\(state)'" }
            if let when { tip += " \(when)" }
            return MotherNoticeMark(
                wide: name.isEmpty ? "✓ told" : "✓ told \(name)", narrow: "✓",
                tooltip: tip,
                accessibilitySentence: "Told \(who)" + (when.map { " \($0)" } ?? "") + ".")
        case .held:
            let tip: String
            switch notice.reason {
            case "loop_guard": tip = MotherNoticeText.heldBarText(.loopGuard)
            case "cap":        tip = MotherNoticeText.heldBarText(.cap)
            default:           tip = "Notice held: \(MotherNoticeText.reasonWords(notice.reason))."
            }
            return MotherNoticeMark(
                wide: "⏸ held", narrow: "⏸", tooltip: tip,
                accessibilitySentence: "Notice held: \(MotherNoticeText.reasonWords(notice.reason)).")
        case .dropped, .notSent, .none:
            return nil
        }
    }
}

/// The Overview's "Notices" section for one job.
public struct MotherNoticeSectionModel: Equatable, Sendable {
    /// One line, always shown.
    public let summary: String
    /// Muted (a "Not notified" line) rather than normal.
    public let isMuted: Bool
    /// One line per history entry, oldest first; empty when there is nothing to expand.
    public let details: [String]

    public static func make(annotation: MotherJobAnnotation?, origin: MotherOriginDisplay,
                            now: Date) -> MotherNoticeSectionModel? {
        guard let annotation else { return nil }
        switch origin.kind {
        case .focus:
            if !origin.isClickable {
                return MotherNoticeSectionModel(
                    summary: "Not notified: the focus that queued this is closed.", isMuted: true, details: [])
            }
            return focusSection(annotation.notice, name: MotherNoticeText.cleanName(origin.name), now: now)
        case .unverified, .you, .unknown, .other:
            return MotherNoticeSectionModel(
                summary: "Not notified: \(reason(from: origin.tooltip)).", isMuted: true, details: [])
        }
    }

    /// The first line of an origin tooltip as a clause: no `Not notified.` tail, lower-cased start.
    static func reason(from tooltip: String) -> String {
        var line = tooltip.components(separatedBy: "\n").first ?? tooltip
        line = line.replacingOccurrences(of: " Not notified.", with: "")
        while line.hasSuffix(".") { line.removeLast() }
        guard let first = line.first else { return "not a focus job" }
        return first.lowercased() + line.dropFirst()
    }

    private static func focusSection(_ notice: MotherNoticeAnnotation?, name: String, now: Date) -> MotherNoticeSectionModel {
        let who = name.isEmpty ? "the focus" : name
        guard let notice, notice.status != .none || !notice.history.isEmpty else {
            return MotherNoticeSectionModel(summary: "Notices to \(who): none sent yet.", isMuted: true, details: [])
        }
        let last = notice.history.last
        let status = last?.status ?? notice.status
        let reason = last?.reason ?? notice.reason
        let at = last?.atMs ?? notice.atMs
        let states: [String] = last?.states ?? (notice.lastState.map { [$0] } ?? [])
        let words = states.map(MotherNoticeText.stateWords).filter { !$0.isEmpty }

        var parts: [String] = []
        if let head = words.last { parts.append(head) }
        let when = at.map { MotherNoticeText.ago(atMs: $0, now: now, long: false) }
        switch status {
        case .told:    parts.append("told" + (when.map { " \($0)" } ?? ""))
        case .held:    parts.append("held (\(MotherNoticeText.reasonWords(reason)))")
        case .dropped: parts.append("dropped (\(MotherNoticeText.reasonWords(reason)))")
        case .notSent: parts.append("not sent (\(MotherNoticeText.reasonWords(reason)))")
        case .none:    parts.append("nothing sent")
        }
        var summary = "Notices to \(who): " + parts.joined(separator: ", ")
        if words.count > 1 {
            summary += " (with \(words.dropLast().joined(separator: ", ")))"
        }
        summary += "."
        return MotherNoticeSectionModel(summary: summary, isMuted: false,
                                        details: notice.history.map { detail($0, now: now) })
    }

    private static func detail(_ e: MotherNoticeHistoryEntry, now: Date) -> String {
        var parts: [String] = []
        parts.append(e.atMs.map { MotherNoticeText.ago(atMs: $0, now: now, long: false) } ?? "time unknown")
        let states = e.states.map(MotherNoticeText.stateWords).filter { !$0.isEmpty }
        parts.append(states.isEmpty ? "no states" : states.joined(separator: ", "))
        switch e.status {
        case .told:
            parts.append("delivered")
            parts.append(e.wake ? "woke the session" : "queued behind a turn")
        case .held:    parts.append("held (\(MotherNoticeText.reasonWords(e.reason)))")
        case .dropped: parts.append("dropped (\(MotherNoticeText.reasonWords(e.reason)))")
        case .notSent: parts.append("not sent (\(MotherNoticeText.reasonWords(e.reason)))")
        case .none:    parts.append("nothing sent")
        }
        return parts.joined(separator: " · ")
    }
}

/// The text Debug ▸ Copy Mother Notice Stats puts on the pasteboard. Counts and tags only: never a
/// title or a focus name.
public enum MotherNoticeStats {
    public static func text(state: MotherNoticeStateWire?, annotations: [String: MotherJobAnnotation]) -> String {
        var lines = ["Mother notice stats"]
        guard let state else {
            lines.append("No notice state received from the daemon yet.")
            return lines.joined(separator: "\n")
        }
        lines.append("Session notices: \(state.enabled ? "on" : "off")")
        lines.append("Focuses: \(state.focuses.count)")
        for f in state.focuses {
            let days = f.wakesByDay.sorted { $0.day < $1.day }.suffix(7)
                .map { "\(MotherOriginDisplay.clean($0.day, cap: 10))=\($0.count)" }
            lines.append("  \(MotherOriginDisplay.clean(f.tag, cap: 60)): mode \(f.mode.rawValue); wakes per day (last 7): "
                         + (days.isEmpty ? "none" : days.joined(separator: " ")))
        }
        var byReason: [String: Int] = [:]
        for f in state.focuses { if let h = f.held { byReason[h.reason, default: 0] += h.count } }
        let held = byReason.sorted { $0.key < $1.key }
            .map { "\(MotherOriginDisplay.clean($0.key, cap: 30))=\($0.value)" }
        lines.append("Held notices by reason: " + (held.isEmpty ? "none" : held.joined(separator: " ")))
        let verified = annotations.values.filter { $0.origin?.kind == .focus }.count
        let total = annotations.count
        let share = total == 0 ? "n/a" : "\(verified)/\(total) (\(Int((Double(verified) / Double(total) * 100).rounded()))%)"
        lines.append("Jobs with a verified origin: \(share)")
        return lines.joined(separator: "\n")
    }
}
