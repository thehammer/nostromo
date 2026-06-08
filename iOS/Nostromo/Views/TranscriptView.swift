// Nostromo iOS — TranscriptView.swift
//
// Phase 2: interactive transcript view for a single focus session.
// Attaches on appear, streams live deltas, detaches on disappear.
// Bottom input bar sends user messages via session_send.
// askQuestion blocks render as tappable option buttons (same mechanism).
//
// Phase 3: toolbar menu provides Stop, Restart, and New Session controls.
// Stop is enabled only when the session is mid-turn or awaiting permission.
// New Session re-spawns in $HOME (iOS never receives project paths via
// FocusMeta — cwd-awareness is intentionally out of scope on mobile).

import SwiftUI
import NostromoKit

struct TranscriptView: View {
    let tag:         String
    let displayName: String
    let agentName:   String
    let viewName:    String
    let client:      NetworkClient

    @StateObject private var store: TranscriptStore
    @State private var draft = ""

    @State private var showStopConfirm        = false
    @State private var showRestartConfirm     = false
    @State private var showNewSessionConfirm  = false

    init(tag: String, displayName: String, agentName: String, viewName: String, client: NetworkClient) {
        self.tag = tag
        self.displayName = displayName
        self.agentName = agentName
        self.viewName = viewName
        self.client = client
        _store = StateObject(wrappedValue: TranscriptStore(client: client))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(store.turns, id: \.id) { turn in
                        TurnCard(turn: turn, onAnswer: { store.send($0) })
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
        .safeAreaInset(edge: .bottom) {
            InputBar(draft: $draft) {
                store.send(draft)
                draft = ""
            }
        }
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showRestartConfirm = true } label: {
                        Label("Restart", systemImage: "arrow.clockwise")
                    }

                    Button(role: .destructive) { showStopConfirm = true } label: {
                        Label("Stop", systemImage: "stop.circle")
                    }
                    .disabled(store.state != .midTurn && store.state != .awaitingPermission)

                    Button(role: .destructive) { showNewSessionConfirm = true } label: {
                        Label("New Session", systemImage: "plus.bubble")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog(
            "Stop session?",
            isPresented: $showStopConfirm,
            titleVisibility: .visible
        ) {
            Button("Stop", role: .destructive) { store.stop() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The running turn will be interrupted.")
        }
        .confirmationDialog(
            "New Session?",
            isPresented: $showNewSessionConfirm,
            titleVisibility: .visible
        ) {
            Button("New Session", role: .destructive) { store.newSession() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Starts a fresh session in your home directory (not the project folder). The current transcript will be cleared.")
        }
        .onAppear { store.attach(tag: tag, agentName: agentName, viewName: viewName) }
        .onDisappear { store.detach() }
    }
}

// MARK: - InputBar

private struct InputBar: View {
    @Binding var draft: String
    let onSend: () -> Void

    private var isEmpty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .onSubmit {
                    if !isEmpty { onSend() }
                }

            Button(action: onSend) {
                Image(systemName: "paperplane.fill")
            }
            .disabled(isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

// MARK: - TurnCard

private struct TurnCard: View {
    let turn:     DaemonTurn
    let onAnswer: (String) -> Void

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
                BlockView(block: block, onAnswer: onAnswer)
            }
        }
    }
}

// MARK: - BlockView

private struct BlockView: View {
    let block:    DaemonTurnBlock
    let onAnswer: (String) -> Void

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

        case .askQuestion(let question, let header, let options, _):
            AskQuestionPrompt(
                question: question,
                header:   header,
                options:  options,
                onAnswer: onAnswer
            )
        }
    }
}
