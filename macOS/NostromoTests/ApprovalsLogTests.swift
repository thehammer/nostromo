import XCTest
import AppKit
import NostromoKit

// AP5: the Approvals log window, its store, the menu, the two links and `approvals log` over app-control.
//
//   * `ApprovalsLogStoreTests`   one request in flight, matching replies, timeouts, lost connection.
//   * `ApprovalsLogViewTests`    filters, links, expanding a row, Show in transcript, paging, no mutation.
//   * `ApprovalsLogLinkTests`    the guard bar's `View in log` and a click on a row's approval status.
//   * `ApprovalsLogMenuTests`    Window ▸ Approvals.
//   * `ApprovalsLogAppControlTests`  the JSON `approvals log` prints and its read-then-ask-again pattern.
//   * `ApprovalsLogScrollSafetyTests`  everything but Show in transcript moves no transcript.

// MARK: - Fixtures

/// What the store sends the daemon connection, recorded.
final class ApprovalsLogRecorder: ApprovalsLogSending {
    struct Query: Equatable {
        let tag: String?
        let outcome: String?
        let sinceMs: Int64?
        let limit: Int
        let cursor: String?
    }

    private(set) var queries: [Query] = []
    /// The request id each query carried, in the order sent.
    private(set) var requestIds: [String] = []
    private(set) var entries: [String] = []
    /// The row time (ms) each entry request carried, in the order sent.
    private(set) var entryTimes: [Int64?] = []

    /// The request id of the query sent last: what a daemon would echo in the page that answers it.
    var lastRequestId: String? { requestIds.last }

    func sendApprovalsLogQuery(tag: String?, outcome: String?, sinceMs: Int64?, limit: Int, cursor: String?,
                               requestId: String) {
        queries.append(Query(tag: tag, outcome: outcome, sinceMs: sinceMs, limit: limit, cursor: cursor))
        requestIds.append(requestId)
    }

    func sendApprovalsLogEntry(id: String, tsMs: Int64?) {
        entries.append(id)
        entryTimes.append(tsMs)
    }
}

/// A transcript revealer that records, and answers `canReveal` as told.
final class ApprovalsRevealRecorder: ApprovalsTranscriptRevealing {
    var canRevealAnswer = true
    private(set) var revealed: [(tag: String, toolUseId: String)] = []

    func canReveal(tag: String, toolUseId: String) -> Bool { canRevealAnswer }

    func reveal(tag: String, toolUseId: String) -> Bool {
        revealed.append((tag, toolUseId))
        return true
    }
}

enum ApprovalsLogFixtures {

    static func row(_ id: String, tag: String = "cody-1", toolUseId: String? = nil, outcome: String? = "denied",
                    kind: ApprovalsLogRowKind = .request, entryIds: [String]? = nil, sensitive: Bool = false,
                    summary: String = "ls -la", ts: String = "2026-11-07T14:02:03Z") -> ApprovalsLogRow {
        ApprovalsLogRow(rowId: id, kind: kind, ts: ts, tag: tag, toolUseId: toolUseId, requestId: kind == .request ? id : nil,
                        entryIds: entryIds ?? [id], agent: "cody", toolName: "Bash", summary: summary, outcome: outcome,
                        byWindow: "w1", latencyMs: 1500, sensitive: sensitive)
    }

    static func page(_ rows: [ApprovalsLogRow], next: String? = nil, requestId: String? = nil) -> ServerMsg {
        .approvalsLogPage(ApprovalsLogPageFrame(rows: rows, nextCursor: next, requestId: requestId))
    }

    /// An entry whose recorded input holds `command`.
    static func detail(id: String, command: String) throws -> ApprovalsLogDetail {
        let json: [String: Any] = ["id": id, "event": "request", "ts": "2026-11-07T14:02:03Z",
                                   "input": ["command": command], "reason": ["kind": "ask"], "sensitive": false]
        return try JSONDecoder().decode(ApprovalsLogDetail.self, from: JSONSerialization.data(withJSONObject: json))
    }

    static func detailFrame(id: String, command: String) throws -> ServerMsg {
        .approvalsLogDetail(ApprovalsLogDetailFrame(id: id, detail: try detail(id: id, command: command)))
    }
}

/// A store over a recorder, with timeouts run by hand, and a view over both.
final class ApprovalsLogWorld {
    let recorder: ApprovalsLogRecorder
    let revealer: ApprovalsRevealRecorder
    let store: ApprovalsLogStore
    let view: ApprovalsLogView
    private let timeoutRunner: () -> Void

    init(connected: Bool = true) {
        let recorder = ApprovalsLogRecorder()
        let revealer = ApprovalsRevealRecorder()
        var scheduled: [() -> Void] = []
        let store = ApprovalsLogStore(schedule: { _, work in scheduled.append(work) })
        if connected { store.sender = recorder }
        let view = ApprovalsLogView(store: store, revealer: revealer, timeZone: TimeZone(identifier: "UTC")!)
        view.frame = NSRect(x: 0, y: 0, width: 980, height: 560)
        view.layoutSubtreeIfNeeded()
        self.recorder = recorder
        self.revealer = revealer
        self.store = store
        self.view = view
        timeoutRunner = {
            let work = scheduled
            scheduled = []
            work.forEach { $0() }
        }
    }

    /// Run every timeout the store asked for, as if its time had passed.
    func runTimeouts() { timeoutRunner() }

    /// The page a daemon sends for the query sent last: it echoes that query's request id.
    func page(_ rows: [ApprovalsLogRow], next: String? = nil) -> ServerMsg {
        ApprovalsLogFixtures.page(rows, next: next, requestId: recorder.lastRequestId)
    }

    /// Open the view on every row and answer its first query with `rows`.
    func open(rows: [ApprovalsLogRow], next: String? = nil, link: ApprovalsLogLink? = nil) {
        view.apply(link: link)
        store.ingest(page(rows, next: next))
        view.layoutSubtreeIfNeeded()
    }
}

// MARK: - The store

final class ApprovalsLogStoreTests: XCTestCase {

    func testOnlyOneRequestIsInFlightAndTheNextStartsWhenTheFirstIsAnswered() {
        let w = ApprovalsLogWorld()
        var answers: [String] = []
        w.store.query(tag: "a", outcome: nil, sinceMs: nil, limit: 10, cursor: nil) { _ in answers.append("first") }
        w.store.query(tag: "b", outcome: nil, sinceMs: nil, limit: 10, cursor: nil) { _ in answers.append("second") }
        XCTAssertEqual(w.recorder.queries.map(\.tag), ["a"], "the second waits")
        XCTAssertEqual(w.store.pendingCount, 2)

        w.store.ingest(w.page([]))
        XCTAssertEqual(answers, ["first"])
        XCTAssertEqual(w.recorder.queries.map(\.tag), ["a", "b"], "the second starts now")
        w.store.ingest(w.page([]))
        XCTAssertEqual(answers, ["first", "second"])
        XCTAssertEqual(w.store.pendingCount, 0)
    }

    func testAnEntryReplyResolvesOnlyTheEntryRequestWithThatId() throws {
        let w = ApprovalsLogWorld()
        var got: [ApprovalsLogDetail?] = []
        w.store.entry(id: "r1") { if case .answered(let d) = $0 { got.append(d) } }
        w.store.ingest(try ApprovalsLogFixtures.detailFrame(id: "someone-else", command: "x"))
        XCTAssertTrue(got.isEmpty, "another id's answer is not ours")
        w.store.ingest(w.page([]))
        XCTAssertTrue(got.isEmpty, "a page does not answer an entry request")
        w.store.ingest(try ApprovalsLogFixtures.detailFrame(id: "r1", command: "echo hi"))
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got.first??.input?.stringField("command"), "echo hi")
        XCTAssertEqual(w.recorder.entries, ["r1"])
    }

    func testARefusalResolvesTheRequestInFlight() {
        let w = ApprovalsLogWorld()
        var reply: ApprovalsLogReply<ApprovalsLogPageFrame>?
        w.store.query(tag: nil, outcome: nil, sinceMs: nil, limit: 10, cursor: "junk") { reply = $0 }
        w.store.ingest(.approvalsLogRefused(ApprovalsLogRefusedFrame(code: "bad_cursor", requestId: "log-1")))
        guard case .refused(let code)? = reply else { return XCTFail("\(String(describing: reply))") }
        XCTAssertEqual(code, "bad_cursor")
    }

    func testARefusalThatNamesAnotherQueryDoesNotResolveTheOneInFlight() {
        let w = ApprovalsLogWorld()
        var reply: ApprovalsLogReply<ApprovalsLogPageFrame>?
        w.store.query(tag: nil, outcome: nil, sinceMs: nil, limit: 10, cursor: nil) { reply = $0 }
        w.store.ingest(.approvalsLogRefused(ApprovalsLogRefusedFrame(code: "bad_cursor", requestId: "log-0")))
        w.store.ingest(.approvalsLogRefused(ApprovalsLogRefusedFrame(code: "bad_cursor")))
        XCTAssertNil(reply, "a refusal for an older query, or for none, is not this query's")
        w.store.ingest(.approvalsLogRefused(ApprovalsLogRefusedFrame(code: "bad_cursor", requestId: "log-1")))
        XCTAssertNotNil(reply)
    }

    func testATimeoutEndsTheRequestAndALateAnswerIsIgnored() {
        let w = ApprovalsLogWorld()
        var answers = 0
        var timedOut = false
        w.store.query(tag: nil, outcome: nil, sinceMs: nil, limit: 10, cursor: nil) {
            answers += 1
            if case .timedOut = $0 { timedOut = true }
        }
        w.runTimeouts()
        XCTAssertTrue(timedOut)
        w.store.ingest(w.page([]))
        XCTAssertEqual(answers, 1, "the completion ran once")
    }

    func testALostConnectionFailsEveryWaiterAtOnce() {
        let w = ApprovalsLogWorld()
        var failures: [String] = []
        for _ in 0..<3 {
            w.store.query(tag: nil, outcome: nil, sinceMs: nil, limit: 10, cursor: nil) {
                if case .failed(let why) = $0 { failures.append(why) }
            }
        }
        w.store.failPendingRequests(reason: "lost")
        XCTAssertEqual(failures, ["lost", "lost", "lost"])
        XCTAssertEqual(w.store.pendingCount, 0)
    }

    func testWithoutAConnectionARequestFailsAtOnce() {
        let w = ApprovalsLogWorld(connected: false)
        var failed = false
        w.store.query(tag: nil, outcome: nil, sinceMs: nil, limit: 10, cursor: nil) {
            if case .failed = $0 { failed = true }
        }
        XCTAssertTrue(failed)
        XCTAssertTrue(w.recorder.queries.isEmpty)
    }

    // MARK: Matching a page to its query

    func testALatePageForATimedOutQueryDoesNotAnswerTheQueryThatFollowsIt() throws {
        let w = ApprovalsLogWorld()
        var aReplies: [String] = []
        var bRows: [[String]] = []
        w.store.query(tag: "a", outcome: nil, sinceMs: nil, limit: 10, cursor: nil) {
            if case .timedOut = $0 { aReplies.append("timedOut") } else { aReplies.append("other") }
        }
        let idA = try XCTUnwrap(w.recorder.lastRequestId)
        w.runTimeouts()
        XCTAssertEqual(aReplies, ["timedOut"], "A gave up after its timeout")

        w.store.query(tag: "b", outcome: nil, sinceMs: nil, limit: 10, cursor: nil) {
            if case .answered(let page) = $0 { bRows.append(page.rows.map(\.rowId)) }
        }
        let idB = try XCTUnwrap(w.recorder.lastRequestId)
        XCTAssertNotEqual(idA, idB, "each query carries its own request id")
        XCTAssertEqual(w.recorder.requestIds, [idA, idB])

        // A's page arrives late, while B is waiting.
        w.store.ingest(ApprovalsLogFixtures.page([ApprovalsLogFixtures.row("from-a")], requestId: idA))
        XCTAssertTrue(bRows.isEmpty, "B must not be answered with A's rows")
        XCTAssertEqual(w.store.pendingCount, 1, "B is still waiting")

        w.store.ingest(ApprovalsLogFixtures.page([ApprovalsLogFixtures.row("from-b")], requestId: idB))
        XCTAssertEqual(bRows, [["from-b"]], "B is answered by its own page")
        XCTAssertEqual(w.store.pendingCount, 0)
        XCTAssertEqual(aReplies, ["timedOut"], "A's completion never runs a second time")
    }

    func testAPageThatNamesNoQueryOrAnotherOneIsDropped() throws {
        let w = ApprovalsLogWorld()
        var answers = 0
        w.store.query(tag: nil, outcome: nil, sinceMs: nil, limit: 10, cursor: nil) { _ in answers += 1 }
        let id = try XCTUnwrap(w.recorder.lastRequestId)

        w.store.ingest(ApprovalsLogFixtures.page([ApprovalsLogFixtures.row("no-id")], requestId: nil))
        w.store.ingest(ApprovalsLogFixtures.page([ApprovalsLogFixtures.row("other-id")], requestId: id + "-other"))
        XCTAssertEqual(answers, 0)
        XCTAssertEqual(w.store.pendingCount, 1, "the query is still waiting for its own page")

        w.store.ingest(ApprovalsLogFixtures.page([], requestId: id))
        XCTAssertEqual(answers, 1)
    }

    func testAnEntryRequestCarriesTheRowTimeWhenItIsKnown() {
        let w = ApprovalsLogWorld()
        w.store.entry(id: "r1", ts: Date(timeIntervalSince1970: 1_700_000_000.5)) { _ in }
        w.store.failPendingRequests(reason: "done")
        w.store.entry(id: "r2") { _ in }
        XCTAssertEqual(w.recorder.entries, ["r1", "r2"])
        XCTAssertEqual(w.recorder.entryTimes.count, 2)
        XCTAssertEqual(w.recorder.entryTimes[0], 1_700_000_000_500, "milliseconds since the epoch")
        XCTAssertNil(w.recorder.entryTimes[1], "no time known: none sent")
    }
}

// MARK: - The window's content

final class ApprovalsLogViewTests: XCTestCase {

    private func rowCell(_ view: ApprovalsLogView, row: Int) -> ApprovalsLogRowView? {
        view.tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? ApprovalsLogRowView
    }

    func testOpeningReadsTheNewestPageAndShowsTheRowsAsTheDaemonSentThem() {
        let w = ApprovalsLogWorld()
        w.view.apply(link: nil)
        XCTAssertEqual(w.recorder.queries, [.init(tag: nil, outcome: nil, sinceMs: nil, limit: ApprovalsLogStore.pageSize, cursor: nil)])
        w.store.ingest(w.page([ApprovalsLogFixtures.row("r3"), ApprovalsLogFixtures.row("r2"),
                                                  ApprovalsLogFixtures.row("r1")]))
        XCTAssertEqual(w.view.visibleRows.map(\.rowId), ["r3", "r2", "r1"], "newest first, as sent")
        XCTAssertEqual(w.view.tableView.numberOfRows, 3)
        let first = rowCell(w.view, row: 0)
        XCTAssertNotNil(first)
    }

    func testTheFocusFilterAsksTheDaemonForThatFocusAndStartsOver() {
        let w = ApprovalsLogWorld()
        w.open(rows: [ApprovalsLogFixtures.row("r1", tag: "cody-1"), ApprovalsLogFixtures.row("r2", tag: "ada-2")])
        XCTAssertTrue(w.view.focusPopup.itemTitles.contains("ada-2"), "the focuses seen are offered")
        w.view.setFocusFilter("ada-2")
        XCTAssertEqual(w.recorder.queries.last?.tag, "ada-2")
        XCTAssertTrue(w.view.visibleRows.isEmpty, "the old rows are dropped until the answer")
        w.store.ingest(w.page([ApprovalsLogFixtures.row("r2", tag: "ada-2")]))
        XCTAssertEqual(w.view.visibleRows.map(\.rowId), ["r2"])
    }

    func testTheOutcomeFilterAsksForItsGroup() {
        let w = ApprovalsLogWorld()
        w.open(rows: [ApprovalsLogFixtures.row("r1")])
        w.view.setOutcomeFilter(.timedOut)
        XCTAssertEqual(w.recorder.queries.last?.outcome, "timed_out")
        w.store.ingest(w.page([ApprovalsLogFixtures.row("r9", outcome: "timed_out")]))
        XCTAssertEqual(w.view.visibleRows.map(\.rowId), ["r9"])
        w.view.setOutcomeFilter(nil)
        XCTAssertNil(w.recorder.queries.last?.outcome)
    }

    func testTheOutcomePopupOffersTheSixGroups() {
        let w = ApprovalsLogWorld()
        XCTAssertEqual(w.view.outcomePopup.itemTitles,
                       ["All outcomes", "Allowed", "Denied", "Timed out or no app", "Guard-blocked", "Refused", "Rules"])
    }

    func testALinkKeepsOnlyItsRowsAndShowAllBringsTheRestBack() {
        let w = ApprovalsLogWorld()
        let rows = [ApprovalsLogFixtures.row("r2", toolUseId: "toolu_2"), ApprovalsLogFixtures.row("r1", toolUseId: "toolu_1")]
        w.open(rows: rows, link: ApprovalsLogLink(toolUseId: "toolu_1"))
        XCTAssertEqual(w.view.visibleRows.map(\.rowId), ["r1"])
        XCTAssertFalse(w.view.showAllButton.isHidden)
        XCTAssertTrue(w.view.linkLabel.stringValue.hasPrefix("Showing:"))
        w.view.showAll()
        XCTAssertEqual(w.view.visibleRows.map(\.rowId), ["r2", "r1"])
        XCTAssertTrue(w.view.showAllButton.isHidden)
    }

    func testAGuardBlockLinkMatchesItsEntryId() {
        let w = ApprovalsLogWorld()
        let block = ApprovalsLogFixtures.row("gate-1", kind: .guardBlocked, entryIds: ["gate-1"])
        w.open(rows: [ApprovalsLogFixtures.row("r1"), block], link: ApprovalsLogLink(tag: "cody-1", entryId: "gate-1"))
        XCTAssertEqual(w.view.visibleRows.map(\.rowId), ["gate-1"])
    }

    func testALinkKeepsReadingOlderPagesUntilItFindsItsRow() {
        let w = ApprovalsLogWorld()
        w.open(rows: [ApprovalsLogFixtures.row("r9", toolUseId: "toolu_9")], next: "c1",
               link: ApprovalsLogLink(toolUseId: "toolu_1"))
        XCTAssertEqual(w.recorder.queries.last?.cursor, "c1", "no match yet: the next page is asked for")
        w.store.ingest(w.page([ApprovalsLogFixtures.row("r1", toolUseId: "toolu_1")], next: "c2"))
        XCTAssertEqual(w.view.visibleRows.map(\.rowId), ["r1"])
        XCTAssertEqual(w.recorder.queries.count, 2, "found it: it stops reading")
    }

    func testTheNextPageIsAskedForWithTheCursorAndRowsAreNotDuplicated() {
        let w = ApprovalsLogWorld()
        w.open(rows: [ApprovalsLogFixtures.row("r2"), ApprovalsLogFixtures.row("r1")], next: "c1")
        w.view.loadNextPage()
        XCTAssertEqual(w.recorder.queries.last?.cursor, "c1")
        w.store.ingest(w.page([ApprovalsLogFixtures.row("r1"), ApprovalsLogFixtures.row("r0")]))
        XCTAssertEqual(w.view.visibleRows.map(\.rowId), ["r2", "r1", "r0"])
        let before = w.recorder.queries.count
        w.view.loadNextPage()
        XCTAssertEqual(w.recorder.queries.count, before, "no cursor: nothing more to ask for")
    }

    func testAFailedReadSaysSoInsteadOfShowingAnEmptyLog() {
        let w = ApprovalsLogWorld()
        w.view.apply(link: nil)
        w.store.ingest(.approvalsLogRefused(ApprovalsLogRefusedFrame(code: "not_operator_app", requestId: "log-1")))
        XCTAssertTrue(w.view.statusLabel.stringValue.contains("not_operator_app"), w.view.statusLabel.stringValue)
    }

    // MARK: Expanding

    func testExpandingARowAsksForTheEntryOnceAndShowsTheFullInputWithTokensInTheWarningColour() throws {
        let w = ApprovalsLogWorld()
        let bidi = "echo safe \u{27E8}U+202E\u{27E9} evil\nrm -rf ~ \u{27E8}U+200B\u{27E9}"
        w.open(rows: [ApprovalsLogFixtures.row("r1")])
        w.view.toggleExpanded(rowId: "r1")
        XCTAssertEqual(w.recorder.entries, ["r1"])
        XCTAssertNil(w.view.detailText(rowId: "r1"), "nothing to show before the daemon answers")
        w.store.ingest(try ApprovalsLogFixtures.detailFrame(id: "r1", command: bidi))

        let text = try XCTUnwrap(w.view.detailText(rowId: "r1"))
        XCTAssertTrue(text.string.contains("echo safe \u{27E8}U+202E\u{27E9} evil\nrm -rf ~ \u{27E8}U+200B\u{27E9}"), "the full input, every line")
        for token in ["\u{27E8}U+202E\u{27E9}", "\u{27E8}U+200B\u{27E9}"] {
            let range = (text.string as NSString).range(of: token)
            XCTAssertNotEqual(range.location, NSNotFound, token)
            let color = text.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
            XCTAssertEqual(color, ApprovalPalette.warning, "\(token) is shown in the warning colour")
        }
        let plain = (text.string as NSString).range(of: "echo safe")
        XCTAssertNotEqual(text.attribute(.foregroundColor, at: plain.location, effectiveRange: nil) as? NSColor, ApprovalPalette.warning)
        XCTAssertTrue(text.string.contains("\"kind\""), "the reason is shown too")
    }

    func testARawInvisibleCharacterInARecordedInputIsStillShownAsAToken() throws {
        let detail = try ApprovalsLogFixtures.detail(id: "r1", command: "a\u{202E}b")
        let text = ApprovalsLogView.detailText(detail)
        XCTAssertFalse(text.string.contains("\u{202E}"), "no raw bidi control reaches the screen")
        XCTAssertTrue(text.string.contains("\u{27E8}U+202E"), text.string)
    }

    func testExpandingARowAsksForItsEntryAtTheRowsTime() {
        let w = ApprovalsLogWorld()
        w.open(rows: [ApprovalsLogFixtures.row("r1", ts: "2026-11-07T14:02:03Z")])
        w.view.toggleExpanded(rowId: "r1")
        let expected = ApprovalsLogText.timestamp("2026-11-07T14:02:03Z").map { Int64($0.timeIntervalSince1970 * 1000) }
        XCTAssertNotNil(expected)
        XCTAssertEqual(w.recorder.entryTimes, [expected], "the daemon is told which day to read")
    }

    func testCollapsingAndExpandingAgainDoesNotAskTwice() throws {
        let w = ApprovalsLogWorld()
        w.open(rows: [ApprovalsLogFixtures.row("r1")])
        w.view.toggleExpanded(rowId: "r1")
        w.store.ingest(try ApprovalsLogFixtures.detailFrame(id: "r1", command: "ls"))
        w.view.toggleExpanded(rowId: "r1")
        XCTAssertFalse(w.view.expanded.contains("r1"))
        w.view.toggleExpanded(rowId: "r1")
        XCTAssertEqual(w.recorder.entries, ["r1"])
        XCTAssertNotNil(w.view.detailText(rowId: "r1"))
    }

    func testAnEntryThatIsGoneSaysSo() {
        let w = ApprovalsLogWorld()
        w.open(rows: [ApprovalsLogFixtures.row("r1")])
        w.view.toggleExpanded(rowId: "r1")
        w.store.ingest(.approvalsLogDetail(ApprovalsLogDetailFrame(id: "r1", detail: nil)))
        XCTAssertEqual(w.view.details["r1"], .missing)
    }

    // MARK: Show in transcript

    func testShowInTranscriptRevealsTheCallOnceAndNothingElseInTheWindowDoes() throws {
        let w = ApprovalsLogWorld()
        w.open(rows: [ApprovalsLogFixtures.row("r1", toolUseId: "toolu_1"), ApprovalsLogFixtures.row("r2", toolUseId: "toolu_2")])
        // Everything else the window can do.
        w.view.setOutcomeFilter(.denied)
        w.store.ingest(w.page([ApprovalsLogFixtures.row("r1", toolUseId: "toolu_1")]))
        w.view.setFocusFilter("cody-1")
        w.store.ingest(w.page([ApprovalsLogFixtures.row("r1", toolUseId: "toolu_1")]))
        w.view.toggleExpanded(rowId: "r1")
        w.store.ingest(try ApprovalsLogFixtures.detailFrame(id: "r1", command: "ls"))
        w.view.toggleExpanded(rowId: "r1")
        w.view.showAll()
        XCTAssertTrue(w.revealer.revealed.isEmpty, "only Show in transcript moves a transcript")

        w.view.toggleExpanded(rowId: "r1")
        XCTAssertTrue(w.view.showInTranscript(rowId: "r1"))
        XCTAssertEqual(w.revealer.revealed.count, 1)
        XCTAssertEqual(w.revealer.revealed.first?.tag, "cody-1")
        XCTAssertEqual(w.revealer.revealed.first?.toolUseId, "toolu_1")
    }

    func testShowInTranscriptIsDisabledWithATooltipWhenThePaneCannotRevealTheCall() throws {
        let w = ApprovalsLogWorld()
        w.revealer.canRevealAnswer = false
        w.open(rows: [ApprovalsLogFixtures.row("r1", toolUseId: "toolu_1")])
        w.view.toggleExpanded(rowId: "r1")
        w.store.ingest(try ApprovalsLogFixtures.detailFrame(id: "r1", command: "ls"))
        let cell = try XCTUnwrap(rowCell(w.view, row: 0))
        XCTAssertFalse(cell.showButton.isHidden)
        XCTAssertFalse(cell.showButton.isEnabled)
        XCTAssertFalse((cell.showButton.toolTip ?? "").isEmpty)

        w.revealer.canRevealAnswer = true
        w.view.tableView.reloadData()
        let enabled = try XCTUnwrap(rowCell(w.view, row: 0))
        XCTAssertTrue(enabled.showButton.isEnabled)
    }

    func testARowWithNoToolCallHasNoShowInTranscript() throws {
        let w = ApprovalsLogWorld()
        w.open(rows: [ApprovalsLogFixtures.row("g1", kind: .guardBlocked)])
        w.view.toggleExpanded(rowId: "g1")
        let cell = try XCTUnwrap(rowCell(w.view, row: 0))
        XCTAssertTrue(cell.showButton.isHidden)
        XCTAssertFalse(w.view.showInTranscript(rowId: "g1"))
        XCTAssertTrue(w.revealer.revealed.isEmpty)
    }

    // MARK: Nothing edits or deletes

    func testNoControlMenuOrContextMenuEditsDeletesClearsOrRemovesAnEntry() throws {
        let w = ApprovalsLogWorld()
        w.open(rows: [ApprovalsLogFixtures.row("r1", toolUseId: "toolu_1")])
        w.view.toggleExpanded(rowId: "r1")
        w.view.layoutSubtreeIfNeeded()
        let banned = ["delete", "remove", "clear", "edit", "erase", "purge", "trash", "forget", "wipe", "revoke"]

        var titles: [String] = []
        for menu in w.view.allMenus { titles += menu.items.map(\.title) }
        var controls: [String] = []
        func walk(_ v: NSView) {
            if let button = v as? NSButton { controls.append(button.title) }
            if v.menu != nil { titles += v.menu!.items.map(\.title) }
            v.subviews.forEach(walk)
        }
        walk(w.view)
        for title in titles + controls {
            for word in banned {
                XCTAssertFalse(title.lowercased().contains(word), "'\(title)' offers to \(word) an entry")
            }
        }
        let cell = try XCTUnwrap(rowCell(w.view, row: 0))
        XCTAssertNil(cell.menu, "a row has no context menu")
        XCTAssertNil(w.view.menu)
    }

    func testNoActionOfAnyControlNamesAnEditingVerb() throws {
        let w = ApprovalsLogWorld()
        w.open(rows: [ApprovalsLogFixtures.row("r1", toolUseId: "toolu_1")])
        w.view.toggleExpanded(rowId: "r1")
        var actions: [String] = []
        func walk(_ v: NSView) {
            if let control = v as? NSControl, let action = control.action { actions.append(NSStringFromSelector(action)) }
            v.subviews.forEach(walk)
        }
        walk(w.view)
        for action in actions {
            for word in ["delete", "remove", "clear", "edit", "erase", "purge"] {
                XCTAssertFalse(action.lowercased().contains(word), action)
            }
        }
    }
}

private extension NSPopUpButton {
    var itemTitles: [String] { itemArray.map(\.title) }
}

// MARK: - The links

final class ApprovalsLogLinkTests: ApprovalRowTestCase {

    func testTheGuardBarsViewInLogIsEnabledAndOpensTheLogOnItsEntryWithoutTouchingFocus() throws {
        let saved = ApprovalOverlayHost.openLog
        defer { ApprovalOverlayHost.openLog = saved }
        var opened: [ApprovalsLogLink] = []
        ApprovalOverlayHost.openLog = { opened.append($0) }

        let p = ApprovalPane(self, withComposer: true)
        let responder = p.window.firstResponder
        p.store.handle(.guardBlocked(try ApprovalAP2bFixtures.guardBlocked(tag: "cody-1", toolUseId: "toolu_g", entryId: "gate-7")))
        let bar = try XCTUnwrap(p.host.guardBar)

        XCTAssertTrue(bar.logLink.isEnabled)
        XCTAssertNotNil(bar.logLink.target)
        XCTAssertNotNil(bar.logLink.action)
        XCTAssertEqual(bar.logLink.accessibilityLabel(), "View in the approvals log")
        XCTAssertTrue(bar.logLink.refusesFirstResponder)
        XCTAssertFalse(bar.acceptsFirstResponder)

        bar.logLink.performClick(nil)

        XCTAssertEqual(opened, [ApprovalsLogLink(tag: "cody-1", entryId: "gate-7")])
        XCTAssertTrue(p.window.firstResponder === responder, "the composer keeps the keyboard")
        XCTAssertNotNil(p.host.guardBar, "the bar stays")
    }

    func testAClickOnARowsApprovalStatusOpensTheLogOnItsCallAndDoesNotToggleTheFold() throws {
        let saved = FoldRowView.approvalLogOpener
        defer { FoldRowView.approvalLogOpener = saved }
        var opened: [ApprovalsLogLink] = []
        FoldRowView.approvalLogOpener = { opened.append($0) }

        let (store, _) = makeStore()
        try request(store, "a")
        let (window, row) = makeRow(settledGroup(["toolu_a"]), store: store)
        var toggles: [Bool] = []
        row.onToggle = { toggles.append($0) }
        XCTAssertFalse(row.approvalField.isHidden, "precondition: the row shows a status")

        let point = ba6cCenter(of: row.approvalField)
        ba6cPress(row, in: window, at: point, releasedAt: point)

        XCTAssertEqual(opened, [ApprovalsLogLink(toolUseId: "toolu_a")])
        XCTAssertTrue(toggles.isEmpty, "the click is the link's, not the fold's")
    }

    func testAClickElsewhereOnTheRowStillTogglesTheFoldAndOpensNoLog() throws {
        let saved = FoldRowView.approvalLogOpener
        defer { FoldRowView.approvalLogOpener = saved }
        var opened: [ApprovalsLogLink] = []
        FoldRowView.approvalLogOpener = { opened.append($0) }

        let (store, _) = makeStore()
        try request(store, "a")
        let (window, row) = makeRow(settledGroup(["toolu_a"]), store: store)
        var toggles: [Bool] = []
        row.onToggle = { toggles.append($0) }

        let summary = ba6cCenter(of: row.summaryField)
        ba6cPress(row, in: window, at: summary, releasedAt: summary)

        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(toggles.count, 1)
    }

    func testARowWithNoStatusHasNoLink() throws {
        let saved = FoldRowView.approvalLogOpener
        defer { FoldRowView.approvalLogOpener = saved }
        var opened: [ApprovalsLogLink] = []
        FoldRowView.approvalLogOpener = { opened.append($0) }
        let (store, _) = makeStore()
        let (_, row) = makeRow(settledGroup(["toolu_a"]), store: store)
        XCTAssertTrue(row.approvalField.isHidden)
        XCTAssertFalse(row.openApprovalLog())
        XCTAssertTrue(opened.isEmpty)
    }
}

// MARK: - The menu

final class ApprovalsLogMenuTests: XCTestCase {

    private func walk(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(walk) ?? []) }
    }

    func testWindowApprovalsIsTheFirstItemWithNoKeyEquivalentAndTheMenuIsTheWindowsMenu() throws {
        _ = NSApplication.shared
        let main = MainMenu.make(target: nil)
        let windowMenu = try XCTUnwrap(main.items.compactMap(\.submenu).first { $0.title == "Window" }, "no Window menu")
        let first = try XCTUnwrap(windowMenu.items.first)
        XCTAssertEqual(first.title, "Approvals")
        XCTAssertEqual(first.keyEquivalent, "")
        XCTAssertEqual(first.action, #selector(MainMenuActions.showApprovalsLog(_:)))
        XCTAssertTrue(NSApp.windowsMenu === windowMenu, "macOS adds Minimize, Zoom and the window list to it")
        XCTAssertTrue(windowMenu.items.allSatisfy { $0.keyEquivalent.isEmpty }, "the Window menu takes no shortcut")
    }

    func testNoExistingShortcutChanged() throws {
        _ = NSApplication.shared
        let main = MainMenu.make(target: nil)
        let card = try XCTUnwrap(walk(main).first { $0.title == "Go to Approval Card" })
        XCTAssertEqual(card.keyEquivalent, "a")
        XCTAssertEqual(card.keyEquivalentModifierMask, [.command, .option])
        let session = try XCTUnwrap(main.items.compactMap(\.submenu).first { $0.title == "Session" })
        let keys = session.items.map { "\($0.keyEquivalent)|\($0.keyEquivalentModifierMask.rawValue)" }
        XCTAssertEqual(Set(keys).count, keys.count, "no two Session items share a shortcut")
        let titles = main.items.compactMap(\.submenu).map(\.title)
        for existing in ["Edit", "Terminal", "Debug", "Session"] { XCTAssertTrue(titles.contains(existing), existing) }
    }
}

// MARK: - app-control

final class ApprovalsLogAppControlTests: XCTestCase {

    func testARowsJSONCarriesTheWindowsFields() {
        let json = ApprovalsLogJSON.row(for: ApprovalsLogFixtures.row("r1", toolUseId: "toolu_1"), redactSensitive: true)
        XCTAssertEqual(json["row_id"] as? String, "r1")
        XCTAssertEqual(json["kind"] as? String, "request")
        XCTAssertEqual(json["tag"] as? String, "cody-1")
        XCTAssertEqual(json["tool_use_id"] as? String, "toolu_1")
        XCTAssertEqual(json["tool_name"] as? String, "Bash")
        XCTAssertEqual(json["summary"] as? String, "ls -la")
        XCTAssertEqual(json["outcome"] as? String, "denied")
        XCTAssertEqual(json["outcome_text"] as? String, "denied by you")
        XCTAssertEqual(json["by_window"] as? String, "w1")
        XCTAssertEqual(json["latency_ms"] as? UInt64, 1500)
        XCTAssertEqual(json["entry_ids"] as? [String], ["r1"])
        XCTAssertNil(json["withheld"])
    }

    func testTheRealAppWithholdsASensitiveRowsSummaryAndTheQAInstanceDoesNot() {
        let row = ApprovalsLogFixtures.row("r1", sensitive: true, summary: "send the message to Dana")
        let real = ApprovalsLogJSON.row(for: row, redactSensitive: true)
        XCTAssertEqual(real["withheld"] as? Bool, true)
        XCTAssertNil(real["summary"])
        XCTAssertFalse("\(real)".contains("Dana"))
        let qa = ApprovalsLogJSON.row(for: row, redactSensitive: false)
        XCTAssertEqual(qa["summary"] as? String, "send the message to Dana")
        XCTAssertNil(qa["withheld"])
        let ordinary = ApprovalsLogJSON.row(for: ApprovalsLogFixtures.row("r2"), redactSensitive: true)
        XCTAssertEqual(ordinary["summary"] as? String, "ls -la", "every other row is returned in full")
    }

    // MARK: Withholding

    /// Every string anywhere in the serialized reply, as one text.
    private func serialized(_ json: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: json)
        return String(decoding: data, as: UTF8.self)
    }

    private func logRow(_ kind: ApprovalsLogRowKind, summary: String, ruleLabel: String? = nil,
                        refusalCode: String? = nil, outcome: String? = nil, sensitive: Bool = true) -> ApprovalsLogRow {
        ApprovalsLogRow(rowId: "x1", kind: kind, ts: "2026-11-07T14:02:03Z", tag: "teri-1", entryIds: ["x1"],
                        summary: summary, outcome: outcome, refusalCode: refusalCode, ruleLabel: ruleLabel,
                        sensitive: sensitive)
    }

    func testTheRealAppShowsNoRuleTextAnywhereInASensitiveRuleRow() throws {
        let row = logRow(.rule, summary: "session rule granted: Bash(gh pr view 123:*)", ruleLabel: "Bash(gh pr view 123:*)")
        let real = ApprovalsLogJSON.row(for: row, redactSensitive: true)
        XCTAssertEqual(real["withheld"] as? Bool, true)
        let text = try serialized(real)
        XCTAssertFalse(text.contains("gh pr view"), "no command text anywhere in the row: \(text)")
        XCTAssertFalse(text.contains("Bash("), "no rule text anywhere in the row: \(text)")
        XCTAssertNil(real["summary"])
        XCTAssertNil(real["rule_label"])
        XCTAssertFalse((real["outcome_text"] as? String ?? "").contains("gh pr view"))
    }

    func testTheQAInstanceStillShowsTheRuleOfASensitiveRuleRow() throws {
        let row = logRow(.rule, summary: "session rule granted: Bash(gh pr view 123:*)", ruleLabel: "Bash(gh pr view 123:*)")
        let qa = ApprovalsLogJSON.row(for: row, redactSensitive: false)
        XCTAssertNil(qa["withheld"])
        XCTAssertEqual(qa["rule_label"] as? String, "Bash(gh pr view 123:*)")
        XCTAssertEqual(qa["summary"] as? String, "session rule granted: Bash(gh pr view 123:*)")
        XCTAssertTrue((qa["outcome_text"] as? String ?? "").contains("gh pr view"), "the outcome text names the rule")
    }

    func testTheRealAppShowsNoSummaryTextOfASensitiveRowOfAnyOtherKind() throws {
        let secret = "Dana's diagnosis is in the attached file"
        let rows = [
            logRow(.other, summary: secret),
            logRow(.guardBlocked, summary: secret, ruleLabel: secret, outcome: "guard_blocked"),
            logRow(.refusal, summary: secret, refusalCode: "not_operator_app"),
            logRow(.request, summary: secret, outcome: "denied"),
        ]
        for row in rows {
            let text = try serialized(ApprovalsLogJSON.row(for: row, redactSensitive: true))
            XCTAssertFalse(text.contains("Dana"), "\(row.kind): \(text)")
            XCTAssertFalse(text.contains("diagnosis"), "\(row.kind): \(text)")
        }
    }

    func testARowThatIsNotSensitiveIsNeverWithheldEvenInTheRealApp() throws {
        let row = logRow(.rule, summary: "session rule granted: Bash(ls:*)", ruleLabel: "Bash(ls:*)", sensitive: false)
        let real = ApprovalsLogJSON.row(for: row, redactSensitive: true)
        XCTAssertNil(real["withheld"])
        XCTAssertEqual(real["rule_label"] as? String, "Bash(ls:*)")
        XCTAssertTrue((real["outcome_text"] as? String ?? "").contains("Bash(ls:*)"))
    }

    func testTheRowsMatchWhatTheWindowShows() {
        let w = ApprovalsLogWorld()
        let rows = [ApprovalsLogFixtures.row("r2"), ApprovalsLogFixtures.row("g1", outcome: "guard_blocked", kind: .guardBlocked)]
        w.open(rows: rows)
        let json = ApprovalsLogJSON.reply(.ready(ApprovalsLogPageFrame(rows: rows, nextCursor: nil)), redactSensitive: false)
        XCTAssertEqual((json["rows"] as? [[String: Any]])?.map { $0["row_id"] as? String }, w.view.visibleRows.map(\.rowId))
        XCTAssertEqual(json["state"] as? String, "ready")
    }

    func testTheReaderAnswersLoadingThenTheRowsThenReadsAfresh() {
        let w = ApprovalsLogWorld()
        var now = Date(timeIntervalSince1970: 1_000)
        let t0 = now
        let reader = ApprovalsLogReader(clock: { now })
        func read(at date: Date) -> ApprovalsLogReader.Result {
            now = date
            return reader.read(tag: "cody-1", outcome: "denied", sinceMs: nil, limit: 20, store: w.store)
        }
        guard case .loading = read(at: t0) else { return XCTFail("the first ask starts the read") }
        XCTAssertEqual(w.recorder.queries, [.init(tag: "cody-1", outcome: "denied", sinceMs: nil, limit: 20, cursor: nil)])
        guard case .loading = read(at: t0.addingTimeInterval(0.25)) else { return XCTFail("still reading") }
        XCTAssertEqual(w.recorder.queries.count, 1, "asking again does not start a second read")

        w.store.ingest(w.page([ApprovalsLogFixtures.row("r1")]))
        guard case .ready(let page) = read(at: t0.addingTimeInterval(0.5)) else { return XCTFail("ready") }
        XCTAssertEqual(page.rows.map(\.rowId), ["r1"])
        guard case .ready = read(at: t0.addingTimeInterval(1)) else { return XCTFail("kept for the poll") }

        guard case .loading = read(at: t0.addingTimeInterval(60)) else { return XCTFail("a later ask reads afresh") }
        XCTAssertEqual(w.recorder.queries.count, 2)
    }

    func testAFailedReadIsAnErrorState() {
        let w = ApprovalsLogWorld(connected: false)
        let reader = ApprovalsLogReader()
        guard case .failed = reader.read(tag: nil, outcome: nil, sinceMs: nil, limit: 5, store: w.store) else {
            return XCTFail("no connection: an error, not `loading` forever")
        }
        let json = ApprovalsLogJSON.reply(.failed("Not connected to the daemon."), redactSensitive: true)
        XCTAssertEqual(json["state"] as? String, "error")
    }
}

// MARK: - Scroll safety

/// The window and its links move no transcript, in a pane that follows the tail and one scrolled up, with
/// partly typed composer text (`SafetyRig.assertNoMove` also checks the first responder, text and selection).
/// Show in transcript is the one control that does move one, and is not in this gate.
final class ApprovalsLogScrollSafetyTests: XCTestCase {

    private func manager(_ world: ApprovalsLogWorld) -> ApprovalsWindowManager {
        let defaults = UserDefaults(suiteName: "ApprovalsLog-\(UUID().uuidString)")!
        return ApprovalsWindowManager(defaults: defaults, store: world.store, revealer: world.revealer,
                                      visibleScreens: { [NSRect(x: 0, y: 0, width: 1600, height: 1000)] })
    }

    func testOpeningFilteringExpandingPagingAndTheLinksMoveNoTranscript() throws {
        for following in [true, false] {
            let rig = following ? SafetyRig.followingTail(self) : SafetyRig.scrolledUp(self)
            let world = ApprovalsLogWorld()
            let windows = manager(world)
            defer { windows.close() }
            let at = "(following: \(following))"
            let rows = [ApprovalsLogFixtures.row("r2", toolUseId: "toolu_2"), ApprovalsLogFixtures.row("r1", toolUseId: "toolu_1")]

            rig.assertNoMove("Window > Approvals opens the window \(at)", following: following) {
                windows.show()
            }
            let view = try XCTUnwrap(windows.logView)
            rig.assertNoMove("the first page arrives \(at)", following: following) {
                world.store.ingest(world.page(rows))
            }
            rig.assertNoMove("the outcome filter changes \(at)", following: following) {
                view.setOutcomeFilter(.denied)
                world.store.ingest(world.page(rows))
            }
            rig.assertNoMove("the focus filter changes \(at)", following: following) {
                view.setFocusFilter("cody-1")
                world.store.ingest(world.page(rows))
            }
            rig.assertNoMove("a row expands \(at)", following: following) {
                view.toggleExpanded(rowId: "r1")
                world.store.ingest(try! ApprovalsLogFixtures.detailFrame(id: "r1", command: "ls"))
            }
            rig.assertNoMove("a row collapses \(at)", following: following) {
                view.toggleExpanded(rowId: "r1")
            }
            rig.assertNoMove("the next page loads \(at)", following: following) {
                view.loadNextPage()
                world.store.ingest(world.page([ApprovalsLogFixtures.row("r0")]))
            }
            rig.assertNoMove("a click on an approval status opens the window on a call \(at)", following: following) {
                windows.show(link: ApprovalsLogLink(toolUseId: "toolu_1"))
                world.store.ingest(world.page(rows))
            }
            rig.assertNoMove("the guard bar's View in log opens it on an entry \(at)", following: following) {
                let bar = GuardBlockedBar(text: "Blocked: Cody tried to open a production shell")
                bar.frame = NSRect(x: 0, y: 0, width: 600, height: GuardBlockedBar.height)
                bar.onViewInLog = { windows.show(link: ApprovalsLogLink(tag: "cody-1", entryId: "gate-1")) }
                bar.logLink.performClick(nil)
                world.store.ingest(world.page([]))
            }
            XCTAssertTrue(world.revealer.revealed.isEmpty, "none of these revealed a call \(at)")
            rig.assertNoMove("the window closes \(at)", following: following) {
                windows.close()
            }
        }
    }

    func testTheWindowIsAPanelThatNeverEndsTheAppAndRemembersItsFrame() throws {
        let world = ApprovalsLogWorld()
        let defaults = UserDefaults(suiteName: "ApprovalsLog-\(UUID().uuidString)")!
        let windows = ApprovalsWindowManager(defaults: defaults, store: world.store, revealer: world.revealer,
                                             visibleScreens: { [NSRect(x: 0, y: 0, width: 1600, height: 1000)] })
        defer { windows.close() }
        windows.show()
        let panel = try XCTUnwrap(windows.panel)
        XCTAssertEqual(panel.title, "Approvals")
        XCTAssertFalse((panel as NSWindow) is NostromoWindow, "a NostromoWindow's close ends the app")
        XCTAssertFalse(panel.canBecomeMain)
        windows.show()
        XCTAssertTrue(windows.panel === panel, "one reusable window")

        let moved = NSRect(x: 120, y: 140, width: 900, height: 500)
        panel.setFrame(moved, display: false)
        defaults.set(NSStringFromRect(moved), forKey: ApprovalsWindowManager.defaultsKey)
        windows.close()
        let again = ApprovalsWindowManager(defaults: defaults, store: world.store, revealer: world.revealer,
                                           visibleScreens: { [NSRect(x: 0, y: 0, width: 1600, height: 1000)] })
        defer { again.close() }
        again.show()
        XCTAssertEqual(again.panel?.frame, moved, "it opens where it was left")
    }
}
