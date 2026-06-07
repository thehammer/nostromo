// NostromoKit — TranscriptStore.swift
//
// @MainActor ObservableObject that owns a single attached focus's transcript.
// Sends SessionAttach on attach(tag:), ingests sessionTurns (snapshot) and
// sessionTurnDelta (live deltas), and sends SessionDetach on teardown.

import Foundation
import Combine

@MainActor
public final class TranscriptStore: ObservableObject {

    // MARK: - Public state

    @Published public private(set) var turns: [DaemonTurn] = []

    // MARK: - Dependencies

    private let client: NetworkClient
    private var tag: String?
    private var cancellable: AnyCancellable?

    // MARK: - Init

    public init(client: NetworkClient) {
        self.client = client
    }

    // MARK: - Attach / detach

    public func attach(tag: String) {
        self.tag = tag
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

    private func handle(_ msg: ServerMsg) {
        switch msg {
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
