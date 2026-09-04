// NostromoKit — DaemonStore.swift
//
// @MainActor ObservableObject that owns a NetworkClient and routes ServerMsg
// into observable state consumed by SwiftUI views.
//
// DaemonStore is the single source of truth for the iOS app:
//   - sessions: [String: SessionInfo]  keyed by tag
//   - connected: Bool                  forwarded from NetworkClient
//
// When a SessionListResp arrives (reply to the implicit session_list request
// sent after subscribe), the sessions dict is fully replaced.
// SessionState messages update individual entries in place.
// SessionDown/SessionExited mark sessions as not-alive.

import Foundation
import Combine

@MainActor
public final class DaemonStore: ObservableObject {

    // MARK: - Public state

    /// All known sessions, keyed by tag.  Updated by `session_list_resp` and
    /// `session_state` messages.
    @Published public private(set) var sessions: [String: SessionInfo] = [:]

    /// Sorted session list for list views (stable order by tag).
    public var sessionList: [SessionInfo] {
        sessions.values.sorted { $0.tag < $1.tag }
    }

    /// All known Mother jobs. Updated by `mother_jobs` broadcasts.
    @Published public private(set) var motherJobs: [MotherJob] = []

    /// Live peek snapshots keyed by job id.  Updated by `mother_peek` broadcasts.
    /// An entry is cleared when its todos array arrives empty (terminal transition).
    @Published public private(set) var motherPeeks: [String: MotherPeekSnapshot] = [:]

    /// Perri PR review queue. Updated by `perri_state` broadcasts.
    @Published public private(set) var perriQueue: [PrQueueItem] = []

    /// Perri current-PR detail snapshot. Updated by `perri_state` broadcasts.
    @Published public private(set) var perriCurrentPr: PrSnapshot? = nil

    /// Fred mailbox snapshot. Updated by `fred_state` broadcasts; nil until first broadcast.
    @Published public private(set) var fredMailbox: MailboxSnapshot? = nil

    /// Fred calendar snapshot. Updated by `fred_state` broadcasts; nil until first broadcast.
    @Published public private(set) var fredCalendar: CalendarSnapshot? = nil

    /// Latest Teri todos snapshot. Updated by `teri_state` broadcasts.
    @Published public private(set) var teriTodos: TeriTodosSnapshot? = nil

    /// Daemon-served focus registry, keyed by tag.
    @Published public private(set) var focuses: [String: FocusMeta] = [:]

    /// Per-focus layout models, keyed by session tag.
    /// Updated by `focus_layout` (structural) and `pane_content` (content-only) broadcasts.
    @Published public private(set) var focusLayouts: [String: FocusLayoutModel] = [:]

    /// Per-focus region UI state (W5 — ios-curated-view-parity, D6): which
    /// pane is frontmost per region path, unread marks, scroll-restore keys.
    /// Updated on `focus_layout` arrival (classified against the previously
    /// stored tree — see `handle(_:)`) and on `pane_content` arrival (a
    /// content-version bump, and a frontmost-pane refresh so a push to the
    /// visible tab is never marked unread).
    @Published public private(set) var focusRegionStates: [String: FocusRegionState] = [:]

    /// Per-focus transcript stores, and per-(focus, pane) scroll-restore
    /// keys (W6 — ios-curated-view-parity, D5). Deliberately NOT
    /// `@Published`: neither is a rendering input for this object's own
    /// observers, and both must survive a view-hierarchy rebuild. See
    /// `transcriptStore(for:)` and `setScrollKey(tag:paneId:key:)`.
    private var transcriptStores: [String: TranscriptStore] = [:]
    private var scrollKeys: [String: [String: Int]] = [:]

    /// Focuses grouped + ordered for list rendering.
    public var focusRows: [FocusRow] { buildFocusRows(Array(focuses.values)) }

    /// Whether the daemon connection is currently alive.
    @Published public private(set) var connected: Bool = false

    // MARK: - Ambient activity (ios-curated-view-parity W4)

    /// One assembled `ActivityStreamModel` per focus tag, keyed by
    /// `ActivityEvent.focusTag` (or `unattributedActivityKey` for events the
    /// daemon couldn't resolve to a known focus — never dropped, never
    /// guessed onto an arbitrary tab).
    @Published public private(set) var activityModels: [String: ActivityStreamModel] = [:]

    /// Daemon-wide ambient-activity ingestion health (not per-focus — the
    /// daemon's `ActivityHealth` broadcast describes its own ingest, not one
    /// focus's). Defaults optimistic until the first real frame arrives.
    @Published public private(set) var activityHealth = ActivityHealthState(
        ingesting: true, reason: nil, lastEventAt: nil, hookInstalled: true)

    /// Key `activityModels` is stored under for an event the daemon could
    /// not attribute to a known focus.
    public static let unattributedActivityKey = "__unattributed__"

    /// Tags with an outstanding `ClientActivitySnapshotRequest` — set on a
    /// detected gap, cleared once that tag's `activitySnapshot` arrives.
    /// Exposed so the one-outstanding-request-per-tag rate limit (D8) is
    /// directly testable without inspecting the socket (`NetworkClient.send`
    /// no-ops silently with no live connection in tests).
    @Published public private(set) var pendingActivitySnapshotRequests: Set<String> = []

    /// Count of `ClientActivitySnapshotRequest` frames actually sent, per
    /// tag — the test-observable stand-in for "was the wire message sent."
    @Published public private(set) var activitySnapshotRequestCount: [String: Int] = [:]

    // MARK: - Dependencies

    public let client: NetworkClient

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    public init(client: NetworkClient) {
        self.client = client
        bind()
    }

    // MARK: - Lifecycle

    public func start() {
        client.start()
    }

    public func stop() {
        client.stop()
    }

    /// Request a fresh `SessionListResp` from the daemon.  Views can call this
    /// on pull-to-refresh; the response arrives via the normal message stream.
    public func refreshSessions() {
        client.send(ClientSessionList())
    }

    /// Request a fresh `FocusListResp` from the daemon.
    public func refreshFocuses() {
        client.send(ClientFocusList())
    }

    /// The operator tapping a tab in `TabStripView` (W5 — ios-curated-view-
    /// parity, D1/D6). Local client state only — no daemon round trip: a tab
    /// switch is operator input, not something the daemon needs to know
    /// about. Makes `paneId` frontmost for `regionPath` within `tag`'s focus
    /// and clears its unread mark.
    public func selectPane(tag: String, regionPath: String, paneId: String) {
        var region = focusRegionStates[tag] ?? FocusRegionState()
        let version = focusLayouts[tag]?.paneContentVersion[paneId] ?? 0
        region.select(paneId: paneId, regionPath: regionPath, contentVersion: version)
        // W6 (D5): the selection is ALSO recorded under the compact strip's
        // region, so that rotating an iPad from a regular-width region into
        // the single-strip presentation shows the surface the operator was
        // actually reading rather than whatever the strip last held. At
        // regular width `RegionPath.root` is never itself a visible region
        // unless the tree's root IS the tabs node being selected in (in
        // which case this is the same write), so this can't disturb a
        // sibling region's own frontmost tab.
        if regionPath != FocusRegionState.compactRegion {
            region.select(paneId: paneId, regionPath: FocusRegionState.compactRegion, contentVersion: version)
        }
        focusRegionStates[tag] = region
    }

    /// Request a full ambient-activity snapshot for `tag` (D8). Rate-limited
    /// to one outstanding request per tag so a burst of gaps on a cellular
    /// link cannot produce a request storm — a constraint macOS's `AppStore`
    /// doesn't need because a Mac's link isn't the bottleneck. The pending
    /// marker is cleared when that tag's `activitySnapshot` arrives
    /// (`handle(_:)`), so a later gap can request again.
    public func requestActivitySnapshot(tag: String) {
        guard !pendingActivitySnapshotRequests.contains(tag) else { return }
        pendingActivitySnapshotRequests.insert(tag)
        activitySnapshotRequestCount[tag, default: 0] += 1
        client.send(ClientActivitySnapshotRequest(tag: tag))
    }

    /// Send a Mother job action to the daemon.
    ///
    /// The daemon shells out to `mother <action> <job_id>` and re-broadcasts
    /// a fresh `mother_jobs` snapshot.  Valid action strings: `"cancel"`,
    /// `"retry"`, `"force_start"`.
    public func motherAction(jobId: String, action: String) {
        client.send(ClientMotherAction(jobId: jobId, action: action))
    }

    /// Resume an awaiting Mother job by supplying the operator's answer.
    ///
    /// The daemon shells out to `mother resume <job_id> <answer>` and
    /// re-broadcasts a fresh `mother_jobs` snapshot.
    public func motherResume(jobId: String, answer: String) {
        client.send(ClientMotherResume(jobId: jobId, answer: answer))
    }

    // MARK: - Bindings

    private func bind() {
        // Forward connection state.
        client.$connected
            .receive(on: RunLoop.main)
            .sink { [weak self] isConnected in
                self?.connected = isConnected
                if isConnected {
                    // Request the current session list immediately after connecting.
                    self?.client.send(ClientSessionList())
                    // Request the focus registry immediately after connecting.
                    self?.client.send(ClientFocusList())
                } else {
                    // Clear stale state on disconnect so the list doesn't show
                    // ghost entries if the daemon is restarted.
                    self?.sessions       = [:]
                    self?.focuses        = [:]
                    self?.focusLayouts   = [:]
                    self?.focusRegionStates = [:]
                    self?.motherJobs     = []
                    self?.motherPeeks    = [:]
                    self?.perriQueue     = []
                    self?.perriCurrentPr = nil
                    self?.fredMailbox    = nil
                    self?.fredCalendar   = nil
                    self?.teriTodos      = nil
                    // A reconnect starts fresh and says so — never
                    // resurrects pre-drop events (D8's client half of the
                    // PRD's "no persistence across a drop" requirement).
                    self?.activityModels = [:]
                    self?.activityHealth = ActivityHealthState(
                        ingesting: false, reason: "disconnected", lastEventAt: nil,
                        hookInstalled: self?.activityHealth.hookInstalled ?? true)
                    self?.pendingActivitySnapshotRequests = []
                }
            }
            .store(in: &cancellables)

        // Route incoming server messages.
        client.messages
            .receive(on: RunLoop.main)
            .sink { [weak self] msg in
                self?.handle(msg)
            }
            .store(in: &cancellables)
    }

    // MARK: - Message handling

    private func handle(_ msg: ServerMsg) {
        switch msg {

        case .sessionListResp(let list):
            // Replace the full sessions dict with the fresh snapshot.
            sessions = Dictionary(uniqueKeysWithValues: list.map { ($0.tag, $0) })

        case .sessionState(let tag, let state):
            guard var info = sessions[tag] else { return }
            info = SessionInfo(
                tag:           info.tag,
                agentName:     info.agentName,
                viewName:      info.viewName,
                sessionId:     info.sessionId,
                alive:         state != .crashed,
                remoteControl: info.remoteControl,
                state:         state,
                stopReason:    info.stopReason
            )
            sessions[tag] = info

        case .sessionDown(let tag, let reason):
            guard var info = sessions[tag] else { return }
            info = SessionInfo(
                tag:           info.tag,
                agentName:     info.agentName,
                viewName:      info.viewName,
                sessionId:     info.sessionId,
                alive:         false,
                remoteControl: info.remoteControl,
                state:         .idle,
                stopReason:    reason
            )
            sessions[tag] = info

        case .sessionExited(let tag, _):
            guard var info = sessions[tag] else { return }
            info = SessionInfo(
                tag:           info.tag,
                agentName:     info.agentName,
                viewName:      info.viewName,
                sessionId:     info.sessionId,
                alive:         false,
                remoteControl: info.remoteControl,
                state:         .idle,
                stopReason:    info.stopReason
            )
            sessions[tag] = info

        case .sessionSpawned(let tag, let sessionId):
            if var info = sessions[tag] {
                info = SessionInfo(
                    tag:           info.tag,
                    agentName:     info.agentName,
                    viewName:      info.viewName,
                    sessionId:     sessionId ?? info.sessionId,
                    alive:         true,
                    remoteControl: info.remoteControl,
                    state:         info.state,
                    stopReason:    nil
                )
                sessions[tag] = info
            }
            // Re-request the list to pick up any new sessions.
            client.send(ClientSessionList())

        case .focusListResp(let list), .focusRegistryUpdated(let list):
            focuses = Dictionary(uniqueKeysWithValues: list.map { ($0.tag, $0) })

        case .motherJobs(let jobs):
            motherJobs = jobs

        case .motherPeek(let snap):
            if snap.todos.isEmpty {
                motherPeeks.removeValue(forKey: snap.jobId)
            } else {
                motherPeeks[snap.jobId] = snap
            }

        case .perriState(let queue, let current):
            perriQueue     = queue
            perriCurrentPr = current

        case .fredState(let mailbox, let calendar):
            fredMailbox  = mailbox
            fredCalendar = calendar

        case .teriState(let snap):
            teriTodos = snap

        case .focusLayout(let tag, let tree, let focusedPane):
            var model = focusLayouts[tag] ?? FocusLayoutModel.initial
            let oldTree = model.tree
            model.tree        = tree
            model.focusedPane = focusedPane
            focusLayouts[tag] = model

            // W5 (ios-curated-view-parity, D4): classify the change against
            // the previously-stored tree and apply the transition into this
            // focus's region state — the mechanism by which a deliberate
            // show's `active`/`focused_pane` is honoured without an
            // unrelated content-only republish fighting the operator's own
            // tab choice.
            //
            // W6: applied to EVERY region in either presentation, not just
            // the compact strip — a regular-width tree has one region per
            // simultaneously-visible area, each with its own frontmost tab.
            // Each region sees only the panes it hosts as `available`, which
            // is what makes "a show that changes the frontmost tab of one
            // region does not change the frontmost tab of another" true:
            // `focused_pane` can only land in the region that actually holds
            // it. Region paths are a pure function of the tree, so this
            // maintains both presentations' state without the store ever
            // knowing which width is on screen.
            let change = LayoutChangeClassifier.classify(old: oldTree, new: tree)
            var region = focusRegionStates[tag] ?? FocusRegionState()
            for membership in Self.regionMemberships(tree: tree, content: model.paneContent) {
                region.apply(
                    change: change,
                    regionPath: membership.path,
                    // The compact strip keeps W5's whole-tree resolution
                    // verbatim (nil when two tabs nodes disagree — one strip
                    // has one frontmost thing, and guessing is worse than
                    // declining). A regular-width region resolves its OWN
                    // tabs node's `active`, because two regions are two
                    // separate frontmost things and neither is ambiguous.
                    treeActivePaneId: membership.path == FocusRegionState.compactRegion
                        ? tree.resolvedActivePaneId
                        : LayoutRegions.activePane(forRegion: membership.path, in: tree),
                    focusedPane: focusedPane,
                    available: membership.paneIds
                )
            }
            // Region state for a path or pane the new tree no longer
            // contains is discarded rather than accumulating for the
            // lifetime of the connection — and, worse, resurrecting a stale
            // frontmost pane if a later rebuild reintroduces the same path.
            region.prune(
                livePaths: LayoutRegions.allPaths(in: tree),
                livePanes: Set(tree.paneIds)
            )
            focusRegionStates[tag] = region

        case .paneContent(let tag, let paneId, let content, let freshness, let address):
            var model = focusLayouts[tag] ?? FocusLayoutModel.initial
            // A `.loading` update must never clobber content the operator is
            // already looking at — render it only on first paint (no prior
            // content for this pane, or the prior content was itself `.loading`).
            let existing = model.paneContent[paneId]
            if content == .loading, let existing, existing != .loading {
                return
            }
            model.paneContent[paneId] = content
            model.paneFreshness[paneId] = freshness
            model.paneAddress[paneId] = address
            // W5, D7: the content-version bump lives here, after the
            // suppression guard above — a suppressed `.loading` push must
            // never mark a pane unread, so it must never bump the version.
            model.paneContentVersion[paneId, default: 0] += 1
            focusLayouts[tag] = model

            // A push to the pane that's already frontmost is immediately
            // seen — refresh its last-seen version so it's never marked
            // unread (D7).
            //
            // W6: noted for every region hosting this pane in EITHER
            // presentation, so the unread mark is legible per region at
            // regular width — where a show can land unseen in a region the
            // operator isn't looking at *within a view he is looking at*.
            // The compact strip's region is always included, even for a push
            // that arrives before the `focus_layout` introducing its pane
            // (when `hostingPaths` can't place it yet), so W5's behaviour is
            // preserved exactly.
            var region = focusRegionStates[tag] ?? FocusRegionState()
            var paths = LayoutRegions.hostingPaths(of: paneId, in: model.tree)
            if !paths.contains(FocusRegionState.compactRegion) {
                paths.insert(FocusRegionState.compactRegion, at: 0)
            }
            for path in paths {
                region.noteContentVersion(
                    paneId: paneId,
                    regionPath: path,
                    contentVersion: model.paneContentVersion[paneId] ?? 0
                )
            }
            focusRegionStates[tag] = region

        case .focusCreated(let meta):
            // Register the new focus in the focus registry.
            focuses[meta.tag] = meta.toFocusMeta()
            // Seed the layout model so the tab appears immediately.
            if focusLayouts[meta.tag] == nil {
                focusLayouts[meta.tag] = FocusLayoutModel.initial
            }

        case .activity(let ev):
            let tag = ev.focusTag ?? Self.unattributedActivityKey
            var model = activityModels[tag] ?? ActivityStreamModel()
            let gapDetected = model.ingest(ev)
            activityModels[tag] = model
            if gapDetected {
                // A seq gap means this stream may already be presenting an
                // incomplete record — re-sync from a full daemon snapshot
                // rather than silently continue with a hole in the history.
                requestActivitySnapshot(tag: tag)
            }

        case .activitySnapshot(let tag, let streams):
            var model = ActivityStreamModel()
            for stream in streams {
                for event in stream.events {
                    model.ingest(event)
                }
            }
            activityModels[tag] = model
            // The snapshot this gap asked for has arrived — a later gap for
            // this tag is free to request another.
            pendingActivitySnapshotRequests.remove(tag)

        case .activityHealth(let ingesting, let reason, let lastEventAt, let hookInstalled):
            activityHealth = ActivityHealthState(
                ingesting: ingesting, reason: reason, lastEventAt: lastEventAt, hookInstalled: hookInstalled)

        default:
            break
        }
    }

    // MARK: - Perri actions

    /// Load a specific PR into the Perri current-PR view.
    ///
    /// The daemon shells out to `perri load_pr -- <number> <repo>` and the
    /// native source re-broadcasts a fresh `perri_state` snapshot.
    public func perriLoadPr(number: Int, repo: String) {
        client.send(ClientPerriAction(action: "load_pr", prNumber: number, repo: repo))
    }

    /// Clear the current PR from the Perri view.
    ///
    /// The daemon shells out to `perri clear_current_pr` and the native source
    /// re-broadcasts a fresh `perri_state` snapshot.
    public func perriClear() {
        client.send(ClientPerriAction(action: "clear", prNumber: nil, repo: nil))
    }

    /// Approve a PR from the iOS queue row.
    ///
    /// The daemon resolves the HEAD sha, posts `gh pr review --approve`, then
    /// writes the Phase 1 approval signal (approvals.jsonl + queue.dirty) so
    /// the PR is suppressed on the next broadcast — identical instant-removal
    /// behaviour to the desk `submit-review` flow.
    ///
    /// **Always gate this call behind a `confirmationDialog`** — the user must
    /// explicitly confirm before anything is posted to GitHub.
    public func perriApprove(number: Int, repo: String) {
        client.send(ClientPerriAction(action: "approve", prNumber: number, repo: repo))
    }
}


// MARK: - Long-lived per-focus view state (ios-curated-view-parity W6, D5)

extension DaemonStore {

    /// The `TranscriptStore` for `tag`, created on first request and kept
    /// for the lifetime of this `DaemonStore`.
    ///
    /// The transcript's turns used to live in a `@StateObject` inside
    /// `TranscriptView`, which is fine right up until something destroys and
    /// rebuilds that view — which is exactly what a width-class change does.
    /// A fresh `TranscriptStore` starts empty and re-requests the whole
    /// snapshot, so rotating an iPad blanked the transcript, refilled it, and
    /// let its autoscroll drag the operator to the bottom of a conversation
    /// she was reading the middle of. Hoisting the store here is the same
    /// move `FocusRegionState` makes for frontmost tabs and unread marks
    /// (W5, memo B4): the state survives the transition because it was never
    /// in the view.
    ///
    /// NOT `@Published` — nothing about this cache is a rendering input, and
    /// republishing the whole store when a focus is first opened would
    /// re-render every other view observing it. `TranscriptStore` is itself
    /// an `ObservableObject`; views observe the returned instance directly.
    public func transcriptStore(for tag: String) -> TranscriptStore {
        if let existing = transcriptStores[tag] { return existing }
        let created = TranscriptStore(client: client)
        transcriptStores[tag] = created
        return created
    }

    /// Record `paneId`'s scroll-restore key for `tag`.
    ///
    /// Held OUTSIDE `focusRegionStates` on purpose, even though
    /// `FocusRegionState` owns the same notion for its own (tested) restore
    /// decision: `focusRegionStates` is `@Published`, and a scroll key
    /// changes as the operator's thumb moves. Republishing the store on
    /// every scroll tick would re-render every surface in the focus mid-drag
    /// — jank introduced by the very mechanism meant to stop the view
    /// jumping. Surfaces save on teardown and restore on first layout, so
    /// this is written rarely and read once.
    public func setScrollKey(tag: String, paneId: String, key: Int) {
        scrollKeys[tag, default: [:]][paneId] = key
    }

    /// What restoring `paneId`'s saved scroll position should do, given what
    /// the surface currently reports visible. Delegates the decision to
    /// `ScrollRestore.decide` — the same rule, and the same tested three
    /// lines, `FocusRegionState.scrollRestore` uses and macOS's
    /// `ScrollDecision` has used since W2.
    public func scrollRestore(tag: String, paneId: String, visibleRange: ClosedRange<Int>?) -> ScrollRestore {
        ScrollRestore.decide(savedKey: scrollKeys[tag]?[paneId], visibleRange: visibleRange)
    }
}

// MARK: - Region membership (ios-curated-view-parity W6)

extension DaemonStore {

    /// Every region that hosts panes in EITHER presentation of `tree`, with
    /// the panes it hosts — the compact strip's single `RegionPath.root`
    /// region first, then each regular-width region in walk order.
    ///
    /// The store deliberately maintains both presentations' region state
    /// without knowing which one is currently on screen: it can't know (the
    /// width class is a SwiftUI environment value read in the focus view,
    /// and there may be no view at all when a broadcast arrives), and it
    /// doesn't need to, because region paths are a pure function of the tree
    /// rather than of the presentation. That is the entire mechanism behind
    /// W6's losslessness criterion — state written while the iPad was
    /// landscape is found again the instant it turns portrait.
    ///
    /// Where both presentations name the same path (a `tabs` node sitting at
    /// the tree root), the two memberships are merged rather than applied
    /// twice, with the compact region's fuller pane list winning — a
    /// superset of `available` only ever widens what `apply` will accept,
    /// never narrows it.
    static func regionMemberships(
        tree: PaneTree,
        content: [String: PaneContentWire]
    ) -> [RegionMembership] {
        var ordered: [String] = []
        var panes: [String: [String]] = [:]

        func add(_ membership: RegionMembership) {
            if panes[membership.path] == nil {
                ordered.append(membership.path)
                panes[membership.path] = membership.paneIds
                return
            }
            var merged = panes[membership.path] ?? []
            for paneId in membership.paneIds where !merged.contains(paneId) {
                merged.append(paneId)
            }
            panes[membership.path] = merged
        }

        layoutPlan(tree: tree, width: .compact, content: content).regions.forEach(add)
        layoutPlan(tree: tree, width: .regular, content: content).regions.forEach(add)

        return ordered.map { RegionMembership(path: $0, paneIds: panes[$0] ?? []) }
    }
}
