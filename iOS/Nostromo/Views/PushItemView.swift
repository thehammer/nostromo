// Nostromo iOS — PushItemView.swift
//
// What a tapped notification opens (W13). It looks the item up over the VPN (`push_waiting`) and shows
// the Mother job, the decision or the PR it was about. Read-only: a decision says "Answer it on your
// Mac" (the phone answers nothing, B10, Q4, Q7). When the primary cannot be reached it still shows
// the kind, host and reference from the notification and says the machines are unreachable. It is
// never empty.

import SwiftUI
import NostromoKit

struct PushItemView: View {
    @EnvironmentObject var push: PushModel
    @EnvironmentObject var store: DaemonStore
    @Environment(\.dismiss) private var dismiss

    let payload: PushPayload

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("Kind", kindName)
                    row("Host", payload.host)
                    if let ref = payload.ref { row("Reference", ref) }
                }
                if payload.resolved {
                    Section { Text("This no longer needs you.") }
                } else if store.connectionState != .connected {
                    Section {
                        Label("Your machines are unreachable", systemImage: "wifi.slash")
                        Text("Details load over your VPN when it is up.").font(.footnote).foregroundStyle(.secondary)
                    }
                } else if !stillWaiting {
                    Section { Text("This no longer needs you.") }
                } else {
                    detail
                }
            }
            .navigationTitle(kindName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { push.requestWaiting() }
        }
    }

    private var kindName: String {
        switch payload.kind {
        case .mother: return "Mother"
        case .decision: return "Decision"
        case .review: return "Review"
        case .summary: return "Waiting for you"
        }
    }

    private var stillWaiting: Bool {
        payload.kind == .summary || push.waiting.contains { $0.itemRef == payload.item }
    }

    @ViewBuilder private var detail: some View {
        switch payload.kind {
        case .mother:
            Section("Mother") {
                Text("A job is waiting on an answer.")
                Text("Answer it on your Mac.").foregroundStyle(.secondary)
            }
        case .decision:
            Section("Decision") {
                Text("An agent is waiting on a decision.")
                Text("Answer it on your Mac.").font(.headline)
            }
        case .review:
            Section("Review") {
                Text("A pull request is waiting for your review.")
            }
        case .summary:
            Section("Waiting for you") {
                ForEach(push.waiting) { item in
                    HStack {
                        Text(item.ref ?? kindLabel(item.kind))
                        Spacer()
                        Text(item.host).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func kindLabel(_ kind: PushKindWire) -> String {
        switch kind {
        case .mother: return "Mother"
        case .decision: return "Decision"
        case .review: return "Review"
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}
