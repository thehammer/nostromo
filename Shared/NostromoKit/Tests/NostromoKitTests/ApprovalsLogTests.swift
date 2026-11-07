// NostromoKit — ApprovalsLogTests.swift
//
// AP5: the Approvals log's wire types, words and paging.

import XCTest
@testable import NostromoKit

final class ApprovalsLogTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!

    private func row(_ id: String, kind: ApprovalsLogRowKind = .request, outcome: String? = nil,
                     refusal: String? = nil, ts: String = "2026-11-07T14:02:03Z") -> ApprovalsLogRow {
        ApprovalsLogRow(rowId: id, kind: kind, ts: ts, outcome: outcome, refusalCode: refusal)
    }

    // MARK: wire

    func testAPageFrameDecodesRowsAndTheCursor() throws {
        let json = """
        {"type":"approvals_log_page","rows":[{"row_id":"r1","kind":"request","ts":"2026-11-07T14:02:03.123456Z",
        "tag":"cody-1","tool_use_id":"toolu_1","request_id":"r1","entry_ids":["e1","e2"],"agent":"main",
        "subagent":{"agent_id":"a1","agent_type":"Explore"},"tool_name":"Bash","summary":"ls","outcome":"denied",
        "by_window":"w1","latency_ms":1500,"sensitive":true}],"next_cursor":"abc"}
        """
        let frame = try JSONDecoder().decode(ApprovalsLogPageFrame.self, from: Data(json.utf8))
        XCTAssertEqual(frame.nextCursor, "abc")
        XCTAssertEqual(frame.rows.count, 1)
        let r = frame.rows[0]
        XCTAssertEqual(r.entryIds, ["e1", "e2"])
        XCTAssertEqual(r.subagent?.agentType, "Explore")
        XCTAssertEqual(r.latencyMs, 1500)
        XCTAssertTrue(r.sensitive)
        XCTAssertEqual(r.toolUseId, "toolu_1")
    }

    func testAnUnknownRowKindIsOtherAndAnUndecodableRowIsSkipped() throws {
        let json = """
        {"rows":[{"row_id":"x","kind":"from_the_future","ts":"2026-11-07T14:02:03Z","entry_ids":[],"summary":"s","sensitive":false},
        {"nonsense":true}]}
        """
        let frame = try JSONDecoder().decode(ApprovalsLogPageFrame.self, from: Data(json.utf8))
        XCTAssertEqual(frame.rows.map(\.kind), [.other])
        XCTAssertNil(frame.nextCursor)
    }

    func testADetailFrameCarriesTheFullInputExactlyAsRecorded() throws {
        let json = """
        {"id":"r1","detail":{"id":"e1","kind":"request","event":"request","ts":"2026-11-07T14:02:03Z",
        "input":{"command":"echo \\u27E8U+202E\\u27E9 hi"},"reason":{"kind":"ask"},"sensitive":false}}
        """
        let frame = try JSONDecoder().decode(ApprovalsLogDetailFrame.self, from: Data(json.utf8))
        XCTAssertEqual(frame.detail?.input?.stringField("command"), "echo ⟨U+202E⟩ hi")
        XCTAssertNil(try JSONDecoder().decode(ApprovalsLogDetailFrame.self, from: Data(#"{"id":"x"}"#.utf8)).detail)
    }

    func testTheRequestsEncodeToTheDaemonsWireForm() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let query = ClientApprovalsLogQuery(tag: "cody-1", outcome: "denied", sinceMs: 5, limit: 50,
                                            cursor: nil, operatorNonce: "n")
        XCTAssertEqual(String(data: try encoder.encode(query), encoding: .utf8),
                       #"{"limit":50,"operator_nonce":"n","outcome":"denied","since_ms":5,"tag":"cody-1","type":"approvals_log_query"}"#)
        let entry = ClientApprovalsLogEntry(id: "e1", operatorNonce: nil)
        XCTAssertEqual(String(data: try encoder.encode(entry), encoding: .utf8),
                       #"{"id":"e1","type":"approvals_log_entry"}"#)
    }

    func testAQueryEncodesItsRequestIdAndAnEntryRequestItsRowTime() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let query = ClientApprovalsLogQuery(tag: nil, outcome: nil, sinceMs: nil, limit: 50, cursor: "c",
                                            requestId: "log-7", operatorNonce: "n")
        XCTAssertEqual(String(data: try encoder.encode(query), encoding: .utf8),
                       #"{"cursor":"c","limit":50,"operator_nonce":"n","request_id":"log-7","type":"approvals_log_query"}"#)
        let entry = ClientApprovalsLogEntry(id: "e1", tsMs: 1_700_000_000_500, operatorNonce: "n")
        XCTAssertEqual(String(data: try encoder.encode(entry), encoding: .utf8),
                       #"{"id":"e1","operator_nonce":"n","ts_ms":1700000000500,"type":"approvals_log_entry"}"#)
    }

    func testAPageFrameDecodesTheRequestIdItEchoesAndToleratesItsAbsence() throws {
        let with = try JSONDecoder().decode(ApprovalsLogPageFrame.self,
                                            from: Data(#"{"rows":[],"next_cursor":"c","request_id":"log-7"}"#.utf8))
        XCTAssertEqual(with.requestId, "log-7")
        XCTAssertEqual(with.nextCursor, "c")
        let without = try JSONDecoder().decode(ApprovalsLogPageFrame.self, from: Data(#"{"rows":[]}"#.utf8))
        XCTAssertNil(without.requestId, "a daemon that does not echo it")
    }

    func testARefusalFrameDecodesTheRequestIdItNames() throws {
        let with = try JSONDecoder().decode(ApprovalsLogRefusedFrame.self,
                                            from: Data(#"{"code":"bad_cursor","request_id":"log-7"}"#.utf8))
        XCTAssertEqual(with.requestId, "log-7")
        let without = try JSONDecoder().decode(ApprovalsLogRefusedFrame.self, from: Data(#"{"code":"bad_cursor"}"#.utf8))
        XCTAssertNil(without.requestId)
    }

    func testAnInputReadsAsItsOwnLinesNotAsEscapedJSON() throws {
        let one = try JSONDecoder().decode(ApprovalJSON.self, from: Data(#"{"command":"a\nb ⟨U+202E⟩"}"#.utf8))
        XCTAssertEqual(one.inputText, "a\nb ⟨U+202E⟩")
        let two = try JSONDecoder().decode(ApprovalJSON.self, from: Data(#"{"description":"d","command":"ls"}"#.utf8))
        XCTAssertEqual(two.inputText, "command: ls\ndescription: d")
        let nested = try JSONDecoder().decode(ApprovalJSON.self, from: Data(#"{"a":{"b":1}}"#.utf8))
        XCTAssertTrue(nested.inputText.contains("\"b\""), "a nested value falls back to JSON")
    }

    // MARK: words

    func testTheOutcomeWordsReuseTheTranscriptRowsWhereOneExists() {
        XCTAssertEqual(ApprovalsLogText.outcomePhrase(row("a", outcome: "denied")), "denied by you")
        XCTAssertEqual(ApprovalsLogText.outcomePhrase(row("a", outcome: "timed_out")), "denied: no answer in 15 min")
        XCTAssertEqual(ApprovalsLogText.outcomePhrase(row("a", outcome: "no_app")), "denied: Nostromo closed")
        XCTAssertEqual(ApprovalsLogText.outcomePhrase(row("a", outcome: "allowed_by_session_rule")), "allowed by session rule")
        XCTAssertEqual(ApprovalsLogText.outcomePhrase(row("a")), "awaiting an answer")
        XCTAssertEqual(ApprovalsLogText.outcomePhrase(row("a", outcome: "from_the_future")), "from the future")
    }

    func testWithholdingKeepsTheRuleAndTheSummaryOutOfTheOutcomePhrase() {
        let rule = ApprovalsLogRow(rowId: "r", kind: .rule, ts: "2026-11-07T14:02:03Z",
                                   summary: "session rule granted: Bash(gh pr view 123:*)",
                                   ruleLabel: "Bash(gh pr view 123:*)", sensitive: true)
        XCTAssertTrue(ApprovalsLogText.outcomePhrase(rule).contains("gh pr view"), "shown by default")
        let withheld = ApprovalsLogText.outcomePhrase(rule, withholding: true)
        XCTAssertFalse(withheld.contains("gh pr view"), withheld)
        XCTAssertFalse(withheld.contains("Bash("), withheld)
        XCTAssertTrue(withheld.contains("session rule granted"), "it still says what kind of event it was")

        let other = ApprovalsLogRow(rowId: "o", kind: .other, ts: "2026-11-07T14:02:03Z",
                                    summary: "something about Dana", sensitive: true)
        XCTAssertEqual(ApprovalsLogText.outcomePhrase(other), "something about Dana")
        XCTAssertFalse(ApprovalsLogText.outcomePhrase(other, withholding: true).contains("Dana"))

        let denied = row("d", outcome: "denied")
        XCTAssertEqual(ApprovalsLogText.outcomePhrase(denied, withholding: true), "denied by you",
                       "words that carry no text are unchanged")
    }

    func testEveryRefusalCodeHasItsPhrase() {
        let cases = [("requires_secure_connection", "refused: network peer"),
                     ("not_operator_app", "refused: not the Nostromo app"),
                     ("synthetic_input", "refused: synthetic input"),
                     ("already_resolved", "refused: already answered")]
        for (code, phrase) in cases {
            XCTAssertEqual(ApprovalsLogText.outcomePhrase(row("r", kind: .refusal, refusal: code)), phrase)
        }
    }

    func testTimeIsLocalWithUTCForTheTooltip() {
        let r = row("a", ts: "2026-11-07T14:02:03.5Z")
        XCTAssertEqual(ApprovalsLogText.time(r, timeZone: utc), "14:02:03")
        XCTAssertEqual(ApprovalsLogText.time(r, timeZone: TimeZone(secondsFromGMT: -6 * 3600)!), "08:02:03")
        XCTAssertEqual(ApprovalsLogText.utcTooltip(r.ts), "2026-11-07 14:02:03 UTC")
        XCTAssertEqual(ApprovalsLogText.time(row("a", ts: "garbage"), timeZone: utc), "garbage")
    }

    func testAgentTextNamesTheSubagent() {
        let sub = try! JSONDecoder().decode(ApprovalSubagent.self, from: Data(#"{"agent_id":"a1","agent_type":"Explore"}"#.utf8))
        let r = ApprovalsLogRow(rowId: "a", kind: .request, ts: "2026-11-07T14:02:03Z", agent: "Cody", subagent: sub)
        XCTAssertEqual(ApprovalsLogText.agentText(r), "Cody › Explore")
        XCTAssertEqual(ApprovalsLogText.agentText(row("b")), "")
    }

    func testLatencyReadsInTheUnitThatFits() {
        XCTAssertEqual(ApprovalsLogText.latency(nil), "")
        XCTAssertEqual(ApprovalsLogText.latency(340), "340 ms")
        XCTAssertEqual(ApprovalsLogText.latency(1200), "1.2 s")
        XCTAssertEqual(ApprovalsLogText.latency(125_000), "2 min 5 s")
    }

    func testTheOutcomeGroupsAreTheWireNames() {
        XCTAssertEqual(ApprovalsLogOutcomeGroup.allCases.map(\.rawValue),
                       ["allowed", "denied", "timed_out", "guard_blocked", "refused", "rules"])
        XCTAssertEqual(ApprovalsLogOutcomeGroup.timedOut.title, "Timed out or no app")
    }

    // MARK: links

    func testALinkKeepsOnlyTheRowsItNames() {
        let a = ApprovalsLogRow(rowId: "r1", kind: .request, ts: "2026-11-07T14:02:03Z", tag: "t", toolUseId: "toolu_1",
                                requestId: "r1", entryIds: ["e1", "e2"])
        let b = ApprovalsLogRow(rowId: "g1", kind: .guardBlocked, ts: "2026-11-07T14:02:03Z", tag: "t", entryIds: ["g1"])
        XCTAssertTrue(ApprovalsLogLink(toolUseId: "toolu_1").matches(a))
        XCTAssertFalse(ApprovalsLogLink(toolUseId: "toolu_1").matches(b))
        XCTAssertTrue(ApprovalsLogLink(entryId: "g1").matches(b))
        XCTAssertTrue(ApprovalsLogLink(entryId: "e2").matches(a))
        XCTAssertFalse(ApprovalsLogLink(tag: "other").matches(a))
        XCTAssertTrue(ApprovalsLogLink(tag: "t").matches(b))
        XCTAssertFalse(ApprovalsLogLink(tag: "t").isRowFilter)
        XCTAssertTrue(ApprovalsLogLink(entryId: "g1").isRowFilter)
    }

    // MARK: paging

    func testPagingAppendsWithoutDuplicatesAndStopsWithoutACursor() {
        var pager = ApprovalsLogPager()
        XCTAssertFalse(pager.canLoadMore)
        XCTAssertNil(pager.cursorToSend)
        pager.beginLoading()
        pager.apply(ApprovalsLogPageFrame(rows: [row("a"), row("b")], nextCursor: "c1"))
        XCTAssertTrue(pager.canLoadMore)
        XCTAssertEqual(pager.cursorToSend, "c1")
        pager.beginLoading()
        XCTAssertFalse(pager.canLoadMore, "a page is on its way")
        pager.apply(ApprovalsLogPageFrame(rows: [row("b"), row("c")], nextCursor: nil))
        XCTAssertEqual(pager.rows.map(\.rowId), ["a", "b", "c"])
        XCTAssertFalse(pager.canLoadMore)
    }

    func testPagingLoadsMoreOnlyNearTheEnd() {
        var pager = ApprovalsLogPager()
        pager.apply(ApprovalsLogPageFrame(rows: (0..<50).map { row("r\($0)") }, nextCursor: "next"))
        XCTAssertFalse(pager.shouldLoadMore(lastVisibleIndex: 10))
        XCTAssertTrue(pager.shouldLoadMore(lastVisibleIndex: 45))
    }

    func testAFailedPageCanBeAskedForAgainAndResetStartsOver() {
        var pager = ApprovalsLogPager()
        pager.apply(ApprovalsLogPageFrame(rows: [row("a")], nextCursor: "c"))
        pager.beginLoading()
        pager.failed()
        XCTAssertTrue(pager.canLoadMore)
        pager.reset()
        XCTAssertTrue(pager.rows.isEmpty)
        XCTAssertNil(pager.cursorToSend)
    }
}
