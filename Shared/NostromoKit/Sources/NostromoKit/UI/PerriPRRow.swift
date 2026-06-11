// NostromoKit — PerriPRRow.swift
//
// Shared SwiftUI row for the Perri PR review queue.
// Analogous to MotherJobRow — used by both iOS and macOS (AppKit via
// NSHostingView if needed).
//
// No platform conditionals; no AppKit/UIKit imports.  Pure SwiftUI only.

import SwiftUI

/// A single Perri PR queue row with a CI glyph, title, caption, bucket badge,
/// and a context menu for Load PR / Clear actions.
public struct PerriPRRow: View {
    public let model:    PerriPRRowModel
    public let onLoad:   () -> Void
    public let onClear:  () -> Void

    public init(
        model:   PerriPRRowModel,
        onLoad:  @escaping () -> Void = {},
        onClear: @escaping () -> Void = {}
    ) {
        self.model   = model
        self.onLoad  = onLoad
        self.onClear = onClear
    }

    public var body: some View {
        rowContent
            .contextMenu {
                Button("Load PR", action: onLoad)
                Button("Clear",   action: onClear)
            }
    }

    // MARK: - Row layout

    private var rowContent: some View {
        HStack(spacing: 10) {
            ciGlyph

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(model.title)
                        .font(.headline)
                        .lineLimit(2)

                    if model.newActivity {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 7, height: 7)
                    }
                }

                Text("\(model.repo) #\(model.number) • \(model.author)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(bucketLabel)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(bucketColor.opacity(0.15))
                .foregroundStyle(bucketColor)
                .clipShape(Capsule())
        }
        .padding(.vertical, 4)
    }

    // MARK: - CI glyph

    private var ciGlyph: some View {
        Circle()
            .fill(ciColor)
            .frame(width: 10, height: 10)
            .padding(.top, 2)
    }

    private var ciColor: Color {
        switch model.ciState {
        case .success: return .green
        case .pending: return .orange
        case .failure: return .red
        case .unknown: return .gray
        }
    }

    // MARK: - Bucket display

    private var bucketLabel: String {
        switch model.bucket {
        case "requested":    return "requested"
        case "needs_review": return "needs review"
        case "changes_req":  return "changes req"
        case "dependabot":   return "dependabot"
        default:             return model.bucket
        }
    }

    private var bucketColor: Color {
        switch model.bucket {
        case "requested":    return .blue
        case "needs_review": return .orange
        case "changes_req":  return .red
        case "dependabot":   return .yellow
        default:             return .gray
        }
    }
}
