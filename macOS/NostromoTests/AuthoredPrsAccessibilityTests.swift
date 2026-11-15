import XCTest
import AppKit
import NostromoKit

// What VoiceOver gets from the Overview: each PR row is ONE element that reads the whole row; each group
// header is a heading with its count; the text a long title loses on screen is still read in full.
//
// Mutations (derived by reading the source, to be run by hand), and the test that fails for each:
//   M1 a row stops being one element (`setAccessibilityChildren([])` removed, or its labels exposed)
//        -> testEachRowIsOneElementThatReadsTheWholeRow
//   M2 a row's label is built from its pieces instead of Kit's `accessibilityLabel` (e.g. title only)
//        -> testEachRowIsOneElementThatReadsTheWholeRow
//   M3 a group header loses the heading role or its count -> testGroupHeadersAreHeadingsWithTheirCount
//   M4 the label is cut to the displayed title -> testALongTitleIsReadInFullEvenThoughItIsTruncatedOnScreen
//   M6 the custom action is missing, misnamed, or does not open the job; or is offered on a row with no job
//        -> testARowWithAMotherJobOffersAShowJobAction, testARowWithoutAJobOffersNoCustomAction
//   M5 the refresh button or the list lose their labels -> testTheListAndTheRefreshButtonHaveNames
final class AuthoredPrsAccessibilityTests: XCTestCase {

    private var windows: [NSWindow] = []
    private let clock = APT.FakeClock()

    override func tearDown() {
        for window in windows { window.contentView = nil; window.close() }
        windows = []
        super.tearDown()
    }

    private func makeOverview(_ snapshot: AuthoredPrsSnapshot?) -> AuthoredPrsOverviewView {
        let window = APT.window(size: NSSize(width: 700, height: 900))
        let overview = AuthoredPrsOverviewView(clock: clock.read, timeZone: APT.utc, store: nil)
        window.contentView = overview
        windows.append(window)
        overview.layoutSubtreeIfNeeded()
        overview.apply(snapshot: snapshot, connection: .connected)
        overview.layoutSubtreeIfNeeded()
        return overview
    }

    private var longTitle: String { String(String(repeating: "Longword ", count: 30).prefix(200)) }

    private func fixtures() -> [AuthoredPr] {
        let failing = AuthoredPrChecks(state: .failing, passed: 9, failed: 5,
                                       failingNames: ["swift-tests", "lint", "build", "e2e", "docs"])
        return [
            APT.pr(10, title: "Slash commands 1: picker", group: .needsYou, baseRef: "slash-commands-0",
                   checks: failing, review: AuthoredPrReview(state: .changesRequested, logins: ["dana", "li"]),
                   newComments: 3, unresolvedThreads: 2, owner: APT.motherOwner()),
            APT.pr(11, title: "Retry the relay", group: .needsYou),
            APT.pr(12, title: "Fix the flaky test", group: .needsYou, owner: AuthoredPrOwner(kind: .onBranch, name: "Cody in Nostromo")),
            APT.pr(13, title: longTitle, group: .ready, review: AuthoredPrReview(state: .approved, logins: ["dana"])),
            APT.pr(14, repo: "other/portal", title: "Same repo name, other owner", group: .waiting,
                   checks: AuthoredPrChecks(state: .pending, pending: 2)),
            APT.pr(15, title: "Wip", group: .draft, draft: true, checks: AuthoredPrChecks(state: .none)),
            APT.pr(16, title: "Shipped", group: .waiting, lifecycle: .merged, endedAt: clock.now),
        ]
    }

    // MARK: - Rows

    func testEachRowIsOneElementThatReadsTheWholeRow() throws {
        let prs = fixtures()
        let overview = makeOverview(APT.snapshot(prs))
        let chips = AuthoredPrsPresentation.repoChips(prs)

        for pr in prs {
            let row = try XCTUnwrap(overview.rowView(forRowId: pr.id), "row \(pr.id) is on screen")
            let expected = AuthoredPrsPresentation.row(pr, chip: chips[pr.repo], now: clock.now).accessibilityLabel
            XCTAssertFalse(expected.isEmpty, "precondition")
            XCTAssertTrue(row.isAccessibilityElement(), "\(pr.id): the row is an element")
            XCTAssertEqual(row.accessibilityRole(), .row, "\(pr.id)")
            XCTAssertTrue((row.accessibilityChildren() ?? []).isEmpty, "\(pr.id): nothing inside the row is separately focusable")
            XCTAssertEqual(row.accessibilityLabel(), expected, "\(pr.id): the label is the whole row in words")
        }
    }

    func testARowsLabelSaysWhatTheSightedReaderSees() throws {
        let prs = fixtures()
        let overview = makeOverview(APT.snapshot(prs))
        let row = try XCTUnwrap(overview.rowView(forRowId: prs[0].id))
        let label = try XCTUnwrap(row.accessibilityLabel())
        for part in ["PR 10", "Slash commands 1: picker", "checks failing", "swift-tests", "changes requested by dana, li",
                     "3 new comments", "2 unresolved threads", "base slash-commands-0"] {
            XCTAssertTrue(label.contains(part), "the label has '\(part)': \(label)")
        }
    }

    func testALongTitleIsReadInFullEvenThoughItIsTruncatedOnScreen() throws {
        let prs = fixtures()
        let overview = makeOverview(APT.snapshot(prs))
        let long = try XCTUnwrap(prs.first { $0.title == longTitle })
        XCTAssertEqual(longTitle.count, 200, "precondition")
        let row = try XCTUnwrap(overview.rowView(forRowId: long.id))

        XCTAssertEqual(row.titleLabel.lineBreakMode, .byTruncatingTail, "on screen the title is shortened")
        XCTAssertTrue(try XCTUnwrap(row.accessibilityLabel()).contains(longTitle), "the label has all 200 characters")
    }

    func testARowWithAMotherJobOffersAShowJobAction() throws {
        let prs = fixtures()
        let overview = makeOverview(APT.snapshot(prs))
        var opened: [String] = []
        overview.onOpenJob = { opened.append($0) }
        let row = try XCTUnwrap(overview.rowView(forRowId: prs[0].id))
        let actions = row.accessibilityCustomActions() ?? []

        XCTAssertEqual(actions.map(\.name), ["Show Mother job a1b2c3"])
        XCTAssertTrue(opened.isEmpty, "precondition")
        XCTAssertTrue(try XCTUnwrap(actions.first).handler?() ?? false, "the action reports it was handled")
        XCTAssertEqual(opened, ["a1b2c3"])
    }

    func testARowWithoutAJobOffersNoCustomAction() throws {
        let prs = fixtures()
        let overview = makeOverview(APT.snapshot(prs))
        for pr in prs where pr.owner.jobId == nil {
            let row = try XCTUnwrap(overview.rowView(forRowId: pr.id))
            XCTAssertTrue((row.accessibilityCustomActions() ?? []).isEmpty, "\(pr.id)")
        }
    }

    // MARK: - Group headers

    func testGroupHeadersAreHeadingsWithTheirCount() throws {
        let prs = fixtures()
        let overview = makeOverview(APT.snapshot(prs))
        let models = AuthoredPrsPresentation.groups(prs, now: clock.now, timeZone: APT.utc)
        XCTAssertEqual(models.map(\.group), [.needsYou, .ready, .waiting, .draft], "precondition")

        for model in models {
            let header = try XCTUnwrap(overview.groupHeaderView(for: model.group), "\(model.title) header")
            XCTAssertTrue(header.isAccessibilityElement(), model.title)
            XCTAssertEqual(header.accessibilityRole(), NSAccessibility.Role(rawValue: "AXHeading"), "\(model.title) is a heading")
            XCTAssertEqual(header.accessibilityLabel(), model.accessibilityLabel, model.title)
            XCTAssertTrue((header.accessibilityChildren() ?? []).isEmpty, "\(model.title): its pill is not read separately")
        }
        let needsYou = try XCTUnwrap(overview.groupHeaderView(for: .needsYou))
        XCTAssertEqual(needsYou.accessibilityLabel(), "Needs you, 3", "the group's own count, in words")
        XCTAssertEqual(try XCTUnwrap(overview.groupHeaderView(for: .waiting)).accessibilityLabel(), "Waiting on others, 2")
    }

    // MARK: - Chrome

    func testTheListAndTheRefreshButtonHaveNames() {
        let overview = makeOverview(APT.snapshot(fixtures()))
        XCTAssertEqual(overview.outline.accessibilityLabel(), "My open PRs")
        XCTAssertEqual(overview.header.refreshButton.accessibilityLabel(), "Refresh my open PRs")
        XCTAssertFalse(overview.header.isAccessibilityElement(), "the header is a container; its title and button are the elements")
    }

    func testTheEmptyAndLoadingStatesAreReadAsText() throws {
        let empty = makeOverview(APT.snapshot([]))
        let message = try XCTUnwrap(APT.descendants(of: empty).compactMap { $0 as? AuthoredPrsMessageView }.first)
        XCTAssertTrue(message.isAccessibilityElement())
        XCTAssertEqual(message.accessibilityLabel(), AuthoredPrsPresentation.emptyText)

        let loading = makeOverview(nil)
        let skeleton = try XCTUnwrap(APT.descendants(of: loading).compactMap { $0 as? AuthoredPrsSkeletonView }.first)
        XCTAssertTrue(skeleton.isAccessibilityElement())
        XCTAssertEqual(skeleton.accessibilityLabel(), "Loading your open PRs")
    }
}
