// NostromoKit — AuthoredPrsFilterTests.swift
//
// The My open PRs Overview's Org, Repo and Session filter, as pure functions of the PRs and a selection: which
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
//   (i) counts in the pop-ups follow the repo / session selection instead of the (org-scoped) list
//        -> testRepoAndSessionCountsDoNotChangeWithTheRepoOrSessionSelection
//   (j) entries not sorted A-Z (case-insensitively), or `No session` not last
//        -> testRepoEntriesAreAToZIgnoringCase, testSessionEntriesAreAToZByNameThenNoSession
//   (k) Org AND turned into OR with repo / session in `matching`
//        -> testOrgRepoAndSessionCombineWithAndNotOr
//   (l) org grouping is case-sensitive (drop `.lowercased()` in `orgKey`), or shows the last-seen spelling
//        -> testOneOrgWhateverTheCaseShowsTheFirstSeenSpelling
//   (m) an owner's name shown unsanitised or uncapped in the Org pop-up / empty message (or the tooltip text
//       capped or unsanitised)
//        -> testAHostileOwnerNameIsSanitisedAndCappedInTheOrgMenuWithAnUncappedSanitisedTooltipName
//   (n) rows with no owner part (`noslash`, `/x`, ` /x`) get an org entry, or leave `All`
//        -> testRowsWithNoOwnerPartHaveNoOrgButAreUnderAll
//   (o) Repo / Session entries ignore the Org selection, or an org change resets the selected repo
//        -> testRepoAndSessionEntriesNarrowToTheSelectedOrg, testChangingTheOrgNeverResetsTheSelectedRepo
//   (p) org entries not sorted count-descending then A-Z, or org counts following repo / session
//        -> testOrgEntriesAreAllThenEachOwnerMostPrsFirstThenAToZ, testOrgCountsAreOverTheWholeListWhateverTheRepoAndSessionSelection
//   (q) a selected org that has no PRs left is reset or dropped, or its empty message is generic
//        -> testASelectedOrgWithNoPrsStaysSelectedListedWithZeroAndNamedInTheEmptyMessage
//   (r) the org is not persisted, or a garbage / uppercase / slashed / overlong stored org is believed
//        -> testASelectionRoundTripsThroughItsStoredForm, testStaleOrMalformedStoredOrgsReadAsAll

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

    func testRepoAndSessionCountsDoNotChangeWithTheRepoOrSessionSelection() {
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
            Selection(org: .org("carefeed")),
            Selection(org: .org("the-hammer_1"), repo: .repo("the-hammer_1/x"), session: .focus(tag: "alpha-tag")),
            Selection(org: .org("carefeed"), session: .noSession),
        ]
        for selection in selections {
            let stored = F.stored(selection)
            XCTAssertEqual(F.selection(storedOrg: stored.org, storedRepo: stored.repo, storedSession: stored.session), selection, "\(selection)")
        }
    }

    func testAllIsStoredAsNothing() {
        let stored = F.stored(.all)
        XCTAssertNil(stored.org)
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

    func testStaleOrMalformedStoredOrgsReadAsAll() {
        let long = String(repeating: "x", count: 500)
        let garbage: [Any?] = [nil, 42, 3.5, true, [String](), "", "Carefeed", "CAREFEED", "carefeed/portal", "a/b", "/", " carefeed",
                               "carefeed ", "\ncarefeed", long]
        for value in garbage {
            let selection = F.selection(storedOrg: value, storedRepo: nil, storedSession: nil)
            XCTAssertEqual(selection, .all, "org from \(String(describing: value))")
        }
        XCTAssertEqual(F.selection(storedOrg: "carefeed", storedRepo: nil, storedSession: nil), Selection(org: .org("carefeed")))
        // A bad org does not take a good repo or session down with it.
        let mixed = F.selection(storedOrg: 42, storedRepo: "a/b", storedSession: "none")
        XCTAssertEqual(mixed, Selection(repo: .repo("a/b"), session: .noSession))
    }

    func testTheOrgIsStoredAsItsLowercasedOwnerUnderItsOwnValue() {
        let stored = F.stored(Selection(org: .org("carefeed"), repo: .repo("Carefeed/portal"), session: .noSession))
        XCTAssertEqual(stored.org, "carefeed")
        XCTAssertEqual(stored.repo, "Carefeed/portal")
        XCTAssertEqual(stored.session, "none")
    }

    // MARK: - Org

    /// 1 Carefeed/portal (Alpha), 2 carefeed/api (bravo), 3 CAREFEED/web (Alpha), 4 thehammer/nostromo (Alpha),
    /// 5 thehammer/nostromo (no owner), 6 solo/tool (bravo).
    private func orgFixture() -> [AuthoredPr] {
        [pr(1, repo: "Carefeed/portal", owner: alpha),
         pr(2, repo: "carefeed/api", owner: bravo),
         pr(3, repo: "CAREFEED/web", owner: alpha),
         pr(4, repo: "thehammer/nostromo", owner: alpha),
         pr(5, repo: "thehammer/nostromo", owner: .unknown),
         pr(6, repo: "solo/tool", owner: bravo)]
    }

    func testOrgKeyIsTheLowercasedOwnerPartAndNilWithoutOne() {
        XCTAssertEqual(F.orgKey(ofRepo: "Carefeed/portal"), "carefeed")
        XCTAssertEqual(F.orgKey(ofRepo: "carefeed/portal"), "carefeed")
        XCTAssertEqual(F.orgKey(ofRepo: "a/b/c"), "a", "only the part before the first slash")
        XCTAssertNil(F.orgKey(ofRepo: "noslash"))
        XCTAssertNil(F.orgKey(ofRepo: "/x"))
        XCTAssertNil(F.orgKey(ofRepo: " /x"))
        XCTAssertNil(F.orgKey(ofRepo: ""))
    }

    func testOrgEntriesAreAllThenEachOwnerMostPrsFirstThenAToZ() {
        let prs = orgFixture() + [pr(7, repo: "zeta/one"), pr(8, repo: "Alpha/two")]
        let entries = F.apply(prs, selection: .all).orgEntries
        XCTAssertEqual(entries.map(\.title), ["All", "Carefeed", "thehammer", "Alpha", "solo", "zeta"],
                       "3, 2, then the one-PR orgs A-Z ignoring case")
        XCTAssertEqual(entries.map(\.count), [8, 3, 2, 1, 1, 1])
        XCTAssertEqual(entries.map(\.menuTitle), ["All (8)", "Carefeed (3)", "thehammer (2)", "Alpha (1)", "solo (1)", "zeta (1)"])
        XCTAssertEqual(entries.first?.selection, .all)
        XCTAssertEqual(entries[1].selection, .org("carefeed"))
    }

    func testOrgCountsTiedAtTheTopStillSortAToZ() {
        let prs = [pr(1, repo: "zed/a"), pr(2, repo: "zed/b"), pr(3, repo: "Amy/a"), pr(4, repo: "amy/b"), pr(5, repo: "mid/a")]
        XCTAssertEqual(F.apply(prs, selection: .all).orgEntries.map(\.title), ["All", "Amy", "zed", "mid"])
    }

    func testOneOrgWhateverTheCaseShowsTheFirstSeenSpelling() {
        let result = F.apply(orgFixture(), selection: .all)
        let carefeed = result.orgEntries.filter { $0.selection == .org("carefeed") }
        XCTAssertEqual(carefeed.count, 1, "Carefeed, carefeed and CAREFEED are one org")
        XCTAssertEqual(carefeed.first?.title, "Carefeed", "the spelling of the first PR in the list")
        XCTAssertEqual(carefeed.first?.count, 3)

        let reversed = F.apply(Array(orgFixture().reversed()), selection: .all)
        XCTAssertEqual(reversed.orgEntries.first { $0.selection == .org("carefeed") }?.title, "CAREFEED", "first seen in this order")
        XCTAssertEqual(reversed.orgEntries.filter { $0.title.lowercased() == "carefeed" }.count, 1)

        let selected = F.apply(orgFixture(), selection: Selection(org: .org("carefeed")))
        XCTAssertEqual(numbers(selected), [1, 2, 3], "every spelling matches")
        XCTAssertEqual(selected.orgTitle, "Carefeed")
        XCTAssertEqual(F.apply(orgFixture(), selection: Selection(org: .org("thehammer"))).orgTitle, "thehammer")
        XCTAssertEqual(F.apply(orgFixture(), selection: .all).orgTitle, "All")
    }

    func testRowsWithNoOwnerPartHaveNoOrgButAreUnderAll() {
        let prs = [pr(1, repo: "noslash"), pr(2, repo: "/x"), pr(3, repo: " /x"), pr(4, repo: "a/b/c"), pr(5, repo: "Real/one")]
        let all = F.apply(prs, selection: .all)
        XCTAssertEqual(numbers(all), [1, 2, 3, 4, 5], "all of them show under All")
        XCTAssertEqual(all.orgEntries.map(\.title), ["All", "a", "Real"], "only a/b/c and Real/one name an org")
        XCTAssertEqual(all.orgEntries.first?.count, 5, "All counts every PR, owner part or not")
        XCTAssertEqual(all.orgEntries.map(\.count), [5, 1, 1])
        XCTAssertEqual(all.repoEntries.first?.count, 5)

        XCTAssertEqual(numbers(F.apply(prs, selection: Selection(org: .org("a")))), [4], "a/b/c belongs to a")
        XCTAssertEqual(numbers(F.apply(prs, selection: Selection(org: .org("real")))), [5])
        XCTAssertEqual(numbers(F.apply(prs, selection: Selection(org: .org("")))), [], "an empty org key matches nothing, not the owner-less rows")
    }

    func testAnOrgSelectionShowsOnlyThatOrgsPrsInTheirOrder() {
        let result = F.apply(orgFixture(), selection: Selection(org: .org("thehammer")))
        XCTAssertEqual(numbers(result), [4, 5])
        XCTAssertEqual(result.matched, 2)
        XCTAssertEqual(result.total, 6)
        XCTAssertTrue(result.selection.isActive, "an org alone is a filter")
        XCTAssertEqual(result.orgEntries.first?.count, 6, "All (N) in the Org pop-up stays the whole list")
    }

    func testOrgRepoAndSessionCombineWithAndNotOr() {
        // carefeed holds 1, 2, 3; Alpha owns 1, 3, 4; portal (as the daemon spells it) holds 1.
        XCTAssertEqual(numbers(F.apply(orgFixture(), selection: Selection(org: .org("carefeed"), session: .focus(tag: "alpha-tag")))), [1, 3],
                       "OR would add 4 (Alpha, other org) and 2")
        XCTAssertEqual(numbers(F.apply(orgFixture(), selection: Selection(org: .org("carefeed"), repo: .repo("Carefeed/portal")))), [1])
        XCTAssertEqual(numbers(F.apply(orgFixture(), selection: Selection(org: .org("thehammer"), session: .noSession))), [5],
                       "ownerless PRs of the selected org only")
        XCTAssertEqual(numbers(F.apply(orgFixture(), selection: Selection(org: .org("thehammer"), session: .focus(tag: "bravo-tag")))), [],
                       "bravo has PRs, thehammer has PRs, but not in common")
        XCTAssertEqual(numbers(F.apply(orgFixture(), selection: Selection(org: .org("carefeed"), repo: .repo("Carefeed/portal"),
                                                                           session: .focus(tag: "bravo-tag")))), [],
                       "all three together are an intersection")
        XCTAssertEqual(numbers(F.apply(orgFixture(), selection: Selection(org: .org("solo"), repo: .repo("thehammer/nostromo")))), [],
                       "a repo outside the selected org matches nothing")
    }

    // MARK: Repo and Session follow the Org

    func testRepoAndSessionEntriesNarrowToTheSelectedOrg() {
        let result = F.apply(orgFixture(), selection: Selection(org: .org("thehammer")))
        XCTAssertEqual(result.repoEntries.map(\.menuTitle), ["All (2)", "thehammer/nostromo (2)"], "only the org's repos, All counts the org's PRs")
        XCTAssertEqual(result.sessionEntries.map(\.menuTitle), ["All (2)", "Alpha (1)", "No session (1)"],
                       "bravo owns nothing in this org, so it is not offered")

        let carefeed = F.apply(orgFixture(), selection: Selection(org: .org("carefeed")))
        XCTAssertEqual(carefeed.repoEntries.map(\.menuTitle), ["All (3)", "carefeed/api (1)", "Carefeed/portal (1)", "CAREFEED/web (1)"])
        XCTAssertEqual(carefeed.sessionEntries.map(\.menuTitle), ["All (3)", "Alpha (2)", "bravo (1)"], "no No session entry: every PR here has an owner")

        let all = F.apply(orgFixture(), selection: .all)
        XCTAssertEqual(all.repoEntries.first?.count, 6, "no org: the whole list, as before")
        XCTAssertEqual(all.sessionEntries.first?.count, 6)
    }

    func testRepoAndSessionCountsFollowTheOrgButNotTheOtherPopUp() {
        let withRepo = F.apply(orgFixture(), selection: Selection(org: .org("carefeed"), repo: .repo("carefeed/api")))
        let orgOnly = F.apply(orgFixture(), selection: Selection(org: .org("carefeed")))
        XCTAssertEqual(withRepo.sessionEntries, orgOnly.sessionEntries, "Session counts are over the org, not the repo")
        let withSession = F.apply(orgFixture(), selection: Selection(org: .org("carefeed"), session: .focus(tag: "alpha-tag")))
        XCTAssertEqual(withSession.repoEntries, orgOnly.repoEntries, "Repo counts are over the org, not the session")
    }

    func testOrgCountsAreOverTheWholeListWhateverTheRepoAndSessionSelection() {
        let all = F.apply(orgFixture(), selection: .all).orgEntries
        let selections: [Selection] = [
            Selection(repo: .repo("solo/tool")),
            Selection(session: .focus(tag: "alpha-tag")),
            Selection(org: .org("thehammer"), repo: .repo("thehammer/nostromo"), session: .noSession),
            Selection(org: .org("carefeed"), session: .focus(tag: "bravo-tag")),
        ]
        for selection in selections {
            XCTAssertEqual(F.apply(orgFixture(), selection: selection).orgEntries, all, "\(selection)")
        }
    }

    func testASelectedRepoOutsideTheSelectedOrgStaysSelectedAndListedWithZero() {
        let result = F.apply(orgFixture(), selection: Selection(org: .org("carefeed"), repo: .repo("thehammer/nostromo")))
        XCTAssertEqual(result.selection.repo, .repo("thehammer/nostromo"), "not reset to All")
        XCTAssertEqual(result.matched, 0)
        XCTAssertEqual(result.repoEntries.first { $0.selection == .repo("thehammer/nostromo") }?.menuTitle, "thehammer/nostromo (0)")
        XCTAssertEqual(result.repoEntries.first?.count, 3, "All is the org's PRs")
        XCTAssertEqual(result.repoTitle, "thehammer/nostromo")
    }

    func testChangingTheOrgNeverResetsTheSelectedRepo() {
        let before = F.apply(orgFixture(), selection: Selection(repo: .repo("thehammer/nostromo")))
        XCTAssertEqual(numbers(before), [4, 5], "precondition")
        // What the strip does on an Org pick: only the org part of the selection changes.
        var selection = before.selection
        selection.org = .org("carefeed")
        let after = F.apply(orgFixture(), selection: selection)
        XCTAssertEqual(after.selection.repo, .repo("thehammer/nostromo"))
        XCTAssertEqual(after.emptyState, .noMatch(text: "No PRs in org Carefeed in thehammer/nostromo."))

        selection.org = .all
        XCTAssertEqual(numbers(F.apply(orgFixture(), selection: selection)), [4, 5], "and back: the repo was kept all along")
    }

    func testASelectedSessionOutsideTheSelectedOrgStaysSelectedAndListedWithZero() {
        // bravo owns 2 and 6, but nothing in thehammer.
        let result = F.apply(orgFixture(), selection: Selection(org: .org("thehammer"), session: .focus(tag: "bravo-tag")))
        XCTAssertEqual(result.selection.session, .focus(tag: "bravo-tag"))
        let entry = result.sessionEntries.first { $0.selection == .focus(tag: "bravo-tag") }
        XCTAssertEqual(entry?.count, 0, "still listed, with zero")
        XCTAssertTrue(entry?.menuTitle.hasSuffix(" (0)") ?? false, entry?.menuTitle ?? "not listed")
        XCTAssertFalse(entry?.title.isEmpty ?? true)
        XCTAssertEqual(result.matched, 0)
    }

    // MARK: Selected org that vanished

    func testASelectedOrgWithNoPrsStaysSelectedListedWithZeroAndNamedInTheEmptyMessage() {
        let result = F.apply(orgFixture(), selection: Selection(org: .org("gone")))
        XCTAssertEqual(result.selection.org, .org("gone"), "not reset to All")
        XCTAssertEqual(result.matched, 0)
        XCTAssertEqual(result.total, 6)
        let entry = result.orgEntries.first { $0.selection == .org("gone") }
        XCTAssertEqual(entry?.count, 0)
        XCTAssertEqual(entry?.menuTitle, "gone (0)")
        XCTAssertEqual(result.orgTitle, "gone")
        XCTAssertEqual(result.orgEntries.count, 5, "All, the three real orgs and the selected one")
        XCTAssertEqual(result.orgEntries.last?.selection, .org("gone"), "zero PRs sorts last")
        XCTAssertEqual(result.emptyState, .noMatch(text: "No PRs in org gone."))
        XCTAssertEqual(result.repoEntries.map(\.menuTitle), ["All (0)"])
    }

    func testEmptyStateNamesTheOrgAlongsideRepoAndSession() {
        let result = F.apply(orgFixture(), selection: Selection(org: .org("solo"), session: .focus(tag: "alpha-tag")))
        guard case .noMatch(let text) = result.emptyState else { return XCTFail("expected a no-match message") }
        XCTAssertTrue(text.hasPrefix("No PRs in org solo from "), text)
        XCTAssertEqual(F.apply(orgFixture(), selection: Selection(org: .org("solo"), session: .noSession)).emptyState,
                       .noMatch(text: "No PRs in org solo without a session."))
        guard case .noMatch(let text) = F.apply(orgFixture(), selection: Selection(org: .org("solo"), repo: .repo("a/b"), session: .noSession)).emptyState
        else { return XCTFail("expected a no-match message") }
        for part in ["org solo", "a/b", "without a session"] { XCTAssertTrue(text.contains(part), "'\(text)' names \(part)") }
    }

    // MARK: Untrusted org names

    func testAHostileOwnerNameIsSanitisedAndCappedInTheOrgMenuWithAnUncappedSanitisedTooltipName() {
        let hostile = "Ev\u{202E}il\u{0007}\u{2066}" + String(repeating: "o", count: 150)
        let repo = hostile + "/repo"
        let prs = [pr(1, repo: repo), pr(2, repo: "carefeed/portal")]
        let result = F.apply(prs, selection: .all)
        let key = F.orgKey(ofRepo: repo)
        let entry = result.orgEntries.first { $0.selection == .org(key ?? "") }
        XCTAssertNotNil(key)
        XCTAssertNotNil(entry, "the hostile org is listed")
        let title = entry?.title ?? ""
        XCTAssertFalse(hasBidiOrControl(title))
        XCTAssertFalse(hasBidiOrControl(entry?.menuTitle ?? ""))
        XCTAssertTrue(title.hasPrefix("Evil"), "what is printable is kept: \(title)")
        XCTAssertLessThanOrEqual(title.count, 60, "capped like a repo name")
        XCTAssertTrue(title.hasSuffix("…"))

        let full = entry?.fullTitle ?? ""
        XCTAssertFalse(hasBidiOrControl(full), "the tooltip name is sanitised too")
        XCTAssertTrue(full.hasPrefix("Evil"))
        XCTAssertGreaterThan(full.count, title.count, "longer than the menu title: \(full.count)")
        XCTAssertLessThanOrEqual(full.count, MotherOriginDisplay.tooltipCap, "but capped at the tooltip cap")
        XCTAssertTrue(full.hasSuffix("…"))

        // It still selects by what the daemon named it, and the empty message is clean.
        let selected = F.apply(prs, selection: Selection(org: .org(key ?? ""), session: .noSession))
        XCTAssertEqual(numbers(selected), [1])
        let none = F.apply(prs, selection: Selection(org: .org(key ?? ""), repo: .repo("carefeed/portal")))
        guard case .noMatch(let text) = none.emptyState else { return XCTFail("expected a no-match message") }
        XCTAssertFalse(hasBidiOrControl(text))
        XCTAssertFalse(hasBidiOrControl(none.orgTitle))
        XCTAssertLessThanOrEqual(none.orgTitle.count, 60)
    }

    func testRepoAndSessionTooltipsAreCappedToo() {
        let longRepo = "carefeed/" + String(repeating: "r", count: 200)
        let name = String(repeating: "s", count: 200)
        let prs = [pr(1, repo: longRepo, owner: owner(tag: "t", name: name))]
        let result = F.apply(prs, selection: .all)
        for full in [result.repoEntries[1].fullTitle, result.sessionEntries[1].fullTitle] {
            XCTAssertEqual(full.count, MotherOriginDisplay.tooltipCap)
            XCTAssertTrue(full.hasSuffix("…"))
        }
    }

    func testAnOwnerWithNothingPrintableIsCalledUnnamedAndAShortNameIsItsOwnTooltip() {
        let result = F.apply([pr(1, repo: "\u{202E}\u{0007}/x"), pr(2, repo: "short/x")], selection: .all)
        XCTAssertTrue(result.orgEntries.contains { $0.title == "unnamed org" })
        let short = result.orgEntries.first { $0.title == "short" }
        XCTAssertEqual(short?.fullTitle, "short", "a name that fits is its own tooltip")
    }

    func testAnOwnerNameOfExactlyTheCapIsNotTruncated() {
        let name = String(repeating: "q", count: 60)
        let entry = F.apply([pr(1, repo: name + "/x")], selection: .all).orgEntries[1]
        XCTAssertEqual(entry.title, name)
        XCTAssertEqual(entry.fullTitle, name)
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
