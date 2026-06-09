// Nostromo iOS — MotherQueueView.swift
//
// Phase 4: Mother job queue tab.  Shows running/queued/done jobs from the
// daemon's MotherJobs broadcast.  Tapping a job navigates to
// MotherJobDetailView for detail + action controls.

import SwiftUI
import NostromoKit

struct MotherQueueView: View {
    @EnvironmentObject var store: DaemonStore

    var body: some View {
        Group {
            if !store.connected {
                disconnectedView
            } else if store.motherJobs.isEmpty {
                emptyView
            } else {
                jobList
            }
        }
        .animation(.easeInOut(duration: 0.25), value: store.connected)
        .animation(.easeInOut(duration: 0.25), value: store.motherJobs.count)
    }

    // MARK: - Sub-views

    private var jobList: some View {
        List {
            let running = jobs(for: ["running", "awaiting"])
            let queued  = jobs(for: ["queued", "ready"])
            let done    = jobs(for: ["succeeded", "failed", "cancelled"])

            if !running.isEmpty {
                Section("Running") {
                    ForEach(running) { job in jobRow(job) }
                }
            }
            if !queued.isEmpty {
                Section("Queued") {
                    ForEach(queued) { job in jobRow(job) }
                }
            }
            if !done.isEmpty {
                Section("Done") {
                    ForEach(done) { job in jobRow(job) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            // Daemon pushes ~2s; no-op here.
        }
    }

    @ViewBuilder
    private func jobRow(_ job: MotherJob) -> some View {
        NavigationLink {
            MotherJobDetailView(job: job)
        } label: {
            NostromoKit.MotherJobRow(
                model: rowModel(for: job),
                onArchive:    { store.motherAction(jobId: job.id, action: "archive") },
                onCancel:     { store.motherAction(jobId: job.id, action: "cancel")  },
                onRetry:      {},
                onForceStart: {}
            )
        }
    }

    private func rowModel(for job: MotherJob) -> MotherJobRowModel {
        MotherJobRowModel(
            id: job.id,
            state: job.state,
            title: job.title.isEmpty ? job.id : job.title,
            repo: job.repo,
            branch: job.branch,
            relativeTimestamp: relativeTimestamp(for: job)
        )
    }

    /// Approximate relative timestamp from ISO-8601 string fields.
    private func relativeTimestamp(for job: MotherJob) -> String? {
        let ts = job.finishedAt ?? job.startedAt ?? job.createdAt
        guard let ts else { return nil }
        let fmtFrac  = ISO8601DateFormatter()
        fmtFrac.formatOptions  = [.withInternetDateTime, .withFractionalSeconds]
        let fmtBasic = ISO8601DateFormatter()
        fmtBasic.formatOptions = [.withInternetDateTime]
        guard let date = fmtFrac.date(from: ts) ?? fmtBasic.date(from: ts) else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

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
            Text("No Jobs")
                .font(.title2.weight(.semibold))
            Text("Mother's queue is empty.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - Helpers

    /// Jobs matching any of the given states, sorted newest-first by createdAt.
    private func jobs(for states: [String]) -> [MotherJob] {
        store.motherJobs
            .filter { states.contains($0.state) }
            .sorted { lhs, rhs in
                // Newest first; fall back to id ordering for stability.
                let l = lhs.createdAt ?? ""
                let r = rhs.createdAt ?? ""
                return l == r ? lhs.id > rhs.id : l > r
            }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        MotherQueueView()
            .navigationTitle("Queue")
            .environmentObject({
                let client = NetworkClient(host: "127.0.0.1", port: 47100)
                let store  = DaemonStore(client: client)
                return store
            }())
    }
}
