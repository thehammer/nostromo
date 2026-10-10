import XCTest

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

    func testTheDisplacedWaitersTimeoutDoesNotCutTheNewWaitersWaitShort() {
        let store = WorkStore(requestTimeout: 0.4)
        var second: [WorkResponse] = []
        store.expect(requestId: "r1") { _ in }
        pumpMainQueue(for: 0.25)                       // t = 0.25 s
        store.expect(requestId: "r1") { second.append($0) }
        pumpMainQueue(for: 0.3)                        // t = 0.55 s: the first timer (0.4 s) has fired

        XCTAssertTrue(second.isEmpty,
                      "the first registration's timeout resolved the second waiter early: \(second)")
        XCTAssertEqual(store.pendingRequestCount, 1)

        let outcome = try! JSONDecoder().decode(SendOutcome.self, from: #"{"kind":"seeded"}"#.data(using: .utf8)!)
        store.resolve(requestId: "r1", with: .sendResult(.ok(outcome)))
        XCTAssertEqual(second.count, 1)
    }
}
