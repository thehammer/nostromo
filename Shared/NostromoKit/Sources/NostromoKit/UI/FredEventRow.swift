// NostromoKit — FredEventRow.swift
//
// Shared SwiftUI row for a single calendar event.
// Used by both iOS (inside a List) and macOS (inside an NSHostingView-wrapped List).
// No AppKit / UIKit — pure SwiftUI only.

import SwiftUI

/// A single calendar event row with status colour, title, and time range.
public struct FredEventRow: View {
    public let event:     CalendarEvent
    /// Pre-formatted time range string (e.g. "09:00–10:00"). Pass nil to hide.
    public let timeRange: String?

    public init(event: CalendarEvent, timeRange: String? = nil) {
        self.event     = event
        self.timeRange = timeRange
    }

    public var body: some View {
        HStack(spacing: 10) {
            // Status bar
            RoundedRectangle(cornerRadius: 2)
                .fill(statusColor)
                .frame(width: 4)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.headline)
                    .lineLimit(2)
                    .strikethrough(isCancelledOrDeclined, color: .secondary)
                    .foregroundStyle(isCancelledOrDeclined ? .secondary : .primary)

                if let tr = timeRange {
                    Text(tr)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if event.isNow {
                Image(systemName: "play.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
        .background(event.isNow ? Color.orange.opacity(0.10) : Color.clear)
        .cornerRadius(4)
    }

    // MARK: - Private helpers

    private var isCancelledOrDeclined: Bool {
        event.status == "cancelled" || event.status == "declined"
    }

    private var statusColor: Color {
        if event.isNow               { return .orange }
        if isCancelledOrDeclined     { return .secondary }
        if event.status == "tentativelyAccepted" { return Color(.systemGray) }
        return .accentColor
    }
}
