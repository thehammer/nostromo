// Nostromo iOS — FredView.swift
//
// Fred tab: mailbox + calendar from the daemon's fred_state broadcast.
// Mirrors MotherQueueView's structure but shows email and calendar sections
// instead of a job queue.

import SwiftUI
import NostromoKit

struct FredView: View {
    @EnvironmentObject var store: DaemonStore
    var onStartAgent: () -> Void = {}

    var body: some View {
        Group {
            if !store.connected {
                disconnectedView
            } else {
                contentList
            }
        }
        .animation(.easeInOut(duration: 0.25), value: store.connected)
    }

    // MARK: - Content

    private var contentList: some View {
        List {
            authBannerSection
            mailboxSection
            calendarSection
            startAgentSection
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Auth banner

    @ViewBuilder
    private var authBannerSection: some View {
        if let prompt = store.fredMailbox?.authPrompt {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Microsoft sign-in required", systemImage: "person.badge.key")
                        .font(.headline)
                        .foregroundStyle(.orange)

                    Text("Visit the URL below and enter the code to authenticate.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Link(prompt.verificationUri,
                         destination: URL(string: prompt.verificationUri)!)
                        .font(.caption)

                    HStack {
                        Text("Code:")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(prompt.userCode)
                            .font(.system(.title3, design: .monospaced).weight(.bold))
                            .foregroundStyle(.primary)
                    }

                    Text("Expires \(expiryText(prompt.expiresAt))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Mailbox section

    private var mailboxSection: some View {
        Section {
            if let snap = store.fredMailbox {
                if snap.items.isEmpty {
                    Text(snap.error != nil ? "Error loading mailbox" : "Inbox empty")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                } else {
                    ForEach(snap.items) { item in
                        NostromoKit.FredMailRow(
                            item: item,
                            relativeTime: relativeTime(for: item.receivedAt)
                        )
                    }
                }
            } else {
                Label("Loading mailbox…", systemImage: "arrow.clockwise")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
        } header: {
            Text("Mailbox")
        } footer: {
            if let err = store.fredMailbox?.error {
                Text(err)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Calendar section

    private var calendarSection: some View {
        Section {
            let events = (store.fredCalendar?.events ?? [])
                .sorted { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }

            if events.isEmpty {
                Text(store.fredCalendar?.error != nil ? "Error loading calendar" : "No events today")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                ForEach(events) { event in
                    NostromoKit.FredEventRow(
                        event: event,
                        timeRange: timeRange(start: event.start, end: event.end)
                    )
                }
            }
        } header: {
            Text("Today")
        } footer: {
            if let err = store.fredCalendar?.error {
                Text(err)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Start agent section

    private var startAgentSection: some View {
        Section {
            Button("Start Fred Agent") {
                onStartAgent()
            }
        }
    }

    // MARK: - Disconnected view

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

    // MARK: - Helpers

    private func relativeTime(for date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func timeRange(start: Date?, end: Date?) -> String? {
        guard let start else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        let startStr = fmt.string(from: start)
        if let end {
            return "\(startStr)–\(fmt.string(from: end))"
        }
        return startStr
    }

    private func expiryText(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        FredView()
            .navigationTitle("Fred")
            .environmentObject({
                let client = NetworkClient(host: "127.0.0.1", port: 47100)
                let store  = DaemonStore(client: client)
                return store
            }())
    }
}
