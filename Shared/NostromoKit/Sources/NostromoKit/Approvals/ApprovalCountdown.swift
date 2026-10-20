// NostromoKit — ApprovalCountdown.swift
//
// The card's "denies in 14:32" text (AP2a). Pure functions over the request's
// deadline and a clock reading, so the Mac's 1 Hz timer only has to call them.

import Foundation

public enum ApprovalCountdown {

    /// Whole seconds left before `deadlineAtMs`, rounded **up** (a fresh 15-minute
    /// request reads `15:00`, and `0:00` appears only once the deadline has passed).
    /// Never negative.
    public static func secondsLeft(deadlineAtMs: UInt64, nowMs: UInt64) -> Int {
        guard deadlineAtMs > nowMs else { return 0 }
        let remainingMs = deadlineAtMs - nowMs
        // Divide first: adding 999 to a huge remainder would overflow.
        let seconds = remainingMs / 1000 + (remainingMs % 1000 == 0 ? 0 : 1)
        return Int(min(seconds, UInt64(Int.max)))
    }

    /// `14:32`, `0:05`, `0:00`. Minutes are not capped (an hour reads `60:00`).
    public static func clock(seconds: Int) -> String {
        let s = max(0, seconds)
        let rest = s % 60
        return "\(s / 60):\(rest < 10 ? "0" : "")\(rest)"
    }

    /// `denies in 14:32`.
    public static func label(seconds: Int) -> String {
        "denies in \(clock(seconds: seconds))"
    }

    public static func label(deadlineAtMs: UInt64, nowMs: UInt64) -> String {
        label(seconds: secondsLeft(deadlineAtMs: deadlineAtMs, nowMs: nowMs))
    }
}
