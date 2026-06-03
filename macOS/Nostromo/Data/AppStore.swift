import AppKit
import Foundation
import Combine
import os

private let log = Logger(subsystem: "com.hammer.nostromo", category: "store")

/// Shared observable state for the whole app.
///
/// Data flows:
///   - NostromodClient (IPC) → session/activity events
///   - MotherBrokerClient (broker socket) → Mother job events + mutations
///   - FileWatchers (flat files) → rate limits, posture, perri queue
class AppStore: ObservableObject {
    static let shared = AppStore()

    // MARK: - Published state

    // Mother
    @Published private(set) var motherStatus:       MotherStatus = MotherStatus()
    @Published private(set) var motherJobs:         [MotherJob]  = []
    /// True while the broker socket is connected (hello received + subscribe sent).
    @Published private(set) var brokerConnected:    Bool         = false
    /// Set on action failure; UI observes and clears after display.
    @Published private(set) var motherActionError:  String?      = nil

    // Budget
    @Published private(set) var rateLimits: RateLimits?     = nil
    @Published private(set) var posture:    PostureSnapshot? = nil

    // Activity
    @Published private(set) var recentActivity: [ActivityEvent] = []

    // Perri PR queue
    @Published private(set) var perriQueue:        [PRQueueItem]  = []
    @Published private(set) var perriQueueStale:   Bool           = false
    @Published private(set) var perriQueueError:   String?        = nil
    @Published private(set) var perriQueueLoading: Bool           = false

    // Active focus agent tag — set by MainLayout on every focus switch.
    @Published private(set) var activeFocusAgentTag: String?      = nil

    // MARK: - Internals

    private let client  = NostromodClient()
    private let broker  = MotherBrokerClient()
    private var cancellables     = Set<AnyCancellable>()
    private var perriQueueTimer: Timer?

    /// In-memory job map keyed by id — folded from broker snapshot + events.
    private var jobMap: [String: MotherJob] = [:]

    /// Shared ChatSession instances keyed by agent tag.
    private var sessionRegistry: [String: ChatSession] = [:]

    private init() {}

    // MARK: - Session registry

    func session(for tag: String, agentName: String? = nil, displayName: String? = nil,
                 workingDirectory: String? = nil) -> ChatSession {
        if let s = sessionRegistry[tag] { return s }
        let s = ChatSession(tag: tag, agentName: agentName, displayName: displayName,
                            workingDirectory: workingDirectory, client: client)
        sessionRegistry[tag] = s
        return s
    }

    // MARK: - Active focus

    func setActiveFocusAgentTag(_ tag: String?) { activeFocusAgentTag = tag }

    // MARK: - Startup

    func start() {
        log.info("AppStore starting")

        // IPC messages (session, activity)
        client.messages
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.handle($0) }
            .store(in: &cancellables)

        // File-backed data (rate limits, posture, perri queue)
        FileWatchers.shared.rateLimits
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.rateLimits = $0 }
            .store(in: &cancellables)

        FileWatchers.shared.posture
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.posture = $0 }
            .store(in: &cancellables)

        FileWatchers.shared.perriQueue
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in
                guard let self else { return }
                self.perriQueue      = items
                self.perriQueueStale = false
                self.perriQueueError = nil
            }
            .store(in: &cancellables)

        // Broker connection state → brokerConnected
        broker.connected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.brokerConnected = $0 }
            .store(in: &cancellables)

        // Broker events → job map + derived status
        broker.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.applyBrokerEvent($0) }
            .store(in: &cancellables)

        FileWatchers.shared.start()
        client.start()
        broker.start()

        // Perri queue: immediate refresh on startup, then every 5 min
        triggerPerriQueueRefresh()
        perriQueueTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.triggerPerriQueueRefresh()
        }
    }

    // MARK: - Broker event fold

    private func applyBrokerEvent(_ event: BrokerEvent) {
        switch event {
        case .hello:
            break   // connection state already set via broker.connected

        case .snapshot(let jobs):
            jobMap = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })
            publishJobsAndStatus()

        case .newJob(let job):
            // A job that was queued after the initial snapshot arrived.
            // The broker embeds the full payload in the "queued" event so
            // we can insert it directly rather than reconnecting.
            jobMap[job.id] = job
            publishJobsAndStatus()

        case .stateChange(let jobId, let eventKind, let question, let pausedReason, let toState):
            guard let existing = jobMap[jobId] else {
                log.debug("broker stateChange for unknown job \(jobId.prefix(8), privacy: .public) — ignoring")
                return
            }
            jobMap[jobId] = foldJobState(existing, eventKind: eventKind,
                                         question: question, pausedReason: pausedReason, toState: toState)
            publishJobsAndStatus()

        case .ping:
            break

        case .reconnected:
            // Clear stale state; next snapshot will repopulate
            jobMap.removeAll()
            publishJobsAndStatus()
        }
    }

    /// Mirror of the broker's foldState: maps event kind → updated MotherJob.
    private func foldJobState(_ job: MotherJob, eventKind: String,
                               question: String?, pausedReason: String?, toState: String?) -> MotherJob {
        var state = job.state
        var q     = job.question
        var pr    = job.pausedReason

        switch eventKind {
        case "queued", "ready", "running", "succeeded", "failed", "cancelled":
            state = eventKind; q = nil; pr = nil
        case "awaiting_input":
            state = "awaiting"; q = question; pr = nil
        case "paused_for_quota":
            state = "awaiting"; q = nil; pr = pausedReason
        case "resumed", "auto_resumed":
            state = "ready"; q = nil; pr = nil
        case "retried", "escalated":
            state = toState ?? "ready"; q = nil; pr = nil
        default:
            break  // non-state-affecting (current_activity, etc.)
        }

        return MotherJob(
            id: job.id, state: state, repo: job.repo, isolation: job.isolation,
            title: job.title,
            createdAt: job.createdAt, startedAt: job.startedAt, finishedAt: job.finishedAt,
            planPath: job.planPath, question: q, pausedReason: pr,
            adherenceStatus: job.adherenceStatus, currentTier: job.currentTier,
            kind:   job.kind,
            phases: job.phases,
            cycles: job.cycles
        )
    }

    private func publishJobsAndStatus() {
        // Sort: awaiting → running → queued → failed → succeeded → other; then by startedAt desc
        let order: [String: Int] = ["awaiting": 0, "running": 1, "queued": 2, "failed": 3, "succeeded": 4]
        let jobs = jobMap.values.sorted {
            let a = order[$0.state] ?? 5, b = order[$1.state] ?? 5
            if a != b { return a < b }
            return ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast)
        }
        motherJobs   = jobs
        motherStatus = MotherStatus.from(jobs: jobs)
    }

    // MARK: - Mother action methods (called from MotherView)

    func answerJob(_ id: String, text: String) {
        broker.answer(job: id, text: text) { [weak self] result in
            self?.handleActionResult(result, verb: "answer")
        }
    }

    func cancelJob(_ id: String) {
        broker.cancel(job: id) { [weak self] result in
            self?.handleActionResult(result, verb: "cancel")
        }
    }

    func retryJob(_ id: String) {
        broker.retry(job: id) { [weak self] result in
            self?.handleActionResult(result, verb: "retry")
        }
    }

    func forceStartJob(_ id: String) {
        broker.forceStart(job: id) { [weak self] result in
            self?.handleActionResult(result, verb: "force-start")
        }
    }

    func archiveJob(_ id: String) {
        guard let bin = AppStore.findBinary("mother") else {
            motherActionError = "mother binary not found"
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let proc = Process()
            proc.executableURL = bin
            proc.arguments = ["archive", id]
            try? proc.run()
            proc.waitUntilExit()
        }
    }

    func archiveAllJobs() {
        guard let bin = AppStore.findBinary("mother") else {
            motherActionError = "mother binary not found"
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let proc = Process()
            proc.executableURL = bin
            proc.arguments = ["archive", "--older-than", "0"]
            try? proc.run()
            proc.waitUntilExit()
        }
    }

    func openPlan(path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func clearMotherActionError() { motherActionError = nil }

    private func handleActionResult(_ result: Result<Void, BrokerError>, verb: String) {
        switch result {
        case .success:
            log.info("broker \(verb) succeeded")
        case .failure(let err):
            log.warning("broker \(verb) failed: \(err.userFacingMessage, privacy: .public)")
            motherActionError = err.userFacingMessage
        }
    }

    // MARK: - Perri queue

    func refreshPerriQueue() {
        guard !perriQueueLoading else { return }
        perriQueueLoading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            Self.runPerriQueuePane()
            DispatchQueue.main.async { self?.perriQueueLoading = false }
        }
    }

    private func triggerPerriQueueRefresh() {
        guard !perriQueueLoading else { return }
        perriQueueLoading = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            Self.runPerriQueuePane()
            DispatchQueue.main.async { self?.perriQueueLoading = false }
        }
    }

    private static func runPerriQueuePane() {
        guard let binary = findBinary("perri-queue-pane") else {
            log.warning("perri-queue-pane not found — skipping refresh")
            return
        }
        let proc = Process()
        proc.executableURL = binary
        proc.arguments     = ["--json"]

        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["/usr/local/bin", "/opt/homebrew/bin",
                     "\(home)/.npm/bin", "\(home)/.local/bin",
                     "\(home)/.claude/bin"].joined(separator: ":")
        env["PATH"] = (env["PATH"] ?? "") + ":" + extra
        proc.environment    = env
        proc.standardOutput = Pipe()
        proc.standardError  = Pipe()

        do    { try proc.run(); proc.waitUntilExit() }
        catch { log.warning("perri-queue-pane launch failed: \(error.localizedDescription, privacy: .public)") }

        if proc.terminationStatus != 0 {
            log.warning("perri-queue-pane exited \(proc.terminationStatus, privacy: .public)")
        }
    }

    private static func findBinary(_ name: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/usr/local/bin/\(name)", "/opt/homebrew/bin/\(name)",
            "\(home)/.local/bin/\(name)", "\(home)/.claude/bin/\(name)",
        ]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: hit)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments     = [name]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try? proc.run(); proc.waitUntilExit()
        let p = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return p.isEmpty ? nil : URL(fileURLWithPath: p)
    }

    // MARK: - IPC handling (nostromd session/activity events)

    private func handle(_ msg: ServerMsg) {
        switch msg {
        case .welcome(let version, let pid):
            log.info("nostromd v\(version, privacy: .public) pid \(pid, privacy: .public)")

        case .motherJobs(let jobs):
            // Ignored — jobs now come from the broker
            log.debug("mother_jobs IPC message ignored (broker is source of truth)")
            _ = jobs

        case .motherStatusline:
            // Ignored — status now derived from broker job map
            break

        case .activity(let ev):
            log.debug("activity: \(ev.agent, privacy: .public) — \(ev.summary, privacy: .public)")
            recentActivity.append(ev)
            if recentActivity.count > 64 { recentActivity.removeFirst() }

        case .error(let msg):
            log.error("Daemon error: \(msg, privacy: .public)")

        case .sessionSpawned, .sessionTurns, .sessionTurnDelta,
             .sessionState, .sessionPermissionRequest, .sessionExited:
            break

        case .pong, .unknown:
            break
        }
    }
}
