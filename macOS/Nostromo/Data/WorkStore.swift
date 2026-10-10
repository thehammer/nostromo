import Foundation
import Combine

/// A targeted daemon answer to a `request_id`-keyed work request.
enum WorkResponse {
    case detail(WorkResult<WorkItemDetail>)
    case sendPreview(WorkResult<SendPreview>)
    case sendResult(WorkResult<SendOutcome>)
    /// No answer arrived within `requestTimeout`.
    case timedOut
    /// The request ended without an answer for a reason other than a timeout:
    /// its id was reused by a newer request (`superseded`) or the daemon
    /// connection went away (`connection_lost`).
    case failed(WorkError)
}

/// A source's items after filtering and grouping, plus the counts the filter
/// bar shows. Computed by `WorkStore.listSnapshot`.
struct WorkListSnapshot: Equatable {
    let groups: [WorkGroup]
    /// Items of the source before any filter.
    let totalCount: Int
    let filteredCount: Int
    /// Per requested facet: value → count, ignoring that facet's own filter.
    let facetCounts: [WorkFacet: [String: Int]]
}

/// In-memory home of the Teri work data pushed by the daemon: per-source
/// status, items (merged across groups), Teri's picks, and the continuations
/// of in-flight targeted requests.
///
/// Storage and request plumbing only. Queries, view state and rendering are
/// layered on top by later slices (`WorkQuery`, `TeriViewState`, the tab
/// views); `AppStore.handle(_:)` is the only writer in production. Views take
/// a `WorkStore` rather than reaching for `.shared`, so tests build their own.
final class WorkStore: ObservableObject {
    static let shared = WorkStore()

    /// Latest health of each source. Absent until the daemon reports it.
    @Published private(set) var statuses: [WorkSource: SourceStatus] = [:]
    /// Teri's latest published picks, once received.
    @Published private(set) var picks: PicksSnapshot?
    /// Bumped on every snapshot so views can re-query without diffing items.
    @Published private(set) var revision: Int = 0
    /// Whether the daemon connection is up. Views dim and say "Disconnected"
    /// while it is not, but keep the data they have.
    @Published private(set) var isConnected: Bool = true

    /// Sends a client frame to the daemon. Set by `TeriBindings`; nil in tests
    /// that do not look at outgoing frames.
    var sendFrame: ((WorkClientMessage) -> Void)?

    /// How long a request waits for its answer before resolving `.timedOut`.
    let requestTimeout: TimeInterval

    /// Items of each `(source, group)`; a snapshot fully replaces its group.
    private var groups: [GroupKey: [WorkItem]] = [:]
    private var pendingRequests: [String: PendingRequest] = [:]

    /// A waiting continuation. `token` tells a registration apart from a later
    /// one that reuses its id, so a stale timeout never resolves the newer waiter.
    private struct PendingRequest {
        let token = UUID()
        let completion: (WorkResponse) -> Void
    }

    private struct GroupKey: Hashable {
        let source: WorkSource
        let group: String?
    }

    init(requestTimeout: TimeInterval = 10) {
        self.requestTimeout = requestTimeout
    }

    // MARK: - Reads

    /// All items of `source`, merged across its groups (e.g. every repo's docs).
    func items(for source: WorkSource) -> [WorkItem] {
        groups.filter { $0.key.source == source }.values.flatMap { $0 }
    }

    /// Every item of every source.
    var allItems: [WorkItem] {
        groups.values.flatMap { $0 }
    }

    func status(for source: WorkSource) -> SourceStatus? {
        statuses[source]
    }

    /// Number of in-flight requests (diagnostics and tests).
    var pendingRequestCount: Int { pendingRequests.count }

    // MARK: - Derived lists

    /// Lists with more items than this are filtered off the main thread.
    static let backgroundThreshold = 300

    private static let derivationQueue = DispatchQueue(label: "nostromo.work.derive", qos: .userInitiated)

    /// `source`'s items filtered, sorted and grouped for display, with the counts
    /// the filter bar needs. Synchronous.
    func listSnapshot(source: WorkSource, filter: WorkFilter, sort: WorkSortKey,
                      facets: [WorkFacet]) -> WorkListSnapshot {
        Self.makeSnapshot(items: items(for: source), source: source, filter: filter, sort: sort, facets: facets)
    }

    /// Like `listSnapshot`, but a large source is derived on a background queue.
    /// `completion` always runs on the main thread (immediately for a small
    /// source). A caller that can be re-asked while one is in flight should
    /// ignore results that are no longer current.
    func computeListSnapshot(source: WorkSource, filter: WorkFilter, sort: WorkSortKey,
                             facets: [WorkFacet], completion: @escaping (WorkListSnapshot) -> Void) {
        let items = items(for: source)
        if items.count <= Self.backgroundThreshold {
            completion(Self.makeSnapshot(items: items, source: source, filter: filter, sort: sort, facets: facets))
            return
        }
        Self.derivationQueue.async {
            let snapshot = Self.makeSnapshot(items: items, source: source, filter: filter, sort: sort, facets: facets)
            DispatchQueue.main.async { completion(snapshot) }
        }
    }

    private static func makeSnapshot(items: [WorkItem], source: WorkSource, filter: WorkFilter,
                                     sort: WorkSortKey, facets: [WorkFacet]) -> WorkListSnapshot {
        var filter = filter
        filter.sources = []   // the source is the tab, not a user filter
        let matching = WorkQuery.filter(items, filter)
        var counts: [WorkFacet: [String: Int]] = [:]
        for facet in facets {
            counts[facet] = WorkQuery.facetCounts(items, filter: filter, facet: facet)
        }
        return WorkListSnapshot(
            groups: WorkQuery.group(matching, source: source, sort: sort),
            totalCount: items.count,
            filteredCount: matching.count,
            facetCounts: counts)
    }

    // MARK: - Daemon requests

    /// Ask the daemon for `itemId`'s detail; `completion` runs once with the
    /// answer, a timeout or a failure. Fails at once when there is no connection.
    func requestDetail(_ itemId: String, completion: @escaping (WorkResponse) -> Void) {
        guard isConnected, let sendFrame else {
            completion(.failed(WorkError(code: "not_connected", message: "Not connected to nostromd")))
            return
        }
        let requestId = UUID().uuidString
        expect(requestId: requestId, completion: completion)
        sendFrame(.detailRequest(requestId: requestId, itemId: itemId))
    }

    /// Ask the daemon to refresh `source` (all sources when nil). The daemon
    /// debounces, so asking often is harmless.
    func refresh(source: WorkSource?) {
        sendFrame?(.refresh(source: source, fred: false))
    }

    /// Ask the daemon to (re)generate Teri's picks.
    func refreshPicks(reason: String) {
        sendFrame?(.picksRefresh(reason: reason))
    }

    // MARK: - Daemon pushes

    func setConnected(_ connected: Bool) {
        if isConnected != connected { isConnected = connected }
    }

    func apply(status: SourceStatus) {
        statuses[status.source] = status
    }

    /// Replace one group's items. An empty `items` removes the group.
    func apply(snapshot source: WorkSource, group: String?, items: [WorkItem]) {
        let key = GroupKey(source: source, group: group)
        if items.isEmpty {
            groups.removeValue(forKey: key)
        } else {
            groups[key] = items
        }
        revision += 1
    }

    func apply(picks: PicksSnapshot) {
        self.picks = picks
    }

    /// Forget everything pushed over a connection that is gone: items, source
    /// statuses and picks. The next connection's daemon re-sends what it has,
    /// and an older daemon with no work data must not leave this one's behind.
    func reset() {
        groups.removeAll()
        statuses.removeAll()
        picks = nil
        revision += 1
    }

    // MARK: - Request continuations

    /// Register `completion` for `requestId`; it runs once, with the daemon's
    /// answer, `.timedOut`, or `.failed`. Call on the main thread.
    ///
    /// Reusing the id of a request still in flight fails the earlier waiter
    /// (`superseded`) rather than silently replacing it, and the new request
    /// gets its own full timeout.
    func expect(requestId: String, completion: @escaping (WorkResponse) -> Void) {
        let pending = PendingRequest(completion: completion)
        if let displaced = pendingRequests.updateValue(pending, forKey: requestId) {
            displaced.completion(.failed(WorkError(
                code: "superseded",
                message: "A newer request reused request id \(requestId)")))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + requestTimeout) { [weak self] in
            guard let self, self.pendingRequests[requestId]?.token == pending.token else { return }
            self.resolve(requestId: requestId, with: .timedOut)
        }
    }

    /// Fail every request still waiting (the daemon connection went away, so
    /// no answer will come). Late answers are then ignored by `resolve`.
    func failPendingRequests(reason: String) {
        let pending = pendingRequests
        pendingRequests.removeAll()
        for (_, request) in pending {
            request.completion(.failed(WorkError(code: "connection_lost", message: reason)))
        }
    }

    /// Complete the request `requestId`. A late or duplicate answer (already
    /// resolved or timed out) is ignored.
    func resolve(requestId: String, with response: WorkResponse) {
        guard let pending = pendingRequests.removeValue(forKey: requestId) else { return }
        pending.completion(response)
    }
}
