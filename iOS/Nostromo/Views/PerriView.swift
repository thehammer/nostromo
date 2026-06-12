// Nostromo iOS — PerriView.swift
//
// Perri PR review queue tab.  Shows the PR review queue (top) and the
// current-PR detail (below), driven by the daemon's `perri_state` broadcast
// via `DaemonStore.perriQueue` and `DaemonStore.perriCurrentPr`.
//
// Modelled after MotherQueueView.

import SwiftUI
import NostromoKit

struct PerriView: View {
    @EnvironmentObject var store: DaemonStore

    /// Staged pending approval — set on first swipe tap; cleared on cancel or
    /// after the confirmation's "Approve" button fires the actual request.
    /// Nothing is sent to GitHub until the user confirms.
    @State private var pendingApproval: PrQueueItem?

    var body: some View {
        Group {
            if !store.connected {
                disconnectedView
            } else if store.perriQueue.isEmpty && store.perriCurrentPr == nil {
                emptyView
            } else {
                contentList
            }
        }
        .animation(.easeInOut(duration: 0.25), value: store.connected)
        .animation(.easeInOut(duration: 0.25), value: store.perriQueue.count)
        // Confirmation gate — nothing reaches GitHub until the user taps "Approve" here.
        .confirmationDialog(
            pendingApproval.map { "Approve PR #\($0.number) in \($0.repo)?" } ?? "",
            isPresented: Binding(
                get:  { pendingApproval != nil },
                set:  { if !$0 { pendingApproval = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let item = pendingApproval {
                Button("Approve") {
                    store.perriApprove(number: item.number, repo: item.repo)
                    pendingApproval = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingApproval = nil
            }
        } message: {
            Text("The approval will be posted to GitHub. The PR will leave the queue once the index catches up.")
        }
    }

    // MARK: - Main content

    private var contentList: some View {
        List {
            if !store.perriQueue.isEmpty {
                queueSection
            }

            if let pr = store.perriCurrentPr {
                currentPrSection(pr)
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Queue section

    private var queueSection: some View {
        let buckets: [(label: String, key: String)] = [
            ("Requested",   "requested"),
            ("Needs Review","needs_review"),
            ("Changes Req", "changes_req"),
            ("Dependabot",  "dependabot"),
        ]

        return ForEach(buckets, id: \.key) { bucket in
            let items = store.perriQueue.filter { $0.bucket == bucket.key }
            if !items.isEmpty {
                Section(bucket.label) {
                    ForEach(items) { item in
                        NostromoKit.PerriPRRow(
                            model:   rowModel(for: item),
                            onLoad:  { store.perriLoadPr(number: item.number, repo: item.repo) },
                            onClear: { store.perriClear() }
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                // First tap only stages the approval — confirmation
                                // dialog fires before anything is sent to GitHub.
                                pendingApproval = item
                            } label: {
                                Label("Approve", systemImage: "checkmark.seal.fill")
                            }
                            .tint(.green)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Current-PR section

    @ViewBuilder
    private func currentPrSection(_ pr: PrSnapshot) -> some View {
        Section("Current PR") {
            VStack(alignment: .leading, spacing: 8) {
                // Title + metadata
                Text(pr.title)
                    .font(.headline)
                    .lineLimit(3)

                Text("\(pr.repo) #\(pr.prNumber.map(String.init) ?? "?") • \(pr.author)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Diff stats
                HStack(spacing: 16) {
                    Label("+\(pr.additions)", systemImage: "plus.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Label("-\(pr.deletions)", systemImage: "minus.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Label("\(pr.changedFiles) files", systemImage: "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // CI summary
                if !pr.ciChecks.isEmpty {
                    ciSummary(pr.ciChecks)
                }
            }
            .padding(.vertical, 4)

            // Diff or "too large" notice
            if pr.diffTooLarge {
                Text("Diff too large to display")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic()
            } else if !pr.diff.isEmpty {
                Text(pr.diff.prefix(4000))  // truncate; full syntax highlighting is out of scope
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(60)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func ciSummary(_ checks: [CiCheck]) -> some View {
        let passed  = checks.filter { $0.state == .success }.count
        let failed  = checks.filter { $0.state == .failure }.count
        let pending = checks.filter { $0.state == .pending }.count

        HStack(spacing: 12) {
            if passed > 0 {
                Label("\(passed) passed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }
            if pending > 0 {
                Label("\(pending) pending", systemImage: "clock.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
            if failed > 0 {
                Label("\(failed) failed", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
    }

    // MARK: - Empty / disconnected views

    private var disconnectedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "network.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Disconnected")
                .font(.title2.weight(.semibold))
            Text("Nostromo is trying to reconnect…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ProgressView()
        }
        .padding()
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No PRs")
                .font(.title2.weight(.semibold))
            Text("Perri's review queue is empty.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - Row model helper

    private func rowModel(for item: PrQueueItem) -> PerriPRRowModel {
        PerriPRRowModel(
            id:          item.id,
            number:      item.number,
            title:       item.title,
            repo:        item.repo,
            author:      item.author,
            bucket:      item.bucket,
            ciState:     item.ciState,
            newActivity: item.newActivity
        )
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        PerriView()
            .navigationTitle("Perri")
            .environmentObject({
                let client = NetworkClient(host: "127.0.0.1", port: 47100)
                let store  = DaemonStore(client: client)
                return store
            }())
    }
}
