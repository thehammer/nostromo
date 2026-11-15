import XCTest
import AppKit
import NostromoKit

// The waiting pill a PR raises on its focus's sidebar row.
//
// Contract. A PR the daemon marks `pill` (it needs the user and its known, open owner has not been told) is
// ONE waiting item on that owner's focus: it adds one to the waiting pill and nothing to the blocking one. A
// draft, an unknown, ambiguous or closed owner, or a row the daemon did not mark raises nothing. When the next
// snapshot no longer marks it (the focus was told, the PR was fixed) the item goes. Resetting the store clears
// it.
//
// Every test uses its own focus tags: `AppStore.shared` is process-wide and other producers' items (Mother,
// approvals) may be in it.
//
// Mutations (to be run by hand), and the test that fails for each:
//   M1 `prAttention` classed as blocking                 -> testAPrAttentionReasonIsWaiting, testAMarkedPrAddsOneWaitingCountAndNoBlockingCount
//   M2 the store does not hand the snapshot to the producer -> testAMarkedPrAddsOneWaitingCountAndNoBlockingCount
//   M3 a row the daemon did not mark still raises one    -> testRowsTheDaemonDidNotMarkAndOwnersThatCannotBeToldRaiseNothing
//   M4 the item stays when the next snapshot clears the mark -> testThePillGoesWhenTheNextSnapshotClearsTheMark
//   M5 reset leaves the items behind                     -> testResettingTheStoreClearsThePills
final class AuthoredPrPillTests: XCTestCase {

    private let store = AppStore.shared

    override func setUp() {
        super.setUp()
        store.resetAuthoredPrsForTesting()
    }

    override func tearDown() {
        store.resetAuthoredPrsForTesting()
        super.tearDown()
    }

    private func uniqueTag(_ stem: String = "pill") -> String { "\(stem)-\(UUID().uuidString)" }

    private func owner(_ kind: AuthoredPrOwnerKind = .motherJob, tag: String) -> AuthoredPrOwner {
        AuthoredPrOwner(kind: kind, tag: tag, name: "Cody (nostromo)", jobId: kind == .motherJob ? "a1b2c3" : nil)
    }

    private func apply(_ prs: [AuthoredPr]) {
        store.daemonConnectedForTesting(authoredPrs: true, notify: true)
        store.applyAuthoredPrsForTesting(APT.snapshot(prs))
    }

    private func waiting(_ tag: String) -> Int { SidebarBadgeModel.needsYouCounts(from: store.needsYou).waiting[tag] ?? 0 }
    private func blocking(_ tag: String) -> Int { SidebarBadgeModel.needsYouCounts(from: store.needsYou).blocking[tag] ?? 0 }

    private func authoredPrItems(on tag: String) -> [NeedsYouItem] {
        store.needsYou.items.filter { $0.id.hasPrefix("authored-pr:") && $0.source == .focus(tag) }
    }

    // MARK: - Classification

    func testAPrAttentionReasonIsWaiting() {
        XCTAssertEqual(SidebarBadgeModel.needsYouClass(of: .prAttention(number: 458)), .waiting)
    }

    // MARK: - Raising

    func testAMarkedPrAddsOneWaitingCountAndNoBlockingCount() {
        let tag = uniqueTag()
        XCTAssertEqual(waiting(tag), 0, "precondition")

        apply([HF.pr(458, owner: owner(tag: tag), pill: true)])

        XCTAssertEqual(store.needsYou.perFocus[tag], 1, "exactly one item on the owner's focus")
        XCTAssertEqual(waiting(tag), 1, "one on the waiting pill")
        XCTAssertEqual(blocking(tag), 0, "none on the blocking one: a PR never stops an agent")
        XCTAssertEqual(authoredPrItems(on: tag).map(\.reason), [.prAttention(number: 458)])
    }

    func testTwoMarkedPrsOnOneFocusAddTwoAndEachFocusIsCountedOnItsOwn() {
        let one = uniqueTag("one"), two = uniqueTag("two")
        apply([
            HF.pr(1, owner: owner(tag: one), pill: true),
            HF.pr(2, owner: owner(.linked, tag: one), pill: true),
            HF.pr(3, owner: owner(.onBranch, tag: two), pill: true),
        ])
        XCTAssertEqual(waiting(one), 2)
        XCTAssertEqual(waiting(two), 1)
    }

    func testRowsTheDaemonDidNotMarkAndOwnersThatCannotBeToldRaiseNothing() {
        let tag = uniqueTag()
        let candidates = [AuthoredPrCandidate(tag: tag, name: "A", via: .motherJob)]
        apply([
            HF.pr(10, owner: owner(tag: tag), pill: false),                                             // not marked
            HF.pr(11, group: .draft, draft: true, owner: owner(tag: tag), pill: true),                  // a draft
            HF.pr(12, owner: AuthoredPrOwner(kind: .closed, tag: tag, name: "Gone"), pill: true),       // closed owner
            HF.pr(13, owner: AuthoredPrOwner(kind: .ambiguous, tag: tag, candidates: candidates), pill: true),
            HF.pr(14, owner: .unknown, pill: true),                                                     // unknown owner
            HF.pr(15, group: .ready, lifecycle: .merged, owner: owner(tag: tag), pill: true),           // merged
        ])
        XCTAssertEqual(store.needsYou.perFocus[tag] ?? 0, 0)
        XCTAssertEqual(waiting(tag), 0)
        XCTAssertEqual(blocking(tag), 0)
        XCTAssertTrue(store.needsYou.items.filter { $0.id.hasPrefix("authored-pr:") }.isEmpty, "nothing at all from the PR producer")
    }

    // MARK: - Going away

    func testThePillGoesWhenTheNextSnapshotClearsTheMark() {
        let tag = uniqueTag()
        apply([HF.pr(458, owner: owner(tag: tag), pill: true)])
        XCTAssertEqual(waiting(tag), 1, "precondition")

        // The focus was told: the daemon sends the row again without the mark (and with `told`).
        apply([HF.pr(458, owner: owner(tag: tag), told: HF.told(), pill: false)])

        XCTAssertEqual(waiting(tag), 0)
        XCTAssertNil(store.needsYou.perFocus[tag])
    }

    func testThePillGoesWhenThePrLeavesTheList() {
        let tag = uniqueTag()
        apply([HF.pr(458, owner: owner(tag: tag), pill: true)])
        apply([])
        XCTAssertEqual(waiting(tag), 0)
    }

    func testAMarkedPrAppearingInALaterSnapshotRaisesIt() {
        let tag = uniqueTag()
        apply([HF.pr(458, owner: owner(tag: tag), pill: false)])
        XCTAssertEqual(waiting(tag), 0)
        apply([HF.pr(458, owner: owner(tag: tag), pill: true)])
        XCTAssertEqual(waiting(tag), 1)
    }

    func testResettingTheStoreClearsThePills() {
        let tag = uniqueTag()
        apply([HF.pr(458, owner: owner(tag: tag), pill: true)])
        XCTAssertEqual(waiting(tag), 1, "precondition")

        store.resetAuthoredPrsForTesting()

        XCTAssertEqual(waiting(tag), 0)
        XCTAssertTrue(authoredPrItems(on: tag).isEmpty)
    }

    func testTheSamePrSnapshotAppliedTwiceIsStillOneItem() {
        let tag = uniqueTag()
        let pr = HF.pr(458, owner: owner(tag: tag), pill: true)
        apply([pr])
        apply([pr])
        XCTAssertEqual(waiting(tag), 1)
    }
}
