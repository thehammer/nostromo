// Nostromo iOS — PerriView.swift
//
// Perri PR review queue tab.  Shows the PR review queue (top) and the
// current-PR detail (below), driven by the daemon's `perri_state` broadcast
// via `DaemonStore.perriQueue` and `DaemonStore.perriCurrentPr`.
//
// `perriCurrentPr` is per-focus (W7/W8) — this tab is the built-in "perri"
// focus's own global view (not a per-focus DynamicFocusView), so it reads
// that one focus's entry (`store.perriCurrentPr(for: "perri")`) rather than
// picking one arbitrarily out of the per-tag dictionary. Redesigning this
// tab for isolation (e.g. so it shows every focus's PR) is a separate
// question the W8 plan explicitly leaves alone (D8).
//
// Modelled after MotherQueueView.

import SwiftUI
import NostromoKit

struct PerriView: View {
    @EnvironmentObject var store: DaemonStore

    /// The built-in Perri focus's session tag — this tab's one, hardcoded
    /// identity (D8). See this file's top doc comment for why.
    private static let builtInTag = "perri"

    /// Staged pending approval — set on first swipe tap; cleared on cancel or
    /// after the confirmation's "Approve" button fires the actual request.
    /// Nothing is sent to GitHub until the user confirms.
    @State private var pendingApproval: PrQueueItem?

    var body: some View {
        let hosted = store.perriSections(primaryName: HostNames.primary)
        let showsPrimary = store.showsPrimary(primaryName: HostNames.primary)
        let primaryHasContent = showsPrimary
            && !(store.perriQueue.isEmpty && store.perriCurrentPr(for: Self.builtInTag) == nil)
        Group {
            if !store.connected && !store.hasLastKnownContent {
                disconnectedView
            } else if !primaryHasContent && hosted.isEmpty {
                emptyView
            } else {
                contentList(hosted: hosted, showsPrimary: primaryHasContent)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: store.connected)
        .animation(.easeInOut(duration: 0.25), value: store.perriQueue.count)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                HostScopePicker()
                MissedUpdatesBanner(topics: MissedUpdatesNotice.perriTopics)
            }
        }
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

    private func contentList(hosted: [PerriHostSection], showsPrimary: Bool) -> some View {
        // The primary's headings carry its name once another Mac is on the list or the scope is a group.
        let scope = store.effectiveScope(primaryName: HostNames.primary)
        let primaryTitle = (!hosted.isEmpty || !scope.isSingleHost) ? HostNames.primary : nil
        return List {
            if showsPrimary {
                if !store.perriQueue.isEmpty {
                    queueSection(title: primaryTitle)
                }

                if let pr = store.perriCurrentPr(for: Self.builtInTag) {
                    currentPrSection(pr)
                }
            }

            ForEach(hosted) { section in
                hostedSections(section)
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - A satellite's queue (read-only)

    @ViewBuilder
    private func hostedSections(_ section: PerriHostSection) -> some View {
        ForEach(section.groups) { group in
            Section {
                ForEach(group.rows) { row in
                    HostedPerriRowView(row: row)
                        .opacity(section.isLastKnown ? 0.55 : 1)
                }
            } header: {
                Text([section.title, group.label].compactMap { $0 }.joined(separator: " · "))
            } footer: {
                if let label = section.lastKnownLabel { Text(label) }
            }
        }
    }

    // MARK: - Queue section

    private func queueSection(title: String?) -> some View {
        let buckets: [(label: String, key: String)] = [
            ("Requested",   "requested"),
            ("Needs Review","needs_review"),
            ("Changes Req", "changes_req"),
            ("Dependabot",  "dependabot"),
        ]

        return ForEach(buckets, id: \.key) { bucket in
            let items = store.perriQueue.filter { $0.bucket == bucket.key }
            if !items.isEmpty {
                Section([title, bucket.label].compactMap { $0 }.joined(separator: " · ")) {
                    ForEach(items, id: \.bucketScopedId) { item in
                        NostromoKit.PerriPRRow(
                            model:   rowModel(for: item),
                            onLoad:  { store.perriLoadPr(number: item.number, repo: item.repo) },
                            onClear: { store.perriClear() },
                            actionsEnabled: store.canMutate
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            // Approve, Load and Clear change the Mac's Perri state: not offered
                            // when the transport cannot send them (WebSocket).
                            if store.canMutate {
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

    // Deliberately no `marked:` here (unlike PaneSurfaceView's `pr_list`
    // rows — W2, ios-curated-view-parity). This tab's queue is not a pane:
    // it has no `PaneAddress` to mark *from*. Giving it one would mean
    // inventing a second addressing path for the same queue, which is the
    // disagreeing-renderers problem this PRD family exists to end.
    // Reconciling iOS's three PR renderings is out of scope for this wedge.
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

// MARK: - A satellite's PR row

/// One PR from a satellite's queue, read-only: no approve, load or clear. It shows the fields the
/// frame carried (a title, or the fixed `PR #N` line when the host sent none). Its GitHub link is
/// offered only for a real URL, never for a pseudonymous row.
private struct HostedPerriRowView: View {
    let row: HostedPerriRow

    var body: some View {
        if let url = row.url {
            Link(destination: url) { content }
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.text).font(.body)
            if let secondary = row.secondary {
                Text(secondary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
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
