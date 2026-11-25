// Nostromo iOS — PairingErrorBanner.swift
//
// The pairing failure sentences, verbatim from `PairingCopy`, with the real address. The entered
// address and code stay in place below it, so Try Again is one tap. Local Network refused (D1) adds
// Open Settings and Try Again.

import SwiftUI
import NostromoKit

struct PairingErrorBanner: View {
    let failure: PairingFailure
    let address: String
    let kindName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(sentence, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            if failure == .localNetworkDenied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
        .accessibilityElement(children: .combine)
    }

    private var sentence: String {
        switch failure {
        case .expired: return PairingCopy.expired()
        case .invalid: return PairingCopy.invalid()
        case .unreachable, .notSaved: return PairingCopy.unreachable(address: address)
        case .localNetworkDenied: return PairingCopy.localNetworkDenied(address: address)
        }
    }
}
