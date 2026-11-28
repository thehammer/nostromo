// Nostromo iOS — HostScopePicker.swift
//
// The one control that says whose content the Focuses, Perri and Queue tabs show: All, Work,
// Personal, or one Mac by name (W11 slice 2). The selection lives in `DaemonStore` (persisted), so
// every tab shows the same one. A compact menu: it fits an iPhone's width and an iPad's, in either
// size class. Hidden while there is only one Mac, since there is nothing to choose between.
//
// Read-only like the rest of the phone: choosing a scope changes what is drawn, nothing is sent.

import SwiftUI
import NostromoKit

/// What the primary's own rows are called when a Mac name is shown. The server sends no label for
/// itself, so this is the phone's word for it.
enum HostNames {
    static let primary = "This Mac"
}

struct HostScopePicker: View {
    @EnvironmentObject var store: DaemonStore

    var body: some View {
        let hosts = store.hostEntries(primaryName: HostNames.primary)
        if hosts.count > 1 {
            let options = HostScopeOptions.options(for: hosts)
            HStack {
                Label("Show", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Picker("Show", selection: Binding(
                    get: { store.effectiveScope(primaryName: HostNames.primary) },
                    set: { store.selectScope($0) }
                )) {
                    ForEach(options, id: \.self) { scope in
                        Text(HostScopeOptions.label(for: scope))
                            .accessibilityLabel(HostScopeOptions.accessibilityLabel(for: scope))
                            .tag(scope)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("Which Macs to show")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }
}

/// The line under a Mac's name when it is not connected: when it was last heard from.
struct LastKnownCaption: View {
    let text: String?

    var body: some View {
        if let text {
            Text(text).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
