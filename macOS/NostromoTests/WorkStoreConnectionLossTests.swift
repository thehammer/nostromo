import XCTest

// What the work store does when the daemon connection goes away: requests in
// flight are failed (not left to time out against a daemon that will never
// answer them), and data from the dead connection is dropped so a reconnect to
// a different transport/daemon never shows stale Teri/Fred/work data.
//
// `failPendingRequests(reason:)` and `reset()` are the connection-loss API.

final class WorkStoreConnectionLossTests: XCTestCase {

    private func item(_ id: String, _ source: WorkSource = .repoDocs) -> WorkItem {
        let json = #"{"id":"\#(id)","source":"\#(source.rawValue)","kind":"doc","title":"t"}"#
        return try! JSONDecoder().decode(WorkItem.self, from: json.data(using: .utf8)!)
    }

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

    private func pumpMainQueue(for seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testFailingPendingRequestsAnswersEveryWaiterWithAnErrorThatCarriesTheReason() {
        let store = WorkStore()
        var answers: [String: WorkResponse] = [:]
        store.expect(requestId: "detail-1") { answers["detail-1"] = $0 }
        store.expect(requestId: "send-1") { answers["send-1"] = $0 }
        XCTAssertEqual(store.pendingRequestCount, 2)

        store.failPendingRequests(reason: "daemon connection lost")
        pumpMainQueue()

        XCTAssertEqual(Set(answers.keys), ["detail-1", "send-1"], "every in-flight request must be answered")
        for (id, response) in answers {
            XCTAssertFalse(isSuccess(response), "\(id) must not look successful")
            XCTAssertFalse(isTimeout(response), "\(id) must be told the connection was lost, not that it timed out")
            XCTAssertTrue(String(describing: response).contains("daemon connection lost"),
                          "\(id)'s error must carry the reason: \(response)")
        }
        XCTAssertEqual(store.pendingRequestCount, 0)
    }

    func testAnAnswerThatArrivesAfterTheRequestWasFailedIsIgnored() {
        let store = WorkStore()
        var calls = 0
        store.expect(requestId: "r1") { _ in calls += 1 }
        store.failPendingRequests(reason: "daemon connection lost")
        pumpMainQueue()

        let outcome = try! JSONDecoder().decode(SendOutcome.self, from: #"{"kind":"seeded"}"#.data(using: .utf8)!)
        store.resolve(requestId: "r1", with: .sendResult(.ok(outcome)))
        XCTAssertEqual(calls, 1)
    }

    func testFailingPendingRequestsWhenNothingIsPendingIsHarmless() {
        let store = WorkStore()
        store.failPendingRequests(reason: "daemon connection lost")
        XCTAssertEqual(store.pendingRequestCount, 0)
    }

    func testResetDropsEveryItemAndSourceStatusAndTellsViewsToRequery() {
        let store = WorkStore()
        store.apply(snapshot: .repoDocs, group: "a", items: [item("doc:a:1")])
        store.apply(snapshot: .jira, group: nil, items: [item("jira:X-1", .jira)])
        store.apply(status: SourceStatus(source: .jira, state: .fresh, count: 3))
        XCTAssertEqual(store.allItems.count, 2)
        let revisionBefore = store.revision

        store.reset()

        XCTAssertTrue(store.allItems.isEmpty, "items from the dead connection must not survive")
        XCTAssertTrue(store.items(for: .jira).isEmpty)
        XCTAssertNil(store.status(for: .jira), "source statuses from the dead connection must not survive")
        XCTAssertNotEqual(store.revision, revisionBefore, "views re-query on revision; reset must bump it")
    }

    func testAfterAResetTheStoreAcceptsFreshDataAsIfNew() {
        let store = WorkStore()
        store.apply(snapshot: .repoDocs, group: "a", items: [item("doc:a:1")])
        store.reset()
        store.apply(snapshot: .repoDocs, group: "a", items: [item("doc:a:9")])
        XCTAssertEqual(store.items(for: .repoDocs).map(\.id), ["doc:a:9"])
    }
}
