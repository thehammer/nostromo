import XCTest
import Combine

// Perri side pane, slice 2: the pane's state for one focus. What these pin, from outside:
//
//   * one tab per (PR, target); opening it again focuses it and navigates nothing
//   * tabs are in content order whatever order they were opened in
//   * at most eight tabs: the least recently focused, not active, not unsent tab goes first
//   * a PR change (the focus's pin) closes the other PRs' tabs, but never a tab with unsent text
//   * the model follows the pin only: the first pin (also after a restore) is not a change, clearing it
//     keeps every tab, and the same pin again does nothing
//   * each focus tag has its own pane
//
// No web view is involved: tabs only get one when a pane view shows them. `unsentCheck` is injected, and
// the cap and the PR change are awaited directly.

@MainActor
final class ReviewPaneModelTests: XCTestCase {

    private var unsent = Set<ReviewTab.ID>()
    private var unsentChecks = 0

    private let repo = "acme/web"
    private func pr(_ number: Int, _ repo: String = "acme/web") -> ReviewPR { ReviewPR(repo: repo, number: number) }

    private func makeModel(tag: String = "perri-test", store: ReviewPaneStore? = nil) -> ReviewPaneModel {
        let model = ReviewPaneModel(tag: tag, store: store)
        model.unsentCheck = { [unowned self] tab in
            self.unsentChecks += 1
            return self.unsent.contains(tab.id)
        }
        return model
    }

    private func makeStore() throws -> ReviewPaneStore {
        let suite = "ReviewPaneModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return ReviewPaneStore(defaults: defaults, jiraSite: { nil })
    }

    private func url(_ s: String) -> URL { URL(string: s)! }

    /// "repo#number conversation|diff|ticket KEY|page NAME" for each tab, in tab order.
    private func described(_ model: ReviewPaneModel) -> [String] {
        model.tabs.map { tab in
            let what: String
            switch tab.target {
            case .conversation: what = "conversation"
            case .diff: what = "diff"
            case .ticket(let key): what = "ticket \(key)"
            case .page: what = "page \(tab.startURL.lastPathComponent)"
            }
            return "\(tab.pr.repo)#\(tab.pr.number) \(what)"
        }
    }

    /// Opens `count` conversation tabs for acme/web #1...#count, oldest focus first (#1 least recently focused).
    @discardableResult
    private func openTabs(_ count: Int, in model: ReviewPaneModel) -> [ReviewTab] {
        var tabs: [ReviewTab] = []
        for number in 1...count {
            let tab = model.open(pr: pr(number), target: .conversation)
            tab.lastFocused = Date(timeIntervalSince1970: TimeInterval(number))
            tabs.append(tab)
        }
        return tabs
    }

    // MARK: Identity reuse

    func testOpeningTheSameTargetTwiceFocusesTheOneTabAndNavigatesNothing() {
        let model = makeModel()
        let conversation = model.open(pr: pr(7), target: .conversation)
        _ = model.open(pr: pr(7), target: .diff)
        XCTAssertEqual(model.tabs.count, 2)

        conversation.currentURL = url("https://github.com/acme/web/pull/7#issuecomment-1")   // the person scrolled and navigated
        let again = model.open(pr: pr(7), target: .conversation, url: url("https://github.com/elsewhere"))

        XCTAssertTrue(again === conversation, "the same tab, not a second one")
        XCTAssertEqual(model.tabs.count, 2)
        XCTAssertEqual(model.activeTab?.id, conversation.id, "and it is focused")
        XCTAssertEqual(again.startURL, pr(7).conversationURL, "the start URL is untouched")
        XCTAssertEqual(again.currentURL, url("https://github.com/acme/web/pull/7#issuecomment-1"), "so is where the tab is now")
    }

    func testTheSameTargetOfADifferentPRIsAnotherTab() {
        let model = makeModel()
        let a = model.open(pr: pr(7), target: .diff)
        let b = model.open(pr: pr(8), target: .diff)
        let c = model.open(pr: pr(7, "acme/api"), target: .diff)
        XCTAssertEqual(Set([a.id, b.id, c.id]).count, 3, "same number in another repo is another PR")
        XCTAssertEqual(model.tabs.count, 3)
    }

    func testOpeningAnExistingTabAsksForKeyboardFocusToo() {
        let model = makeModel()
        var requests = 0
        let cancellable = model.focusRequests.sink { requests += 1 }
        model.open(pr: pr(7), target: .conversation)
        let afterFirst = requests
        model.open(pr: pr(7), target: .conversation)
        XCTAssertGreaterThanOrEqual(afterFirst, 1)
        XCTAssertGreaterThan(requests, afterFirst, "re-opening is also a request for the tab")
        cancellable.cancel()
    }

    func testEveryLinkOrPopupPageIsANewTab() {
        let model = makeModel()
        let opener = model.open(pr: pr(7), target: .conversation)
        let one = model.openPage(from: opener, url: url("https://github.com/acme/web/issues/1"))
        let two = model.openPage(from: opener, url: url("https://github.com/acme/web/issues/1"))
        XCTAssertFalse(one === two)
        XCTAssertEqual(model.tabs.count, 3)
        XCTAssertEqual(one.pr, opener.pr, "a page belongs to the PR it was opened from")
    }

    // MARK: Content order

    /// Pinned PR 20 of acme/web; others: acme/api #5, acme/web #9 (conversation and diff) and #10.
    private func openContentFixture(in model: ReviewPaneModel, reversed: Bool) {
        var specs: [(ReviewPR, ReviewTarget, Int, String?)] = [
            (pr(20), .diff, 0, nil),
            (pr(20), .ticket("CORE-2"), 2, "https://carefeed.atlassian.net/browse/CORE-2"),
            (pr(20), .conversation, 0, nil),
            (pr(20), .ticket("CORE-1"), 1, "https://carefeed.atlassian.net/browse/CORE-1"),
            (pr(10), .conversation, 0, nil),
            (pr(9), .diff, 0, nil),
            (pr(5, "acme/api"), .conversation, 0, nil),
            (pr(9), .conversation, 0, nil),
        ]
        if reversed { specs.reverse() }
        for (pr, target, order, url) in specs {
            model.open(pr: pr, target: target, url: url.flatMap(URL.init(string:)), ticketOrder: order)
        }
    }

    private let expectedContentOrder = [
        "acme/web#20 conversation", "acme/web#20 diff", "acme/web#20 ticket CORE-1", "acme/web#20 ticket CORE-2",
        "acme/api#5 conversation", "acme/web#9 conversation", "acme/web#9 diff", "acme/web#10 conversation",
    ]

    func testTabsAreInContentOrderWhateverOrderTheyWereOpened() async {
        for reversed in [false, true] {
            let model = makeModel()
            await model.pinChanged(to: pr(20))
            openContentFixture(in: model, reversed: reversed)
            XCTAssertEqual(described(model), expectedContentOrder, "opened \(reversed ? "backwards" : "forwards")")
        }
    }

    func testThePinnedPRComesFirstAndThePinMovesItsTabsToTheFront() async {
        let model = makeModel()
        model.open(pr: pr(9), target: .conversation)
        model.open(pr: pr(10), target: .conversation)
        XCTAssertEqual(described(model), ["acme/web#9 conversation", "acme/web#10 conversation"], "no pin: repo then number")

        await model.pinChanged(to: pr(10))
        XCTAssertEqual(described(model), ["acme/web#10 conversation", "acme/web#9 conversation"])
    }

    func testPRsAreOrderedByNumberNotByTheDigitsOfTheNumber() {
        let model = makeModel()
        for n in [100, 9, 25, 3] { model.open(pr: pr(n), target: .conversation) }
        XCTAssertEqual(model.tabs.map(\.pr.number), [3, 9, 25, 100])
    }

    func testPagesAreInTheOrderTheyWereOpened() {
        for order in [["a", "b"], ["b", "a"]] {
            let model = makeModel()
            let opener = model.open(pr: pr(7), target: .conversation)
            model.open(pr: pr(7), target: .diff)
            for name in order { model.openPage(from: opener, url: url("https://github.com/acme/web/\(name)")) }
            XCTAssertEqual(described(model), ["acme/web#7 conversation", "acme/web#7 diff",
                                              "acme/web#7 page \(order[0])", "acme/web#7 page \(order[1])"])
        }
    }

    // MARK: Visibility and closing

    func testThePaneIsVisibleExactlyWhileThereAreTabs() {
        let model = makeModel()
        XCTAssertFalse(model.isVisible)
        XCTAssertNil(model.activeTab)
        let tab = model.open(pr: pr(7), target: .conversation)
        XCTAssertTrue(model.isVisible)
        model.close(tab)
        XCTAssertFalse(model.isVisible)
        XCTAssertNil(model.activeTab)
        XCTAssertNil(model.activeID)
    }

    private func threeTabs(_ model: ReviewPaneModel) -> (conversation: ReviewTab, diff: ReviewTab, ticket: ReviewTab) {
        let c = model.open(pr: pr(7), target: .conversation)
        let d = model.open(pr: pr(7), target: .diff)
        let t = model.open(pr: pr(7), target: .ticket("CORE-1"), url: url("https://carefeed.atlassian.net/browse/CORE-1"), ticketOrder: 1)
        XCTAssertEqual(model.tabs.map(\.id), [c.id, d.id, t.id], "precondition: conversation, diff, ticket")
        return (c, d, t)
    }

    func testClosingTheActiveTabActivatesItsNeighbour() {
        let model = makeModel()
        let (conversation, diff, ticket) = threeTabs(model)

        model.focus(diff)
        model.close(diff)
        XCTAssertEqual(model.activeID, ticket.id, "the tab that took its place")

        model.close(ticket)
        XCTAssertEqual(model.activeID, conversation.id, "the last tab closed: the one before it")

        model.close(conversation)
        XCTAssertNil(model.activeID)
    }

    func testClosingTheFirstActiveTabActivatesTheNewFirst() {
        let model = makeModel()
        let (conversation, diff, _) = threeTabs(model)
        model.focus(conversation)
        model.close(conversation)
        XCTAssertEqual(model.activeID, diff.id)
    }

    func testClosingAnotherTabKeepsTheActiveOne() {
        let model = makeModel()
        let (conversation, diff, ticket) = threeTabs(model)
        model.focus(diff)
        model.close(conversation)
        XCTAssertEqual(model.activeID, diff.id)
        model.close(ticket)
        XCTAssertEqual(model.activeID, diff.id)
        XCTAssertEqual(model.tabs.map(\.id), [diff.id])
    }

    func testCloseOthersKeepsOnlyThatTabAndFocusesIt() {
        let model = makeModel()
        let (_, diff, _) = threeTabs(model)
        model.closeOthers(than: diff)
        XCTAssertEqual(model.tabs.map(\.id), [diff.id])
        XCTAssertEqual(model.activeID, diff.id)
    }

    // MARK: Cap of eight

    func testAtEightTabsNothingIsEvicted() async {
        let model = makeModel()
        openTabs(8, in: model)
        await model.enforceCap()
        XCTAssertEqual(model.tabs.count, 8)
    }

    func testTheNinthTabEvictsTheLeastRecentlyFocused() async {
        let model = makeModel()
        openTabs(8, in: model)
        let ninth = model.open(pr: pr(9), target: .conversation)
        await model.enforceCap()

        XCTAssertEqual(model.tabs.count, 8)
        XCTAssertFalse(model.tabs.contains { $0.pr.number == 1 }, "#1 was focused longest ago")
        XCTAssertTrue(model.tabs.contains { $0.id == ninth.id })
        XCTAssertEqual(model.activeID, ninth.id)
    }

    func testRecencyIsOfFocusNotOfOpening() async {
        let model = makeModel()
        let tabs = openTabs(8, in: model)
        model.focus(tabs[0])      // #1 was opened first but is the most recently focused now
        model.open(pr: pr(9), target: .conversation)
        await model.enforceCap()

        XCTAssertTrue(model.tabs.contains { $0.pr.number == 1 }, "focused just now: stays")
        XCTAssertFalse(model.tabs.contains { $0.pr.number == 2 }, "the least recently focused now")
        XCTAssertEqual(model.tabs.count, 8)
    }

    func testTheActiveTabIsNeverEvicted() async {
        let model = makeModel()
        openTabs(8, in: model)
        let ninth = model.open(pr: pr(9), target: .conversation)
        ninth.lastFocused = Date(timeIntervalSince1970: 0)      // the oldest of all, yet it is the active one
        await model.enforceCap()

        XCTAssertTrue(model.tabs.contains { $0.id == ninth.id })
        XCTAssertFalse(model.tabs.contains { $0.pr.number == 1 }, "the next oldest goes instead")
        XCTAssertEqual(model.tabs.count, 8)
    }

    func testATabWithUnsentTextIsSkippedAndMarked() async {
        let model = makeModel()
        let tabs = openTabs(8, in: model)
        unsent = [tabs[0].id]
        model.open(pr: pr(9), target: .conversation)
        await model.enforceCap()

        XCTAssertTrue(model.tabs.contains { $0.id == tabs[0].id }, "unsent text is never evicted")
        XCTAssertTrue(tabs[0].unsent, "and it is marked")
        XCTAssertFalse(model.tabs.contains { $0.pr.number == 2 }, "the next least recently focused goes")
        XCTAssertEqual(model.tabs.count, 8)
    }

    func testWhenNoTabQualifiesTheNinthOpensAnyway() async {
        let model = makeModel()
        let tabs = openTabs(8, in: model)
        unsent = Set(tabs.map(\.id))
        let ninth = model.open(pr: pr(9), target: .conversation)
        await model.enforceCap()

        XCTAssertEqual(model.tabs.count, 9, "every other tab holds unsent text: nothing is lost")
        XCTAssertEqual(model.activeID, ninth.id)
        XCTAssertTrue(tabs.allSatisfy(\.unsent))

        unsent = []     // the text was sent: the next check can evict
        await model.enforceCap()
        XCTAssertEqual(model.tabs.count, 8)
        XCTAssertTrue(model.tabs.contains { $0.id == ninth.id })
    }

    func testOpeningAPageOverTheCapEvictsAsWell() async {
        let model = makeModel()
        let tabs = openTabs(8, in: model)
        model.openPage(from: tabs[7], url: url("https://github.com/acme/web/issues/1"))
        await model.enforceCap()
        XCTAssertEqual(model.tabs.count, 8)
        XCTAssertFalse(model.tabs.contains { $0.pr.number == 1 })
    }

    // MARK: PR change

    func testAPRChangeClosesTheOtherPRsTabs() async {
        let model = makeModel()
        await model.pinChanged(to: pr(1))
        model.open(pr: pr(1), target: .conversation)
        model.open(pr: pr(1), target: .diff)
        let other = model.open(pr: pr(2), target: .conversation)

        await model.pinChanged(to: pr(2))

        XCTAssertEqual(model.tabs.map(\.id), [other.id], "PR 1's tabs are gone, PR 2's stays")
        XCTAssertEqual(model.currentPin, pr(2))
    }

    func testAPRChangeKeepsATabWithUnsentTextAndMarksIt() async {
        let model = makeModel()
        await model.pinChanged(to: pr(1))
        let conversation = model.open(pr: pr(1), target: .conversation)
        let diff = model.open(pr: pr(1), target: .diff)
        let next = model.open(pr: pr(2), target: .conversation)
        unsent = [diff.id]

        await model.pinChanged(to: pr(2))

        XCTAssertEqual(described(model), ["acme/web#2 conversation", "acme/web#1 diff"], "the pinned PR first, the kept tab after it")
        XCTAssertTrue(diff.unsent, "marked so the person sees why it stayed")
        XCTAssertFalse(next.unsent)
        XCTAssertFalse(model.tabs.contains { $0.id == conversation.id })
    }

    func testTheFirstPinIsNotAChange() async {
        let model = makeModel()
        model.open(pr: pr(1), target: .conversation)
        model.open(pr: pr(3), target: .diff)
        await model.pinChanged(to: pr(2))
        XCTAssertEqual(model.tabs.count, 2, "there was no earlier PR to leave")
        XCTAssertEqual(unsentChecks, 0)
    }

    func testTheFirstPinAfterARestoreIsNotAChange() async throws {
        let store = try makeStore()
        let first = makeModel(tag: "perri-restore", store: store)
        first.open(pr: pr(1), target: .conversation)
        first.open(pr: pr(1), target: .diff)

        let restored = makeModel(tag: "perri-restore", store: store)
        XCTAssertEqual(restored.tabs.count, 2, "precondition: restored")
        await restored.pinChanged(to: pr(2))      // the daemon's first state after launch
        XCTAssertEqual(restored.tabs.count, 2, "the saved tabs survive the first pin")

        await restored.pinChanged(to: pr(3))      // now it really changed
        XCTAssertEqual(restored.tabs.count, 0)
    }

    func testClearingThePinKeepsEveryTab() async {
        let model = makeModel()
        await model.pinChanged(to: pr(1))
        model.open(pr: pr(1), target: .conversation)
        model.open(pr: pr(2), target: .conversation)

        await model.pinChanged(to: nil)

        XCTAssertEqual(model.tabs.count, 2)
        XCTAssertNil(model.currentPin)
        XCTAssertEqual(unsentChecks, 0)
    }

    func testTheSamePinAgainIsANoOp() async {
        let model = makeModel()
        await model.pinChanged(to: pr(1))
        model.open(pr: pr(1), target: .conversation)
        let elsewhere = model.open(pr: pr(2), target: .conversation)    // the person opened another PR's tab on purpose

        await model.pinChanged(to: pr(1))      // what a queue refresh amounts to: the pin did not move
        await model.pinChanged(to: pr(1))

        XCTAssertEqual(model.tabs.count, 2)
        XCTAssertTrue(model.tabs.contains { $0.id == elsewhere.id })
        XCTAssertEqual(unsentChecks, 0, "nothing was even looked at")
    }

    func testClearingAndThenReturningToTheSamePRChangesNothing() async {
        let model = makeModel()
        await model.pinChanged(to: pr(1))
        model.open(pr: pr(1), target: .conversation)
        await model.pinChanged(to: nil)
        model.open(pr: pr(2), target: .conversation)
        await model.pinChanged(to: pr(1))
        XCTAssertEqual(model.tabs.count, 2, "the PR did not change: no tab closes")

        await model.pinChanged(to: pr(3))
        XCTAssertEqual(model.tabs.count, 0, "a different PR closes both")
    }

    /// A -> B -> C while B's tabs are still being checked. B's pass must notice the pin moved on and leave
    /// everything to C's pass: it must not close tabs that belong to C (here: a C tab the person opened earlier).
    func testAPinThatMovesOnWhileTabsAreBeingCheckedLeavesTheNewPRsTabsAlone() async {
        let model = makeModel()
        model.unsentCheck = { _ in
            try? await Task.sleep(nanoseconds: 150_000_000)
            return false
        }
        await model.pinChanged(to: pr(1))                                   // A
        let a = model.open(pr: pr(1), target: .conversation)
        let b = model.open(pr: pr(2), target: .conversation)
        let c = model.open(pr: pr(3), target: .conversation)
        let c2 = model.open(pr: pr(3), target: .diff)

        let toB = Task { @MainActor in await model.pinChanged(to: self.pr(2)) }      // B's pass is mid-probe...
        try? await Task.sleep(nanoseconds: 30_000_000)
        let toC = Task { @MainActor in await model.pinChanged(to: self.pr(3)) }      // ...when the pin moves to C
        await toB.value
        await toC.value

        XCTAssertEqual(model.currentPin, pr(3))
        XCTAssertTrue(model.tabs.contains { $0.id == c.id }, "C's conversation tab survived B's pass")
        XCTAssertTrue(model.tabs.contains { $0.id == c2.id }, "C's diff tab survived B's pass")
        XCTAssertFalse(model.tabs.contains { $0.id == a.id }, "A's tab is closed")
        XCTAssertFalse(model.tabs.contains { $0.id == b.id }, "B's tab is closed")
        XCTAssertEqual(model.tabs.count, 2)
    }

    // MARK: One pane per focus

    func testEachFocusTagHasItsOwnIndependentPane() throws {
        let registry = ReviewPaneRegistry(store: try makeStore())
        let a = registry.model(for: "perri-aaaa")
        let b = registry.model(for: "perri-bbbb")

        XCTAssertTrue(a === registry.model(for: "perri-aaaa"), "one model per tag, shared by every window")
        XCTAssertFalse(a === b)

        let tab = a.open(pr: pr(1), target: .conversation)
        a.widthFraction = 0.3
        XCTAssertTrue(a.isVisible)
        XCTAssertFalse(b.isVisible, "the other focus is untouched")
        XCTAssertEqual(b.widthFraction, ReviewPaneModel.defaultWidthFraction)

        b.open(pr: pr(1), target: .conversation)
        a.close(tab)
        XCTAssertFalse(a.isVisible)
        XCTAssertTrue(b.isVisible, "closing in one focus does not close the other's tab")
    }

    func testEachFocusFollowsItsOwnPin() async throws {
        let registry = ReviewPaneRegistry(store: try makeStore())
        let a = registry.model(for: "perri-aaaa")
        let b = registry.model(for: "perri-bbbb")
        a.unsentCheck = { _ in false }
        b.unsentCheck = { _ in false }
        await a.pinChanged(to: pr(1))
        await b.pinChanged(to: pr(1))
        a.open(pr: pr(1), target: .conversation)
        b.open(pr: pr(1), target: .conversation)

        await a.pinChanged(to: pr(2))

        XCTAssertFalse(a.isVisible, "a moved on to another PR")
        XCTAssertTrue(b.isVisible, "b is still on the first")
    }

    func testRemovingAFocusTakesItsPaneAndSavedStateWithIt() throws {
        let registry = ReviewPaneRegistry(store: try makeStore())
        let model = registry.model(for: "perri-aaaa")
        model.open(pr: pr(1), target: .conversation)
        model.widthFraction = 0.33

        registry.remove(tag: "perri-aaaa")

        let fresh = registry.model(for: "perri-aaaa")
        XCTAssertFalse(fresh === model)
        XCTAssertFalse(fresh.isVisible, "no tabs come back")
        XCTAssertEqual(fresh.widthFraction, ReviewPaneModel.defaultWidthFraction, "nor the width")
    }

    // MARK: Two windows, one pane

    func testTheMostRecentWindowHoldsThePaneAndHandsItBackWhenItLeaves() {
        let model = makeModel()
        let first = NSObject(), second = NSObject()
        let firstID = ObjectIdentifier(first), secondID = ObjectIdentifier(second)
        XCTAssertNil(model.presenterID)

        model.claimPresenter(firstID)
        XCTAssertEqual(model.presenterID, firstID)
        model.claimPresenter(secondID)
        XCTAssertEqual(model.presenterID, secondID, "the most recently shown window takes the pane")

        model.releasePresenter(secondID)
        XCTAssertEqual(model.presenterID, firstID, "the earlier window takes it back")

        model.releasePresenter(secondID)
        XCTAssertEqual(model.presenterID, firstID, "releasing a window that no longer holds it changes nothing")

        model.releasePresenter(firstID)
        XCTAssertNil(model.presenterID, "no window shows the pane")
    }

    func testAWindowThatLeavesWithoutHoldingThePaneIsForgotten() {
        let model = makeModel()
        let first = NSObject(), second = NSObject()
        let firstID = ObjectIdentifier(first), secondID = ObjectIdentifier(second)
        model.claimPresenter(firstID)
        model.claimPresenter(secondID)

        model.releasePresenter(firstID)          // the older window goes away while the newer holds the pane
        XCTAssertEqual(model.presenterID, secondID)

        model.releasePresenter(secondID)
        XCTAssertNil(model.presenterID, "the gone window is not handed the pane")
    }

    func testReclaimingMovesAWindowToTheFront() {
        let model = makeModel()
        let first = NSObject(), second = NSObject()
        let firstID = ObjectIdentifier(first), secondID = ObjectIdentifier(second)
        model.claimPresenter(firstID)
        model.claimPresenter(secondID)
        model.claimPresenter(firstID)          // the first window was shown again
        XCTAssertEqual(model.presenterID, firstID)

        model.releasePresenter(firstID)
        XCTAssertEqual(model.presenterID, secondID)
    }

    // MARK: A PR whose repo is not owner/name

    func testAMalformedRepoHasNoPullRequestPageURLs() {
        for repo in ["bad repo/../x", "", "owner", "a/b/c", "a b/c", "a/b?x=y", "a/b#frag", "owner/", "/name", "a/b c",
                     "a/b%2Fc", "a\\b/c", "ow@ner/name", "ow:ner/name", "https://evil.example/x"] {
            let bad = ReviewPR(repo: repo, number: 1)
            XCTAssertNil(bad.conversationURL, "conversation: \(repo.debugDescription)")
            XCTAssertNil(bad.diffURL, "diff: \(repo.debugDescription)")
        }
    }

    func testAWellFormedRepoHasItsPullRequestPageURLs() {
        let good = ReviewPR(repo: "acme/web", number: 7)
        XCTAssertEqual(good.conversationURL, url("https://github.com/acme/web/pull/7"))
        XCTAssertEqual(good.diffURL, url("https://github.com/acme/web/pull/7/files"))
        let dotted = ReviewPR(repo: "Acme-Inc/web_app.v2", number: 12)
        XCTAssertEqual(dotted.conversationURL, url("https://github.com/Acme-Inc/web_app.v2/pull/12"))
    }

    func testAMalformedRepoDefaultsToABlankPageWithoutCrashing() {
        let bad = ReviewPR(repo: "bad repo/../x", number: 1)
        for target: ReviewTarget in [.conversation, .diff, .ticket("CORE-1"), .page(1)] {
            XCTAssertEqual(ReviewPaneModel.defaultURL(pr: bad, target: target), url("about:blank"), "\(target)")
        }
        XCTAssertEqual(ReviewPaneModel.defaultURL(pr: pr(7), target: .diff), url("https://github.com/acme/web/pull/7/files"))

        let model = makeModel()
        let tab = model.open(pr: bad, target: .conversation)
        XCTAssertEqual(tab.startURL, url("about:blank"), "opening it anyway does not crash and loads nothing")
    }

    /// `$` in an ICU pattern also matches before a trailing line break.
    func testARepoWithALineBreakInItHasNoPullRequestPageURLs() {
        for repo in ["acme/web\n", "acme/web\r\n", "acme\n/web", "\nacme/web"] {
            let bad = ReviewPR(repo: repo, number: 1)
            XCTAssertNil(bad.conversationURL, "conversation: \(repo.debugDescription)")
            XCTAssertNil(bad.diffURL, "diff: \(repo.debugDescription)")
        }
    }
}
