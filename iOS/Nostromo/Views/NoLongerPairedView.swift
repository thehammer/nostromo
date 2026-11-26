// Nostromo iOS — NoLongerPairedView.swift
//
// Full screen after the server said this device is not (or no longer) paired. By the time this
// renders, `AppSession` has cleared the credential and wiped the content (PRD-AC27). Pair Again goes
// to the pairing screen with the address filled in (PRD-AC30, AC32).

import SwiftUI
import NostromoKit

struct NoLongerPairedView: View {
    let kindName: String
    let onPairAgain: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "link.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(PairingCopy.noLongerPaired(kind: kindName))
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Spacer()
            Button(action: onPairAgain) {
                Text("Pair Again").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(24)
    }
}
