// Nostromo iOS — TranscriptView.swift
//
// Read-only transcript view for a single focus session.
// Attaches on appear, streams live deltas, detaches on disappear.
// No input bar (Phase 3).

import SwiftUI
import NostromoKit

struct TranscriptView: View {
    let tag:         String
    let displayName: String
    let client:      NetworkClient

    @StateObject private var store: TranscriptStore

    init(tag: String, displayName: String, client: NetworkClient) {
        self.tag = tag
        self.displayName = displayName
        self.client = client
        _store = StateObject(wrappedValue: TranscriptStore(client: client))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(store.turns, id: \.id) { turn in
                        TurnCard(turn: turn)
                    }
                }
                .padding()
            }
            .onChange(of: store.turns.count) { _ in
                if let last = store.turns.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.attach(tag: tag) }
        .onDisappear { store.detach() }
    }
}

// MARK: - TurnCard

private struct TurnCard: View {
    let turn: DaemonTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // User message
            if !turn.userInput.isEmpty {
                HStack {
                    Spacer()
                    Text(turn.userInput)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }

            // Assistant blocks
            ForEach(Array(turn.blocks.enumerated()), id: \.offset) { _, block in
                BlockView(block: block)
            }
        }
    }
}

// MARK: - BlockView

private struct BlockView: View {
    let block: DaemonTurnBlock

    var body: some View {
        switch block {
        case .text(let s):
            Text(s)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

        case .toolCall(let toolName, let inputSummary, _):
            HStack(spacing: 6) {
                Image(systemName: "wrench")
                    .imageScale(.small)
                Text("\(toolName) — \(inputSummary)")
                    .font(.caption)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))

        case .toolResult(_, let isError):
            HStack(spacing: 6) {
                Image(systemName: isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .imageScale(.small)
                    .foregroundStyle(isError ? Color.red : Color.green)
                Text(isError ? "Error" : "Result")
                    .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))

        case .resultSummary(let durationMs, _, let isError):
            HStack(spacing: 6) {
                Image(systemName: isError ? "xmark.circle" : "checkmark.circle")
                    .imageScale(.small)
                    .foregroundStyle(isError ? Color.red : Color.green)
                Text(isError ? "Failed" : "Done in \(durationMs / 1000)s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .errorMessage(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)

        case .askQuestion(let question, _, _, _):
            Label(question, systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
    }
}
