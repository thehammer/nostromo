import XCTest
import AppKit
import NostromoKit

// The Mother pane's "My open PRs" Overview, from the outside: when it is there, what it says in every state,
// and what its keys, clicks and menus do. No daemon: `AppStore.shared` is driven through its test seams and
// left as found. Nothing here touches the real UserDefaults or the general pasteboard.
//
// Mutations (derived by reading the source, to be run by hand), and the test that fails for each:
//   M1 pinned row shown for a daemon that does not advertise the feature
//        -> testAnOldDaemonKeepsSelectAJobAndHasNoPinnedRow
//   M2 `showOverview()` leaves `selectedJobId` set
//        -> testSelectingTheOverviewClearsTheJobSelectionAndShowsIt
//   M3 `openOnGitHub` opens `URL(string: model.url)` without `AuthoredPrsLinks` validation
//        -> testOnlyAnExactGitHubPullUrlIsEverOpened
//   M4 `refresh()` ignores `refreshBlocked`
//        -> testRefreshDoesNothingWhileTheDaemonSaysItIsBlocked
//   M5 `requestShowOverview` does not record the request
//        -> testCommandZeroSwitchesAnExistingMotherViewToTheOverview, testCommandZeroRequestedBeforeAMotherViewExistsIsFoundByTheViewCreatedAfterwards
//   M6 the usage report carries a PR's title, repo or login
//        -> testCopyGitHubUsagePutsCountsOnTheClipboardAndNothingElse
//   M7 a disconnect clears the snapshot instead of marking it reconnecting
//        -> testADaemonDisconnectKeepsTheLastSnapshotAndMarksItReconnecting
//   M8 a title is parsed as Markdown or attributed text (a link attribute appears)
//        -> testATitleWithMarkdownLinkSyntaxIsShownAsThePlainString
//   M9 the skeleton never gives way to a message
//        -> testTheSkeletonShowsForFiveSecondsThenAMessage
//   M10 ⌘0 moved to another key, or the Debug item given a key equivalent
//        -> testTheViewMenuOffersShowMyPrsOnCommandZero
//   M11 the Overview's availability is read from the property before it has changed (the @Published trap)
//        -> testTheOverviewAppearsAsSoonAsTheDaemonConnectsEvenBeforeTheFirstSnapshot,
//           testReconnectingToAnOldDaemonPutsSelectAJobBack
final class AuthoredPrsOverviewTests: XCTestCase {

    private var windows: [NSWindow] = []
    private let clock = APT.FakeClock()
    private var savedCoalescing: TimeInterval = 0

    override func setUp() {
        super.setUp()
        savedCoalescing = MotherView.selectionCoalescing
        MotherView.selectionCoalescing = 0
        MotherView.requestedJobId = nil
        AppStore.shared.resetAuthoredPrsForTesting()
        AppStore.shared.applyBrokerEventForTesting(.snapshot([]))
        let name = "AuthoredPrsOverviewTests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        let previous = MotherView.widthDefaults
        MotherView.widthDefaults = suite
        addTeardownBlock {
            MotherView.widthDefaults = previous
            suite.removePersistentDomain(forName: name)
        }
    }

    override func tearDown() {
        MotherView.selectionCoalescing = savedCoalescing
        MotherView.requestedJobId = nil
        for window in windows { window.contentView = nil; window.close() }
        windows = []
        AppStore.shared.resetAuthoredPrsForTesting()
        AppStore.shared.applyBrokerEventForTesting(.snapshot([]))
        super.tearDown()
    }

    // MARK: - Rigs

    private func makeMotherView() -> (window: NSWindow, view: MotherView) {
        let window = APT.window(size: NSSize(width: 900, height: 600))
        let view = MotherView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        windows.append(window)
        return (window, view)
    }

    /// A stand-alone Overview (no store) with an injected clock and time zone, in a window.
    private func makeOverview(_ snapshot: AuthoredPrsSnapshot? = nil,
                              connection: AuthoredPrsConnection = .connected) -> AuthoredPrsOverviewView {
        let window = APT.window(size: NSSize(width: 700, height: 500))
        let overview = AuthoredPrsOverviewView(clock: clock.read, timeZone: APT.utc, store: nil)
        window.contentView = overview
        windows.append(window)
        overview.layoutSubtreeIfNeeded()
        overview.apply(snapshot: snapshot, connection: connection)
        overview.layoutSubtreeIfNeeded()
        return overview
    }

    /// The daemon says it publishes the list, and the first snapshot arrives.
    private func connect(prs: [AuthoredPr] = [APT.pr(1, group: .needsYou)]) {
        AppStore.shared.daemonConnectedForTesting(authoredPrs: true)
        AppStore.shared.applyAuthoredPrsForTesting(APT.snapshot(prs))
    }

    private func job(_ id: String) -> MotherJob {
        MotherJob(id: id, state: "running", repo: "nostromo", isolation: "none", title: "Job \(id)",
                  createdAt: Date(), startedAt: Date(), finishedAt: nil, planPath: nil,
                  question: nil, pausedReason: nil, adherenceStatus: nil, currentTier: nil)
    }

    private func publish(_ jobs: [MotherJob]) {
        AppStore.shared.applyBrokerEventForTesting(.snapshot(jobs))
        let deadline = Date().addingTimeInterval(3)
        while AppStore.shared.motherJobs.map(\.id) != jobs.map(\.id), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private func assertHeaderVisible(_ overview: AuthoredPrsOverviewView, _ context: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        overview.layoutSubtreeIfNeeded()
        XCTAssertFalse(overview.header.isHidden, "\(context): the header is shown", file: file, line: line)
        XCTAssertTrue(overview.header.titleLabel.stringValue.hasPrefix("My open PRs"), "\(context): the header says what this is", file: file, line: line)
        XCTAssertGreaterThanOrEqual(overview.header.frame.height, AuthoredPrsHeaderView.barHeight, "\(context): the header has its height", file: file, line: line)
    }

    // MARK: - The pinned row and the right-hand side

    func testThePinnedOverviewRowExistsOnlyWhenTheDaemonPublishesTheList() {
        let (_, view) = makeMotherView()
        XCTAssertFalse(view.hasPinnedOverviewRow, "no daemon yet: no row")
        AppStore.shared.daemonConnectedForTesting(authoredPrs: true)
        XCTAssertTrue(view.hasPinnedOverviewRow)
        AppStore.shared.daemonConnectedForTesting(authoredPrs: false)
        XCTAssertFalse(view.hasPinnedOverviewRow, "a reconnect to a daemon without the feature takes the row away")
    }

    func testSelectingTheOverviewClearsTheJobSelectionAndShowsIt() {
        let (_, view) = makeMotherView()
        connect()
        view.listDidSelect(job("a"))
        XCTAssertEqual(view.selectedJobId, "a", "precondition")
        XCTAssertFalse(view.isShowingOverview)
        XCTAssertTrue(view.overviewView.isHidden, "a job's detail replaces the Overview")

        view.showOverview()

        XCTAssertNil(view.selectedJobId)
        XCTAssertNil(view.shownDetail, "the job's detail is gone from the right-hand side")
        XCTAssertTrue(view.isShowingOverview)
        XCTAssertFalse(view.overviewView.isHidden)
        XCTAssertEqual(view.detailContainer.accessibilityLabel(), MotherView.overviewAccessibilityLabel)
    }

    func testWithNoSelectionTheRightSideShowsTheOverviewNotSelectAJob() {
        let (_, view) = makeMotherView()
        connect()
        XCTAssertNil(view.selectedJobId)
        XCTAssertTrue(view.isShowingOverview)
        XCTAssertFalse(view.overviewView.isHidden)
        XCTAssertEqual(view.detailContainer.accessibilityLabel(), MotherView.overviewAccessibilityLabel)
    }

    func testTheOverviewAppearsAsSoonAsTheDaemonConnectsEvenBeforeTheFirstSnapshot() {
        let (_, view) = makeMotherView()
        AppStore.shared.daemonConnectedForTesting(authoredPrs: true)   // no snapshot frame yet
        XCTAssertTrue(view.hasPinnedOverviewRow)
        XCTAssertFalse(view.overviewView.isHidden, "the Overview is on screen (its skeleton) as soon as the feature is known")
        XCTAssertEqual(view.detailContainer.accessibilityLabel(), MotherView.overviewAccessibilityLabel)
    }

    func testAnOldDaemonKeepsSelectAJobAndHasNoPinnedRow() {
        let (_, view) = makeMotherView()
        AppStore.shared.daemonConnectedForTesting(authoredPrs: false)
        XCTAssertFalse(view.hasPinnedOverviewRow)
        XCTAssertFalse(view.isShowingOverview)
        XCTAssertTrue(view.overviewView.isHidden)
        XCTAssertEqual(view.detailContainer.accessibilityLabel(), MotherView.emptyAccessibilityLabel)

        // Even a stray frame cannot conjure the Overview for a daemon that never offered it.
        AppStore.shared.applyAuthoredPrsForTesting(APT.snapshot([APT.pr(1)]))
        XCTAssertFalse(view.hasPinnedOverviewRow)
        XCTAssertTrue(view.overviewView.isHidden)
        XCTAssertEqual(view.detailContainer.accessibilityLabel(), MotherView.emptyAccessibilityLabel)

        view.showOverview()
        XCTAssertFalse(view.isShowingOverview, "asking for the Overview does nothing without the feature")
        XCTAssertTrue(view.overviewView.isHidden)
    }

    func testReconnectingToAnOldDaemonPutsSelectAJobBack() {
        let (_, view) = makeMotherView()
        connect()
        XCTAssertFalse(view.overviewView.isHidden, "precondition: the Overview was showing")
        AppStore.shared.daemonConnectedForTesting(authoredPrs: false)
        XCTAssertFalse(view.hasPinnedOverviewRow)
        XCTAssertTrue(view.overviewView.isHidden)
        XCTAssertEqual(view.detailContainer.accessibilityLabel(), MotherView.emptyAccessibilityLabel)
    }

    // MARK: - The Mother-job link

    func testTheMotherJobLinkSelectsThatJob() {
        let (_, view) = makeMotherView()
        connect()
        publish([job("job-16"), job("job-17")])
        view.showOverview()
        XCTAssertNil(view.selectedJobId, "precondition")

        view.overviewView.onOpenJob("job-17")

        XCTAssertEqual(view.selectedJobId, "job-17")
        XCTAssertFalse(view.isShowingOverview)
        XCTAssertEqual(view.shownDetail?.currentJobId, "job-17")
    }

    func testPressingTheJobIdInARowAsksToOpenThatJob() throws {
        let pr = APT.pr(5, group: .needsYou, owner: APT.motherOwner(job: "job-17"))
        let overview = makeOverview(APT.snapshot([pr]))
        var opened: [String] = []
        overview.onOpenJob = { opened.append($0) }
        let row = try XCTUnwrap(overview.rowView(forRowId: pr.id))
        XCTAssertFalse(row.jobButton.isHidden)

        row.jobButton.performClick(nil)

        XCTAssertEqual(opened, ["job-17"])
    }

    func testTheContextMenuOffersTheMotherJobOnlyForARowThatHasOne() throws {
        let owned = APT.pr(5, group: .needsYou, owner: APT.motherOwner(job: "job-17"))
        let plain = APT.pr(6, group: .needsYou)
        let overview = makeOverview(APT.snapshot([owned, plain]))
        var opened: [String] = []
        overview.onOpenJob = { opened.append($0) }

        let ownedMenu = try XCTUnwrap(overview.contextMenu(forRowId: owned.id))
        let plainMenu = try XCTUnwrap(overview.contextMenu(forRowId: plain.id))
        XCTAssertEqual(plainMenu.items.map(\.title), ["Open on GitHub"])
        let item = try XCTUnwrap(ownedMenu.items.first { $0.title == "Show Mother Job job-17" })
        _ = NSApplication.shared.sendAction(try XCTUnwrap(item.action), to: item.target, from: item)

        XCTAssertEqual(opened, ["job-17"])
    }

    // MARK: - Command-0

    func testCommandZeroSwitchesAnExistingMotherViewToTheOverview() {
        let (_, view) = makeMotherView()
        connect()
        view.listDidSelect(job("a"))
        XCTAssertEqual(view.selectedJobId, "a", "precondition")

        var switched = false
        MotherView.requestShowOverview { switched = true }
        XCTAssertTrue(switched, "the caller's switch to the Mother focus ran")
        view.applyRequestedOverview(isKeyWindow: true)

        XCTAssertNil(view.selectedJobId)
        XCTAssertTrue(view.isShowingOverview)
        XCTAssertFalse(view.overviewView.isHidden)
    }

    func testCommandZeroRequestedBeforeAMotherViewExistsIsFoundByTheViewCreatedAfterwards() {
        connect()
        var switched = false
        MotherView.requestShowOverview { switched = true }
        XCTAssertTrue(switched)

        let (window, view) = makeMotherView()   // what the focus switch creates
        view.applyRequestedOverview(isKeyWindow: true)
        APT.flushMain()

        XCTAssertTrue(view.isShowingOverview)
        XCTAssertTrue(window.firstResponder === view.overviewView.outline, "the request reached the view that did not exist when it was made")
    }

    func testCommandZeroAppliesOnlyInTheKeyWindow() {
        let (_, view) = makeMotherView()
        connect()
        view.listDidSelect(job("a"))
        MotherView.requestShowOverview { }

        view.applyRequestedOverview(isKeyWindow: false)
        XCTAssertEqual(view.selectedJobId, "a", "a window that is not key keeps what it shows")

        view.applyRequestedOverview(isKeyWindow: true)
        XCTAssertNil(view.selectedJobId, "the key window takes the pending request")
    }

    func testCommandZeroRequestedBeforeAMotherViewJoinsAKeyWindowIsAppliedOnJoining() throws {
        connect()
        let window = APT.window(size: NSSize(width: 900, height: 600))
        windows.append(window)
        window.makeKeyAndOrderFront(nil)
        try XCTSkipUnless(window.isKeyWindow, "this test process cannot make a key window")
        MotherView.requestShowOverview { }

        let view = MotherView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        window.contentView = view
        APT.flushMain()

        XCTAssertTrue(window.firstResponder === view.overviewView.outline, "joining the key window applied the pending request")
    }

    func testTheViewMenuOffersShowMyPrsOnCommandZero() throws {
        let menu = MainMenu.make(target: nil)
        let view = try XCTUnwrap(menu.items.compactMap(\.submenu).first { $0.title == "View" })
        let item = try XCTUnwrap(view.items.first { $0.title == "Show My PRs" })
        XCTAssertEqual(item.keyEquivalent, "0")
        XCTAssertEqual(item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask), [.command])
        XCTAssertEqual(item.action, #selector(MainMenuActions.showMyPrs(_:)))

        let debug = try XCTUnwrap(menu.items.compactMap(\.submenu).first { $0.title == "Debug" })
        let usage = try XCTUnwrap(debug.items.first { $0.title == "Copy GitHub usage" })
        XCTAssertEqual(usage.keyEquivalent, "", "counts only, and no shortcut")
        XCTAssertEqual(usage.action, #selector(MainMenuActions.copyGitHubUsage))
    }

    // MARK: - Opening on GitHub

    private let validURL = "https://github.com/carefeed/portal/pull/458"

    private func overviewForOpening(_ prs: [AuthoredPr]) -> (AuthoredPrsOverviewView, () -> [URL]) {
        let overview = makeOverview(APT.snapshot(prs))
        var opened: [URL] = []
        overview.opener = { opened.append($0) }
        return (overview, { opened })
    }

    func testCommandOOpensTheSelectedPrOnGitHub() {
        let pr = APT.pr(458, url: validURL, group: .needsYou)
        let (overview, opened) = overviewForOpening([pr, APT.pr(459)])
        overview.selectRow(id: pr.id)

        overview.outline.onOpenOnGitHub?()

        XCTAssertEqual(opened(), [URL(string: validURL)!])
    }

    func testCommandOWithNothingSelectedOpensNothing() {
        let (overview, opened) = overviewForOpening([APT.pr(458, url: validURL, group: .needsYou)])
        overview.clearSelection()
        overview.outline.onOpenOnGitHub?()
        XCTAssertTrue(opened().isEmpty)
    }

    func testCommandClickOpensThatRowsPrOnGitHub() throws {
        let pr = APT.pr(458, url: validURL, group: .needsYou)
        let (overview, opened) = overviewForOpening([pr])
        let row = try XCTUnwrap(overview.outlineRow(forRowId: pr.id))

        overview.outline.onCommandClick?(row)

        XCTAssertEqual(opened(), [URL(string: validURL)!])
    }

    func testTheContextMenuOpensThePrOnGitHub() throws {
        let pr = APT.pr(458, url: validURL, group: .needsYou)
        let (overview, opened) = overviewForOpening([pr])
        let menu = try XCTUnwrap(overview.contextMenu(forRowId: pr.id))
        let item = try XCTUnwrap(menu.items.first { $0.title == "Open on GitHub" })

        _ = NSApplication.shared.sendAction(try XCTUnwrap(item.action), to: item.target, from: item)

        XCTAssertEqual(opened(), [URL(string: validURL)!])
    }

    func testOnlyAnExactGitHubPullUrlIsEverOpened() throws {
        let bad = [
            "http://github.com/carefeed/portal/pull/1",
            "https://github.com/carefeed/portal/pull/1?x=1",
            "https://github.com/carefeed/portal/pull/1#files",
            "https://github.com/carefeed/portal/pull/1/files",
            "https://github.com/carefeed/portal/pull/abc",
            "https://github.com/carefeed/portal/issues/1",
            "https://evil.example/carefeed/portal/pull/1",
            "https://github.com.evil.example/carefeed/portal/pull/1",
            " https://github.com/carefeed/portal/pull/1",
            "https://github.com/carefeed/portal/pull/1\n",
            "javascript:alert(1)",
            "file:///etc/passwd",
            "",
        ]
        let control = APT.pr(1, url: validURL, group: .needsYou)
        let hostile = bad.enumerated().map { APT.pr(100 + $0.offset, url: $0.element, group: .waiting) }
        let (overview, opened) = overviewForOpening([control] + hostile)

        // Control: the harness does open a good URL, so "nothing opened" below means something.
        overview.selectRow(id: control.id)
        overview.outline.onOpenOnGitHub?()
        XCTAssertEqual(opened(), [URL(string: validURL)!], "precondition: a valid URL opens")

        for pr in hostile {
            overview.selectRow(id: pr.id)
            overview.outline.onOpenOnGitHub?()
            if let row = overview.outlineRow(forRowId: pr.id) { overview.outline.onCommandClick?(row) }
            if let menu = overview.contextMenu(forRowId: pr.id), let item = menu.items.first(where: { $0.title == "Open on GitHub" }),
               let action = item.action {
                _ = NSApplication.shared.sendAction(action, to: item.target, from: item)
            }
        }
        XCTAssertEqual(opened().count, 1, "no URL but the control's was opened; opened: \(opened())")
    }

    // MARK: - Refresh

    func testCommandRAndTheHeaderButtonRefreshOnce() {
        let overview = makeOverview(APT.snapshot([APT.pr(1, group: .needsYou)]))
        var refreshes = 0
        overview.refreshAction = { refreshes += 1 }

        overview.outline.onRefresh?()
        XCTAssertEqual(refreshes, 1, "⌘R asks once")
        overview.refresh()
        XCTAssertEqual(refreshes, 2)
        XCTAssertTrue(overview.header.refreshButton.isEnabled)
        overview.header.refreshButton.performClick(nil)
        XCTAssertEqual(refreshes, 3, "⟳ asks once")
    }

    func testRefreshGoesToTheStoresSenderByDefault() {
        let overview = makeOverview(APT.snapshot([APT.pr(1)]))
        var sent = 0
        AppStore.shared.authoredPrsRefreshSender = { sent += 1 }
        overview.refresh()
        XCTAssertEqual(sent, 1)
    }

    func testRefreshDoesNothingWhileTheDaemonSaysItIsBlocked() {
        for blocked in [AuthoredPrsRefreshBlocked.running, .rateLimited, .unknown] {
            let snapshot = APT.snapshot([APT.pr(1)], refreshBlocked: blocked)
            let overview = makeOverview(snapshot)
            var refreshes = 0
            overview.refreshAction = { refreshes += 1 }

            overview.outline.onRefresh?()
            overview.refresh()
            overview.header.refreshButton.performClick(nil)

            XCTAssertEqual(refreshes, 0, "\(blocked): nothing is asked")
            XCTAssertFalse(overview.header.refreshButton.isEnabled, "\(blocked): ⟳ is disabled")
            let reason = AuthoredPrsPresentation.header(snapshot, now: clock.now, timeZone: APT.utc).refreshDisabledReason
            XCTAssertNotNil(reason, "\(blocked): the daemon's block has a stated reason")
            XCTAssertEqual(overview.header.refreshButton.toolTip, reason, "\(blocked): the tooltip is the reason")
        }
    }

    func testRefreshDoesNothingBeforeTheFirstSnapshot() {
        let overview = makeOverview(nil)
        var refreshes = 0
        overview.refreshAction = { refreshes += 1 }
        overview.refresh()
        XCTAssertEqual(refreshes, 0)
        XCTAssertFalse(overview.header.refreshButton.isEnabled)
        XCTAssertEqual(overview.header.refreshButton.toolTip, "Waiting for the first update")
    }

    // MARK: - States

    func testAnEmptyListSaysSoWithTheHeaderStillShown() {
        let overview = makeOverview(APT.snapshot([]))
        XCTAssertEqual(overview.shownMessage?.title, AuthoredPrsPresentation.emptyText)
        XCTAssertFalse(overview.isShowingList)
        XCTAssertFalse(overview.isShowingSkeleton)
        XCTAssertFalse(overview.isDimmed)
        assertHeaderVisible(overview, "empty")
        XCTAssertEqual(overview.header.titleLabel.stringValue, "My open PRs · 0")
    }

    func testGitHubNotConnectedSaysHowToConnectWithTheHeaderStillShown() {
        for token in [AuthoredPrsTokenState.missing, .rejected] {
            // Even rows left over from before the token went away are not shown as if they were current.
            let overview = makeOverview(APT.snapshot([APT.pr(1)], token: token))
            XCTAssertEqual(overview.shownMessage?.title, AuthoredPrsPresentation.notConnectedTitle, "\(token)")
            XCTAssertEqual(overview.shownMessage?.detail, AuthoredPrsPresentation.notConnectedDetail, "\(token)")
            XCTAssertFalse(overview.isShowingList, "\(token)")
            assertHeaderVisible(overview, "\(token)")
        }
    }

    func testHiddenOrgsAreNamedInANoteAboveTheListWhichStaysShown() {
        let overview = makeOverview(APT.snapshot([APT.pr(1, group: .needsYou)], hiddenOrgs: ["acme", "initech"]))
        XCTAssertTrue(overview.isShowingList)
        XCTAssertEqual(overview.displayedRowIds.count, 1)
        assertHeaderVisible(overview, "hidden orgs")
        let note = "Some repos hidden: GitHub denied access to org acme, initech."
        XCTAssertTrue(APT.texts(in: overview.header).contains(note), "the header carries the note: \(APT.texts(in: overview.header))")
    }

    func testReconnectingKeepsTheRowsDimmedWithANote() {
        let overview = makeOverview(APT.snapshot([APT.pr(1, group: .needsYou), APT.pr(2)]), connection: .reconnecting)
        XCTAssertTrue(overview.isShowingList)
        XCTAssertEqual(overview.displayedRowIds.count, 2, "the last list stays")
        XCTAssertTrue(overview.isDimmed)
        assertHeaderVisible(overview, "reconnecting")
        XCTAssertTrue(APT.texts(in: overview.header).contains(AuthoredPrsPresentation.reconnectingText))

        overview.apply(snapshot: APT.snapshot([APT.pr(1, group: .needsYou), APT.pr(2)]), connection: .connected)
        XCTAssertFalse(overview.isDimmed, "back to normal once the link is up")
        XCTAssertFalse(APT.texts(in: overview.header).contains(AuthoredPrsPresentation.reconnectingText))
    }

    func testRateLimitedShowsWhenItResumesAsOfWhenAndDimsTheRows() {
        let checked = clock.now.addingTimeInterval(-120)
        let resumes = clock.now.addingTimeInterval(600)
        let poll = AuthoredPrsPoll(state: .rateLimited, checkedAt: checked, intervalSecs: 300, resumesAt: resumes)
        let overview = makeOverview(APT.snapshot([APT.pr(1, group: .needsYou)], poll: poll, refreshBlocked: .rateLimited))

        XCTAssertTrue(overview.isShowingList)
        XCTAssertTrue(overview.isDimmed, "the rows are older than they look")
        assertHeaderVisible(overview, "rate limited")
        let resumesAt = AuthoredPrsPresentation.clock(resumes, timeZone: APT.utc)
        XCTAssertTrue(overview.header.freshnessLabel.stringValue.contains("paused: GitHub rate limit low, resumes \(resumesAt)"),
                      overview.header.freshnessLabel.stringValue)
        XCTAssertTrue(APT.texts(in: overview.header).contains("as of \(AuthoredPrsPresentation.clock(checked, timeZone: APT.utc))"))
        XCTAssertFalse(overview.header.refreshButton.isEnabled)
        XCTAssertEqual(overview.header.refreshButton.toolTip, "Paused: GitHub rate limit low")
    }

    func testAnOfflineRelayIsWordedNotHiddenBehindLive() {
        let since = clock.now.addingTimeInterval(-3600)
        let relay = AuthoredPrsRelay(state: .offline, since: since)
        let overview = makeOverview(APT.snapshot([APT.pr(1)], relay: relay, poll: AuthoredPrsPoll(state: .ok, checkedAt: clock.now.addingTimeInterval(-40), intervalSecs: 300)))
        let text = overview.header.freshnessLabel.stringValue
        XCTAssertTrue(text.contains("relay offline since \(AuthoredPrsPresentation.clock(since, timeZone: APT.utc)) · polling every 5m"), text)
        XCTAssertFalse(text.contains("live"))
    }

    // MARK: - The skeleton

    func testTheSkeletonShowsForFiveSecondsThenAMessage() {
        let overview = makeOverview(nil)
        XCTAssertTrue(overview.isShowingSkeleton, "no snapshot yet: grey bars")
        XCTAssertNil(overview.shownMessage)
        assertHeaderVisible(overview, "skeleton")

        clock.advance(4.9)
        overview.tick()
        XCTAssertTrue(overview.isShowingSkeleton, "still inside the five seconds")

        clock.advance(0.2)
        overview.tick()
        XCTAssertFalse(overview.isShowingSkeleton)
        XCTAssertNotNil(overview.shownMessage, "after five seconds with nothing, a message")
        assertHeaderVisible(overview, "after the skeleton")
    }

    func testTheSkeletonReturnsAfterAReconnectThatBringsNoSnapshotYet() {
        let overview = makeOverview(nil)
        clock.advance(6)
        overview.tick()
        XCTAssertFalse(overview.isShowingSkeleton, "precondition: the message is up")

        overview.apply(snapshot: nil, connection: .reconnecting)
        overview.apply(snapshot: nil, connection: .connected)

        XCTAssertTrue(overview.isShowingSkeleton, "a fresh wait gets a fresh skeleton")
    }

    func testTheFirstSnapshotReplacesTheSkeleton() {
        let overview = makeOverview(nil)
        XCTAssertTrue(overview.isShowingSkeleton)
        overview.apply(snapshot: APT.snapshot([APT.pr(1, group: .needsYou)]), connection: .connected)
        XCTAssertFalse(overview.isShowingSkeleton)
        XCTAssertTrue(overview.isShowingList)
    }

    // MARK: - A daemon disconnect

    func testADaemonDisconnectKeepsTheLastSnapshotAndMarksItReconnecting() {
        let (_, view) = makeMotherView()
        connect(prs: [APT.pr(1, group: .needsYou), APT.pr(2, group: .ready)])
        let before = view.overviewView.displayedRowIds
        XCTAssertEqual(before.count, 2, "precondition")
        XCTAssertEqual(AppStore.shared.authoredPrsConnection, .connected)

        AppStore.shared.daemonDisconnectedForTesting()

        XCTAssertNotNil(AppStore.shared.authoredPrs, "the last snapshot is kept")
        XCTAssertEqual(AppStore.shared.authoredPrsConnection, .reconnecting)
        XCTAssertEqual(view.overviewView.displayedRowIds, before)
        XCTAssertEqual(view.overviewView.connection, .reconnecting)
        XCTAssertTrue(view.overviewView.isDimmed)
        XCTAssertTrue(APT.texts(in: view.overviewView.header).contains(AuthoredPrsPresentation.reconnectingText))
        XCTAssertTrue(view.hasPinnedOverviewRow, "the pinned row stays too")

        AppStore.shared.applyAuthoredPrsForTesting(APT.snapshot([APT.pr(1, group: .needsYou)]))
        XCTAssertEqual(AppStore.shared.authoredPrsConnection, .connected, "a frame means the link is back")
        XCTAssertFalse(view.overviewView.isDimmed)
        XCTAssertEqual(view.overviewView.displayedRowIds.count, 1)
    }

    // MARK: - Debug: Copy GitHub usage

    func testCopyGitHubUsagePutsCountsOnTheClipboardAndNothingElse() throws {
        var window = AuthoredPrsUsageCounts()
        window.charged = 7; window.graphqlPoints = 42; window.visibleCharged = 5
        var total = AuthoredPrsUsageCounts()
        total.charged = 123; total.search = 9
        let secretPr = APT.pr(9, repo: "secretorg/secretrepo", title: "SECRET-TITLE-xyz",
                              review: AuthoredPrReview(state: .approved, logins: ["secret-login"]),
                              owner: APT.motherOwner(job: "job-secret", name: "Secret Agent"))
        AppStore.shared.applyAuthoredPrsForTesting(APT.snapshot(
            [secretPr], hiddenOrgs: ["secret-org"], usage: AuthoredPrsUsage(windowSecs: 3600, window: window, sinceStart: total)))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("AuthoredPrsOverviewTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        let returned = AuthoredPrsDiagnostics.copyReportToPasteboard(store: AppStore.shared, pasteboard: pasteboard)

        let text = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertEqual(text, returned)
        for count in ["charged: 7", "graphql points: 42", "visible charged: 5", "charged: 123", "search: 9"] {
            XCTAssertTrue(text.contains(count), "the report has \(count):\n\(text)")
        }
        for secret in ["SECRET-TITLE", "secretorg", "secretrepo", "secret-login", "secret-org", "job-secret", "Secret Agent", "github.com"] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(secret), "the report must not carry \(secret):\n\(text)")
        }
        for line in text.split(separator: "\n") {
            let isHeading = line.hasPrefix("GitHub usage")
            let isCount = String(line).range(of: #"^[a-z ]+: \d+$"#, options: .regularExpression) != nil
            XCTAssertTrue(isHeading || isCount, "every line is a heading or a count: \(line)")
        }
    }

    func testCopyGitHubUsageBeforeAnyReportSaysSoAndReplacesTheClipboard() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("AuthoredPrsOverviewTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("stale", forType: .string)

        AuthoredPrsDiagnostics.copyReportToPasteboard(store: AppStore.shared, pasteboard: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "No GitHub usage reported yet.")
    }

    // MARK: - Untrusted text is plain text

    private func prJSON(title: String, name: String = "ci / build", login: String = "dana", base: String = "main",
                        owner: String = "Cody") -> [String: Any] {
        ["repo": "carefeed/portal", "number": 7, "url": "https://github.com/carefeed/portal/pull/7", "title": title,
         "group": "needs_you", "lifecycle": "open", "base_ref": base,
         "checks": ["state": "failing", "failed": 1, "failing_names": [name]],
         "review": ["state": "changes_requested", "logins": [login]],
         "owner": ["kind": "mother_job", "job_id": "a1b2c3", "name": owner]]
    }

    private func isPlainEverywhere(_ row: AuthoredPrRowView, file: StaticString = #filePath, line: UInt = #line) {
        let labels = [row.statusLabel, row.numberLabel, row.titleLabel, row.ageLabel, row.checksLabel, row.reviewLabel,
                      row.baseLabel, row.ownerPrefixLabel, row.ownerSuffixLabel]
        for label in labels {
            XCTAssertFalse(APT.hasLink(label.attributedStringValue), "no link attribute in \(label.stringValue)", file: file, line: line)
            XCTAssertFalse(label.allowsEditingTextAttributes, file: file, line: line)
            XCTAssertFalse(label.isSelectable, file: file, line: line)
        }
        XCTAssertFalse(APT.hasLink(row.jobButton.attributedTitle), "the job id is a button, not a link attribute", file: file, line: line)
        XCTAssertFalse(APT.descendants(of: row).contains { $0 is NSTextView }, "no rich text view in a row", file: file, line: line)
    }

    func testATitleWithMarkdownLinkSyntaxIsShownAsThePlainString() throws {
        let snapshot = try APT.decodedSnapshot(prs: [prJSON(title: "[click](https://evil)")])
        let overview = makeOverview(snapshot)
        let row = try XCTUnwrap(overview.rowView(forRowId: "carefeed/portal#7"))

        XCTAssertEqual(row.titleLabel.stringValue, "[click](https://evil)")
        XCTAssertEqual(row.titleLabel.attributedStringValue.string, "[click](https://evil)")
        isPlainEverywhere(row)
    }

    func testBidiAndRightToLeftControlsNeverReachTheScreen() throws {
        let raw = "\u{202E}[click](https://evil)\u{202C} \u{2066}rtl\u{2069}\u{200F}end"
        let cleaned = AuthoredPrsText.clean(raw, max: AuthoredPrsBounds.title)
        XCTAssertNotEqual(cleaned, raw, "precondition: the controls are there to be removed")
        let snapshot = try APT.decodedSnapshot(prs: [prJSON(title: raw, name: raw, login: raw, base: raw, owner: raw)])
        let overview = makeOverview(snapshot)
        let row = try XCTUnwrap(overview.rowView(forRowId: "carefeed/portal#7"))

        XCTAssertEqual(row.titleLabel.stringValue, cleaned)
        let bidi: (Unicode.Scalar) -> Bool = { [Unicode.GeneralCategory.format, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory) }
        for label in [row.titleLabel, row.checksLabel, row.reviewLabel, row.baseLabel, row.ownerSuffixLabel] {
            XCTAssertFalse(label.stringValue.unicodeScalars.contains(where: bidi), "no control characters in \(label.stringValue)")
        }
        XCTAssertFalse((row.accessibilityLabel() ?? "").unicodeScalars.contains(where: bidi), "nor in what VoiceOver reads")
        isPlainEverywhere(row)
    }

    func testMarkdownInCheckNamesLoginsAndBranchesIsAlsoPlain() throws {
        let hostile = "[x](https://evil)"
        let snapshot = try APT.decodedSnapshot(prs: [prJSON(title: "t", name: hostile, login: hostile, base: hostile, owner: hostile)])
        let overview = makeOverview(snapshot)
        let row = try XCTUnwrap(overview.rowView(forRowId: "carefeed/portal#7"))

        XCTAssertTrue(row.checksLabel.stringValue.contains(hostile))
        XCTAssertTrue(row.reviewLabel.stringValue.contains(hostile))
        XCTAssertTrue(row.baseLabel.stringValue.contains(hostile))
        isPlainEverywhere(row)
    }
}
