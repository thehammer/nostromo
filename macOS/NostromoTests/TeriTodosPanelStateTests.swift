import XCTest

// What the Teri todos panel should show for each situation the daemon can put
// it in. Previously "no snapshot yet", "the fetch failed", "Teri isn't set up"
// and "genuinely nothing to do" all rendered as the same "No Todos" empty
// state; the user could not tell a healthy empty list from a broken one.
final class TeriTodosPanelStateTests: XCTestCase {

    // MARK: - Helpers

    /// `TeriTodosSnapshot` only has a Decoder init, so build it the way the
    /// app does: from the daemon's JSON.
    private func snapshot(
        items: Int = 0,
        stale: Bool? = nil,
        error: String? = nil,
        notConfigured: Bool? = nil
    ) throws -> TeriTodosSnapshot {
        var fields: [String] = [#""generated_at": "2026-10-10T12:00:00Z""#]
        let todos = (0..<items).map { i in
            #"{"id": \#(i + 1), "title": "Todo \#(i)", "status": "open", "priority": 3, "due_date": null, "jira_key": null}"#
        }
        fields.append(#""items": [\#(todos.joined(separator: ","))]"#)
        if let stale { fields.append(#""stale": \#(stale)"#) }
        if let error {
            let data = try JSONEncoder().encode(error)   // JSON-escaped string literal
            fields.append(#""error": \#(String(decoding: data, as: UTF8.self))"#)
        }
        if let notConfigured { fields.append(#""not_configured": \#(notConfigured)"#) }
        let json = "{" + fields.joined(separator: ",") + "}"
        return try JSONDecoder().decode(TeriTodosSnapshot.self, from: Data(json.utf8))
    }

    // MARK: - Wire decoding

    func testNotConfiguredDecodesFromTheDaemonFlag() throws {
        XCTAssertTrue(try snapshot(notConfigured: true).notConfigured)
        XCTAssertFalse(try snapshot(notConfigured: false).notConfigured)
    }

    func testNotConfiguredDefaultsToFalseWhenAnOlderDaemonOmitsIt() throws {
        let snap = try snapshot()   // no `not_configured` key at all
        XCTAssertFalse(snap.notConfigured)
    }

    // MARK: - resolve(_:)

    func testNoSnapshotYetIsLoadingNotEmpty() {
        XCTAssertEqual(TeriTodosPanelState.resolve(nil), .loading)
    }

    func testHealthyEmptySnapshotIsTheEmptyState() throws {
        XCTAssertEqual(TeriTodosPanelState.resolve(try snapshot()), .empty)
    }

    func testEmptySnapshotWithAnErrorShowsTheErrorNeverEmpty() throws {
        let snap = try snapshot(error: "Teri CLI exited with status 1")
        XCTAssertEqual(TeriTodosPanelState.resolve(snap), .error("Teri CLI exited with status 1"))
    }

    func testEmptySnapshotFromAnUnconfiguredTeriIsNotConfiguredNotEmpty() throws {
        let snap = try snapshot(notConfigured: true)
        XCTAssertEqual(TeriTodosPanelState.resolve(snap), .notConfigured)
    }

    func testErrorWinsOverNotConfiguredWhenBothAreSetAndThereAreNoItems() throws {
        let snap = try snapshot(error: "boom", notConfigured: true)
        XCTAssertEqual(TeriTodosPanelState.resolve(snap), .error("boom"))
    }

    func testItemsAreShownAsAListWithNoMarkersWhenFresh() throws {
        let snap = try snapshot(items: 2, stale: false)
        XCTAssertEqual(TeriTodosPanelState.resolve(snap), .list(stale: false, error: nil))
    }

    func testItemsWinOverAnErrorAndCarryTheErrorAlongAsABanner() throws {
        let snap = try snapshot(items: 1, error: "refresh failed")
        XCTAssertEqual(TeriTodosPanelState.resolve(snap), .list(stale: false, error: "refresh failed"))
    }

    func testStaleItemsKeepTheStaleMarker() throws {
        let snap = try snapshot(items: 3, stale: true)
        XCTAssertEqual(TeriTodosPanelState.resolve(snap), .list(stale: true, error: nil))
    }

    func testItemsWinOverNotConfigured() throws {
        let snap = try snapshot(items: 1, notConfigured: true)
        XCTAssertEqual(TeriTodosPanelState.resolve(snap), .list(stale: false, error: nil))
    }

    func testStaleSnapshotWithNoItemsAndNoErrorIsStillEmptyNotAList() throws {
        let snap = try snapshot(items: 0, stale: true)
        XCTAssertEqual(TeriTodosPanelState.resolve(snap), .empty)
    }

    func testStaleEmptySnapshotWithAnErrorIsTheErrorState() throws {
        let snap = try snapshot(items: 0, stale: true, error: "offline")
        XCTAssertEqual(TeriTodosPanelState.resolve(snap), .error("offline"))
    }
}
