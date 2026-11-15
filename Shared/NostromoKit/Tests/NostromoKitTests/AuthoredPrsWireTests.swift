// NostromoKit — AuthoredPrsWireTests.swift
//
// The `authored_prs` frame (feature `authored_prs_v1`): `{"type":"authored_prs","snapshot":{…}}`.
// Decoding is lenient on purpose: an unknown enum value becomes `.unknown`, a missing optional is
// nil/empty/zero, a row that cannot be decoded is dropped while the others stay, and everything that
// came from GitHub is stripped of control and bidi characters and cut to the daemon's bounds.
//
// The golden `tests/fixtures/authored_prs/frame-authored-prs.json` is written by the daemon's own
// Rust types; reading it here keeps the Kit honest about what the daemon really sends.
//
// Mutations this file (with AuthoredPrsPresentationTests.swift) is meant to catch:
//   1. Format ages from receipt time instead of `checked_at`
//        -> AuthoredPrsPresentationTests.testOtherReposAgeComesFromCheckedAtAndTheInjectedClock
//   2. Drop the `+N more` cap on failing check names
//        -> AuthoredPrsPresentationTests.testFiveFailingChecksWithFiveNamesShowThreeThenPlusTwoMore
//   3. Show a hidden empty group
//        -> AuthoredPrsPresentationTests.testEmptyGroupsAreHidden
// (Wire-level guards: a malformed row must cost only itself, and unsafe characters and over-long
// strings must never reach a row: testAMalformedRowIsDroppedAndTheOthersDecode,
// testControlAndBidiCharactersAreStrippedFromEveryGitHubString, testOverLongStringsAndListsAreCutToTheBounds.)

import XCTest
@testable import NostromoKit

// MARK: - Helpers

private func isoDate(_ s: String) -> Date {
    ISO8601DateFormatter().date(from: s)!
}

private func jsonData(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object)
}

private func frameData(_ snapshot: [String: Any]) throws -> Data {
    try jsonData(["type": "authored_prs", "snapshot": snapshot])
}

private func decodeSnapshot(_ snapshot: [String: Any]) throws -> AuthoredPrsSnapshot {
    try JSONDecoder().decode(AuthoredPrsFrame.self, from: try frameData(snapshot)).snapshot
}

private func decodePrs(_ rows: [Any]) throws -> [AuthoredPr] {
    try decodeSnapshot(["prs": rows]).prs
}

/// The smallest row the Kit accepts, with overrides merged over it.
private func prDict(_ number: Int = 1, _ overrides: [String: Any] = [:]) -> [String: Any] {
    var d: [String: Any] = ["repo": "o/r", "number": number, "title": "T\(number)",
                            "group": "waiting", "lifecycle": "open"]
    d.merge(overrides) { _, new in new }
    return d
}

private func decodeOnePr(_ overrides: [String: Any] = [:]) throws -> AuthoredPr {
    let rows = try decodePrs([prDict(1, overrides)])
    return try XCTUnwrap(rows.first)
}

// MARK: - The daemon's golden frame

final class AuthoredPrsDaemonGoldenTests: XCTestCase {

    private static func fixtureData() throws -> Data {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // NostromoKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // NostromoKit
            .deletingLastPathComponent()   // Shared
            .deletingLastPathComponent()   // <repo>
        return try Data(contentsOf: root.appendingPathComponent("tests/fixtures/authored_prs/frame-authored-prs.json"))
    }

    private func golden() throws -> AuthoredPrsSnapshot {
        try JSONDecoder().decode(AuthoredPrsFrame.self, from: try Self.fixtureData()).snapshot
    }

    private func pr(_ number: Int, in snapshot: AuthoredPrsSnapshot, file: StaticString = #filePath, line: UInt = #line) throws -> AuthoredPr {
        try XCTUnwrap(snapshot.prs.first { $0.number == number }, "PR #\(number) missing", file: file, line: line)
    }

    func testTheGoldenFrameArrivesAsAnAuthoredPrsServerMsgWithTheSameSnapshot() throws {
        let data = try Self.fixtureData()
        guard case .authoredPrs(let viaServerMsg) = ServerMsg.decode(from: data) else {
            return XCTFail("the golden frame did not decode to ServerMsg.authoredPrs")
        }
        XCTAssertEqual(viaServerMsg, try golden())
        XCTAssertEqual(viaServerMsg.prs.count, 7)
    }

    func testGoldenSnapshotHeaderFields() throws {
        let s = try golden()
        XCTAssertEqual(s.generatedAt, isoDate("2026-11-14T12:00:00Z"))
        XCTAssertEqual(s.token, .connected)
        XCTAssertEqual(s.relay.state, .catchingUp)
        XCTAssertEqual(s.relay.org, "Carefeed")
        XCTAssertNil(s.relay.since)
        XCTAssertEqual(s.poll.state, .rateLimited)
        XCTAssertEqual(s.poll.checkedAt, isoDate("2026-11-14T11:58:00Z"))
        XCTAssertEqual(s.poll.intervalSecs, 300)
        XCTAssertNil(s.poll.resumesAt)
        XCTAssertEqual(s.refreshBlocked, .running)
        XCTAssertEqual(s.hiddenOrgs, ["Secret-Org", "an organization"])
        XCTAssertEqual(s.totalOpen, 9)
        XCTAssertEqual(s.shown, 7)
        XCTAssertEqual(s.prs.count, 7)
    }

    func testGoldenUsageWindowAndSinceStartCounts() throws {
        let u = try golden().usage
        XCTAssertEqual(u.windowSecs, 3600)
        XCTAssertEqual(u.window.charged, 41)
        XCTAssertEqual(u.window.notModified, 17)
        XCTAssertEqual(u.window.search, 22)
        XCTAssertEqual(u.window.graphqlPoints, 19)
        XCTAssertEqual(u.window.relayCharged, 4)
        XCTAssertEqual(u.window.visibleCharged, 36)
        XCTAssertEqual(u.window.hiddenCharged, 5)
        XCTAssertEqual(u.sinceStart.charged, 120)
        XCTAssertEqual(u.sinceStart.notModified, 80)
        XCTAssertEqual(u.sinceStart.search, 100)
        XCTAssertEqual(u.sinceStart.graphqlPoints, 70)
        XCTAssertEqual(u.sinceStart.relayCharged, 12)
        XCTAssertEqual(u.sinceStart.visibleCharged, 100)
        XCTAssertEqual(u.sinceStart.hiddenCharged, 20)
    }

    func testGoldenFailingRowWithMotherJobOwner() throws {
        let p = try pr(101, in: try golden())
        XCTAssertEqual(p.repo, "Carefeed/admin-portal")
        XCTAssertEqual(p.title, "Fix the visitor export")
        XCTAssertEqual(p.url, "https://github.com/Carefeed/admin-portal/pull/101")
        XCTAssertEqual(p.group, .needsYou)
        XCTAssertEqual(p.lifecycle, .open)
        XCTAssertFalse(p.draft)
        XCTAssertEqual(p.baseRef, "release/2026-11")
        XCTAssertEqual(p.updatedAt, isoDate("2026-11-14T11:55:00Z"))
        XCTAssertEqual(p.checks.state, .failing)
        XCTAssertEqual(p.checks.passed, 3)
        XCTAssertEqual(p.checks.failed, 2)
        XCTAssertEqual(p.checks.pending, 0)
        XCTAssertEqual(p.checks.failingNames, ["unit tests", "lint"])
        XCTAssertEqual(p.review.state, .changesRequested)
        XCTAssertEqual(p.review.logins, ["alice"])
        XCTAssertEqual(p.newComments, 3)
        XCTAssertEqual(p.unresolvedThreads, 2)
        XCTAssertTrue(p.threadsTruncated)
        XCTAssertEqual(p.owner.kind, .motherJob)
        XCTAssertEqual(p.owner.name, "Portal export")
        XCTAssertEqual(p.owner.jobId, "job-17")
        XCTAssertEqual(p.owner.tag, "focus-portal")
    }

    func testGoldenReadyAndWaitingRows() throws {
        let s = try golden()
        let ready = try pr(202, in: s)
        XCTAssertEqual(ready.group, .ready)
        XCTAssertEqual(ready.checks.state, .passing)
        XCTAssertEqual(ready.review.state, .approved)
        XCTAssertEqual(ready.review.logins, ["bob", "carefeed-bot[bot]"])
        XCTAssertEqual(ready.owner.kind, .linked)
        XCTAssertNil(ready.baseRef)

        let waiting = try pr(303, in: s)
        XCTAssertEqual(waiting.group, .waiting)
        XCTAssertEqual(waiting.checks.state, .pending)
        XCTAssertEqual(waiting.checks.pending, 1)
        XCTAssertEqual(waiting.review.state, .reviewRequested)
        XCTAssertEqual(waiting.owner.kind, .onBranch)
        XCTAssertEqual(waiting.owner.name, "Widgets")
    }

    func testGoldenDraftRowHasAnAmbiguousOwnerWithTwoCandidates() throws {
        let p = try pr(404, in: try golden())
        XCTAssertTrue(p.draft)
        XCTAssertEqual(p.group, .draft)
        XCTAssertEqual(p.owner.kind, .ambiguous)
        XCTAssertEqual(p.owner.candidates.count, 2)
        XCTAssertEqual(p.owner.candidates.map(\.name), ["Alpha", "Beta"])
        XCTAssertEqual(p.owner.candidates.map(\.tag), ["focus-alpha", "focus-beta"])
        XCTAssertEqual(p.owner.candidates.first?.jobId, "job-3")
        XCTAssertNil(p.owner.candidates.last?.jobId)
    }

    func testGoldenRowWithDetailsUnavailableAndAClosedOwner() throws {
        let p = try pr(505, in: try golden())
        XCTAssertTrue(p.detailsUnavailable)
        XCTAssertEqual(p.owner.kind, .closed)
        XCTAssertEqual(p.owner.name, "A focus that closed")
        XCTAssertEqual(p.checks.state, .none)
        XCTAssertEqual(p.review.state, .none)
    }

    func testGoldenMergedAndClosedRowsCarryEndedAt() throws {
        let s = try golden()
        let merged = try pr(606, in: s)
        XCTAssertEqual(merged.lifecycle, .merged)
        XCTAssertEqual(merged.endedAt, isoDate("2026-11-14T11:58:00Z"))
        XCTAssertEqual(merged.owner.kind, .unknown)

        let closed = try pr(707, in: s)
        XCTAssertEqual(closed.lifecycle, .closed)
        XCTAssertEqual(closed.endedAt, isoDate("2026-11-14T11:59:00Z"))

        for row in s.prs where row.lifecycle == .open {
            XCTAssertNil(row.endedAt, "#\(row.number) is open and must have no ended_at")
        }
    }
}

// MARK: - Tolerant decoding

final class AuthoredPrsWireTests: XCTestCase {

    // MARK: Unknown enum values

    func testUnknownEnumValuesDecodeToUnknownAndDoNotCostTheFrameOrTheRow() throws {
        let snapshot: [String: Any] = [
            "token": "revoked-by-aliens",
            "relay": ["state": "teleporting"],
            "poll": ["state": "vibing"],
            "refresh_blocked": "cosmic_rays",
            "prs": [prDict(7, [
                "group": "someday",
                "lifecycle": "archived",
                "checks": ["state": "flaky"],
                "review": ["state": "vibes_only"],
                "owner": ["kind": "committee"],
            ])],
        ]
        let s = try decodeSnapshot(snapshot)
        XCTAssertEqual(s.token, .unknown)
        XCTAssertEqual(s.relay.state, .unknown)
        XCTAssertEqual(s.poll.state, .unknown)
        XCTAssertEqual(s.refreshBlocked, .unknown)
        XCTAssertEqual(s.prs.map(\.number), [7], "an unknown enum value must not drop the row")
        let p = try XCTUnwrap(s.prs.first)
        XCTAssertEqual(p.group, .unknown)
        XCTAssertEqual(p.lifecycle, .unknown)
        XCTAssertEqual(p.checks.state, .unknown)
        XCTAssertEqual(p.review.state, .unknown)
        XCTAssertEqual(p.owner.kind, .unknown)

        // And the same frame still arrives as an authored_prs message.
        guard case .authoredPrs(let viaServerMsg) = ServerMsg.decode(from: try frameData(snapshot)) else {
            return XCTFail("a frame with unknown enum values must still decode to .authoredPrs")
        }
        XCTAssertEqual(viaServerMsg, s)
    }

    func testAnUnknownGroupSortsAfterDrafts() {
        XCTAssertEqual(AuthoredPrGroup.displayOrder, [.needsYou, .ready, .waiting, .draft, .unknown])
    }

    func testKnownEnumWireValuesDecodeToTheirCases() throws {
        let s = try decodeSnapshot([
            "token": "rejected",
            "relay": ["state": "not_configured"],
            "poll": ["state": "paused"],
            "refresh_blocked": "rate_limited",
            "prs": [prDict(1, ["group": "needs_you", "owner": ["kind": "on_branch"],
                               "review": ["state": "review_requested"]])],
        ])
        XCTAssertEqual(s.token, .rejected)
        XCTAssertEqual(s.relay.state, .notConfigured)
        XCTAssertEqual(s.poll.state, .paused)
        XCTAssertEqual(s.refreshBlocked, .rateLimited)
        XCTAssertEqual(s.prs.first?.group, .needsYou)
        XCTAssertEqual(s.prs.first?.owner.kind, .onBranch)
        XCTAssertEqual(s.prs.first?.review.state, .reviewRequested)
    }

    func testRefreshBlockedIsNilWhenAbsentOrNull() throws {
        XCTAssertNil(try decodeSnapshot([:]).refreshBlocked)
        XCTAssertNil(try decodeSnapshot(["refresh_blocked": NSNull()]).refreshBlocked)
        XCTAssertEqual(try decodeSnapshot(["refresh_blocked": "running"]).refreshBlocked, .running)
    }

    // MARK: Missing optionals

    func testAnEmptySnapshotDecodesToEmptyDefaultsInsteadOfFailing() throws {
        let s = try decodeSnapshot([:])
        XCTAssertEqual(s.token, .unknown)
        XCTAssertEqual(s.relay.state, .unknown)
        XCTAssertEqual(s.poll.state, .unknown)
        XCTAssertNil(s.refreshBlocked)
        XCTAssertNil(s.generatedAt)
        XCTAssertEqual(s.hiddenOrgs, [])
        XCTAssertEqual(s.prs, [])
        XCTAssertEqual(s.totalOpen, 0)
        XCTAssertEqual(s.shown, 0)
        XCTAssertEqual(s.usage.window.charged, 0)
        XCTAssertEqual(s.usage.sinceStart.charged, 0)
    }

    func testARowWithOnlyItsRequiredFieldsHasNilOptionalsAndZeroCounts() throws {
        let p = try decodeOnePr()
        XCTAssertEqual(p.repo, "o/r")
        XCTAssertEqual(p.number, 1)
        XCTAssertEqual(p.title, "T1")
        XCTAssertEqual(p.id, "o/r#1")
        XCTAssertNil(p.updatedAt)
        XCTAssertNil(p.endedAt)
        XCTAssertNil(p.baseRef)
        XCTAssertFalse(p.draft)
        XCTAssertFalse(p.detailsUnavailable)
        XCTAssertFalse(p.threadsTruncated)
        XCTAssertEqual(p.newComments, 0)
        XCTAssertEqual(p.unresolvedThreads, 0)
        XCTAssertEqual(p.checks.state, .none)
        XCTAssertEqual(p.checks.failingNames, [])
        XCTAssertEqual(p.review.state, .none)
        XCTAssertEqual(p.review.logins, [])
        XCTAssertEqual(p.owner.kind, .unknown)
        XCTAssertEqual(p.owner.candidates, [])
    }

    func testAnEmptyBaseRefIsNilAndAnUnparseableDateIsNilWithoutDroppingTheRow() throws {
        let p = try decodeOnePr(["base_ref": "", "updated_at": "yesterday-ish", "ended_at": 12])
        XCTAssertNil(p.baseRef)
        XCTAssertNil(p.updatedAt)
        XCTAssertNil(p.endedAt)
    }

    func testDatesWithFractionalSecondsParse() throws {
        let p = try decodeOnePr(["updated_at": "2026-11-14T12:00:00.250Z"])
        let expected = isoDate("2026-11-14T12:00:00Z").addingTimeInterval(0.25)
        XCTAssertEqual(try XCTUnwrap(p.updatedAt).timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.01)
    }

    // MARK: Malformed rows

    func testAMalformedRowIsDroppedAndTheOthersDecode() throws {
        let rows: [Any] = [
            prDict(1),
            ["repo": "o/r", "title": "no number"],                    // missing number
            prDict(3, ["title": 42]),                                 // title is not a string
            ["number": 4, "title": "no repo"],                        // missing repo
            "not even an object",
            prDict(6),
        ]
        let s = try decodeSnapshot(["prs": rows, "total_open": 6, "shown": 6])
        XCTAssertEqual(s.prs.map(\.number), [1, 6], "malformed rows cost only themselves")
        XCTAssertEqual(s.totalOpen, 6, "the daemon's totals are kept as sent")
    }

    func testAMalformedOwnerCandidateIsDroppedAndTheOthersDecode() throws {
        let p = try decodeOnePr(["owner": ["kind": "ambiguous", "candidates": [
            ["tag": "a", "name": "A"],
            7,
            ["tag": "b", "name": "B", "job_id": "job-2"],
        ] as [Any]]])
        XCTAssertEqual(p.owner.candidates.map(\.name), ["A", "B"])
        XCTAssertEqual(p.owner.candidates.last?.jobId, "job-2")
    }

    func testABadChecksReviewOrOwnerBlockDefaultsInsteadOfDroppingTheRow() throws {
        let p = try decodeOnePr(["checks": "oops", "review": 5, "owner": ["not", "an", "object"]])
        XCTAssertEqual(p.checks.state, .none)
        XCTAssertEqual(p.review.state, .none)
        XCTAssertEqual(p.owner.kind, .unknown)
    }

    // MARK: Hostile text

    private static let dirty = "A\u{202E}B\nC\u{0000}D\u{2066}"   // bidi override, newline, NUL, bidi isolate

    func testControlAndBidiCharactersAreStrippedFromEveryGitHubString() throws {
        let dirty = Self.dirty
        let p = try decodeOnePr([
            "title": dirty,
            "repo": dirty,
            "base_ref": dirty,
            "checks": ["state": "failing", "failed": 2, "failing_names": [dirty, "\u{202E}"]],
            "review": ["state": "approved", "logins": [dirty]],
            "owner": ["kind": "linked", "name": dirty, "tag": dirty, "job_id": dirty,
                      "candidates": [["tag": dirty, "name": dirty]]],
        ])
        // A newline becomes a space, NUL and bidi controls vanish.
        XCTAssertEqual(p.title, "AB CD")
        XCTAssertEqual(p.repo, "AB CD")
        XCTAssertEqual(p.baseRef, "AB CD")
        XCTAssertEqual(p.checks.failingNames, ["AB CD"], "a name that is nothing but control characters is dropped")
        XCTAssertEqual(p.review.logins, ["AB CD"])
        XCTAssertEqual(p.owner.name, "AB CD")
        XCTAssertEqual(p.owner.tag, "AB CD")
        XCTAssertEqual(p.owner.jobId, "AB CD")
        XCTAssertEqual(p.owner.candidates.first?.name, "AB CD")
        XCTAssertEqual(p.owner.candidates.first?.tag, "AB CD")
    }

    func testHiddenOrgsAndTheRelayOrgAreCleanedToo() throws {
        let dirty = Self.dirty
        let s = try decodeSnapshot(["hidden_orgs": [dirty], "relay": ["state": "live", "org": dirty]])
        XCTAssertEqual(s.hiddenOrgs, ["AB CD"])
        XCTAssertEqual(s.relay.org, "AB CD")
    }

    func testTitlesAreTrimmedAndTabsBecomeSpaces() throws {
        let p = try decodeOnePr(["title": "  Fix\tthe thing \n"])
        XCTAssertEqual(p.title, "Fix the thing")
    }

    func testNothingIsStrippedFromOrdinaryNonAsciiText() throws {
        let p = try decodeOnePr(["title": "Café 日本語 – ✓ 🚀"])
        XCTAssertEqual(p.title, "Café 日本語 – ✓ 🚀")
    }

    // MARK: Bounds

    func testOverLongStringsAndListsAreCutToTheBounds() throws {
        let long = { (n: Int) in String(repeating: "x", count: n) }
        let names = (0..<30).map { "check-\($0)" }
        let logins = (0..<15).map { "login-\($0)" }
        let candidates: [[String: Any]] = (0..<12).map { ["tag": "t\($0)", "name": "n\($0)"] }
        let p = try decodeOnePr([
            "title": long(500),
            "base_ref": long(200),
            "new_comments": 5000,
            "checks": ["state": "failing", "failing_names": names + [long(150)]],
            "review": ["state": "approved", "logins": logins],
            "owner": ["kind": "ambiguous", "name": long(300), "candidates": candidates],
        ])
        XCTAssertEqual(p.title.count, AuthoredPrsBounds.title)
        XCTAssertEqual(p.baseRef?.count, AuthoredPrsBounds.baseRef)
        XCTAssertEqual(p.newComments, Int(AuthoredPrsBounds.newComments))
        XCTAssertEqual(p.checks.failingNames.count, AuthoredPrsBounds.failingNames)
        XCTAssertEqual(p.checks.failingNames.first, "check-0")
        XCTAssertEqual(p.review.logins.count, AuthoredPrsBounds.logins)
        XCTAssertEqual(p.review.logins.last, "login-9")
        XCTAssertEqual(p.owner.name?.count, AuthoredPrsBounds.name)
        XCTAssertEqual(p.owner.candidates.count, AuthoredPrsBounds.candidates)
        XCTAssertEqual(p.owner.candidates.last?.name, "n7")
    }

    func testAnOverLongCheckNameIsCut() throws {
        let p = try decodeOnePr(["checks": ["state": "failing", "failing_names": [String(repeating: "y", count: 150)]]])
        XCTAssertEqual(p.checks.failingNames.first?.count, AuthoredPrsBounds.checkName)
    }

    func testStringsAtTheBoundAreKeptWhole() throws {
        let exact = String(repeating: "z", count: AuthoredPrsBounds.title)
        let p = try decodeOnePr(["title": exact])
        XCTAssertEqual(p.title, exact)
    }

    func testHiddenOrgsAndOrgNamesAreCutToTheBounds() throws {
        let orgs = (0..<15).map { "org-\($0)" }
        let s = try decodeSnapshot(["hidden_orgs": orgs,
                                    "relay": ["state": "live", "org": String(repeating: "o", count: 100)]])
        XCTAssertEqual(s.hiddenOrgs.count, AuthoredPrsBounds.hiddenOrgs)
        XCTAssertEqual(s.hiddenOrgs.last, "org-9")
        XCTAssertEqual(s.relay.org.count, AuthoredPrsBounds.orgName)
    }
}
