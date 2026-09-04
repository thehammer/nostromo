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

struct TranscriptView<Accessory: View>: View {
    let tag:         String
    let displayName: String
    let agentName:   String
    let viewName:    String
    let client:      NetworkClient
    /// The ambient-activity ticker (ios-curated-view-parity W4), composed
    /// above the input bar inside this view's own bottom safe-area inset —
    /// NOT a second `safeAreaInset` (that would land below the input bar
    /// instead of above it). Owned and injected by `DynamicFocusView`; this
    /// view knows nothing about `ActivityStreamModel`/`DaemonStore`.
    let bottomAccessory: () -> Accessory
    /// Save this surface's scroll-restore key (W6 — ios-curated-view-parity,
    /// D5): the index of the topmost turn currently on screen. Called on
    /// teardown only, never mid-drag — see `DaemonStore.setScrollKey`.
    let saveScrollKey: (Int) -> Void
    /// Decide whether to restore a previously-saved position, given what is
    /// currently visible. `.none` when the saved turn is already on screen,
    /// which is what stops a restore producing a visible jump on a
    /// transition that happened not to move anything.
    let restoreScroll: (ClosedRange<Int>?) -> ScrollRestore

    /// The session's transcript. `@ObservedObject`, NOT `@StateObject`: the
    /// store is owned by `DaemonStore` and outlives this view, so a
    /// width-class change — which destroys and rebuilds this whole hierarchy
    /// — no longer blanks the transcript and re-requests it from the daemon.
    @ObservedObject private var store: TranscriptStore
    @State private var draft = ""

    /// Which turn indices are currently on screen. View-local and transient
    /// on purpose — this is "what is in front of the operator right now",
    /// not durable state; the durable half is the single key handed to
    /// `saveScrollKey` on teardown.
    @State private var visibleTurnIndices: Set<Int> = []
    /// Guards the one-shot restore, so a later re-layout can't yank the
    /// viewport after the operator has started scrolling again.
    @State private var hasRestored = false

    @State private var showStopConfirm        = false
    @State private var showRestartConfirm     = false
    @State private var showNewSessionConfirm  = false

    init(
        tag: String, displayName: String, agentName: String, viewName: String, client: NetworkClient,
        store: TranscriptStore,
        saveScrollKey: @escaping (Int) -> Void,
        restoreScroll: @escaping (ClosedRange<Int>?) -> ScrollRestore,
        @ViewBuilder bottomAccessory: @escaping () -> Accessory
    ) {
        self.tag = tag
        self.displayName = displayName
        self.agentName = agentName
        self.viewName = viewName
        self.client = client
        self.bottomAccessory = bottomAccessory
        self.saveScrollKey = saveScrollKey
        self.restoreScroll = restoreScroll
        _store = ObservedObject(wrappedValue: store)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(store.turns.enumerated()), id: \.element.id) { index, turn in
                        TurnCard(turn: turn, onAnswer: { store.send($0) })
                            // Turn rendering itself is untouched (W6 is not
                            // allowed to assume a turn is one fixed-height
                            // row, and doesn't): these only record which
                            // indices are on screen.
                            .onAppear    { visibleTurnIndices.insert(index) }
                            .onDisappear { visibleTurnIndices.remove(index) }
                    }
                }
                .padding()
            }
            .onChange(of: store.turns.count) { _, _ in
                if let last = store.turns.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            // The restore half of D5. Fires on the first layout that knows
            // what it is showing — not in `onAppear`, where nothing is
            // measured yet and a saved key could only be obeyed blindly.
            .onChange(of: visibleTurnIndices) { _, indices in
                guard !hasRestored, !indices.isEmpty else { return }
                hasRestored = true
                guard case .scrollTo(let target) = restoreScroll(visibleRange(from: indices)),
                      store.turns.indices.contains(target) else { return }
                // No animation: this is putting the operator back where she
                // already was, not taking her somewhere.
                proxy.scrollTo(store.turns[target].id, anchor: .top)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                bottomAccessory()
                InputBar(draft: $draft) {
                    store.send(draft)
                    draft = ""
                }
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
        .onDisappear {
            // Save the topmost visible turn before this hierarchy goes away
            // — a width-class change is the case that matters, and it gives
            // no other warning.
            if let topmost = visibleTurnIndices.min() { saveScrollKey(topmost) }
            store.detach()
        }
    }

    /// The contiguous span of turn indices currently on screen. `nil` before
    /// anything has been laid out, which `ScrollRestore` reads as a first
    /// paint.
    private func visibleRange(from indices: Set<Int>) -> ClosedRange<Int>? {
        guard let low = indices.min(), let high = indices.max() else { return nil }
        return low...high
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
