// Nostromo iOS — UnreachableBanner.swift
//
// The banner over last-known content when the server cannot be reached (PRD-AC22), or when iOS's
// Local Network permission blocks the address (D1). Neither ever moves the app to the pairing screen.

import SwiftUI
import NostromoKit

struct ConnectionBanner: View {
    @EnvironmentObject var store: DaemonStore
    @EnvironmentObject var session: AppSession

    var body: some View {
        switch store.connectionState {
        case .unreachable:
            banner(PairingCopy.unreachableBanner(address: session.serverAddress), settings: false)
        case .localNetworkDenied:
            banner(PairingCopy.localNetworkBanner(address: session.serverAddress), settings: true)
        case .connecting, .connected, .notPaired:
            EmptyView()
        }
    }

    private func banner(_ text: String, settings: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
            Text(text).font(.footnote)
            if settings {
                Spacer(minLength: 4)
                Button("Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .font(.footnote.weight(.semibold))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.2))
        .accessibilityElement(children: .combine)
    }
}
