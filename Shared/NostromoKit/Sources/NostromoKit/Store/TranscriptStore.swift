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
    /// How many live views are currently attached to this store (W6 —
    /// ios-curated-view-parity, D5). Normally 1. It briefly reaches 2 (or
    /// dips through 0) during a width-class change, when SwiftUI tears down
    /// one view hierarchy and builds another around the same session; see
    /// `attach`/`detach`.
    private var attachCount = 0

    // MARK: - Init

    public init(client: NetworkClient) {
        self.client = client
    }

    // MARK: - Attach / detach

    /// Attach to a session tag, storing agentName and viewName for re-spawn
    /// after new_session.
    ///
    /// Idempotent (W6, D5): re-attaching to the tag this store is already
    /// attached to is a no-op that keeps the transcript exactly as it is. It
    /// has to be, because a width-class change — rotating an iPad, dragging
    /// a multitasking divider — genuinely destroys and rebuilds the view
    /// hierarchy hosting the transcript, and the naive version of this
    /// method clears `turns` and re-requests the whole snapshot from the
    /// daemon. That is a visible reload: the transcript blanks, refills, and
    /// its autoscroll yanks the operator to the bottom of a conversation she
    /// was reading the middle of. The PRD's requirement is that a width-class
    /// change preserves every surface's scroll position and that NOTHING
    /// reloads; this, plus the store outliving the view (see
    /// `DaemonStore.transcriptStore(for:)`), is how that is true rather than
    /// hoped for.
    public func attach(tag: String, agentName: String, viewName: String) {
        self.agentName = agentName
        self.viewName = viewName

        if self.tag == tag, cancellable != nil {
            attachCount += 1
            return
        }

        self.tag = tag
        turns = []
        attachCount = 1
        cancellable = client.messages
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.handle($0) }
        client.send(ClientSessionAttach(tag: tag))
    }

    /// Release one view's interest in this session.
    ///
    /// The real teardown is deferred by one main-actor hop so it survives a
    /// view-hierarchy rebuild, whose `onAppear`/`onDisappear` pair can fire
    /// in EITHER order: if the new view attaches first the count never
    /// reaches zero, and if the old view detaches first the deferred check
    /// finds the count back above zero and does nothing. Without the defer,
    /// one of those two orderings silently detaches the session the operator
    /// is still looking at.
    public func detach() {
        attachCount -= 1
        guard attachCount <= 0 else { return }
        Task { @MainActor [weak self] in
            guard let self, self.attachCount <= 0 else { return }
            self.tearDown()
        }
    }

    private func tearDown() {
        if let tag { client.send(ClientSessionDetach(tag: tag)) }
        cancellable?.cancel()
        cancellable = nil
        tag = nil
        attachCount = 0
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
