import Foundation
import Combine
import NostromoKit

/// Every focus's background tasks, fed by `AppStore` (BA3). One instance per app (`shared`), so
/// every window's chip and popover for a focus read the same list from the same delivery.
///
/// Per tag it keeps the daemon's latest `session_tasks` snapshot (REPLACE semantics), the
/// `session_task_detail` text per task, and what the daemon cannot tell after it restarted: the
/// tasks that were running when the connection dropped, shown `stopped` with a local
/// `end_reason: restart` (design contract §2.3).
///
/// `changes` publishes a focus tag when what that focus shows changed. It is coalesced to at most
/// four deliveries a second per tag: the first change goes out at once, later ones within the
/// window fold into one delivery at its end, which always carries the latest state. A subscriber
/// reads `list(for:)` when it hears its tag.
///
/// "Seen" (`✓ N done` hides once the popover was opened) is the `ended_at_ms` high-water mark at
/// the last open, per tag, persisted in `UserDefaults` under `nostromo.background.seen` (at most
/// 200 tags, least recently used dropped first; a removed focus's entry goes with it).
final class BackgroundTaskStore {
    static let shared = BackgroundTaskStore()

    /// The shortest gap between two deliveries for one tag (4 Hz).
    static let minimumInterval: TimeInterval = 0.25
    static let seenDefaultsKey = "nostromo.background.seen"
    static let seenCapacity = 200

    let changes = PassthroughSubject<String, Never>()

    /// The daemon of the current connection advertised the `tasks` feature. Without it ⇧⌘B is
    /// disabled.
    var tasksSupported = false

    /// What Stop knows about one task. Never a status: the task is `stopped` only when a snapshot says so.
    struct TaskStop: Equatable {
        enum Phase: Equatable {
            /// The request is out, or the CLI took it and no snapshot shows the task over yet.
            case stopping
            /// What went wrong, already sanitised and cut to `StopReason.limit`.
            case failed(String)
        }
        var phase: Phase
        /// Identifies the request: a late answer or timer for an older request changes nothing.
        let token: Int
    }

    /// What a Stop control shows for one task.
    struct StopDisplay: Equatable {
        /// Stop can be offered (the task is not over and the CLI supports it).
        var offered = false
        var stopping = false
        /// `Couldn't stop: <reason>` is shown with this reason.
        var failure: String?
        /// The CLI cannot stop tasks (`stop_supported == false`) for a task that is not over.
        var unsupported = false
    }

    /// The reason text Stop shows: the CLI's words, one line, no invisible or control characters.
    enum StopReason {
        static let limit = 120
        static func clean(_ raw: String?, fallback: String) -> String {
            let text = FoldTextSanitizer.sanitizeInline(raw ?? "").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return fallback }
            // Cut by characters and by scalars: one grapheme can hold thousands of combining marks.
            guard text.count > limit || text.unicodeScalars.count > limit else { return text }
            var cut = String(text.prefix(limit - 1))
            if cut.unicodeScalars.count > limit - 1 {
                cut = String(String.UnicodeScalarView(cut.unicodeScalars.prefix(limit - 1)))
            }
            return cut + "\u{2026}"
        }
    }

    /// Seconds after the CLI took a stop within which a snapshot must show the task over.
    static let confirmationTimeout: TimeInterval = 10

    /// What one focus holds.
    struct TagState: Equatable {
        /// The daemon's latest snapshot.
        var tasks: [TaskMetaWire] = []
        var details: [String: SessionTaskDetailWire] = [:]
        var stopSupported: Bool?
        var daemonEpoch: String?
        var sessionId: String?
        /// Tasks a daemon restart ended: kept in Ended until the next Clear Context.
        var restartStopped: [TaskMetaWire] = []
        /// Tasks that were not over when the connection dropped, shown stopped (restart) until the
        /// next snapshot says whether the daemon restarted (keep them) or not (its snapshot is the truth).
        var awaitingReconnect: [TaskMetaWire] = []
        var hasSnapshot = false
        /// Stop requests in flight or failed, per task id. Cleared by a snapshot that shows the task over
        /// (or no longer lists it), a new session, a daemon restart and `forget`.
        var stops: [String: TaskStop] = [:]

        /// Everything the list is built from; a daemon entry wins over a local one with its id.
        var allTasks: [TaskMetaWire] { restartStopped + awaitingReconnect + tasks }
    }

    private(set) var states: [String: TagState] = [:]

    private let now: () -> Date
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let defaults: UserDefaults
    private let requestsProvider: () -> TaskRequests
    private var nextStopToken = 0
    private var lastDelivery: [String: Date] = [:]
    private var pending: Set<String> = []
    /// tag → (seen `ended_at_ms`, last used, seconds since 1970).
    private var seen: [String: (mark: UInt64, usedAt: Double)] = [:]

    /// `schedule` runs work after a delay on the main thread (tests pass a manual scheduler);
    /// `defaults` holds the seen marks (tests pass their own suite).
    init(now: @escaping () -> Date = Date.init,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         },
         defaults: UserDefaults = .standard,
         requests: @escaping () -> TaskRequests = { TaskRequests.shared }) {
        self.requestsProvider = requests
        self.now = now
        self.schedule = schedule
        self.defaults = defaults
        loadSeen()
    }

    // MARK: Reading

    func state(for tag: String) -> TagState? {
        states[tag]
    }

    /// The daemon has sent at least one snapshot for `tag` on some connection.
    func hasSnapshot(tag: String) -> Bool {
        states[tag]?.hasSnapshot == true
    }

    /// The seen mark of `tag`, if the popover was ever opened for it.
    func seenMark(tag: String) -> UInt64? {
        seen[tag]?.mark
    }

    /// What the chip and the popover show for `tag` now.
    func list(for tag: String) -> BackgroundTaskList {
        guard let state = states[tag] else { return .empty }
        return BackgroundTaskList.make(tasks: state.allTasks, details: state.details, nowMs: nowMs,
                                       seenEndedAtMs: seen[tag]?.mark, stopSupported: state.stopSupported)
    }

    /// What a Stop control for `taskId` shows. `ended`: the task is over as far as the list says.
    func stopDisplay(tag: String, taskId: String, ended: Bool) -> StopDisplay {
        let state = states[tag]
        let supported = state?.stopSupported != false
        var display = StopDisplay(offered: !ended && supported, unsupported: !ended && !supported)
        guard !ended, let stop = state?.stops[taskId] else { return display }
        switch stop.phase {
        case .stopping: display.stopping = true
        case .failed(let reason): display.failure = reason
        }
        return display
    }

    // MARK: Stop

    /// Ask the CLI to stop `taskId`. The store does **not** check the human-gesture gate itself: the
    /// `StopConfirmation` is the proof that `TaskStopButton`'s permitted, distinct arm and confirm gestures
    /// both passed. Only the button mints one (its initializer is `fileprivate` to `TaskStopButton.swift`),
    /// so no other code compiles a call. The button closures in the popover and the task window are the
    /// only callers; a fitness test (`TaskStopGateFitnessTests`) also scans for any other route. Nothing
    /// here changes a task's status, only what Stop shows next to it.
    func requestStop(tag: String, taskId: String, confirmation _: StopConfirmation) {
        var state = states[tag] ?? TagState()
        if state.stops[taskId]?.phase == .stopping { return }
        nextStopToken += 1
        let token = nextStopToken
        state.stops[taskId] = TaskStop(phase: .stopping, token: token)
        states[tag] = state
        // With no connection the completion runs at once with the failure.
        requestsProvider().requestStop(tag: tag, taskId: taskId) { [weak self] reply in
            self?.stopAnswered(tag: tag, taskId: taskId, token: token, reply: reply)
        }
        noteChange(tag)
    }

    private func stopAnswered(tag: String, taskId: String, token: Int, reply: TaskReply<SessionTaskStopResultWire>) {
        guard var state = states[tag], state.stops[taskId]?.token == token else { return }
        switch reply {
        case .timedOut:
            state.stops[taskId]?.phase = .failed("Claude Code didn't answer")
        case .failed(let reason):
            state.stops[taskId]?.phase = .failed(StopReason.clean(reason, fallback: "Claude Code didn't answer"))
        case .answered(let wire):
            switch wire.outcome {
            case .accepted:
                // Stays `stopping` until a snapshot shows the task over; if none does, say so.
                schedule(Self.confirmationTimeout) { [weak self] in
                    self?.confirmationExpired(tag: tag, taskId: taskId, token: token)
                }
                return
            case .refused:
                state.stops[taskId]?.phase = .failed(StopReason.clean(wire.message, fallback: "Claude Code refused"))
            case .timeout:
                state.stops[taskId]?.phase = .failed("Claude Code didn't answer")
            case .unsupported:
                state.stops.removeValue(forKey: taskId)
                state.stopSupported = false
            case .notRunning:
                state.stops.removeValue(forKey: taskId)
            case .unknown(let raw):
                state.stops[taskId]?.phase = .failed(StopReason.clean(raw, fallback: "Claude Code didn't answer"))
            }
        }
        states[tag] = state
        noteChange(tag)
    }

    private func confirmationExpired(tag: String, taskId: String, token: Int) {
        guard var state = states[tag], let stop = state.stops[taskId], stop.token == token, stop.phase == .stopping else { return }
        state.stops[taskId]?.phase = .failed("no confirmation from Claude Code")
        states[tag] = state
        noteChange(tag)
    }

    // MARK: Ingest

    /// Take one decoded daemon frame; frames that are not task frames are ignored.
    func ingest(_ msg: ServerMsg) {
        switch msg {
        case .sessionTasks(let snapshot):
            apply(snapshot)
        case .sessionTaskDetail(let detail):
            var state = states[detail.tag] ?? TagState()
            guard state.details[detail.taskId] != detail else { return }
            state.details[detail.taskId] = detail
            states[detail.tag] = state
            noteChange(detail.tag)
        default:
            break
        }
    }

    private func apply(_ snapshot: SessionTasksWire) {
        let tag = snapshot.tag
        var state = states[tag] ?? TagState()
        let epoch = snapshot.daemonEpoch.isEmpty ? nil : snapshot.daemonEpoch
        let newDaemon = state.daemonEpoch != nil && epoch != nil && state.daemonEpoch != epoch
        let newSession = !newDaemon && state.sessionId != nil && snapshot.sessionId != nil
            && state.sessionId != snapshot.sessionId

        if newDaemon {
            // The daemon restarted: what ran under the old one did not survive it.
            let stamp = nowMs
            state.restartStopped += state.awaitingReconnect
                + state.tasks.filter { !$0.status.isTerminal }.map { $0.ended(as: .stopped, endReason: .restart, atMs: stamp) }
        }
        if newDaemon || newSession { state.stops = [:] }
        // Either way the wait is over. Same daemon: its snapshot is the truth about every task it knows.
        state.awaitingReconnect = []

        if newSession {
            // Clear Context or a new session: what still ran shows stopped first, then the list clears.
            let stamp = nowMs
            let stoppedFirst = state.tasks.map {
                $0.status.isTerminal ? $0 : $0.ended(as: .stopped, endReason: .sessionEnded, atMs: stamp)
            }
            if stoppedFirst != state.tasks {
                state.tasks = stoppedFirst
                states[tag] = state
                deliver(tag)   // now, whatever the window: this state must be seen before the next replaces it
            }
            state.restartStopped = []
            state.details = [:]
        }

        let newIds = Set(snapshot.tasks.map(\.id))
        let dropped = Set(state.tasks.map(\.id)).subtracting(newIds)
        let localIds = Set(state.restartStopped.map(\.id))
        for id in dropped where !localIds.contains(id) { state.details.removeValue(forKey: id) }
        // A local entry is replaced by the daemon's own when the daemon knows the task.
        state.restartStopped.removeAll { newIds.contains($0.id) }

        state.tasks = snapshot.tasks
        state.stopSupported = snapshot.stopSupported ?? (state.stopSupported == false && !newDaemon ? false : nil)
        // What the snapshot shows over (or no longer lists) has nothing left to stop.
        let liveIds = Set(snapshot.tasks.filter { !$0.status.isTerminal }.map(\.id))
        state.stops = state.stops.filter { liveIds.contains($0.key) }
        state.daemonEpoch = epoch ?? state.daemonEpoch
        state.sessionId = snapshot.sessionId ?? state.sessionId
        state.hasSnapshot = true
        guard states[tag] != state else { return }
        states[tag] = state
        noteChange(tag)
    }

    /// The daemon connection dropped. The CLI dies with the daemon, so nothing can be running
    /// any more as far as this client can tell: every task not over shows `stopped` (restart) at
    /// once, never `running`.
    func daemonDisconnected() {
        let stamp = nowMs
        for (tag, var state) in states {
            let live = state.tasks.filter { !$0.status.isTerminal }
            guard !live.isEmpty else { continue }
            state.awaitingReconnect += live.map { $0.ended(as: .stopped, endReason: .restart, atMs: stamp) }
            state.tasks.removeAll { !$0.status.isTerminal }
            state.stops = [:]
            states[tag] = state
            noteChange(tag)
        }
    }

    /// The focus is gone: its tasks and its seen mark.
    func forget(tag: String) {
        states.removeValue(forKey: tag)
        lastDelivery.removeValue(forKey: tag)
        pending.remove(tag)
        if seen.removeValue(forKey: tag) != nil { saveSeen() }
    }

    /// The popover was opened: everything that has ended so far is seen, and the chip's
    /// `done` / `failed` state goes.
    func markSeen(tag: String) {
        guard let state = states[tag] else { return }
        let all = state.allTasks
        // A task that ended without an `ended_at_ms` still counts as seen: mark 0.
        let mark = BackgroundTaskList.seenMark(of: all) ?? (all.contains { $0.status.isTerminal } ? 0 : nil)
        let previous = seen[tag]?.mark
        guard mark != nil || previous != nil else { return }
        let newMark = max(previous ?? 0, mark ?? 0)
        seen[tag] = (newMark, now().timeIntervalSince1970)
        trimSeen()
        saveSeen()
        if previous != newMark { noteChange(tag) }
    }

    // MARK: - Coalescing

    private var nowMs: UInt64 {
        UInt64(max(0, (now().timeIntervalSince1970 * 1000).rounded()))
    }

    private func noteChange(_ tag: String) {
        guard !pending.contains(tag) else { return }   // a delivery is already due; it reads the latest
        let elapsed = lastDelivery[tag].map { now().timeIntervalSince($0) } ?? .infinity
        if elapsed >= Self.minimumInterval {
            deliver(tag)
        } else {
            pending.insert(tag)
            schedule(Self.minimumInterval - elapsed) { [weak self] in
                guard let self, self.pending.remove(tag) != nil else { return }
                self.deliver(tag)
            }
        }
    }

    private func deliver(_ tag: String) {
        lastDelivery[tag] = now()
        changes.send(tag)
    }

    // MARK: - Seen marks

    private func loadSeen() {
        guard let stored = defaults.dictionary(forKey: Self.seenDefaultsKey) else { return }
        for (tag, value) in stored {
            guard let pair = value as? [NSNumber], pair.count == 2 else { continue }
            seen[tag] = (pair[0].uint64Value, pair[1].doubleValue)
        }
    }

    private func saveSeen() {
        let stored = seen.mapValues { [NSNumber(value: $0.mark), NSNumber(value: $0.usedAt)] }
        defaults.set(stored, forKey: Self.seenDefaultsKey)
    }

    private func trimSeen() {
        guard seen.count > Self.seenCapacity else { return }
        let oldest = seen.sorted { $0.value.usedAt < $1.value.usedAt }.prefix(seen.count - Self.seenCapacity)
        for (tag, _) in oldest { seen.removeValue(forKey: tag) }
    }
}
