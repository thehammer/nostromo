import XCTest

// Filter / group / facet-count semantics of the Teri work list (design
// contract §5). The Mac and the daemon's MCP tool implement the same rules; both
// are checked against ONE fixture, `tests/fixtures/work_query_cases.json`
// (Rust side: `tests/work_query.rs`). The fixture path is derived from #filePath,
// so no bundle resources are involved.

// MARK: - Shared builders (used by every Teri/Work test in this target)

enum WorkTestSupport {
    private static let client = NostromodClient(socketPath: "/dev/null")

    /// Decode work items exactly the way the app does: as the `items` of a
    /// `work_snapshot` frame, so dates go through the app's own date strategy
    /// (RFC 3339 with and without fractional seconds).
    static func decodeItems(_ rawItems: [Any]) throws -> [WorkItem] {
        let frame: [String: Any] = ["type": "work_snapshot", "source": "todos", "items": rawItems]
        let raw = try JSONSerialization.data(withJSONObject: frame)
        let obj = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        let msg = client.decode(type_: "work_snapshot", json: obj, raw: raw)
        guard case .workSnapshot(_, _, let items) = msg else {
            throw NSError(domain: "WorkTestSupport", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "items did not decode: \(msg)"])
        }
        return items
    }

    /// One item from wire fields.
    static func makeItem(_ fields: [String: Any]) -> WorkItem {
        try! decodeItems([fields])[0]
    }

    /// A todo as the daemon would send it.
    static func todo(_ n: Int, _ title: String, status: String = "open", priority: Int? = 3,
                     due: String? = nil, createdAt: String? = nil, updatedAt: String? = nil,
                     linked: [String] = [], searchText: String? = nil) -> WorkItem {
        var f: [String: Any] = [
            "id": "todo:\(n)", "source": "todos", "kind": "todo", "title": title,
            "status": status, "search_text": searchText ?? title,
        ]
        if let priority { f["priority"] = ["label": "P\(priority)", "rank": priority] }
        if let due { f["due"] = due }
        if let createdAt { f["created_at"] = createdAt }
        if let updatedAt { f["updated_at"] = updatedAt }
        if !linked.isEmpty { f["linked"] = linked }
        return makeItem(f)
    }

    static func makeDetail(itemId: String, title: String, markdown: String = "") -> WorkItemDetail {
        let json: [String: Any] = ["item_id": itemId, "title": title, "markdown": markdown,
                                   "fields": [["Priority", "P1"]]]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(WorkItemDetail.self, from: data)
    }

    // MARK: fixture

    static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // NostromoTests
            .deletingLastPathComponent()   // macOS
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("tests/fixtures/work_query_cases.json")
    }

    static func loadFixtureObject() throws -> [String: Any] {
        let data = try Data(contentsOf: fixtureURL)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}

// MARK: - Tests

final class WorkQueryTests: XCTestCase {

    private func decodeFilter(_ obj: Any?) throws -> WorkFilter {
        let data = try JSONSerialization.data(withJSONObject: obj ?? [String: Any]())
        return try JSONDecoder().decode(WorkFilter.self, from: data)
    }

    private func ids(_ items: [WorkItem]) -> [String] { items.map(\.id) }

    // MARK: Shared fixture

    func testTheSharedFixtureCoversEveryOperationWithEnoughCases() throws {
        let fixture = try WorkTestSupport.loadFixtureObject()
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 12)
        let ops = Set(cases.compactMap { $0["op"] as? String })
        XCTAssertTrue(ops.isSuperset(of: ["filter", "group", "facet_counts"]), "ops used: \(ops)")
        XCTAssertFalse((fixture["items"] as? [Any] ?? []).isEmpty)
    }

    func testEveryCaseInTheSharedFixtureGivesTheExpectedResult() throws {
        let fixture = try WorkTestSupport.loadFixtureObject()
        let items = try WorkTestSupport.decodeItems(try XCTUnwrap(fixture["items"] as? [Any]))
        XCTAssertEqual(items.count, (fixture["items"] as? [Any])?.count, "every fixture item decodes")
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])

        for c in cases {
            let name = c["name"] as? String ?? "?"
            let op = c["op"] as? String ?? "?"
            let filter = try decodeFilter(c["filter"])
            XCTContext.runActivity(named: "[\(op)] \(name)") { _ -> Void in
                switch op {
                case "filter":
                    let want = c["expected_ids"] as? [String] ?? []
                    XCTAssertEqual(ids(WorkQuery.filter(items, filter)), want, name)

                case "group":
                    guard let source = (c["source"] as? String).flatMap(WorkSource.init(rawValue:)) else {
                        return XCTFail("group case without a valid source: \(name)")
                    }
                    let sort = (c["sort"] as? String).flatMap(WorkSortKey.init(rawValue:)) ?? .newest
                    let groups = WorkQuery.group(WorkQuery.filter(items, filter), source: source, sort: sort)
                    let got = groups.map { GroupShape(key: $0.key, ids: ids($0.items)) }
                    let want = (c["expected_groups"] as? [[String: Any]] ?? []).map {
                        GroupShape(key: $0["key"] as? String, ids: $0["ids"] as? [String] ?? [])
                    }
                    XCTAssertEqual(got, want, name)

                case "facet_counts":
                    guard let facet = (c["facet"] as? String).flatMap(WorkFacet.init(rawValue:)) else {
                        return XCTFail("facet case without a valid facet: \(name)")
                    }
                    let want = (c["expected_counts"] as? [String: Int]) ?? [:]
                    XCTAssertEqual(WorkQuery.facetCounts(items, filter: filter, facet: facet), want, name)

                default:
                    XCTFail("unknown op \(op) in case \(name)")
                }
            }
        }
    }

    private struct GroupShape: Equatable {
        let key: String?
        let ids: [String]
    }

    // MARK: Filter wire format

    func testAFilterDecodesFromAnyMixOfOptionalKeys() throws {
        XCTAssertEqual(try decodeFilter([String: Any]()), WorkFilter())
        let f = try decodeFilter(["sources": ["jira"], "has_severity": true, "query": "x", "unknown_future_key": 1])
        XCTAssertEqual(f.sources, [.jira])
        XCTAssertEqual(f.hasSeverity, true)
        XCTAssertEqual(f.query, "x")
        XCTAssertEqual(f.kinds, [])
    }

    func testAFilterRoundTripsThroughJSONWithTheWireKeyForSeverity() throws {
        var f = WorkFilter()
        f.sources = [.repoDocs]
        f.repos = ["alpha"]
        f.hasSeverity = false
        f.query = "café"
        let data = try JSONEncoder().encode(f)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["has_severity"] as? Bool, false, "encoded with the snake_case key")
        XCTAssertEqual(try JSONDecoder().decode(WorkFilter.self, from: data), f)
    }

    func testSortAndFacetNamesAreTheWireNames() {
        XCTAssertEqual([WorkSortKey.newest, .oldest, .title].map(\.rawValue), ["newest", "oldest", "title"])
        XCTAssertEqual(WorkFacet(rawValue: "environment"), .environment)
        XCTAssertEqual(WorkSortKey(rawValue: "newest"), .newest)
    }

    // MARK: Search ergonomics beyond the shared fixture

    func testFilteringNeverChangesInputOrderOrDropsItemsForAnEmptyFilter() throws {
        let items = [WorkTestSupport.todo(3, "C"), WorkTestSupport.todo(1, "A"), WorkTestSupport.todo(2, "B")]
        XCTAssertEqual(ids(WorkQuery.filter(items, WorkFilter())), ["todo:3", "todo:1", "todo:2"])
    }

    func testTheTitleIsSearchedEvenWhenSearchTextIsEmpty() {
        let item = WorkTestSupport.todo(1, "Renew passport", searchText: "")
        var f = WorkFilter()
        f.query = "passport"
        XCTAssertEqual(ids(WorkQuery.filter([item], f)), ["todo:1"])
    }

    // MARK: Per-keystroke cost (acceptance: <= 100 ms over 1,000 items of ~8 KiB each)

    private struct LCG {
        var s: UInt64
        mutating func next() -> Int {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Int(s >> 33)
        }
    }

    private func makeBigCorpus() throws -> (items: [WorkItem], vocab: [String]) {
        var rng = LCG(s: 42)
        let letters = Array("abcdefghijklmnopqrstuvwxy")   // no "z": the unique marker below is the only "zz…" text
        let vocab: [String] = (0..<600).map { _ in
            let len = 5 + rng.next() % 5
            return String((0..<len).map { _ in letters[rng.next() % letters.count] })
        }
        var raw: [[String: Any]] = []
        for i in 0..<1000 {
            var words: [String] = []
            var size = 0
            while size < 8 * 1024 {
                let w = vocab[rng.next() % vocab.count]
                words.append(w)
                size += w.utf8.count + 1
            }
            var text = words.joined(separator: " ")
            if i == 500 { text += " \(vocab[0]) \(vocab[1]) zzuniqueneedle" }
            raw.append(["id": "perf:\(i)", "source": "repo_docs", "kind": "bug", "repo": "r\(i % 9)",
                        "title": "Document \(i)", "search_text": text])
        }
        return (try WorkTestSupport.decodeItems(raw), vocab)
    }

    private func seconds(_ block: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        block()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }

    func testFilteringOnAThreeTermQueryIsCorrectOverALargeCorpus() throws {
        let (items, vocab) = try makeBigCorpus()
        var f = WorkFilter()
        f.query = "\(vocab[0]) \(vocab[1]) zzuniqueneedle"
        XCTAssertEqual(ids(WorkQuery.filter(items, f)), ["perf:500"], "a term only in the last bytes of a body is found")
    }

    func testASingleKeystrokeOverOneThousandBigItemsFitsTheInteractiveBudget() throws {
        let (items, vocab) = try makeBigCorpus()
        let prefix = "\(vocab[0]) \(vocab[1]) \(vocab[2])"

        // The user has already typed the earlier characters: a first pass over a fresh
        // item set may legitimately build whatever it needs to make later keystrokes cheap.
        var warm = WorkFilter()
        warm.query = prefix
        _ = WorkQuery.filter(items, warm)

        // Five keystrokes (each a different appended letter, so no result can be reused),
        // judged on the fastest: real elapsed time, but a busy CI runner that steals the
        // CPU for a while cannot fail the test unless it slows ALL five runs.
        var timings: [Double] = []
        for letter in ["a", "b", "c", "d", "e"] {
            var f = WorkFilter()
            f.query = prefix + letter
            var result: [WorkItem] = []
            timings.append(seconds { result = WorkQuery.filter(items, f) })
            XCTAssertLessThanOrEqual(result.count, items.count)
        }
        let best = try XCTUnwrap(timings.min())
        XCTAssertLessThan(best, 0.100, "fastest of 5 keystrokes took \(best * 1000) ms (all: \(timings.map { Int($0 * 1000) }) ms)")
    }
}
