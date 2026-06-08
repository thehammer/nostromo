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
            MotherJobRow(job: job)
        }
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

// MARK: - MotherJobRow

private struct MotherJobRow: View {
    let job: MotherJob

    var body: some View {
        HStack(spacing: 12) {
            stateCircle

            VStack(alignment: .leading, spacing: 2) {
                Text(job.title.isEmpty ? job.id : job.title)
                    .font(.headline)
                    .lineLimit(2)

                if let repoBranch = repoBranchLabel {
                    Text(repoBranch)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let ts = relativeTimestamp {
                Text(ts)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private var stateCircle: some View {
        Circle()
            .fill(stateColor)
            .frame(width: 10, height: 10)
            .padding(.top, 2)
    }

    private var stateColor: Color {
        switch job.state {
        case "running":           return .blue
        case "awaiting":          return .orange
        case "queued", "ready":   return .gray
        case "succeeded":         return .green
        case "failed":            return .red
        case "cancelled":         return .gray
        default:                  return .gray
        }
    }

    private var repoBranchLabel: String? {
        switch (job.repo, job.branch) {
        case (let r?, let b?): return "\(r) • \(b)"
        case (let r?, nil):    return r
        case (nil, let b?):    return b
        case (nil, nil):       return nil
        }
    }

    /// Approximate relative timestamp from ISO-8601 string.
    private var relativeTimestamp: String? {
        let ts = job.finishedAt ?? job.startedAt ?? job.createdAt
        guard let ts else { return nil }
        // Parse the ISO-8601 date and format relatively.
        let fmtFrac  = ISO8601DateFormatter()
        fmtFrac.formatOptions  = [.withInternetDateTime, .withFractionalSeconds]
        let fmtBasic = ISO8601DateFormatter()
        fmtBasic.formatOptions = [.withInternetDateTime]
        guard let date = fmtFrac.date(from: ts) ?? fmtBasic.date(from: ts) else {
            return nil
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
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
