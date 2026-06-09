// NostromoKit — FredMailRow.swift
//
// Shared SwiftUI row for a single mailbox item.
// Used by both iOS (inside a List) and macOS (inside an NSHostingView-wrapped List).
// No AppKit / UIKit — pure SwiftUI only.

import SwiftUI

/// A single email row with unread indicator, VIP star, invite glyph, and relative time.
public struct FredMailRow: View {
    public let item:         MailboxItem
    /// Pre-formatted relative time string (e.g. "2 min ago"). Pass nil to hide.
    public let relativeTime: String?

    public init(item: MailboxItem, relativeTime: String? = nil) {
        self.item         = item
        self.relativeTime = relativeTime
    }

    public var body: some View {
        HStack(spacing: 10) {
            // Unread dot (same size when read so rows don't shift)
            Circle()
                .fill(item.isRead ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                // Sender line
                HStack(spacing: 4) {
                    Text(item.from)
                        .font(item.isRead ? .headline : .headline.weight(.semibold))
                        .lineLimit(1)
                    if item.vip {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                            .font(.caption2)
                    }
                }
                // Subject line
                Text(item.subject)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                if let ts = relativeTime {
                    Text(ts)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if item.isInvite {
                    Image(systemName: "calendar")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
