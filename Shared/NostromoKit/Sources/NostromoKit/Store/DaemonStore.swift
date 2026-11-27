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

    /// Perri current-PR detail snapshot, per focus (W7/W8). Updated by
    /// `perri_state` broadcasts, keyed by the frame's `tag` — a frame for one
    /// focus never overwrites another's entry. An entry's lifetime matches
    /// its focus's: pruned to the live focus set whenever `focuses` changes
    /// (see `handle(_:)`'s `.focusListResp`/`.focusRegistryUpdated` arm).
    @Published public private(set) var perriCurrentPr: [String: PrSnapshot] = [:]

    /// The PR under review for `tag`, or `nil` when that focus has none.
    public func perriCurrentPr(for tag: String) -> PrSnapshot? {
        perriCurrentPr[tag]
    }

    /// Fred mailbox snapshot. Updated by `fred_state` broadcasts; nil until first broadcast.
    @Published public private(set) var fredMailbox: MailboxSnapshot? = nil

    /// Fred calendar snapshot. Updated by `fred_state` broadcasts; nil until first broadcast.
    @Published public private(set) var fredCalendar: CalendarSnapshot? = nil

    /// Latest Teri todos snapshot. Updated by `teri_state` broadcasts.
    @Published public private(set) var teriTodos: TeriTodosSnapshot? = nil
    /// Topics the daemon withheld from this connection (e.g. teri, fred, work).
    @Published public private(set) var withheldTopics: Set<String> = []

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

    /// Focuses grouped + ordered for list rendering. Each row's secondary
    /// line is the focus's PR under review (W8) when it has one — see
    /// `FocusPRLabel`.
    public var focusRows: [FocusRow] {
        buildFocusRows(Array(focuses.values)) { tag in
            let pr = self.perriCurrentPr[tag]
            return (pr?.repo, pr?.prNumber)
        }
    }

    /// Whether the daemon connection is currently alive.
    @Published public private(set) var connected: Bool = false

    // MARK: - Backplane state (W11)

    /// Why the link is up or down. Only `.notPaired` means the pairing is gone (PRD-AC22).
    @Published public private(set) var connectionState: ConnectionState = .connecting

    /// What the screen shows is last-known, not live: it came from the cache or from before a drop.
    @Published public private(set) var isStale: Bool = false

    /// When the cached snapshot was saved, while `isStale` because of a relaunch.
    @Published public private(set) var lastKnownAt: Date? = nil

    /// Why a topic is withheld, from `Withheld.reason` (`not_shared` in v1: Q2).
    @Published public private(set) var withheldReasons: [String: String] = [:]

    /// Mother jobs of each satellite host, keyed by the host's name. The primary's own jobs stay in
    /// `motherJobs`, so a job is identified by `(host, id)` and two hosts' queues never collide.
    @Published public private(set) var hostedMotherJobs: [String: [MotherJob]] = [:]

    /// Sessions and focuses of each satellite host, keyed by host name (metadata only for a `work` host).
    @Published public private(set) var hostedSessions: [String: [SessionInfo]] = [:]
    @Published public private(set) var hostedFocuses: [String: [FocusMeta]] = [:]

    /// A satellite's Perri queue and PRs under review, and the decisions it holds, by host name.
    /// Display only: the phone answers nothing. The primary's own stay in `perriQueue` and
    /// `pendingDecisions`.
    @Published public private(set) var hostedPerri: [String: HostedPerriState] = [:]
    @Published public private(set) var hostedDecisions: [String: [HostedDecision]] = [:]

    /// The satellites connected to the primary, from `Hosts`.
    @Published public private(set) var hostInfos: [HostInfoWire] = []

    /// Every satellite heard of, kept across a disconnect so its last-known rows keep a name, an
    /// egress and a last-seen time.
    @Published public private(set) var hostRoster = HostRoster()

    /// Permission requests held per host and focus tag (`""` is the primary), from `approval_pending`.
    @Published public private(set) var approvalCounts: [String: [String: Int]] = [:]

    /// Which Macs' content the Focuses, Perri and queue views show. Persisted (non-sensitive, per
    /// install). Use `effectiveScope(primaryName:)` to read it: it falls back to All when it names a
    /// host that is gone.
    @Published public private(set) var scopeSelection: HostScope = .all

    /// Topics the daemon said (`gap`) may have missed updates for this client, by topic name
    /// (`"mother_jobs"`, `"perri"`, ...). A list shows `MissedUpdatesNotice.text` while its topic is
    /// here; `refreshMissedUpdates()` is the pull-to-refresh that clears them.
    @Published public private(set) var missedUpdates: Set<String> = []

    /// What each host last reported it may do with content. Kept after the host disconnects, so its
    /// last-known rows keep their shape; a host never heard from is treated as `work`.
    @Published public private(set) var hostEgress: [String: HostEgress] = [:]

    /// The merged list across Macs (Q8): "needs you" first, then recency; each row carries its
    /// Mac's name when the rows come from more than one Mac or the scope is a group of Macs.
    /// `primaryName` names the primary's rows.
    public func mergedQueue(primaryName: String) -> [MergedQueueRow] {
        MergedQueue.rows(primaryJobs: motherJobs, primarySessions: sessionList,
                         hostedJobs: hostedMotherJobs, hostedSessions: hostedSessions,
                         egress: hostEgress, primaryName: primaryName,
                         hostedDecisions: hostedDecisions,
                         approvalCounts: approvalCounts.filter { !$0.key.isEmpty },
                         scope: displayScope(primaryName: primaryName),
                         hosts: hostEntries(primaryName: primaryName))
    }

    // MARK: - Hosts and scope (W11 slice 2)

    /// The Macs the phone can show content for: the primary, then each satellite heard of. A
    /// satellite that is not connected (or any, while the phone's own link is down) is last-known.
    public func hostEntries(primaryName: String) -> [HostEntry] {
        let withContent = Set(hostedMotherJobs.keys).union(hostedSessions.keys).union(hostedFocuses.keys)
            .union(hostedPerri.keys).union(hostedDecisions.keys)
            .union(approvalCounts.keys.filter { !$0.isEmpty })
        return hostRoster.entries(primaryName: primaryName, hostsWithContent: withContent,
                                  linkLive: connected && !isStale)
    }

    /// The selected scope, or All when it names a host that is gone (or a kind no host has).
    public func effectiveScope(primaryName: String) -> HostScope {
        scopeSelection.resolved(against: hostEntries(primaryName: primaryName))
    }

    /// The scope the lists are drawn with. With only one Mac there is nothing to choose between, so no
    /// group scope applies and no Mac name is added to a row (Q8: rows from one Mac carry none).
    public func displayScope(primaryName: String) -> HostScope {
        let hosts = hostEntries(primaryName: primaryName)
        return hosts.count > 1 ? scopeSelection.resolved(against: hosts) : .host(primaryName)
    }

    /// What the scope picker offers right now.
    public func scopeOptions(primaryName: String) -> [HostScope] {
        HostScopeOptions.options(for: hostEntries(primaryName: primaryName))
    }

    /// Choose what to show everywhere (Focuses, Perri, queue) and remember it.
    public func selectScope(_ scope: HostScope) {
        scopeSelection = scope
        scopeDefaults.set(scope.storageValue, forKey: Self.scopeDefaultsKey)
    }

    /// The Focuses list's sections under the current scope: the primary's first, then each satellite's,
    /// keyed by (host, tag).
    public func focusSections(primaryName: String, now: Date = Date()) -> [FocusHostSection] {
        HostedFocuses.sections(
            primaryFocuses: Array(focuses.values), primarySessions: sessions,
            primaryPR: { tag in
                let pr = self.perriCurrentPr[tag]
                return (pr?.repo, pr?.prNumber)
            },
            hostedFocuses: hostedFocuses, hostedSessions: hostedSessions, hostedPerri: hostedPerri,
            hosts: hostEntries(primaryName: primaryName), scope: displayScope(primaryName: primaryName),
            now: now)
    }

    /// The satellites' Perri sections under the current scope. The primary's own queue is drawn
    /// separately (and only when `showsPrimary(primaryName:)`).
    public func perriSections(primaryName: String, now: Date = Date()) -> [PerriHostSection] {
        let scope = displayScope(primaryName: primaryName)
        return HostedPerri.sections(hostedPerri: hostedPerri, hosts: hostEntries(primaryName: primaryName),
                                    scope: scope, includePrimary: scope.matches(host: primaryName, egress: .personal)
                                        && !perriQueue.isEmpty,
                                    now: now)
    }

    /// Whether the primary's own content is in the current scope.
    public func showsPrimary(primaryName: String) -> Bool {
        effectiveScope(primaryName: primaryName).matches(host: primaryName, egress: .personal)
    }

    /// The "needs you" count per host (`""` is the primary), display only. Fed from Kit's
    /// `NeedsYouAggregator` by a Mother producer and an approvals-count producer; the phone shows
    /// the count and never answers, resumes or acknowledges (B10).
    @Published public private(set) var needsYouCount: [String: Int] = [:]

    /// Whether a `mother_jobs` frame has arrived on the live connection (not from the cache): the
    /// pairing success screen waits for it (PRD-AC8).
    @Published public private(set) var motherJobsReceived: Bool = false

    /// Whether this client may answer, resume, cancel or retry anything. False over the backplane
    /// transport: the phone is a read-only window (B10, Q4), and `WebSocketClient` refuses those
    /// verbs besides. True only for the legacy TCP transport.
    public var canMutate: Bool { client.canMutate }

    /// Whether anything last-known is on screen. While it is, the tabs keep showing it under a banner
    /// instead of replacing it with "Disconnected".
    public var hasLastKnownContent: Bool {
        !motherJobs.isEmpty || !sessions.isEmpty || !focuses.isEmpty || !perriQueue.isEmpty
            || !hostedMotherJobs.isEmpty || !hostedSessions.isEmpty || !hostedFocuses.isEmpty
            || hostedPerri.values.contains { !$0.queue.isEmpty } || !hostedDecisions.isEmpty
            || approvalCounts.contains { !$0.key.isEmpty && $0.value.values.contains { $0 > 0 } }
    }

    /// Whether the Fred and Teri tabs should say "Mail, calendar and todos stay on your Mac in this
    /// version." (`Withheld { reason: "not_shared" }`).
    public func isNotShared(_ topic: String) -> Bool {
        withheldTopics.contains(topic) && withheldReasons[topic] == "not_shared"
    }

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

    // MARK: - Decisions (ios-curated-view-parity W3)

    /// The atomic answer-once gate for decision requests. `public` so the
    /// one presentation site (`NostromoApp.swift`) can claim an answer
    /// before sending it — see `answerDecision(requestId:choiceId:)`'s doc
    /// comment for the full claim-then-send contract.
    public let decisionStore = DecisionStore()

    /// Outstanding decision requests, oldest first. A queue, not a slot: the
    /// daemon allows one active request per FOCUS TAG, so two different
    /// focuses can each have a decision outstanding at once, and both must
    /// eventually be presented. The view presents `pendingDecisions.first`
    /// and the next entry becomes current once the head is answered,
    /// dismissed, or resolved elsewhere.
    @Published public private(set) var pendingDecisions: [PendingDecision] = []

    // MARK: - Dependencies

    public let client: any DaemonTransport

    /// The legacy TCP client, when that is the transport (Settings → Advanced → Local network).
    public var legacyClient: NetworkClient? { client as? NetworkClient }

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()
    /// The on-disk last-known content, or `nil` for the legacy transport (which keeps no content
    /// across a drop and clears the screen on disconnect, as it always has).
    private let cache: ContentCache?
    /// Where the scope selection is kept: `UserDefaults.standard` in the app, a throwaway suite in tests.
    private let scopeDefaults: UserDefaults
    static let scopeDefaultsKey = "nostromo.hostScope"
    /// Satellite decisions already resolved, so a late `decision_request` cannot bring one back.
    private var resolvedHostedDecisions: Set<String> = []
    private var needsYou: [String: NeedsYouAggregator] = [:]
    /// Set by `wipeAll()`: a frame already in flight must not refill the store or the cache after a
    /// wipe. Cleared by the next live connection.
    private var isWiped = false

    // MARK: - Init

    /// `cache` non-nil is the backplane mode: the cached collections survive a drop (marked
    /// `isStale`), and a relaunch starts from the saved snapshot.
    public init(client: any DaemonTransport, cache: ContentCache? = nil,
                scopeDefaults: UserDefaults = .standard) {
        self.client = client
        self.cache = cache
        self.scopeDefaults = scopeDefaults
        self.scopeSelection = HostScope(storageValue: scopeDefaults.string(forKey: Self.scopeDefaultsKey))
        bind()
        hydrateFromCache()
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
        client.connectionStatePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.connectionState = $0 }
            .store(in: &cancellables)

        client.connectedPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] isConnected in
                self?.connected = isConnected
                if isConnected {
                    self?.isWiped = false
                    self?.isStale = false
                    self?.lastKnownAt = nil
                    // The primary does not retain a satellite's decision requests, so one held
                    // from before this connection cannot be vouched for: it goes until a live
                    // frame says it is (still) there.
                    self?.hostedDecisions = [:]
                    self?.resolvedHostedDecisions = []
                    // Request the current session list immediately after connecting.
                    self?.client.send(ClientSessionList())
                    // Request the focus registry immediately after connecting.
                    self?.client.send(ClientFocusList())
                } else {
                    // With a cache, the cached collections are last-known content: keep them on
                    // screen, marked stale, until the next connection replaces them (PRD-AC22).
                    // Without one (legacy transport) clear them so the list doesn't show ghost
                    // entries if the daemon is restarted.
                    if self?.cache != nil {
                        self?.isStale = self?.hasLastKnownContent ?? false
                    } else {
                        self?.clearLastKnownContent()
                    }
                    self?.focusLayouts   = [:]
                    self?.focusRegionStates = [:]
                    self?.motherPeeks    = [:]
                    self?.fredMailbox    = nil
                    self?.fredCalendar   = nil
                    self?.teriTodos      = nil
                    self?.withheldTopics = []
                    self?.withheldReasons = [:]
                    // A reconnect starts fresh and says so — never
                    // resurrects pre-drop events (D8's client half of the
                    // PRD's "no persistence across a drop" requirement).
                    self?.activityModels = [:]
                    self?.activityHealth = ActivityHealthState(
                        ingesting: false, reason: "disconnected", lastEventAt: nil,
                        hookInstalled: self?.activityHealth.hookInstalled ?? true)
                    self?.pendingActivitySnapshotRequests = []
                    // A request whose daemon connection is gone cannot be
                    // answered — leaving an armed sheet up after a reconnect
                    // would answer a request the daemon has already
                    // cancelled. `decisionStore`'s claimed resolutions are
                    // NOT cleared here; they're a record of what's already
                    // answered, not a liveness signal.
                    self?.pendingDecisions = []
                }
            }
            .store(in: &cancellables)

        // Route incoming server messages.
        client.framePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] frame in
                guard self?.isWiped == false else { return }
                if let raw = frame.raw { self?.cache?.record(host: frame.host, raw: raw) }
                self?.handle(frame.msg, host: frame.host)
            }
            .store(in: &cancellables)
    }

    // MARK: - Needs you (display only)

    private func refreshNeedsYouMother(host: String, jobs: [MotherJob]) {
        var aggregator = needsYou[host] ?? NeedsYouAggregator()
        aggregator.set(producer: MotherNeedsYouProducer.name, items: MotherNeedsYouProducer.items(from: jobs))
        needsYou[host] = aggregator
        needsYouCount[host] = aggregator.snapshot.total
    }

    private func refreshNeedsYouApprovals(host: String, tag: String, count: Int) {
        approvalCounts[host, default: [:]][tag] = count
        let items = approvalCounts[host, default: [:]].sorted { $0.key < $1.key }.flatMap { tag, count in
            (0..<max(count, 0)).map {
                NeedsYouItem(id: "approvals:\(tag):\($0)", source: .focus(tag), reason: .approvalPending(1))
            }
        }
        var aggregator = needsYou[host] ?? NeedsYouAggregator()
        aggregator.set(producer: ApprovalsNeedsYouProducer.name, items: items)
        needsYou[host] = aggregator
        needsYouCount[host] = aggregator.snapshot.total
    }

    // MARK: - Last-known content

    /// The collections the cache holds and the stale view shows.
    private func clearLastKnownContent() {
        sessions       = [:]
        focuses        = [:]
        motherJobs     = []
        perriQueue     = []
        perriCurrentPr = [:]
        hostedMotherJobs = [:]
        hostedSessions = [:]
        hostedFocuses  = [:]
        hostedPerri    = [:]
        hostedDecisions = [:]
        resolvedHostedDecisions = []
        hostRoster     = HostRoster()
        hostInfos      = []
        hostEgress     = [:]
        needsYou       = [:]
        approvalCounts = [:]
        needsYouCount  = [:]
    }

    /// Loads the saved snapshot through the same `handle` the live frames use, then marks the
    /// content stale: it stays so until the first live connection.
    private func hydrateFromCache() {
        guard let snapshot = cache?.load() else { return }
        for frame in snapshot.frames {
            let hosted = ServerMsg.decodeHosted(from: Data(frame.json.utf8))
            handle(hosted.msg, host: hosted.host)
        }
        motherJobsReceived = false   // cached, not live
        isStale = true
        lastKnownAt = snapshot.savedAt
    }

    /// Pull to refresh after a `gap`: start the subscription over (fresh snapshots, no replay) and
    /// forget the notices.
    public func refreshMissedUpdates() {
        missedUpdates = []
        client.refreshNow()
    }

    /// Forgets everything shown and deletes the cache file. Called when the pairing is gone (revoke,
    /// un-pair, pairing with a different server): after it, memory and disk hold no Nostromo content.
    /// The client forgets its sequence numbers too: a client restarted after a failed pairing would
    /// otherwise resume, be told its topics are "covered", and never be sent the snapshots the wiped
    /// lists need.
    public func wipeAll() {
        client.resetResume()
        isWiped = true
        missedUpdates = []
        cache?.wipe()
        clearLastKnownContent()
        focusLayouts = [:]
        focusRegionStates = [:]
        motherPeeks = [:]
        fredMailbox = nil
        fredCalendar = nil
        teriTodos = nil
        withheldTopics = []
        withheldReasons = [:]
        activityModels = [:]
        pendingActivitySnapshotRequests = []
        pendingDecisions = []
        transcriptStores = [:]
        scrollKeys = [:]
        motherJobsReceived = false
        isStale = false
        lastKnownAt = nil
        scopeSelection = .all
        scopeDefaults.removeObject(forKey: Self.scopeDefaultsKey)
    }

    // MARK: - Message handling

    /// Routes one frame by the host it names: the primary's own (`nil`) takes the long-standing path,
    /// a satellite's frames land in the per-host collections. A satellite's session-scoped frames
    /// (turns, panes, layouts) are not kept: its tags may collide with the primary's.
    private func handle(_ msg: ServerMsg, host: String?) {
        guard let host else { handle(msg); return }
        switch msg {
        case .motherJobs(let jobs):
            hostedMotherJobs[host] = jobs
            refreshNeedsYouMother(host: host, jobs: jobs)
        case .sessionListResp(let list):
            hostedSessions[host] = list
        case .focusListResp(let list), .focusRegistryUpdated(let list):
            hostedFocuses[host] = list
            // As for the primary: a PR pinned to a focus the host no longer lists is gone.
            if var state = hostedPerri[host] {
                let live = Set(list.map(\.tag))
                state.currents = state.currents.filter { live.contains($0.key) }
                hostedPerri[host] = state
            }
        case .perriState(let tag, let queue, let current):
            var state = hostedPerri[host] ?? HostedPerriState()
            state.queue = queue
            if let current { state.currents[tag] = current } else { state.currents.removeValue(forKey: tag) }
            hostedPerri[host] = state
        case .decisionRequest(let tag, let requestId, let prompt, _, _, _):
            let key = "\(host)|\(requestId)"
            guard !resolvedHostedDecisions.contains(key),
                  !(hostedDecisions[host] ?? []).contains(where: { $0.requestId == requestId }) else { return }
            hostedDecisions[host, default: []].append(
                HostedDecision(host: host, tag: tag, requestId: requestId, prompt: prompt))
        case .decisionResolved(_, let requestId, _, _):
            resolvedHostedDecisions.insert("\(host)|\(requestId)")
            hostedDecisions[host]?.removeAll { $0.requestId == requestId }
            if hostedDecisions[host]?.isEmpty == true { hostedDecisions.removeValue(forKey: host) }
        case .approvalPending(let tag, let count):
            refreshNeedsYouApprovals(host: host, tag: tag, count: count)
        default:
            break
        }
    }

    private func handle(_ msg: ServerMsg) {
        switch msg {

        case .sessionListResp(let list):
            // Replace the full sessions dict with the fresh snapshot.
            sessions = Dictionary(list.map { ($0.tag, $0) }, uniquingKeysWith: { _, last in last })

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
                stopReason:    info.stopReason,
                mcpBridgeConnected: info.mcpBridgeConnected,
                agentTurns:    info.agentTurns,
                agentMessages: info.agentMessages,
                agentProblems: info.agentProblems,
                activityEpoch: info.activityEpoch,
                lastProblem:   info.lastProblem
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
                stopReason:    reason,
                mcpBridgeConnected: info.mcpBridgeConnected,
                agentTurns:    info.agentTurns,
                agentMessages: info.agentMessages,
                agentProblems: info.agentProblems,
                activityEpoch: info.activityEpoch,
                lastProblem:   info.lastProblem
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
                stopReason:    info.stopReason,
                mcpBridgeConnected: info.mcpBridgeConnected,
                agentTurns:    info.agentTurns,
                agentMessages: info.agentMessages,
                agentProblems: info.agentProblems,
                activityEpoch: info.activityEpoch,
                lastProblem:   info.lastProblem
            )
            sessions[tag] = info

        case .sessionBridge(let tag, let connected):
            // Additive health signal: whether the session's MCP bridge is
            // connected to the daemon. Ignored for a tag we hold no session for.
            guard var info = sessions[tag] else { return }
            info = SessionInfo(
                tag:           info.tag,
                agentName:     info.agentName,
                viewName:      info.viewName,
                sessionId:     info.sessionId,
                alive:         info.alive,
                remoteControl: info.remoteControl,
                state:         info.state,
                stopReason:    info.stopReason,
                mcpBridgeConnected: connected,
                agentTurns:    info.agentTurns,
                agentMessages: info.agentMessages,
                agentProblems: info.agentProblems,
                activityEpoch: info.activityEpoch,
                lastProblem:   info.lastProblem
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
                    stopReason:    nil,
                    mcpBridgeConnected: info.mcpBridgeConnected,
                    agentTurns:    info.agentTurns,
                    agentMessages: info.agentMessages,
                    agentProblems: info.agentProblems,
                    activityEpoch: info.activityEpoch,
                    lastProblem:   info.lastProblem
                )
                sessions[tag] = info
            }
            // Re-request the list to pick up any new sessions.
            client.send(ClientSessionList())

        case .focusListResp(let list), .focusRegistryUpdated(let list):
            focuses = Dictionary(list.map { ($0.tag, $0) }, uniquingKeysWith: { _, last in last })
            // Per-focus PR pin dies with its focus (W8, D3): a tag no longer
            // in the registry can never be shown on screen again, so its
            // entry must not linger in perriCurrentPr forever.
            let liveTags = Set(focuses.keys)
            perriCurrentPr = perriCurrentPr.filter { liveTags.contains($0.key) }

        case .motherJobs(let jobs):
            motherJobs = jobs
            motherJobsReceived = true
            refreshNeedsYouMother(host: "", jobs: jobs)

        case .approvalPending(let tag, let count):
            refreshNeedsYouApprovals(host: "", tag: tag, count: count)

        case .gap(let topic, _, _, _, let reason):
            // A daemon restart came with the snapshots that replace the list: nothing to warn of.
            if reason.mayHaveMissedUpdates { missedUpdates.insert(topic) }

        case .hosts(let list):
            hostInfos = list
            hostRoster.apply(list)
            for host in list { hostEgress[host.name] = host.egress }

        case .motherPeek(let snap):
            if snap.todos.isEmpty {
                motherPeeks.removeValue(forKey: snap.jobId)
            } else {
                motherPeeks[snap.jobId] = snap
            }

        case .perriState(let tag, let queue, let current):
            perriQueue = queue   // fleet-wide, unchanged regardless of tag
            if let current {
                perriCurrentPr[tag] = current
            } else {
                perriCurrentPr.removeValue(forKey: tag)
            }

        case .fredState where cache != nil, .teriState where cache != nil:
            // Q2: mail, calendar and todos stay on the Mac in v1. Nothing from Fred or Teri is kept
            // over the backplane transport, whatever arrives.
            break

        case .fredState(let mailbox, let calendar):
            fredMailbox  = mailbox
            fredCalendar = calendar
            // Real data arriving means the daemon is no longer withholding it.
            withheldTopics.remove("fred")

        case .withheld(let topics, let reason):
            withheldTopics = Set(topics)
            withheldReasons = Dictionary(topics.map { ($0, reason) }, uniquingKeysWith: { _, last in last })

        case .teriState(let snap):
            teriTodos = snap
            withheldTopics.remove("teri")

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

        case .decisionRequest(let tag, let requestId, let prompt, let detail, let choices, let contextPaneId):
            // Drop a request whose id this client already has a resolution
            // for — a late `decision_request` replay following a
            // `decision_resolved` for the same id must never reconstruct an
            // armed prompt.
            guard decisionStore.resolution(for: requestId) == nil else { return }
            // Deduplicate by request id so a re-broadcast can't enqueue twice.
            guard !pendingDecisions.contains(where: { $0.requestId == requestId }) else { return }
            pendingDecisions.append(PendingDecision(
                tag: tag, requestId: requestId, prompt: prompt, detail: detail,
                choices: choices, contextPaneId: contextPaneId))

        case .decisionResolved(_, let requestId, let resolution, let choiceId):
            _ = decisionStore.claimAnswer(
                requestId: requestId,
                record: Self.decisionResolutionRecord(resolution: resolution, choiceId: choiceId)
            )
            pendingDecisions.removeAll { $0.requestId == requestId }

        default:
            break
        }
    }

    /// Maps a `decision_resolved` frame's raw `resolution`/`choice_id`
    /// strings to a `DecisionResolutionRecord`. `"answered"` with a
    /// `choiceId` is the only path to `.choice` — every other combination
    /// (including the defensive case of `"answered"` with no `choiceId`,
    /// which the daemon never actually sends) collapses to either
    /// `.dismissed` or `.resolvedElsewhere`, both of which reconstruct
    /// inert rather than armed.
    private static func decisionResolutionRecord(resolution: String, choiceId: String?) -> DecisionResolutionRecord {
        if resolution == "answered", let choiceId {
            return .choice(choiceId)
        }
        if resolution == "dismissed" {
            return .dismissed
        }
        return .resolvedElsewhere(resolution)
    }

    // MARK: - Perri actions

    /// Load a specific PR into the Perri current-PR view.
    ///
    /// The daemon writes `current-pr.json` directly (via
    /// `crate::data::perri_current_pr::write_pointer`) and the native source
    /// re-broadcasts a fresh `perri_state` snapshot.
    public func perriLoadPr(number: Int, repo: String) {
        client.send(ClientPerriAction(action: "load_pr", prNumber: number, repo: repo))
    }

    /// Clear the current PR from the Perri view.
    ///
    /// The daemon removes `current-pr.json` directly (via
    /// `crate::data::perri_current_pr::clear_pointer`) and the native source
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

    // MARK: - Decision actions

    /// Answer a decision request. The caller (the one presentation site,
    /// `NostromoApp.swift`) must call `decisionStore.claimAnswer(requestId:
    /// record:)` first and only invoke this method if that claim succeeds —
    /// that ordering is what makes a second, contradictory answer for the
    /// same request structurally impossible on this client, not merely
    /// caught downstream by the daemon's own `AlreadyAnswered` guard.
    ///
    /// Removes the request from `pendingDecisions` (unconditionally safe —
    /// a no-op if it's already gone) and sends `ClientDecisionAnswer` —
    /// `choiceId: nil` means dismissed without choosing, a distinct,
    /// meaningful outcome, not a default choice.
    public func answerDecision(requestId: String, choiceId: String?) {
        pendingDecisions.removeAll { $0.requestId == requestId }
        client.send(ClientDecisionAnswer(requestId: requestId, choiceId: choiceId))
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

    // MARK: - pr_diff: per-file scroll restore (ios-curated-view-parity W8)

    /// `pr_diff` can show different files at different times, and the
    /// single `scrollKeys[tag][paneId]` slot above can't tell one file's
    /// saved row from another's. Reuses that same private, non-published
    /// storage — no re-render per scroll tick here either — keyed by a
    /// composite `"paneId#file"` string only this pair of methods ever
    /// constructs, so it can never collide with a plain paneId used by any
    /// other content kind.
    public func setDiffFileScrollKey(tag: String, paneId: String, file: String, key: Int) {
        setScrollKey(tag: tag, paneId: "\(paneId)#\(file)", key: key)
    }

    public func diffFileScrollRestore(tag: String, paneId: String, file: String, visibleRange: ClosedRange<Int>?) -> ScrollRestore {
        scrollRestore(tag: tag, paneId: "\(paneId)#\(file)", visibleRange: visibleRange)
    }

    // MARK: - pr_diff: selected-file slot (ios-curated-view-parity W8, D2)

    /// Which file `pr_diff`'s `paneId` currently has open, scoped by
    /// `identity` (`"\(repo)#\(number)"`-shaped, built by `DiffSurfaceView`
    /// itself). Delegated through `focusRegionStates` — unlike the scroll
    /// keys above, this DOES need to be `@Published`: a manual file
    /// selection at regular width (no fresh anchor, no address change) must
    /// still re-render `DiffSurfaceView` so it reflects the new choice.
    /// Writes are rare (a tap, not a scroll tick), so the jank concern the
    /// scroll keys avoid doesn't apply here.
    public func selectedDiffFile(tag: String, paneId: String, identity: String) -> String? {
        focusRegionStates[tag]?.selectedFile(for: paneId, identity: identity)
    }

    public func setSelectedDiffFile(tag: String, paneId: String, path: String, identity: String) {
        var region = focusRegionStates[tag] ?? FocusRegionState()
        region.setSelectedFile(path, identity: identity, for: paneId)
        focusRegionStates[tag] = region
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
