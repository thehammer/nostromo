// Nostromo iOS — FredView.swift
//
// Fred tab. In v1 mail, calendar and todos stay on the Mac for every device, with no way to turn
// sharing on (Q2, PRD AC34, AC56), so this tab only says so: no spinner, no empty list that looks
// like "no mail".

import SwiftUI
import NostromoKit

struct FredView: View {
    var body: some View { NotSharedView() }
}

/// The Q2 line, shared by the Fred and Teri tabs.
struct NotSharedView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(PairingCopy.notShared)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // One VoiceOver element: the sentence.
        .accessibilityElement(children: .combine)
    }
}
