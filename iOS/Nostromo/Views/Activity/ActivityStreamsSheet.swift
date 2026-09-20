// Nostromo iOS — ActivityStreamsSheet.swift
//
// The expanded view behind the ticker (ios-curated-view-parity W4, D5): one
// row per agent stream — the main stream plus each subagent, labelled by
// `agentType`, running vs finished visibly distinguished.
//
// A `.sheet` rather than a taller panel: a phone has no window to overlay,
// and a sheet doesn't change the layout underneath it, which is how
// "expanding it doesn't change the frontmost tab or the transcript's scroll
// position" becomes true by construction rather than by testing. Presented
// from `DynamicFocusView` (the focus view) — never from `TranscriptView` or
// `PaneSurfaceView` — so it survives whatever those are doing (tab
// switches, rotation) without disappearing underneath the operator.
//
// D6: reads only `summary`, `agent`, `agentType`, `kind` — never
// `toolInput`, `cwd`, or `toolUseId`.

import SwiftUI
import NostromoKit

struct ActivityStreamsSheet: View {
    let model: ActivityStreamModel

    var body: some View {
        NavigationStack {
            List {
                if let main = model.mainStream {
                    Section("Main") {
                        AgentStreamRow(stream: main)
                    }
                }

                let subagents = model.subagentStreams
                if !subagents.isEmpty {
                    Section("Subagents") {
                        ForEach(subagents, id: \.agentId) { sub in
                            AgentStreamRow(stream: sub)
                        }
                    }
                }

                if model.mainStream == nil && subagents.isEmpty {
                    Text("No activity yet.")
                        .foregroundStyle(.tertiary)
                }
            }
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - AgentStreamRow

private struct AgentStreamRow: View {
    let stream: ActivityAgentStream

    /// Subagent streams carry `agentType`; the main stream never does (its
    /// `agentType` is always nil — see `ActivityStreamModel.ingest`), so it
    /// falls through to the most recent event's `agent` field instead. One
    /// formula covers both rows rather than each row picking its own
    /// fallback chain.
    private var label: String {
        stream.agentType ?? stream.events.last?.agent ?? "Agent"
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.subheadline)
                    .fontWeight(.medium)
                if let last = stream.events.last {
                    Text(last.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Text(stream.finished ? "Finished" : "Running")
                .font(.caption2)
                .foregroundStyle(stream.finished ? Color.secondary : Color.green)
        }
        .padding(.vertical, 2)
    }
}
