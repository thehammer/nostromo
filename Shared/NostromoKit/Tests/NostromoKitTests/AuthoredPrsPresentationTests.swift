// NostromoKit — AuthoredPrsPresentationTests.swift
//
// What the My open PRs Overview says, as pure functions of a snapshot, a clock and a time zone.
// Every test injects `now` and America/Chicago; nothing reads the machine's clock or zone.
// (2026-11-14 is CST, UTC-6: 21:00Z is 3:00 pm.)
//
// Mutations this file (with AuthoredPrsWireTests.swift) is meant to catch:
//   1. Format ages from receipt time instead of `checked_at`
//        -> testOtherReposAgeComesFromCheckedAtAndTheInjectedClock
//           (the snapshot's generated_at is "now", so an age taken from it reads 0s, not 40s;
//            an age taken from the machine clock reads nothing like 40s)
//   2. Drop the `+N more` cap on failing check names
//        -> testFiveFailingChecksWithFiveNamesShowThreeThenPlusTwoMore
//   3. Show a hidden empty group
//        -> testEmptyGroupsAreHidden

import XCTest
@testable import NostromoKit

// MARK: - Helpers

private let chicago = TimeZone(identifier: "America/Chicago")!

private func at(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
}

/// 3:00 pm in Chicago.
private let now = at("2026-11-14T21:00:00Z")

private typealias P = AuthoredPrsPresentation

private func header(
    relay: AuthoredPrsRelay = AuthoredPrsRelay(state: .live),
    poll: AuthoredPrsPoll = AuthoredPrsPoll(state: .ok, checkedAt: now.addingTimeInterval(-40), intervalSecs: 60),
    refreshBlocked: AuthoredPrsRefreshBlocked? = nil,
    prs: [AuthoredPr] = [],
    totalOpen: Int? = nil,
    shown: Int? = nil,
    generatedAt: Date? = nil,
    at clock: Date = now
) -> AuthoredPrsHeaderModel {
    let snapshot = AuthoredPrsSnapshot(generatedAt: generatedAt, token: .connected, relay: relay, poll: poll,
                                       refreshBlocked: refreshBlocked, hiddenOrgs: [], totalOpen: totalOpen,
                                       shown: shown, prs: prs, usage: AuthoredPrsUsage())
    return P.header(snapshot, now: clock, timeZone: chicago)
}

private func pr(_ number: Int = 1, repo: String = "thehammer/nostromo", title: String = "A title",
                group: AuthoredPrGroup = .waiting, lifecycle: AuthoredPrLifecycle = .open,
                endedAt: Date? = nil, updatedAt: Date? = nil, baseRef: String? = nil,
                draft: Bool = false, detailsUnavailable: Bool = false,
                checks: AuthoredPrChecks = AuthoredPrChecks(state: .none),
                review: AuthoredPrReview = AuthoredPrReview(state: .none),
                newComments: Int = 0, unresolved: Int = 0, truncated: Bool = false,
                owner: AuthoredPrOwner = .unknown) -> AuthoredPr {
    AuthoredPr(repo: repo, number: number, url: "https://github.com/\(repo)/pull/\(number)", title: title,
               draft: draft, updatedAt: updatedAt, group: group, lifecycle: lifecycle, endedAt: endedAt,
               baseRef: baseRef, detailsUnavailable: detailsUnavailable, checks: checks, review: review,
               newComments: newComments, unresolvedThreads: unresolved, threadsTruncated: truncated, owner: owner)
}

private func row(_ pr: AuthoredPr, chip: String? = nil) -> AuthoredPrRowModel {
    P.row(pr, chip: chip, now: now)
}

private func groups(_ prs: [AuthoredPr], showAll: Set<AuthoredPrGroup> = []) -> [AuthoredPrsGroupModel] {
    P.groups(prs, showAll: showAll, now: now, timeZone: chicago)
}

private func failing(_ failed: Int, names: [String], passed: Int = 0, pending: Int = 0) -> AuthoredPrChecks {
    AuthoredPrChecks(state: .failing, passed: passed, failed: failed, pending: pending, failingNames: names)
}

// MARK: - Header

final class AuthoredPrsHeaderTests: XCTestCase {

    // MARK: Carefeed words

    func testCarefeedIsLiveWhenTheRelayIsLive() {
        XCTAssertEqual(header(relay: AuthoredPrsRelay(state: .live)).carefeed, "live")
    }

    func testCarefeedOfflineRelayNamesTheClockTimeItWentDownAndTheFallbackPollInterval() {
        let relay = AuthoredPrsRelay(state: .offline, since: at("2026-11-14T20:47:00Z"))   // 2:47 pm CST
        let poll = AuthoredPrsPoll(state: .ok, checkedAt: now.addingTimeInterval(-40), intervalSecs: 300)
        XCTAssertEqual(header(relay: relay, poll: poll).carefeed, "relay offline since 2:47 pm · polling every 5m")
    }

    func testCarefeedCatchingUpSaysSo() {
        XCTAssertEqual(header(relay: AuthoredPrsRelay(state: .catchingUp, org: "Carefeed")).carefeed, "catching up…")
    }

    func testCarefeedWithNoRelayConfiguredSaysItPollsAtTheDaemonInterval() {
        let poll = AuthoredPrsPoll(state: .ok, checkedAt: now.addingTimeInterval(-40), intervalSecs: 60)
        XCTAssertEqual(header(relay: AuthoredPrsRelay(state: .notConfigured), poll: poll).carefeed, "polling every 1m")
    }

    // MARK: Other repos words

    func testOtherReposChecked40SecondsAgo() {
        XCTAssertEqual(header().otherRepos, "checked 40s ago")
    }

    func testOtherReposChecking() {
        XCTAssertEqual(header(poll: AuthoredPrsPoll(state: .checking)).otherRepos, "checking…")
    }

    func testOtherReposPausedByTheRateLimitSaysWhenItResumes() {
        let resumes = at("2026-11-14T21:40:00Z")   // 3:40 pm CST
        let paused = AuthoredPrsPoll(state: .paused, checkedAt: now.addingTimeInterval(-40), intervalSecs: 300, resumesAt: resumes)
        let limited = AuthoredPrsPoll(state: .rateLimited, checkedAt: now.addingTimeInterval(-40), intervalSecs: 300, resumesAt: resumes)
        XCTAssertEqual(header(poll: paused).otherRepos, "paused: GitHub rate limit low, resumes 3:40 pm")
        XCTAssertEqual(header(poll: limited).otherRepos, "paused: GitHub rate limit low, resumes 3:40 pm")
    }

    func testOtherReposErrorSaysWhenItRetries() {
        let poll = AuthoredPrsPoll(state: .error, checkedAt: now.addingTimeInterval(-300), intervalSecs: 60,
                                   retryAt: now.addingTimeInterval(120))
        XCTAssertEqual(header(poll: poll).otherRepos, "couldn't reach GitHub, retrying in 2m")
    }

    func testOtherReposRateLimitedWithNoResumeTimeNamesTheCheckInterval() {
        let poll = AuthoredPrsPoll(state: .rateLimited, checkedAt: now.addingTimeInterval(-40), intervalSecs: 300)
        XCTAssertEqual(header(poll: poll).otherRepos, "rate limit low · checking every 5m")
    }

    func testFreshnessJoinsBothSources() {
        XCTAssertEqual(header().freshness, "Carefeed: live · Other repos: checked 40s ago")
    }

    // MARK: Criterion 14: nothing claims "live" it did not hear

    func testCarefeedSaysLiveOnlyWhenTheRelayStateIsLive() {
        let relayStates: [AuthoredPrsRelayState] = [.live, .catchingUp, .offline, .notConfigured, .unknown]
        let pollStates: [AuthoredPrsPollState] = [.ok, .checking, .rateLimited, .paused, .error, .idle, .unknown]
        for relayState in relayStates {
            let relay = AuthoredPrsRelay(state: relayState, since: at("2026-11-14T20:47:00Z"), org: "Carefeed")
            for pollState in pollStates {
                let poll = AuthoredPrsPoll(state: pollState, checkedAt: now.addingTimeInterval(-40), intervalSecs: 60,
                                           resumesAt: now.addingTimeInterval(600), retryAt: now.addingTimeInterval(60))
                let h = header(relay: relay, poll: poll)
                if relayState == .live {
                    XCTAssertEqual(h.carefeed, "live", "relay \(relayState) / poll \(pollState)")
                } else {
                    XCTAssertFalse(h.carefeed.contains("live"), "relay \(relayState) / poll \(pollState): \(h.carefeed)")
                    XCTAssertFalse(h.freshness.contains("live"), "relay \(relayState) / poll \(pollState): \(h.freshness)")
                }
            }
        }
    }

    func testOtherReposAgeComesFromCheckedAtAndTheInjectedClock() {
        let checkedAt = now.addingTimeInterval(-40)
        let poll = AuthoredPrsPoll(state: .ok, checkedAt: checkedAt, intervalSecs: 60)

        // The frame "arrived" at `now` (generated_at). The age is still 40s: it is measured from checked_at.
        XCTAssertEqual(header(poll: poll, generatedAt: now, at: now).otherRepos, "checked 40s ago")
        // A minute later by the injected clock, with the very same snapshot, it reads a minute older.
        XCTAssertEqual(header(poll: poll, generatedAt: now, at: now.addingTimeInterval(60)).otherRepos, "checked 1m ago")
        // A stale check is called stale, however fresh the frame is.
        let stale = AuthoredPrsPoll(state: .ok, checkedAt: now.addingTimeInterval(-600), intervalSecs: 60)
        XCTAssertEqual(header(poll: stale, generatedAt: now, at: now).otherRepos, "checked 10m ago")
    }

    func testAgeFormatting() {
        XCTAssertEqual(P.age(from: now.addingTimeInterval(-40), now: now), "40s")
        XCTAssertEqual(P.age(from: now.addingTimeInterval(-300), now: now), "5m")
        XCTAssertEqual(P.age(from: now.addingTimeInterval(-7200), now: now), "2h")
        XCTAssertEqual(P.age(from: now.addingTimeInterval(-3 * 86400), now: now), "3d")
        XCTAssertEqual(P.age(from: now.addingTimeInterval(30), now: now), "0s", "a date in the future never goes negative")
    }

    func testARowsAgeComesFromItsUpdatedAt() {
        let r = row(pr(updatedAt: now.addingTimeInterval(-3 * 3600)))
        XCTAssertEqual(r.age, "3h")
        XCTAssertEqual(row(pr(updatedAt: nil)).age, "")
    }

    // MARK: Count, showing, as-of, refresh

    func testTheCountIsOpenRowsOnly() {
        let prs = [pr(1), pr(2), pr(3),
                   pr(4, lifecycle: .merged, endedAt: now), pr(5, lifecycle: .closed, endedAt: now)]
        let h = header(prs: prs)
        XCTAssertEqual(h.countText, "My open PRs · 3")
        XCTAssertEqual(h.count, 3)
    }

    func testShowingNotesTheCapOnlyWhenTheDaemonCappedTheList() {
        XCTAssertEqual(header(totalOpen: 134, shown: 100).showing, "Showing the 100 most recently updated of 134")
        XCTAssertNil(header(totalOpen: 9, shown: 9).showing)
        XCTAssertNil(header().showing)
    }

    func testAsOfIsShownOnlyWhileRateLimitedPausedOrUnreachable() {
        let checked = at("2026-11-14T21:12:00Z")   // 3:12 pm CST
        for state in [AuthoredPrsPollState.rateLimited, .paused, .error] {
            let poll = AuthoredPrsPoll(state: state, checkedAt: checked, intervalSecs: 300)
            XCTAssertEqual(header(poll: poll).asOf, "as of 3:12 pm", "\(state)")
        }
        for state in [AuthoredPrsPollState.ok, .checking, .idle] {
            let poll = AuthoredPrsPoll(state: state, checkedAt: checked, intervalSecs: 60)
            XCTAssertNil(header(poll: poll).asOf, "\(state)")
        }
    }

    func testRefreshIsEnabledUnlessTheDaemonSaidItIsBlocked() {
        let free = header(refreshBlocked: nil)
        XCTAssertNil(free.refreshDisabledReason)
        XCTAssertTrue(free.refreshEnabled)

        for blocked in [AuthoredPrsRefreshBlocked.running, .rateLimited] {
            let h = header(refreshBlocked: blocked)
            XCTAssertNotNil(h.refreshDisabledReason, "\(blocked)")
            XCTAssertFalse(h.refreshEnabled, "\(blocked)")
            XCTAssertFalse(h.refreshDisabledReason?.isEmpty ?? true, "\(blocked)")
        }
    }
}

// MARK: - Rows

final class AuthoredPrsRowTests: XCTestCase {

    // MARK: Checks line

    func testChecksLineWithNothingFailingCountsPassedAndPending() {
        let passing = AuthoredPrChecks(state: .passing, passed: 9)
        XCTAssertEqual(row(pr(checks: passing)).checksLine, "Checks: 9 passed")
        XCTAssertNil(row(pr(checks: passing)).checksTooltip)

        let pending = AuthoredPrChecks(state: .pending, pending: 3)
        XCTAssertEqual(row(pr(checks: pending)).checksLine, "Checks: 3 pending")

        let mixed = AuthoredPrChecks(state: .pending, passed: 4, pending: 1)
        XCTAssertEqual(row(pr(checks: mixed)).checksLine, "Checks: 1 pending · 4 passed")
    }

    func testChecksLineWithNoChecksSaysNone() {
        XCTAssertEqual(row(pr(checks: AuthoredPrChecks(state: .none))).checksLine, "Checks: none")
    }

    func testChecksLineWithOneFailingNameNamesItAndCountsTheRest() {
        let r = row(pr(checks: failing(1, names: ["swift-tests"], passed: 9)))
        XCTAssertEqual(r.checksLine, "Checks: 1 failed (swift-tests) · 9 passed")
        XCTAssertEqual(r.checksTooltip, "Failing checks:\nswift-tests")
    }

    func testChecksLineWithThreeFailingNamesListsAllThree() {
        let r = row(pr(checks: failing(3, names: ["a", "b", "c"])))
        XCTAssertEqual(r.checksLine, "Checks: 3 failed (a, b, c)")
    }

    func testFiveFailingChecksWithFiveNamesShowThreeThenPlusTwoMore() {
        let r = row(pr(checks: failing(5, names: ["a", "b", "c", "d", "e"])))
        XCTAssertEqual(r.checksLine, "Checks: 5 failed (a, b, c, +2 more)")
        XCTAssertEqual(r.checksTooltip, "Failing checks:\na\nb\nc\nd\ne", "the tooltip lists every failing check")
    }

    func testChecksLineWithFailuresButNoNamesStillCountsThem() {
        let r = row(pr(checks: failing(2, names: [], passed: 5)))
        XCTAssertEqual(r.checksLine, "Checks: 2 failed · 5 passed")
        XCTAssertNil(r.checksTooltip)
    }

    func testChecksLineOrdersFailedThenPendingThenPassed() {
        let r = row(pr(checks: failing(1, names: ["x"], passed: 9, pending: 2)))
        XCTAssertEqual(r.checksLine, "Checks: 1 failed (x) · 2 pending · 9 passed")
    }

    // MARK: Review line

    func testReviewLineNamesExactlyOneReviewState() {
        func line(_ state: AuthoredPrReviewState, _ logins: [String]) -> String {
            row(pr(review: AuthoredPrReview(state: state, logins: logins))).reviewLine
        }
        XCTAssertEqual(line(.approved, ["a", "b"]), "Approved by a, b")
        XCTAssertEqual(line(.changesRequested, ["dana"]), "Changes requested by dana")
        XCTAssertEqual(line(.reviewRequested, ["x"]), "Review requested from x")
        XCTAssertEqual(line(.none, []), "No review yet")
    }

    func testReviewLineAppendsNewCommentsAndUnresolvedThreads() {
        let review = AuthoredPrReview(state: .approved, logins: ["a"])
        XCTAssertEqual(row(pr(review: review, newComments: 3, unresolved: 2)).reviewLine,
                       "Approved by a · 3 new comments · 2 unresolved")
    }

    func testReviewLineUsesTheSingularForOneNewComment() {
        let review = AuthoredPrReview(state: .none)
        XCTAssertEqual(row(pr(review: review, newComments: 1)).reviewLine, "No review yet · 1 new comment")
    }

    func testReviewLineShowsAPlusWhenTheUnresolvedCountWasCut() {
        let review = AuthoredPrReview(state: .changesRequested, logins: ["dana"])
        XCTAssertEqual(row(pr(review: review, unresolved: 2, truncated: true)).reviewLine,
                       "Changes requested by dana · 2+ unresolved")
    }

    func testReviewLineAppendsNothingWhenThereAreNoCommentsOrThreads() {
        let review = AuthoredPrReview(state: .approved, logins: ["a"])
        XCTAssertEqual(row(pr(review: review, newComments: 0, unresolved: 0)).reviewLine, "Approved by a")
    }

    // MARK: Base

    func testBaseIsNilUnlessTheRowHasABaseRef() {
        XCTAssertNil(row(pr(baseRef: nil)).base)
        XCTAssertEqual(row(pr(baseRef: "slash-commands-0")).base, "slash-commands-0")
    }

    // MARK: Owner

    func testOwnerOfAMotherJobLinksTheJobIdAndNamesTheFocus() {
        let owner = AuthoredPrOwner(kind: .motherJob, name: "Cody", jobId: "a1b2c3")
        let r = row(pr(owner: owner))
        XCTAssertEqual(r.ownerPrefix, "Mother job ")
        XCTAssertEqual(r.ownerJobId, "a1b2c3")
        XCTAssertEqual(r.ownerSuffix, " · Cody")
        XCTAssertEqual(r.ownerText, "Mother job a1b2c3 · Cody")
    }

    func testOwnerTextForEveryOtherKind() {
        func text(_ owner: AuthoredPrOwner) -> String { row(pr(owner: owner)).ownerText }
        XCTAssertEqual(text(AuthoredPrOwner(kind: .onBranch, name: "Widgets")), "On branch in Widgets")
        XCTAssertEqual(text(AuthoredPrOwner(kind: .linked, name: "Nostromo daemon")), "Linked to Nostromo daemon")
        XCTAssertEqual(text(AuthoredPrOwner(kind: .ambiguous, candidates: [
            AuthoredPrCandidate(tag: "a", name: "Alpha"), AuthoredPrCandidate(tag: "b", name: "Beta"),
        ])), "2 possible focuses")
        XCTAssertEqual(text(AuthoredPrOwner(kind: .closed, name: "Gone")), "Gone · closed")
        XCTAssertEqual(text(.unknown), "Owner unknown")
    }

    func testOnlyAMotherJobOwnerHasALinkableJobId() {
        XCTAssertNil(row(pr(owner: AuthoredPrOwner(kind: .linked, name: "X"))).ownerJobId)
        XCTAssertNil(row(pr(owner: AuthoredPrOwner(kind: .onBranch, name: "X"))).ownerJobId)
        XCTAssertNil(row(pr(owner: .unknown)).ownerJobId)
    }

    func testOwnerTextAppendsDetailsUnavailableWhenFlagged() {
        let owner = AuthoredPrOwner(kind: .linked, name: "X")
        XCTAssertEqual(row(pr(detailsUnavailable: true, owner: owner)).ownerText, "Linked to X · details unavailable")
        XCTAssertEqual(row(pr(detailsUnavailable: true, owner: .unknown)).ownerText, "Owner unknown · details unavailable")
        XCTAssertEqual(row(pr(detailsUnavailable: false, owner: owner)).ownerText, "Linked to X")
    }

    // MARK: Status

    func testStatusGlyphAndWordForEachChecksState() {
        func assertStatus(_ checks: AuthoredPrChecks, _ glyph: String, _ word: String,
                          _ kind: AuthoredPrRowModel.StatusKind, line: UInt = #line) {
            let r = row(pr(checks: checks))
            XCTAssertEqual(r.statusGlyph, glyph, line: line)
            XCTAssertEqual(r.statusWord, word, line: line)
            XCTAssertEqual(r.statusKind, kind, line: line)
        }
        assertStatus(AuthoredPrChecks(state: .passing, passed: 3), "✓", "passing", .passing)
        assertStatus(failing(1, names: ["x"]), "✗", "failing", .failing)
        assertStatus(AuthoredPrChecks(state: .pending, pending: 1), "●", "pending", .pending)
        assertStatus(AuthoredPrChecks(state: .none), "–", "no checks", .none)
    }

    func testMergedAndClosedRowsSayMergedAndClosedWhateverTheirChecksWere() {
        let passing = AuthoredPrChecks(state: .passing, passed: 6)
        let merged = row(pr(lifecycle: .merged, endedAt: now, checks: passing))
        XCTAssertEqual(merged.statusWord, "Merged")
        XCTAssertEqual(merged.statusKind, .merged)
        XCTAssertEqual(merged.statusGlyph, "◆")

        let closed = row(pr(lifecycle: .closed, endedAt: now, checks: passing))
        XCTAssertEqual(closed.statusWord, "Closed")
        XCTAssertEqual(closed.statusKind, .closed)
        XCTAssertEqual(closed.statusGlyph, "○")
    }

    func testARowCarriesItsIdentityForSelectionAndOpening() {
        let r = row(pr(458, repo: "thehammer/nostromo", title: "Slash commands 1"))
        XCTAssertEqual(r.id, "thehammer/nostromo#458")
        XCTAssertEqual(r.numberText, "#458")
        XCTAssertEqual(r.title, "Slash commands 1")
        XCTAssertEqual(r.url, "https://github.com/thehammer/nostromo/pull/458")
    }

    // MARK: VoiceOver

    func testAccessibilityLabelReadsTheWholeRowInOneBreath() {
        let p = pr(458, repo: "thehammer/nostromo", title: "Slash commands 1", baseRef: "slash-commands-0",
                   checks: failing(1, names: ["swift-tests"]),
                   review: AuthoredPrReview(state: .changesRequested, logins: ["dana"]),
                   newComments: 3,
                   owner: AuthoredPrOwner(kind: .motherJob, name: "Cody", jobId: "job-1"))
        XCTAssertEqual(row(p).accessibilityLabel,
                       "PR 458, Slash commands 1, nostromo, checks failing: swift-tests, changes requested by dana, "
                       + "3 new comments, base slash-commands-0, owner Cody, Mother job")
    }

    func testAccessibilityLabelOfADraftWithNothingGoingOn() {
        let p = pr(5, repo: "o/repo", title: "T", draft: true)
        XCTAssertEqual(row(p).accessibilityLabel, "PR 5, T, repo, draft, no checks, no review yet, owner unknown")
    }

    func testAccessibilityLabelOfAMergedRowSaysMerged() {
        let p = pr(606, repo: "thehammer/nostromo", title: "Release 1.4", lifecycle: .merged, endedAt: now,
                   checks: AuthoredPrChecks(state: .passing, passed: 6),
                   review: AuthoredPrReview(state: .approved, logins: ["bob"]))
        XCTAssertEqual(row(p).accessibilityLabel,
                       "PR 606, Release 1.4, nostromo, merged, checks passing, approved by bob, owner unknown")
    }
}

// MARK: - Groups

final class AuthoredPrsGroupsTests: XCTestCase {

    func testGroupsAreOrderedNeedsYouReadyWaitingDrafts() {
        let prs = [pr(1, group: .draft), pr(2, group: .waiting), pr(3, group: .needsYou), pr(4, group: .ready),
                   pr(5, group: .waiting)]
        XCTAssertEqual(groups(prs).map(\.group), [.needsYou, .ready, .waiting, .draft])
    }

    func testEmptyGroupsAreHidden() {
        XCTAssertEqual(groups([]).map(\.group), [], "no rows, no group headings at all")
        let prs = [pr(1, group: .needsYou), pr(2, group: .draft)]
        XCTAssertEqual(groups(prs).map(\.group), [.needsYou, .draft])
        XCTAssertNil(groups(prs).first { $0.group == .ready }, "Ready is empty and must not appear")
        XCTAssertNil(groups(prs).first { $0.group == .waiting }, "Waiting on others is empty and must not appear")
        XCTAssertTrue(groups(prs).allSatisfy { !$0.rows.isEmpty })
    }

    func testGroupTitles() {
        XCTAssertEqual(P.groupTitle(.needsYou), "NEEDS YOU")
        XCTAssertEqual(P.groupTitle(.ready), "READY")
        XCTAssertEqual(P.groupTitle(.waiting), "WAITING ON OTHERS")
        XCTAssertEqual(P.groupTitle(.draft), "DRAFTS")
        let models = groups([pr(1, group: .needsYou), pr(2, group: .waiting)])
        XCTAssertEqual(models.map(\.title), ["NEEDS YOU", "WAITING ON OTHERS"])
    }

    func testAGroupHeadingIsReadAsWordsWithItsCount() {
        let prs = [pr(1, group: .needsYou), pr(2, group: .needsYou), pr(3, group: .needsYou), pr(4, group: .waiting)]
        let models = groups(prs)
        XCTAssertEqual(models.first { $0.group == .needsYou }?.accessibilityLabel, "Needs you, 3")
        XCTAssertEqual(models.first { $0.group == .waiting }?.accessibilityLabel, "Waiting on others, 1")
    }

    func testAGroupShows25RowsThenShowNMore() throws {
        let prs = (1...30).map { pr($0, group: .waiting) }
        let g = try XCTUnwrap(groups(prs).first)
        XCTAssertEqual(g.rows.count, 25)
        XCTAssertEqual(g.rows.map(\.number), Array(1...25), "the daemon's order is kept; the cap takes the first rows")
        XCTAssertEqual(g.count, 30, "the group's count is the full count, not the shown count")
        XCTAssertEqual(g.hiddenCount, 5)
        XCTAssertEqual(g.showMoreTitle, "Show 5 more")
    }

    func testShowAllLiftsTheLimitForThatGroupOnly() throws {
        let prs = (1...30).map { pr($0, group: .waiting) } + (101...130).map { pr($0, group: .ready) }

        let lifted = groups(prs, showAll: [.waiting])
        let waiting = try XCTUnwrap(lifted.first { $0.group == .waiting })
        XCTAssertEqual(waiting.rows.count, 30)
        XCTAssertEqual(waiting.count, 30)
        XCTAssertNil(waiting.showMoreTitle)

        let ready = try XCTUnwrap(lifted.first { $0.group == .ready })
        XCTAssertEqual(ready.rows.count, 25, "showing all of Waiting must not expand Ready")
        XCTAssertEqual(ready.showMoreTitle, "Show 5 more")
    }

    func testAGroupOfExactly25RowsHasNoShowMore() throws {
        let prs = (1...25).map { pr($0, group: .ready) }
        let g = try XCTUnwrap(groups(prs).first)
        XCTAssertEqual(g.rows.count, 25)
        XCTAssertEqual(g.hiddenCount, 0)
        XCTAssertNil(g.showMoreTitle)
    }

    // MARK: Repo chips

    func testRepoChipIsTheBareRepoNameWhenNamesAreDistinct() throws {
        let prs = [pr(1, repo: "thehammer/nostromo", group: .ready), pr(2, repo: "Carefeed/admin-portal", group: .ready)]
        let rows = try XCTUnwrap(groups(prs).first).rows
        XCTAssertEqual(rows.map(\.repoChip), ["nostromo", "admin-portal"])
    }

    func testRepoChipKeepsTheOwnerWhenTwoShownReposShareAName() {
        let prs = [pr(1, repo: "Carefeed/app", group: .ready), pr(2, repo: "other/app", group: .waiting),
                   pr(3, repo: "thehammer/nostromo", group: .waiting)]
        let all = groups(prs).flatMap(\.rows)
        XCTAssertEqual(all.first { $0.number == 1 }?.repoChip, "Carefeed/app")
        XCTAssertEqual(all.first { $0.number == 2 }?.repoChip, "other/app")
        XCTAssertEqual(all.first { $0.number == 3 }?.repoChip, "nostromo")
    }

    func testTwoPrsInTheSameRepoDoNotMakeTheNameAmbiguous() {
        let prs = [pr(1, repo: "Carefeed/app", group: .ready), pr(2, repo: "Carefeed/app", group: .waiting)]
        XCTAssertEqual(groups(prs).flatMap(\.rows).map(\.repoChip), ["app", "app"])
    }
}

// MARK: - Lifecycle

final class AuthoredPrsLifecycleTests: XCTestCase {

    func testAMergedRowExpiresExactlySixtySecondsAfterItEnded() {
        let ended = at("2026-11-14T20:58:00Z")
        let merged = pr(1, lifecycle: .merged, endedAt: ended)
        XCTAssertFalse(P.isExpired(merged, now: ended))
        XCTAssertFalse(P.isExpired(merged, now: ended.addingTimeInterval(59)))
        XCTAssertTrue(P.isExpired(merged, now: ended.addingTimeInterval(60)))
        XCTAssertTrue(P.isExpired(merged, now: ended.addingTimeInterval(61)))
    }

    func testAClosedRowExpiresTheSameWay() {
        let ended = at("2026-11-14T20:58:00Z")
        let closed = pr(1, lifecycle: .closed, endedAt: ended)
        XCTAssertFalse(P.isExpired(closed, now: ended.addingTimeInterval(59)))
        XCTAssertTrue(P.isExpired(closed, now: ended.addingTimeInterval(60)))
    }

    func testAnOpenRowNeverExpires() {
        let open = pr(1, lifecycle: .open, endedAt: at("2020-01-01T00:00:00Z"))
        XCTAssertFalse(P.isExpired(open, now: now))
        XCTAssertFalse(P.isExpired(pr(2), now: now.addingTimeInterval(86400 * 365)))
    }
}

// MARK: - Body states and notes

final class AuthoredPrsBodyTests: XCTestCase {

    private func snapshot(token: AuthoredPrsTokenState = .connected, prs: [AuthoredPr] = [],
                          hiddenOrgs: [String] = []) -> AuthoredPrsSnapshot {
        AuthoredPrsSnapshot(token: token, hiddenOrgs: hiddenOrgs, prs: prs)
    }

    func testAMissingTokenIsNotConnectedAndARejectedOneSaysRejected() {
        XCTAssertEqual(P.body(snapshot(token: .missing)), .notConnected(rejected: false))
        XCTAssertEqual(P.body(snapshot(token: .rejected)), .notConnected(rejected: true))
    }

    func testWithoutAConnectionThereIsNoListEvenIfRowsArrived() {
        XCTAssertEqual(P.body(snapshot(token: .missing, prs: [pr(1)])), .notConnected(rejected: false))
        XCTAssertEqual(P.body(snapshot(token: .rejected, prs: [pr(1)])), .notConnected(rejected: true))
    }

    func testConnectedWithNoRowsIsEmptyAndWithRowsIsAList() {
        XCTAssertEqual(P.body(snapshot(prs: [])), .empty)
        XCTAssertEqual(P.body(snapshot(prs: [pr(1)])), .list)
    }

    func testHiddenOrgsNoteNamesTheOrgsGitHubDenied() {
        XCTAssertEqual(P.hiddenOrgsNote(snapshot(hiddenOrgs: ["X", "Y"])),
                       "Some repos hidden: GitHub denied access to org X, Y.")
        XCTAssertNil(P.hiddenOrgsNote(snapshot(hiddenOrgs: [])))
    }

    // MARK: Usage report

    private func counts(_ values: [Int]) -> AuthoredPrsUsageCounts {
        var c = AuthoredPrsUsageCounts()
        c.charged = values[0]; c.notModified = values[1]; c.search = values[2]; c.graphqlPoints = values[3]
        c.relayCharged = values[4]; c.visibleCharged = values[5]; c.hiddenCharged = values[6]
        return c
    }

    func testUsageReportHasTheCountsAndNothingElse() {
        let window = [41, 17, 22, 19, 4, 36, 5]
        let sinceStart = [120, 80, 101, 70, 12, 99, 21]
        let usage = AuthoredPrsUsage(windowSecs: 3600, window: counts(window), sinceStart: counts(sinceStart))
        let report = P.usageReport(usage)

        for n in window + sinceStart {
            XCTAssertTrue(report.contains(String(n)), "the report is missing \(n):\n\(report)")
        }

        // It is built from counts: a snapshot full of repo, title and login text leaks none of it.
        let secretive = AuthoredPrsSnapshot(
            hiddenOrgs: ["secret-org"],
            prs: [pr(7, repo: "acme/secret-repo", title: "Secret roadmap",
                     review: AuthoredPrReview(state: .approved, logins: ["mallory"]))],
            usage: usage)
        let fromSnapshot = P.usageReport(secretive.usage)
        for leaked in ["acme", "secret-repo", "Secret roadmap", "mallory", "secret-org", "thehammer"] {
            XCTAssertFalse(fromSnapshot.localizedCaseInsensitiveContains(leaked), "\(leaked) leaked into the usage report")
        }

        // Only words, numbers, spaces, colons and commas: no slashes, hashes, quotes or URLs.
        let allowed = CharacterSet.alphanumerics.union(.whitespacesAndNewlines).union(CharacterSet(charactersIn: ":,"))
        XCTAssertTrue(report.unicodeScalars.allSatisfy { allowed.contains($0) }, report)
    }
}
