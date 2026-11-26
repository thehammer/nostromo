// Nostromo iOS — MissedUpdatesBanner.swift
//
// "Updates may have been missed — pull to refresh" over a list whose topic the daemon reported a
// `gap` for (W12): frames were dropped for this connection (it read too slowly, or the daemon's
// replay window no longer reached back to where it left off). Tapping Refresh starts the
// subscription over; so does pulling the list.

import SwiftUI
import NostromoKit

struct MissedUpdatesBanner: View {
    @EnvironmentObject var store: DaemonStore
    let topics: Set<String>

    var body: some View {
        if MissedUpdatesNotice.isDue(for: topics, missed: store.missedUpdates) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.clockwise.circle")
                Text(MissedUpdatesNotice.text).font(.footnote)
                Spacer(minLength: 4)
                Button("Refresh") { store.refreshMissedUpdates() }
                    .font(.footnote.weight(.semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.25))
            .accessibilityElement(children: .combine)
        }
    }
}
