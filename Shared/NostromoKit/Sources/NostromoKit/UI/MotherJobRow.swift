// NostromoKit — MotherJobRow.swift
//
// Shared SwiftUI row for the Mother job queue.  Used by both iOS (inside a
// NavigationLink) and macOS (inside an NSHostingView-wrapped List).
//
// Swipe actions work via trackpad on macOS 13+ and finger swipe on iOS.
// Terminal-state rows show "Archive"; active rows show "Cancel".

import SwiftUI

/// A single Mother job row with built-in swipe-to-archive / swipe-to-cancel.
public struct MotherJobRow: View {
    public let model: MotherJobRowModel
    public let onArchive: () -> Void
    public let onCancel: () -> Void

    public init(
        model: MotherJobRowModel,
        onArchive: @escaping () -> Void = {},
        onCancel:  @escaping () -> Void = {}
    ) {
        self.model     = model
        self.onArchive = onArchive
        self.onCancel  = onCancel
    }

    public var body: some View {
        rowContent
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if model.isDone {
                    Button(role: .destructive, action: onArchive) {
                        Label("Archive", systemImage: "archivebox")
                    }
                } else {
                    Button(role: .destructive, action: onCancel) {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                }
            }
    }

    // MARK: - Row layout

    private var rowContent: some View {
        HStack(spacing: 12) {
            stateCircle

            VStack(alignment: .leading, spacing: 2) {
                Text(model.title.isEmpty ? model.id : model.title)
                    .font(.headline)
                    .lineLimit(2)

                if let repoBranch = repoBranchLabel {
                    Text(repoBranch)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let ts = model.relativeTimestamp {
                Text(ts)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private var stateCircle: some View {
        Circle()
            .fill(stateColor)
            .frame(width: 10, height: 10)
            .padding(.top, 2)
    }

    private var stateColor: Color {
        switch model.state {
        case "running":          return .blue
        case "awaiting":         return .orange
        case "queued", "ready":  return .gray
        case "succeeded":        return .green
        case "failed":           return .red
        case "cancelled":        return .gray
        default:                 return .gray
        }
    }

    private var repoBranchLabel: String? {
        switch (model.repo, model.branch) {
        case (let r?, let b?): return "\(r) • \(b)"
        case (let r?, nil):    return r
        case (nil, let b?):    return b
        case (nil, nil):       return nil
        }
    }
}
