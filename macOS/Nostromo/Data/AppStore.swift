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
    /// Live peek snapshots keyed by job id. Cleared on disconnect and on terminal transition.
    @Published private(set) var motherPeeks:        [String: MotherPeekPayload] = [:]
    /// True while the broker socket is connected (hello received + subscribe sent).
    @Published private(set) var brokerConnected:    Bool         = false
    /// Set on action failure; UI observes and clears after display.
    @Published private(set) var motherActionError:  String?      = nil

    // Budget
    @Published private(set) var rateLimits: RateLimits?     = nil
    @Published private(set) var posture:    PostureSnapshot? = nil

    // Activity — one assembled ActivityStreamModel per focus tag (keyed by
    // ActivityEvent.focusTag, or "unattributed" for events the daemon
    // couldn't resolve to a known focus — never dropped, never guessed at).
    @Published private(set) var activityModels: [String: ActivityStreamModel] = [:]
    /// Daemon-wide ambient-activity ingestion health. Defaults optimistic
    /// (ingesting) until the first real `ActivityHealth` frame arrives on
    /// connect, so a fresh launch doesn't flash a false "not receiving" state.
    @Published private(set) var activityHealth = ActivityHealthState(ingesting: true, reason: nil, hookInstalled: true)

    // Teri todos
    @Published private(set) var teriTodos:            TeriTodosSnapshot? = nil

    // Perri PR queue
    @Published private(set) var perriQueue:          [PRQueueItem]  = []
    @Published private(set) var perriQueueStale:     Bool           = false
    @Published private(set) var perriQueueError:     String?        = nil
    @Published private(set) var perriQueueLoading:   Bool           = false

    // Perri PR detail pane
    @Published private(set) var perriDetail:         PRDetail?      = nil
    @Published private(set) var perriDetailLoading:  Bool           = false

    // Fred mailbox + calendar — updated from fred_state IPC broadcasts.
    @Published private(set) var fredMailbox:  MailboxSnapshot?  = nil
    @Published private(set) var fredCalendar: CalendarSnapshot? = nil

    // Active focus agent tag — set by MainLayout on every focus switch.
    @Published private(set) var activeFocusAgentTag: String?      = nil

    // Agent-authored pane layout (Phase 1).
    // Keyed by focus tag; updated from FocusLayout / PaneContent broadcasts.
    @Published private(set) var focusLayouts: [String: FocusLayoutModel] = [:]

    // Session health — keyed by focus agent tag.
    // Updated from the IPC stream for every tag the client sees events for,
    // so the sidebar badge can render for any opened focus without the active
    // focus view being visible. `.healthy` entries are omitted (implicitly healthy).
    @Published private(set) var sessionHealth: [String: SessionHealth] = [:]

    // Daemon-driven decision modal (W6). A single flat slot rather than a
    // per-tag map: only one sheet is ever shown at a time (out of scope: a
    // decision-queue UI), and the daemon enforces at most one outstanding
    // request per *focus tag* on the wire — this slot just tracks whichever
    // one most recently arrived. Overwritten (not queued) on every new
    // `decision_request` frame; `MainLayout` presents it and clears it once
    // answered or dismissed.
    @Published private(set) var pendingDecision: PendingDecision?

    // MARK: - Internals

    /// Exposed so `TranscriptLoadHarness` can inject synthetic daemon traffic
    /// through the real production code path rather than a parallel one.
    let client = NostromodClient()
    private let broker  = MotherBrokerClient()
    private var cancellables     = Set<AnyCancellable>()
    /// Per-PR detail cache keyed by "{repo-with-dashes}-{number}".
    private var prDetailCache: [String: PRDetail] = [:]
    /// The item whose detail the user most recently requested; used to ignore stale fetches.
    private var pendingSelection: PRQueueItem?

    /// In-memory job map keyed by id — folded from broker snapshot + events.
    private var jobMap: [String: MotherJob] = [:]

    /// Shared ChatSession instances keyed by agent tag.
    private var sessionRegistry: [String: ChatSession] = [:]

    private init() {}

    // MARK: - Memory self-defense

    /// Live transcript panes, weakly held, so the watchdog can tell them to shed.
    private let transcriptPanes = NSHashTable<ReplView>.weakObjects()
    private let watchdog = MemoryWatchdog()
    /// Where shed/warning toasts are shown. Set by `MainLayout`.
    var onMemoryToast: ((String, ToastSeverity) -> Void)?

    func registerTranscriptPane(_ pane: ReplView) {
        transcriptPanes.add(pane)
    }

    /// Start watching the app's own footprint. Called once, from `AppDelegate`.
    func startMemoryWatchdog() {
        // `done` is called once every pane has finished compacting, so the
        // watchdog measures memory that has actually been freed rather than
        // memory it has only asked for. Two panes can share one `ChatSession`
        // (same tag): the second `compactBatch` finds every candidate already in
        // flight, returns `false`, and its completion fires immediately — so the
        // group still balances.
        watchdog.onShed = { [weak self] done in
            guard let self else { done(); return }
            let panes = self.transcriptPanes.allObjects
            guard !panes.isEmpty else { done(); return }
            let group = DispatchGroup()
            for pane in panes {
                group.enter()
                pane.shedMaterializedViews { group.leave() }
            }
            group.notify(queue: .main) { done() }
        }
        watchdog.onWarn = { [weak self] title, detail in
            self?.onMemoryToast?("\(title) — \(detail)", .warning)
        }
        watchdog.start()
    }

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

    // MARK: - Decision modal (W6)

    /// Send the operator's answer to the daemon and clear `pendingDecision` if
    /// it's still the one being answered — a later `decision_request` may
    /// already have overwritten it (see `pendingDecision`'s doc comment).
    /// Recording the answer into `DecisionStore` is `DecisionSheet`'s job, not
    /// this one — this method only forwards the answer over the wire.
    func answerDecision(requestId: String, choiceId: String?) {
        client.decisionAnswer(requestId: requestId, choiceId: choiceId)
        if pendingDecision?.requestId == requestId {
            pendingDecision = nil
        }
    }

    // MARK: - Ambient activity (activity-path wedge)

    /// Key `activityModels` is stored under for an event the daemon could not
    /// attribute to a known focus — never dropped, never guessed onto an
    /// arbitrary tab.
    static let unattributedActivityKey = "__unattributed__"

    /// The `ActivityStreamModel` for `tag`, or an empty (neutral "waiting")
    /// model if nothing has arrived for it yet.
    func activityModel(for tag: String) -> ActivityStreamModel {
        activityModels[tag] ?? ActivityStreamModel()
    }

    /// Return the ChatSession for `tag` if one has already been created (lazy —
    /// does not create a new session). Used by health UI that needs to call
    /// `restart()` / `dismissHealth()` without triggering a new spawn.
    func sessionForHealthView(tag: String) -> ChatSession? {
        sessionRegistry[tag]
    }

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

        // Perri detail — arrives when current-pr-detail.json is written by the daemon.
        FileWatchers.shared.perriDetail
            .receive(on: DispatchQueue.main)
            .sink { [weak self] detail in self?.handleDetailUpdate(detail) }
            .store(in: &cancellables)

        // pr-cache dir changed — re-check if pending selection is now warm.
        FileWatchers.shared.prCacheChanged
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.checkPrCacheForPendingSelection() }
            .store(in: &cancellables)

        // Broker connection state → brokerConnected + daemon recovery.
        // When the broker goes offline, attempt `mother daemon start` after a
        // short delay as a backstop — the launchd plist keeps the runner alive
        // for most cases, but a clean-exit race or a crashed broker can leave
        // the daemon stopped without launchd noticing.
        broker.connected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                self?.brokerConnected = connected
                if !connected {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                        guard let self, !self.brokerConnected else { return }
                        log.warning("broker offline — attempting 'mother daemon start'")
                        let proc = Process()
                        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                        proc.arguments = ["mother", "daemon", "start"]
                        proc.environment = ProcessInfo.processInfo.environment
                        try? proc.run()
                    }
                }
            }
            .store(in: &cancellables)

        // Broker events → job map + derived status
        broker.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.applyBrokerEvent($0) }
            .store(in: &cancellables)

        FileWatchers.shared.start()
        // Under the load harness the daemon connection is suppressed entirely, so
        // a measurement run never contends with — or is polluted by — live
        // sessions. The harness drives `client.messages` / `client.connected`
        // itself, which is the same path the daemon's traffic takes.
        if TranscriptLoadHarness.isActive {
            TranscriptLoadHarness.startIfRequested(client: client)
        } else {
            client.start()
        }
        broker.start()

        // Fallback poll: `mother list --format json` every 30 s reconciles any
        // external changes (e.g. tmux archive) that the broker didn't broadcast.
        // The broker is authoritative for live events; this only catches stragglers.
        Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.pollMotherList() }
            .store(in: &cancellables)

        // Phase 1: keep the daemon's focus registry mirrored from the Mac.
        client.connected
            .receive(on: DispatchQueue.main)
            .filter { $0 }                       // push on each successful (re)connect
            .sink { [weak self] _ in self?.pushFocusRegistry() }
            .store(in: &cancellables)

        FocusStore.shared.$focuses
            .receive(on: DispatchQueue.main)
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.pushFocusRegistry() }
            .store(in: &cancellables)

        // Perri queue: the daemon keeps the "queue" pane live on its own via
        // the live-pane-sources source-binding broadcaster — no FSEvents
        // watcher and no periodic bash shell-out needed on this side anymore.
        // The refresh button writes queue.dirty to ask the daemon for an
        // immediate cycle; `nostromo.refresh_pane_content` does the same
        // for an agent-driven refresh.
    }

    private func pushFocusRegistry() {
        client.focusRegistryPush(FocusStore.shared.wireProjection())
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
            guard jobMap[jobId] != nil else {
                log.debug("broker stateChange for unknown job \(jobId.prefix(8), privacy: .public) — ignoring")
                return
            }
            if eventKind == "archived" {
                // Archived jobs leave the queue entirely.
                jobMap.removeValue(forKey: jobId)
            } else {
                let updated = foldJobState(jobMap[jobId]!, eventKind: eventKind,
                                           question: question, pausedReason: pausedReason, toState: toState)
                jobMap[jobId] = updated
                // Clear peek snapshot on terminal transition — the daemon sends an
                // empty clear too, but removing here avoids any flash between the
                // state change and the next peek poll.
                let terminalStates: Set<String> = ["succeeded", "failed", "cancelled"]
                if terminalStates.contains(updated.state) {
                    motherPeeks.removeValue(forKey: jobId)
                }
            }
            publishJobsAndStatus()

        case .ping:
            break

        case .reconnected:
            // Clear stale state; next snapshot will repopulate
            jobMap.removeAll()
            motherPeeks.removeAll()
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

    /// True while a `pollMotherList()` subprocess is in flight. Read/written only
    /// on the main thread (the timer fires on `.main`, and the background poll's
    /// completion always hops back to `.main` before touching this), so no lock
    /// is needed. Guards against unbounded subprocess pileup: without it, a
    /// single stuck poll (e.g. a pipe deadlock) would leave every subsequent
    /// 30s tick free to spawn yet another subprocess on top of it.
    private var motherPollInFlight = false

    private func pollMotherList() {
        guard !motherPollInFlight else { return }
        guard let bin = AppStore.findBinary("mother") else { return }
        motherPollInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer {
                DispatchQueue.main.async { self?.motherPollInFlight = false }
            }
            guard let result = ProcessRunner.runCapturingStdout(bin, arguments: ["list", "--format", "json"]),
                  result.status == 0
            else { return }
            // Parse just the job ids and states to detect jobs that have been
            // externally archived (removed from mother's list) so we can remove
            // them from our jobMap without a broker event.
            guard let raw = try? JSONSerialization.jsonObject(with: result.data) as? [[String: Any]] else { return }
            let liveIds = Set(raw.compactMap { $0["id"] as? String })
            DispatchQueue.main.async {
                guard let self else { return }
                let stale = self.jobMap.keys.filter { !liveIds.contains($0) }
                if !stale.isEmpty {
                    stale.forEach { self.jobMap.removeValue(forKey: $0) }
                    self.publishJobsAndStatus()
                }
            }
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
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let proc = Process()
            proc.executableURL = bin
            proc.arguments = ["archive", id]
            try? proc.run()
            proc.waitUntilExit()
            // Optimistically remove from UI — the broker may push an "archived"
            // event too, but jobMap.removeValue is idempotent so the double-remove
            // is harmless. Without this the list only updates if/when the broker
            // event arrives, which can be delayed or absent.
            guard proc.terminationStatus == 0 else { return }
            DispatchQueue.main.async {
                self?.jobMap.removeValue(forKey: id)
                self?.publishJobsAndStatus()
            }
        }
    }

    func archiveAllJobs() {
        guard let bin = AppStore.findBinary("mother") else {
            motherActionError = "mother binary not found"
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let proc = Process()
            proc.executableURL = bin
            proc.arguments = ["archive", "--older-than", "0"]
            try? proc.run()
            proc.waitUntilExit()
            // Optimistically remove all terminal-state jobs from the UI.
            guard proc.terminationStatus == 0 else { return }
            DispatchQueue.main.async {
                let terminal: Set<String> = ["succeeded", "failed", "cancelled"]
                self?.jobMap = self?.jobMap.filter { !terminal.contains($0.value.state) } ?? [:]
                self?.publishJobsAndStatus()
            }
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

    /// Ask the Rust daemon for an immediate queue re-fetch by writing the dirty sentinel.
    func refreshPerriQueue() {
        let home    = FileManager.default.homeDirectoryForCurrentUser.path
        let dirty   = "\(home)/.claude/state/perri/queue.dirty"
        DispatchQueue.global(qos: .userInitiated).async {
            try? FileManager.default.createDirectory(atPath: "\(home)/.claude/state/perri",
                                                     withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: dirty, contents: nil)
            log.debug("wrote queue.dirty sentinel")
        }
    }

    // MARK: - Perri PR detail

    /// Called when the user selects a PR row.
    func selectPR(_ item: PRQueueItem) {
        pendingSelection = item
        let key = prDetailCacheKey(item)

        // Cache hit: SHA matches (or we don't have a SHA yet — accept on TTL grounds).
        if let cached = prDetailCache[key],
           (item.headSha.isEmpty || cached.headSha == item.headSha) {
            perriDetail        = cached
            perriDetailLoading = false
            return
        }

        // Cache miss: show loading state and ask the daemon.
        perriDetail        = nil
        perriDetailLoading = true

        let home    = FileManager.default.homeDirectoryForCurrentUser.path
        let stateDir = "\(home)/.claude/state/perri"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try FileManager.default.createDirectory(atPath: stateDir,
                                                        withIntermediateDirectories: true)
                // Write current-pr.json (single-slot signal to the daemon).
                let pointer: [String: Any] = ["number": item.number, "repo": item.repo]
                let data = try JSONSerialization.data(withJSONObject: pointer,
                                                      options: [.prettyPrinted])
                try data.write(to: URL(fileURLWithPath: "\(stateDir)/current-pr.json"),
                               options: .atomic)
                // Write the dirty sentinel so the daemon fetches immediately.
                FileManager.default.createFile(atPath: "\(stateDir)/current-pr.dirty",
                                               contents: nil)
            } catch {
                log.warning("selectPR signal write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Thin helpers for typed-content action dispatch

    /// Load a PR by identity only — used by `pr_list` pane rows where we have
    /// `repo` + `number` but no full `PRQueueItem`. Writes the same sentinels as
    /// `selectPR(_:)` so the daemon fetches and broadcasts the diff/CI detail.
    func loadPR(repo: String, number: Int) {
        // Build a minimal PRQueueItem shell so we can reuse selectPR's cache key logic.
        let shell = PRQueueItem(
            repo:        repo,
            number:      number,
            title:       "",
            author:      "",
            bucket:      "needs_review",
            newActivity: false,
            url:         "",
            ciState:     .unknown,
            headSha:     ""
        )
        selectPR(shell)
    }

    /// Called when FileWatchers receives an updated PRDetail from current-pr-detail.json.
    private func handleDetailUpdate(_ detail: PRDetail?) {
        guard let detail else { return }
        let key = "\(detail.repo.replacingOccurrences(of: "/", with: "-"))-\(detail.prNumber ?? 0)"
        prDetailCache[key] = detail

        // Only publish if this matches the currently-pending selection.
        guard let pending = pendingSelection,
              detail.repo == pending.repo,
              (detail.prNumber.map { Int($0) } ?? -1) == pending.number
        else { return }

        perriDetail        = detail
        perriDetailLoading = false
        pushDetailToDiffPane(detail)
    }

    /// Called when the pr-cache/ directory changes — re-check if pending selection is warm.
    private func checkPrCacheForPendingSelection() {
        guard let pending = pendingSelection, perriDetailLoading else { return }
        let key  = prDetailCacheKey(pending)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = "\(home)/.claude/state/perri/pr-cache/\(key).json"

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let data   = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let detail = try? JSONDecoder().decode(PRDetail.self, from: data)
            else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.prDetailCache[key] = detail
                // Only satisfy if still pending for this item.
                guard let still = self.pendingSelection,
                      detail.repo == still.repo,
                      (detail.prNumber.map { Int($0) } ?? -1) == still.number
                else { return }
                self.perriDetail        = detail
                self.perriDetailLoading = false
                self.pushDetailToDiffPane(detail)
            }
        }
    }


    /// Push a formatted PRDetail summary into the Perri diff pane.
    private func pushDetailToDiffPane(_ detail: PRDetail) {
        let number = detail.prNumber.map { $0 } ?? 0
        let divider = String(repeating: "─", count: 60)

        // ── Header ────────────────────────────────────────────────────────────
        var lines: [String] = [
            detail.title,
            "\(detail.repo) #\(number) · \(detail.author)",
            divider,
        ]

        // ── Links ─────────────────────────────────────────────────────────────
        lines.append("🔗 GitHub  \(detail.url)")
        // Extract Jira ticket key from title (e.g. "CORE-1234", "PAYM-567")
        let jiraPattern = #"[A-Z]{2,6}-\d+"#
        if let range = detail.title.range(of: jiraPattern, options: .regularExpression),
           !detail.title[range].isEmpty {
            let key = String(detail.title[range])
            lines.append("📋 Jira    https://carefeed.atlassian.net/browse/\(key)")
        }
        lines.append("")

        // ── Stats ─────────────────────────────────────────────────────────────
        let fileWord = detail.changedFiles == 1 ? "file" : "files"
        lines.append("📊 +\(detail.additions)  -\(detail.deletions)  in \(detail.changedFiles) \(fileWord)")
        lines.append("")

        // ── CI checks ─────────────────────────────────────────────────────────
        if !detail.ciChecks.isEmpty {
            let passing = detail.ciChecks.filter { $0.state == .success }
            let failing = detail.ciChecks.filter { $0.state == .failure }
            let pending = detail.ciChecks.filter { $0.state == .pending }
            let unknown = detail.ciChecks.filter { $0.state == .unknown }

            var ciSummary = "CI  "
            if !passing.isEmpty { ciSummary += "✓ \(passing.count) passing  " }
            if !pending.isEmpty { ciSummary += "○ \(pending.count) pending  " }
            if !failing.isEmpty { ciSummary += "✗ \(failing.count) failing  " }
            if !unknown.isEmpty { ciSummary += "? \(unknown.count) unknown" }
            lines.append(ciSummary.trimmingCharacters(in: .whitespaces))

            // Surface failing checks with detail
            for check in failing {
                lines.append("  ✗ \(check.name)")
                if let d = check.detail, !d.isEmpty {
                    lines.append("    \(d.prefix(200))")
                }
            }
            // Surface pending checks
            for check in pending {
                lines.append("  ○ \(check.name)")
            }
            lines.append("")
        }

        // ── Diff ──────────────────────────────────────────────────────────────
        // Deliberately absent (W2 — curated-agent-views). This used to append
        // the first 150 diff lines and a "… N more lines" apology. The diff
        // now has a real renderer — the daemon's `perri.get_pr_diff` source
        // parses it per file/hunk/line and `CodeContentView` draws it with a
        // gutter — so this function's job shrinks to the header/links/stats/CI
        // summary it was actually good at. A client-side line budget was the
        // silent truncation the PRD set out to remove.

        var model = focusLayouts["perri"] ?? FocusLayoutModel.initial
        // Never overwrite a pane the daemon is driving with structured content
        // (W2). This writes `focusLayouts` directly, bypassing the
        // `.paneContent` handler entirely, so without this guard a `Diff` or
        // `Code` push would be clobbered within milliseconds of arriving and
        // the pane would flicker back to a text summary on every PR load.
        // `nil` and `.text` are the states this function has always owned.
        switch model.paneContent["diff"] {
        case nil, .text:
            model.paneContent["diff"] = .text(lines.joined(separator: "\n"))
            focusLayouts["perri"] = model
        default:
            break
        }
    }

    private func prDetailCacheKey(_ item: PRQueueItem) -> String {
        "\(item.repo.replacingOccurrences(of: "/", with: "-"))-\(item.number)"
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
        guard let result = ProcessRunner.runCapturingStdout(URL(fileURLWithPath: "/usr/bin/which"), arguments: [name]) else {
            return nil
        }
        let p = String(data: result.data, encoding: .utf8)?
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

        case .motherPeek(let payload):
            if payload.isEmpty {
                motherPeeks.removeValue(forKey: payload.jobId)
            } else {
                motherPeeks[payload.jobId] = payload
            }

        case .motherStatusline:
            // Ignored — status now derived from broker job map
            break

        case .activity(let ev):
            log.debug("activity: \(ev.agent, privacy: .public) — \(ev.summary, privacy: .public)")
            let tag = ev.focusTag ?? Self.unattributedActivityKey
            var model = activityModels[tag] ?? ActivityStreamModel()
            let gapDetected = model.ingest(ev)
            activityModels[tag] = model
            if gapDetected {
                // A seq gap means this stream may already be presenting an
                // incomplete record — re-sync from a full daemon snapshot
                // rather than silently continue with a hole in the history.
                log.debug("activity seq gap detected for \(tag, privacy: .public) — requesting a fresh snapshot")
                client.requestActivitySnapshot(tag: tag)
            }

        case .activitySnapshot(let tag, let streams):
            var model = ActivityStreamModel()
            for stream in streams {
                for event in stream.events {
                    model.ingest(event)
                }
            }
            activityModels[tag] = model

        case .activityHealth(let ingesting, let reason, _, let hookInstalled):
            activityHealth = ActivityHealthState(ingesting: ingesting, reason: reason, hookInstalled: hookInstalled)

        case .error(let msg):
            log.error("Daemon error: \(msg, privacy: .public)")

        case .sessionState(let tag, let state):
            // Derive health for the sparse sidebar badge map (all focuses, not just
            // the one with an active ChatSession view).
            switch state {
            case .idle, .midTurn, .awaitingPermission:
                applySessionHealth(.healthy, for: tag)
            case .crashed:
                applySessionHealth(.recovering, for: tag)
            }

        case .sessionDown(let tag, let reason):
            if reason == .user {
                applySessionHealth(.healthy, for: tag)
            } else {
                applySessionHealth(.permanentlyDown(reason), for: tag)
            }

        case .sessionSummaryUpdate(let tag, let summary):
            FocusStore.shared.updateSummary(tag: tag, summary: summary)

        case .perriState(let queue, let current):
            // Daemon push is an additive, lower-latency source feeding the same
            // publishers the file-watchers already drive.  The file-watcher path
            // is preserved (not removed) in this wedge.
            perriQueue      = queue
            perriQueueStale = false
            perriQueueError = nil
            // `current` is already decoded as PRDetail? from the wire shape.
            if let current { perriDetail = current }

        case .fredState(let mailbox, let calendar):
            fredMailbox  = mailbox
            fredCalendar = calendar

        case .teriState(let snap):
            teriTodos = snap

        case .sessionSpawned, .sessionTurns, .sessionTurnDelta,
             .sessionPermissionRequest, .sessionExited:
            break

        // ── agent-authored pane layout (Phase 1) ─────────────────────────────
        case .focusLayout(let tag, let tree, let focusedPane):
            // Structural update — rebuild the tree for this focus. Content is
            // preserved (content pushes are decoupled from layout geometry).
            var model = focusLayouts[tag] ?? FocusLayoutModel.initial
            model.tree        = tree
            model.focusedPane = focusedPane
            focusLayouts[tag] = model

        case .paneContent(let tag, let paneId, let content, let freshness, let address):
            // Content update — update the leaf without touching tree geometry so
            // operator drag-resizes survive.
            var model = focusLayouts[tag] ?? FocusLayoutModel.initial
            let existingContent = model.paneContent[paneId]
            // A `.loading` update must never clobber content the operator is
            // already looking at — render it only on first paint (D10): no
            // prior content for this pane, or the prior content was itself
            // `.loading`.
            if content == .loading, let existingContent, existingContent != .loading {
                return
            }
            // No-op write guard (D9): an idempotent push (identical content,
            // freshness, and address) causes zero @Published churn downstream
            // — no flicker, no scroll reset, no spinner. An address-only
            // change (W1) must NOT be swallowed here, which is why it's part
            // of this comparison.
            if existingContent == content
                && model.paneFreshness[paneId] == freshness
                && model.paneAddress[paneId] == address {
                return
            }
            model.paneContent[paneId] = content
            model.paneFreshness[paneId] = freshness
            model.paneAddress[paneId] = address
            focusLayouts[tag] = model

        case .decisionRequest(let tag, let requestId, let prompt, let detail, let choices, let contextPaneId):
            // Overwrites any prior pending decision — see the property's doc
            // comment for why a single flat slot is correct here. `MainLayout`
            // observes this and presents the sheet; nothing here decides
            // presentation or touches `DecisionStore`.
            pendingDecision = PendingDecision(tag: tag, requestId: requestId, prompt: prompt,
                                              detail: detail, choices: choices, contextPaneId: contextPaneId)

        case .focusCreated(let meta):
            // An agent-spawned focus was created — add it to FocusStore so the
            // tab appears, and seed an empty layout so DynamicFocusView has state.
            let focus = meta.toFocus()
            FocusStore.shared.add(focus)
            if focusLayouts[meta.tag] == nil {
                focusLayouts[meta.tag] = FocusLayoutModel.initial
            }

        case .pong, .unknown:
            break
        }
    }

    /// Update `sessionHealth` for `tag`. `.healthy` entries are removed to keep
    /// the map sparse (healthy is the default / zero value).
    private func applySessionHealth(_ health: SessionHealth, for tag: String) {
        if health == .healthy {
            sessionHealth.removeValue(forKey: tag)
        } else {
            sessionHealth[tag] = health
        }
    }
}
