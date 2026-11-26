// Nostromo iOS — PairingSuccessView.swift
//
// "Paired as <name>" for a moment: `AppSession` hands over to the tabs once the first Mother frame
// has arrived, or after 1.5 s, whichever is later. The name is the server's final one (a duplicate
// becomes "iPhone 2"). It says nothing else.

import SwiftUI

struct PairingSuccessView: View {
    let name: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("Paired as \(name)")
                .font(.title2.weight(.semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
