import Foundation
import Combine
import os

private let log = Logger(subsystem: "com.hammer.nostromo", category: "chat")

// MARK: - SessionHealth

// MARK: - TurnChange

/// A precise description of what just changed in `ChatSession.turns`.
///
/// `@Published turns` remains the addressable model — virtualization needs
/// random access by index — but it is no longer what drives rendering. It fires
/// on every block append, and `ReplView` used to respond by walking the *entire*
/// turn array, so the cost of painting one streamed token rose linearly with
/// session length. Subscribers use this instead and do O(changed) work,
/// consulting `turns` only by index.
enum TurnChange {
    /// One turn was appended at `index`.
    case appended(index: Int)
    /// `addedCount` blocks were appended to the turn at `index`.
    case updatedBlocks(index: Int, addedCount: Int)
    /// Turns from `replacedFrom` onward were replaced (attach reconcile).
    /// Everything before that index kept its identity and its rendered view.
    case spliced(replacedFrom: Int)
    /// The transcript was emptied. Every turn view must be released.
    case cleared
}

/// Observable health state of a daemon-hosted focus session.
///
/// Derivation rules (from daemon events):
///   `.sessionState(.crashed)`         → `.recovering`  (supervisor may be retrying)
///   `.sessionDown(.crashLoopGuard)`   → `.permanentlyDown(.crashLoopGuard)`  (alarm)
///   `.sessionDown(.staleId)`          → `.permanentlyDown(.staleId)`         (alarm)
///   `.sessionDown(.user)`             → `.healthy`     (benign user stop — clear indicator)
///   `.sessionState(.idle/.midTurn/…)` → `.healthy`     (recovery succeeded)
enum SessionHealth: Equatable {
    case healthy
    case recovering
    case permanentlyDown(DaemonStopReason)
}

/// Thin client over a **nostromod-hosted** persistent session for one focus.
///
/// The daemon owns the long-lived `claude --input-format stream-json` child,
/// parses the stream, maintains the canonical transcript, and broadcasts turn
/// deltas to every attached client (mirroring = daemon broadcast). This type:
///   - spawns/attaches the focus's session over IPC (idempotent),
///   - sends user input (`session_send` → the daemon writes the child's stdin),
///   - maps the daemon's `Turn`/`TurnBlock`/`TurnDelta` into the GUI's
///     `ChatTurn`/`TurnBlock` so `ReplView` renders unchanged.
///
/// Replaces the previous model of spawning a fresh `claude -p` per message.
/// Conversation persistence + session-id management now live in the daemon.
class ChatSession: ObservableObject {

    let tag: String            // local IPC address for this focus's session
    let agentName: String      // passed to the daemon → claude `--agent`
    let displayName: String    // `-n` / `--remote-control` name (phone-facing label)
    let workingDirectory: String?

    @Published private(set) var turns:          [ChatTurn]    = []
    @Published private(set) var isRunning:      Bool          = false
    @Published private(set) var pendingCount:   Int           = 0     // daemon queues; reserved
    /// Derived from daemon health events. Drives the sidebar badge and pace-bars status strip.
    @Published private(set) var health:         SessionHealth = .healthy
    /// Fraction of the context window used (0–1), derived from the most recent
    /// turn's token-usage report. Nil until the first turn completes.
    /// Assumes a 200 k-token context window (claude-sonnet default).
    @Published private(set) var contextFraction: Double?      = nil

    private static let contextLimit: Double = 200_000

    /// When true, the health indicator is suppressed for the current `health` value.
    /// Cleared automatically on the next health *change* so the indicator re-appears.
    private(set) var isDismissed: Bool = false

    /// The health value to show in the UI. Returns `.healthy` when the indicator
    /// has been dismissed, so callers don't need to check `isDismissed` separately.
    var displayedHealth: SessionHealth { isDismissed ? .healthy : health }

    /// Incremental companion to `$turns`. See `TurnChange`.
    let changes = PassthroughSubject<TurnChange, Never>()

    /// Which daemon-side transcript lifetime the current `daemonId`s belong to.
    ///
    /// The daemon numbers turns `t0, t1, …` from a counter that lives on its
    /// `SessionTranscript`, and that struct is rebuilt from scratch whenever the
    /// daemon restarts. So the turn that was `t450` comes back as `t7`. Now that
    /// turns are *retained* across a reattach rather than replaced, an unscoped
    /// `daemonId` lookup would happily append a new epoch's blocks to an ancient
    /// turn that happens to share the id. Every delta lookup filters on this.
    private(set) var currentEpoch = 0

    /// The daemon's session id, as reported by `.sessionSpawned`. Used only to
    /// tell "different conversation" from "we were away too long" when an attach
    /// snapshot shares no common ground with what we retained.
    private(set) var currentSessionId: String?

    /// Skeleton/payload split for retained turns. See `TurnPayloadStore`.
    let payloadStore = TurnPayloadStore()

    private let client: NostromodClient
    private var cancellables = Set<AnyCancellable>()

    init(tag: String, agentName: String? = nil, displayName: String? = nil,
         workingDirectory: String? = nil, client: NostromodClient) {
        self.tag              = tag
        self.agentName        = agentName ?? tag
        self.displayName      = displayName ?? (agentName ?? tag)
        self.workingDirectory = workingDirectory
        self.client           = client
        log.info("ChatSession[\(tag, privacy: .public)] init (daemon-hosted)")

        client.messages
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.handle($0) }
            .store(in: &cancellables)

        // Spawn/attach exactly once per connection. `connected` replays its
        // current value, so a session created while already connected fires
        // immediately; a reconnect (incl. daemon restart) flips false→true and
        // re-issues. This replaces the old init+welcome pair that double-attached
        // (which double-rendered every turn).
        client.connected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isConnected in
                guard let self, isConnected else { return }
                self.spawnAndAttach()
            }
            .store(in: &cancellables)
    }

    /// Spawn (or resume) this focus's session and attach for turn deltas.
    /// Both calls are idempotent daemon-side, so re-issuing on reconnect is safe.
    private func spawnAndAttach() {
        // remoteControl: false. EMPIRICAL FINDING (2026-05-31): `--remote-control`
        // is INERT in `--input-format stream-json`/`--print` mode — it's accepted
        // but never registers a session with Anthropic's relay (claude's own
        // --debug-file shows zero remote-control activity), so the focus never
        // appears in the Claude mobile/web app. Native phone control requires an
        // INTERACTIVE session, which is incompatible with the structured stream-json
        // rendering this GUI needs. Enabling it only spawned dead relay connections.
        // The `displayName` is still threaded as the `-n` label (and is the relay
        // name if/when we ever drive a focus in interactive mode). See the PRD's
        // "Remote control — disproven" note for the path forward (our own client).
        client.sessionSpawn(tag: tag, agentName: agentName, viewName: displayName,
                            cwd: workingDirectory, sessionId: nil, remoteControl: false)
        client.sessionAttach(tag: tag)
    }

    /// Clear the local display and start a fresh daemon session (new claude
    /// session id on the next message).
    func newSession() {
        turns = []
        payloadStore.clear()
        currentSessionId = nil
        currentEpoch += 1
        changes.send(.cleared)
        contextFraction = nil
        // The daemon's `new_session` stops the child, drops the session from its
        // registry, and clears the stored id ("next spawn is fresh"). If we don't
        // re-spawn, the tag becomes unknown and every subsequent send fails with
        // "unknown session tag". So immediately spawn+attach a fresh session
        // (sessionSpawn with id=nil → new uuid since the id was just cleared).
        client.sessionControl(tag: tag, action: "new_session")
        spawnAndAttach()
        log.info("ChatSession[\(self.tag, privacy: .public)] new_session requested — respawned")
    }

    // MARK: - Send

    func send(_ text: String, images: [URL] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isRunning = true   // optimistic; SessionState(mid_turn) reconciles
        // Optimistic echo: show the user's message instantly instead of waiting
        // for the daemon to parse + replay it back over IPC (that round-trip is
        // what felt laggy). The local turn has no daemonId; apply(.turnStarted)
        // adopts it when the daemon's matching turn arrives (dedupe by text), so
        // subsequent block deltas attach to it.
        turns.append(ChatTurn(userInput: trimmed, timestamp: Date(), epoch: currentEpoch))
        changes.send(.appended(index: turns.count - 1))
        client.sessionSend(tag: tag, text: trimmed, imagePaths: images.map { $0.path })
    }

    // MARK: - Recovery

    /// Request a daemon-side restart of this session (resumes with the same
    /// session id). The health indicator clears naturally when the daemon
    /// broadcasts `SessionState::Idle` after the new child is ready.
    func restart() {
        client.sessionControl(tag: tag, action: "restart")
        log.info("ChatSession[\(self.tag, privacy: .public)] restart requested")
    }

    /// Suppress the health indicator for the current health value. The
    /// suppression lifts automatically on the next health state change.
    func dismissHealth() {
        isDismissed = true
        // Notify observers (the badge and pace-bars strip observe isDismissed
        // indirectly via AppStore which re-publishes on every health update).
        objectWillChange.send()
    }

    // MARK: - Inbound (daemon broadcast)

    private func handle(_ msg: ServerMsg) {
        switch msg {
        case .sessionSpawned(let t, let sessionId) where t == tag:
            // The daemon sends this on every idempotent re-spawn, so it lands
            // before the attach snapshot on the same connection — which is what
            // lets the reconciler tell a different conversation apart from a
            // long absence.
            if let sessionId { currentSessionId = sessionId }

        case .sessionTurns(let t, let daemonTurns) where t == tag:
            adoptSnapshot(daemonTurns)

        case .sessionTurnDelta(let t, let delta) where t == tag:
            apply(delta)

        case .sessionState(let t, let state) where t == tag:
            isRunning = (state == .midTurn || state == .awaitingPermission)
            switch state {
            case .idle, .midTurn, .awaitingPermission:
                updateHealth(.healthy)   // recovery succeeded — clear indicator
            case .crashed:
                updateHealth(.recovering)
            }

        case .sessionExited(let t, _) where t == tag:
            isRunning = false

        case .sessionDown(let t, let reason) where t == tag:
            isRunning = false
            if reason == .user {
                // Benign user-requested stop — clear any indicator.
                updateHealth(.healthy)
            } else {
                // CrashLoopGuard or StaleId → alarm.
                updateHealth(.permanentlyDown(reason))
            }

        default:
            break
        }
    }

    /// Update health and clear the dismissed flag if the value changed.
    private func updateHealth(_ newHealth: SessionHealth) {
        if newHealth != health {
            isDismissed = false
        }
        health = newHealth
    }

    // MARK: - Attach snapshot

    /// Splice an attach snapshot into what we already hold, rather than
    /// replacing it. See `TurnReconciler` for the full rationale.
    private func adoptSnapshot(_ daemonTurns: [DaemonTurn]) {
        currentEpoch += 1
        let sessionIdChanged = lastReconciledSessionId != nil
            && currentSessionId != nil
            && lastReconciledSessionId != currentSessionId
        lastReconciledSessionId = currentSessionId

        let snapshot = daemonTurns.map { Self.mapTurn($0, epoch: currentEpoch) }
        let outcome  = TurnReconciler.reconcile(retained: turns,
                                                snapshot: snapshot,
                                                sessionIdChanged: sessionIdChanged)

        if outcome.didReplaceAll {
            payloadStore.clear()
        } else {
            // Turns the splice dropped (a replaced tail) release their payloads.
            let survivors = Set(outcome.turns.map { $0.id })
            for turn in turns where !survivors.contains(turn.id) {
                payloadStore.drop(turn.id)
            }
        }

        turns = outcome.turns
        enforceRetentionCap()
        // `.cleared` means "release every turn view and re-sync from `turns`",
        // so it covers the replacement snapshot too.
        changes.send(outcome.didReplaceAll ? .cleared : .spliced(replacedFrom: outcome.replacedFrom))
        log.info("""
            ChatSession[\(self.tag, privacy: .public)] attach reconcile: \
            epoch=\(self.currentEpoch) snapshot=\(snapshot.count) overlap=\(outcome.overlap) \
            retained=\(self.turns.count) gap=\(outcome.insertedGapMarker) replaced=\(outcome.didReplaceAll)
            """)
    }

    /// The session id in force the last time a snapshot was reconciled. Compared
    /// against `currentSessionId` to detect a genuinely different conversation.
    private var lastReconciledSessionId: String?

    // MARK: - Live deltas

    /// Index of the turn a delta addresses, scoped to the current epoch.
    ///
    /// The epoch filter is what stops a re-issued `t7` from landing on the
    /// `t7` of a previous daemon lifetime, five hundred turns back.
    private func index(ofDaemonId turnId: String) -> Int? {
        turns.lastIndex { $0.daemonId == turnId && $0.epoch == currentEpoch }
    }

    private func apply(_ delta: DaemonTurnDelta) {
        switch delta {
        case .turnStarted(let turn):
            // Reconcile with an optimistic local echo (same text, not yet bound
            // to a daemon id). If none (e.g. a phone-originated message), append.
            //
            // Bounded to the newest few turns: an unbounded search would let an
            // identical message sent an hour ago ("yes", "continue") swallow
            // this turn and strand every subsequent block delta.
            let searchFloor = max(0, turns.count - TurnReconciler.echoAdoptionWindow)
            let echoIndex = turns[searchFloor...].lastIndex {
                $0.daemonId == nil && $0.marker == nil && $0.userInput == turn.userInput
            }
            if let i = echoIndex {
                turns[i].daemonId   = turn.id
                turns[i].epoch      = currentEpoch
                turns[i].isComplete = turn.isComplete
                // Adopt the record's own timestamp. The optimistic echo stamped
                // itself with `Date()`, which is not the value the daemon will
                // report for this turn on a later reattach — leaving it would
                // make the turn unmatchable and duplicate it on reconnect.
                turns[i].timestampRaw = turn.timestamp
                if let parsed = turn.timestamp.flatMap({ Self.iso.date(from: $0) }) {
                    turns[i].timestamp = parsed
                }
                if !turn.blocks.isEmpty {
                    turns[i].blocks = turn.blocks.map(Self.mapBlock)
                    changes.send(.updatedBlocks(index: i, addedCount: turns[i].blocks.count))
                }
            } else {
                turns.append(Self.mapTurn(turn, epoch: currentEpoch))
                changes.send(.appended(index: turns.count - 1))
            }
            compactColdTurn()
            enforceRetentionCap()

        case .blockAppended(let turnId, let block):
            if let i = index(ofDaemonId: turnId) {
                turns[i].blocks.append(Self.mapBlock(block))
                changes.send(.updatedBlocks(index: i, addedCount: 1))
            }

        case .turnCompleted(let turnId, let summary, let contextTokens):
            if let i = index(ofDaemonId: turnId) {
                turns[i].blocks.append(.resultSummary(ResultSummaryData(
                    durationMs: summary.durationMs,
                    costUSD:    summary.costUsd,
                    isError:    summary.isError)))
                turns[i].isComplete = true
                changes.send(.updatedBlocks(index: i, addedCount: 1))
            }
            if let ct = contextTokens, ct > 0 {
                contextFraction = min(1.0, Double(ct) / Self.contextLimit)
            }

        case .turnErrored(let turnId, let message):
            if let i = index(ofDaemonId: turnId) {
                turns[i].blocks.append(.errorMessage(message))
                turns[i].isComplete = true
                changes.send(.updatedBlocks(index: i, addedCount: 1))
            }
        }
    }

    // MARK: - Retention

    /// Hand the turn that just fell out of the hot window to the payload store.
    ///
    /// Compression happens on turn *completion* and off the main thread, so a
    /// streaming turn never pays for it.
    private func compactColdTurn() {
        let index = turns.count - 1 - TurnPayloadStore.hotWindow
        guard index >= 0, turns[index].isComplete, turns[index].marker == nil else { return }
        let turn = turns[index]
        payloadStore.compact(turn) { [weak self] skeleton in
            guard let self, let i = self.turns.firstIndex(where: { $0.id == skeleton.id })
            else { return }
            self.turns[i] = skeleton
        }
    }

    /// Drop the oldest turns once retention exceeds the skeleton cap, and say so
    /// at the top of the transcript. This is the one place history genuinely
    /// becomes unreachable, so it is never silent.
    private func enforceRetentionCap() {
        guard turns.count > TurnPayloadStore.maxRetainedTurns else { return }
        let overflow = turns.count - TurnPayloadStore.maxRetainedTurns
        for turn in turns.prefix(overflow) { payloadStore.drop(turn.id) }
        turns.removeFirst(overflow)
        if turns.first?.marker != .historyUnavailable {
            turns.insert(.marker(.historyUnavailable), at: 0)
        }
        changes.send(.spliced(replacedFrom: 0))
    }

    /// Full content for a turn whose payload was compressed, for the moment a
    /// view materializes it. Turns still in the hot window are returned as-is.
    func hydrated(_ turn: ChatTurn) -> TurnPayloadStore.Hydration {
        payloadStore.hydrate(turn)
    }

    // MARK: - Mapping (daemon model → GUI model)

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func mapTurn(_ t: DaemonTurn, epoch: Int) -> ChatTurn {
        ChatTurn(userInput:    t.userInput,
                 timestamp:    t.timestamp.flatMap { iso.date(from: $0) } ?? Date(),
                 timestampRaw: t.timestamp,
                 blocks:       t.blocks.map(mapBlock),
                 isComplete:   t.isComplete,
                 daemonId:     t.id,
                 epoch:        epoch)
    }

    private static func mapBlock(_ b: DaemonTurnBlock) -> TurnBlock {
        switch b {
        case .text(let s):
            return .text(s)
        case .toolCall(let name, let summary, let full):
            return .toolCall(ToolCallData(toolName: name, inputSummary: summary, inputFull: full))
        case .toolResult(let content, let isError):
            return .toolResult(ToolResultData(content: content, isError: isError))
        case .resultSummary(let d, let c, let e):
            return .resultSummary(ResultSummaryData(durationMs: d, costUSD: c, isError: e))
        case .errorMessage(let m):
            return .errorMessage(m)
        case .askQuestion(let q, let h, let opts, let multi):
            return .askQuestion(AskQuestionData(
                question: q,
                header:   h,
                options:  opts.map { AskQuestionData.Option(label: $0.label, description: $0.description, recommended: $0.recommended) },
                multiSelect: multi))
        }
    }
}
