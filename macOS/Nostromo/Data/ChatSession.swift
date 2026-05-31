import Foundation
import Combine
import os

private let log = Logger(subsystem: "com.hammer.nostromo", category: "chat")

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
    let workingDirectory: String?

    @Published private(set) var turns:        [ChatTurn] = []
    @Published private(set) var isRunning:    Bool       = false
    @Published private(set) var pendingCount: Int        = 0  // daemon queues; reserved

    private let client: NostromodClient
    private var cancellables = Set<AnyCancellable>()

    init(tag: String, agentName: String? = nil, workingDirectory: String? = nil,
         client: NostromodClient) {
        self.tag              = tag
        self.agentName        = agentName ?? tag
        self.workingDirectory = workingDirectory
        self.client           = client
        log.info("ChatSession[\(tag, privacy: .public)] init (daemon-hosted)")

        client.messages
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.handle($0) }
            .store(in: &cancellables)

        // Attempt immediately (covers the common case where the daemon socket is
        // already connected); the `.welcome` handler re-issues on (re)connect and
        // daemon restart, so this is robust to ordering.
        spawnAndAttach()
    }

    /// Spawn (or resume) this focus's session and attach for turn deltas.
    /// Both calls are idempotent daemon-side, so re-issuing on reconnect is safe.
    private func spawnAndAttach() {
        client.sessionSpawn(tag: tag, agentName: agentName, viewName: agentName,
                            cwd: workingDirectory, sessionId: nil, remoteControl: false)
        client.sessionAttach(tag: tag)
    }

    /// Clear the local display and start a fresh daemon session (new claude
    /// session id on the next message).
    func newSession() {
        turns = []
        client.sessionControl(tag: tag, action: "new_session")
        log.info("ChatSession[\(self.tag, privacy: .public)] new_session requested")
    }

    // MARK: - Send

    func send(_ text: String, images: [URL] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Optimistic — the daemon's SessionState(mid_turn) reconciles this; it
        // keeps the input bar responsive without waiting for the round-trip.
        isRunning = true
        client.sessionSend(tag: tag, text: trimmed)
        // NOTE: images are surfaced in the UI but not yet forwarded to the
        // daemon/child (same known gap as before; tracked separately).
    }

    // MARK: - Inbound (daemon broadcast)

    private func handle(_ msg: ServerMsg) {
        switch msg {
        case .welcome:
            // Daemon connected (or reconnected after a restart). Re-spawn +
            // re-attach so the GUI re-syncs; the daemon's session outlived us.
            spawnAndAttach()

        case .sessionTurns(let t, let daemonTurns) where t == tag:
            turns = daemonTurns.map(Self.mapTurn)

        case .sessionTurnDelta(let t, let delta) where t == tag:
            apply(delta)

        case .sessionState(let t, let state) where t == tag:
            isRunning = (state == .midTurn || state == .awaitingPermission)

        case .sessionExited(let t, _) where t == tag:
            isRunning = false

        default:
            break
        }
    }

    private func apply(_ delta: DaemonTurnDelta) {
        switch delta {
        case .turnStarted(let turn):
            turns.append(Self.mapTurn(turn))

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
