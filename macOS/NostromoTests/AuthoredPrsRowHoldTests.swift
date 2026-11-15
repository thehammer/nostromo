import XCTest
import AppKit
import NostromoKit

// A row the reader is pointing at or has selected must not move or vanish under them; a Merged or Closed row
// lingers for 60 seconds and then goes. Driven through a stand-alone Overview with an injected clock, plus the
// pure Kit rule (`AuthoredPrsHold.merge`) it is built on.
//
// Mutations (derived by reading the source, to be run by hand), and the test that fails for each:
//   M1 `heldIds` ignores the hovered row
//        -> testAHoveredRowDoesNotMoveOnARegroupingSnapshotUntilTheHoverEnds,
//           testAHoveredRowDoesNotVanishWhenTheSnapshotDropsItUntilTheHoverEnds
//   M2 `heldIds` ignores the selected row
//        -> testASelectedRowDoesNotMoveOnARegroupingSnapshotUntilTheSelectionEnds,
//           testASelectedRowDoesNotVanishWhenTheSnapshotDropsItUntilTheSelectionEnds
//   M3 `setHovered` / `outlineViewSelectionDidChange` do not reconcile when the hold ends
//        -> the "...until the hover ends" and "...until the selection ends" tests (the pending move never applies)
//   M4 lingerSeconds 60 -> 30 (or 120)
//        -> testAMergedRowShowsForSixtySecondsThenIsRemoved, testAClosedRowLingersTheSameSixtySeconds
//   M5 `tick()` does not reconcile
//        -> testAMergedRowShowsForSixtySecondsThenIsRemoved
//   M6 a held row is dropped once it expires
//        -> testAHeldRowThatAlreadyEndedIsStillHeldUntilItIsReleased
//   M7 `merge` ignores `held` -> every Kit-level "held" test below
//   M8 `merge` puts a held row at the end of its group instead of its slot
//        -> testAHeldRowKeepsItsGroupAndItsPlaceWhenTheSnapshotMovesIt, testTwoHeldRowsKeepTheirPlaces
final class AuthoredPrsRowHoldTests: XCTestCase {

    private var windows: [NSWindow] = []
    private let clock = APT.FakeClock()

    override func tearDown() {
        for window in windows { window.contentView = nil; window.close() }
        windows = []
        super.tearDown()
    }

    private let a = APT.pr(1, title: "A", group: .needsYou)
    private let b = APT.pr(2, title: "B", group: .needsYou)
    private let c = APT.pr(3, title: "C", group: .ready)
    private let d = APT.pr(4, title: "D", group: .waiting)

    private func moved(_ pr: AuthoredPr, to group: AuthoredPrGroup, title: String? = nil) -> AuthoredPr {
        var copy = pr
        copy.group = group
        if let title { copy.title = title }
        return copy
    }

    private func makeOverview(_ prs: [AuthoredPr]) -> AuthoredPrsOverviewView {
        let window = APT.window(size: NSSize(width: 700, height: 600))
        let overview = AuthoredPrsOverviewView(clock: clock.read, timeZone: APT.utc, store: nil)
        window.contentView = overview
        windows.append(window)
        overview.layoutSubtreeIfNeeded()
        overview.apply(snapshot: APT.snapshot(prs), connection: .connected)
        overview.layoutSubtreeIfNeeded()
        return overview
    }

    private func apply(_ prs: [AuthoredPr], to overview: AuthoredPrsOverviewView) {
        overview.apply(snapshot: APT.snapshot(prs), connection: .connected)
    }

    private let allThree = ["NEEDS YOU", "READY", "WAITING ON OTHERS"]

    // MARK: - A hovered row holds still

    func testAHoveredRowDoesNotMoveOnARegroupingSnapshotUntilTheHoverEnds() {
        let overview = makeOverview([a, b, c, d])
        XCTAssertEqual(overview.displayedRowIds, [a.id, b.id, c.id, d.id], "precondition")
        XCTAssertEqual(overview.groupTitles, allThree, "precondition")
        overview.setHovered(rowId: b.id)

        apply([c, d, moved(b, to: .waiting)], to: overview)   // a is gone and b regrouped

        XCTAssertEqual(overview.displayedRowIds, [b.id, c.id, d.id], "b stays under the pointer in its old group; a's removal applies... only after")
        XCTAssertEqual(overview.groupTitles, allThree, "b's old group stays while b is held")

        overview.setHovered(rowId: nil)

        XCTAssertEqual(overview.displayedRowIds, [c.id, d.id, b.id], "the hover ended: b moves to its new group")
        XCTAssertEqual(overview.groupTitles, ["READY", "WAITING ON OTHERS"])
    }

    func testAHoveredRowDoesNotVanishWhenTheSnapshotDropsItUntilTheHoverEnds() {
        let overview = makeOverview([a, b, c, d])
        overview.setHovered(rowId: b.id)

        apply([a, c, d], to: overview)

        XCTAssertEqual(overview.displayedRowIds, [a.id, b.id, c.id, d.id], "b is still there under the pointer")

        overview.setHovered(rowId: nil)

        XCTAssertEqual(overview.displayedRowIds, [a.id, c.id, d.id], "the hover ended: b goes")
    }

    func testMovingThePointerToAnotherRowReleasesTheFirst() {
        let overview = makeOverview([a, b, c, d])
        overview.setHovered(rowId: b.id)
        apply([a, c, d], to: overview)
        XCTAssertTrue(overview.displayedRowIds.contains(b.id), "precondition: b is held")

        overview.setHovered(rowId: c.id)

        XCTAssertEqual(overview.displayedRowIds, [a.id, c.id, d.id], "b is released as soon as the pointer is on c")
    }

    func testAHeldRowStillFollowsTheSnapshotsOtherFields() throws {
        let overview = makeOverview([a, b, c, d])
        overview.setHovered(rowId: b.id)

        apply([a, moved(b, to: .needsYou, title: "B, retitled"), c, d], to: overview)

        let row = try XCTUnwrap(overview.rowView(forRowId: b.id))
        XCTAssertEqual(row.titleLabel.stringValue, "B, retitled", "holding a row's place does not freeze its words")
    }

    // MARK: - A selected row holds still

    func testASelectedRowDoesNotMoveOnARegroupingSnapshotUntilTheSelectionEnds() {
        let overview = makeOverview([a, b, c, d])
        overview.selectRow(id: b.id)
        XCTAssertEqual(overview.selectedRowId, b.id, "precondition")

        apply([c, d, moved(b, to: .waiting)], to: overview)

        XCTAssertEqual(overview.displayedRowIds, [b.id, c.id, d.id])
        XCTAssertEqual(overview.groupTitles, allThree)
        XCTAssertEqual(overview.selectedRowId, b.id, "and it is still the selected one")

        overview.clearSelection()

        XCTAssertEqual(overview.displayedRowIds, [c.id, d.id, b.id])
        XCTAssertEqual(overview.groupTitles, ["READY", "WAITING ON OTHERS"])
    }

    func testASelectedRowDoesNotVanishWhenTheSnapshotDropsItUntilTheSelectionEnds() {
        let overview = makeOverview([a, b, c, d])
        overview.selectRow(id: b.id)

        apply([a, c, d], to: overview)
        XCTAssertEqual(overview.displayedRowIds, [a.id, b.id, c.id, d.id])
        XCTAssertEqual(overview.selectedRowId, b.id)

        overview.clearSelection()
        XCTAssertEqual(overview.displayedRowIds, [a.id, c.id, d.id])
    }

    func testSelectingAnotherRowReleasesTheFirst() {
        let overview = makeOverview([a, b, c, d])
        overview.selectRow(id: b.id)
        apply([a, c, d], to: overview)
        XCTAssertTrue(overview.displayedRowIds.contains(b.id), "precondition: b is held")

        overview.selectRow(id: c.id)

        XCTAssertEqual(overview.displayedRowIds, [a.id, c.id, d.id])
        XCTAssertEqual(overview.selectedRowId, c.id)
    }

    func testAHoverAndASelectionAreReleasedIndependently() {
        let overview = makeOverview([a, b, c, d])
        overview.setHovered(rowId: a.id)
        overview.selectRow(id: b.id)

        apply([c, moved(a, to: .ready), moved(b, to: .waiting), d], to: overview)
        XCTAssertEqual(overview.displayedRowIds, [a.id, b.id, c.id, d.id], "both hold still")

        overview.setHovered(rowId: nil)
        XCTAssertEqual(overview.displayedRowIds, [b.id, c.id, a.id, d.id], "a moves, b is still selected")

        overview.clearSelection()
        XCTAssertEqual(overview.displayedRowIds, [c.id, a.id, b.id, d.id], "now b moves too")
        XCTAssertEqual(overview.groupTitles, ["READY", "WAITING ON OTHERS"])
    }

    // MARK: - Merged and Closed linger for sixty seconds

    private func rowStatus(_ overview: AuthoredPrsOverviewView, _ pr: AuthoredPr) -> String? {
        overview.rowView(forRowId: pr.id)?.statusLabel.stringValue
    }

    func testAMergedRowShowsForSixtySecondsThenIsRemoved() {
        let merged = APT.pr(9, title: "M", group: .waiting, lifecycle: .merged, endedAt: clock.now)
        let overview = makeOverview([a, merged])
        XCTAssertTrue(overview.displayedRowIds.contains(merged.id))
        XCTAssertTrue(rowStatus(overview, merged)?.contains("Merged") == true, "it says Merged: \(String(describing: rowStatus(overview, merged)))")

        clock.advance(59.9)
        overview.tick()
        XCTAssertTrue(overview.displayedRowIds.contains(merged.id), "still there just under a minute")

        clock.advance(0.2)
        overview.tick()
        XCTAssertEqual(overview.displayedRowIds, [a.id], "a minute after it ended, the row is gone")
        XCTAssertEqual(overview.groupTitles, ["NEEDS YOU"], "and so is its now-empty group")
    }

    func testAClosedRowLingersTheSameSixtySeconds() {
        let closed = APT.pr(9, title: "X", group: .waiting, lifecycle: .closed, endedAt: clock.now)
        let overview = makeOverview([a, closed])
        XCTAssertTrue(rowStatus(overview, closed)?.contains("Closed") == true)

        clock.advance(59.9)
        overview.tick()
        XCTAssertTrue(overview.displayedRowIds.contains(closed.id))
        clock.advance(0.2)
        overview.tick()
        XCTAssertEqual(overview.displayedRowIds, [a.id])
    }

    func testAnEndedRowWithNoEndTimeIsNotRemovedByTheClock() {
        let merged = APT.pr(9, title: "M", group: .waiting, lifecycle: .merged, endedAt: nil)
        let overview = makeOverview([a, merged])
        clock.advance(3600)
        overview.tick()
        XCTAssertTrue(overview.displayedRowIds.contains(merged.id), "without an end time there is nothing to count from")
    }

    func testARowThatEndedLongAgoIsNotShownWhenItArrives() {
        let stale = APT.pr(9, title: "M", group: .waiting, lifecycle: .merged, endedAt: clock.now.addingTimeInterval(-61))
        let overview = makeOverview([a, stale])
        XCTAssertEqual(overview.displayedRowIds, [a.id])
    }

    func testAHeldRowThatAlreadyEndedIsStillHeldUntilItIsReleased() {
        let merged = APT.pr(9, title: "M", group: .waiting, lifecycle: .merged, endedAt: clock.now.addingTimeInterval(-30))
        let overview = makeOverview([a, merged])
        overview.setHovered(rowId: merged.id)

        clock.advance(31)
        overview.tick()
        XCTAssertTrue(overview.displayedRowIds.contains(merged.id), "past its minute but under the pointer: held")

        overview.setHovered(rowId: nil)
        XCTAssertEqual(overview.displayedRowIds, [a.id], "released: gone")
    }

    func testASelectedRowThatAlreadyEndedIsStillHeldUntilItIsDeselected() {
        let merged = APT.pr(9, title: "M", group: .waiting, lifecycle: .merged, endedAt: clock.now.addingTimeInterval(-30))
        let overview = makeOverview([a, merged])
        overview.selectRow(id: merged.id)

        clock.advance(31)
        overview.tick()
        XCTAssertTrue(overview.displayedRowIds.contains(merged.id))

        overview.clearSelection()
        XCTAssertEqual(overview.displayedRowIds, [a.id])
    }

    // MARK: - The rule itself (Kit)

    private func ids(_ prs: [AuthoredPr]) -> [String] { prs.map(\.id) }

    func testWithNothingHeldTheIncomingRowsAreShownAsTheyAre() {
        let incoming = [moved(b, to: .ready), c, d]
        XCTAssertEqual(AuthoredPrsHold.merge(displayed: [a, b, c, d], incoming: incoming, held: []), incoming)
    }

    func testAHeldRowKeepsItsGroupAndItsPlaceWhenTheSnapshotMovesIt() throws {
        let a1 = a, b1 = b, c1 = APT.pr(5, title: "E", group: .needsYou)
        let result = AuthoredPrsHold.merge(displayed: [a1, b1, c1], incoming: [a1, moved(b1, to: .ready), c1], held: [b1.id])

        XCTAssertEqual(ids(result), [a1.id, b1.id, c1.id], "b is where it was")
        XCTAssertEqual(try XCTUnwrap(result.first { $0.id == b1.id }).group, .needsYou, "in the group it was in")
    }

    func testAHeldRowStaysWhenTheSnapshotDropsIt() {
        let result = AuthoredPrsHold.merge(displayed: [a, b, c], incoming: [a, c], held: [b.id])
        XCTAssertEqual(ids(result), [a.id, b.id, c.id])
    }

    func testAHeldRowsOtherFieldsFollowTheSnapshot() throws {
        let result = AuthoredPrsHold.merge(displayed: [a, b], incoming: [a, moved(b, to: .ready, title: "B2")], held: [b.id])
        let row = try XCTUnwrap(result.first { $0.id == b.id })
        XCTAssertEqual(row.title, "B2")
        XCTAssertEqual(row.group, .needsYou)
    }

    func testReleasingTheHoldAppliesEveryPendingMoveAndRemoval() {
        let incoming = [c, d, moved(b, to: .waiting)]
        let held = AuthoredPrsHold.merge(displayed: [a, b, c, d], incoming: incoming, held: [b.id])
        XCTAssertNotEqual(ids(held), ids(incoming), "precondition: the hold changed something")

        XCTAssertEqual(AuthoredPrsHold.merge(displayed: held, incoming: incoming, held: []), incoming)
    }

    func testTwoHeldRowsKeepTheirPlaces() {
        let e = APT.pr(5, title: "E", group: .needsYou), f = APT.pr(6, title: "F", group: .needsYou)
        let result = AuthoredPrsHold.merge(displayed: [a, b, e, f], incoming: [f, e, b, a], held: [b.id, e.id])

        XCTAssertEqual(result.firstIndex { $0.id == b.id }, 1)
        XCTAssertEqual(result.firstIndex { $0.id == e.id }, 2)
        XCTAssertEqual(Set(ids(result)), Set([a.id, b.id, e.id, f.id]), "nothing lost, nothing doubled")
        XCTAssertEqual(result.count, 4)
    }

    func testGroupsStayInDisplayOrderWhateverIsHeld() {
        let result = AuthoredPrsHold.merge(displayed: [a, b, c, d], incoming: [d, c, moved(a, to: .draft), moved(b, to: .waiting)], held: [a.id])
        let order = result.map(\.group)
        let ranks = order.map { AuthoredPrGroup.displayOrder.firstIndex(of: $0)! }
        XCTAssertEqual(ranks, ranks.sorted(), "needs you, ready, waiting, drafts, other: \(order)")
    }

    func testAHeldIdThatIsNotOnScreenAddsNothingAndHidesNothing() {
        let x = APT.pr(7, title: "X", group: .ready)
        let unknown = AuthoredPrsHold.merge(displayed: [a], incoming: [a], held: ["not-a-row"])
        XCTAssertEqual(ids(unknown), [a.id], "a held id with no row conjures none")

        let arriving = AuthoredPrsHold.merge(displayed: [a], incoming: [a, x], held: [x.id])
        XCTAssertTrue(ids(arriving).contains(x.id), "a row that is not on screen cannot be held back: it is shown when it arrives")
    }
}
