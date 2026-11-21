// NostromoKit — AuthoredPrsMergeQueueTests.swift
//
// The merge queue, as the Kit sees it (feature `authored_prs_merge_queue_v1`): the two additive row fields
// (`merge_via`, `queue`), the request's `expected_via`, the answers `queued` / `already_queued` and the other
// queue codes, when the button is offered and how it is worded, the confirmation sentence per path, and the
// "In merge queue" and "dropped" row states. The daemon enforces every rule again; here the question is only what
// the app decodes, sends and shows.
//
// The goldens under `tests/fixtures/authored_prs/` are written by the daemon's own Rust types.
//
// Mutations this file is meant to catch:
//   1. A queue row offered a (squash-and-merge) button by an app that did not hear `authored_prs_merge_queue_v1`
//        -> testAQueueRowIsNotReadyWithoutTheFeature
//   2. An unknown or absent `merge_via` read as `direct` once the feature is there
//        -> testAnUnknownOrMissingWayInIsNotReadyOnADaemonThatKnowsQueues, testAnUnknownMergeViaIsNeverDirect
//   3. The queue confirmation worded as a squash merge (or the reverse)
//        -> testTheConfirmationSaysWhichWayThePrGoesIn
//   4. `expected_via` sent for a direct merge (an older request is no longer byte-identical) or dropped for a queue
//        -> testTheRequestSaysQueueOnlyForAQueue
//   5. `queued` read as a merge (or any other success read as queued)
//        -> testQueuedIsNotAMerge
//   6. "Dropped from the merge queue" shown before the entry was ever seen, or never shown after
//        -> testAnAttemptIsDroppedOnlyAfterItsEntryWasSeen
//   7. A queued attempt regrouping the row
//        -> testAnAttemptNeverMovesARowBetweenGroups (AuthoredPrsMergeUITests) and testQueuedNeverRegroups

import XCTest
@testable import NostromoKit

private func fixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("tests/fixtures/authored_prs/\(name)")
    return try Data(contentsOf: url)
}

private func jsonData(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

private func decodeRow(_ overrides: [String: Any] = [:]) throws -> AuthoredPr {
    var d: [String: Any] = ["repo": "o/r", "number": 1, "title": "T", "group": "waiting", "lifecycle": "open"]
    d.merge(overrides) { _, new in new }
    let frame = try jsonData(["type": "authored_prs", "snapshot": ["prs": [d]]])
    return try XCTUnwrap(try JSONDecoder().decode(AuthoredPrsFrame.self, from: frame).snapshot.prs.first)
}

private func pr(via: AuthoredPrMergeVia? = .queue, queue: AuthoredPrQueue? = nil, number: Int = 458,
                baseRef: String? = "main", title: String = "Fix the thing", group: AuthoredPrGroup = .ready,
                perriBy: String = "perri:cody-pr-1") -> AuthoredPr {
    AuthoredPr(repo: "thehammer/nostromo", number: number, title: title, group: group, lifecycle: .open,
               baseRef: baseRef, checks: AuthoredPrChecks(state: .passing, passed: 3),
               review: AuthoredPrReview(state: .approved, logins: ["dana"]), headShaShort: "0123abcd",
               perri: AuthoredPrPerri(verdict: .approved, by: perriBy, forCurrentHead: true),
               mergeVia: via, queue: queue)
}

private func answer(_ result: [String: Any]) throws -> AuthoredPrAnswer<AuthoredPrDone>? {
    let data = try jsonData(["type": "authored_pr_merge_result", "request_id": "r8", "result": result])
    guard case .merge(_, let answer)? = AuthoredPrAnswerFrame.decode(data) else { return nil }
    return answer
}

final class AuthoredPrsMergeQueueWireTests: XCTestCase {

    func testTheFeatureIsNamedAsTheDaemonNamesIt() {
        XCTAssertEqual(authoredPrsMergeQueueFeature, "authored_prs_merge_queue_v1")
    }

    func testTheDaemonsGoldenRowsDecode() throws {
        let data = try fixture("frame-authored-prs-merge-queue.json")
        let rows = try JSONDecoder().decode(AuthoredPrsFrame.self, from: data).snapshot.prs
        XCTAssertEqual(rows.map(\.mergeVia), [.direct, .queue, .queue, .queue, nil])
        XCTAssertEqual(rows.map(\.queue), [nil, nil, AuthoredPrQueue(state: .queued, position: 2),
                                           AuthoredPrQueue(state: .awaitingChecks, position: nil), nil])
    }

    func testAnOldDaemonsRowsHaveNeitherField() throws {
        let row = try decodeRow()
        XCTAssertNil(row.mergeVia)
        XCTAssertNil(row.queue)
    }

    func testAnUnknownMergeViaIsNeverDirect() throws {
        XCTAssertEqual(try decodeRow(["merge_via": "direct"]).mergeVia, .direct)
        XCTAssertEqual(try decodeRow(["merge_via": "queue"]).mergeVia, .queue)
        for odd: Any in ["merge_train", "", "Queue", "DIRECT", 3, true, ["queue"]] {
            let via = try decodeRow(["merge_via": odd]).mergeVia
            XCTAssertEqual(via, .unknown, "\(odd) must not read as anything the app acts on")
        }
        XCTAssertNil(try decodeRow(["merge_via": NSNull()]).mergeVia)
    }

    func testTheQueueEntryIsBoundedAndTolerant() throws {
        let q = try XCTUnwrap(try decodeRow(["queue": ["state": "awaiting_checks", "position": 3]]).queue)
        XCTAssertEqual(q, AuthoredPrQueue(state: .awaitingChecks, position: 3))
        XCTAssertEqual(try decodeRow(["queue": ["state": "queued", "position": 4_000_000]]).queue?.position, 9999)
        for bad: Any in [0, -2, "2", 1.5, NSNull()] {
            XCTAssertNil(try decodeRow(["queue": ["state": "queued", "position": bad]]).queue?.position, "\(bad)")
        }
        XCTAssertEqual(try decodeRow(["queue": ["state": "something_new"]]).queue?.state, .unknown)
        XCTAssertNil(try decodeRow(["queue": "queued"]).queue, "a malformed entry is no entry")
    }

    func testTheRequestSaysQueueOnlyForAQueue() throws {
        func json(_ via: AuthoredPrMergeVia?) throws -> NSDictionary {
            let r = ClientAuthoredPrMerge(requestId: via == .queue ? "r8" : "r7", repo: "thehammer/nostromo", number: 458,
                                          expectedHeadShaShort: "0123abcd", expectedVia: via)
            return try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? NSDictionary)
        }
        // A direct request is exactly what an older build sent (the daemon's golden for it).
        let direct = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: try fixture("frame-authored-pr-merge.json")) as? NSDictionary)
        XCTAssertEqual(try json(nil), direct)
        XCTAssertEqual(try json(.direct), direct)
        XCTAssertEqual(try json(.unknown), direct, "an unknown way is never sent")
        let queue = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: try fixture("frame-authored-pr-merge-queue.json")) as? NSDictionary)
        XCTAssertEqual(try json(.queue), queue)
        XCTAssertEqual(queue["expected_via"] as? String, "queue")
    }

    func testQueuedIsNotAMerge() throws {
        let golden = try XCTUnwrap(AuthoredPrAnswerFrame.decode(try fixture("frame-authored-pr-merge-result-queued.json")))
        XCTAssertEqual(golden, .merge(requestId: "r8", .ok(AuthoredPrDone(queued: true))))
        let ok = try XCTUnwrap(try answer(["status": "ok", "value": [String: Any]()]))
        XCTAssertFalse(ok.mergeQueued)
        XCTAssertTrue(try XCTUnwrap(try answer(["status": "ok", "value": ["code": "queued"]])).mergeQueued)
        for code: Any in ["merged", "Queued", "", 1, NSNull()] {
            XCTAssertFalse(try XCTUnwrap(try answer(["status": "ok", "value": ["code": code]])).mergeQueued, "\(code)")
        }
        XCTAssertFalse(AuthoredPrAnswer<AuthoredPrDone>.failed(code: "queued").mergeQueued, "a failure is not a queue")
        XCTAssertEqual(AuthoredPrAnswer<AuthoredPrDone>.failed(code: "queued").mergeFailure, .unknown)
    }

    func testTheQueueCodesDecodeToTheirOwnCasesWithTheirOwnWords() throws {
        let table: [(String, AuthoredPrMergeCode)] = [
            ("already_queued", .alreadyQueued), ("queue_refused", .queueRefused),
            ("queue_unknown", .queueUnknown), ("via_changed", .viaChanged),
        ]
        var words = Set<String>()
        for (wire, want) in table {
            XCTAssertEqual(AuthoredPrMergeCode(wire: wire), want, wire)
            XCTAssertEqual(try answer(["status": "err", "value": ["code": wire]])?.mergeFailure, want, wire)
            XCTAssertTrue(words.insert(AuthoredPrsMergeWords.failure(want)).inserted, wire)
        }
        XCTAssertEqual(AuthoredPrsMergeWords.failure(.droppedFromQueue), "Dropped from the merge queue")
        XCTAssertEqual(AuthoredPrMergeCode(wire: "dropped_from_queue"), .unknown, "dropped is never a daemon answer")
        // None of GitHub's words, and none of the success words, in a refusal.
        XCTAssertFalse(AuthoredPrsMergeWords.failure(.queueRefused).contains("merged"))
    }
}

final class AuthoredPrsMergeQueueUITests: XCTestCase {

    func testAQueueRowIsNotReadyWithoutTheFeature() {
        let row = pr(via: .queue)
        XCTAssertEqual(AuthoredPrsPresentation.mergeReadiness(row), .queueNeedsUpdate)
        XCTAssertEqual(AuthoredPrsPresentation.mergeReadiness(row, queueSupported: false), .queueNeedsUpdate)
        XCTAssertEqual(AuthoredPrsPresentation.mergeReadiness(row, queueSupported: true), .ready)
        let button = AuthoredPrsPresentation.mergeButton(row, queueSupported: false)
        XCTAssertEqual(button?.state, .unavailable)
        XCTAssertEqual(button?.isEnabled, false)
        XCTAssertEqual(button?.reason, "Update Nostromo to merge into a merge queue")
        XCTAssertNil(button?.confirmation, "nothing that is not ready can lead to a request")
        XCTAssertNil(AuthoredPrsPresentation.mergeConfirmation(row, queueSupported: false))
    }

    func testAnUnknownOrMissingWayInIsNotReadyOnADaemonThatKnowsQueues() {
        XCTAssertEqual(AuthoredPrsPresentation.mergeReadiness(pr(via: .unknown), queueSupported: true), .mergeMethodUnknown)
        XCTAssertEqual(AuthoredPrsPresentation.mergeReadiness(pr(via: .unknown), queueSupported: false), .mergeMethodUnknown)
        XCTAssertEqual(AuthoredPrsPresentation.mergeReadiness(pr(via: nil), queueSupported: true), .mergeMethodUnknown)
        // An old daemon says nothing and only merges directly.
        XCTAssertEqual(AuthoredPrsPresentation.mergeReadiness(pr(via: nil), queueSupported: false), .ready)
        XCTAssertEqual(AuthoredPrsPresentation.mergeReadiness(pr(via: .direct), queueSupported: false), .ready)
        XCTAssertEqual(AuthoredPrsPresentation.mergeReadiness(pr(via: .direct), queueSupported: true), .ready)
    }

    func testEveryOtherRuleStillComesFirst() {
        // A queue row that is not otherwise ready says the other reason, not "update Nostromo".
        var row = pr(via: .queue)
        row.perri = nil
        XCTAssertEqual(AuthoredPrsPresentation.mergeReadiness(row), .perriNotApproved(.none))
        row = pr(via: .queue)
        row.draft = true
        XCTAssertEqual(AuthoredPrsPresentation.mergeReadiness(row), .draft)
        row = pr(via: .queue)
        row.review = AuthoredPrReview(state: .none)
        XCTAssertEqual(AuthoredPrsPresentation.mergeReadiness(row), .humanApprovalMissing)
    }

    func testTheConfirmationSaysWhichWayThePrGoesIn() throws {
        let queue = try XCTUnwrap(AuthoredPrsPresentation.mergeConfirmation(pr(via: .queue), queueSupported: true))
        XCTAssertEqual(queue.message, "Add #458 Fix the thing to the merge queue for main? Head 0123abcd. "
                       + "Perri approved. Human approval: yes. Checks: green.")
        XCTAssertEqual(queue.via, .queue)
        XCTAssertEqual(queue.confirmTitle, "Add to merge queue")
        let direct = try XCTUnwrap(AuthoredPrsPresentation.mergeConfirmation(pr(via: .direct), queueSupported: true))
        XCTAssertEqual(direct.message, "Squash and merge #458 Fix the thing into main? Head 0123abcd. "
                       + "Perri approved. Human approval: yes. Checks: green.")
        XCTAssertEqual(direct.via, .direct)
        XCTAssertEqual(direct.confirmTitle, "Merge")
        // An old daemon's row (no `merge_via`) is a direct merge, worded as before.
        let old = try XCTUnwrap(AuthoredPrsPresentation.mergeConfirmation(pr(via: nil)))
        XCTAssertEqual(old.message, direct.message)
        // No base shown (the default branch): "the base branch", as the direct sentence says.
        let noBase = try XCTUnwrap(AuthoredPrsPresentation.mergeConfirmation(pr(via: .queue, baseRef: nil), queueSupported: true))
        XCTAssertTrue(noBase.message.hasPrefix("Add #458 Fix the thing to the merge queue for the base branch? "), noBase.message)
    }

    func testTheQueueConfirmationKeepsTheApprovalRecorderWordingAndTheTitleRules() throws {
        let cody = try XCTUnwrap(AuthoredPrsPresentation.mergeConfirmation(
            pr(via: .queue, perriBy: "cody:cody-pr-1"), queueSupported: true))
        XCTAssertTrue(cody.message.contains("Approval recorded by cody:cody-pr-1, not by Perri."), cody.message)
        XCTAssertEqual(cody.approval, "Approval recorded by cody:cody-pr-1, not by Perri.")
        let long = try XCTUnwrap(AuthoredPrsPresentation.mergeConfirmation(
            pr(via: .queue, title: "line\none\u{202E}" + String(repeating: "x", count: 200)), queueSupported: true))
        XCTAssertFalse(long.message.contains("\n") || long.message.contains("\u{202E}"))
        XCTAssertTrue(long.message.contains("…"))
    }

    func testTheButtonIsWordedForTheWayIn() throws {
        let queue = try XCTUnwrap(AuthoredPrsPresentation.mergeButton(pr(via: .queue), queueSupported: true))
        XCTAssertEqual(queue.state, .ready)
        XCTAssertEqual(queue.title, "Add to merge queue")
        XCTAssertEqual(queue.accessibilityLabel, "Add PR 458 to the merge queue")
        XCTAssertTrue(queue.tooltip.contains("merge queue for main"), queue.tooltip)
        XCTAssertFalse(queue.tooltip.contains("Squash"), queue.tooltip)
        let direct = try XCTUnwrap(AuthoredPrsPresentation.mergeButton(pr(via: .direct), queueSupported: true))
        XCTAssertEqual(direct.title, "Merge")
        XCTAssertEqual(direct.accessibilityLabel, "Merge PR 458")
        XCTAssertTrue(direct.tooltip.hasPrefix("Squash and merge into main"))
    }

    func testAddingToTheQueueIsNotWordedAsMerging() throws {
        let attempt = AuthoredPrMergeAttempt(head: "0123abcd", progress: .merging)
        let queue = try XCTUnwrap(AuthoredPrsPresentation.mergeButton(pr(via: .queue), attempt: attempt, queueSupported: true))
        XCTAssertEqual(queue.state, .merging)
        XCTAssertEqual(queue.title, "Adding…")
        let direct = try XCTUnwrap(AuthoredPrsPresentation.mergeButton(pr(via: .direct), attempt: attempt, queueSupported: true))
        XCTAssertEqual(direct.title, "Merging…")
    }

    func testAQueuedAttemptAndAQueueEntryBothShowInMergeQueue() throws {
        let queuedAttempt = AuthoredPrMergeAttempt(head: "0123abcd", progress: .queued)
        let waiting = try XCTUnwrap(AuthoredPrsPresentation.mergeButton(pr(via: .queue), attempt: queuedAttempt,
                                                                        queueSupported: true))
        XCTAssertEqual(waiting.state, .queued)
        XCTAssertEqual(waiting.title, "In merge queue")
        XCTAssertFalse(waiting.isEnabled)
        XCTAssertNil(waiting.confirmation)
        XCTAssertEqual(waiting.accessibilityLabel, "PR 458: In merge queue")
        // The daemon's row says where it is: the same state with the position, and no attempt needed.
        let entry = AuthoredPrQueue(state: .queued, position: 2)
        let placed = try XCTUnwrap(AuthoredPrsPresentation.mergeButton(pr(via: .queue, queue: entry), queueSupported: true))
        XCTAssertEqual(placed.state, .queued)
        XCTAssertEqual(placed.title, "In merge queue (2)")
        XCTAssertEqual(placed.accessibilityLabel, "PR 458: In merge queue, position 2")
        XCTAssertTrue(placed.tooltip.contains("position 2"), placed.tooltip)
        // An app that did not hear the feature does not act on the field.
        XCTAssertEqual(AuthoredPrsPresentation.mergeButton(pr(via: .queue, queue: entry), queueSupported: false)?.state,
                       .unavailable)
    }

    func testEveryStateOfAQueueRowIsMarkedQueueSoTheRowGivesItOneWidth() throws {
        let entry = AuthoredPrQueue(state: .queued, position: 2)
        let rows: [(AuthoredPr, AuthoredPrMergeAttempt?)] = [
            (pr(via: .queue), nil),
            (pr(via: .queue), AuthoredPrMergeAttempt(head: "0123abcd", progress: .merging)),
            (pr(via: .queue), AuthoredPrMergeAttempt(head: "0123abcd", progress: .queued)),
            (pr(via: .queue, queue: entry), nil),
            (pr(via: .queue), AuthoredPrMergeAttempt(head: "0123abcd", progress: .failed(.droppedFromQueue))),
        ]
        for (row, attempt) in rows {
            XCTAssertEqual(AuthoredPrsPresentation.mergeButton(row, attempt: attempt, queueSupported: true)?.isQueue, true)
        }
        XCTAssertEqual(AuthoredPrsPresentation.mergeButton(pr(via: .queue), queueSupported: false)?.isQueue, true)
        for via: AuthoredPrMergeVia? in [.direct, nil] {
            XCTAssertEqual(AuthoredPrsPresentation.mergeButton(pr(via: via), queueSupported: true)?.isQueue, false)
        }
    }

    func testTheButtonTitlesStayShortEnoughForOneWidth() throws {
        // The Mac gives every state of the button one width; the longest title must fit it (see the Mac's
        // `mergeButtonWidth` and its test).
        let longest = ["Add to merge queue", "In merge queue (9999)", "In merge queue", "Merging…", "Adding…", "Merged", "Merge"]
        XCTAssertLessThanOrEqual(longest.map(\.count).max() ?? 0, 21)
    }

    func testAnAttemptIsDroppedOnlyAfterItsEntryWasSeen() {
        let queued = AuthoredPrMergeAttempt(head: "0123abcd", progress: .queued)
        let entry = AuthoredPrQueue(state: .queued, position: 1)
        // A snapshot older than the enqueue has no entry yet: keep waiting.
        XCTAssertEqual(AuthoredPrsPresentation.reconcile(queued, with: pr(via: .queue)), queued)
        // The entry shows: remembered.
        let seen = AuthoredPrsPresentation.reconcile(queued, with: pr(via: .queue, queue: entry))
        XCTAssertEqual(seen.progress, .queued)
        XCTAssertTrue(seen.sawQueueEntry)
        // It is still showing: nothing changes.
        XCTAssertEqual(AuthoredPrsPresentation.reconcile(seen, with: pr(via: .queue, queue: entry)), seen)
        // Then the PR is open and the entry is gone: dropped.
        let dropped = AuthoredPrsPresentation.reconcile(seen, with: pr(via: .queue))
        XCTAssertEqual(dropped.progress, .failed(.droppedFromQueue))
        XCTAssertEqual(dropped.head, "0123abcd")
        // Merged (or closed) is not dropped: the row says what happened itself.
        var merged = pr(via: .queue)
        merged.lifecycle = .merged
        XCTAssertEqual(AuthoredPrsPresentation.reconcile(seen, with: merged), seen)
        // Other attempts are untouched.
        for progress: AuthoredPrMergeProgress in [.merging, .merged, .failed(.busy)] {
            let a = AuthoredPrMergeAttempt(head: "0123abcd", progress: progress, sawQueueEntry: true)
            XCTAssertEqual(AuthoredPrsPresentation.reconcile(a, with: pr(via: .queue)), a)
        }
    }

    func testADroppedAttemptShowsTheNoticeAndTheButtonIsAvailableAgain() throws {
        let dropped = AuthoredPrMergeAttempt(head: "0123abcd", progress: .failed(.droppedFromQueue), sawQueueEntry: true)
        let row = pr(via: .queue)
        XCTAssertEqual(AuthoredPrsPresentation.mergeNotice(row, attempt: dropped), "Dropped from the merge queue")
        let button = try XCTUnwrap(AuthoredPrsPresentation.mergeButton(row, attempt: dropped, queueSupported: true))
        XCTAssertEqual(button.state, .ready, "available again")
        XCTAssertEqual(button.title, "Add to merge queue")
        XCTAssertNotNil(button.confirmation)
        // A push since is another head: the old notice is not about this row.
        var moved = row
        moved.headShaShort = "89abcdef"
        XCTAssertNil(AuthoredPrsPresentation.mergeNotice(moved, attempt: dropped))
    }

    func testQueuedNeverRegroups() {
        let queued = AuthoredPrMergeAttempt(head: "0123abcd", progress: .queued)
        let rows = [pr(via: .queue, number: 1), pr(via: .queue, number: 2, group: .needsYou)]
        let plain = AuthoredPrsPresentation.groups(rows, now: Date(), timeZone: TimeZone(identifier: "UTC")!,
                                                   perri: true, merge: true, mergeQueue: true)
        let withAttempts = AuthoredPrsPresentation.groups(
            rows, now: Date(), timeZone: TimeZone(identifier: "UTC")!, perri: true, merge: true, mergeQueue: true,
            mergeAttempts: [rows[0].id: queued, rows[1].id: queued])
        XCTAssertEqual(plain.map { $0.group }, withAttempts.map { $0.group })
        XCTAssertEqual(plain.map { $0.rows.map(\.id) }, withAttempts.map { $0.rows.map(\.id) })
    }

    func testTheRowThreadsTheQueueFlagAndTheReasonShowsOnTheReviewLine() throws {
        let now = Date()
        let off = AuthoredPrsPresentation.row(pr(via: .queue), now: now, perri: true, merge: true, mergeQueue: false)
        XCTAssertEqual(off.mergeButton?.state, .unavailable)
        XCTAssertTrue(off.reviewLine.contains("Update Nostromo to merge into a merge queue"), off.reviewLine)
        let on = AuthoredPrsPresentation.row(pr(via: .queue), now: now, perri: true, merge: true, mergeQueue: true)
        XCTAssertEqual(on.mergeButton?.state, .ready)
        XCTAssertEqual(on.mergeButton?.title, "Add to merge queue")
        XCTAssertFalse(on.reviewLine.contains("Update Nostromo"))
    }
}
