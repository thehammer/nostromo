// NostromoKit — TeriTodoRow.swift
//
// Shared SwiftUI row for a Teri todo.  Used by both iOS (TeriView) and macOS
// (NSHostingView-wrapped list inside TeriView).
//
// Priority colour logic mirrors the TUI (src/views/teri.rs):
//   1 → red    2 → orange (amber)    4/5 → secondary (dim)    else → primary

import SwiftUI

/// A single Teri todo row with priority badge, title, optional Jira chip,
/// and optional relative due date.
public struct TeriTodoRow: View {
    public let model: TeriTodoRowModel

    public init(model: TeriTodoRowModel) {
        self.model = model
    }

    public var body: some View {
        HStack(spacing: 10) {
            priorityBadge

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.title)
                        .font(.headline)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let key = model.jiraKey {
                        Text(key)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(.secondary.opacity(0.5), lineWidth: 1)
                            )
                    }
                }
            }

            Spacer()

            if let due = model.relativeDue ?? model.rawDueDate {
                Text(due)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Priority badge

    private var priorityBadge: some View {
        Text("P\(model.priority)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(priorityColor)
            )
    }

    private var priorityColor: Color {
        switch model.priority {
        case 1:        return .red
        case 2:        return .orange
        case 4, 5:     return .secondary
        default:       return .primary
        }
    }
}

// MARK: - Preview

#Preview {
    List {
        TeriTodoRow(model: TeriTodoRowModel(
            id: 1,
            title: "Write the Teri cross-platform broadcast",
            priority: 1,
            jiraKey: "CORE-123",
            relativeDue: "in 2 days"
        ))
        TeriTodoRow(model: TeriTodoRowModel(
            id: 2,
            title: "Review the macOS split-view layout for all agent views",
            priority: 2,
            jiraKey: nil,
            relativeDue: "in 1 week"
        ))
        TeriTodoRow(model: TeriTodoRowModel(
            id: 3,
            title: "Update documentation for the daemon IPC protocol",
            priority: 3,
            jiraKey: nil,
            relativeDue: nil
        ))
        TeriTodoRow(model: TeriTodoRowModel(
            id: 4,
            title: "Archive old completed todos",
            priority: 5,
            jiraKey: nil,
            relativeDue: "3 weeks ago"
        ))
    }
}
