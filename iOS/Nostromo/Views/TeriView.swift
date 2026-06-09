// Nostromo iOS — TeriView.swift
//
// Teri todos tab.  Shows active todos from the daemon's TeriState broadcast.
// Todos are sorted by priority ASC, then nulls-last on due_date, then due_date ASC,
// mirroring the SQL ORDER BY in TeriTodosNativeSource.

import SwiftUI
import NostromoKit

struct TeriView: View {
    @EnvironmentObject var store: DaemonStore

    var body: some View {
        Group {
            if !store.connected {
                disconnectedView
            } else if items.isEmpty {
                emptyView
            } else {
                todoList
            }
        }
        .animation(.easeInOut(duration: 0.25), value: store.connected)
        .animation(.easeInOut(duration: 0.25), value: items.count)
    }

    // MARK: - Sub-views

    private var todoList: some View {
        List {
            if let err = store.teriTodos?.error {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                ForEach(items) { todo in
                    NostromoKit.TeriTodoRow(model: rowModel(for: todo))
                }
            }
        }
        .listStyle(.insetGrouped)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                startButton
            }
        }
    }

    private var startButton: some View {
        Button {
            showStartAlert = true
        } label: {
            Image(systemName: "play.circle")
        }
        .alert("Use Mac App", isPresented: $showStartAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Use the Mac app to drive the Teri REPL and manage todos interactively.")
        }
    }

    @State private var showStartAlert = false

    private var disconnectedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "network.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Disconnected")
                .font(.title2.weight(.semibold))
            Text("Nostromo is trying to reconnect…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ProgressView()
        }
        .padding()
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Todos")
                .font(.title2.weight(.semibold))
            Text("Teri's todo list is empty.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - Helpers

    /// Active todos sorted by priority ASC, then nulls-last on due_date, then due_date ASC.
    /// Mirrors the SQL order in TeriTodosNativeSource.
    private var items: [TeriTodo] {
        guard let snap = store.teriTodos else { return [] }
        return snap.items.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            switch (lhs.dueDate, rhs.dueDate) {
            case (nil, nil):          return false
            case (nil, _):            return false   // nil → pushed to end
            case (_, nil):            return true
            case (let l?, let r?):    return l < r
            }
        }
    }

    private func rowModel(for todo: TeriTodo) -> TeriTodoRowModel {
        TeriTodoRowModel(
            id:          todo.id,
            title:       todo.title,
            priority:    todo.priority,
            jiraKey:     todo.jiraKey,
            relativeDue: relativeDue(for: todo.dueDate),
            rawDueDate:  todo.dueDate
        )
    }

    /// Format an ISO date string (yyyy-MM-dd) to a relative string.
    /// Falls back to the raw string if parsing fails.
    private func relativeDue(for dateStr: String?) -> String? {
        guard let dateStr else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone   = .gmt
        guard let date = fmt.date(from: dateStr) else { return nil }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .abbreviated
        return rel.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        TeriView()
            .navigationTitle("Teri")
            .environmentObject({
                let client = NetworkClient(host: "127.0.0.1", port: 47100)
                let store  = DaemonStore(client: client)
                return store
            }())
    }
}
