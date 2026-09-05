import AppKit
import Foundation
import Combine
import os

private let log = Logger(subsystem: "com.hammer.nostromo", category: "store")
/// Shared with `DynamicFocusView.swift`'s render-path logging (same
/// subsystem/category there) so `log show --predicate 'category == "panes"'`
/// reads as one timeline: FocusLayout/PaneContent frame arrival here,
/// reconcile/content-push/layout on the render side. Counts, ids, kinds and
/// geometry only — never pane content.
private let panesLog = Logger(subsystem: "com.hammer.nostromo", category: "panes")

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
    // `ActivityStreamStore` bounds both axes: each model's own retention
    // (event count per stream, subagent stream entry count) and the number
    // of tracked focus tags itself — see the 2026-09-02 "unbounded memory
    // growth" bug doc and ActivityStreamModel.swift's retention constants.
    @Published private(set) var activityStreams = ActivityStreamStore()
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

    // Active focus SESSION tag — distinct from activeFocusAgentTag above.
    // Built-in focuses have agentTag == sessionTag (Focus.sessionTag), which
    // is why ActivityTickerView keying off activeFocusAgentTag looked fine
    // by coincidence; a project-scoped focus's sessionTag is
    // "\(agentTag)-\(id.prefix(8))", and that's what the daemon actually
    // stamps every activity event's focus_tag with (NOSTROMO_FOCUS_TAG, see
    // session_manager.rs), so the ticker must key off THIS, not the agent
    // tag. Set by MainLayout alongside activeFocusAgentTag, not instead of
    // it — PaceBarsView/StatusBarView are unrelated consumers of the agent
    // tag and must not regress.
    @Published private(set) var activeFocusSessionTag: String?    = nil

    // Agent-authored pane layout (Phase 1).
    // Keyed by focus tag; updated from FocusLayout / PaneContent broadcasts.
    // An entry's lifetime now exactly matches its focus's: `evictPerFocusState`
    // removes it the moment `FocusStore` reports the focus gone (see `start()`
    // and `fix/per-focus-state-eviction`). A built-in focus can never be
    // removed from `FocusStore`, so its entry is never evicted either.
    @Published private(set) var focusLayouts: [String: FocusLayoutModel] = [:]

    // Session health — keyed by focus agent tag.
    // Updated from the IPC stream for every tag the client sees events for,
    // so the sidebar badge can render for any opened focus without the active
    // focus view being visible. `.healthy` entries are omitted (implicitly healthy).
    // An entry's lifetime now ends with its focus, via `evictPerFocusState`.
    @Published private(set) var sessionHealth: [String: SessionHealth] = [:]

    // Daemon-driven decision modal (multi-window decision-sheet fix). Plain
    // `PassthroughSubject`s, NOT `@Published` — deliberately. `@Published`
    // replays its CURRENT value to every new subscriber, which is exactly
    // how a window opened mid-decision (a display attached while a request
    // is outstanding) would acquire a duplicate sheet the instant it
    // subscribes. A subject has no replay: a late subscriber sees nothing
    // until the next event, so presentation stays keyed to a single
    // subscriber (`DecisionPresenter`) rather than to "whoever's listening
    // right now". Same precedent as `FileWatchers.shared.thresholdEvents`.
    //
    // `decisionRequests` fires once per `decision_request` frame;
    // `decisionResolutions` fires once per `decision_resolved` frame (the
    // backstop that lets `DecisionPresenter` close a live sheet for reasons
    // the app itself couldn't otherwise know about: a timeout, a cancelled
    // session, or a second connected client).
    let decisionRequests = PassthroughSubject<PendingDecision, Never>()
    let decisionResolutions = PassthroughSubject<ResolvedDecision, Never>()

    // MARK: - Internals

    /// Exposed so `TranscriptLoadHarness` can inject synthetic daemon traffic
    /// through the real production code path rather than a parallel one.
    let client = NostromodClient()
    private let broker  = MotherBrokerClient()
    private var cancellables     = Set<AnyCancellable>()
    /// Per-PR detail cache keyed by "{repo-with-dashes}-{number}", bounded by
    /// an LRU eviction policy budgeted primarily in bytes
    /// (`PRDetailCache.maxRetainedDiffBytes`, 8 MiB) with a secondary entry
    /// cap (`PRDetailCache.maxRetainedEntries`, 64). See `PRDetailCache` for
    /// the policy itself.
    private var prDetailCache = PRDetailCache()
    /// The item whose detail the user most recently requested; used to ignore stale fetches.
    private var pendingSelection: PRQueueItem?

    /// In-memory job map keyed by id — folded from broker snapshot + events.
    private var jobMap: [String: MotherJob] = [:]

    /// Shared ChatSession instances keyed by agent tag. Like `focusLayouts`,
    /// an entry's lifetime now exactly matches its focus's — see
    /// `evictPerFocusState` and `start()`'s `FocusStore.shared.focusRemovals`
    /// subscription. The removed session is also `detach()`ed (not just
    /// dropped), which is what stops it re-issuing `session_spawn` on the
    /// next daemon reconnect (see `ChatSession.detach()`).
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

    /// Live code/diff panes, weakly held — mirrors `transcriptPanes` exactly,
    /// but for Debug ▸ Copy code-pane diagnostics rather than the memory
    /// watchdog (diagnostics job:
    /// `.claude/plans/instrument-code-pane-render-diagnostics.md`).
    private let codePanes = NSHashTable<CodeContentView>.weakObjects()

    func registerCodePane(_ pane: CodeContentView) {
        codePanes.add(pane)
    }

    /// One block per live code/diff pane: its render-audit report, which
    /// document kind it has loaded, row/label counts, and a truncated
    /// preview of its first few rows — enough to tell "the model is empty"
    /// from "the model is fine and the paint is not" without a debugger.
    func codePaneDiagnosticsReport() -> String {
        let panes = codePanes.allObjects
        guard !panes.isEmpty else { return "no live code/diff panes" }
        return panes.map { pane in
            let measurements = pane.currentMeasurements()
            let preview = pane.firstRowsPreview()
                .enumerated()
                .map { "  [\($0.offset)] \($0.element)" }
                .joined(separator: "\n")
            return """
                kind: \(pane.loadedKindDescription)
                \(CodePaneRenderAudit.report(of: measurements))
                first rows:
                \(preview.isEmpty ? "  (none)" : preview)
                """
        }.joined(separator: "\n---\n")
    }

    /// Every live agent-authored content pane, weakly held — mirrors
    /// `transcriptPanes` exactly. Registration must never be what keeps a
    /// pane alive; it exists only so "Copy pane diagnostics" (AppDelegate's
    /// Debug menu) can report on every pane currently on screen without a
    /// debugger.
    private let panes = NSHashTable<PaneContentNSView>.weakObjects()

    func registerPane(_ pane: PaneContentNSView) {
        panes.add(pane)
    }

    /// One line per live pane — content kind, sibling-renderer visibility,
    /// owning focus tag, and the `PaneFirstPaintAudit` verdict — everything
    /// needed to tell "the model is empty" from "the model is fine and the
    /// geometry is not" without a debugger. Never includes pane content.
    func paneDiagnosticsReport() -> String {
        let lines = panes.allObjects.map { $0.diagnosticsLine() }.sorted()
        guard !lines.isEmpty else { return "No live panes." }
        return lines.joined(separator: "\n")
    }

    /// Verbatim `PaneFirstPaintAudit.Measurements` for every live
    /// agent-authored pane, reusing the same `panes` registry
    /// `paneDiagnosticsReport()` reads — no second registry. Consumed by
    /// `TranscriptDiagnostics.snapshot()` (W1 — launch-smoke-test) and by
    /// `reconcile`'s own launch-layout observability note.
    func currentPaneMeasurements() -> [PaneFirstPaintAudit.Measurements] {
        panes.allObjects.map { $0.currentMeasurements() }
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

    /// Returns the shared `ChatSession` for `tag`, creating one if none
    /// exists yet. This is a **lazy creator**, which is exactly why the
    /// ordering in `FocusStore.remove(_:)` matters (see its comment): any
    /// caller that reaches this after a focus is removed but before every
    /// view holding a reference to its old session has let go would silently
    /// recreate — and re-spawn — the session eviction just removed.
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
    func setActiveFocusSessionTag(_ tag: String?) { activeFocusSessionTag = tag }

    // MARK: - Decision modal (multi-window decision-sheet fix)

    /// Forward the operator's answer to the daemon. Claiming the answer into
    /// `DecisionStore` is `DecisionSheet`'s job, not this one (it happens
    /// before this is even called) — this method only puts the frame on the
    /// wire. There is no local state here to clear: liveness/presentation
    /// tracking lives entirely in `DecisionStore`/`DecisionPresenter` now.
    func answerDecision(requestId: String, choiceId: String?) {
        client.decisionAnswer(requestId: requestId, choiceId: choiceId)
    }

    // MARK: - Ambient activity (activity-path wedge)

    /// Key `activityStreams` is stored under for an event the daemon could
    /// not attribute to a known focus — never dropped, never guessed onto an
    /// arbitrary tab. Aliases `ActivityStreamStore.unattributedTag`, which is
    /// the canonical value — `AppStore.swift` isn't part of
    /// `ActivityStreamModel.swift`'s dual `Sources`/`TestSources` membership,
    /// so the constant itself must live there, not here.
    static let unattributedActivityKey = ActivityStreamStore.unattributedTag

    /// The `ActivityStreamModel` for `tag`, or an empty (neutral "waiting")
    /// model if nothing has arrived for it yet.
    func activityModel(for tag: String) -> ActivityStreamModel {
        activityStreams.model(for: tag)
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

        // Per-focus state dies with the focus (fix/per-focus-state-eviction).
        // Keyed on focus REMOVAL specifically — never on a session-lifecycle
        // event (`.sessionExited`, `.sessionDown`, `.sessionState(.crashed)`)
        // — because every one of those is non-terminal (a benign stop, a
        // supervisor retry, a resumable daemon-side session) and evicting on
        // one would drop state for a session the operator could still return
        // to. A focus being removed is the one point its transcript becomes
        // permanently unreachable through the UI — see `FocusStore.focusRemovals`.
        FocusStore.shared.focusRemovals
            .receive(on: DispatchQueue.main)
            .sink { [weak self] focus in self?.evictPerFocusState(tag: focus.sessionTag) }
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

    /// Per-focus state dies with the focus. Called once per `focusRemovals`
    /// event (`start()`), never on any other schedule. Evicts `focusLayouts`,
    /// `sessionRegistry` (detached, not merely dropped — that is what stops
    /// the daemon-side session from being respawned on the next reconnect),
    /// and `sessionHealth`.
    ///
    /// Deliberately does NOT touch `activityStreams`: `ActivityStreamStore`
    /// bounds its own tag count internally (LRU eviction over
    /// `maxTrackedFocusTags`) and hands back a fresh empty model for any tag
    /// it has already dropped, so it cannot grow without bound the way the
    /// other three maps could. Its lack of *focus-removal* pruning is a
    /// separate, lower-severity hygiene gap, not the retention bug this hook
    /// exists to close — see `ActivityStreamStore` for details.
    ///
    /// `TranscriptDiagnostics.forgetTag` IS in scope here, even though it
    /// looks like the same shape of tag-keyed cleanup as `activityStreams`:
    /// it is emitter bookkeeping for a number a human reads in the
    /// diagnostics stream (`splitNodesRendered`), not app state another
    /// queued fix owns, and — unlike `activityStreams` — leaving it unpruned
    /// produces an actively wrong, permanently inflated count rather than a
    /// merely stale one. It only covers focus *removal*; the window-close and
    /// multi-window staleness this doesn't cover is tracked as its own filed
    /// bug (`.claude/bugs/open/2026-09-04-renderedtreeshapebytag-still-goes-
    /// stale-on-window-close.md`).
    private func evictPerFocusState(tag: String) {
        focusLayouts.removeValue(forKey: tag)
        sessionRegistry.removeValue(forKey: tag)?.detach()
        sessionHealth.removeValue(forKey: tag)
        TranscriptDiagnostics.forgetTag(tag)
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
        if let cached = prDetailCache.detail(forKey: key) {
            if item.headSha.isEmpty || cached.headSha == item.headSha {
                perriDetail        = cached
                perriDetailLoading = false
                return
            }
            // Stale: the SHA moved on. Free the entry rather than retaining a
            // diff for a commit that no longer exists.
            prDetailCache.remove(forKey: key)
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
        let key = PRDetailCache.key(repo: detail.repo, number: detail.prNumber ?? 0)
        prDetailCache.store(detail, forKey: key, protecting: pendingSelectionCacheKey)

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
                self.prDetailCache.store(detail, forKey: key, protecting: self.pendingSelectionCacheKey)
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

        // Never overwrite a pane the daemon is driving with structured content
        // (W2), and never write a pane that doesn't exist in this focus's
        // current tree — in `perri-curated` there is no pane literally named
        // `diff` (its detail panes are `detail.0`/`detail.1`), so writing
        // blind here invents a pane id the daemon never sent. This writes
        // `focusLayouts` directly, bypassing the `.paneContent` handler
        // entirely, so without the ownership half of this guard a `Diff` or
        // `Code` push would be clobbered within milliseconds of arriving and
        // the pane would flicker back to a text summary on every PR load.
        // `nil` and `.text` are the states this function has always owned.
        let existing = focusLayouts["perri"]?.paneContent[DiffPaneSummaryPolicy.paneId]
        guard DiffPaneSummaryPolicy.shouldWriteSummary(tree: focusLayouts["perri"]?.tree, existing: existing)
        else { return }
        var model = focusLayouts["perri"] ?? FocusLayoutModel.initial
        model.paneContent[DiffPaneSummaryPolicy.paneId] = .text(lines.joined(separator: "\n"))
        focusLayouts["perri"] = model
    }

    private func prDetailCacheKey(_ item: PRQueueItem) -> String {
        PRDetailCache.key(repo: item.repo, number: item.number)
    }

    /// The cache key that must be exempt from eviction right now: the PR the
    /// operator is actively viewing (or awaiting), if any. Passed as
    /// `protecting:` to every `prDetailCache.store` call.
    private var pendingSelectionCacheKey: String? {
        pendingSelection.map(prDetailCacheKey)
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
            // Read-modify-write, not `activityStreams[tag, default:].ingest(ev)`
            // or a remove-then-reinsert — deliberately. `ActivityStreamModel`'s
            // arrays are now bounded (≤2000 events store-wide), so the
            // non-unique-reference deep copy this shape can cause is bounded
            // constant work, not the unbounded-O(n²) cost `ChatSession.swift`'s
            // `turns` comment (:63-75) documents avoiding for an *unbounded*
            // array. Don't "improve" this without measuring: `@Published`
            // has no `_modify`, `default:` subscript access depends on
            // Combine's willSet timing rather than a language guarantee, and
            // remove-then-reinsert fires the publisher twice per event —
            // doubling `render()` on every `ActivityTickerView` in every
            // attached-display window, inside a fix for a memory bug.
            let gapDetected = activityStreams.ingest(ev, tag: tag)
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
            activityStreams.replace(tag: tag, with: model)

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
            // preserved (content pushes are decoupled from layout geometry)
            // for every pane id that's still IN the new tree.
            //
            // A pane id that left the tree gets its content/freshness/address
            // dropped here rather than carried forward. The daemon reuses
            // pane ids (`new_pane_id` allocates the lowest free `detail.<n>`,
            // and a PR change tears down and re-issues a curated region's
            // tabs wholesale) — without this prune, a recycled pane id would
            // render from its *previous* occupant's content the instant
            // `DynamicFocusView.renderLayout`'s closing `updateContent` call
            // ran, until the `PaneContent` frame that always follows a
            // structural `FocusLayout` broadcast caught up. Dropping it here
            // means a recycled pane starts from "waiting for content…" — a
            // brief, honest placeholder — instead of someone else's PR.
            //
            // Deliberately still read-modify-write, not
            // `removeValue`-then-reinsert: the latter would restore unique
            // ownership of the inner dictionaries (same non-uniqueness/copy
            // cost documented at `ChatSession.swift:63-75`) but fires
            // `@Published` TWICE per push, doubling `handleLayoutUpdate` on
            // every `DynamicFocusView` in every window — inside a fix for
            // redundant re-rendering. The entry-count leak this file's other
            // fix (`evictPerFocusState`) closes is what actually bounds this
            // dictionary; this shape is measured, not assumed, to be fine.
            var model = focusLayouts[tag] ?? FocusLayoutModel.initial
            model.tree        = tree
            model.focusedPane = focusedPane
            let livePaneIds = Set(tree.paneIds)
            let droppedContentCount = model.paneContent.keys.filter { !livePaneIds.contains($0) }.count
            model.paneContent   = Self.pruned(model.paneContent,   keeping: livePaneIds)
            model.paneFreshness = Self.pruned(model.paneFreshness, keeping: livePaneIds)
            model.paneAddress   = Self.pruned(model.paneAddress,   keeping: livePaneIds)
            focusLayouts[tag] = model
            panesLog.debug("""
                focusLayout tag=\(tag, privacy: .public) paneIds=\(Array(livePaneIds).sorted(), privacy: .public) \
                prunedContentEntries=\(droppedContentCount, privacy: .public)
                """)

        case .paneContent(let tag, let paneId, let content, let freshness, let address):
            // Content update — update the leaf without touching tree geometry so
            // operator drag-resizes survive.
            //
            // Read-modify-write, deliberately not restructured — see the
            // identical note on the `.focusLayout` arm above. Now that
            // `.jsonSnapshot`/`.unknown` compare structurally (D6), the no-op
            // guard below actually fires for them too, which is the real fix
            // for the redundant-@Published-write cost this shape has always
            // paid — not a change to the shape itself.
            var model = focusLayouts[tag] ?? FocusLayoutModel.initial
            let existingContent = model.paneContent[paneId]
            let kindLabel = Self.paneContentKindLabel(content)
            // A `.loading` update must never clobber content the operator is
            // already looking at — render it only on first paint (D10): no
            // prior content for this pane, or the prior content was itself
            // `.loading`.
            if content == .loading, let existingContent, existingContent != .loading {
                panesLog.debug("""
                    paneContent SWALLOWED (loading-clobber guard) tag=\(tag, privacy: .public) \
                    pane=\(paneId, privacy: .public)
                    """)
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
                panesLog.debug("""
                    paneContent SWALLOWED (no-op guard) tag=\(tag, privacy: .public) pane=\(paneId, privacy: .public) \
                    kind=\(kindLabel, privacy: .public)
                    """)
                return
            }
            panesLog.debug("""
                paneContent tag=\(tag, privacy: .public) pane=\(paneId, privacy: .public) kind=\(kindLabel, privacy: .public)
                """)
            model.paneContent[paneId] = content
            model.paneFreshness[paneId] = freshness
            model.paneAddress[paneId] = address
            focusLayouts[tag] = model

        case .decisionRequest(let tag, let requestId, let prompt, let detail, let choices, let contextPaneId):
            // Published once, to whichever single subscriber is listening
            // (`DecisionPresenter`) — nothing here decides presentation or
            // touches `DecisionStore`.
            decisionRequests.send(PendingDecision(tag: tag, requestId: requestId, prompt: prompt,
                                                  detail: detail, choices: choices, contextPaneId: contextPaneId))

        case .decisionResolved(let tag, let requestId, let resolution, let choiceId):
            decisionResolutions.send(ResolvedDecision(tag: tag, requestId: requestId,
                                                       resolution: resolution, choiceId: choiceId))

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

    /// Drop every entry of `dict` whose key isn't in `ids` — shared by the
    /// `.focusLayout` handler's three parallel prunes (`paneContent`,
    /// `paneFreshness`, `paneAddress`) down to the pane ids the incoming tree
    /// actually names. One named helper instead of three copies of the same
    /// filter closure keeps it visually obvious all three follow identical
    /// pruning rules (see `docs/mcp/panes.md`'s "Pane ids are recycled" section
    /// for why this prune exists at all).
    private static func pruned<Value>(_ dict: [String: Value], keeping ids: Set<String>) -> [String: Value] {
        dict.filter { ids.contains($0.key) }
    }

    /// A short, content-free label for `PaneContentWire` — counts/ids/kinds
    /// only, never the payload itself. Duplicated (not shared) with
    /// `DynamicFocusView.contentKindLabel`: same shape, different file, and
    /// three similar lines beat a premature cross-file abstraction for
    /// something this small.
    private static func paneContentKindLabel(_ content: PaneContentWire) -> String {
        switch content {
        case .text:           return "text"
        case .jsonSnapshot:   return "jsonSnapshot"
        case .prList:         return "prList"
        case .loading:        return "loading"
        case .error:          return "error"
        case .code:           return "code"
        case .diff:           return "diff"
        case .prConversation: return "prConversation"
        case .ticket:         return "ticket"
        case .unknown:        return "unknown"
        }
    }
}
