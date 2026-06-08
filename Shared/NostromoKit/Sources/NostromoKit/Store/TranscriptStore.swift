// NostromoKit — TranscriptStore.swift
//
// @MainActor ObservableObject that owns a single attached focus's transcript.
// Sends SessionAttach on attach(tag:), ingests sessionTurns (snapshot) and
// sessionTurnDelta (live deltas), and sends SessionDetach on teardown.
// Phase 2: send(_ text:) emits ClientSessionSend; published state tracks
// SessionState updates from the daemon.

import Foundation
import Combine

@MainActor
public final class TranscriptStore: ObservableObject {

    // MARK: - Public state

    @Published public private(set) var turns: [DaemonTurn] = []
    @Published public private(set) var state: SessionState = .idle

    // MARK: - Dependencies

    private let client: NetworkClient
    private var tag: String?
    private var agentName: String = ""
    private var viewName: String = ""
    private var cancellable: AnyCancellable?

    // MARK: - Init

    public init(client: NetworkClient) {
        self.client = client
    }

    // MARK: - Attach / detach

    /// Attach to a session tag, storing agentName and viewName for re-spawn after new_session.
    public func attach(tag: String, agentName: String, viewName: String) {
        self.tag = tag
        self.agentName = agentName
        self.viewName = viewName
        turns = []
        cancellable = client.messages
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.handle($0) }
        client.send(ClientSessionAttach(tag: tag))
    }

    public func detach() {
        if let tag { client.send(ClientSessionDetach(tag: tag)) }
        cancellable?.cancel()
        cancellable = nil
        tag = nil
    }

    // MARK: - Message handling

    // MARK: - Send

    public func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let tag else { return }
        // Optimistic echo — real turn de-duped on arrival via id mismatch
        turns.append(DaemonTurn(id: "local-\(UUID().uuidString)",
                                userInput: trimmed, timestamp: nil,
                                blocks: [], isComplete: false))
        client.send(ClientSessionSend(tag: tag, text: trimmed, images: []))
    }

    // MARK: - Session lifecycle controls

    public func stop() {
        guard let tag else { return }
        client.send(ClientSessionControl(tag: tag, action: "stop"))
    }

    public func restart() {
        guard let tag else { return }
        client.send(ClientSessionControl(tag: tag, action: "restart"))
        // No re-spawn: daemon restarts child and re-attaches clients automatically
    }

    public func newSession() {
        guard let tag else { return }
        turns = []  // optimistic clear
        client.send(ClientSessionControl(tag: tag, action: "new_session"))
        // MUST re-spawn: new_session deregisters the tag (session_manager.rs:679-684).
        // cwd: nil → daemon defaults to $HOME (iOS never receives filesystem paths
        // via FocusMeta — cwd-awareness is intentionally out of scope on mobile).
        client.send(ClientSessionSpawn(tag: tag, agentName: agentName, viewName: viewName,
                                       cwd: nil, sessionId: nil, remoteControl: false))
        client.send(ClientSessionAttach(tag: tag))
    }

    // MARK: - Message handling

    private func handle(_ msg: ServerMsg) {
        switch msg {
        case .sessionState(let t, let s) where t == tag:
            state = s
        case .sessionTurns(let t, let snapshot) where t == tag:
            turns = snapshot                         // replace full snapshot
        case .sessionTurnDelta(let t, let delta) where t == tag:
            apply(delta)                             // append / mutate
        default:
            break
        }
    }

    private func apply(_ delta: DaemonTurnDelta) {
        switch delta {
        case .turnStarted(let turn):
            // De-dup guard: if we attached to an already-running session the
            // snapshot may have already included this turn.
            if !turns.contains(where: { $0.id == turn.id }) {
                turns.append(turn)
            }
        case .blockAppended(let turnId, let block):
            if let i = turns.firstIndex(where: { $0.id == turnId }) {
                turns[i] = turns[i].appending(block)
            }
        case .turnCompleted(let turnId, _), .turnErrored(let turnId, _):
            if let i = turns.firstIndex(where: { $0.id == turnId }) {
                turns[i] = turns[i].completed()
            }
        }
    }
}
