// NostromoKit — MotherTodoList.swift
//
// Shared SwiftUI component that renders a list of PeekTodo items from a live
// Mother job snapshot.  Used by both the iOS MotherJobDetailView (wrapped in a
// Section) and the macOS MotherView detail pane.
//
// Each row shows a status icon and content text:
//   completed   — green  checkmark.circle.fill  + strikethrough muted text
//   in_progress — orange arrow.trianglehead.2.clockwise + normal text
//   pending     — secondary circle              + muted text

import SwiftUI

public struct MotherTodoList: View {

    public let todos: [PeekTodo]

    public init(todos: [PeekTodo]) {
        self.todos = todos
    }

    public var body: some View {
        ForEach(todos.indices, id: \.self) { idx in
            todoRow(todos[idx])
        }
    }

    @ViewBuilder
    private func todoRow(_ todo: PeekTodo) -> some View {
        HStack(alignment: .top, spacing: 6) {
            statusIcon(for: todo.status)
                .frame(width: 16)
            Text(todo.content)
                .font(.caption)
                .foregroundStyle(todo.status == "completed" ? .secondary : .primary)
                .strikethrough(todo.status == "completed")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func statusIcon(for status: String) -> some View {
        switch status {
        case "completed":
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case "in_progress":
            Image(systemName: "arrow.trianglehead.2.clockwise")
                .font(.caption)
                .foregroundStyle(.orange)
        default:
            Image(systemName: "circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Preview

#Preview("Mixed statuses") {
    List {
        Section("Progress") {
            MotherTodoList(todos: [
                PeekTodo(status: "completed",   content: "Add Rust protocol variant"),
                PeekTodo(status: "in_progress", content: "Add NostromoKit wire types"),
                PeekTodo(status: "pending",     content: "Add iOS tab"),
                PeekTodo(status: "pending",     content: "Add macOS detail pane"),
            ])
        }
    }
}
