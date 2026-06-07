// Nostromo iOS — FocusListView.swift
//
// Shows all daemon-hosted sessions as a list with live state badges.
// The state badge updates within ~1 s whenever the daemon pushes a
// `session_state` message (no polling).

import SwiftUI
import NostromoKit

struct FocusListView: View {
    @EnvironmentObject var store: DaemonStore

    var body: some View {
        Group {
            if !store.connected {
                disconnectedView
            } else if store.sessionList.isEmpty {
                emptyView
            } else {
                sessionList
            }
        }
        .animation(.easeInOut(duration: 0.25), value: store.connected)
        .animation(.easeInOut(duration: 0.25), value: store.sessionList.count)
    }

    // MARK: - Sub-views

    private var sessionList: some View {
        List(store.sessionList, id: \.tag) { session in
            SessionRow(session: session)
        }
        .listStyle(.insetGrouped)
        .refreshable {
            // Pull-to-refresh requests a fresh session list from the daemon.
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
            Text("No Sessions")
                .font(.title2.weight(.semibold))
            Text("Start a session on your Mac to see it here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

// MARK: - SessionRow

private struct SessionRow: View {
    let session: SessionInfo

    var body: some View {
        HStack(spacing: 12) {
            // State badge
            stateBadge

            // Session info
            VStack(alignment: .leading, spacing: 2) {
                Text(session.viewName.isEmpty ? session.tag : session.viewName)
                    .font(.headline)
                Text(session.tag)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Alive indicator
            if !session.alive {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .imageScale(.small)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Badge

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
        guard session.alive else { return .gray }
        switch session.state {
        case .idle:                return .green
        case .midTurn:             return .blue
        case .awaitingPermission:  return .orange
        case .crashed:             return .red
        }
    }

    private var badgeIcon: String {
        guard session.alive else { return "stop.circle" }
        switch session.state {
        case .idle:                return "checkmark.circle"
        case .midTurn:             return "bolt.circle"
        case .awaitingPermission:  return "questionmark.circle"
        case .crashed:             return "xmark.circle"
        }
    }
}

// MARK: - Preview

#Preview {
    FocusListView()
        .environmentObject({
            let client = NetworkClient(host: "127.0.0.1", port: 47100)
            return DaemonStore(client: client)
        }())
}
