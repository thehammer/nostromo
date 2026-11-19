// NostromoKit — AuthoredPrsFilterTests.swift
//
// The My open PRs Overview's Repo and Session filter, as pure functions of the PRs and a selection: which
// PRs show, what the two pop-ups offer and call each entry, what the empty message says, how a selection is
// remembered, and the "n of m" wording the header and the group headers take from it.
//
// Mutations this file is meant to catch, and the test that fails for each:
//   (a) the filter is applied to the count the pinned row / header `count` carries (the header's `count`
//       becomes the matched number)
//        -> testHeaderCountStaysTheTotalWhileTheTextSaysNOfM
//           (the Mac side of this, the pinned Overview row and the sidebar pills, is in
//            AuthoredPrsFilterBarTests.testAFilterThatHidesEverythingNeverChangesThePinnedRowsCountOrTheSidebarPills)
//   (b) repo AND session turned into repo OR session
//        -> testRepoAndSessionCombineWithAndNotOr
//   (c) a name that came from an agent or GitHub shown as it arrived (bidi override, control characters, no cap)
//        -> testAnOwnersNameIsSanitisedAndCappedInTheMenuAndTheEmptyMessage,
//           testARepoNameIsSanitisedAndCappedButStillMatchesByItsRawName
//   (d) a selected repo or session that has no PRs left is silently reset to All, or dropped from its pop-up
//        -> testASelectedRepoWithNoPrsStaysSelectedAndListedWithZero,
//           testASelectedSessionWithNoPrsStaysSelectedAndListedWithZero,
//           testSelectingNoSessionWhenEveryPrHasAnOwnerStillListsItWithZero
//   (e) a group's count shows only what matches (or only the total) instead of "n of m"
//        -> testGroupCountsReadNOfMWhileFilteredAndJustNWhenNot
//   (f) a stale or malformed stored value (a number, "", an unknown prefix, an overlong string) is believed
//        -> testStaleOrMalformedStoredValuesReadAsAll
//   (g) closed / unknown / ambiguous owners, or one with no tag, are given a session of their own or dropped
//        -> testNoSessionHoldsEveryPrWhoseOwnerIsClosedUnknownAmbiguousOrTagless
//   (h) a repo chip's wording changes when the filter hides the repo it shared a name with
//        -> testRepoChipsAreComputedOverTheUnfilteredList
//   (i) counts in the pop-ups follow the selection instead of the whole list
//        -> testPopUpCountsDoNotChangeWithTheSelection
//   (j) entries not sorted A-Z (case-insensitively), or `No session` not last
//        -> testRepoEntriesAreAToZIgnoringCase, testSessionEntriesAreAToZByNameThenNoSession

import XCTest
@testable import NostromoKit

// MARK: - Helpers

private typealias F = AuthoredPrsFilter
private typealias Selection = AuthoredPrsFilterSelection

private let chicago = TimeZone(identifier: "America/Chicago")!
private let now = ISO8601DateFormatter().date(from: "2026-11-14T21:00:00Z")!

private func owner(_ kind: AuthoredPrOwnerKind = .motherJob, tag: String? = nil, name: String? = nil) -> AuthoredPrOwner {
    AuthoredPrOwner(kind: kind, tag: tag, name: name, jobId: kind == .motherJob ? "job" : nil)
}

private func pr(_ number: Int, repo: String = "carefeed/portal", group: AuthoredPrGroup = .waiting,
                lifecycle: AuthoredPrLifecycle = .open, owner: AuthoredPrOwner = .unknown) -> AuthoredPr {
    AuthoredPr(repo: repo, number: number, url: "https://github.com/\(repo)/pull/\(number)", title: "PR \(number)",
               draft: false, updatedAt: nil, group: group, lifecycle: lifecycle, endedAt: nil, baseRef: nil,
               detailsUnavailable: false, checks: AuthoredPrChecks(state: .none), review: AuthoredPrReview(state: .none),
               newComments: 0, unresolvedThreads: 0, threadsTruncated: false, owner: owner)
}

private func numbers(_ result: AuthoredPrsFilterResult) -> [Int] { result.prs.map(\.number) }

private let alpha = owner(tag: "alpha-tag", name: "Alpha")
private let bravo = owner(.linked, tag: "bravo-tag", name: "bravo")

/// 1 portal/Alpha, 2 portal/bravo, 3 nostromo/Alpha, 4 nostromo/closed owner, 5 nostromo/unknown owner,
/// 6 portal/ambiguous owner, 7 portal/tag-less owner, 8 api/on-branch owner with an empty tag.
private func fixture() -> [AuthoredPr] {
    [
        pr(1, repo: "carefeed/portal", owner: alpha),
        pr(2, repo: "carefeed/portal", owner: bravo),
        pr(3, repo: "thehammer/nostromo", owner: alpha),
        pr(4, repo: "thehammer/nostromo", owner: owner(.closed, tag: "gone-tag", name: "Gone")),
        pr(5, repo: "thehammer/nostromo", owner: .unknown),
        pr(6, repo: "carefeed/portal", owner: owner(.ambiguous, tag: "x", name: "Maybe")),
        pr(7, repo: "carefeed/portal", owner: owner(.linked, tag: nil, name: "Nameless")),
        pr(8, repo: "carefeed/api", owner: owner(.onBranch, tag: "", name: "Empty tag")),
    ]
}

private func hasBidiOrControl(_ s: String) -> Bool {
    s.unicodeScalars.contains { scalar in
        let v = scalar.value
        return v < 0x20 || v == 0x7F || (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v)
            || v == 0x200E || v == 0x200F || v == 0x061C
    }
}

// MARK: - Which PRs show

final class AuthoredPrsFilterTests: XCTestCase {

    func testNoSelectionShowsEveryPrInTheOrderItCame() {
        let result = F.apply(fixture(), selection: .all)
        XCTAssertEqual(numbers(result), [1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(result.matched, 8)
        XCTAssertEqual(result.total, 8)
        XCTAssertFalse(result.selection.isActive)
        XCTAssertEqual(result.emptyState, .none)
    }

    func testARepoSelectionShowsOnlyThatReposPrsInTheirOrder() {
        let result = F.apply(fixture(), selection: Selection(repo: .repo("carefeed/portal")))
        XCTAssertEqual(numbers(result), [1, 2, 6, 7])
        XCTAssertEqual(result.matched, 4)
        XCTAssertEqual(result.total, 8)
        XCTAssertTrue(result.selection.isActive)
    }

    func testASessionSelectionShowsOnlyPrsOwnedByThatFocus() {
        let result = F.apply(fixture(), selection: Selection(session: .focus(tag: "alpha-tag")))
        XCTAssertEqual(numbers(result), [1, 3])
    }

    func testRepoAndSessionCombineWithAndNotOr() {
        // Alpha owns 1 and 3; portal holds 1, 2, 6 and 7. OR would also return 2, 3, 6 and 7.
        let result = F.apply(fixture(), selection: Selection(repo: .repo("carefeed/portal"), session: .focus(tag: "alpha-tag")))
        XCTAssertEqual(numbers(result), [1])
        XCTAssertEqual(result.matched, 1)

        let noSessionInNostromo = F.apply(fixture(), selection: Selection(repo: .repo("thehammer/nostromo"), session: .noSession))
        XCTAssertEqual(numbers(noSessionInNostromo), [4, 5], "OR would also return the other repos' ownerless PRs")
    }

    func testNoSessionHoldsEveryPrWhoseOwnerIsClosedUnknownAmbiguousOrTagless() {
        let result = F.apply(fixture(), selection: Selection(session: .noSession))
        XCTAssertEqual(numbers(result), [4, 5, 6, 7, 8])
        XCTAssertEqual(F.session(of: fixture()[3]), .noSession, "closed")
        XCTAssertEqual(F.session(of: fixture()[4]), .noSession, "unknown")
        XCTAssertEqual(F.session(of: fixture()[5]), .noSession, "ambiguous")
        XCTAssertEqual(F.session(of: fixture()[6]), .noSession, "no tag")
        XCTAssertEqual(F.session(of: fixture()[7]), .noSession, "an empty tag")
        XCTAssertEqual(F.session(of: fixture()[0]), .focus(tag: "alpha-tag"))
    }

    func testAllThreeKindsOfLiveOwnerCountAsASession() {
        let prs = [pr(1, owner: owner(.motherJob, tag: "m", name: "M")),
                   pr(2, owner: owner(.linked, tag: "l", name: "L")),
                   pr(3, owner: owner(.onBranch, tag: "b", name: "B"))]
        let result = F.apply(prs, selection: .all)
        XCTAssertEqual(result.sessionEntries.map(\.title), ["All", "B", "L", "M"], "no No session entry: every PR has an owner")
    }

    // MARK: - The pop-ups

    func testRepoEntriesAreAToZIgnoringCase() {
        let prs = [pr(1, repo: "zeta/one"), pr(2, repo: "Alpha/two"), pr(3, repo: "beta/three"), pr(4, repo: "alpha/zzz")]
        let titles = F.apply(prs, selection: .all).repoEntries.map(\.title)
        XCTAssertEqual(titles.first, "All")
        XCTAssertEqual(Array(titles.dropFirst()), ["Alpha/two", "alpha/zzz", "beta/three", "zeta/one"])
    }

    func testPopUpCountsAreHowManyPrsEachEntryHoldsAndMenuTitlesCarryThem() {
        let result = F.apply(fixture(), selection: .all)
        let repos = Dictionary(uniqueKeysWithValues: result.repoEntries.map { ($0.title, $0.count) })
        XCTAssertEqual(repos, ["All": 8, "carefeed/portal": 4, "thehammer/nostromo": 3, "carefeed/api": 1])
        XCTAssertEqual(result.repoEntries.first?.menuTitle, "All (8)")
        XCTAssertEqual(result.repoEntries.first { $0.title == "carefeed/portal" }?.menuTitle, "carefeed/portal (4)")

        let sessions = Dictionary(uniqueKeysWithValues: result.sessionEntries.map { ($0.title, $0.count) })
        XCTAssertEqual(sessions, ["All": 8, "Alpha": 2, "bravo": 1, "No session": 5])
        XCTAssertEqual(result.sessionEntries.first { $0.title == "Alpha" }?.menuTitle, "Alpha (2)")
    }

    func testPopUpCountsDoNotChangeWithTheSelection() {
        let all = F.apply(fixture(), selection: .all)
        let filtered = F.apply(fixture(), selection: Selection(repo: .repo("carefeed/portal"), session: .focus(tag: "alpha-tag")))
        XCTAssertEqual(filtered.repoEntries, all.repoEntries)
        XCTAssertEqual(filtered.sessionEntries, all.sessionEntries)
    }

    func testSessionEntriesAreAToZByNameThenNoSession() {
        let prs = [pr(1, owner: owner(tag: "t1", name: "zulu")), pr(2, owner: owner(tag: "t2", name: "Alpha")),
                   pr(3, owner: .unknown), pr(4, owner: owner(tag: "t3", name: "bravo"))]
        let titles = F.apply(prs, selection: .all).sessionEntries.map(\.title)
        XCTAssertEqual(titles, ["All", "Alpha", "bravo", "zulu", "No session"])
    }

    func testTwoFocusesWithTheSameNameAreTwoEntriesThatSelectDifferently() {
        let prs = [pr(1, owner: owner(tag: "t1", name: "Cody")), pr(2, owner: owner(tag: "t2", name: "Cody"))]
        let entries = F.apply(prs, selection: .all).sessionEntries.dropFirst()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.map(\.selection)).count, 2)
        XCTAssertEqual(numbers(F.apply(prs, selection: Selection(session: .focus(tag: "t2")))), [2])
    }

    func testAFocusWithoutANameIsCalledByItsTagAndOneWithNeitherIsCalledFocus() {
        let prs = [pr(1, owner: owner(tag: "tagged-focus", name: nil)), pr(2, owner: owner(tag: "other", name: "  "))]
        let titles = F.apply(prs, selection: .all).sessionEntries.map(\.title)
        XCTAssertEqual(titles, ["All", "other", "tagged-focus"])
    }

    // MARK: - Selection kept when nothing is left

    func testASelectedRepoWithNoPrsStaysSelectedAndListedWithZero() {
        let result = F.apply(fixture(), selection: Selection(repo: .repo("gone/repo")))
        XCTAssertEqual(result.selection.repo, .repo("gone/repo"), "not reset to All")
        XCTAssertEqual(result.matched, 0)
        let entry = result.repoEntries.first { $0.selection == .repo("gone/repo") }
        XCTAssertEqual(entry?.count, 0)
        XCTAssertEqual(entry?.menuTitle, "gone/repo (0)")
        XCTAssertEqual(result.repoTitle, "gone/repo")
        XCTAssertEqual(result.repoEntries.count, 5, "All, the three real repos and the selected one")
    }

    func testASelectedSessionWithNoPrsStaysSelectedAndListedWithZero() {
        let result = F.apply(fixture(), selection: Selection(session: .focus(tag: "vanished-tag")))
        XCTAssertEqual(result.selection.session, .focus(tag: "vanished-tag"))
        XCTAssertEqual(result.matched, 0)
        let entry = result.sessionEntries.first { $0.selection == .focus(tag: "vanished-tag") }
        XCTAssertEqual(entry?.count, 0)
        XCTAssertEqual(entry?.title, "vanished-tag", "no name is known for it: its tag is the best name there is")
        XCTAssertEqual(result.sessionTitle, "vanished-tag")
    }

    func testSelectingNoSessionWhenEveryPrHasAnOwnerStillListsItWithZero() {
        let prs = [pr(1, owner: alpha), pr(2, owner: bravo)]
        let result = F.apply(prs, selection: Selection(session: .noSession))
        XCTAssertEqual(result.selection.session, .noSession)
        XCTAssertEqual(result.sessionEntries.last?.selection, .noSession)
        XCTAssertEqual(result.sessionEntries.last?.count, 0)
        XCTAssertEqual(result.matched, 0)
    }

    func testWhenTheListEmptiesAltogetherTheSelectionIsStillKeptAndThereIsNoNoMatchMessage() {
        let result = F.apply([], selection: Selection(repo: .repo("a/b"), session: .noSession))
        XCTAssertEqual(result.selection, Selection(repo: .repo("a/b"), session: .noSession))
        XCTAssertEqual(result.total, 0)
        XCTAssertEqual(result.emptyState, .none, "an empty list has its own message; this one is for PRs that exist but are filtered out")
    }

    // MARK: - Empty-state wording

    func testEmptyStateNamesWhatWasSelected() {
        let prs = fixture()
        XCTAssertEqual(F.apply(prs, selection: Selection(repo: .repo("gone/repo"))).emptyState,
                       .noMatch(text: "No PRs in gone/repo."))
        XCTAssertEqual(F.apply(prs, selection: Selection(session: .focus(tag: "vanished-tag"))).emptyState,
                       .noMatch(text: "No PRs from vanished-tag."))
        XCTAssertEqual(F.apply([pr(1, owner: alpha)], selection: Selection(session: .noSession)).emptyState,
                       .noMatch(text: "No PRs without a session."))
        XCTAssertEqual(F.apply(prs, selection: Selection(repo: .repo("carefeed/api"), session: .focus(tag: "alpha-tag"))).emptyState,
                       .noMatch(text: "No PRs in carefeed/api from Alpha."))
        XCTAssertEqual(F.apply(prs, selection: Selection(repo: .repo("thehammer/nostromo"), session: .focus(tag: "bravo-tag"))).emptyState,
                       .noMatch(text: "No PRs in thehammer/nostromo from bravo."))
    }

    func testNoEmptyStateWhileAnythingMatches() {
        XCTAssertEqual(F.apply(fixture(), selection: Selection(repo: .repo("carefeed/portal"))).emptyState, .none)
    }

    // MARK: - Untrusted names

    func testAnOwnersNameIsSanitisedAndCappedInTheMenuAndTheEmptyMessage() {
        // Built directly, so the wire's own cleaning never ran.
        let hostile = "Co\u{202E}dy\u{0007}\u{2066}x" + String(repeating: "n", count: 100)
        let prs = [pr(1, owner: owner(tag: "t", name: hostile))]
        let result = F.apply(prs, selection: .all)
        let title = result.sessionEntries[1].title
        XCTAssertFalse(hasBidiOrControl(title), "no bidi or control character reaches the menu")
        XCTAssertFalse(hasBidiOrControl(result.sessionEntries[1].menuTitle))
        XCTAssertTrue(title.hasPrefix("Cody"), "what is printable is kept: \(title)")
        XCTAssertLessThanOrEqual(title.count, 40, "capped like the job list's From: names")
        XCTAssertTrue(title.hasSuffix("…"))

        let selected = F.apply(prs, selection: Selection(repo: .repo("none/there"), session: .focus(tag: "t")))
        guard case .noMatch(let text) = selected.emptyState else { return XCTFail("expected a no-match message") }
        XCTAssertFalse(hasBidiOrControl(text))
        XCTAssertFalse(hasBidiOrControl(selected.sessionTitle))
        XCTAssertLessThanOrEqual(selected.sessionTitle.count, 40)
    }

    func testAControlCharacterOnlyNameFallsBackToTheTag() {
        let prs = [pr(1, owner: owner(tag: "fallback-tag", name: "\u{202E}\u{0007}\n"))]
        XCTAssertEqual(F.apply(prs, selection: .all).sessionEntries[1].title, "fallback-tag")
    }

    func testARepoNameIsSanitisedAndCappedButStillMatchesByItsRawName() {
        let hostile = "evil\u{202E}/re\u{0000}po-" + String(repeating: "r", count: 100)
        let prs = [pr(1, repo: hostile), pr(2, repo: "carefeed/portal")]
        let result = F.apply(prs, selection: Selection(repo: .repo(hostile)))
        XCTAssertEqual(numbers(result), [1], "matching uses the repo as the daemon named it")
        let entry = result.repoEntries.first { $0.selection == .repo(hostile) }
        let title = entry?.title ?? ""
        XCTAssertFalse(hasBidiOrControl(title))
        XCTAssertFalse(hasBidiOrControl(result.repoTitle))
        XCTAssertLessThanOrEqual(title.count, 60)
        XCTAssertTrue(title.hasPrefix("evil/re"), "printable text survives: \(title)")
        XCTAssertTrue(title.hasSuffix("…"))
    }

    func testARepoWithNothingPrintableIsCalledUnnamed() {
        let result = F.apply([pr(1, repo: "\u{202E}\u{0007}")], selection: .all)
        XCTAssertEqual(result.repoEntries[1].title, "unnamed repo")
    }

    // MARK: - Remembering the selection

    func testASelectionRoundTripsThroughItsStoredForm() {
        let selections: [Selection] = [
            .all,
            Selection(repo: .repo("carefeed/portal")),
            Selection(session: .focus(tag: "alpha-tag")),
            Selection(session: .noSession),
            Selection(repo: .repo("a/b"), session: .focus(tag: "weird tag: with colon")),
            Selection(repo: .repo("a/b"), session: .noSession),
        ]
        for selection in selections {
            let stored = F.stored(selection)
            XCTAssertEqual(F.selection(storedRepo: stored.repo, storedSession: stored.session), selection, "\(selection)")
        }
    }

    func testAllIsStoredAsNothing() {
        let stored = F.stored(.all)
        XCTAssertNil(stored.repo)
        XCTAssertNil(stored.session)
    }

    func testStaleOrMalformedStoredValuesReadAsAll() {
        let long = String(repeating: "x", count: 500)
        let garbage: [Any?] = [nil, 42, 3.5, true, [String](), "", "bogus", "bogus:thing", "focus:", "FOCUS:abc", long, "focus:" + long]
        for value in garbage {
            let selection = F.selection(storedRepo: value, storedSession: value)
            // A non-empty, sane string is a legitimate repo name; everything else must read as All.
            if let s = value as? String, !s.isEmpty, s.count <= 200 {
                XCTAssertEqual(selection.repo, .repo(s), "\(s)")
            } else {
                XCTAssertEqual(selection.repo, .all, "repo from \(String(describing: value))")
            }
            XCTAssertEqual(selection.session, .all, "session from \(String(describing: value))")
        }
    }

    func testOnlyAStoredShapeThatStoredWritesIsReadBackAsASession() {
        XCTAssertEqual(F.selection(storedRepo: nil, storedSession: "none").session, .noSession)
        XCTAssertEqual(F.selection(storedRepo: nil, storedSession: "focus:abc").session, .focus(tag: "abc"))
        XCTAssertEqual(F.selection(storedRepo: 7, storedSession: 7), .all)
    }

    // MARK: - Header and group wording

    private func snapshot(_ prs: [AuthoredPr]) -> AuthoredPrsSnapshot {
        AuthoredPrsSnapshot(generatedAt: now, token: .connected, relay: AuthoredPrsRelay(state: .live),
                            poll: AuthoredPrsPoll(state: .ok, checkedAt: now.addingTimeInterval(-40), intervalSecs: 60),
                            refreshBlocked: nil, hiddenOrgs: [], totalOpen: nil, shown: nil, prs: prs, usage: AuthoredPrsUsage())
    }

    func testHeaderCountStaysTheTotalWhileTheTextSaysNOfM() {
        let prs = (1...12).map { pr($0) }
        let filtered = AuthoredPrsPresentation.header(snapshot(prs), now: now, timeZone: chicago, matchedOpen: 3)
        XCTAssertEqual(filtered.countText, "My open PRs · 3 of 12")
        XCTAssertEqual(filtered.count, 12, "the count is every open PR, whatever the filter shows")

        let none = AuthoredPrsPresentation.header(snapshot(prs), now: now, timeZone: chicago, matchedOpen: 0)
        XCTAssertEqual(none.countText, "My open PRs · 0 of 12")
        XCTAssertEqual(none.count, 12)

        let plain = AuthoredPrsPresentation.header(snapshot(prs), now: now, timeZone: chicago)
        XCTAssertEqual(plain.countText, "My open PRs · 12", "no filter, no 'of'")
        XCTAssertEqual(plain.count, 12)
    }

    func testHeaderTotalIgnoresPrsThatAreNotOpen() {
        let prs = (1...5).map { pr($0) } + [pr(6, group: .ready, lifecycle: .merged)]
        let model = AuthoredPrsPresentation.header(snapshot(prs), now: now, timeZone: chicago, matchedOpen: 2)
        XCTAssertEqual(model.countText, "My open PRs · 2 of 5")
    }

    func testGroupCountsReadNOfMWhileFilteredAndJustNWhenNot() throws {
        let all = [pr(1, group: .needsYou), pr(2, group: .needsYou), pr(3, group: .needsYou),
                   pr(4, group: .needsYou), pr(5, group: .needsYou), pr(6, group: .waiting)]
        let matching = Array(all.prefix(2))

        let filtered = AuthoredPrsPresentation.groups(matching, unfiltered: all, now: now, timeZone: chicago)
        XCTAssertEqual(filtered.map(\.group), [.needsYou], "a group with nothing matching is hidden")
        let needsYou = try XCTUnwrap(filtered.first)
        XCTAssertEqual(needsYou.count, 2)
        XCTAssertEqual(needsYou.unfilteredCount, 5)
        XCTAssertEqual(needsYou.countText, "2 of 5")
        XCTAssertEqual(needsYou.accessibilityLabel, "Needs you, 2 of 5")

        let plain = try XCTUnwrap(AuthoredPrsPresentation.groups(all, now: now, timeZone: chicago).first)
        XCTAssertEqual(plain.countText, "5")
        XCTAssertEqual(plain.accessibilityLabel, "Needs you, 5")
        XCTAssertNil(plain.unfilteredCount)
    }

    func testAGroupWhoseEveryPrMatchesStillSaysNOfN() throws {
        let all = [pr(1, group: .ready), pr(2, group: .waiting)]
        let model = try XCTUnwrap(AuthoredPrsPresentation.groups([all[0]], unfiltered: all, now: now, timeZone: chicago).first)
        XCTAssertEqual(model.countText, "1 of 1", "the filter is on, so the wording says so")
    }

    func testRepoChipsAreComputedOverTheUnfilteredList() throws {
        let a = pr(1, repo: "one/portal", group: .needsYou)
        let b = pr(2, repo: "two/portal", group: .needsYou)
        // Filtered to one repo, the two portals no longer collide among the shown rows; the chip must not shorten.
        let filtered = AuthoredPrsPresentation.groups([a], unfiltered: [a, b], now: now, timeZone: chicago)
        XCTAssertEqual(filtered.first?.rows.first?.repoChip, "one/portal")
        let plain = AuthoredPrsPresentation.groups([a], now: now, timeZone: chicago)
        XCTAssertEqual(plain.first?.rows.first?.repoChip, "portal", "unfiltered behaviour is unchanged")
    }
}
