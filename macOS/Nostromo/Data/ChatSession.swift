import Foundation
import Combine
import os

private let log = Logger(subsystem: "com.hammer.nostromo", category: "chat")

// MARK: - SessionHealth

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

    @Published private(set) var turns:        [ChatTurn]     = []
    @Published private(set) var isRunning:    Bool           = false
    @Published private(set) var pendingCount: Int            = 0     // daemon queues; reserved
    /// Derived from daemon health events. Drives the sidebar badge and pace-bars status strip.
    @Published private(set) var health:       SessionHealth  = .healthy

    /// When true, the health indicator is suppressed for the current `health` value.
    /// Cleared automatically on the next health *change* so the indicator re-appears.
    private(set) var isDismissed: Bool = false

    /// The health value to show in the UI. Returns `.healthy` when the indicator
    /// has been dismissed, so callers don't need to check `isDismissed` separately.
    var displayedHealth: SessionHealth { isDismissed ? .healthy : health }

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
        turns.append(ChatTurn(userInput: trimmed, timestamp: Date()))
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
        case .sessionTurns(let t, let daemonTurns) where t == tag:
            turns = daemonTurns.map(Self.mapTurn)

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

    private func apply(_ delta: DaemonTurnDelta) {
        switch delta {
        case .turnStarted(let turn):
            // Reconcile with an optimistic local echo (same text, not yet bound
            // to a daemon id). If none (e.g. a phone-originated message), append.
            if let i = turns.lastIndex(where: { $0.daemonId == nil && $0.userInput == turn.userInput }) {
                turns[i].daemonId   = turn.id
                turns[i].isComplete = turn.isComplete
                if !turn.blocks.isEmpty { turns[i].blocks = turn.blocks.map(Self.mapBlock) }
            } else {
                turns.append(Self.mapTurn(turn))
            }

        case .blockAppended(let turnId, let block):
            if let i = turns.firstIndex(where: { $0.daemonId == turnId }) {
                turns[i].blocks.append(Self.mapBlock(block))
            }

        case .turnCompleted(let turnId, let summary):
            if let i = turns.firstIndex(where: { $0.daemonId == turnId }) {
                turns[i].blocks.append(.resultSummary(ResultSummaryData(
                    durationMs: summary.durationMs,
                    costUSD:    summary.costUsd,
                    isError:    summary.isError)))
                turns[i].isComplete = true
            }

        case .turnErrored(let turnId, let message):
            if let i = turns.firstIndex(where: { $0.daemonId == turnId }) {
                turns[i].blocks.append(.errorMessage(message))
                turns[i].isComplete = true
            }
        }
    }

    // MARK: - Mapping (daemon model → GUI model)

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func mapTurn(_ t: DaemonTurn) -> ChatTurn {
        ChatTurn(userInput:  t.userInput,
                 timestamp:  t.timestamp.flatMap { iso.date(from: $0) } ?? Date(),
                 blocks:     t.blocks.map(mapBlock),
                 isComplete: t.isComplete,
                 daemonId:   t.id)
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
                options:  opts.map { AskQuestionData.Option(label: $0.label, description: $0.description) },
                multiSelect: multi))
        }
    }
}
