// NostromoKit — AuthoredPrsMergeTests.swift
//
// Perri's verdict and the Merge verb, as the Kit sees them (features `authored_prs_perri_v1` and
// `authored_prs_merge_v1`): the two additive row fields, the merge request, its answer frame and the words
// for every code, and when the Merge button is offered. The daemon enforces every rule again; here the
// question is only what the app decodes, sends and shows.
//
// The goldens under `tests/fixtures/authored_prs/` are written by the daemon's own Rust types.
//
// Mutations this file is meant to catch:
//   1. A short head that is not exactly eight lowercase hex digits kept on the row (it is echoed back in
//      the merge request)
//        -> testHeadShaShortIsKeptOnlyWhenExactlyEightLowercaseHexDigits
//   2. An absent `for_current_head` read as true (an old approval counted as approval of the new head)
//        -> testAbsentForCurrentHeadMeansNotForTheCurrentHead
//   3. An unknown or malformed merge answer read as success
//        -> testAnUnknownCodeIsAGenericFailureNeverSuccess, testMalformedMergeAnswersAreNotFrames
//   4. The merge request sent with other keys, or the daemon's refusal not read as "not permitted"
//        -> testTheMergeRequestHasExactlyTheDocumentedKeys, testARefusalOfThePeerIsNotPermitted
//   5. The button offered on a row Perri did not approve at this head, or on a draft, red or merged row
//        -> testMergeReadiness...

import XCTest
@testable import NostromoKit

// MARK: - Helpers

private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // NostromoKitTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // NostromoKit
        .deletingLastPathComponent()   // Shared
        .deletingLastPathComponent()   // <repo>
        .appendingPathComponent("tests/fixtures/authored_prs/\(name)")
}

private func fixture(_ name: String) throws -> Data { try Data(contentsOf: fixtureURL(name)) }

private func jsonData(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object)
}

/// The smallest row the Kit accepts, with overrides merged over it.
private func prDict(_ overrides: [String: Any] = [:]) -> [String: Any] {
    var d: [String: Any] = ["repo": "o/r", "number": 1, "title": "T", "group": "waiting", "lifecycle": "open"]
    d.merge(overrides) { _, new in new }
    return d
}

private func decodeRow(_ overrides: [String: Any] = [:]) throws -> AuthoredPr {
    let frame = try jsonData(["type": "authored_prs", "snapshot": ["prs": [prDict(overrides)]]])
    let snapshot = try JSONDecoder().decode(AuthoredPrsFrame.self, from: frame).snapshot
    return try XCTUnwrap(snapshot.prs.first, "the row was dropped")
}

private func mergeFrame(_ result: [String: Any], id: String = "r7") throws -> Data {
    try jsonData(["type": "authored_pr_merge_result", "request_id": id, "result": result])
}

private func err(_ code: String) -> [String: Any] { ["status": "err", "value": ["code": code]] }

private func answer(_ result: [String: Any]) throws -> AuthoredPrAnswer<AuthoredPrDone>? {
    guard case .merge(_, let answer)? = AuthoredPrAnswerFrame.decode(try mergeFrame(result)) else { return nil }
    return answer
}

// MARK: - Rows: head and Perri

final class AuthoredPrsPerriRowTests: XCTestCase {

    func testHeadShaShortIsKeptOnlyWhenExactlyEightLowercaseHexDigits() throws {
        XCTAssertEqual(try decodeRow(["head_sha_short": "0123abcd"]).headShaShort, "0123abcd")
        XCTAssertEqual(try decodeRow(["head_sha_short": "ffffffff"]).headShaShort, "ffffffff")
        XCTAssertEqual(try decodeRow(["head_sha_short": "00000000"]).headShaShort, "00000000")
        for bad: Any in ["0123ABCD", "0123abc", "0123abcde", "", " 123abcd", "0123abc\n", "0123abcg", "01234567 ",
                         "0123abcd\u{0}", "０１２３abcd", String(repeating: "a", count: 40), 12345678, true,
                         ["0123abcd"], NSNull()] {
            XCTAssertNil(try decodeRow(["head_sha_short": bad]).headShaShort, "\(bad) must not be kept")
        }
    }

    func testARowWithoutTheNewFieldsFromAnOlderDaemonStillDecodesWithBothAbsent() throws {
        let row = try decodeRow()
        XCTAssertNil(row.headShaShort)
        XCTAssertNil(row.perri)
        XCTAssertEqual(row.title, "T", "the rest of the row is untouched")
    }

    func testPerriDecodesWithEachVerdict() throws {
        for (wire, want) in [("approved", AuthoredPrPerriVerdict.approved),
                             ("changes_requested", .changesRequested),
                             ("comment", .comment)] {
            let perri = try XCTUnwrap(try decodeRow(["perri": ["verdict": wire, "for_current_head": true,
                                                              "at": "2026-11-14T11:45:00Z", "by": "perri"]]).perri)
            XCTAssertEqual(perri.verdict, want, wire)
            XCTAssertTrue(perri.forCurrentHead)
            XCTAssertEqual(perri.by, "perri")
            XCTAssertEqual(perri.at, ISO8601DateFormatter().date(from: "2026-11-14T11:45:00Z"))
        }
    }

    func testAnUnknownVerdictIsUnknownNeverApproved() throws {
        for wire: Any in ["merge", "APPROVED", "approve", "", NSNull(), 1] {
            let perri = try XCTUnwrap(try decodeRow(["perri": ["verdict": wire, "for_current_head": true]]).perri, "\(wire)")
            XCTAssertEqual(perri.verdict, .unknown, "\(wire)")
        }
        let missing = try XCTUnwrap(try decodeRow(["perri": ["for_current_head": true]]).perri)
        XCTAssertEqual(missing.verdict, .unknown)
    }

    func testAbsentForCurrentHeadMeansNotForTheCurrentHead() throws {
        XCTAssertFalse(try XCTUnwrap(try decodeRow(["perri": ["verdict": "approved"]]).perri).forCurrentHead)
        XCTAssertFalse(try XCTUnwrap(try decodeRow(["perri": ["verdict": "approved", "for_current_head": "yes"]]).perri).forCurrentHead)
        XCTAssertFalse(try XCTUnwrap(try decodeRow(["perri": ["verdict": "approved", "for_current_head": 1]]).perri).forCurrentHead)
        XCTAssertFalse(try XCTUnwrap(try decodeRow(["perri": ["verdict": "approved", "for_current_head": NSNull()]]).perri).forCurrentHead)
        XCTAssertTrue(try XCTUnwrap(try decodeRow(["perri": ["verdict": "approved", "for_current_head": true]]).perri).forCurrentHead)
    }

    func testTheNameOfWhoRecordedItIsCleanedAndCut() throws {
        let long = String(repeating: "x", count: 500)
        let by = try XCTUnwrap(try decodeRow(["perri": ["verdict": "comment", "by": long]]).perri?.by)
        XCTAssertLessThanOrEqual(by.count, AuthoredPrsBounds.name)
        XCTAssertFalse(by.isEmpty)

        let dirty = try XCTUnwrap(try decodeRow(["perri": ["verdict": "comment", "by": "pe\u{0}rri\u{202E}:a\nb\u{7}"]]).perri?.by)
        XCTAssertFalse(dirty.unicodeScalars.contains { $0.properties.generalCategory == .control || $0.value == 0x202E },
                       "\(dirty.debugDescription)")
        XCTAssertTrue(dirty.hasPrefix("perri"))

        XCTAssertNil(try decodeRow(["perri": ["verdict": "comment", "by": ""]]).perri?.by, "an empty name is no name")
        XCTAssertNil(try decodeRow(["perri": ["verdict": "comment", "by": "\n\t"]]).perri?.by)
        XCTAssertNil(try decodeRow(["perri": ["verdict": "comment"]]).perri?.by)
    }

    func testARowWithAGarbagePerriStillDecodesWithPerriAbsent() throws {
        for garbage: Any in ["approved", 5, [1, 2], true, NSNull()] {
            let row = try decodeRow(["perri": garbage, "head_sha_short": "0123abcd"])
            XCTAssertNil(row.perri, "\(garbage)")
            XCTAssertEqual(row.headShaShort, "0123abcd", "the rest of the row survives \(garbage)")
            XCTAssertEqual(row.title, "T")
        }
    }

    func testTheDaemonsGoldenFrameDecodesEveryKindOfRow() throws {
        let frame = try JSONDecoder().decode(AuthoredPrsFrame.self, from: try fixture("frame-authored-prs-perri.json"))
        let rows = frame.snapshot.prs
        XCTAssertEqual(rows.count, 6)
        func row(_ n: Int) throws -> AuthoredPr { try XCTUnwrap(rows.first { $0.number == n }) }

        XCTAssertEqual(try row(1).headShaShort, "0123abcd")
        XCTAssertEqual(try row(1).perri, AuthoredPrPerri(verdict: .approved,
                                                         at: ISO8601DateFormatter().date(from: "2026-11-14T11:45:00Z"),
                                                         by: "perri:cody-pr-1", forCurrentHead: true))
        XCTAssertEqual(try row(2).perri?.verdict, .changesRequested)
        XCTAssertEqual(try row(2).perri?.forCurrentHead, true)
        XCTAssertNil(try row(2).perri?.by)
        XCTAssertEqual(try row(3).perri?.verdict, .comment)
        XCTAssertEqual(try row(3).perri?.forCurrentHead, false)
        XCTAssertEqual(try row(4).perri?.verdict, .approved)
        XCTAssertEqual(try row(4).perri?.forCurrentHead, false)
        XCTAssertEqual(try row(5).headShaShort, "abcdef01")
        XCTAssertNil(try row(5).perri)
        XCTAssertNil(try row(6).headShaShort)
        XCTAssertNil(try row(6).perri)
    }
}

// MARK: - The merge request and its answer

final class AuthoredPrsMergeWireTests: XCTestCase {

    func testTheFeatureFlagsAreTheDaemonsStrings() {
        XCTAssertEqual(authoredPrsPerriFeature, "authored_prs_perri_v1")
        XCTAssertEqual(authoredPrsMergeFeature, "authored_prs_merge_v1")
    }

    func testTheMergeRequestHasExactlyTheDocumentedKeys() throws {
        let request = ClientAuthoredPrMerge(requestId: "r7", repo: "thehammer/nostromo", number: 458,
                                            expectedHeadShaShort: "0123abcd")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["type", "request_id", "repo", "number", "expected_head_sha_short"])
        XCTAssertEqual(object["type"] as? String, "authored_pr_merge")
        XCTAssertEqual(object["request_id"] as? String, "r7")
        XCTAssertEqual(object["repo"] as? String, "thehammer/nostromo")
        XCTAssertEqual(object["number"] as? Int, 458)
        XCTAssertEqual(object["expected_head_sha_short"] as? String, "0123abcd")
    }

    func testTheMergeRequestIsWhatTheDaemonsGoldenSays() throws {
        let request = ClientAuthoredPrMerge(requestId: "r7", repo: "thehammer/nostromo", number: 458,
                                            expectedHeadShaShort: "0123abcd")
        let encoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? NSDictionary)
        let golden = try XCTUnwrap(try JSONSerialization.jsonObject(with: try fixture("frame-authored-pr-merge.json")) as? NSDictionary)
        XCTAssertEqual(encoded, golden)
    }

    func testTheDaemonsGoldenAnswersDecode() throws {
        XCTAssertEqual(AuthoredPrAnswerFrame.decode(try fixture("frame-authored-pr-merge-result.json")),
                       .merge(requestId: "r7", .ok(AuthoredPrDone())))
        XCTAssertEqual(AuthoredPrAnswerFrame.decode(try fixture("frame-authored-pr-merge-result-error.json")),
                       .merge(requestId: "r7", .failed(code: "perri_stale")))
    }

    func testAnOkAnswerIsASuccess() throws {
        XCTAssertEqual(try answer(["status": "ok", "value": [String: Any]()]), .ok(AuthoredPrDone()))
        XCTAssertNil(try answer(["status": "ok", "value": [String: Any]()])?.mergeFailure)
    }

    func testEveryFailureCodeOfTheDaemonDecodesToItsOwnCase() throws {
        let table: [(String, AuthoredPrMergeCode)] = [
            ("not_found", .notFound), ("not_open", .notOpen), ("draft", .draft), ("not_approved", .notApproved),
            ("checks_not_green", .checksNotGreen), ("not_mergeable", .notMergeable), ("blocked", .blocked),
            ("behind", .behind), ("head_changed", .headChanged), ("perri_not_approved", .perriNotApproved),
            ("perri_stale", .perriStale), ("token_cannot_merge", .tokenCannotMerge), ("rate_limited", .rateLimited),
            ("unreachable", .unreachable), ("busy", .busy), ("not_permitted", .notPermitted),
        ]
        XCTAssertEqual(table.count, 16, "the daemon has 17 codes, `ok` is the success")
        XCTAssertEqual(Set(table.map { $0.1.hashable }).count, 16, "each code is its own case")
        for (wire, want) in table {
            let a = try XCTUnwrap(try answer(err(wire)), wire)
            XCTAssertEqual(a, .failed(code: wire))
            XCTAssertEqual(a.mergeFailure, want, wire)
            XCTAssertEqual(AuthoredPrMergeCode(wire: wire), want, wire)
        }
    }

    func testAnUnknownCodeIsAGenericFailureNeverSuccess() throws {
        for wire in ["merged", "success", "ok", "OK", "", "not_a_code", "head_changed ", "Draft", "perri-stale"] {
            let a = try XCTUnwrap(try answer(err(wire)), wire)
            XCTAssertEqual(a.mergeFailure, .unknown, "\(wire.debugDescription)")
            XCTAssertNotEqual(a, .ok(AuthoredPrDone()))
        }
        // An error with no code at all, or a status the Kit does not know, is a failure too.
        XCTAssertEqual(try answer(["status": "err"])?.mergeFailure, .unknown)
        XCTAssertEqual(try answer(["status": "err", "value": [String: Any]()])?.mergeFailure, .unknown)
        XCTAssertEqual(try answer(["status": "merged", "value": [String: Any]()])?.mergeFailure, .unknown)
        XCTAssertEqual(try answer(["status": "OK", "value": [String: Any]()])?.mergeFailure, .unknown)
    }

    func testARefusalOfThePeerIsNotPermitted() throws {
        for wire in ["not_permitted", "not_operator_app", "requires_secure_connection"] {
            XCTAssertEqual(try answer(err(wire))?.mergeFailure, .notPermitted, wire)
        }
    }

    func testMalformedMergeAnswersAreNotFrames() throws {
        let bad: [[String: Any]] = [
            ["type": "authored_pr_merge_result", "request_id": "r7"],
            ["type": "authored_pr_merge_result", "request_id": "r7", "result": "ok"],
            ["type": "authored_pr_merge_result", "request_id": "r7", "result": ["status": "ok"]],
            ["type": "authored_pr_merge_result", "request_id": "r7", "result": [String: Any]()],
            ["type": "authored_pr_merge_result", "result": ["status": "ok", "value": [String: Any]()]],
            ["type": "authored_pr_merge_result", "request_id": 7, "result": ["status": "ok", "value": [String: Any]()]],
            ["type": "authored_pr_merge", "request_id": "r7", "result": ["status": "ok", "value": [String: Any]()]],
            ["type": "authored_pr_merge_results", "request_id": "r7", "result": ["status": "ok", "value": [String: Any]()]],
        ]
        for object in bad {
            XCTAssertNil(AuthoredPrAnswerFrame.decode(try jsonData(object)), "\(object)")
        }
        XCTAssertNil(AuthoredPrAnswerFrame.decode(Data("not json".utf8)))
        XCTAssertNil(AuthoredPrAnswerFrame.decode(Data()))
    }

    func testTheRequestIdOfAMergeFrameIsReadFromTheFrame() throws {
        let frame = try XCTUnwrap(AuthoredPrAnswerFrame.decode(try mergeFrame(err("busy"), id: "req-42")))
        XCTAssertEqual(frame.requestId, "req-42")
        XCTAssertEqual(frame, .merge(requestId: "req-42", .failed(code: "busy")))
        XCTAssertEqual(AuthoredPrAnswerFrame.merge(requestId: "x", .ok(AuthoredPrDone())).requestId, "x")
    }

    func testAMergeAnswerIsNotTakenForTheAnswerOfAnotherVerb() throws {
        // Same shape, another type: a link or notify answer is never a merge answer.
        for type in ["authored_pr_link_result", "authored_pr_notify_result"] {
            let data = try jsonData(["type": type, "request_id": "r7",
                                     "result": ["status": "ok", "value": [String: Any]()]])
            if case .merge? = AuthoredPrAnswerFrame.decode(data) { XCTFail("\(type) read as a merge answer") }
        }
    }

    func testTheMergeFailureOfAnAnswer() {
        XCTAssertNil(AuthoredPrAnswer<AuthoredPrDone>.ok(AuthoredPrDone()).mergeFailure)
        XCTAssertEqual(AuthoredPrAnswer<AuthoredPrDone>.unreachable.mergeFailure, .unreachable,
                       "the daemon never answered")
        XCTAssertEqual(AuthoredPrAnswer<AuthoredPrDone>.failed(code: "behind").mergeFailure, .behind)
        XCTAssertEqual(AuthoredPrAnswer<AuthoredPrDone>.failed(code: "what").mergeFailure, .unknown)
    }

    func testEveryCodeHasItsOwnNonEmptyWords() {
        let all: [AuthoredPrMergeCode] = [
            .notFound, .notOpen, .draft, .notApproved, .checksNotGreen, .notMergeable, .blocked, .behind,
            .headChanged, .perriNotApproved, .perriStale, .tokenCannotMerge, .rateLimited, .unreachable, .busy,
            .notPermitted, .unknown,
        ]
        var seen = Set<String>()
        for code in all {
            let words = AuthoredPrsMergeWords.failure(code)
            XCTAssertFalse(words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(code)")
            XCTAssertTrue(seen.insert(words).inserted, "\(code) shares its words with another code: \(words)")
        }
        XCTAssertEqual(seen.count, 17)
    }

    func testTheWordsNeverCarryTheDaemonsCodeOrAnything() {
        // The words are the app's own: they hold no wire code and no placeholder.
        for wire in ["not_found", "not_open", "checks_not_green", "head_changed", "perri_stale", "perri_not_approved"] {
            let words = AuthoredPrsMergeWords.failure(AuthoredPrMergeCode(wire: wire))
            XCTAssertFalse(words.contains("_"), words)
            XCTAssertFalse(words.contains("%"), words)
        }
    }

    func testTheValuesCrossAConcurrencyBoundary() async {
        // `Sendable`: this only compiles when each of these is.
        let frame = AuthoredPrAnswerFrame.merge(requestId: "r", .failed(code: "busy"))
        let code = AuthoredPrMergeCode.perriStale
        let perri = AuthoredPrPerri(verdict: .approved, forCurrentHead: true)
        let readiness = AuthoredPrsPresentation.MergeReadiness.perriNotApproved(.olderVersion)
        let answer = AuthoredPrAnswer<AuthoredPrDone>.unreachable
        let result = await Task.detached { @Sendable () -> (AuthoredPrAnswerFrame, AuthoredPrMergeCode, AuthoredPrPerri,
                                                            AuthoredPrsPresentation.MergeReadiness,
                                                            AuthoredPrAnswer<AuthoredPrDone>) in
            (frame, code, perri, readiness, answer)
        }.value
        XCTAssertEqual(result.0, frame)
        XCTAssertEqual(result.1, code)
        XCTAssertEqual(result.2, perri)
        XCTAssertEqual(result.3, readiness)
        XCTAssertEqual(result.4, answer)
    }
}

private extension AuthoredPrMergeCode {
    /// A stable name for a case, to count distinct cases.
    var hashable: String { "\(self)" }
}

// MARK: - When the Merge button is offered

final class AuthoredPrsMergeReadinessTests: XCTestCase {

    private typealias Readiness = AuthoredPrsPresentation.MergeReadiness

    /// A PR that may be merged: open, not a draft, green, approved by a human, Perri approved this head.
    private func pr(lifecycle: AuthoredPrLifecycle = .open, draft: Bool = false,
                    checks: AuthoredPrChecksState = .passing, review: AuthoredPrReviewState = .approved,
                    perri: AuthoredPrPerri? = AuthoredPrPerri(verdict: .approved, forCurrentHead: true),
                    head: String? = "0123abcd") -> AuthoredPr {
        AuthoredPr(repo: "o/r", number: 1, url: "https://github.com/o/r/pull/1", title: "T", draft: draft,
                   updatedAt: nil, group: .ready, lifecycle: lifecycle,
                   checks: AuthoredPrChecks(state: checks), review: AuthoredPrReview(state: review),
                   headShaShort: head, perri: perri)
    }

    private func perri(_ verdict: AuthoredPrPerriVerdict, current: Bool) -> AuthoredPrPerri {
        AuthoredPrPerri(verdict: verdict, forCurrentHead: current)
    }

    func testAnOpenGreenApprovedPrThatPerriApprovedAtThisHeadIsReady() {
        XCTAssertEqual(AuthoredPrsPresentation.mergeReadiness(pr()), .ready)
        XCTAssertTrue(Readiness.ready.isReady)
        // No checks at all is fine too.
        XCTAssertEqual(AuthoredPrsPresentation.mergeReadiness(pr(checks: .none)), .ready)
    }

    func testMergeReadinessOfALifecycleThatIsNotOpen() {
        for lifecycle in [AuthoredPrLifecycle.merged, .closed] {
            XCTAssertEqual(AuthoredPrsPresentation.mergeReadiness(pr(lifecycle: lifecycle)), .mergedOrClosed)
        }
        // Whatever else holds, it is the first thing said.
        let everythingWrong = pr(lifecycle: .merged, draft: true, checks: .failing, review: .changesRequested,
                                 perri: nil, head: nil)
        XCTAssertEqual(AuthoredPrsPresentation.mergeReadiness(everythingWrong), .mergedOrClosed)
        XCTAssertEqual(AuthoredPrsPresentation.mergeReadiness(pr(lifecycle: .closed, draft: true)), .mergedOrClosed)
        // A lifecycle this build does not know is not open either.
        XCTAssertNotEqual(AuthoredPrsPresentation.mergeReadiness(pr(lifecycle: .unknown)), .ready)
    }

    func testADraftIsNotReady() {
        XCTAssertEqual(AuthoredPrsPresentation.mergeReadiness(pr(draft: true)), .draft)
    }

    func testChecksThatAreNotPassingAreNotReadyButPassingOrNoneAre() {
        for state in [AuthoredPrChecksState.failing, .pending, .unknown] {
            XCTAssertEqual(AuthoredPrsPresentation.mergeReadiness(pr(checks: state)), .checksNotGreen, "\(state)")
        }
        for state in [AuthoredPrChecksState.passing, .none] {
            XCTAssertEqual(AuthoredPrsPresentation.mergeReadiness(pr(checks: state)), .ready, "\(state)")
        }
    }

    func testWithoutAHumanApprovalItIsNotReady() {
        for review in [AuthoredPrReviewState.none, .changesRequested, .reviewRequested, .unknown] {
            XCTAssertEqual(AuthoredPrsPresentation.mergeReadiness(pr(review: review)), .humanApprovalMissing, "\(review)")
        }
    }

    func testWithoutPerrisApprovalOfThisHeadItIsNotReady() {
        XCTAssertEqual(AuthoredPrsPresentation.mergeReadiness(pr(perri: nil)), .perriNotApproved(.none))
        // Approved, but for an older version: never approval of this one.
        XCTAssertEqual(AuthoredPrsPresentation.mergeReadiness(pr(perri: perri(.approved, current: false))),
                       .perriNotApproved(.olderVersion))
        XCTAssertEqual(AuthoredPrsPresentation.mergeReadiness(pr(perri: perri(.changesRequested, current: false))),
                       .perriNotApproved(.olderVersion))
        XCTAssertEqual(AuthoredPrsPresentation.mergeReadiness(pr(perri: perri(.comment, current: false))),
                       .perriNotApproved(.olderVersion))
        // Asked for changes to this version.
        XCTAssertEqual(AuthoredPrsPresentation.mergeReadiness(pr(perri: perri(.changesRequested, current: true))),
                       .perriNotApproved(.changesRequested))
        // Only commented, or a verdict this build does not know.
        XCTAssertEqual(AuthoredPrsPresentation.mergeReadiness(pr(perri: perri(.comment, current: true))),
                       .perriNotApproved(.none))
        XCTAssertEqual(AuthoredPrsPresentation.mergeReadiness(pr(perri: perri(.unknown, current: true))),
                       .perriNotApproved(.none))
    }

    func testAnApprovalAtTheCurrentHeadIsNotEnoughWithoutTheHeadToEcho() {
        XCTAssertEqual(AuthoredPrsPresentation.mergeReadiness(pr(head: nil)), .perriNotApproved(.none))
    }

    func testWhenSeveralReasonsHoldTheFirstInTheDocumentedOrderIsSaid() {
        // draft beats checks beats human approval beats Perri.
        XCTAssertEqual(AuthoredPrsPresentation.mergeReadiness(
            pr(draft: true, checks: .failing, review: .none, perri: nil)), .draft)
        XCTAssertEqual(AuthoredPrsPresentation.mergeReadiness(
            pr(checks: .failing, review: .none, perri: nil)), .checksNotGreen)
        XCTAssertEqual(AuthoredPrsPresentation.mergeReadiness(
            pr(checks: .pending, review: .changesRequested, perri: perri(.changesRequested, current: false))),
                       .checksNotGreen)
        XCTAssertEqual(AuthoredPrsPresentation.mergeReadiness(
            pr(review: .reviewRequested, perri: perri(.changesRequested, current: true))), .humanApprovalMissing)
        XCTAssertEqual(AuthoredPrsPresentation.mergeReadiness(
            pr(review: .none, perri: nil, head: nil)), .humanApprovalMissing)
        // Perri's reasons: an older version is said before what the verdict was.
        XCTAssertEqual(AuthoredPrsPresentation.mergeReadiness(
            pr(perri: perri(.changesRequested, current: false), head: nil)), .perriNotApproved(.olderVersion))
    }

    func testOnlyReadyIsReady() {
        let others: [Readiness] = [.draft, .checksNotGreen, .humanApprovalMissing, .perriNotApproved(.none),
                                   .perriNotApproved(.olderVersion), .perriNotApproved(.changesRequested),
                                   .mergedOrClosed]
        for other in others { XCTAssertFalse(other.isReady, "\(other)") }
    }

    /// Every combination of the inputs: ready exactly when all of them allow it, so no input can be left out.
    func testReadyExactlyWhenEveryRuleHolds() {
        let lifecycles: [AuthoredPrLifecycle] = [.open, .merged, .closed, .unknown]
        let checks: [AuthoredPrChecksState] = [.passing, .none, .failing, .pending, .unknown]
        let reviews: [AuthoredPrReviewState] = [.approved, .none, .changesRequested, .reviewRequested, .unknown]
        let verdicts: [AuthoredPrPerri?] = [nil] + [AuthoredPrPerriVerdict.approved, .changesRequested, .comment, .unknown]
            .flatMap { v in [true, false].map { AuthoredPrPerri(verdict: v, forCurrentHead: $0) } }
        for lifecycle in lifecycles { for draft in [false, true] { for c in checks { for r in reviews {
            for v in verdicts { for head in [String?.none, "0123abcd"] {
                let row = pr(lifecycle: lifecycle, draft: draft, checks: c, review: r, perri: v, head: head)
                let allows = lifecycle == .open && !draft && (c == .passing || c == .none) && r == .approved
                    && v?.verdict == .approved && v?.forCurrentHead == true && head != nil
                XCTAssertEqual(AuthoredPrsPresentation.mergeReadiness(row).isReady, allows,
                               "\(lifecycle) draft:\(draft) \(c) \(r) \(String(describing: v)) head:\(String(describing: head))")
            } }
        } } } }
    }
}
