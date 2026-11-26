// Nostromo iOS — NotificationSettingsView.swift
//
// Notification settings (W13): per-kind switches, quiet hours, the evening summary, the host classes
// and work owners (read-only: only a shell on the primary changes them), a link to iOS Settings when
// notifications are denied, and the Sent notifications list. Plus the banner the root view shows when
// notifications are not getting through.

import SwiftUI
import UserNotifications
import NostromoKit

struct NotificationSettingsView: View {
    @EnvironmentObject var push: PushModel
    @EnvironmentObject var store: DaemonStore
    @State private var authorization: UNAuthorizationStatus = .notDetermined

    var body: some View {
        Form {
            authorizationSection
            prefsSaveSection
            Section("Notify me about") {
                ForEach(PushKindWire.allCases, id: \.self) { kind in
                    Toggle(title(kind), isOn: Binding(
                        get: { push.prefs.kinds.enabled(kind) },
                        set: { value in push.update { $0.kinds.set(kind, to: value) } }))
                }
            }
            Section("Quiet hours") {
                Toggle("Quiet hours", isOn: Binding(
                    get: { push.prefs.quiet.enabled }, set: { value in push.update { $0.quiet.enabled = value } }))
                DatePicker("From", selection: time(\.quiet.start), displayedComponents: .hourAndMinute)
                DatePicker("Until", selection: time(\.quiet.end), displayedComponents: .hourAndMinute)
                Text("Nothing alerts during quiet hours. A summary arrives when they end if something still waits.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Evening summary") {
                Toggle("Evening summary", isOn: Binding(
                    get: { push.prefs.eveningSummary != nil },
                    set: { value in push.update { $0.eveningSummary = value ? "17:30" : nil } }))
                if push.prefs.eveningSummary != nil {
                    DatePicker("At", selection: eveningTime, displayedComponents: .hourAndMinute)
                }
            }
            hostsSection
            Section {
                Text("For private lock screens, set Show Previews to When Unlocked in iOS Settings.")
                    .font(.footnote).foregroundStyle(.secondary)
                NavigationLink("Sent notifications") { SentNotificationsView() }
            }
        }
        .navigationTitle("Notifications")
        .task { authorization = await PushCoordinator.shared.authorization() }
        .onAppear { push.requestWaiting() }
    }

    @ViewBuilder private var authorizationSection: some View {
        switch authorization {
        case .denied:
            Section {
                Text("Notifications are turned off for Nostromo in iOS.")
                Button("Open iOS Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        case .notDetermined:
            Section {
                Button("Turn on notifications") {
                    Task {
                        _ = await PushCoordinator.shared.enable()
                        authorization = await PushCoordinator.shared.authorization()
                    }
                }
            }
        default:
            EmptyView()
        }
    }

    /// An edit the primary has not kept stays as typed, with the reason it is not saved yet.
    @ViewBuilder private var prefsSaveSection: some View {
        switch push.prefsSave {
        case .saved:
            EmptyView()
        case .pending:
            Section {
                Label("Not saved yet. It will save when your Mac is reachable.", systemImage: "clock")
                    .font(.footnote)
            }
        case .failed:
            Section {
                Label("Your Mac did not keep these settings. They will be sent again.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
            }
        }
    }

    @ViewBuilder private var hostsSection: some View {
        if let status = push.status {
            Section("Machines") {
                let classes = status.hostClasses
                let seen = store.hostInfos.map(\.name)
                ForEach(Array(Set(seen + classes.keys)).sorted(), id: \.self) { host in
                    HStack {
                        Text(host)
                        Spacer()
                        if classes[host] == .personal {
                            Text("Personal").foregroundStyle(.secondary)
                        } else {
                            Text("Details stay on \(host)").foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Which machines are personal, and which owners count as work, is set on the primary.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Work owners") {
                ForEach(status.workOwners, id: \.self) { Text($0) }
            }
        }
    }

    private func title(_ kind: PushKindWire) -> String {
        switch kind {
        case .mother: return "Mother jobs"
        case .decision: return "Decisions"
        case .review: return "Reviews"
        }
    }

    // `HH:MM` strings on the wire, a Date for the picker.
    private func time(_ keyPath: WritableKeyPath<PushPrefsWire, String>) -> Binding<Date> {
        Binding(
            get: { Self.date(from: push.prefs[keyPath: keyPath]) },
            set: { date in push.update { $0[keyPath: keyPath] = Self.hhmm(date) } })
    }

    private var eveningTime: Binding<Date> {
        Binding(
            get: { Self.date(from: push.prefs.eveningSummary ?? "17:30") },
            set: { date in push.update { $0.eveningSummary = Self.hhmm(date) } })
    }

    private static func date(from hhmm: String) -> Date {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        var c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        c.hour = parts.first ?? 0
        c.minute = parts.count > 1 ? parts[1] : 0
        return Calendar.current.date(from: c) ?? Date()
    }

    private static func hhmm(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

/// Shown above the tabs when notifications have not been deliverable for more than 15 minutes.
struct PushDeliveryBanner: View {
    @ObservedObject var push: PushModel

    var body: some View {
        if let text = PushModel.bannerText(failingSince: push.status?.failingSince, now: Date()) {
            HStack(spacing: 8) {
                Image(systemName: "bell.slash")
                Text(text).font(.footnote)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.2))
            .accessibilityElement(children: .combine)
        }
    }
}
