// Nostromo iOS — MotherJobDetailView.swift
//
// Phase 4: Detail view for a single Mother job.
// Shows metadata, timestamps, PR link, and action controls
// (cancel / retry / force-start) appropriate to the job's current state.
//
// Phase 5: Adds an answer UI for awaiting jobs — shows the question text and
// a submit control so the operator can resume the job from the phone.

import SwiftUI
import NostromoKit

struct MotherJobDetailView: View {
    let job: MotherJob
    @EnvironmentObject var store: DaemonStore

    @State private var showCancelConfirm     = false
    @State private var showRetryConfirm      = false
    @State private var showForceStartConfirm = false
    @State private var answerText            = ""

    var body: some View {
        Form {
            // MARK: Identity
            Section("Job") {
                LabeledContent("Title", value: job.title.isEmpty ? job.id : job.title)
                LabeledContent("State") {
                    Text(job.state.capitalized)
                        .foregroundStyle(stateColor)
                        .fontWeight(.semibold)
                }
                LabeledContent("ID", value: job.id)
            }

            // MARK: Repository
            if job.repo != nil || job.branch != nil {
                Section("Repository") {
                    if let repo = job.repo {
                        LabeledContent("Repo", value: repo)
                    }
                    if let branch = job.branch {
                        LabeledContent("Branch", value: branch)
                    }
                }
            }

            // MARK: Timestamps
            let timestamps = timestampRows
            if !timestamps.isEmpty {
                Section("Timestamps") {
                    ForEach(timestamps, id: \.0) { label, value in
                        LabeledContent(label, value: value)
                    }
                }
            }

            // MARK: PR Link
            if let prUrl = job.prUrl, let url = URL(string: prUrl) {
                Section("Pull Request") {
                    Link("Open PR", destination: url)
                }
            }

            // MARK: Live progress (running + awaiting only)
            if (job.state == "running" || job.state == "awaiting"),
               let peek = store.motherPeeks[job.id],
               !peek.todos.isEmpty {
                Section("Progress") {
                    NostromoKit.MotherTodoList(todos: peek.todos)
                }
            }

            // MARK: Await Question (awaiting state only)
            if job.state == "awaiting" {
                Section("Question") {
                    Text(job.question ?? "This job is waiting for your input.")
                        .foregroundStyle(.primary)
                    TextField("Your answer…", text: $answerText, axis: .vertical)
                        .lineLimit(3...)
                    Button("Submit Answer") {
                        store.motherResume(jobId: job.id, answer: answerText)
                        answerText = ""
                    }
                    .disabled(answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            // MARK: Actions
            let actions = availableActions
            if !actions.isEmpty {
                Section("Actions") {
                    ForEach(actions, id: \.0) { label, color, confirmKey in
                        Button(label, role: color == Color.red ? .destructive : .none) {
                            switch confirmKey {
                            case "cancel":      showCancelConfirm     = true
                            case "retry":       showRetryConfirm      = true
                            case "force_start": showForceStartConfirm = true
                            default:            break
                            }
                        }
                        .foregroundStyle(color)
                    }
                }
            }
        }
        .navigationTitle(job.title.isEmpty ? job.id : job.title)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Cancel job?",
            isPresented: $showCancelConfirm,
            titleVisibility: .visible
        ) {
            Button("Cancel Job", role: .destructive) {
                store.motherAction(jobId: job.id, action: "cancel")
            }
            Button("Dismiss", role: .cancel) {}
        } message: {
            Text("The job will be stopped and marked cancelled.")
        }
        .confirmationDialog(
            "Retry job?",
            isPresented: $showRetryConfirm,
            titleVisibility: .visible
        ) {
            Button("Retry") {
                store.motherAction(jobId: job.id, action: "retry")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The job will be re-queued for another attempt.")
        }
        .confirmationDialog(
            "Force-start job?",
            isPresented: $showForceStartConfirm,
            titleVisibility: .visible
        ) {
            Button("Force Start") {
                store.motherAction(jobId: job.id, action: "force_start")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The job will be started immediately, skipping the queue cap.")
        }
    }

    // MARK: - Helpers

    private var stateColor: Color {
        switch job.state {
        case "running":           return .blue
        case "awaiting":          return .orange
        case "queued", "ready":   return .gray
        case "succeeded":         return .green
        case "failed":            return .red
        case "cancelled":         return .gray
        default:                  return .primary
        }
    }

    private var timestampRows: [(String, String)] {
        var rows: [(String, String)] = []
        if let ts = job.createdAt  { rows.append(("Created",  formattedDate(ts))) }
        if let ts = job.startedAt  { rows.append(("Started",  formattedDate(ts))) }
        if let ts = job.finishedAt { rows.append(("Finished", formattedDate(ts))) }
        return rows
    }

    /// Returns (label, color, actionKey) tuples for actions valid in this state.
    private var availableActions: [(String, Color, String)] {
        switch job.state {
        case "running", "awaiting":
            return [("Cancel Job", .red, "cancel")]
        case "queued", "ready":
            return [
                ("Cancel Job",   .red,     "cancel"),
                ("Force Start",  .primary, "force_start"),
            ]
        case "failed", "cancelled":
            return [("Retry", .primary, "retry")]
        default:
            return []
        }
    }

    private func formattedDate(_ iso: String) -> String {
        let fmtFrac  = ISO8601DateFormatter()
        fmtFrac.formatOptions  = [.withInternetDateTime, .withFractionalSeconds]
        let fmtBasic = ISO8601DateFormatter()
        fmtBasic.formatOptions = [.withInternetDateTime]
        guard let date = fmtFrac.date(from: iso) ?? fmtBasic.date(from: iso) else {
            return iso
        }
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        return df.string(from: date)
    }
}

// MARK: - Preview

#Preview("Running job") {
    NavigationStack {
        MotherJobDetailView(job: MotherJob(
            id: "preview-job",
            state: "running",
            title: "Build the auth flow in admin portal",
            repo: "admin-portal",
            branch: "feature/auth",
            prUrl: nil,
            createdAt: "2026-06-07T10:00:00Z",
            startedAt: "2026-06-07T10:01:00Z",
            finishedAt: nil
        ))
        .environmentObject({
            let client = NetworkClient(host: "127.0.0.1", port: 47100)
            return DaemonStore(client: client)
        }())
    }
}

#Preview("Awaiting answer") {
    NavigationStack {
        MotherJobDetailView(job: MotherJob(
            id: "await-job",
            state: "awaiting",
            title: "Migrate user schema",
            repo: "core",
            branch: "feature/user-schema",
            prUrl: nil,
            createdAt: "2026-06-07T10:00:00Z",
            startedAt: "2026-06-07T10:01:00Z",
            finishedAt: nil,
            question: "The migration adds a NOT NULL column to a 50M-row table. Should I use a backfill default or a nullable-then-backfill approach?"
        ))
        .environmentObject({
            let client = NetworkClient(host: "127.0.0.1", port: 47100)
            return DaemonStore(client: client)
        }())
    }
}
