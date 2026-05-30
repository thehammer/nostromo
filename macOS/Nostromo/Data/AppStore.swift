import Foundation
import Combine
import os

private let log = Logger(subsystem: "com.hammer.nostromo", category: "store")

/// Shared observable state for the whole app.
///
/// Data flows: NostromodClient (IPC) and FileWatchers (flat files) → AppStore → UI.
/// All mutations happen on the main queue; UI components can read directly.
class AppStore: ObservableObject {
    static let shared = AppStore()

    // MARK: - Published state

    // Mother
    @Published private(set) var motherStatus: MotherStatus = MotherStatus()
    @Published private(set) var motherJobs:   [MotherJob]  = []

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

    // MARK: - Internals

    private let client = NostromodClient()
    private var cancellables        = Set<AnyCancellable>()
    private var perriQueueTimer:    Timer?
    private var motherJobsTimer:    Timer?

    /// Shared ChatSession instances keyed by agent tag.
    /// Multiple windows showing the same tag observe the same session (mirrored).
    private var sessionRegistry: [String: ChatSession] = [:]

    private init() {}

    // MARK: - Session registry

    func session(for tag: String, workingDirectory: String? = nil) -> ChatSession {
        if let s = sessionRegistry[tag] { return s }
        let s = ChatSession(tag: tag, workingDirectory: workingDirectory)
        sessionRegistry[tag] = s
        return s
    }

    // MARK: - Startup

    func start() {
        log.info("AppStore starting")
        // IPC messages
        client.messages
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.handle($0) }
            .store(in: &cancellables)

        // File-backed data
        FileWatchers.shared.rateLimits
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.rateLimits = $0 }
            .store(in: &cancellables)

        FileWatchers.shared.posture
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.posture = $0 }
            .store(in: &cancellables)

        FileWatchers.shared.motherStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.motherStatus = $0 }
            .store(in: &cancellables)

        // Subscribe to the perri queue cache watcher — this fires immediately with
        // whatever's in ~/.claude/state/perri/.queue.cache.json, then updates whenever
        // any process (Perri skill, TUI, ↺ button) writes a fresh cache.
        FileWatchers.shared.perriQueue
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in
                guard let self else { return }
                self.perriQueue      = items
                self.perriQueueStale = false
                self.perriQueueError = nil
            }
            .store(in: &cancellables)

        FileWatchers.shared.start()
        client.start()

        // Poll mother jobs directly via `mother list --format json`.
        pollMotherJobs()
        motherJobsTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.pollMotherJobs()
        }

        // Fire a background refresh on startup so data is fresh, then every 5 min.
        triggerPerriQueueRefresh()
        perriQueueTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.triggerPerriQueueRefresh()
        }
    }

    private func pollMotherJobs() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let mother = Self.findMother() else { return }
            let proc = Process()
            proc.executableURL = mother
            proc.arguments = ["list", "--format", "json"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError  = Pipe()
            guard (try? proc.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard let jobs = try? JSONDecoder().decode([MotherJobSlim].self, from: data) else { return }
            var status = MotherStatus()
            for job in jobs {
                switch job.state {
                case "running":  status.running  += 1
                case "queued":   status.queued   += 1
                case "awaiting": status.awaiting += 1
                case "failed":   status.failed   += 1
                default: break
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.motherJobs   = jobs.map { $0.toMotherJob() }
                self.motherStatus = status
            }
        }
    }

    private static func findMother() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/usr/local/bin/mother",
            "/opt/homebrew/bin/mother",
            "\(home)/.local/bin/mother",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    // MARK: - Perri queue

    /// Refresh the perri queue by running perri-queue-pane in the background.
    /// The cache file write triggers the FileWatchers FSEvent, which publishes the result.
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

    /// Run `perri-queue-pane --json` as a side-effect: it writes a fresh result to
    /// `~/.claude/state/perri/.queue.cache.json`, which the FileWatchers FSEvent
    /// watcher picks up and publishes.  Return value is intentionally discarded.
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
        proc.environment   = env
        proc.standardOutput = Pipe()   // discard — watcher reads the cache file
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
        // Fallback: ask `which`
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

    // MARK: - IPC handling

    private func handle(_ msg: ServerMsg) {
        switch msg {
        case .welcome(let version, let pid):
            log.info("nostromd v\(version, privacy: .public) pid \(pid, privacy: .public)")

        case .motherJobs(let jobs):
            log.debug("mother_jobs: \(jobs.count, privacy: .public) jobs")
            motherJobs = jobs

        case .motherStatusline(let status):
            log.debug("mother_statusline: ▶\(status.running, privacy: .public) ⏸\(status.queued, privacy: .public) ?\(status.awaiting, privacy: .public) !\(status.failed, privacy: .public)")
            motherStatus = status

        case .activity(let ev):
            log.debug("activity: \(ev.agent, privacy: .public) — \(ev.summary, privacy: .public)")
            recentActivity.append(ev)
            if recentActivity.count > 64 { recentActivity.removeFirst() }

        case .error(let msg):
            log.error("Daemon error: \(msg, privacy: .public)")

        case .pong, .unknown:
            break
        }
    }
}
