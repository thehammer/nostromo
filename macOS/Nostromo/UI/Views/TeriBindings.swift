import AppKit
import NostromoKit
import SwiftUI

/// The Teri lane's glue to the app: builds the native surface the daemon's
/// `teri_surface` pane maps to (see `DynamicFocusView.makeLeafView`).
enum TeriBindings {
    static func makeSurface(focus: Focus) -> NSView {
        let host = NSHostingView(rootView: TeriTodosPanel())
        host.translatesAutoresizingMaskIntoConstraints = false
        return host
    }
}

// MARK: - TeriTodosPanel (SwiftUI list inside NSHostingView)

/// SwiftUI todos list rendered inside the Teri's native `teri_surface` pane.
struct TeriTodosPanel: View {
    @ObservedObject private var store = AppStore.shared

    var body: some View {
        VStack(spacing: 0) {
            // Panel header
            HStack {
                Text("Todos")
                    .font(.headline)
                Spacer()
                if store.teriTodos?.stale == true {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            if let err = store.teriTodos?.error {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }

            if items.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No Todos")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                List {
                    ForEach(items) { todo in
                        NostromoKit.TeriTodoRow(model: rowModel(for: todo))
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    /// Active todos sorted by priority ASC, then nulls-last on due_date, then due_date ASC.
    private var items: [TeriTodo] {
        guard let snap = store.teriTodos else { return [] }
        return snap.items.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            switch (lhs.dueDate, rhs.dueDate) {
            case (nil, nil):       return false
            case (nil, _):         return false
            case (_, nil):         return true
            case (let l?, let r?): return l < r
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
