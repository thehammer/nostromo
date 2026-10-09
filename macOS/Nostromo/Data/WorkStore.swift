import Foundation
import Combine

/// A targeted daemon answer to a `request_id`-keyed work request.
enum WorkResponse {
    case detail(WorkResult<WorkItemDetail>)
    case sendPreview(WorkResult<SendPreview>)
    case sendResult(WorkResult<SendOutcome>)
    /// No answer arrived within `requestTimeout`.
    case timedOut
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

    /// How long a request waits for its answer before resolving `.timedOut`.
    let requestTimeout: TimeInterval

    /// Items of each `(source, group)`; a snapshot fully replaces its group.
    private var groups: [GroupKey: [WorkItem]] = [:]
    private var pendingRequests: [String: (WorkResponse) -> Void] = [:]

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

    // MARK: - Daemon pushes

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

    // MARK: - Request continuations

    /// Register `completion` for `requestId`; it runs once, with the daemon's
    /// answer or `.timedOut`. Call on the main thread.
    func expect(requestId: String, completion: @escaping (WorkResponse) -> Void) {
        pendingRequests[requestId] = completion
        DispatchQueue.main.asyncAfter(deadline: .now() + requestTimeout) { [weak self] in
            self?.resolve(requestId: requestId, with: .timedOut)
        }
    }

    /// Complete the request `requestId`. A late or duplicate answer (already
    /// resolved or timed out) is ignored.
    func resolve(requestId: String, with response: WorkResponse) {
        guard let completion = pendingRequests.removeValue(forKey: requestId) else { return }
        completion(response)
    }
}
