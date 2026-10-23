// NostromoKit — ApprovalRowStatusText.swift
//
// AP2b: what a tool call's transcript row says about its permission request, in place.
// Pure: no UI. The Mac row shows `text(timeZone:)` in one suffix field and posts nothing.

import Foundation

/// Where a tool call stands as far as its approval request goes.
public enum ApprovalRowStatus: Equatable, Sendable {
    /// Waiting for a person.
    case awaiting
    /// A person allowed it, at this time (ms since the epoch).
    case approved(atMs: UInt64)
    case allowedBySessionRule
    case allowedByYourRule
    case deniedByYou
    case deniedNoAnswer
    case deniedAppClosed
    case deniedRestarted
    case deniedUnavailable
    case deniedUnreadable
    case blockedByGuard
    /// The request is gone without an answer (withdrawn or cancelled), or ended in a way this build
    /// has no words for: the row says nothing.
    case withdrawn

    /// The status for an `approval_resolved.outcome` (the audit log's name for it). An outcome this
    /// build doesn't know says nothing rather than guessing.
    public static func forOutcome(_ outcome: String, atMs: UInt64) -> ApprovalRowStatus {
        switch outcome {
        case "allowed_once", "answered": return .approved(atMs: atMs)
        case "allowed_by_session_rule": return .allowedBySessionRule
        case "allowed_by_your_rule": return .allowedByYourRule
        case "denied", "denied_and_stopped": return .deniedByYou
        case "timed_out": return .deniedNoAnswer
        case "no_app": return .deniedAppClosed
        case "restart", "restart_crash": return .deniedRestarted
        case "approval_unavailable": return .deniedUnavailable
        case "invalid_request": return .deniedUnreadable
        case "guard_blocked": return .blockedByGuard
        default: return .withdrawn
        }
    }

    public var isAwaiting: Bool { self == .awaiting }

    /// The call was refused: denied for any reason, or blocked by the guard.
    public var isRefusal: Bool {
        switch self {
        case .deniedByYou, .deniedNoAnswer, .deniedAppClosed, .deniedRestarted, .deniedUnavailable,
             .deniedUnreadable, .blockedByGuard: return true
        case .awaiting, .approved, .allowedBySessionRule, .allowedByYourRule, .withdrawn: return false
        }
    }

    /// What the row says, or nil for nothing. `approved by you · 14:02` uses the local time of `timeZone`.
    public func text(timeZone: TimeZone = .current) -> String? {
        switch self {
        case .awaiting: return "awaiting your approval"
        case .approved(let atMs): return "approved by you · \(Self.clock(atMs, in: timeZone))"
        case .allowedBySessionRule: return "allowed by session rule"
        case .allowedByYourRule: return "allowed by your rule"
        case .deniedByYou: return "denied by you"
        case .deniedNoAnswer: return "denied: no answer in 15 min"
        case .deniedAppClosed: return "denied: Nostromo closed"
        case .deniedRestarted: return "denied: Nostromo restarted"
        case .deniedUnavailable: return "denied: approvals unavailable"
        case .deniedUnreadable: return "denied: unreadable request"
        case .blockedByGuard: return "blocked: production-shell guard"
        case .withdrawn: return nil
        }
    }

    /// `HH:mm`, 24-hour, in `timeZone`.
    private static func clock(_ ms: UInt64, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
