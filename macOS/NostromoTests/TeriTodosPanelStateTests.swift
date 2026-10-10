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

    // MARK: - Wiring (source-as-text)
    //
    // `TeriBindings.swift` imports AppKit/SwiftUI and the `AppStore` singleton,
    // so it isn't compiled into the host-less NostromoTests bundle. As in
    // TeriFredWiringTests, pin the wiring by reading the source: the pure
    // decision above is worthless if the view doesn't render from it.

    func testPanelRendersFromTheResolvedStateOfTheStoresSnapshot() throws {
        let source = try Self.codeOnly("UI/Views/TeriBindings.swift")
        XCTAssertNotNil(
            source.range(of: #"TeriTodosPanelState\s*\.resolve\(\s*(self\.)?store\.teriTodos\s*\)"#,
                         options: .regularExpression),
            "TeriTodosPanel must derive its state via TeriTodosPanelState.resolve(store.teriTodos)")
        XCTAssertNotNil(
            source.range(of: #"switch\s+[^{]*(state|TeriTodosPanelState\s*\.resolve)[^{]*\{"#,
                         options: .regularExpression),
            "TeriTodosPanel must switch over the resolved state")
        for label in ["loading", "error", "notConfigured", "empty", "list"] {
            XCTAssertNotNil(
                source.range(of: #"case\s+\."# + label + #"\b"#, options: .regularExpression),
                "the panel must render a branch for .\(label)")
        }
    }

    func testPanelShowsLoadingForTheLoadingStateAndNoTodosOnlyForTheEmptyState() throws {
        let source = try Self.codeOnly("UI/Views/TeriBindings.swift")

        XCTAssertTrue(source.contains("Loading"), "the loading state must say it is loading")
        XCTAssertEqual(try Self.caseLabel(preceding: "Loading", in: source), "loading",
                       "\"Loading\" must be rendered by the .loading branch")

        // A nil snapshot must never read as "No Todos": that text may only
        // appear under the .empty branch.
        var searchFrom = source.startIndex
        while let hit = source.range(of: "No Todos", range: searchFrom..<source.endIndex) {
            XCTAssertEqual(try Self.caseLabel(preceding: hit, in: source), "empty",
                           "\"No Todos\" may only be rendered by the .empty branch")
            searchFrom = hit.upperBound
        }
    }

    // MARK: - Source helpers

    /// The `case .<label>` nearest before `needle`'s first occurrence.
    private static func caseLabel(preceding needle: String, in source: String) throws -> String? {
        let hit = try XCTUnwrap(source.range(of: needle), "\"\(needle)\" not found in source")
        return try caseLabel(preceding: hit, in: source)
    }

    private static func caseLabel(preceding hit: Range<String.Index>, in source: String) throws -> String? {
        let before = String(source[source.startIndex..<hit.lowerBound])
        let regex = try NSRegularExpression(pattern: #"case\s+\.(\w+)"#)
        let matches = regex.matches(in: before, range: NSRange(before.startIndex..., in: before))
        guard let last = matches.last, let r = Range(last.range(at: 1), in: before) else { return nil }
        return String(before[r])
    }

    /// Source with `//` line comments removed, so prose in comments can't
    /// satisfy (or trip) the assertions.
    private static func codeOnly(_ relative: String) throws -> String {
        try source(relative)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let r = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<r.lowerBound])
            }
            .joined(separator: "\n")
    }

    private static func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)   // …/macOS/NostromoTests/TeriTodosPanelStateTests.swift
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Nostromo")
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }
}
