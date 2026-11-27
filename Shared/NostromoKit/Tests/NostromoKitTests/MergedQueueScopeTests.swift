// NostromoKit — MergedQueueScopeTests.swift
//
// The merged queue under a host scope, with satellites' held decisions and approvals as rows
// (W11 slice 2). What these guard:
//   * a scope drops other Macs' rows INCLUDING their decisions and approvals, and never reorders
//     what is left ("needs you" first, then recency);
//   * the badge rule: a Mac's name on every row when rows come from more than one Mac, and always
//     when the scope is a group of Macs; none for one Mac's rows under a single-host scope;
//   * a decision row comes only from a satellite, needs the operator, says its question when the
//     frame carried one and a fixed phrase when not, and points at the Mac ("Answer it on your Mac");
//   * an approval row exists only for a count above zero, is keyed by (host, tag), and a work host's
//     tag never reaches the row id raw;
//   * a host that is not connected has last-known rows;
//   * the original call (no scope, no hosts) behaves exactly as before.

import XCTest
@testable import NostromoKit

final class MergedQueueScopeTests: XCTestCase {

    // 2027-01-15T08:00:00Z
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let primary = "Sendai"

    // MARK: Builders

    private func job(_ id: String, state: String = "running", createdAt: String? = nil) -> MotherJob {
        MotherJob(id: id, state: state, title: "T-\(id)", createdAt: createdAt)
    }

    private func session(_ tag: String) -> SessionInfo {
        SessionInfo(tag: tag, agentName: "cody", viewName: "view", sessionId: nil, alive: true,
                    remoteControl: false, state: .idle, stopReason: nil, mcpBridgeConnected: nil)
    }

    private func decision(_ host: String, tag: String = "cody-1", id: String, prompt: String = "") -> HostedDecision {
        HostedDecision(host: host, tag: tag, requestId: id, prompt: prompt)
    }

    private func entry(_ name: String, _ egress: HostEgress, primary: Bool = false, connected: Bool = true,
                       lastSeen: Date? = nil) -> HostEntry {
        HostEntry(name: name, egress: egress, isPrimary: primary, connected: connected, lastSeen: lastSeen)
    }

    /// The primary "Sendai", work satellite "kobe", personal satellite "studio": all connected.
    private var hosts: [HostEntry] {
        [entry(primary, .personal, primary: true), entry("kobe", .work), entry("studio", .personal)]
    }

    private let egress: [String: HostEgress] = ["kobe": .work, "studio": .personal]

    private func rows(primaryJobs: [MotherJob] = [], primarySessions: [SessionInfo] = [],
                      hostedJobs: [String: [MotherJob]] = [:], hostedSessions: [String: [SessionInfo]] = [:],
                      egress: [String: HostEgress]? = nil,
                      decisions: [String: [HostedDecision]] = [:], approvals: [String: [String: Int]] = [:],
                      scope: HostScope? = nil, hosts: [HostEntry]? = nil) -> [MergedQueueRow] {
        MergedQueue.rows(primaryJobs: primaryJobs, primarySessions: primarySessions, hostedJobs: hostedJobs,
                         hostedSessions: hostedSessions, egress: egress ?? self.egress, primaryName: primary,
                         hostedDecisions: decisions, approvalCounts: approvals, scope: scope,
                         hosts: hosts ?? self.hosts, now: now)
    }

    // MARK: - A scenario with every kind of row

    private func scenario(scope: HostScope?) -> [MergedQueueRow] {
        rows(primaryJobs: [job("p-await", state: "awaiting", createdAt: "2027-01-15T06:00:00Z"),
                           job("p-run", createdAt: "2027-01-15T07:00:00Z")],
             hostedJobs: ["studio": [job("s-await", state: "awaiting", createdAt: "2027-01-15T05:00:00Z"),
                                     job("s-run", createdAt: "2027-01-15T07:30:00Z")],
                          "kobe": [job("k-run", createdAt: "2027-01-15T07:45:00Z")]],
             decisions: ["kobe": [decision("kobe", id: "d1")]],
             scope: scope)
    }

    func testWithoutAScopeEveryMacsRowsAreListedNeedsYouFirstThenNewest() {
        XCTAssertEqual(scenario(scope: nil).map(\.id),
                       ["|job|p-await", "studio|job|s-await", "kobe|decision|d1",
                        "kobe|job|k-run", "studio|job|s-run", "|job|p-run"])
    }

    func testEachScopeKeepsOnlyItsMacsRowsInTheOrderTheyHaveInTheFullList() {
        let expected: [(scope: HostScope, ids: [String])] = [
            (.all,            ["|job|p-await", "studio|job|s-await", "kobe|decision|d1",
                               "kobe|job|k-run", "studio|job|s-run", "|job|p-run"]),
            (.work,           ["kobe|decision|d1", "kobe|job|k-run"]),
            (.personal,       ["|job|p-await", "studio|job|s-await", "studio|job|s-run", "|job|p-run"]),
            (.host("studio"), ["studio|job|s-await", "studio|job|s-run"]),
            (.host("Sendai"), ["|job|p-await", "|job|p-run"]),
            (.host("kobe"),   ["kobe|decision|d1", "kobe|job|k-run"]),
            (.host("nobody"), []),
        ]
        for row in expected {
            XCTAssertEqual(scenario(scope: row.scope).map(\.id), row.ids, "scope \(row.scope)")
        }
    }

    func testAHostWithNoEgressOnRecordIsWorkForTheScope() {
        let result = rows(hostedJobs: ["mystery": [job("m1")]], egress: [:], scope: .work, hosts: [])
        XCTAssertEqual(result.map(\.id), ["mystery|job|m1"], "Unknown means the strict reading: work")
        XCTAssertTrue(rows(hostedJobs: ["mystery": [job("m1")]], egress: [:], scope: .personal, hosts: []).isEmpty)
    }

    // MARK: - A scope drops other Macs' decisions and approvals

    func testAScopeDropsOtherHostsDecisionsAndApprovalsToo() {
        let decisions = ["kobe": [decision("kobe", id: "kd")], "studio": [decision("studio", id: "sd")]]
        let approvals = ["kobe": ["f-1": 2], "studio": ["cody-1": 1]]

        let studio = rows(decisions: decisions, approvals: approvals, scope: .host("studio"))
        XCTAssertEqual(Set(studio.map(\.id)), ["studio|decision|sd", "studio|approval|cody-1"])

        let work = rows(decisions: decisions, approvals: approvals, scope: .work)
        XCTAssertEqual(Set(work.map(\.host)), ["kobe"])
        XCTAssertEqual(work.filter { $0.kind == .decision }.map(\.id), ["kobe|decision|kd"])
        XCTAssertEqual(work.filter { $0.kind == .approval }.count, 1)

        let personal = rows(decisions: decisions, approvals: approvals, scope: .personal)
        XCTAssertEqual(Set(personal.map(\.host)), ["studio"])

        let primaryOnly = rows(decisions: decisions, approvals: approvals, scope: .host("Sendai"))
        XCTAssertTrue(primaryOnly.isEmpty, "The primary holds no satellite decisions")

        XCTAssertEqual(rows(decisions: decisions, approvals: approvals, scope: .all).count, 4)
    }

    func testAHostThatOnlyHoldsADecisionStillHasARow() {
        let result = rows(decisions: ["kobe": [decision("kobe", id: "kd")]], scope: .host("kobe"))
        XCTAssertEqual(result.map(\.kind), [.decision])
    }

    // MARK: - Badges

    func testBadgeRuleAcrossScopesAndMacs() {
        // (scope, which Macs have rows) -> badge shown?
        let primaryJobs = [job("p1")]
        let studioJobs = ["studio": [job("s1")]]
        let kobeJobs = ["kobe": [job("k1")]]
        let both = studioJobs.merging(kobeJobs) { a, _ in a }

        func badges(scope: HostScope?, primaryJobs: [MotherJob] = [], hostedJobs: [String: [MotherJob]] = [:]) -> [String?] {
            rows(primaryJobs: primaryJobs, hostedJobs: hostedJobs, scope: scope).map(\.hostBadge)
        }

        // No scope: the original rule, a badge only when more than one Mac has rows.
        XCTAssertEqual(badges(scope: nil, primaryJobs: primaryJobs), [nil])
        XCTAssertEqual(badges(scope: nil, hostedJobs: studioJobs), [nil])
        XCTAssertEqual(Set(badges(scope: nil, primaryJobs: primaryJobs, hostedJobs: studioJobs)), ["Sendai", "studio"])

        // A group scope always names the Mac, even when only one Mac has rows.
        XCTAssertEqual(badges(scope: .all, primaryJobs: primaryJobs), ["Sendai"])
        XCTAssertEqual(badges(scope: .all, hostedJobs: studioJobs), ["studio"])
        XCTAssertEqual(badges(scope: .work, hostedJobs: kobeJobs), ["kobe"])
        XCTAssertEqual(badges(scope: .personal, hostedJobs: studioJobs), ["studio"])
        XCTAssertEqual(Set(badges(scope: .personal, primaryJobs: primaryJobs, hostedJobs: both)), ["Sendai", "studio"])
        XCTAssertEqual(Set(badges(scope: .all, primaryJobs: primaryJobs, hostedJobs: both)), ["Sendai", "studio", "kobe"])

        // One Mac under a single-host scope: nothing to tell apart, no badge, however many Macs exist.
        XCTAssertEqual(badges(scope: .host("studio"), primaryJobs: primaryJobs, hostedJobs: both), [nil])
        XCTAssertEqual(badges(scope: .host("kobe"), primaryJobs: primaryJobs, hostedJobs: both), [nil])
        XCTAssertEqual(badges(scope: .host("Sendai"), primaryJobs: primaryJobs, hostedJobs: both), [nil])
    }

    func testEveryRowOfOneMacUnderASingleHostScopeIsUnbadgedIncludingDecisionsAndApprovals() {
        let result = rows(hostedJobs: ["kobe": [job("k1")], "studio": [job("s1")]],
                          decisions: ["kobe": [decision("kobe", id: "kd")]],
                          approvals: ["kobe": ["f-1": 1]], scope: .host("kobe"))
        XCTAssertEqual(result.count, 3)
        XCTAssertTrue(result.allSatisfy { $0.hostBadge == nil }, "\(result.map(\.hostBadge))")
    }

    func testEveryRowIsBadgedWithItsOwnMacsNameUnderAGroupScope() {
        let result = rows(primaryJobs: [job("p1")],
                          hostedJobs: ["studio": [job("s1")]],
                          decisions: ["studio": [decision("studio", id: "sd")]],
                          approvals: ["studio": ["cody-1": 1]], scope: .personal)
        XCTAssertEqual(result.count, 4)
        for row in result {
            XCTAssertEqual(row.hostBadge, row.host ?? "Sendai", "row \(row.id)")
        }
    }

    // MARK: - Decision rows

    func testADecisionRowNeedsYouShowsItsQuestionAndPointsAtTheMac() throws {
        let result = rows(decisions: ["studio": [decision("studio", tag: "cody-1a2b3c4d", id: "req-1",
                                                           prompt: "Ship the export behind a flag?")]])

        let row = try XCTUnwrap(result.first)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(row.kind, .decision)
        XCTAssertEqual(row.host, "studio")
        XCTAssertTrue(row.needsYou)
        XCTAssertEqual(row.text, "Ship the export behind a flag?")
        XCTAssertEqual(row.footnote, ReasonPhrases.answerOnYourMac)
        XCTAssertNil(row.job)
        XCTAssertNil(row.session)
    }

    func testADecisionWithNoQuestionSaysTheFixedPhrase() throws {
        let row = try XCTUnwrap(rows(decisions: ["kobe": [decision("kobe", id: "req-1", prompt: "")]]).first)
        XCTAssertEqual(row.text, ReasonPhrases.decisionLine)
        XCTAssertFalse(row.text.isEmpty)
        XCTAssertEqual(row.footnote, ReasonPhrases.answerOnYourMac)
        XCTAssertTrue(row.needsYou)
    }

    func testAWorkHostThatDoesSendAQuestionHasItShownBecauseRenderingFollowsTheFrame() throws {
        let row = try XCTUnwrap(rows(decisions: ["kobe": [decision("kobe", id: "req-1", prompt: "Which branch?")]]).first)
        XCTAssertEqual(row.text, "Which branch?")
    }

    func testTwoHostsHoldingTheSameRequestIdGiveTwoRows() {
        let result = rows(decisions: ["kobe": [decision("kobe", tag: "f-48a0007a", id: "req-0a1b2c3d")],
                                      "studio": [decision("studio", tag: "cody-1a2b3c4d", id: "req-0a1b2c3d",
                                                          prompt: "Ship it?")]])

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(Set(result.map(\.id)).count, 2)
        XCTAssertEqual(Set(result.compactMap(\.host)), ["kobe", "studio"])
    }

    func testTwoDecisionsOfOneHostAreTwoRows() {
        let result = rows(decisions: ["kobe": [decision("kobe", id: "a"), decision("kobe", id: "b")]])
        XCTAssertEqual(Set(result.map(\.id)), ["kobe|decision|a", "kobe|decision|b"])
    }

    // MARK: - Approval rows

    func testAnApprovalRowExistsOnlyForACountAboveZero() throws {
        let result = rows(approvals: ["studio": ["t-two": 2, "t-zero": 0, "t-negative": -1, "t-one": 1]])

        XCTAssertEqual(result.count, 2)
        let two = try XCTUnwrap(result.first { $0.text == ReasonPhrases.approvalLine(count: 2) })
        let one = try XCTUnwrap(result.first { $0.text == ReasonPhrases.approvalLine(count: 1) })
        XCTAssertNotEqual(two.text, one.text, "The row says how many")
        for row in [two, one] {
            XCTAssertEqual(row.kind, .approval)
            XCTAssertEqual(row.host, "studio")
            XCTAssertTrue(row.needsYou)
            XCTAssertEqual(row.footnote, ReasonPhrases.answerOnYourMac)
            XCTAssertNil(row.job)
            XCTAssertNil(row.session)
        }
    }

    func testAHostWhoseApprovalsAreAllZeroHasNoRows() {
        XCTAssertTrue(rows(approvals: ["studio": ["a": 0, "b": 0]]).isEmpty)
    }

    func testThePrimarysApprovalCountsAreNotRows() {
        XCTAssertTrue(rows(approvals: ["": ["cody-1": 3]]).isEmpty, "The empty host name is the primary's own")
        let mixed = rows(approvals: ["": ["cody-1": 3], "studio": ["cody-1": 1]])
        XCTAssertEqual(mixed.map(\.host), ["studio"])
    }

    func testTheSameTagOnTwoHostsGivesTwoApprovalRowsWithDistinctIds() {
        let personalToo = [entry(primary, .personal, primary: true), entry("studio", .personal),
                           entry("amber", .personal), entry("kobe", .work)]
        let result = rows(egress: ["studio": .personal, "amber": .personal, "kobe": .work],
                          approvals: ["studio": ["cody-1": 1], "amber": ["cody-1": 1], "kobe": ["cody-1": 1]],
                          hosts: personalToo)

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(Set(result.map(\.id)).count, 3, "Keyed by (host, tag): \(result.map(\.id))")
        XCTAssertEqual(Set(result.compactMap(\.host)), ["studio", "amber", "kobe"])
    }

    func testAPersonalHostsApprovalIdNamesTheTagAndIsNotMetadataOnly() throws {
        let row = try XCTUnwrap(rows(approvals: ["studio": ["cody-1a2b3c4d": 2]]).first)
        XCTAssertTrue(row.id.hasPrefix("studio|approval|"))
        XCTAssertTrue(row.id.contains("cody-1a2b3c4d"))
        XCTAssertFalse(row.isMetadataOnly)
    }

    func testAWorkHostsApprovalIdHashesTheTagInsteadOfCarryingIt() throws {
        func id(_ tag: String) throws -> String {
            try XCTUnwrap(rows(approvals: ["kobe": [tag: 2]]).first).id
        }
        let first = try id("f-48a0007a")

        XCTAssertTrue(first.hasPrefix("kobe|approval|"))
        XCTAssertFalse(first.contains("f-48a0007a"), "A work host's tag is never used raw: \(first)")
        let suffix = String(first.dropFirst("kobe|approval|".count))
        XCTAssertEqual(suffix.count, 8, "A short hash")
        XCTAssertTrue(suffix.allSatisfy { "0123456789abcdef".contains($0) }, suffix)
        XCTAssertEqual(try id("f-48a0007a"), first, "Stable for the same tag")
        XCTAssertNotEqual(try id("f-33acb7de"), first, "Different tags are different rows")
        XCTAssertTrue(try XCTUnwrap(rows(approvals: ["kobe": ["f-48a0007a": 2]]).first).isMetadataOnly)
    }

    func testTwoTagsOnAWorkHostAreTwoRows() {
        let result = rows(approvals: ["kobe": ["f-48a0007a": 2, "f-33acb7de": 1]])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(Set(result.map(\.id)).count, 2)
    }

    // MARK: - Last known

    func testRowsOfAHostThatIsNotConnectedAreLastKnownWithALabel() throws {
        let seen = now.addingTimeInterval(-300)
        let hosts = [entry(primary, .personal, primary: true),
                     entry("kobe", .work, connected: false, lastSeen: seen),
                     entry("studio", .personal, connected: true)]

        let result = rows(hostedJobs: ["kobe": [job("k1")], "studio": [job("s1")]],
                          decisions: ["kobe": [decision("kobe", id: "kd")]],
                          approvals: ["kobe": ["f-1": 1]], hosts: hosts)

        let kobe = result.filter { $0.host == "kobe" }
        XCTAssertEqual(kobe.count, 3)
        for row in kobe {
            XCTAssertTrue(row.isLastKnown, "row \(row.id)")
            XCTAssertTrue(try XCTUnwrap(row.lastKnownLabel).hasPrefix("Last seen "), "row \(row.id)")
        }
        let studio = try XCTUnwrap(result.first { $0.host == "studio" })
        XCTAssertFalse(studio.isLastKnown)
        XCTAssertNil(studio.lastKnownLabel)
    }

    func testAHostNeverHeardFromThatIsNotConnectedSaysLastKnown() throws {
        let hosts = [entry(primary, .personal, primary: true), entry("kobe", .work, connected: false)]
        let row = try XCTUnwrap(rows(hostedJobs: ["kobe": [job("k1")]], hosts: hosts).first)
        XCTAssertTrue(row.isLastKnown)
        XCTAssertEqual(row.lastKnownLabel, "Last known")
    }

    func testThePrimarysRowsAreLastKnownWhileTheLinkIsDown() throws {
        let hosts = [entry(primary, .personal, primary: true, connected: false)]
        let row = try XCTUnwrap(rows(primaryJobs: [job("p1")], hosts: hosts).first)
        XCTAssertTrue(row.isLastKnown)
        XCTAssertNotNil(row.lastKnownLabel)
    }

    func testRowsOfAHostNotInHostsAreNotMarkedLastKnown() {
        let result = rows(primaryJobs: [job("p1")], hostedJobs: ["kobe": [job("k1")]], hosts: [])
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy { !$0.isLastKnown && $0.lastKnownLabel == nil })
    }

    func testAConnectedHostsRowsAreNotLastKnown() {
        let result = rows(primaryJobs: [job("p1")], hostedJobs: ["kobe": [job("k1")], "studio": [job("s1")]])
        XCTAssertEqual(result.count, 3)
        XCTAssertTrue(result.allSatisfy { !$0.isLastKnown && $0.lastKnownLabel == nil })
    }

    // MARK: - The original call

    func testTheOriginalSixArgumentCallStillBadgesOnlyWhenMoreThanOneMacHasRows() {
        let alone = MergedQueue.rows(primaryJobs: [job("p1")], primarySessions: [session("cody-1")],
                                     hostedJobs: [:], hostedSessions: [:], egress: [:], primaryName: primary)
        XCTAssertEqual(alone.count, 2)
        XCTAssertTrue(alone.allSatisfy { $0.hostBadge == nil }, "One Mac, no scope: no badge")

        let two = MergedQueue.rows(primaryJobs: [job("p1")], primarySessions: [],
                                   hostedJobs: ["kobe": [job("k1")]], hostedSessions: [:],
                                   egress: ["kobe": .personal], primaryName: primary)
        XCTAssertEqual(two.count, 2)
        XCTAssertEqual(Set(two.compactMap(\.hostBadge)), ["Sendai", "kobe"])

        let onlyASatellite = MergedQueue.rows(primaryJobs: [], primarySessions: [],
                                              hostedJobs: ["kobe": [job("k1")]], hostedSessions: [:],
                                              egress: ["kobe": .personal], primaryName: primary)
        XCTAssertEqual(onlyASatellite.count, 1)
        XCTAssertNil(onlyASatellite[0].hostBadge)
    }

    func testTheOriginalCallMakesNoDecisionApprovalOrLastKnownRows() {
        let result = MergedQueue.rows(primaryJobs: [job("p1")], primarySessions: [],
                                      hostedJobs: ["kobe": [job("k1")]], hostedSessions: [:],
                                      egress: [:], primaryName: primary)
        XCTAssertTrue(result.allSatisfy { $0.kind == .job })
        XCTAssertTrue(result.allSatisfy { !$0.isLastKnown && $0.footnote == nil })
    }

    func testWithoutAScopeDecisionsStillMakeAHostAMacForTheBadgeRule() {
        let result = rows(primaryJobs: [job("p1")], decisions: ["kobe": [decision("kobe", id: "kd")]], scope: nil)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(Set(result.compactMap(\.hostBadge)), ["Sendai", "kobe"])
    }
}
