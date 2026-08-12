import Combine
import Foundation
import os

private let log = Logger(subsystem: "com.hammer.nostromo", category: "loadharness")

/// Drives the real transcript code path with synthetic traffic, so the numeric
/// acceptance criteria can be measured on a real app with a real window and a
/// real constraint engine.
///
/// The memory-slope, CPU, `sample`-signature and view-count criteria cannot be
/// checked in the logic test bundle: they need an actual `NSWindow` and an
/// actual steady-state footprint. They also must not need a live daemon — five
/// thousand real turns would cost hundreds of dollars and hours, and would not
/// be reproducible.
///
/// So the harness injects into `NostromodClient.messages` and `connected`, which
/// is the *same* path the daemon's own traffic takes. In particular a simulated
/// reconnect flips `connected` false→true, which re-triggers
/// `ChatSession.spawnAndAttach()` exactly as a daemon restart does, and then
/// delivers `.sessionSpawned` and a 30-turn `.sessionTurns` snapshot exactly as
/// the daemon would. That is what makes the 20-reconnect scenario faithful
/// rather than a mock of itself.
///
/// Activation is by environment variable, **not** `#if DEBUG` — these numbers
/// are only meaningful on a Release build.
///
///   NOSTROMO_LOAD_HARNESS=1        enable; suppress the real daemon connect
///   NOSTROMO_LOAD_TURNS=5000       turns to deliver as live deltas
///   NOSTROMO_LOAD_RECONNECTS=20    reconnect cycles, evenly interleaved
///   NOSTROMO_LOAD_FOCUSES=1..8     panes driven concurrently
///   NOSTROMO_LOAD_SCROLL=1         after load, scroll bottom→top→bottom
///   NOSTROMO_LOAD_DURATION=24h     keep driving for a soak run
final class TranscriptLoadHarness {

    private(set) static var shared: TranscriptLoadHarness?

    /// Whether the harness is active. `AppStore` consults this to suppress the
    /// real daemon connection, so a load run never contends with live sessions.
    static var isActive: Bool {
        ProcessInfo.processInfo.environment["NOSTROMO_LOAD_HARNESS"] == "1"
    }

    let totalTurns: Int
    let reconnects: Int
    let focusCount: Int
    let scrollAfterLoad: Bool
    let durationSeconds: TimeInterval?

    private(set) var turnsDelivered = 0

    /// Panes actually driven. 0 until `begin` runs, so a run that never targeted
    /// anything reports 0 rather than nothing at all.
    private(set) var targetedPaneCount = 0
    /// Focuses the run asked for. Reported alongside `targetedPaneCount` so a run
    /// that drove 1 of 8 fails a criterion instead of passing as a 1-focus run.
    private(set) var requestedFocusCount = 0

    private let client: NostromodClient
    private var tags: [String] = []
    /// Per-tag record of everything delivered, so a reconnect can serve a
    /// faithful attach snapshot — the last 30 turns, exactly as the daemon's
    /// `SCROLLBACK_TURNS` cap does.
    private var records: [String: [DaemonTurn]] = [:]
    private var sessionIds: [String: String] = [:]
    private var nextSeq: [String: Int] = [:]
    private var cursor = 0
    private var timer: DispatchSourceTimer?
    private var rng = SeededRNG(seed: 0x5EED_1234)

    // MARK: - Lifecycle

    static func startIfRequested(client: NostromodClient) {
        guard isActive else { return }
        let harness = TranscriptLoadHarness(client: client)
        shared = harness
        harness.start()
    }

    private init(client: NostromodClient) {
        let env = ProcessInfo.processInfo.environment
        self.client          = client
        self.totalTurns      = Int(env["NOSTROMO_LOAD_TURNS"] ?? "") ?? 5_000
        self.reconnects      = Int(env["NOSTROMO_LOAD_RECONNECTS"] ?? "") ?? 20
        self.focusCount      = max(1, min(8, Int(env["NOSTROMO_LOAD_FOCUSES"] ?? "") ?? 1))
        self.scrollAfterLoad = env["NOSTROMO_LOAD_SCROLL"] == "1"
        self.durationSeconds = Self.parseDuration(env["NOSTROMO_LOAD_DURATION"])
    }

    /// Wait until the window has laid out and its transcript panes have
    /// registered, then drive *those* tags.
    ///
    /// Guessing tags is how the first harness run measured nothing: the traffic
    /// reached a `ChatSession` with no `ReplView` attached, so `ChatSession` was
    /// exercised and the view layer — the expensive half, and the half this work
    /// exists to bound — never was.
    private func start() {
        // 120 s, not 30. A cold Release launch is slow enough that 30 s was
        // occasionally a lie, and the consequence of giving up early is now an
        // abort rather than a quiet guess — so the wait can afford to be
        // generous. One warning at the 30 s mark keeps a stuck run visible.
        let pollInterval = 0.5
        let maxAttempts  = 240
        var attempts     = 0

        func attempt() {
            let live = TranscriptDiagnostics.registeredTags
            if !live.isEmpty || attempts >= maxAttempts {
                let waited = Double(attempts) * pollInterval
                requestedFocusCount = focusCount
                switch LoadHarnessTargeting.resolve(registered: live,
                                                    activeTag: AppStore.shared.activeFocusAgentTag,
                                                    requested: focusCount,
                                                    waitedSeconds: waited) {
                case .success(let plan):
                    if plan.tags.count < plan.requested {
                        // Not fatal, and deliberately so: the 8-focus soak is the
                        // next step, and a tool that refuses to run at all would
                        // be worse than one that runs and says plainly that it
                        // drove 1 of 8. The report fails the row.
                        log.warning("""
                            load harness: asked for \(plan.requested, privacy: .public) focuses but only \
                            \(plan.tags.count, privacy: .public) panes are registered — driving what exists
                            """)
                    }
                    begin(tags: plan.tags)
                case .failure(.noRegisteredPanes(let waitedSeconds)):
                    abort(noPanesAfter: waitedSeconds)
                }
                return
            }
            if attempts == 60 {
                log.warning("load harness: no transcript panes registered after 30s — still waiting")
            }
            attempts += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { attempt() }
        }
        attempt()
    }

    /// No pane ever registered, so there is nothing to measure.
    ///
    /// Aborting is the right answer here rather than driving a guessed tag: this
    /// process is a dedicated harness run, and ninety minutes of data that
    /// measures nothing is worse than no data — especially since the report would
    /// otherwise print PASS for every view-layer criterion.
    private func abort(noPanesAfter waitedSeconds: Double) {
        let message = """
            load harness: no transcript panes registered after \(Int(waitedSeconds))s — aborting \
            rather than driving a guessed tag. Traffic sent to a tag with no ReplView attached \
            exercises ChatSession and never materializes a view, which is the half of the system \
            under test.
            """
        log.error("\(message, privacy: .public)")
        FileHandle.standardError.write(Data((message + "\n").utf8))
        // Force one diagnostics line so the report has a row to fail on rather
        // than an empty file it can only shrug at.
        TranscriptDiagnostics.emitStreamLineNow()
        exit(3)
    }

    private func begin(tags discovered: [String]) {
        tags = discovered
        targetedPaneCount = discovered.count
        log.info("load harness: driving panes \(discovered.joined(separator: ","), privacy: .public)")
        for tag in tags {
            records[tag]    = []
            nextSeq[tag]    = 0
            sessionIds[tag] = "harness-session-\(tag)"
        }
        log.info("""
            load harness: turns=\(self.totalTurns) reconnects=\(self.reconnects) \
            focuses=\(self.focusCount) scroll=\(self.scrollAfterLoad)
            """)

        // Re-announce "connected" so ChatSession attaches, then deliver an empty
        // snapshot — the same order the daemon uses.
        client.connected.send(true)
        for tag in tags {
            client.messages.send(.sessionSpawned(tag: tag, sessionId: sessionIds[tag]))
            client.messages.send(.sessionTurns(tag: tag, turns: []))
        }

        // One turn per tick. Slow enough that the main thread can actually
        // render, fast enough that 5,000 turns finish in a few minutes.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        guard cursor < totalTurns else {
            finish()
            return
        }
        let reconnectEvery = reconnects > 0 ? max(1, totalTurns / reconnects) : Int.max
        if cursor > 0, cursor % reconnectEvery == 0 {
            simulateReconnect()
        }
        for tag in tags { deliverTurn(tag: tag) }
        cursor += 1
        turnsDelivered = cursor
    }

    private func finish() {
        timer?.cancel()
        timer = nil
        log.info("load harness: delivered \(self.turnsDelivered) turns per focus")
        if scrollAfterLoad { scrollRoundTrip() }
        if let seconds = durationSeconds {
            // Soak: keep the app alive and keep delivering so a 24 h run has
            // something to measure. Not run by the acceptance script.
            let deadline = Date().addingTimeInterval(seconds)
            let soak = DispatchSource.makeTimerSource(queue: .main)
            soak.schedule(deadline: .now() + 1, repeating: 1)
            soak.setEventHandler { [weak self] in
                guard let self else { return }
                guard Date() < deadline else { soak.cancel(); return }
                for tag in self.tags { self.deliverTurn(tag: tag) }
                self.turnsDelivered += 1
            }
            soak.resume()
            timer = soak
        }
    }

    // MARK: - Traffic

    /// Deliver one turn as live deltas — `turnStarted`, then a block at a time,
    /// then `turnCompleted`. Not an attach snapshot: the PRD's load profile is
    /// explicit that these must be live deltas to an already-attached session,
    /// because that is the path whose per-delta cost is under test.
    private func deliverTurn(tag: String) {
        let seq = nextSeq[tag] ?? 0
        nextSeq[tag] = seq + 1
        let id = "t\(seq)"
        let timestamp = Self.timestamp(forSequence: seq)
        let userInput = Self.prose(200, rng: &rng)

        let started = DaemonTurn(id: id, userInput: userInput, timestamp: timestamp,
                                 blocks: [], isComplete: false)
        client.messages.send(.sessionTurnDelta(tag: tag, delta: .turnStarted(started)))

        var blocks: [DaemonTurnBlock] = []
        for _ in 0 ..< (3 + Int(rng.next() % 6)) {
            blocks.append(.text(Self.prose(1_024 + Int(rng.next() % 3_072), rng: &rng)))
        }
        for _ in 0 ..< (2 + Int(rng.next() % 5)) {
            blocks.append(.toolCall(
                toolName: "Read", inputSummary: "ReplView.swift",
                inputFull: "{\n  \"file_path\": \"/Users/hammer/Code/nostromo/macOS/Nostromo/UI/Views/ReplView.swift\"\n}"))
            blocks.append(.toolResult(content: Self.prose(2_048, rng: &rng), isError: false))
        }
        // Every 20th turn carries a ≥256 KB tool result — the bound is on the
        // app, not on an assumption that turns are small.
        if seq % 20 == 0 {
            blocks.append(.toolResult(content: Self.prose(262_144, rng: &rng), isError: false))
        }
        // Every 50th turn carries an image attachment.
        if seq % 50 == 0 {
            blocks.append(.text("[screenshot-\(seq).png]"))
        }

        for block in blocks {
            client.messages.send(.sessionTurnDelta(
                tag: tag, delta: .blockAppended(turnId: id, block: block)))
        }

        var recorded = started
        recorded = DaemonTurn(id: id, userInput: userInput, timestamp: timestamp,
                              blocks: blocks, isComplete: true)
        records[tag, default: []].append(recorded)

        client.messages.send(.sessionTurnDelta(tag: tag, delta: .turnCompleted(
            turnId: id,
            summary: DaemonResultSummary(durationMs: 1_200, costUsd: 0.004, isError: false),
            contextTokens: 40_000)))
    }

    /// A daemon restart, through the production path.
    ///
    /// Flipping `connected` false→true is what `ChatSession` actually listens
    /// to; its `spawnAndAttach()` socket writes no-op harmlessly while
    /// disconnected. Turn ids restart from zero, exactly as the daemon's
    /// per-transcript counter does — which is the case the epoch scoping exists
    /// to survive.
    private func simulateReconnect() {
        log.info("load harness: simulated reconnect at turn \(self.cursor)")
        client.connected.send(false)
        client.connected.send(true)
        for tag in tags {
            let record = records[tag] ?? []
            let snapshot = Array(record.suffix(30))
            // Re-number, as a restarted daemon would.
            var reissued: [DaemonTurn] = []
            for (i, turn) in snapshot.enumerated() {
                reissued.append(DaemonTurn(id: "t\(i)", userInput: turn.userInput,
                                           timestamp: turn.timestamp, blocks: turn.blocks,
                                           isComplete: turn.isComplete))
            }
            nextSeq[tag] = reissued.count
            client.messages.send(.sessionSpawned(tag: tag, sessionId: sessionIds[tag]))
            client.messages.send(.sessionTurns(tag: tag, turns: reissued))
        }
    }

    // MARK: - Scripted scroll

    /// Scroll every pane bottom → top → bottom. Far more reliable than UI
    /// automation, and it exercises the same materialization pass a human drag
    /// would.
    private func scrollRoundTrip() {
        NotificationCenter.default.post(name: .transcriptLoadHarnessScroll, object: nil)
    }

    // MARK: - Synthetic content

    private static let words = [
        "session", "transcript", "constraint", "layout", "daemon", "reconnect",
        "turn", "block", "viewport", "materialize", "compress", "payload",
        "the", "a", "of", "and", "in", "to", "for", "with", "that", "this",
        "NSStackView", "ChatSession", "ReplView", "virtualizer", "anchor",
    ]

    static func prose(_ approxBytes: Int, rng: inout SeededRNG) -> String {
        var out = ""
        out.reserveCapacity(approxBytes + 64)
        while out.utf8.count < approxBytes {
            let count = Int(rng.next() % 14) + 4
            for _ in 0 ..< count { out += words[Int(rng.next() % UInt64(words.count))] + " " }
            out += "\n"
            if rng.next() % 7 == 0 { out += "- bullet " + words[Int(rng.next() % UInt64(words.count))] + "\n" }
            if rng.next() % 11 == 0 { out += "## Heading\n" }
        }
        return out
    }

    /// Distinct, monotonic, millisecond-resolution — as the record's own
    /// timestamps are, and as `ChatTurn.identityKey` needs them to be.
    private static func timestamp(forSequence seq: Int) -> String {
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: base.addingTimeInterval(Double(seq)))
    }

    private static func parseDuration(_ raw: String?) -> TimeInterval? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasSuffix("h") { return Double(raw.dropLast()).map { $0 * 3600 } }
        if raw.hasSuffix("m") { return Double(raw.dropLast()).map { $0 * 60 } }
        return Double(raw)
    }
}

extension Notification.Name {
    /// Posted when the harness wants every pane to run its scripted scroll.
    static let transcriptLoadHarnessScroll = Notification.Name("nostromo.loadHarness.scroll")
}

/// Deterministic xorshift, so two runs of the harness are comparable.
struct SeededRNG {
    private var state: UInt64
    init(seed: UInt64) { state = seed | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
