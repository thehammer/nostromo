// Nostromo iOS — FocusListView.swift
//
// Shows the focuses of every Mac in the selected scope: the primary's first, then each satellite's
// (W11 slice 2), each grouped by org with live state badges joined to session state by tag. Tapping
// the primary's focus navigates to TranscriptView. A satellite's focus is read-only: it opens a
// small card that says to open it on that Mac. Everything is keyed by (host, tag).

import SwiftUI
import NostromoKit

struct FocusListView: View {
    @EnvironmentObject var store: DaemonStore

    /// A satellite's focus the operator tapped: read-only, so it opens a small card, not the focus.
    @State private var hostedSelection: HostedFocusSelection?

    var body: some View {
        let sections = store.focusSections(primaryName: HostNames.primary)
        Group {
            if !store.connected && !store.hasLastKnownContent {
                disconnectedView
            } else if sections.isEmpty {
                emptyView
            } else {
                focusList(sections)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: store.connected)
        .animation(.easeInOut(duration: 0.25), value: sections.map(\.rows.count))
        .safeAreaInset(edge: .top, spacing: 0) { HostScopePicker() }
        .sheet(item: $hostedSelection) { selection in
            HostedFocusSheet(selection: selection)
        }
    }

    // MARK: - Sub-views

    private func focusList(_ sections: [FocusHostSection]) -> some View {
        List {
            ForEach(sections) { section in
                if let title = section.title {
                    hostHeader(title, lastKnown: section.lastKnownLabel)
                }
                ForEach(section.rows) { row in
                    rowView(row, in: section)
                        .opacity(section.isLastKnown ? 0.55 : 1)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            store.refreshFocuses()
            store.refreshSessions()
        }
    }

    private func hostHeader(_ title: String, lastKnown: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline.weight(.bold))
            LastKnownCaption(text: lastKnown)
        }
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 2, trailing: 16))
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func rowView(_ row: NostromoKit.FocusRow, in section: FocusHostSection) -> some View {
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
            let session = section.sessions[meta.tag]
            let content = FocusRow(
                label: label,
                secondary: secondary,
                state: session?.state,
                alive: session?.alive
            )
            .listRowInsets(EdgeInsets(
                top: 6, leading: indented ? 32 : 16, bottom: 6, trailing: 16
            ))
            if section.host.isPrimary {
                NavigationLink {
                    DynamicFocusView(
                        tag:         meta.tag,
                        displayName: label,
                        agentName:   meta.agentName,
                        viewName:    meta.displayName,
                        client:      store.client
                    )
                    .environmentObject(store)
                } label: {
                    content
                }
            } else {
                // A satellite's focus is read-only here: no transcript, pane or terminal.
                Button {
                    hostedSelection = HostedFocusSelection(host: section.host.name, tag: meta.tag, label: label)
                } label: {
                    content
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows where to open this focus")
            }
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

// MARK: - Hosted focus card

/// A focus on a satellite that the operator tapped. `(host, tag)` identifies it: a tag can equal the
/// primary's.
struct HostedFocusSelection: Identifiable {
    let host: String
    let tag: String
    let label: String
    var id: String { "\(host)|\(tag)" }
}

/// What a satellite's focus opens in this version: nothing of its content, only where to find it.
private struct HostedFocusSheet: View {
    let selection: HostedFocusSelection
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            Text(selection.label).font(.headline).multilineTextAlignment(.center)
            Text("Open this focus on \(selection.host)")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .presentationDetents([.height(240)])
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
