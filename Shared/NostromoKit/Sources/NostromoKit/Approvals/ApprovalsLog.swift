// NostromoKit — ApprovalsLog.swift
//
// AP5: the Approvals log's words and paging. Pure: no UI. The Mac window and `approvals log` both read
// rows through these, so they say the same thing.

import Foundation

/// The outcome filter the window offers. `rawValue` is what `approvals_log_query.outcome` carries.
public enum ApprovalsLogOutcomeGroup: String, CaseIterable, Equatable, Sendable {
    case allowed
    case denied
    case timedOut = "timed_out"
    case guardBlocked = "guard_blocked"
    case refused
    case rules

    public var title: String {
        switch self {
        case .allowed: return "Allowed"
        case .denied: return "Denied"
        case .timedOut: return "Timed out or no app"
        case .guardBlocked: return "Guard-blocked"
        case .refused: return "Refused"
        case .rules: return "Rules"
        }
    }
}

/// Which rows a link into the window asks for. A link names a call, a request or one entry; the window
/// keeps the rows that match and says so, with a way back to every row.
public struct ApprovalsLogLink: Equatable, Sendable {
    public var tag: String?
    public var toolUseId: String?
    public var requestId: String?
    public var entryId: String?

    public init(tag: String? = nil, toolUseId: String? = nil, requestId: String? = nil, entryId: String? = nil) {
        self.tag = tag; self.toolUseId = toolUseId; self.requestId = requestId; self.entryId = entryId
    }

    /// No call, request or entry named: only (at most) a focus.
    public var isRowFilter: Bool { toolUseId != nil || requestId != nil || entryId != nil }

    public func matches(_ row: ApprovalsLogRow) -> Bool {
        if let tag, row.tag != tag { return false }
        if let toolUseId, row.toolUseId != toolUseId { return false }
        if let requestId, row.requestId != requestId { return false }
        if let entryId, !row.entryIds.contains(entryId) && row.rowId != entryId { return false }
        return true
    }

    /// What the strip above the table says.
    public var description: String {
        if let entryId { return "entry \(entryId.prefix(8))" }
        if let requestId { return "request \(requestId.prefix(8))" }
        if let toolUseId { return "call \(toolUseId.suffix(8))" }
        return tag.map { "focus \($0)" } ?? "everything"
    }
}

public enum ApprovalsLogText {

    /// The row's time as `HH:mm:ss` in `timeZone`; the raw text when it does not parse.
    public static func time(_ row: ApprovalsLogRow, timeZone: TimeZone = .current) -> String {
        guard let date = timestamp(row.ts) else { return row.ts }
        return format(date, "HH:mm:ss", timeZone)
    }

    /// The date and time in `timeZone` (`2026-11-07 14:02:03`), for a column that also shows the day.
    public static func dateTime(_ ts: String, timeZone: TimeZone = .current) -> String {
        guard let date = timestamp(ts) else { return ts }
        return format(date, "yyyy-MM-dd HH:mm:ss", timeZone)
    }

    /// The tooltip: the same instant in UTC.
    public static func utcTooltip(_ ts: String) -> String {
        guard let date = timestamp(ts) else { return ts }
        return format(date, "yyyy-MM-dd HH:mm:ss 'UTC'", TimeZone(identifier: "UTC") ?? .current)
    }

    /// An RFC 3339 time, with or without fractional seconds.
    public static func timestamp(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: text) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    /// What happened to the row, in words. Reuses the transcript row's words where one exists.
    /// `withholding`: the row's text is being kept from the reader, so nothing from its summary or rule goes in the phrase.
    public static func outcomePhrase(_ row: ApprovalsLogRow, withholding: Bool = false) -> String {
        switch row.kind {
        case .refusal: return refusalPhrase(row.refusalCode)
        case .guardBlocked: return "blocked: production-shell guard"
        case .rule: return rulePhrase(row, withholding: withholding)
        case .other: return withholding ? "other event" : row.summary
        case .request:
            guard let outcome = row.outcome else { return "awaiting an answer" }
            return outcomePhrase(outcome)
        }
    }

    public static func outcomePhrase(_ outcome: String) -> String {
        switch outcome {
        case "allowed_once": return "allowed once"
        case "allowed_for_session": return "allowed for this session"
        case "allowed_by_session_rule": return "allowed by session rule"
        case "allowed_always": return "allowed always"
        case "allowed_by_your_rule": return "allowed by your rule"
        case "answered": return "answered"
        case "denied": return "denied by you"
        case "denied_and_stopped": return "denied and stopped"
        case "deny_write_failed": return "denied (the agent could not be told)"
        case "timed_out": return "denied: no answer in 15 min"
        case "no_app": return "denied: Nostromo closed"
        case "restart", "restart_crash": return "denied: Nostromo restarted"
        case "approval_unavailable": return "denied: approvals unavailable"
        case "invalid_request", "request_unparseable": return "denied: unreadable request"
        case "too_large": return "denied: request too large"
        case "withdrawn": return "withdrawn"
        case "cancelled": return "cancelled"
        case "guard_blocked": return "blocked: production-shell guard"
        default: return outcome.replacingOccurrences(of: "_", with: " ")
        }
    }

    public static func refusalPhrase(_ code: String?) -> String {
        switch code {
        case "requires_secure_connection": return "refused: network peer"
        case "not_operator_app": return "refused: not the Nostromo app"
        case "synthetic_input": return "refused: synthetic input"
        case "already_resolved": return "refused: already answered"
        case "unknown_request": return "refused: unknown request"
        case "invalid_answer", "invalid_rule": return "refused: invalid answer"
        case .some(let other): return "refused: " + other.replacingOccurrences(of: "_", with: " ")
        case .none: return "refused"
        }
    }

    private static func rulePhrase(_ row: ApprovalsLogRow, withholding: Bool) -> String {
        let label = withholding ? "" : (row.ruleLabel.map { ": \($0)" } ?? "")
        let words = row.summary.split(separator: ":", maxSplits: 1).first.map(String.init) ?? "rule"
        return words + label
    }

    /// `Cody`, or `Cody › Explore` for a sub-agent (its type, else its id).
    public static func agentText(_ row: ApprovalsLogRow) -> String {
        let main = row.agent ?? ""
        guard let sub = row.subagent else { return main }
        let name = sub.agentType ?? sub.agentId
        return main.isEmpty ? name : "\(main) › \(name)"
    }

    /// `1.2 s`, `340 ms`; empty when not recorded.
    public static func latency(_ ms: UInt64?) -> String {
        guard let ms else { return "" }
        if ms < 1000 { return "\(ms) ms" }
        if ms < 60_000 { return String(format: "%.1f s", Double(ms) / 1000) }
        return "\(ms / 60_000) min \((ms % 60_000) / 1000) s"
    }

    private static func format(_ date: Date, _ pattern: String, _ timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = pattern
        return f.string(from: date)
    }
}

extension ApprovalJSON {
    /// The value as text for a read-only view: a string as it is, anything else as sorted, indented JSON.
    public var displayText: String {
        if case .string(let s) = self { return s }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    /// A tool input as text, every line as recorded: an object of strings reads as its value (one field, a
    /// Bash `command`) or as `key: value` lines; anything else as sorted, indented JSON.
    public var inputText: String {
        guard case .object(let fields) = self, !fields.isEmpty else { return displayText }
        var strings: [(String, String)] = []
        for key in fields.keys.sorted() {
            guard case .string(let value)? = fields[key] else { return displayText }
            strings.append((key, value))
        }
        if strings.count == 1 { return strings[0].1 }
        // `command` (or `file_path`) first: it is what the request is about.
        let lead = ["command", "file_path"]
        strings.sort { a, b in
            let (ia, ib) = (lead.firstIndex(of: a.0) ?? lead.count, lead.firstIndex(of: b.0) ?? lead.count)
            return ia != ib ? ia < ib : a.0 < b.0
        }
        return strings.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
    }

    /// An object's string field (the command of a Bash input, say).
    public func stringField(_ key: String) -> String? {
        if case .object(let fields) = self, case .string(let s)? = fields[key] { return s }
        return nil
    }
}

/// Where cursor paging stands: the rows so far, newest first, and whether the daemon has more.
public struct ApprovalsLogPager: Equatable {
    public private(set) var rows: [ApprovalsLogRow] = []
    public private(set) var nextCursor: String?
    public private(set) var isLoading = false
    public private(set) var hasLoadedFirstPage = false

    public init() {}

    /// More pages exist and none is on its way.
    public var canLoadMore: Bool { hasLoadedFirstPage && nextCursor != nil && !isLoading }

    /// The cursor the next request carries: nil for the first page.
    public var cursorToSend: String? { hasLoadedFirstPage ? nextCursor : nil }

    /// Drop everything (a filter changed).
    public mutating func reset() { self = ApprovalsLogPager() }

    public mutating func beginLoading() { isLoading = true }

    /// A request failed: paging may be tried again.
    public mutating func failed() { isLoading = false }

    /// A page arrived. A row already held (same `rowId`) is not added twice.
    public mutating func apply(_ page: ApprovalsLogPageFrame) {
        let held = Set(rows.map(\.rowId))
        rows.append(contentsOf: page.rows.filter { !held.contains($0.rowId) })
        nextCursor = page.nextCursor
        hasLoadedFirstPage = true
        isLoading = false
    }

    /// Scrolled near the end: ask for the next page when the last visible row is within `margin` of it.
    public func shouldLoadMore(lastVisibleIndex: Int, margin: Int = 10) -> Bool {
        canLoadMore && lastVisibleIndex >= rows.count - margin
    }
}
