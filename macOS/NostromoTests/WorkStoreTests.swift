import XCTest
import Combine

final class WorkStoreTests: XCTestCase {

    private func item(_ id: String, _ source: WorkSource = .repoDocs) -> WorkItem {
        let json = #"{"id":"\#(id)","source":"\#(source.rawValue)","kind":"doc","title":"t"}"#
        return try! JSONDecoder().decode(WorkItem.self, from: json.data(using: .utf8)!)
    }

    func testItemsAreMergedAcrossGroupsOfOneSource() {
        let store = WorkStore()
        store.apply(snapshot: .repoDocs, group: "a", items: [item("doc:a:1")])
        store.apply(snapshot: .repoDocs, group: "b", items: [item("doc:b:1"), item("doc:b:2")])
        store.apply(snapshot: .jira, group: nil, items: [item("jira:X-1", .jira)])
        XCTAssertEqual(Set(store.items(for: .repoDocs).map(\.id)), ["doc:a:1", "doc:b:1", "doc:b:2"])
        XCTAssertEqual(store.items(for: .jira).map(\.id), ["jira:X-1"])
        XCTAssertEqual(store.allItems.count, 4)
    }

    func testASnapshotReplacesItsGroupAndEmptyRemovesIt() {
        let store = WorkStore()
        store.apply(snapshot: .repoDocs, group: "a", items: [item("doc:a:1"), item("doc:a:2")])
        store.apply(snapshot: .repoDocs, group: "a", items: [item("doc:a:3")])
        XCTAssertEqual(store.items(for: .repoDocs).map(\.id), ["doc:a:3"])
        store.apply(snapshot: .repoDocs, group: "a", items: [])
        XCTAssertTrue(store.items(for: .repoDocs).isEmpty)
    }

    func testStatusAndPicksAreStored() {
        let store = WorkStore()
        XCTAssertNil(store.status(for: .jira))
        store.apply(status: SourceStatus(source: .jira, state: .fresh, count: 3))
        XCTAssertEqual(store.status(for: .jira)?.count, 3)
        XCTAssertNil(store.picks)
        store.apply(picks: PicksSnapshot(generating: true))
        XCTAssertEqual(store.picks?.generating, true)
    }

    func testAResponseRunsItsContinuationExactlyOnce() {
        let store = WorkStore()
        var calls = 0
        store.expect(requestId: "r1") { response in
            calls += 1
            guard case .sendResult(.ok(let o)) = response else { return XCTFail("wrong response") }
            XCTAssertEqual(o.kind, "seeded")
        }
        let outcome = try! JSONDecoder().decode(SendOutcome.self, from: #"{"kind":"seeded"}"#.data(using: .utf8)!)
        store.resolve(requestId: "r1", with: .sendResult(.ok(outcome)))
        store.resolve(requestId: "r1", with: .sendResult(.ok(outcome)))   // duplicate: ignored
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(store.pendingRequestCount, 0)
    }

    func testAnUnansweredRequestTimesOut() {
        let store = WorkStore(requestTimeout: 0.05)
        let done = expectation(description: "timed out")
        store.expect(requestId: "r1") { response in
            if case .timedOut = response { done.fulfill() }
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(store.pendingRequestCount, 0)
    }

    func testALateAnswerAfterTimeoutIsIgnored() {
        let store = WorkStore(requestTimeout: 0.05)
        var calls = 0
        let done = expectation(description: "timed out")
        store.expect(requestId: "r1") { _ in calls += 1; done.fulfill() }
        wait(for: [done], timeout: 2)
        let outcome = try! JSONDecoder().decode(SendOutcome.self, from: #"{"kind":"seeded"}"#.data(using: .utf8)!)
        store.resolve(requestId: "r1", with: .sendResult(.ok(outcome)))
        XCTAssertEqual(calls, 1)
    }

    // MARK: - A request id is never silently taken over

    private func isSuccess(_ response: WorkResponse) -> Bool {
        switch response {
        case .detail(.ok), .sendPreview(.ok), .sendResult(.ok): return true
        default: return false
        }
    }

    private func isTimeout(_ response: WorkResponse) -> Bool {
        if case .timedOut = response { return true }
        return false
    }

    /// Let any continuation the store scheduled on the main queue run.
    private func pumpMainQueue(for seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testRegisteringARequestIdThatIsAlreadyPendingFailsTheFirstWaiterInsteadOfReplacingItSilently() {
        let store = WorkStore()
        var first: [WorkResponse] = []
        var second: [WorkResponse] = []
        store.expect(requestId: "r1") { first.append($0) }
        store.expect(requestId: "r1") { second.append($0) }
        pumpMainQueue()

        XCTAssertEqual(first.count, 1, "the displaced waiter must be told, not left hanging until its timeout")
        if let response = first.first {
            XCTAssertFalse(isSuccess(response), "the displaced waiter must get an error, not a result")
            XCTAssertFalse(isTimeout(response), "the displaced waiter must get a clear error, not a timeout")
        }
        XCTAssertTrue(second.isEmpty, "the new waiter is still waiting for the daemon's answer")
        XCTAssertEqual(store.pendingRequestCount, 1)

        // The daemon's answer goes to the new waiter, once, and never to the first again.
        let outcome = try! JSONDecoder().decode(SendOutcome.self, from: #"{"kind":"seeded"}"#.data(using: .utf8)!)
        store.resolve(requestId: "r1", with: .sendResult(.ok(outcome)))
        XCTAssertEqual(second.count, 1)
        XCTAssertTrue(second.first.map(isSuccess) ?? false)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(store.pendingRequestCount, 0)
    }

    func testTheDisplacedWaitersTimeoutDoesNotCutTheNewWaitersWaitShort() throws {
        // Timing-based, so it measures REAL elapsed time instead of trusting that a run-loop pump
        // returns on schedule (under the load of the full suite a "0.25 s" pump can take much
        // longer, and then the second waiter's own timer legitimately fires).
        let timeout: TimeInterval = 0.6
        let store = WorkStore(requestTimeout: timeout)
        var second: [WorkResponse] = []
        store.expect(requestId: "r1") { _ in }
        let firstRegisteredAt = Date()
        pumpMainQueue(for: 0.3)
        store.expect(requestId: "r1") { second.append($0) }
        let secondRegisteredAt = Date()

        // Pump in small slices until the FIRST timer has certainly fired (it was armed at
        // firstRegisteredAt) while the SECOND one (armed at secondRegisteredAt) has not.
        while Date().timeIntervalSince(firstRegisteredAt) < timeout + 0.1 {
            pumpMainQueue(for: 0.02)
        }
        try XCTSkipIf(Date().timeIntervalSince(secondRegisteredAt) >= timeout - 0.05,
                      "the machine was too loaded to hold the window between the two timers")

        XCTAssertTrue(second.isEmpty,
                      "the first registration's timeout resolved the second waiter early: \(second)")
        XCTAssertEqual(store.pendingRequestCount, 1)

        let outcome = try! JSONDecoder().decode(SendOutcome.self, from: #"{"kind":"seeded"}"#.data(using: .utf8)!)
        store.resolve(requestId: "r1", with: .sendResult(.ok(outcome)))
        XCTAssertEqual(second.count, 1)
    }

    // MARK: - Connection flag (T0)

    func testTheStoreStartsConnectedAndTogglesWithSetConnected() {
        let store = WorkStore()
        XCTAssertTrue(store.isConnected)
        var seen: [Bool] = []
        let sub = store.$isConnected.sink { seen.append($0) }
        store.setConnected(false)
        XCTAssertFalse(store.isConnected)
        store.setConnected(true)
        XCTAssertTrue(store.isConnected)
        XCTAssertEqual(seen, [true, false, true], "views can observe the change")
        sub.cancel()
    }

    // MARK: - Detail requests (T0)

    private func detail(_ id: String, _ title: String) -> WorkItemDetail {
        WorkTestSupport.makeDetail(itemId: id, title: title, markdown: "body of \(title)")
    }

    private func requestId(of frame: WorkClientMessage) -> String? {
        guard case .detailRequest(let rid, _) = frame else { return nil }
        return rid
    }

    func testRequestDetailSendsADetailRequestFrameAndResolvesWithTheAnswer() throws {
        let store = WorkStore()
        var sent: [WorkClientMessage] = []
        store.sendFrame = { sent.append($0) }
        var responses: [WorkResponse] = []

        store.requestDetail("todo:7") { responses.append($0) }

        XCTAssertEqual(sent.count, 1)
        guard case .detailRequest(let rid, let itemId) = sent[0] else { return XCTFail("sent \(sent)") }
        XCTAssertEqual(itemId, "todo:7")
        XCTAssertFalse(rid.isEmpty)
        // On the wire it is a work_detail_request carrying item_id.
        let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sent[0])) as? [String: Any]
        XCTAssertEqual(wire?["type"] as? String, "work_detail_request")
        XCTAssertEqual(wire?["item_id"] as? String, "todo:7")
        XCTAssertEqual(wire?["request_id"] as? String, rid)
        XCTAssertTrue(responses.isEmpty, "nothing resolved yet")
        XCTAssertEqual(store.pendingRequestCount, 1)

        store.resolve(requestId: rid, with: .detail(.ok(detail("todo:7", "Seven"))))

        XCTAssertEqual(responses.count, 1)
        guard case .detail(.ok(let d)) = responses[0] else { return XCTFail("got \(responses)") }
        XCTAssertEqual(d.title, "Seven")
        XCTAssertEqual(store.pendingRequestCount, 0)
    }

    func testEveryDetailRequestGetsItsOwnRequestId() {
        let store = WorkStore()
        var sent: [WorkClientMessage] = []
        store.sendFrame = { sent.append($0) }
        store.requestDetail("todo:1") { _ in }
        store.requestDetail("todo:2") { _ in }
        let ids = sent.compactMap(requestId(of:))
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(Set(ids).count, 2, "two in-flight requests must not share an id (the second would supersede the first)")
        XCTAssertEqual(store.pendingRequestCount, 2)
    }

    func testRequestDetailWithNoConnectionFailsInsteadOfWaitingForATimeout() {
        let store = WorkStore()
        XCTAssertNil(store.sendFrame)
        let done = expectation(description: "completed")
        var response: WorkResponse?
        store.requestDetail("todo:1") { r in response = r; done.fulfill() }
        wait(for: [done], timeout: 2)

        guard case .failed(let err)? = response else { return XCTFail("got \(String(describing: response))") }
        XCTAssertEqual(err.code, "not_connected")
        XCTAssertEqual(store.pendingRequestCount, 0, "nothing is left waiting")
    }

    // MARK: - Refresh (T0)

    func testRefreshSendsAWorkRefreshFrameForOneSourceOrAll() {
        let store = WorkStore()
        var sent: [WorkClientMessage] = []
        store.sendFrame = { sent.append($0) }

        store.refresh(source: .jira)
        store.refresh(source: nil)

        XCTAssertEqual(sent, [.refresh(source: .jira, fred: false), .refresh(source: nil, fred: false)])
    }

    func testRefreshWithNoConnectionIsANoOpNotACrash() {
        let store = WorkStore()
        store.refresh(source: .todos)   // no sendFrame: must simply do nothing
        XCTAssertEqual(store.pendingRequestCount, 0)
    }

    // MARK: - listSnapshot (T0)

    private func seededTodosStore() -> WorkStore {
        let store = WorkStore()
        store.apply(snapshot: .todos, group: nil, items: [
            WorkTestSupport.todo(1, "Write report", status: "open", priority: 3, due: "2026-10-12"),
            WorkTestSupport.todo(2, "Fix webhook", status: "in_progress", priority: 1, due: "2026-10-11"),
            WorkTestSupport.todo(3, "Book travel", status: "open", priority: 1),
            WorkTestSupport.todo(4, "Audit access", status: "blocked", priority: 1),
            WorkTestSupport.todo(5, "Call plumber", status: "open", priority: 3, due: "2026-10-09"),
        ])
        // Items of other sources must never leak into a todos snapshot.
        store.apply(snapshot: .jira, group: nil, items: [
            WorkTestSupport.makeItem(["id": "jira:X-1", "source": "jira", "kind": "task", "title": "Jira thing",
                                      "status": "open"]),
        ])
        return store
    }

    private func ids(_ groups: [WorkGroup]) -> [[String]] { groups.map { $0.items.map(\.id) } }

    func testListSnapshotOrdersTodosByPriorityThenDueDateNoneLastThenTitle() {
        let snap = seededTodosStore().listSnapshot(source: .todos, filter: WorkFilter(), sort: .newest, facets: [])

        XCTAssertEqual(snap.groups.count, 1)
        XCTAssertNil(snap.groups.first?.key)
        XCTAssertEqual(ids(snap.groups), [["todo:2", "todo:4", "todo:3", "todo:5", "todo:1"]])
        XCTAssertEqual(snap.totalCount, 5, "only the requested source counts")
        XCTAssertEqual(snap.filteredCount, 5)
        XCTAssertTrue(snap.facetCounts.isEmpty, "facets were not requested")
    }

    func testListSnapshotCountsBeforeAndAfterFiltering() {
        var f = WorkFilter()
        f.statuses = ["open"]
        let snap = seededTodosStore().listSnapshot(source: .todos, filter: f, sort: .newest, facets: [])

        XCTAssertEqual(snap.totalCount, 5, "total is the source's size before any filter")
        XCTAssertEqual(snap.filteredCount, 3)
        XCTAssertEqual(ids(snap.groups), [["todo:3", "todo:5", "todo:1"]])
    }

    func testListSnapshotFacetCountsIgnoreTheFacetsOwnFilter() {
        var f = WorkFilter()
        f.statuses = ["open"]
        let snap = seededTodosStore().listSnapshot(source: .todos, filter: f, sort: .newest, facets: [.status, .kind])

        XCTAssertEqual(snap.facetCounts[.status], ["open": 3, "in_progress": 1, "blocked": 1])
        XCTAssertEqual(snap.facetCounts[.kind], ["todo": 3], "other facets honour the status filter")
        XCTAssertNil(snap.facetCounts[.repo], "only requested facets are computed")
    }

    func testListSnapshotAppliesTheSearchQueryToTitleAndBody() {
        let store = WorkStore()
        store.apply(snapshot: .todos, group: nil, items: [
            WorkTestSupport.todo(1, "Fix webhook", searchText: "Fix webhook\nCheck the retry backoff"),
            WorkTestSupport.todo(2, "Book travel"),
        ])
        var f = WorkFilter()
        f.query = "backoff"
        let snap = store.listSnapshot(source: .todos, filter: f, sort: .newest, facets: [])
        XCTAssertEqual(ids(snap.groups), [["todo:1"]])
        XCTAssertEqual(snap.filteredCount, 1)
        XCTAssertEqual(snap.totalCount, 2)
    }

    func testListSnapshotForASourceWithNoItemsHasNoGroups() {
        let snap = WorkStore().listSnapshot(source: .sentry, filter: WorkFilter(), sort: .newest, facets: [.status])
        XCTAssertTrue(snap.groups.isEmpty)
        XCTAssertEqual(snap.totalCount, 0)
        XCTAssertEqual(snap.filteredCount, 0)
    }

    func testListSnapshotGroupsRepoDocsAcrossTheirPerRepoSnapshots() {
        let store = WorkStore()
        func doc(_ repo: String, _ n: Int, _ created: String) -> WorkItem {
            WorkTestSupport.makeItem(["id": "doc:\(repo):\(n)", "source": "repo_docs", "kind": "bug", "repo": repo,
                                      "title": "\(repo) doc \(n)", "created_at": created])
        }
        store.apply(snapshot: .repoDocs, group: "small", items: [doc("small", 1, "2026-10-01T00:00:00Z")])
        store.apply(snapshot: .repoDocs, group: "big", items: [
            doc("big", 1, "2026-10-01T00:00:00Z"), doc("big", 2, "2026-10-05T00:00:00Z"),
        ])

        let newest = store.listSnapshot(source: .repoDocs, filter: WorkFilter(), sort: .newest, facets: [])
        XCTAssertEqual(newest.groups.map(\.key), ["big", "small"], "bigger group first")
        XCTAssertEqual(ids(newest.groups), [["doc:big:2", "doc:big:1"], ["doc:small:1"]])

        let oldest = store.listSnapshot(source: .repoDocs, filter: WorkFilter(), sort: .oldest, facets: [])
        XCTAssertEqual(ids(oldest.groups).first, ["doc:big:1", "doc:big:2"])
        XCTAssertEqual(oldest.totalCount, 3)
    }
}
