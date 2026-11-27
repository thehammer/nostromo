// Nostromo iOS — MergedQueueList.swift
//
// The Queue tab over the WebSocket transport: one merged list across Macs (Q8, PRD AC52, AC53).
// "Needs you" first, then recency. Every row carries its Mac's name only when the list holds rows
// from more than one Mac, or while the scope is a group of Macs (All, Work, Personal). It is
// read-only: no cancel, retry, answer or approve control (B10). A work host's row is a fixed phrase;
// tapping it opens a card that says where the details are. A satellite's held decision or approval
// is a row that says to answer it on the Mac. A Mac that is not connected shows its last-known rows
// dimmed, with when it was last seen.

import SwiftUI
import NostromoKit

struct MergedQueueList: View {
    @EnvironmentObject var store: DaemonStore

    var body: some View {
        // The phone's own Sessions tab shows the primary's sessions; this list adds every job and
        // the other Macs' sessions.
        let rows = store.mergedQueue(primaryName: HostNames.primary).filter { $0.kind == .job || $0.host != nil }
        content(rows)
            .safeAreaInset(edge: .top, spacing: 0) { HostScopePicker() }
    }

    @ViewBuilder
    private func content(_ rows: [MergedQueueRow]) -> some View {
        if rows.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "tray").font(.system(size: 48)).foregroundStyle(.secondary)
                Text("No jobs").font(.title3.weight(.semibold))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                let needsYou = rows.filter(\.needsYou)
                let rest = rows.filter { !$0.needsYou }
                if !needsYou.isEmpty {
                    Section("Needs you") { ForEach(needsYou) { row in rowLink(row) } }
                }
                if !rest.isEmpty {
                    Section(needsYou.isEmpty ? "" : "Everything else") { ForEach(rest) { row in rowLink(row) } }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    @ViewBuilder
    private func rowLink(_ row: MergedQueueRow) -> some View {
        if row.isMetadataOnly, let host = row.host {
            NavigationLink { WorkHostCardView(row: row, host: host) } label: { label(row) }
        } else if let job = row.job {
            NavigationLink { MotherJobDetailView(job: job) } label: { label(row) }
        } else {
            label(row)
        }
    }

    private func label(_ row: MergedQueueRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let badge = row.hostBadge {
                Text(badge).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(row.text).font(.body)
            if let footnote = row.footnote {
                Text(footnote).font(.caption).foregroundStyle(.secondary)
            }
            LastKnownCaption(text: row.lastKnownLabel)
        }
        .opacity(row.isLastKnown ? 0.55 : 1)
        .accessibilityElement(children: .combine)
    }
}

/// What a work host's row opens: the metadata it has, and where the rest stays (never a blank screen
/// or a spinner, and no request for content).
struct WorkHostCardView: View {
    let row: MergedQueueRow
    let host: String

    var body: some View {
        VStack(spacing: 16) {
            Text(row.text).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            Text(ReasonPhrases.detailsStayOn(host)).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(host)
        .navigationBarTitleDisplayMode(.inline)
    }
}
