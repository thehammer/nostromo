import AppKit
import Foundation
import Combine
import NostromoKit
import os
import UserNotifications

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
    private static var loggedQANoMother = false
    static let shared = AppStore()

    // MARK: - Published state

    // Mother
    /// Everything that needs the operator, app-wide: Mother jobs, W6 decision tags and, later,
    /// approvals and the tracker. The Dock badge, the notifier and the Mother counts strip all
    /// read this one snapshot. Producers register through `needsYouCoordinator`.
    @Published private(set) var needsYou: NeedsYouSnapshot = .empty
    /// Built-in agents the daemon runs (from `welcome`); `.all` until a welcome says otherwise.
    @Published private(set) var enabledAgents: EnabledAgents = .all
    /// The one-time "Mother is staying quiet" note in the Mother panel.
    @Published private(set) var motherNotifyNoteVisible = false
    @Published private(set) var motherStatus:       MotherStatus = MotherStatus()
    @Published private(set) var motherJobs:         [MotherJob]  = []
    /// Who queued each Mother job, from the daemon's `mother_jobs` frame, keyed by job id. Kept
    /// through a disconnect; published only when it changes.
    @Published private(set) var motherAnnotations:  [String: MotherJobAnnotation] = [:]
    /// The daemon's notice switches and each focus's notice state. Nil until the first
    /// `mother_notice_state` frame; published only when it changes. The UI reflects this alone: a
    /// switch is never shown as changed before the daemon says so.
    @Published private(set) var motherNoticeState: MotherNoticeStateWire?
    /// The daemon's last refusal of a notice switch, as one line; cleared by the next state frame or a disconnect.
    @Published private(set) var motherNoticeRefusal: String?
    /// Live peek snapshots keyed by job id. Cleared on disconnect and on terminal transition.
    @Published private(set) var motherPeeks:        [String: MotherPeekPayload] = [:]
    /// True while the broker socket is connected (hello received + subscribe sent).
    @Published private(set) var brokerConnected:    Bool         = false
    /// Set on action failure; UI observes and clears after display.
    @Published private(set) var motherActionError:  String?      = nil
    /// The Mother daemon's state from `mother daemon status` (polled; see `refreshMotherDaemon`).
    @Published private(set) var motherDaemon:       MotherDaemonState = .unknown

    // Budget
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
    // Stale/loading are driven by `perriHealth` (the connection + whether a perri_state frame has
    // arrived since it came up); the wire frame has no stale/error flag of its own.
    @Published private(set) var perriQueueStale:     Bool           = false
    @Published private(set) var perriQueueError:     String?        = nil
    @Published private(set) var perriQueueLoading:   Bool           = true
    private var perriHealth = PerriQueueHealth() {
        didSet {
            if perriQueueStale != perriHealth.stale { perriQueueStale = perriHealth.stale }
            if perriQueueLoading != perriHealth.loading { perriQueueLoading = perriHealth.loading }
        }
    }

    // Perri PR detail pane
    @Published private(set) var perriDetail:         PRDetail?      = nil
    @Published private(set) var perriDetailLoading:  Bool           = false

    // Per-focus PR under review (W7/W8) — keyed by focus session tag, fed by
    // `perri_state` broadcasts now that they carry a `tag` (see `handle(_:)`).
    // This is deliberately separate from `perriDetail` above: `perriDetail`
    // is the single Perri-built-in-focus's own selection (driven by
    // `selectPR`/FileWatchers, unrelated to isolation), while this dictionary
    // is what the sidebar's per-focus label (SidenavGrouping) reads. An
    // entry's lifetime matches its focus's — evicted in `evictPerFocusState`,
    // the same invariant `focusLayouts`/`sessionHealth` already follow.
    @Published private(set) var perriDetailByTag: [String: PRDetail] = [:]

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

    // Focus tags with an outstanding request for the operator's attention
    // (pending decisions today; notifications etc. can reuse it). App-wide, so
    // every window's sidebar flags the same rows. The sidebar reads this and
    // knows nothing about what raised it — `DecisionPresenter` is the writer.
    @Published private(set) var attentionTags: Set<String> = []
    private var attentionRegistry = AttentionRegistry()
    private var motherNotifyNote = MotherNotifyNote()
    /// True from a broker disconnect until the next snapshot: the emptied job map is not the
    /// truth, so Mother's "needs you" items stay as they were (no resolve-then-repost).
    /// If the broker never comes back, the 30 s poll lets go of it (see `MotherResnapshotGuard`).
    private var resnapshotGuard = MotherResnapshotGuard()
    /// The broker has delivered a snapshot this launch: only then is the job map real, and
    /// Mother's "needs you" baseline can be taken.
    private var motherSnapshotSeen = false
    private var awaitingMotherResnapshot: Bool { resnapshotGuard.isHolding }
    /// Owns the aggregator, the Dock badge and the notifier. Approvals register here through
    /// `ApprovalBadges` (`setProducer("approvals", ...)`), with a content builder for their
    /// notifications in the Kit notifier. T5 reads per-focus items from `needsYou`.
    private(set) lazy var needsYouCoordinator: NeedsYouCoordinator = {
        let coordinator = NeedsYouCoordinator(
            center: NeedsYouCoordinator.liveCenter(),
            // The ONLY writer of `dockTile.badgeLabel` in the app (policy-tested).
            dockBadge: { NSApp?.dockTile.badgeLabel = $0 },
            jobTitle: { [weak self] id in self?.jobMap[id]?.title },
            approvalRequest: { ApprovalStore.shared.entry(id: $0)?.request })
        coordinator.onChange = { [weak self] in self?.needsYou = $0 }
        coordinator.notifier.onSurfaceAvailabilityChange = { [weak self] available in
            self?.broker.setNotifySurfaceAvailable(available)
            if available {
                self?.motherNotifyNote.surfaceBecameAvailable()
                self?.publishMotherNotifyNote()
            }
        }
        return coordinator
    }()

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

    /// Session tags whose MCP bridge has been gone for longer than `ToolsOfflinePolicy.grace`: the
    /// session runs but cannot call `mcp__nostromo__*` tools. Empty for a tag that never had a bridge.
    @Published private(set) var toolsOffline: Set<String> = []
    private var toolsOfflinePolicy = ToolsOfflinePolicy()

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
    /// Remote-shell confirm requests (2c): one event per `remote_shell_confirm_request` and per
    /// `remote_shell_resolved`. `RemoteShellPresenter` is the only subscriber; the state lives in
    /// `RemoteShellStore`.
    let remoteShellRequests = PassthroughSubject<RemoteShellConfirmRequest, Never>()
    let remoteShellResolutions = PassthroughSubject<RemoteShellResolved, Never>()
    /// Permission requests (AP2a): one event per `approval_request`, `approvals_snapshot`,
    /// `approval_resolved` and `approval_answer_refused` frame. Deliberately not `@Published`,
    /// like decisions: a request is an event, and `ApprovalStore` owns what it means.
    let approvalEvents = PassthroughSubject<ApprovalEvent, Never>()

    /// `claude_login_state` frames (CL2), for `ClaudeLoginStore`. Not `@Published`, like approvals.
    let claudeLoginEvents = PassthroughSubject<ClaudeLoginStateFrame, Never>()
    /// A daemon-announced focus that this client asked to have selected
    /// (`select_for_client`). Each window's `MainLayout` switches to it only if
    /// it is the key window.
    let focusSelectionRequests = PassthroughSubject<Focus, Never>()
    private let orgResolver = RepoOrgResolver()

    // MARK: - Internals

    /// Exposed so `TranscriptLoadHarness` can inject synthetic daemon traffic
    /// through the real production code path rather than a parallel one.
    let client = NostromodClient()
    private let broker  = MotherBrokerClient()
    /// Re-reads a job with `query.get` after its crew events (gates, review wave, decision, attention).
    private lazy var jobRefresher = MotherJobRefresher(
        fetch: { [weak self] id, done in
            guard let self else { done(.failure(.disconnected)); return }
            self.broker.queryGet(job: id, completion: done)
        },
        apply: { [weak self] refreshed in self?.applyRefreshedJob(refreshed) }
    )
    /// Looks up a job the app has never heard of (a `stateChange` for an unknown id) and inserts it.
    private lazy var discoveryRefresher = MotherJobRefresher(
        fetch: { [weak self] id, done in
            guard let self else { done(.failure(.disconnected)); return }
            self.broker.queryGet(job: id) { result in
                if case .failure = result {
                    log.info("broker discovery of job \(id.prefix(8), privacy: .public) failed or not found")
                }
                done(result)
            }
        },
        apply: { [weak self] found in self?.insertDiscoveredJob(found) }
    )
    /// Ids archived (or reconciled away) in the last 2 minutes; a late discovery or list must not revive them.
    private var recentlyArchived = MotherRecentlyArchived()
    /// Jobs absent from the previous successful `query.list`.
    private var missingOnce = Set<String>()
    private var stateMismatch: [String: String] = [:]
    private var resyncInFlight = false
    private lazy var resyncScheduler = MotherResyncScheduler(
        schedule: { after, repeating, fire in
            let timer = Timer(timeInterval: after, repeats: repeating != nil) { _ in fire() }
            RunLoop.main.add(timer, forMode: .common)
            return { timer.invalidate() }
        },
        tick: { [weak self] in self?.resyncJobs() }
    )
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
    /// Each held job's decision send state (a decision is answered at most once). Main thread only.
    private var decisionStores: [String: MotherDecisionStore] = [:]
    /// Fires when a decision's send state or the broker's capabilities change.
    private let motherDecisionChanges = PassthroughSubject<Void, Never>()
    /// Acknowledgements sent and not yet answered, by job and reason.
    private var acksInFlight = Set<String>()

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
    /// Where daemon `ServerMsg.notification` broadcasts are shown (W5 —
    /// current-pr-collision) — the same toast banner surface as
    /// `onMemoryToast`, set alongside it by `MainLayout`. No production
    /// trigger sends one yet; a later wedge (the same-PR advisory) does.
    var onNotification: ((String, ToastSeverity) -> Void)?

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
        // `scope` is the watchdog's: its own polling asks for `.offscreenOnly`, so a pane the operator
        // is looking at keeps its views; only critical OS pressure asks for `.everything`.
        watchdog.onShedScoped = { [weak self] scope, done in
            guard let self else { done(); return }
            let panes = self.transcriptPanes.allObjects
            guard !panes.isEmpty else { done(); return }
            let group = DispatchGroup()
            for pane in panes {
                group.enter()
                pane.shedMaterializedViews(scope: scope) { group.leave() }
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
        if let s = sessionRegistry[tag] {
            // Re-attach after a rename: carry the current label so the next spawn uses it.
            if let displayName, s.displayName != displayName { s.displayName = displayName }
            return s
        }
        let s = ChatSession(tag: tag, agentName: agentName, displayName: displayName,
                            workingDirectory: workingDirectory, client: client)
        sessionRegistry[tag] = s
        return s
    }

    /// A rename can't reach an already-running session (no protocol change), but
    /// the next spawn/restart of it must use the new label.
    func updateSessionLabel(tag: String, displayName: String) {
        sessionRegistry[tag]?.displayName = displayName
    }

    // MARK: - Active focus

    func setActiveFocusAgentTag(_ tag: String?) { activeFocusAgentTag = tag }
    func setActiveFocusSessionTag(_ tag: String?) { activeFocusSessionTag = tag }

    // MARK: - Decision modal (multi-window decision-sheet fix)

    /// Flag `tag` as needing the operator until `clearAttention(key:)` is called
    /// for every `key` raised on it. Idempotent per key.
    func raiseAttention(tag: String, key: String) {
        attentionRegistry.raise(tag: tag, key: key)
        publishAttention()
    }

    func clearAttention(key: String) {
        attentionRegistry.clear(key: key)
        publishAttention()
    }

    private func publishAttention() {
        let tags = attentionRegistry.tags
        if tags != attentionTags { attentionTags = tags }
        needsYouCoordinator.setAttentionTags(tags)
    }

    // MARK: - Needs you

    /// Hide the "Mother is staying quiet" note. It never comes back during this run.
    func dismissMotherNotifyNote() {
        motherNotifyNote.dismiss()
        publishMotherNotifyNote()
    }

    private func publishMotherNotifyNote() {
        if motherNotifyNote.isRaised != motherNotifyNoteVisible { motherNotifyNoteVisible = motherNotifyNote.isRaised }
    }

    /// Forward the operator's answer to the daemon. Claiming the answer into
    /// `DecisionStore` is `DecisionSheet`'s job, not this one (it happens
    /// before this is even called) — this method only puts the frame on the
    /// wire. There is no local state here to clear: liveness/presentation
    /// tracking lives entirely in `DecisionStore`/`DecisionPresenter` now.
    func answerDecision(requestId: String, choiceId: String?) {
        client.decisionAnswer(requestId: requestId, choiceId: choiceId)
    }

    /// Send the human's answer to a held permission request (`ApprovalStore.answer`).
    func answerApproval(requestId: String, decision: ApprovalDecisionWire, windowID: String) {
        client.approvalAnswer(requestId: requestId, decision: decision, windowId: windowID)
    }

    /// Report an input that was refused at an approval control (`ApprovalStore.reportRefusal`).
    func reportApprovalRefusal(requestId: String?, control: String, channel: ApprovalRefusalChannel) {
        client.approvalRefusalReport(requestId: requestId, control: control, channel: channel)
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
        ModelStore.shared.sender = client

        // IPC messages (session, activity)
        client.messages
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.handle($0) }
            .store(in: &cancellables)

        // File-backed data (posture, perri queue)
        FileWatchers.shared.posture
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.posture = $0 }
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
                self?.resyncScheduler.setConnected(connected)
                if !connected {
                    if !NostromoHome.shouldAttemptMotherDaemonStart(brokerConnected: connected, isQA: NostromoHome.isQAInstance) {
                        // The QA clone points the broker at a dead path on purpose; starting Mother
                        // here would leave a real supervisor running in the QA dir.
                        if !AppStore.loggedQANoMother {
                            AppStore.loggedQANoMother = true
                            log.info("QA instance: broker offline, never starting Mother")
                        }
                        return
                    }
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

        for (name, active) in [(NSApplication.didBecomeActiveNotification, true),
                               (NSApplication.didResignActiveNotification, false)] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] _ in self?.resyncScheduler.setActive(active) }
                .store(in: &cancellables)
        }
        resyncScheduler.setActive(NSApp?.isActive ?? true)

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
        // Notifications: read the system's setting (never prompts; the prompt waits for the
        // first item that can be posted), and re-read it whenever the app comes forward, since
        // the operator may have changed it in System Settings.
        needsYouCoordinator.notifier.refreshAuthorization()
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.needsYouCoordinator.notifier.refreshAuthorization() }
            .store(in: &cancellables)
        broker.start()

        // Fallback poll: `mother list --format json` every 30 s reconciles any
        // external changes (e.g. tmux archive) that the broker didn't broadcast.
        // The broker is authoritative for live events; this only catches stragglers.
        Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.pollMotherList(); self?.refreshMotherDaemon() }
            .store(in: &cancellables)
        refreshMotherDaemon()

        // Phase 1: keep the daemon's focus registry mirrored from the Mac.
        client.connected
            .receive(on: DispatchQueue.main)
            .filter { $0 }                       // push on each successful (re)connect
            .sink { [weak self] _ in self?.pushFocusRegistry() }
            .store(in: &cancellables)

        // Terminal frames go out through this app's one daemon connection.
        TerminalSessionStore.shared.transport = { [client] in client.sendTerminal($0) }
        TerminalStagingStore.shared.transport = { [client] in client.sendTerminal($0) }
        RemoteShellStore.shared.transport = { [client] in client.sendRemoteShell($0) }

        // The work store holds what one connection pushed. When it drops, requests
        // still waiting for an answer can never get one; when a connection comes
        // up, whatever the previous one left behind is stale (the daemon re-sends
        // its retained work frames, and an older daemon sends none).
        client.connected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                // The Perri queue held from a dropped connection is stale until a fresh
                // perri_state frame arrives; a new connection has not delivered one yet.
                self?.perriHealth.connectionChanged(connected)
                if !connected { self?.daemonDisconnected() }
                // Tells every chip whether the daemon is reachable, and on a new connection
                // asks for the model catalogue and the per-agent defaults.
                ModelStore.shared.connectionChanged(connected)
                BackgroundTaskStore.shared.tasksSupported = connected && self?.client.daemonAdvertisesTasks == true
                // Terminal views attach again after a reconnect, and are told when the daemon is gone.
                TerminalSessionStore.shared.connectionChanged(connected)
                // A daemon restart forgets every staged list: so does the drawer.
                TerminalStagingStore.shared.connectionChanged(connected)
                if connected {
                    // What the New Remote Shell picker offers (read from the user's ECS data per request).
                    RemoteShellStore.shared.requestTargets()
                    WorkStore.shared.reset()
                } else {
                    WorkStore.shared.failPendingRequests(reason: "The daemon connection was lost")
                    // The CLI dies with the daemon: nothing shows running until a new snapshot says so.
                    BackgroundTaskStore.shared.daemonDisconnected()
                    // Tracker panes keep their last board; the reconnect's replay replaces it in place.
                    TrackerStore.shared.daemonDisconnected()
                    // A sign-in card from a dropped connection is stale until the daemon says again.
                    ClaudeLoginStore.shared.reset()
                    // Whether each bridge is up is known only from the live connection.
                    self?.toolsOfflinePolicy.reset()
                    self?.refreshToolsOffline()
                }
            }
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

    func pushFocusRegistry() {
        client.focusRegistryPush(FocusStore.shared.wireProjection())
    }

    /// Per-focus state dies with the focus. Called once per `focusRemovals`
    /// event (`start()`), never on any other schedule. Evicts `focusLayouts`,
    /// `sessionRegistry` (detached, not merely dropped — that is what stops
    /// the daemon-side session from being respawned on the next reconnect),
    /// `sessionHealth`, and `perriDetailByTag` (W8 — the per-focus PR pin the
    /// sidebar label reads; without this it leaks one entry per closed focus
    /// forever, the same class of bug this hook already exists to close).
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
        // The closed focus's notice entry (and its held bar) goes now, not at the daemon's next frame.
        if let state = motherNoticeState, state.focus(tag: tag) != nil { motherNoticeState = state.removing(tag: tag) }
        focusLayouts.removeValue(forKey: tag)
        sessionRegistry.removeValue(forKey: tag)?.detach()
        sessionHealth.removeValue(forKey: tag)
        toolsOfflinePolicy.sessionEnded(tag: tag)
        refreshToolsOffline()
        perriDetailByTag.removeValue(forKey: tag)
        ModelStore.shared.forget(tag: tag)
        TranscriptFoldStore.shared.removeFocus(tag: tag)
        TranscriptDiagnostics.forgetTag(tag)
        TrackerStore.shared.forget(tag: tag)
        BackgroundTaskStore.shared.forget(tag: tag)
    }

    // MARK: - Broker event fold

    private func applyBrokerEvent(_ event: BrokerEvent) {
        switch event {
        case .hello:
            // Connection state is already set via broker.connected; the capabilities are new.
            motherDecisionChanges.send()

        case .awaitingNotified(let transport, _):
            // Mother stood down because a client is connected: warn once if we cannot show it.
            if transport == "suppressed_client" {
                motherNotifyNote.suppressionObserved(surfaceAvailable: needsYouCoordinator.notifier.isSurfaceAvailable)
                publishMotherNotifyNote()
            }

        case .snapshot(let jobs):
            motherSnapshotSeen = true
            resnapshotGuard.snapshotReceived()
            jobMap = Dictionary(jobs.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            missingOnce.removeAll()
            stateMismatch.removeAll()
            publishJobsAndStatus()
            resyncScheduler.snapshotReceived()

        case .newJob(let job):
            // A job that was queued after the initial snapshot arrived.
            // The broker embeds the full payload in the "queued" event so
            // we can insert it directly rather than reconnecting.
            jobMap[job.id] = job
            publishJobsAndStatus()

        case .stateChange(let jobId, let eventKind, let question, let pausedReason, let toState):
            if eventKind == "archived" { recentlyArchived.insert(jobId) }
            guard jobMap[jobId] != nil else {
                // Never heard of it (its `queued` event was missed): read it from the broker.
                if eventKind != "archived" { discoveryRefresher.request(job: jobId) }
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

        case .progress(let jobId, let progress):
            guard jobMap[jobId]?.applyProgress(progress) == true else { return }
            publishJobsAndStatus()

        case .crewChanged(let jobId):
            guard jobMap[jobId] != nil else { return }
            jobRefresher.request(job: jobId)

        case .ping:
            break

        case .reconnected:
            // Clear stale state; next snapshot will repopulate
            jobRefresher.cancelAll()
            discoveryRefresher.cancelAll()
            missingOnce.removeAll()
            stateMismatch.removeAll()
            jobMap.removeAll()
            motherPeeks.removeAll()
            resnapshotGuard.disconnected(now: Date())
            publishJobsAndStatus()
        }
    }

    /// A `query.get` result: the broker's record replaces ours, except that the newer progress
    /// overlay wins. A job that left the queue meanwhile stays gone.
    private func applyRefreshedJob(_ refreshed: MotherJob) {
        guard let current = jobMap[refreshed.id] else { return }
        let merged = current.replacing(with: refreshed)
        guard merged != current else { return }
        jobMap[refreshed.id] = merged
        publishJobsAndStatus()
    }

    /// A discovery `query.get` result: inserted only if still unknown and not just archived.
    private func insertDiscoveredJob(_ found: MotherJob) {
        guard MotherJobReconciler.shouldInsertDiscovered(
            id: found.id, jobMap: jobMap, recentlyArchived: recentlyArchived.ids()) else { return }
        jobMap[found.id] = found
        log.info("broker discovered job \(found.id.prefix(8), privacy: .public) via query.get")
        publishJobsAndStatus()
    }

    /// Periodic `query.list` resync. A failed list changes nothing.
    private func resyncJobs() {
        guard brokerConnected, !resyncInFlight else { return }
        resyncInFlight = true
        broker.queryList { [weak self] result in
            guard let self else { return }
            self.resyncInFlight = false
            guard case .success(let listed) = result, self.brokerConnected else { return }
            self.applyListedJobs(listed)
        }
    }

    private func applyListedJobs(_ listing: MotherJobListing) {
        let outcome = MotherJobReconciler.reconcile(
            current: jobMap, listed: listing.jobs,
            missingOnce: missingOnce, recentlyArchived: recentlyArchived.ids(),
            partial: listing.partial, unreadableIds: listing.unreadableIds,
            stateMismatch: stateMismatch)
        missingOnce = outcome.missingOnce
        stateMismatch = outcome.stateMismatch
        outcome.removed.forEach { recentlyArchived.insert($0) }
        guard outcome.jobs != jobMap else { return }
        if !outcome.added.isEmpty || !outcome.removed.isEmpty {
            log.info("broker resync: +\(outcome.added.count, privacy: .public) -\(outcome.removed.count, privacy: .public)")
        }
        outcome.removed.forEach { motherPeeks.removeValue(forKey: $0) }
        jobMap = outcome.jobs
        publishJobsAndStatus()
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
            cycles: job.cycles,
            crew:   job.crew,
            originLabel: job.originLabel
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
        // Only a real change wakes the views: an equal re-publish (a crew event whose
        // refreshed job is identical, a state event that folds to the same job) is dropped.
        let status = MotherStatus.from(jobs: jobs)
        // Note: a Mother hold and a W6 decision (attention tag) for the same job count twice in
        // the Dock total. Intended: they are two separate asks (the job's hold, the focus's decision).
        // A decision that resolved (or was replaced) takes its send state with it.
        var storesChanged = false
        for (id, var store) in decisionStores {
            // A send in flight keeps its state through a moment with no decision (a reconnect, an
            // unreadable refresh): its result is still coming, and the buttons must not re-enable.
            if case .sending = store.state, jobMap[id]?.crew.decision == nil { continue }
            let before = store
            store.sync(decision: jobMap[id]?.crew.decision)
            guard store != before else { continue }
            storesChanged = true
            if store.decisionId == nil { decisionStores.removeValue(forKey: id) } else { decisionStores[id] = store }
        }
        if jobs != motherJobs { motherJobs = jobs }
        if status != motherStatus { motherStatus = status }
        if !awaitingMotherResnapshot { needsYouCoordinator.setMotherJobs(jobs, fromSnapshot: motherSnapshotSeen) }
        if storesChanged { motherDecisionChanges.send() }
    }

    // MARK: - Mother action methods (called from MotherView)

    func answerJob(_ id: String, text: String) {
        broker.answer(job: id, text: text) { [weak self] result in
            self?.handleActionResult(result, verb: "answer")
        }
    }

    // MARK: Hold decisions and acknowledgements
    //
    // Every caller has already checked for a human gesture (`MotherJobDetail`, each control
    // before it calls these). That is why only these paths send `source: "nostromo_app"`.

    /// Answer a hold by option. Sends at most once per decision id unless the send failed;
    /// nothing is retried here and nothing picks an option for the operator.
    func answerMotherDecision(jobId: String, decisionId: String, option: MotherDecisionOption, text: String) {
        var store = decisionStores[jobId] ?? MotherDecisionStore()
        store.sync(decision: jobMap[jobId]?.crew.decision)
        guard store.decisionId == decisionId, let command = store.request(option: option, text: text) else {
            return
        }
        decisionStores[jobId] = store
        motherDecisionChanges.send()
        broker.answer(job: jobId, option: command.option, text: command.text) { [weak self] result in
            self?.finishDecisionAnswer(jobId: jobId, decisionId: command.decisionId, result: result)
        }
    }

    /// The first click of `override_open`.
    func beginMotherDecisionConfirm(jobId: String, decisionId: String, option: MotherDecisionOptionID) {
        var store = decisionStores[jobId] ?? MotherDecisionStore()
        store.sync(decision: jobMap[jobId]?.crew.decision)
        guard store.decisionId == decisionId, store.beginConfirm(option: option) else { return }
        decisionStores[jobId] = store
        motherDecisionChanges.send()
    }

    func cancelMotherDecisionConfirm(jobId: String, decisionId: String) {
        guard var store = decisionStores[jobId], store.decisionId == decisionId else { return }
        store.cancelConfirm()
        decisionStores[jobId] = store
        motherDecisionChanges.send()
    }

    func motherDecisionState(jobId: String, decisionId: String) -> MotherDecisionSendState {
        guard let store = decisionStores[jobId], store.decisionId == decisionId else { return .idle }
        return store.state
    }

    /// Acknowledge a raised attention flag. The refresh shows it as acknowledged.
    func ackMotherAttention(jobId: String, reason: MotherAttentionReason) {
        let key = jobId + "\u{0}" + reason.raw
        guard acksInFlight.insert(key).inserted else { return }   // a double click is one ack
        broker.ack(job: jobId, reason: reason.raw) { [weak self] result in
            guard let self else { return }
            self.acksInFlight.remove(key)
            switch result {
            case .success:
                log.info("broker ack succeeded")
                self.jobRefresher.request(job: jobId)
            case .failure(let err):
                log.warning("broker ack failed: \(err.kind.logName, privacy: .public)")
                self.motherActionError = err.kind == .invalidState
                    ? "That flag was already cleared or changed. Refreshed."
                    : err.decisionMessage
                if err.kind == .invalidState { self.jobRefresher.request(job: jobId) }
            }
        }
    }

    private func finishDecisionAnswer(jobId: String, decisionId: String, result: Result<Void, BrokerError>) {
        if var store = decisionStores[jobId] {
            switch result {
            case .success:
                store.succeeded(decisionId: decisionId)
            case .failure(let err):
                store.failed(decisionId: decisionId, kind: err.kind)
            }
            decisionStores[jobId] = store
        }
        switch result {
        case .success:
            log.info("broker decision answer succeeded")
            jobRefresher.request(job: jobId)
        case .failure(let err):
            // Mother's own message text is never shown or logged: only its class.
            log.warning("broker decision answer failed: \(err.kind.logName, privacy: .public)")
            motherActionError = err.decisionMessage
            // After a timeout Mother may still have applied the answer: read the job before anyone resends.
            if err.kind == .invalidState || err.kind == .timeout { jobRefresher.request(job: jobId) }
        }
        motherDecisionChanges.send()
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
        // A non-default broker (MOTHER_BROKER_SOCK — the fake broker used for QA)
        // is not the Mother the `mother` CLI talks to; reconciling against the real
        // CLI's list would delete every job the other broker reported.
        guard ProcessInfo.processInfo.environment["MOTHER_BROKER_SOCK"] == nil else { return }
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
                // Broker silent for too long: stop holding, so stale items do not stay counted.
                if self.resnapshotGuard.pollSucceeded(now: Date()) { self.publishJobsAndStatus() }
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

    /// Query `mother daemon status`. Skipped for a non-default broker (QA), whose
    /// daemon is not the one the CLI talks to.
    func refreshMotherDaemon() {
        if ProcessInfo.processInfo.environment["MOTHER_BROKER_SOCK"] != nil {
            motherDaemon = .unavailable(reason: "custom broker")
            return
        }
        guard let bin = AppStore.findBinary("mother") else {
            motherDaemon = .unavailable(reason: "mother not found")
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = ProcessRunner.runCapturingStdout(bin, arguments: ["daemon", "status"])
            let state: MotherDaemonState = result.map {
                MotherDaemonState.parse(stdout: String(data: $0.data, encoding: .utf8) ?? "", status: $0.status)
            } ?? .stopped
            DispatchQueue.main.async { self?.motherDaemon = state }
        }
    }

    /// `mother daemon start`, then re-check shortly after.
    func startMotherDaemon() {
        guard ProcessInfo.processInfo.environment["MOTHER_BROKER_SOCK"] == nil,
              let bin = AppStore.findBinary("mother") else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let r = ProcessRunner.runCapturingStdout(bin, arguments: ["daemon", "start"])
            if let r, r.status != 0 {
                DispatchQueue.main.async { self?.motherActionError = "mother daemon start failed (exit \(r.status))" }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.refreshMotherDaemon() }
        }
    }

    /// Re-run a failed job on the next model tier (`mother escalate ID --yes`).
    /// The caller confirms first: escalation costs more.
    func escalateJob(_ id: String) {
        guard ProcessInfo.processInfo.environment["MOTHER_BROKER_SOCK"] == nil else {
            motherActionError = "escalate uses the mother CLI, which is not connected to this broker"
            return
        }
        guard let bin = AppStore.findBinary("mother") else {
            motherActionError = "mother binary not found"
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let r = ProcessRunner.runCapturingStdout(bin, arguments: ["escalate", id, "--yes"])
            if r == nil || r!.status != 0 {
                let out = r.flatMap { String(data: $0.data, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                DispatchQueue.main.async { self?.motherActionError = "escalate failed" + (out.isEmpty ? "" : ": \(out)") }
            }
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

    static func findBinary(_ name: String) -> URL? {
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

    /// Test seam: feeds one daemon message through the same `handle` the live
    /// IPC stream uses, without `start()` (which connects to the daemon and
    /// starts the file watchers under the real home directory).
    func applyForTesting(_ msg: ServerMsg) { handle(msg) }

    /// Test seam: the nostromod connection dropped.
    func daemonDisconnectedForTesting() { daemonDisconnected() }

    /// A dropped daemon connection cannot take a notice switch, so the bell and the held bars must not
    /// look live: the state goes, and the reconnect replay brings it back.
    private func daemonDisconnected() {
        if motherNoticeState != nil { motherNoticeState = nil }
        if motherNoticeRefusal != nil { motherNoticeRefusal = nil }
    }

    /// Test seam: the same for a Mother broker event (the job list the Mother pane shows).
    func applyBrokerEventForTesting(_ event: BrokerEvent) { applyBrokerEvent(event) }

    private func handle(_ msg: ServerMsg) {
        switch msg {
        case .welcome(let version, let pid, let enabled):
            log.info("nostromd v\(version, privacy: .public) pid \(pid, privacy: .public)")
            FocusStore.shared.applyEnabledAgents(enabled)
            if enabledAgents != enabled { enabledAgents = enabled }

        case .motherJobs(let jobs):
            // Ignored — jobs now come from the broker
            log.debug("mother_jobs IPC message ignored (broker is source of truth)")
            _ = jobs

        case .motherAnnotations(let annotations):
            if annotations != motherAnnotations { motherAnnotations = annotations }

        case .motherNoticeState(let state):
            if state != motherNoticeState { motherNoticeState = state }
            if motherNoticeRefusal != nil { motherNoticeRefusal = nil }

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
            if let line = MotherNoticeText.refusalLine(forDaemonError: msg) { motherNoticeRefusal = line }
            // The daemon refused a resend/discard: the card's buttons come back with a notice.
            if isClaudeLoginRefusal(msg) { ClaudeLoginStore.shared.actionRefused() }

        case .sessionState(let tag, let state):
            // Derive health for the sparse sidebar badge map (all focuses, not just
            // the one with an active ChatSession view).
            switch state {
            case .idle, .midTurn, .awaitingPermission:
                applySessionHealth(.healthy, for: tag)
            case .crashed:
                applySessionHealth(.recovering, for: tag)
                sessionStoppedRunning(tag: tag)
            }

        case .sessionBridge(let tag, let connected):
            toolsOfflinePolicy.bridgeChanged(tag: tag, connected: connected, now: Date())
            refreshToolsOffline()

        case .sessionDown(let tag, let reason):
            if reason == .user {
                applySessionHealth(.healthy, for: tag)
            } else {
                applySessionHealth(.permanentlyDown(reason), for: tag)
            }
            sessionStoppedRunning(tag: tag)

        case .sessionSummaryUpdate(let tag, let summary):
            FocusStore.shared.updateSummary(tag: tag, summary: summary)

        case .perriState(let tag, let queue, let current):
            // Daemon push is an additive, lower-latency source feeding the same
            // publishers the file-watchers already drive.  The file-watcher path
            // is preserved (not removed) in this wedge.
            //
            // The daemon sends one of these per focus on every queue poll (60 s), whether or not
            // anything changed, and an `@Published` write publishes even when the value is equal.
            // Each publish rebuilt the sidebar and the Perri queue list, whose new `NSTextField`s
            // leave AppKit KVO records behind for good (docs/diagnostics.md, "View-tree leak"). So
            // only a real change is written.
            if perriQueue != queue { perriQueue = queue }
            if perriQueueError != nil { perriQueueError = nil }
            perriHealth.frameArrived()
            // `current` is already decoded as PRDetail? from the wire shape.
            if let current, perriDetail != current { perriDetail = current }

            // Per-focus PR under review (W8) — a frame for one focus must
            // never clobber another's entry, and clearing a focus's PR must
            // be reflected rather than leaving its last-known PR stuck.
            //
            // A frame can arrive after its focus was closed and evicted
            // (`evictPerFocusState`); writing it would re-create an entry that
            // nothing removes again. Only a live focus may hold one, so an
            // entry's lifetime really is its focus's.
            if let current, FocusStore.shared.focuses.contains(where: { $0.sessionTag == tag }) {
                if perriDetailByTag[tag] != current { perriDetailByTag[tag] = current }
            } else if perriDetailByTag[tag] != nil {
                perriDetailByTag.removeValue(forKey: tag)
            }

        case .fredState(let mailbox, let calendar):
            fredMailbox  = mailbox
            fredCalendar = calendar

        case .teriState(let snap):
            teriTodos = snap

        case .sessionExited(let tag, _):
            sessionStoppedRunning(tag: tag)

        case .sessionSpawned(let tag, _):
            toolsOfflinePolicy.sessionStarted(tag: tag)

        case .sessionTurns, .sessionTurnDelta, .sessionPermissionRequest:
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

        case .notification(_, let level, let message):
            // No per-focus routing yet (same global banner surface
            // onMemoryToast already uses) — `tag` is carried on the wire for
            // a later, more targeted presentation but unused here today.
            let severity: ToastSeverity = level == "alert" ? .alert : (level == "warning" ? .warning : .info)
            onNotification?(message, severity)

        case .focusCreated(let meta):
            // An agent-spawned focus was created — add it to FocusStore so the
            // tab appears, and seed an empty layout so DynamicFocusView has state.
            let focus = meta.toFocus()
            FocusStore.shared.add(focus)
            if focusLayouts[meta.tag] == nil {
                focusLayouts[meta.tag] = FocusLayoutModel.initial
            }
            // The daemon sends no org for a created focus; infer it from the
            // repo remote exactly as the New Focus sheet does, so it groups
            // under the right org rather than the "Carefeed" default.
            if meta.org == nil, let path = focus.projectPath {
                orgResolver.resolve(path) { org in
                    if let org { FocusStore.shared.updateOrg(id: focus.id, org: org) }
                }
            }
            // The creator asked for this focus to be selected in its own windows.
            if meta.selectForClient == client.clientId {
                focusSelectionRequests.send(focus)
            }

        // ── Teri/Fred work views → WorkStore ─────────────────────────────────
        case .workSourceStatus(let status):
            WorkStore.shared.apply(status: status)

        case .workSnapshot(let source, let group, let items):
            WorkStore.shared.apply(snapshot: source, group: group, items: items)

        case .teriPicks(let picks):
            WorkStore.shared.apply(picks: picks)

        case .workDetail(let requestId, let result):
            WorkStore.shared.resolve(requestId: requestId, with: .detail(result))

        case .workSendPreview(let requestId, let result):
            WorkStore.shared.resolve(requestId: requestId, with: .sendPreview(result))

        case .workSendResult(let requestId, let result):
            WorkStore.shared.resolve(requestId: requestId, with: .sendResult(result))

        case .withheld:
            break   // Only sent to network peers; the Mac's local connection never gets one.

        // Model switching: the store every window's chip and popup binds to.
        case .modelCatalog, .sessionModelState, .modelDefaults, .modelRequestResult:
            ModelStore.shared.ingest(msg)

        // Background tasks: the store every window's chip and popover binds to.
        case .sessionTasks, .sessionTaskDetail:
            BackgroundTaskStore.shared.ingest(msg)

        case .sessionTaskStopResult, .sessionTaskOutputResult:
            break   // BA4/BA5 route: the output viewer and the Stop control wait on these

        // The tracker pane's board and the focus's counts: every window's pane reads them from the store.
        case .trackerBoard, .trackerSummary:
            TrackerStore.shared.ingest(msg)

        // Permission approvals (AP2a): `ApprovalStore` keeps them, the card shows them. The guard's
        // block (AP2b) reaches the same store: it makes the row's status and the bar, never a card.
        // The count-only `approval_pending` is a later slice (AP3).
        case .approvalRequest(_, let request):
            approvalEvents.send(.request(request))
        case .approvalsSnapshot(let requests):
            approvalEvents.send(.snapshot(requests))
        case .approvalResolved(let frame):
            approvalEvents.send(.resolved(frame))
        case .approvalAnswerRefused(let frame):
            approvalEvents.send(.answerRefused(frame))
        case .approvalGuardBlocked(let frame):
            approvalEvents.send(.guardBlocked(frame))
        case .approvalPending:
            break

        // A document pane's action was answered: toast the message, open the URL if it is allowed.
        case .paneActionResult(let result):
            handlePaneActionResult(result)

        // A session waiting for a Claude sign-in (CL2): `ClaudeLoginStore` keeps it, the card shows it.
        case .claudeLoginState(let frame):
            claudeLoginEvents.send(frame)

        // Terminal panes (1d): `TerminalSessionStore` keeps them, every window's pane view shows them.
        case .terminalList, .terminalState, .terminalClosed, .terminalReplay, .terminalOutput, .terminalRefused:
            TerminalSessionStore.shared.ingest(msg)
            // A closed terminal takes its staged list with it.
            if case .terminalClosed(let closed) = msg { TerminalStagingStore.shared.terminalClosed(closed.terminalId) }

        // Staged commands (S1): `TerminalStagingStore` keeps them, every window's drawer shows them.
        case .terminalStagingList(let list):
            TerminalStagingStore.shared.ingest(list)
        case .terminalStagingUnreadable(let terminalId):
            TerminalStagingStore.shared.listUnreadable(terminalId)

        // Remote shells (2c): the store keeps the vocabulary; `RemoteShellPresenter` shows the sheets.
        case .remoteShellTargets(let targets):
            RemoteShellStore.shared.setTargets(targets)
        case .remoteShellConfirmRequest(let request):
            remoteShellRequests.send(request)
        case .remoteShellResolved(let resolved):
            remoteShellResolutions.send(resolved)

        case .pong, .unknown:
            break
        }
    }

    /// Where a `pane_action_result`'s `open_url` goes once it passes `DocumentLinkPolicy`. A test seam.
    var openExternalURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// Show a `pane_action_result`'s message as a toast, and open its `open_url` only if it is an
    /// `https:` URL or a `file:` URL inside `~/.nostromo/huey/`. Anything else is dropped silently.
    func handlePaneActionResult(_ result: PaneActionResultWire) {
        if let message = result.message, !message.isEmpty {
            onNotification?(message, result.ok ? .info : .warning)
        }
        guard result.ok, let raw = result.openURL,
              let url = DocumentLinkPolicy.allowedOpenURL(raw)
        else { return }
        openExternalURL(url)
    }

    /// Update `sessionHealth` for `tag`. `.healthy` entries are removed to keep
    /// the map sparse (healthy is the default / zero value).
    /// The session's process is gone: it has no bridge to be missing.
    private func sessionStoppedRunning(tag: String) {
        toolsOfflinePolicy.sessionEnded(tag: tag)
        refreshToolsOffline()
    }

    /// Publish which sessions are offline long enough to show, and arrange to look again when
    /// the next one crosses the grace period.
    private func refreshToolsOffline() {
        let now = Date()
        let offline = toolsOfflinePolicy.offlineTags(now: now)
        if offline != toolsOffline { toolsOffline = offline }
        if let deadline = toolsOfflinePolicy.nextDeadline(now: now) {
            DispatchQueue.main.asyncAfter(deadline: .now() + deadline.timeIntervalSince(now) + 0.1) { [weak self] in
                self?.refreshToolsOffline()
            }
        }
    }

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
        case .terminal:       return "terminal"
        case .document:       return "document"
        case .unknown:        return "unknown"
        }
    }
}

extension AppStore: AttentionSink {}

// MARK: - MotherJobDetailHost

/// What the Mother job detail pane asks of the app.
extension AppStore: MotherJobDetailHost {
    var brokerConnectedPublisher: AnyPublisher<Bool, Never> { $brokerConnected.eraseToAnyPublisher() }
    var motherActionErrorPublisher: AnyPublisher<String?, Never> { $motherActionError.eraseToAnyPublisher() }
    var motherPeeksPublisher: AnyPublisher<[String: MotherPeekPayload], Never> { $motherPeeks.eraseToAnyPublisher() }
    func peek(for jobId: String) -> MotherPeekPayload? { motherPeeks[jobId] }

    var supportsAnswerOption: Bool { broker.supportsAnswerOption }
    var supportsAck: Bool { broker.supportsAck }
    var motherDecisionChangesPublisher: AnyPublisher<Void, Never> { motherDecisionChanges.eraseToAnyPublisher() }

    /// A non-default broker (`MOTHER_BROKER_SOCK`, the QA fake) is not the Mother the CLI talks to.
    var usesDefaultBroker: Bool { ProcessInfo.processInfo.environment["MOTHER_BROKER_SOCK"] == nil }
    func motherBinary() -> URL? { AppStore.findBinary("mother") }
}

// MARK: - Approvals wiring

extension ApprovalStore {
    /// The app's one store of permission requests, fed by `AppStore.approvalEvents` and
    /// answering through the daemon connection. Every pane's card shows from it.
    static let shared: ApprovalStore = {
        let store = ApprovalStore(
            send: { AppStore.shared.answerApproval(requestId: $0, decision: $1, windowID: $2) },
            report: { AppStore.shared.reportApprovalRefusal(requestId: $0, control: $1, channel: $2) },
            canSend: { AppStore.shared.client.hasConnection })
        store.attach(to: AppStore.shared.approvalEvents)
        return store
    }()
}

// MARK: - Claude sign-in wiring

extension ClaudeLoginStore {
    /// The app's one store of sessions waiting for a Claude sign-in, fed by `AppStore.claudeLoginEvents`.
    static let shared: ClaudeLoginStore = {
        let store = ClaudeLoginStore(
            send: { AppStore.shared.client.sendClaudeLoginAction(action: $0, tag: $1, holdID: $2) },
            featureAdvertised: { AppStore.shared.client.daemonAdvertisesClaudeLogin },
            canSend: { AppStore.shared.client.hasConnection })
        store.attach(to: AppStore.shared.claudeLoginEvents)
        return store
    }()
}

// MARK: - Needs you (Mac wiring)

/// One app-wide "needs you" source: the aggregator, the Dock badge and the notifier.
/// Main thread only.
///
/// Producers feed it (`setMotherJobs`, `setAttentionTags`, and `setProducer` for approvals,
/// through `ApprovalBadges`); consumers read `snapshot` (or `AppStore.needsYou`). Nothing else in the app
/// writes the Dock tile or posts a "needs you" notification.
final class NeedsYouCoordinator {
    private var aggregator = NeedsYouAggregator()
    private let dockBadge: (String?) -> Void
    /// What the Dock badge says now (nil at zero).
    private(set) var dockLabel: String?

    private(set) var snapshot = NeedsYouSnapshot.empty
    let notifier: NeedsYouNotifier
    var onChange: ((NeedsYouSnapshot) -> Void)?

    /// `dockBadge` gets `"\(total)"`, or nil at zero, each time the label changes.
    /// `jobTitle` maps a Mother job id to its title for the notification body.
    /// `approvalRequest` maps a request id to its request for the approvals notification text.
    init(center: NotificationCenterLike,
         dockBadge: @escaping (String?) -> Void,
         jobTitle: @escaping (String) -> String?,
         approvalRequest: @escaping (String) -> ApprovalRequestWire? = { _ in nil }) {
        self.dockBadge = dockBadge
        notifier = NeedsYouNotifier(
            center: center,
            builders: [MotherNeedsYouProducer.name: MotherNeedsYouContentBuilder(jobTitle: jobTitle),
                       ApprovalsNeedsYouProducer.name: ApprovalsNeedsYouContentBuilder(request: approvalRequest)],
            baselineExisting: true,
            // A request id is unique for good: one the daemon drops and relists is not announced twice.
            oncePerItemProducers: [ApprovalsNeedsYouProducer.name])
    }

    /// `fromSnapshot`: `jobs` came from the broker's snapshot (not the empty map before it
    /// arrives). The first such call is Mother's baseline, even when empty.
    func setMotherJobs(_ jobs: [MotherJob], fromSnapshot: Bool = true) {
        setProducer(MotherNeedsYouProducer.name, items: MotherNeedsYouProducer.items(from: jobs),
                    baseline: fromSnapshot)
    }

    func setAttentionTags(_ tags: Set<String>) {
        setProducer(DecisionNeedsYouProducer.name, items: DecisionNeedsYouProducer.items(attentionTags: tags))
    }

    /// Replace everything `producer` raised. `ApprovalBadges` registers `"approvals"` through this, with
    /// `baseline: true` from the daemon's first snapshot on (even an empty one).
    func setProducer(_ producer: String, items: [NeedsYouItem], baseline: Bool = false) {
        let updated = aggregator.set(producer: producer, items: items)
        let takesBaseline = baseline && !notifier.hasBaselined(producer)
        guard updated != snapshot || takesBaseline else { return }
        snapshot = updated
        let label = updated.total > 0 ? "\(updated.total)" : nil
        if label != dockLabel {
            dockLabel = label
            dockBadge(label)
        }
        notifier.apply(updated, baselining: takesBaseline ? producer : nil)
        onChange?(updated)
    }

    /// The system's notification center when running as the app; an inert one (notifications
    /// unavailable) under tests and in the QA instance, so neither touches the real center.
    static func liveCenter() -> NotificationCenterLike {
        guard Bundle.main.bundleURL.pathExtension == "app", !NostromoHome.isQAInstance else {
            return UnavailableNotificationCenter()
        }
        return UNUserNotificationCenter.current()
    }
}

/// Stands in for the system center where there is none to use: denied, and it posts nothing.
private final class UnavailableNotificationCenter: NotificationCenterLike {
    func authorizationStatus(completion: @escaping (NeedsYouAuthorization) -> Void) { completion(.denied) }
    func requestAuthorization(completion: @escaping (Bool) -> Void) { completion(false) }
    func add(request: UNNotificationRequest) {}
    func removeDelivered(ids: [String]) {}
    func removePending(ids: [String]) {}
}

/// The one-time note in the Mother panel for "Mother stood down because Nostromo is open,
/// but Nostromo cannot show notifications".
struct MotherNotifyNote {
    static let text = "Mother is staying quiet because Nostromo is open, but Nostromo can't show notifications. "
        + "Allow notifications for Nostromo, or set MOTHER_NOTIFY_SUPPRESS_WHEN_CLIENT=0 in Mother's config."

    private(set) var isRaised = false
    private var dismissed = false

    /// Mother reported `suppressed_client`. Raised only while Nostromo cannot show notifications,
    /// and never after the operator dismissed it.
    mutating func suppressionObserved(surfaceAvailable: Bool) {
        guard !surfaceAvailable, !dismissed else { return }
        isRaised = true
    }

    mutating func dismiss() {
        dismissed = true
        isRaised = false
    }

    /// Notifications were allowed: the note no longer applies (it is not marked dismissed).
    mutating func surfaceBecameAvailable() {
        isRaised = false
    }
}

/// Holds Mother's "needs you" items across a broker reconnect: the emptied job map is not the
/// truth, so items stay as they were until the next `.snapshot` (no resolve-then-repost double
/// alert). If the broker never returns, a successful 30 s `mother list` poll releases the hold
/// once it has lasted more than `maxHold` (2 poll intervals); the emptied map then applies and
/// the stale items resolve, so they are never counted forever.
struct MotherResnapshotGuard {
    static let maxHold: TimeInterval = 60

    private var since: Date?
    var isHolding: Bool { since != nil }

    mutating func disconnected(now: Date) { if since == nil { since = now } }
    mutating func snapshotReceived() { since = nil }

    /// A poll succeeded. True when it released the hold (the caller republishes).
    mutating func pollSucceeded(now: Date) -> Bool {
        guard let start = since, now.timeIntervalSince(start) > Self.maxHold else { return false }
        since = nil
        return true
    }
}

/// The one way to open a Mother job: a "needs you" notification and a transcript marker both go
/// through it.
enum MotherJobRouting {
    /// The existing "open this Mother job" navigation (see `TeriBindings`): select the Mother
    /// focus (the key window's layout switches to it), then open the job's tab. Never activates
    /// the app; a caller that was clicked does that.
    static func open(jobId: String) {
        MotherView.requestedJobId = jobId
        if let mother = FocusStore.shared.focuses.first(where: { $0.id == "mother" }) {
            AppStore.shared.focusSelectionRequests.send(mother)
        }
        NotificationCenter.default.post(name: MotherView.openJobNotification, object: nil)
    }
}

/// Where a click on a "needs you" notification goes.
enum NeedsYouRouting {
    /// Route a delivered notification's `userInfo`. Returns false when it is not one this
    /// routes (another producer, or malformed). Never activates the app: the caller does that,
    /// and only for a click.
    @discardableResult
    static func route(userInfo: [AnyHashable: Any]) -> Bool {
        guard userInfo["producer"] as? String == MotherNeedsYouProducer.name,
              let jobId = userInfo["jobId"] as? String, !jobId.isEmpty else { return false }
        MotherJobRouting.open(jobId: jobId)
        return true
    }
}

extension MotherJob: MotherJobLike {}


// MARK: - MotherNoticeSwitches

/// The two Mother notice switches a person can flip: a focus's mode and the global bell. They change
/// what agents receive and what turns cost, so each runs `HumanGesture.permit` first and sends nothing
/// on a refusal. Nothing is applied locally: the UI follows `AppStore.motherNoticeState`.
struct MotherNoticeSwitches {
    var gesture = MotherGestureInputs()
    var send: (ClientMotherNoticeSettingsSet.Scope, String?, MotherNoticeMode?, Bool?) -> Void = {
        AppStore.shared.client.sendMotherNoticeSettings(scope: $0, tag: $1, mode: $2, enabled: $3)
    }

    /// - Returns: `true` when the frame was sent.
    @discardableResult
    func setFocusMode(tag: String, mode: MotherNoticeMode, control: NSView, menuSelection: Bool) -> Bool {
        guard permitted(control: control, menuSelection: menuSelection, what: "notice mode") else { return false }
        send(.focus, tag, mode, nil)
        return true
    }

    @discardableResult
    func setGlobal(enabled: Bool, control: NSView) -> Bool {
        guard permitted(control: control, menuSelection: false, what: "notice switch") else { return false }
        send(.global, nil, nil, enabled)
        return true
    }

    private func permitted(control: NSView, menuSelection: Bool, what: String) -> Bool {
        let verdict = HumanGesture.permit(gesture.currentEvent(), control: control, menuSelection: menuSelection,
                                          voiceOverEnabled: gesture.voiceOverEnabled,
                                          allowsSynthetic: gesture.allowsSynthetic)
        if case .refused(let reason) = verdict {
            log.info("\(what, privacy: .public) refused: \(reason.rawValue, privacy: .public)")
            return false
        }
        return true
    }
}
