import XCTest

// NostromodClient, ServerMsg and the work models are compiled into this test
// target directly (see NotificationDecodeTests.swift) — no host app needed.
// The JSON fixtures are the shapes the Rust round-trip tests in
// `src/ipc/protocol.rs` (`work_wire_tests`) produce.

final class WorkWireDecodingTests: XCTestCase {
    private var client: NostromodClient!

    override func setUp() {
        super.setUp()
        client = NostromodClient(socketPath: "/dev/null")
    }

    private func decode(_ json: String) throws -> ServerMsg {
        let raw = json.data(using: .utf8)!
        let obj = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        return client.decode(type_: obj["type"] as! String, json: obj, raw: raw)
    }

    // MARK: - Server frames

    func testWorkSourceStatusDecodes() throws {
        let msg = try decode("""
        {"type":"work_source_status","status":{"source":"jira","state":"rate_limited",
         "updated_at":"2026-10-09T14:30:00Z","reason":"slow down","retry_at":"2026-10-09T14:31:00.250Z",
         "count":4,"group_errors":[{"group":"repo","reason":"boom"}]}}
        """)
        guard case .workSourceStatus(let s) = msg else { return XCTFail("got \(msg)") }
        XCTAssertEqual(s.source, .jira)
        XCTAssertEqual(s.state, .rateLimited)
        XCTAssertEqual(s.reason, "slow down")
        XCTAssertNotNil(s.updatedAt)
        XCTAssertNotNil(s.retryAt, "fractional-second dates decode too")
        XCTAssertEqual(s.count, 4)
        XCTAssertEqual(s.groupErrors, [GroupError(group: "repo", reason: "boom")])
    }

    func testWorkSourceStatusWithOnlyRequiredFieldsDecodes() throws {
        let msg = try decode(#"{"type":"work_source_status","status":{"source":"todos","state":"loading"}}"#)
        guard case .workSourceStatus(let s) = msg else { return XCTFail("got \(msg)") }
        XCTAssertEqual(s.state, .loading)
        XCTAssertNil(s.updatedAt)
        XCTAssertEqual(s.count, 0)
        XCTAssertTrue(s.groupErrors.isEmpty)
    }

    func testUnknownSourceStateDecodesAsErrorNotAFailure() throws {
        let msg = try decode(#"{"type":"work_source_status","status":{"source":"sentry","state":"from_the_future"}}"#)
        guard case .workSourceStatus(let s) = msg else { return XCTFail("got \(msg)") }
        XCTAssertEqual(s.state, .error)
    }

    func testWorkSnapshotDecodesItemsAndGroup() throws {
        let msg = try decode("""
        {"type":"work_snapshot","source":"repo_docs","group":"nostromo","items":[
          {"id":"jira:CORE-1","source":"jira","kind":"story","title":"Fix the thing","project":"CORE",
           "status":"In Progress","status_category":"in_progress","priority":{"label":"High","rank":2},
           "created_at":"2026-10-09T14:30:00Z","updated_at":"2026-10-09T14:30:00Z","due":"2026-10-12",
           "url":"https://example.invalid/CORE-1","metrics":{"events":3},"linked":["todo:abc"],
           "search_text":"fix the thing",
           "sent":[{"kind":"focus","target_id":"core-1","label":"CORE-1","created_at":"2026-10-09T14:30:00Z"}]}
        ]}
        """)
        guard case .workSnapshot(let source, let group, let items) = msg else { return XCTFail("got \(msg)") }
        XCTAssertEqual(source, .repoDocs)
        XCTAssertEqual(group, "nostromo")
        XCTAssertEqual(items.count, 1)
        let item = items[0]
        XCTAssertEqual(item.id, "jira:CORE-1")
        XCTAssertEqual(item.statusCategory, "in_progress")
        XCTAssertEqual(item.priority, WorkPriority(label: "High", rank: 2))
        XCTAssertEqual(item.due, "2026-10-12")
        XCTAssertEqual(item.metrics, ["events": 3])
        XCTAssertEqual(item.linked, ["todo:abc"])
        XCTAssertEqual(item.sent.first?.targetId, "core-1")
        XCTAssertNil(item.repo)
    }

    func testEmptyWorkSnapshotWithNoGroupDecodes() throws {
        let msg = try decode(#"{"type":"work_snapshot","source":"todos","items":[]}"#)
        guard case .workSnapshot(let source, let group, let items) = msg else { return XCTFail("got \(msg)") }
        XCTAssertEqual(source, .todos)
        XCTAssertNil(group)
        XCTAssertTrue(items.isEmpty)
    }

    func testTeriPicksDecodes() throws {
        let msg = try decode("""
        {"type":"teri_picks","picks":{"generated_at":"2026-10-09T14:30:00Z","generating":false,
         "unavailable_sources":["sentry"],
         "items":[{"item_id":"jira:CORE-1","source":"jira","title":"Fix the thing","reason":"due soon","done_since":false}]}}
        """)
        guard case .teriPicks(let p) = msg else { return XCTFail("got \(msg)") }
        XCTAssertEqual(p.unavailableSources, [.sentry])
        XCTAssertEqual(p.items.first?.reason, "due soon")
        XCTAssertEqual(p.items.first?.doneSince, false)
        XCTAssertNil(p.error)
    }

    func testWorkDetailOkDecodesFieldPairs() throws {
        let msg = try decode("""
        {"type":"work_detail","request_id":"r1","result":{"status":"ok","value":{
          "item_id":"jira:CORE-1","title":"Fix the thing","fields":[["Status","In Progress"]],
          "markdown":"# hi","files":["a.md"],"links":[{"label":"Open","url":"https://example.invalid"}]}}}
        """)
        guard case .workDetail(let id, let result) = msg, case .ok(let d) = result else { return XCTFail("got \(msg)") }
        XCTAssertEqual(id, "r1")
        XCTAssertEqual(d.fields, [WorkDetailField(label: "Status", value: "In Progress")])
        XCTAssertEqual(d.links.first?.label, "Open")
        XCTAssertEqual(d.markdown, "# hi")
    }

    func testWorkDetailErrDecodesCodeAndMessage() throws {
        let msg = try decode("""
        {"type":"work_detail","request_id":"r1","result":{"status":"err","value":{"code":"not_available","message":"not available yet"}}}
        """)
        guard case .workDetail(_, let result) = msg, case .err(let e) = result else { return XCTFail("got \(msg)") }
        XCTAssertEqual(e.code, "not_available")
    }

    func testWorkSendPreviewDecodes() throws {
        let msg = try decode("""
        {"type":"work_send_preview","request_id":"r2","result":{"status":"ok","value":{
          "item_id":"jira:CORE-1","agent":"claude","working_directory":"/tmp/repo","label":"CORE-1","context":"do it"}}}
        """)
        guard case .workSendPreview(let id, let result) = msg, case .ok(let p) = result else { return XCTFail("got \(msg)") }
        XCTAssertEqual(id, "r2")
        XCTAssertEqual(p.workingDirectory, "/tmp/repo")
        XCTAssertTrue(p.existing.isEmpty)
    }

    func testWorkSendResultOkAndRefusalDecode() throws {
        let ok = try decode("""
        {"type":"work_send_result","request_id":"r3","result":{"status":"ok","value":{"kind":"seeded","focus_tag":"fred"}}}
        """)
        guard case .workSendResult(_, let okResult) = ok, case .ok(let o) = okResult else { return XCTFail("got \(ok)") }
        XCTAssertEqual(o.kind, "seeded")
        XCTAssertEqual(o.focusTag, "fred")
        XCTAssertNil(o.jobId)

        let refused = try decode("""
        {"type":"work_send_result","request_id":"r3","result":{"status":"err","value":{"code":"requires_secure_connection","message":"x"}}}
        """)
        guard case .workSendResult(_, let errResult) = refused, case .err(let e) = errResult else { return XCTFail("got \(refused)") }
        XCTAssertEqual(e.code, "requires_secure_connection")
    }

    func testWithheldDecodes() throws {
        let msg = try decode(#"{"type":"withheld","topics":["fred","teri","work"],"reason":"requires_secure_connection"}"#)
        guard case .withheld(let topics, let reason) = msg else { return XCTFail("got \(msg)") }
        XCTAssertEqual(topics, ["fred", "teri", "work"])
        XCTAssertEqual(reason, "requires_secure_connection")
    }

    func testUnknownFieldsAreIgnored() throws {
        let msg = try decode("""
        {"type":"work_snapshot","source":"jira","extra":1,"items":[
          {"id":"jira:A-1","source":"jira","kind":"bug","title":"t","brand_new_field":{"x":1}}]}
        """)
        guard case .workSnapshot(_, _, let items) = msg else { return XCTFail("got \(msg)") }
        XCTAssertEqual(items.first?.id, "jira:A-1")
        XCTAssertEqual(items.first?.searchText, "")
    }

    // MARK: - FocusMeta

    func testFocusCreatedWithNewFieldsMapsLabelAndProjectPath() throws {
        let msg = try decode("""
        {"type":"focus_created","meta":{"tag":"cody-core-1","display_name":"Cody","agent_name":"cody",
         "is_built_in":false,"label":"CORE-1","project_path":"/Users/x/admin-portal","select_for_client":"abc"}}
        """)
        guard case .focusCreated(let meta) = msg else { return XCTFail("got \(msg)") }
        XCTAssertEqual(meta.selectForClient, "abc")
        let focus = meta.toFocus()
        XCTAssertEqual(focus.label, "CORE-1")
        XCTAssertEqual(focus.projectPath, "/Users/x/admin-portal")
        XCTAssertEqual(focus.daemonTag, "cody-core-1")
        XCTAssertEqual(focus.sessionTag, "cody-core-1")
    }

    func testFocusCreatedFromAnOlderDaemonStillDecodes() throws {
        let msg = try decode("""
        {"type":"focus_created","meta":{"tag":"cody-x","display_name":"Cody","agent_name":"cody","is_built_in":false}}
        """)
        guard case .focusCreated(let meta) = msg else { return XCTFail("got \(msg)") }
        XCTAssertNil(meta.selectForClient)
        let focus = meta.toFocus()
        XCTAssertNil(focus.label)
        XCTAssertNil(focus.projectPath)
    }

    // MARK: - Client frames

    private func encode(_ m: WorkClientMessage) throws -> [String: Any] {
        let data = try JSONEncoder().encode(m)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func testClientFramesEncodeTheWireShape() throws {
        let detail = try encode(.detailRequest(requestId: "r1", itemId: "mail:abc"))
        XCTAssertEqual(detail["type"] as? String, "work_detail_request")
        XCTAssertEqual(detail["request_id"] as? String, "r1")
        XCTAssertEqual(detail["item_id"] as? String, "mail:abc")

        let refresh = try encode(.refresh(source: .jira, fred: false))
        XCTAssertEqual(refresh["type"] as? String, "work_refresh")
        XCTAssertEqual(refresh["source"] as? String, "jira")
        XCTAssertEqual(refresh["fred"] as? Bool, false)

        let refreshAll = try encode(.refresh(source: nil, fred: true))
        XCTAssertNil(refreshAll["source"])
        XCTAssertEqual(refreshAll["fred"] as? Bool, true)

        let picks = try encode(.picksRefresh(reason: "manual"))
        XCTAssertEqual(picks["type"] as? String, "picks_refresh")
        XCTAssertEqual(picks["reason"] as? String, "manual")

        let preview = try encode(.sendPreviewRequest(requestId: "r2", itemId: "todo:1"))
        XCTAssertEqual(preview["type"] as? String, "work_send_preview_request")

        let send = try encode(.send(WorkSendRequest(
            requestId: "r3", itemId: "todo:1", destination: "focus", agent: "claude",
            workingDirectory: nil, label: "a", context: "b", allowDuplicate: true)))
        XCTAssertEqual(send["type"] as? String, "work_send")
        XCTAssertEqual(send["destination"] as? String, "focus")
        XCTAssertEqual(send["allow_duplicate"] as? Bool, true)
        XCTAssertNil(send["working_directory"])

        let seed = try encode(.fredSeed(requestId: "r4", text: "hi"))
        XCTAssertEqual(seed["type"] as? String, "fred_seed")
        XCTAssertEqual(seed["text"] as? String, "hi")
    }
}
