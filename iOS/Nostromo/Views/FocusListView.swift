// Nostromo iOS — FocusListView.swift
//
// Shows all daemon-served focuses grouped by org, with live state badges
// joined to session state by tag.  Tapping a focus navigates to TranscriptView.

import SwiftUI
import NostromoKit

struct FocusListView: View {
    @EnvironmentObject var store: DaemonStore

    var body: some View {
        Group {
            if !store.connected {
                disconnectedView
            } else if store.focusRows.isEmpty {
                emptyView
            } else {
                focusList
            }
        }
        .animation(.easeInOut(duration: 0.25), value: store.connected)
        .animation(.easeInOut(duration: 0.25), value: store.focusRows.count)
    }

    // MARK: - Sub-views

    private var focusList: some View {
        List {
            ForEach(store.focusRows) { row in
                switch row {
                case .orgHeader(let title):
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))

                case .repoHeader(let title):
                    Text(title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 2, trailing: 16))

                case .focus(let meta, let label, let secondary, let indented):
                    let session = store.sessions[meta.tag]
                    NavigationLink {
                        TranscriptView(tag: meta.tag, displayName: label, client: store.client)
                    } label: {
                        FocusRow(
                            label: label,
                            secondary: secondary,
                            state: session?.state,
                            alive: session?.alive
                        )
                        .listRowInsets(EdgeInsets(
                            top: 6, leading: indented ? 32 : 16, bottom: 6, trailing: 16
                        ))
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            store.refreshFocuses()
            store.refreshSessions()
        }
    }

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
            Text("No Focuses")
                .font(.title2.weight(.semibold))
            Text("Start a session on your Mac to see it here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

// MARK: - FocusRow

private struct FocusRow: View {
    let label:     String
    let secondary: String?
    let state:     SessionState?
    let alive:     Bool?

    var body: some View {
        HStack(spacing: 12) {
            stateBadge

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.headline)
                if let secondary {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if alive == false {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .imageScale(.small)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var stateBadge: some View {
        ZStack {
            Circle()
                .fill(badgeColor.opacity(0.18))
                .frame(width: 40, height: 40)
            Image(systemName: badgeIcon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(badgeColor)
        }
    }

    private var badgeColor: Color {
        guard alive != false else { return .gray }
        switch state {
        case .idle:                return .green
        case .midTurn:             return .blue
        case .awaitingPermission:  return .orange
        case .crashed:             return .red
        case nil:                  return .gray
        }
    }

    private var badgeIcon: String {
        guard alive != false else { return "stop.circle" }
        switch state {
        case .idle:                return "checkmark.circle"
        case .midTurn:             return "bolt.circle"
        case .awaitingPermission:  return "questionmark.circle"
        case .crashed:             return "xmark.circle"
        case nil:                  return "circle.dashed"
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        FocusListView()
            .environmentObject({
                let client = NetworkClient(host: "127.0.0.1", port: 47100)
                return DaemonStore(client: client)
            }())
    }
}
