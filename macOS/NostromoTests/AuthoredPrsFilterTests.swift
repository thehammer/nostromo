import XCTest
import AppKit
import NostromoKit

// The My open PRs Overview's Repo / Session filter bar, from the outside: what the strip offers, what picking
// something does to the groups, the header and the group counts, what an empty result says, that the choice is
// remembered (and a stale one is not believed), and that the filter never reaches the pinned Overview row's
// pill, the sidebar waiting pills or anything else computed from the whole snapshot. The pure rules (which PR
// matches, ordering, wording, encoding) are in NostromoKitTests/AuthoredPrsFilterTests.
//
// Every test uses a throwaway UserDefaults suite (removed in teardown); `UserDefaults.standard` is never
// written. No daemon: `AppStore.shared` is driven through its test seams and left as found.
//
// Mutations (to be run by hand), and the test that fails for each:
//   (a) the filter is applied to the count the pinned Overview row / sidebar pills are computed from
//        -> testAFilterThatHidesEverythingNeverChangesThePinnedRowsCountOrTheSidebarPills
//   (b) AND turned into OR when both pop-ups are set
//        -> testRepoAndSessionPickedTogetherShowOnlyThePrsInBoth
//   (c) an owner's name shown as it arrived (bidi override, control characters, no cap)
//        -> testAHostileOwnerNameReachesThePopUpCleanedAndCapped
//   (d) a selection whose PRs are gone (in a new snapshot, or from the stored value) is silently reset to All
//        -> testASelectionWhosePrsVanishStaysAndOffersShowAll, testAStoredSelectionThatMatchesNothingIsKeptNotQuietlyDropped
//   (e) a group's pill shows the total (or only the matching number) instead of "n of m"
//        -> testPickingARepoShowsItsPrsWithNOfMCountsInTheHeaderAndEveryGroup
//   (f) a stale stored value (a number, an empty string, an unknown prefix, an overlong one) is believed
//        -> testStaleOrMalformedStoredValuesStartAsAll
//   (g) the choice is not saved, is saved under the wrong key, or Clear leaves it behind
//        -> testTheChoiceIsRememberedInTheInjectedDefaultsAndClearForgetsIt
//   (h) Clear shown with nothing selected (or hidden with something selected)
//        -> testClearAppearsOnlyWhileSomethingIsSelectedAndPutsEverythingBack
//   (i) an empty result shows the list (or the generic empty text) with no `Show all`, or Show all does nothing
//        -> testAFilterThatMatchesNothingSaysSoAndShowAllBringsEverythingBack
//   (j) the pop-ups lose their VoiceOver label or value, refuse the keyboard, or their items take key equivalents
//        -> testBothPopUpsAreNamedSpokenWithTheirSelectionAndTakeNoKeys
//   (k) a filter change leaves the list scrolled where it was
//        -> testChangingTheFilterScrollsTheListBackToTheTop
//   (l) the strip's pop-ups lose their truncation or tooltip, or the strip overflows a narrow pane
//        -> testTheStripFitsANarrowPaneWithVeryLongNamesAndTruncatesWithTooltips
final class AuthoredPrsFilterBarTests: XCTestCase {

    private var windows: [NSWindow] = []
    private let clock = APT.FakeClock()
    private var suite: UserDefaults!
    private var suiteName = ""
    private var savedDefaults: UserDefaults!
    private var standardBefore: (repo: Any?, session: Any?) = (nil, nil)

    private static let portal = "carefeed/portal"
    private static let nostromo = "thehammer/nostromo"

    private let alpha = AuthoredPrOwner(kind: .motherJob, tag: "alpha-tag", name: "Alpha", jobId: "j1")
    private let bravo = AuthoredPrOwner(kind: .linked, tag: "bravo-tag", name: "bravo")

    /// needs you: 1 (portal, Alpha), 3 (nostromo, Alpha); ready: 2 (portal, bravo);
    /// waiting: 4 (nostromo, no owner), 5 (portal, no owner).
    private func fixture() -> [AuthoredPr] {
        [APT.pr(1, repo: Self.portal, group: .needsYou, owner: alpha),
         APT.pr(2, repo: Self.portal, group: .ready, owner: bravo),
         APT.pr(3, repo: Self.nostromo, group: .needsYou, owner: alpha),
         APT.pr(4, repo: Self.nostromo, group: .waiting),
         APT.pr(5, repo: Self.portal, group: .waiting)]
    }

    override func setUp() {
        super.setUp()
        MotherView.requestedJobId = nil
        AppStore.shared.resetAuthoredPrsForTesting()
        AppStore.shared.applyBrokerEventForTesting(.snapshot([]))
        suiteName = "AuthoredPrsFilterBarTests.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)!
        savedDefaults = AuthoredPrsFilterStore.defaults
        standardBefore = (UserDefaults.standard.object(forKey: AuthoredPrsFilterStore.repoKey),
                          UserDefaults.standard.object(forKey: AuthoredPrsFilterStore.sessionKey))
    }

    override func tearDown() {
        for window in windows { window.contentView = nil; window.close() }
        windows = []
        AuthoredPrsFilterStore.defaults = savedDefaults
        suite.removePersistentDomain(forName: suiteName)
        AppStore.shared.resetAuthoredPrsForTesting()
        AppStore.shared.applyBrokerEventForTesting(.snapshot([]))
        MotherView.requestedJobId = nil
        super.tearDown()
    }

    // MARK: - Rigs

    /// A stand-alone Overview (no store), reading and writing the throwaway suite.
    private func makeOverview(_ prs: [AuthoredPr]? = nil, defaults: UserDefaults? = nil,
                              size: NSSize = NSSize(width: 700, height: 500)) -> AuthoredPrsOverviewView {
        let window = APT.window(size: size)
        let overview = AuthoredPrsOverviewView(clock: clock.read, timeZone: APT.utc, store: nil, filterDefaults: defaults ?? suite)
        window.contentView = overview
        windows.append(window)
        overview.layoutSubtreeIfNeeded()
        overview.apply(snapshot: prs.map { APT.snapshot($0) } ?? APT.snapshot(fixture()), connection: .connected)
        overview.layoutSubtreeIfNeeded()
        return overview
    }

    private func titles(_ popUp: NSPopUpButton) -> [String] { popUp.itemTitles }

    /// What a reader does: open the pop-up and pick the entry whose title starts with `prefix`.
    private func choose(_ popUp: NSPopUpButton, _ prefix: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let index = popUp.itemTitles.firstIndex(where: { $0.hasPrefix(prefix) }) else {
            return XCTFail("no entry starting '\(prefix)' in \(popUp.itemTitles)", file: file, line: line)
        }
        popUp.selectItem(at: index)
        popUp.sendAction(popUp.action, to: popUp.target)
    }

    private func showAllButton(in overview: AuthoredPrsOverviewView) -> NSButton? {
        APT.descendants(of: overview).compactMap { $0 as? NSButton }.first { $0.title == "Show all" }
    }

    private func groupPillText(_ overview: AuthoredPrsOverviewView, _ group: AuthoredPrGroup) -> String? {
        overview.groupHeaderView(for: group)?.countPill.text
    }

    // MARK: - The strip

    func testTheStripOffersAllThenEachRepoAndEachSessionWithCounts() {
        let overview = makeOverview()
        let strip = overview.filterStrip
        XCTAssertFalse(strip.isHidden)
        XCTAssertEqual(titles(strip.repoPopUp), ["All (5)", "carefeed/portal (3)", "thehammer/nostromo (2)"])
        XCTAssertEqual(titles(strip.sessionPopUp), ["All (5)", "Alpha (2)", "bravo (1)", "No session (2)"])
        XCTAssertEqual(strip.repoPopUp.titleOfSelectedItem, "All (5)")
        XCTAssertEqual(strip.sessionPopUp.titleOfSelectedItem, "All (5)")
    }

    func testClearAppearsOnlyWhileSomethingIsSelectedAndPutsEverythingBack() {
        let overview = makeOverview()
        XCTAssertTrue(overview.filterStrip.clearButton.isHidden, "nothing selected: no Clear")

        choose(overview.filterStrip.sessionPopUp, "No session")
        XCTAssertFalse(overview.filterStrip.clearButton.isHidden, "something selected: Clear")
        XCTAssertEqual(Set(overview.displayedRowIds), [APT.pr(4, repo: Self.nostromo).id, APT.pr(5).id])

        overview.filterStrip.clearButton.performClick(nil)
        XCTAssertEqual(overview.filter, .all)
        XCTAssertTrue(overview.filterStrip.clearButton.isHidden)
        XCTAssertEqual(overview.displayedRowIds.count, 5)
        XCTAssertEqual(overview.filterStrip.repoPopUp.titleOfSelectedItem, "All (5)")
        XCTAssertEqual(overview.filterStrip.sessionPopUp.titleOfSelectedItem, "All (5)")
    }

    // MARK: - What a pick does

    func testPickingARepoShowsItsPrsWithNOfMCountsInTheHeaderAndEveryGroup() {
        let overview = makeOverview()
        XCTAssertEqual(overview.header.titleLabel.stringValue, "My open PRs · 5", "precondition: no 'of' without a filter")
        XCTAssertEqual(groupPillText(overview, .needsYou), "2", "precondition")

        choose(overview.filterStrip.repoPopUp, Self.nostromo)

        XCTAssertEqual(overview.filter, AuthoredPrsFilterSelection(repo: .repo(Self.nostromo)))
        XCTAssertEqual(overview.displayedRowIds, [APT.pr(3, repo: Self.nostromo).id, APT.pr(4, repo: Self.nostromo).id])
        XCTAssertEqual(overview.groupTitles, ["NEEDS YOU", "WAITING ON OTHERS"], "the group with nothing matching is hidden")
        XCTAssertEqual(overview.header.titleLabel.stringValue, "My open PRs · 2 of 5")
        XCTAssertEqual(groupPillText(overview, .needsYou), "1 of 2")
        XCTAssertEqual(groupPillText(overview, .waiting), "1 of 2")
        XCTAssertEqual(overview.groupHeaderView(for: .needsYou)?.accessibilityLabel(), "Needs you, 1 of 2")
        XCTAssertEqual(overview.filterStrip.repoPopUp.titleOfSelectedItem, "thehammer/nostromo (2)")
    }

    func testRepoAndSessionPickedTogetherShowOnlyThePrsInBoth() {
        let overview = makeOverview()
        choose(overview.filterStrip.repoPopUp, Self.portal)
        choose(overview.filterStrip.sessionPopUp, "Alpha")
        // Alpha owns 1 and 3, portal holds 1, 2 and 5. OR would show 1, 2, 3 and 5.
        XCTAssertEqual(overview.displayedRowIds, [APT.pr(1).id])
        XCTAssertEqual(overview.header.titleLabel.stringValue, "My open PRs · 1 of 5")
        XCTAssertEqual(overview.filter, AuthoredPrsFilterSelection(repo: .repo(Self.portal), session: .focus(tag: "alpha-tag")))
    }

    func testAHostileOwnerNameReachesThePopUpCleanedAndCapped() {
        // Built directly, so the wire's own cleaning never ran.
        let hostile = AuthoredPrOwner(kind: .motherJob, tag: "evil-tag", name: "Co\u{202E}dy\u{0007}" + String(repeating: "n", count: 100), jobId: "j")
        let overview = makeOverview([APT.pr(1, owner: hostile)])
        let entry = overview.filterStrip.sessionPopUp.itemTitles[1]
        let bad = entry.unicodeScalars.filter { $0.value < 0x20 || (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) }
        XCTAssertTrue(bad.isEmpty, "no bidi or control character in the menu: \(entry.debugDescription)")
        XCTAssertTrue(entry.hasPrefix("Cody"), entry)
        XCTAssertLessThanOrEqual(entry.count, 40 + " (1)".count, "capped like the job list's From: names")
    }

    // MARK: - A snapshot while a menu is open

    /// `NSPopUpButton.removeAllItems` closes an open menu, and a snapshot lands every few seconds. A count that
    /// moves must leave the very same menu and items in place (the open menu keeps showing, now with the new
    /// number); only a change in WHICH entries exist rebuilds them.
    func testASnapshotThatMovesACountKeepsTheMenuAndItsItemsInPlace() {
        let overview = makeOverview()
        let strip = overview.filterStrip
        let menuBefore = strip.repoPopUp.menu
        let itemsBefore = strip.repoPopUp.itemArray.map(ObjectIdentifier.init)
        let sessionItemsBefore = strip.sessionPopUp.itemArray.map(ObjectIdentifier.init)
        XCTAssertEqual(titles(strip.repoPopUp), ["All (5)", "carefeed/portal (3)", "thehammer/nostromo (2)"])

        overview.apply(snapshot: APT.snapshot(fixture() + [APT.pr(6, repo: Self.portal, group: .waiting)]), connection: .connected)

        XCTAssertEqual(titles(strip.repoPopUp), ["All (6)", "carefeed/portal (4)", "thehammer/nostromo (2)"], "the new count shows")
        XCTAssertTrue(strip.repoPopUp.menu === menuBefore, "the repo menu is the same menu")
        XCTAssertEqual(strip.repoPopUp.itemArray.map(ObjectIdentifier.init), itemsBefore, "the repo items are the same items: nothing was rebuilt")
        XCTAssertEqual(strip.sessionPopUp.itemArray.map(ObjectIdentifier.init), sessionItemsBefore, "the session items are untouched")
    }

    func testASnapshotThatChangesWhichEntriesExistRebuildsTheMenu() {
        let overview = makeOverview()
        let strip = overview.filterStrip
        let itemsBefore = strip.repoPopUp.itemArray.map(ObjectIdentifier.init)

        overview.apply(snapshot: APT.snapshot(fixture() + [APT.pr(6, repo: "carefeed/new-repo", group: .waiting)]), connection: .connected)

        XCTAssertEqual(titles(strip.repoPopUp), ["All (6)", "carefeed/new-repo (1)", "carefeed/portal (3)", "thehammer/nostromo (2)"])
        XCTAssertEqual(strip.repoPopUp.itemArray.count, 4)
        XCTAssertNotEqual(Array(strip.repoPopUp.itemArray.map(ObjectIdentifier.init).prefix(itemsBefore.count)), itemsBefore)
    }

    // MARK: - Nothing matches

    func testAFilterThatMatchesNothingSaysSoAndShowAllBringsEverythingBack() throws {
        let overview = makeOverview()
        XCTAssertTrue(try XCTUnwrap(showAllButton(in: overview), "the button exists").isHidden, "but is not offered while the list shows")

        // bravo owns only a portal PR: nostromo and bravo cannot meet.
        choose(overview.filterStrip.repoPopUp, Self.nostromo)
        choose(overview.filterStrip.sessionPopUp, "bravo")

        XCTAssertEqual(overview.shownMessage?.title, "No PRs in thehammer/nostromo from bravo.")
        XCTAssertFalse(overview.isShowingList)
        let button = try XCTUnwrap(showAllButton(in: overview))
        XCTAssertFalse(button.isHidden, "Show all is offered")
        XCTAssertFalse(overview.filterStrip.isHidden, "the strip stays so the reader can change the filter")
        XCTAssertEqual(overview.header.titleLabel.stringValue, "My open PRs · 0 of 5")

        button.performClick(nil)

        XCTAssertEqual(overview.filter, .all)
        XCTAssertNil(overview.shownMessage)
        XCTAssertTrue(overview.isShowingList)
        XCTAssertEqual(overview.displayedRowIds.count, 5)
        XCTAssertTrue(overview.filterStrip.clearButton.isHidden)
    }

    func testAnEmptyListWithNoFilterHasItsOwnMessageAndNoShowAll() throws {
        let overview = makeOverview([])
        XCTAssertEqual(overview.shownMessage?.title, AuthoredPrsPresentation.emptyText)
        XCTAssertTrue(try XCTUnwrap(showAllButton(in: overview)).isHidden)
        XCTAssertTrue(overview.filterStrip.isHidden, "nothing to filter")
    }

    func testASelectionWhosePrsVanishStaysAndOffersShowAll() throws {
        let overview = makeOverview()
        choose(overview.filterStrip.repoPopUp, Self.nostromo)
        XCTAssertEqual(overview.displayedRowIds.count, 2, "precondition")

        // The next snapshot has no PR in that repo any more.
        overview.apply(snapshot: APT.snapshot([APT.pr(1, repo: Self.portal, group: .needsYou), APT.pr(2, repo: Self.portal, group: .ready),
                                               APT.pr(5, repo: Self.portal, group: .waiting)]), connection: .connected)
        overview.layoutSubtreeIfNeeded()

        XCTAssertEqual(overview.filter.repo, .repo(Self.nostromo), "not silently reset to All")
        XCTAssertEqual(overview.filterStrip.repoPopUp.titleOfSelectedItem, "thehammer/nostromo (0)", "still listed, with zero")
        XCTAssertEqual(overview.shownMessage?.title, "No PRs in thehammer/nostromo.")
        XCTAssertFalse(try XCTUnwrap(showAllButton(in: overview)).isHidden)
        XCTAssertEqual(overview.header.titleLabel.stringValue, "My open PRs · 0 of 3")
        XCTAssertEqual(suite.string(forKey: AuthoredPrsFilterStore.repoKey), Self.nostromo, "and still remembered")
    }

    // MARK: - Remembering

    func testTheChoiceIsRememberedInTheInjectedDefaultsAndClearForgetsIt() {
        let first = makeOverview()
        choose(first.filterStrip.repoPopUp, Self.portal)
        choose(first.filterStrip.sessionPopUp, "No session")
        XCTAssertEqual(suite.string(forKey: "nostromo.authoredPrs.filter.repo"), Self.portal)
        XCTAssertEqual(suite.string(forKey: "nostromo.authoredPrs.filter.session"), "none")

        let second = makeOverview()
        XCTAssertEqual(second.filter, AuthoredPrsFilterSelection(repo: .repo(Self.portal), session: .noSession), "a new Overview starts where the last left off")
        XCTAssertEqual(second.displayedRowIds, [APT.pr(5).id])
        XCTAssertEqual(second.filterStrip.repoPopUp.titleOfSelectedItem, "carefeed/portal (3)")

        second.filterStrip.clearButton.performClick(nil)
        XCTAssertNil(suite.object(forKey: "nostromo.authoredPrs.filter.repo"))
        XCTAssertNil(suite.object(forKey: "nostromo.authoredPrs.filter.session"))
        XCTAssertEqual(makeOverview().filter, .all)

        XCTAssertEqual(String(describing: UserDefaults.standard.object(forKey: AuthoredPrsFilterStore.repoKey)),
                       String(describing: standardBefore.repo), "the real preferences were never written")
        XCTAssertEqual(String(describing: UserDefaults.standard.object(forKey: AuthoredPrsFilterStore.sessionKey)),
                       String(describing: standardBefore.session))
    }

    func testStaleOrMalformedStoredValuesStartAsAll() {
        let long = String(repeating: "x", count: 500)
        let cases: [(repo: Any?, session: Any?)] = [
            (42, 42), ("", ""), (nil, "bogus:thing"), (nil, "focus:"), (long, "focus:" + long), (nil, ["a"]),
        ]
        for (repo, session) in cases {
            let name = "AuthoredPrsFilterBarTests.stale.\(UUID().uuidString)"
            let stale = UserDefaults(suiteName: name)!
            addTeardownBlock { stale.removePersistentDomain(forName: name) }
            if let repo { stale.set(repo, forKey: AuthoredPrsFilterStore.repoKey) }
            if let session { stale.set(session, forKey: AuthoredPrsFilterStore.sessionKey) }
            let overview = makeOverview(defaults: stale)
            XCTAssertEqual(overview.filter, .all, "repo \(String(describing: repo)), session \(String(describing: session))")
            XCTAssertEqual(overview.displayedRowIds.count, 5, "the whole list shows")
        }
    }

    func testAStoredSelectionThatMatchesNothingIsKeptNotQuietlyDropped() throws {
        suite.set("gone/repo", forKey: AuthoredPrsFilterStore.repoKey)
        let overview = makeOverview()
        XCTAssertEqual(overview.filter.repo, .repo("gone/repo"))
        XCTAssertEqual(overview.shownMessage?.title, "No PRs in gone/repo.")
        XCTAssertFalse(try XCTUnwrap(showAllButton(in: overview)).isHidden)
        XCTAssertEqual(overview.filterStrip.repoPopUp.titleOfSelectedItem, "gone/repo (0)")
    }

    // MARK: - Accessibility and keyboard

    func testBothPopUpsAreNamedSpokenWithTheirSelectionAndTakeNoKeys() throws {
        let overview = makeOverview()
        let strip = overview.filterStrip
        XCTAssertEqual(strip.repoPopUp.accessibilityLabel(), "Filter by repository")
        XCTAssertEqual(strip.sessionPopUp.accessibilityLabel(), "Filter by session")
        XCTAssertEqual(strip.clearButton.accessibilityLabel(), "Clear filters")

        choose(strip.repoPopUp, Self.portal)
        choose(strip.sessionPopUp, "Alpha")
        XCTAssertEqual(strip.repoPopUp.accessibilityValue() as? String, "carefeed/portal (3)", "the selection is what VoiceOver says")
        XCTAssertEqual(strip.sessionPopUp.accessibilityValue() as? String, "Alpha (2)")
        XCTAssertEqual(strip.repoPopUp.accessibilityValue() as? String, strip.repoPopUp.titleOfSelectedItem)

        for popUp in [strip.repoPopUp, strip.sessionPopUp] {
            XCTAssertTrue(popUp.acceptsFirstResponder, "reachable by keyboard")
            XCTAssertTrue(popUp.keyEquivalent.isEmpty)
            XCTAssertFalse(popUp.itemArray.isEmpty)
            for item in popUp.itemArray {
                XCTAssertTrue(item.keyEquivalent.isEmpty, "'\(item.title)' takes no key: the job list's From: and the main menu own them")
            }
        }
        let window = try XCTUnwrap(overview.window)
        XCTAssertTrue(window.makeFirstResponder(strip.repoPopUp))
        XCTAssertTrue(window.firstResponder === strip.repoPopUp)
        XCTAssertTrue(window.makeFirstResponder(strip.sessionPopUp))
    }

    func testCommandOAndCommandRAreNotTheListsWhileAPopUpHasTheKeyboard() throws {
        let overview = makeOverview()
        let window = try XCTUnwrap(overview.window)
        XCTAssertTrue(window.makeFirstResponder(overview.filterStrip.repoPopUp), "precondition")
        XCTAssertFalse(overview.outline.performKeyEquivalent(with: APT.command("o", window: window)))
        XCTAssertFalse(overview.outline.performKeyEquivalent(with: APT.command("r", window: window)))
    }

    // MARK: - Scrolling

    func testChangingTheFilterScrollsTheListBackToTheTop() throws {
        // 69 PRs in one repo (about 25 rows in each of three groups, which is what the daemon's groups cap at) and a few elsewhere.
        var prs: [AuthoredPr] = []
        let groups: [AuthoredPrGroup] = [.needsYou, .ready, .waiting]
        for i in 1...69 { prs.append(APT.pr(i, repo: Self.portal, group: groups[i % 3])) }
        for i in 100...102 { prs.append(APT.pr(i, repo: Self.nostromo, group: .needsYou)) }
        let overview = makeOverview(prs)
        let scroll = try XCTUnwrap(overview.outline.enclosingScrollView)

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 400))
        scroll.reflectScrolledClipView(scroll.contentView)
        let scrolled = scroll.contentView.bounds.origin.y
        XCTAssertGreaterThan(scrolled, 100, "precondition: the list is scrolled down")

        choose(overview.filterStrip.repoPopUp, Self.portal)   // most rows stay, so nothing forces the scroll back
        overview.layoutSubtreeIfNeeded()

        XCTAssertLessThanOrEqual(scroll.contentView.bounds.origin.y, 0.5, "back at the top")
    }

    // MARK: - Pinned row, sidebar pills and notifications are not the filter's

    private func connectedMotherView(prs: [AuthoredPr]) -> MotherView {
        AuthoredPrsFilterStore.defaults = suite
        let window = APT.window(size: NSSize(width: 900, height: 600))
        let view = MotherView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        window.contentView = view
        windows.append(window)
        view.layoutSubtreeIfNeeded()
        AppStore.shared.daemonConnectedForTesting(authoredPrs: true, notify: true)
        AppStore.shared.applyAuthoredPrsForTesting(APT.snapshot(prs))
        APT.flushMain()
        return view
    }

    /// The count pills drawn outside the Overview itself: the pinned row's.
    func testAFilterThatHidesEverythingNeverChangesThePinnedRowsCountOrTheSidebarPills() {
        let tagA = "pill-a-\(UUID().uuidString)", tagB = "pill-b-\(UUID().uuidString)"
        func owner(_ tag: String) -> AuthoredPrOwner { AuthoredPrOwner(kind: .motherJob, tag: tag, name: "Cody \(tag.prefix(6))", jobId: "j") }
        let prs = [HF.pr(1, repo: Self.portal, owner: owner(tagA), pill: true),
                   HF.pr(2, repo: Self.portal, owner: owner(tagA), pill: true),
                   HF.pr(3, repo: Self.nostromo, owner: owner(tagB), pill: true),
                   HF.pr(4, repo: Self.nostromo, group: .ready, lifecycle: .merged, owner: owner(tagB))]
        let view = connectedMotherView(prs: prs)

        func waiting(_ tag: String) -> Int { SidebarBadgeModel.needsYouCounts(from: AppStore.shared.needsYou).waiting[tag] ?? 0 }
        XCTAssertTrue(view.hasPinnedOverviewRow, "precondition")
        XCTAssertFalse(view.overviewView.displayed.isEmpty, "precondition: the Overview has the snapshot")
        XCTAssertEqual(view.pinnedOverviewCount, 3, "precondition: the pinned row says 3 open PRs")
        XCTAssertEqual(waiting(tagA), 2, "precondition")
        XCTAssertEqual(waiting(tagB), 1, "precondition")

        // A filter that hides every row.
        view.overviewView.setFilter(AuthoredPrsFilterSelection(repo: .repo("nobody/nothing")))
        APT.flushMain()
        XCTAssertEqual(view.overviewView.shownMessage?.title, "No PRs in nobody/nothing.", "precondition: the filter is in force")
        XCTAssertEqual(view.overviewView.header.titleLabel.stringValue, "My open PRs · 0 of 3")

        // ... and a fresh snapshot arriving under it, which is what recomputes the pills. (It must differ from the
        // last one: the store ignores a snapshot equal to the one it holds.)
        AppStore.shared.applyAuthoredPrsForTesting(APT.snapshot(prs, poll: AuthoredPrsPoll(state: .ok, checkedAt: APT.t0.addingTimeInterval(-5))))
        APT.flushMain()

        XCTAssertTrue(view.hasPinnedOverviewRow)
        XCTAssertEqual(view.pinnedOverviewCount, 3, "the pinned row still says 3: the filter's match count never reaches it")
        XCTAssertEqual(waiting(tagA), 2, "the sidebar waiting pills still come from the whole snapshot")
        XCTAssertEqual(waiting(tagB), 1)
    }

    // MARK: - Narrow pane

    func testTheStripFitsANarrowPaneWithVeryLongNamesAndTruncatesWithTooltips() throws {
        let longRepo = "carefeed/" + String(repeating: "very-long-repository-name-", count: 2) + "end"
        let longOwner = AuthoredPrOwner(kind: .motherJob, tag: "long-tag", name: String(repeating: "A session with a long name ", count: 4), jobId: "j")
        let prs = [APT.pr(1, repo: longRepo, group: .needsYou, owner: longOwner), APT.pr(2, repo: Self.portal, group: .waiting)]

        for width in [CGFloat(320), 360] {
            let context = "\(Int(width)) pt"
            let (host, window) = APT.inkHost(size: NSSize(width: width, height: 400), appearance: .darkAqua)
            windows.append(window)
            let overview = AuthoredPrsOverviewView(clock: clock.read, timeZone: APT.utc, store: nil, filterDefaults: suite)
            overview.frame = host.bounds
            host.addSubview(overview)
            overview.apply(snapshot: APT.snapshot(prs), connection: .connected)
            choose(overview.filterStrip.repoPopUp, "carefeed/very")
            choose(overview.filterStrip.sessionPopUp, "A session")
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(APT.render(host), context)

            let strip = overview.filterStrip
            XCTAssertFalse(strip.isHidden, context)
            XCTAssertEqual(strip.bounds.width, width, accuracy: 0.5, context)
            let parts: [(String, NSView)] = [("Repo pop-up", strip.repoPopUp), ("Session pop-up", strip.sessionPopUp), ("Clear", strip.clearButton)]
                + APT.descendants(of: strip).compactMap { ($0 as? NSTextField).map { ("caption '\($0.stringValue)'", $0) } }
            for (name, view) in parts {
                let frame = APT.rect(of: view, in: strip)
                XCTAssertGreaterThanOrEqual(frame.minX, -0.5, "\(context): \(name) starts inside the strip")
                XCTAssertLessThanOrEqual(frame.maxX, width + 0.5, "\(context): \(name) ends inside the strip (\(frame.maxX))")
                XCTAssertGreaterThan(frame.width, 0, "\(context): \(name) has a width")
            }
            XCTAssertFalse(strip.clearButton.isHidden, "\(context): Clear is visible with something selected")
            XCTAssertNotNil(bitmap.ink(in: APT.rect(of: strip.clearButton, in: host), threshold: 0.1), "\(context): Clear is drawn")

            for popUp in [strip.repoPopUp, strip.sessionPopUp] {
                let full = try XCTUnwrap(popUp.titleOfSelectedItem)
                let natural = (full as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width
                XCTAssertLessThan(popUp.frame.width, natural, "\(context): '\(full)' is truncated, not allowed to push the strip wider")
                // The tooltip is the whole sanitised name: not the capped menu title, and not its "(n)" count.
                let expectedFull = popUp === strip.repoPopUp ? longRepo : (longOwner.name ?? "").trimmingCharacters(in: .whitespaces)
                XCTAssertEqual(popUp.toolTip, expectedFull, "\(context): the tooltip carries the full name")
                XCTAssertNotEqual(popUp.toolTip, full, "\(context): and is not the capped menu title with its count")
                XCTAssertTrue(popUp.itemArray.allSatisfy { item in
                    item.toolTip.map { !$0.isEmpty && item.title.hasPrefix(String($0.prefix(8))) } ?? false
                }, "\(context): every entry has its name as a tooltip")
            }
        }
    }
}
