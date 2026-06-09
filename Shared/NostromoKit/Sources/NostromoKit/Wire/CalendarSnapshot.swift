// NostromoKit — CalendarSnapshot.swift
//
// Wire types for Fred's calendar state broadcast.
// Mirrors the Rust structs in `src/data/fred_calendar.rs`, using
// snake_case CodingKeys to match the daemon's serde output.

import Foundation

// MARK: - CalendarEvent

/// A single calendar event in today's snapshot.
/// Mirrors `CalendarEvent` in `src/data/fred_calendar.rs`.
public struct CalendarEvent: Codable, Equatable, Identifiable {
    public let start:  Date?
    public let end:    Date?
    public let title:  String
    public let status: String
    public let isNow:  Bool

    /// Stable derived identifier (no server-side id field).
    public var id: String {
        "\(title)|\(start?.timeIntervalSince1970 ?? 0)"
    }

    enum CodingKeys: String, CodingKey {
        case start
        case end
        case title
        case status
        case isNow = "is_now"
    }

    public init(start: Date?, end: Date?, title: String, status: String, isNow: Bool) {
        self.start  = start
        self.end    = end
        self.title  = title
        self.status = status
        self.isNow  = isNow
    }
}

// MARK: - NextEvent

/// The next upcoming (non-cancelled, non-declined) calendar event.
/// Mirrors `NextEvent` in `src/data/fred_calendar.rs`.
public struct NextEvent: Codable, Equatable {
    public let title:     String
    public let inMinutes: Int

    enum CodingKeys: String, CodingKey {
        case title
        case inMinutes = "in_minutes"
    }

    public init(title: String, inMinutes: Int) {
        self.title     = title
        self.inMinutes = inMinutes
    }
}

// MARK: - CalendarSnapshot

/// Full snapshot of today's calendar events.
/// Mirrors `CalendarSnapshot` in `src/data/fred_calendar.rs`.
public struct CalendarSnapshot: Codable, Equatable {
    public let events:  [CalendarEvent]
    public let next:    NextEvent?
    /// Sweater colour: `"sage"` | `"amber"` | `"red"`.
    public let sweater: String
    public let stale:   Bool
    public let error:   String?

    enum CodingKeys: String, CodingKey {
        case events
        case next
        case sweater
        case stale
        case error
    }

    /// Custom decoder: mirrors Rust `Default` so missing fields decode cleanly.
    public init(from decoder: Decoder) throws {
        let c   = try decoder.container(keyedBy: CodingKeys.self)
        events  = try c.decodeIfPresent([CalendarEvent].self, forKey: .events) ?? []
        next    = try c.decodeIfPresent(NextEvent.self,       forKey: .next)
        sweater = try c.decodeIfPresent(String.self,          forKey: .sweater) ?? ""
        stale   = try c.decodeIfPresent(Bool.self,            forKey: .stale)   ?? false
        error   = try c.decodeIfPresent(String.self,          forKey: .error)
    }

    public init(events: [CalendarEvent], next: NextEvent?, sweater: String,
                stale: Bool, error: String?) {
        self.events  = events
        self.next    = next
        self.sweater = sweater
        self.stale   = stale
        self.error   = error
    }
}
