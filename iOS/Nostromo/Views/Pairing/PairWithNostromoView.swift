// Nostromo iOS — PairWithNostromoView.swift
//
// The first screen with no pairing: the title, the instruction, Scan Code and Enter Code Instead,
// and nothing else (PRD-AC1). It asks for no permission: the camera is requested only when the
// scanner appears, and iOS's Local Network question only after a scan or a typed submit.
// With a hardware keyboard, Return activates Enter Code Instead and a typed digit starts the code.

import SwiftUI
import NostromoKit

struct PairWithNostromoView: View {
    let onScan: () -> Void
    let onEnterCode: () -> Void
    /// A digit typed on a hardware keyboard: jump into the code field with it.
    let onDigit: (String) -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Text(PairingCopy.title)
                .font(.largeTitle.weight(.bold))
            Text(PairingCopy.instructions)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            VStack(spacing: 12) {
                Button(action: onScan) {
                    Text("Scan Code").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(action: onEnterCode) {
                    Text("Enter Code Instead").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .focusable()
        .onKeyPress(characters: .decimalDigits) { press in
            onDigit(press.characters)
            return .handled
        }
    }
}
