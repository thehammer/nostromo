// NostromoKit — TrackerDiffTests.swift
//
// Old rows × new rows → keyed operations (T1, design contract §9; PRD 20): an update touches only
// the rows that changed, an identical push changes nothing, a reorder is one move and not a move
// per neighbour, and a clock tick is told apart from a real change.
//
// Two layers: rows presented from the golden board (what the pane really diffs) and small
// synthetic row lists whose keys make the expected operations obvious. Fixtures and board edits
// come from `TrackerFixtures` (TrackerPresentationTests.swift).

import XCTest
@testable import NostromoKit

private typealias TFx = TrackerFixtures

final class TrackerDiffTests: XCTestCase {

    // MARK: Helpers

    private func rows(_ board: TrackerBoardViewWire, now: Date = TFx.now,
                      filter: TrackerFilter = .all) -> [TrackerRow] {
        TFx.present(board, now: now, filter: filter).rows
    }

    private func touched(_ ops: [TrackerDiffOp]) -> Set<String> {
        Set(ops.map { $0.key })
    }

    private func inserts(_ ops: [TrackerDiffOp]) -> [(row: TrackerRow, at: Int)] {
        ops.compactMap { op -> (row: TrackerRow, at: Int)? in
            if case .insert(let row, let index) = op { return (row, index) }
            return nil
        }
    }

    private func updates(_ ops: [TrackerDiffOp]) -> [TrackerRow] {
        ops.compactMap { op -> TrackerRow? in
            if case .update(let row) = op { return row }
            return nil
        }
    }

    private func removes(_ ops: [TrackerDiffOp]) -> [String] {
        ops.compactMap { op -> String? in
            if case .remove(let key) = op { return key }
            return nil
        }
    }

    private func moves(_ ops: [TrackerDiffOp]) -> [(key: String, to: Int)] {
        ops.compactMap { op -> (key: String, to: Int)? in
            if case .move(let key, let to) = op { return (key, to) }
            return nil
        }
    }

    /// A tiny row for the synthetic cases: its key is its identity, `text` is its content.
    private func prose(_ key: String, _ text: String = "x") -> TrackerRow {
        TrackerRow(key: key, content: .prose(TrackerProseRow(key: key, blocks: [.paragraph([.text(text)])])))
    }

    private func proseRows(_ keys: [String]) -> [TrackerRow] {
        keys.map { prose($0) }
    }

    /// Every insert lands where the row is in the new rows, every move names its new index.
    private func assertIndexesPointAtTheNewRows(_ ops: [TrackerDiffOp], new: [TrackerRow],
                                                file: StaticString = #filePath, line: UInt = #line) {
        for insert in inserts(ops) {
            XCTAssertLessThan(insert.at, new.count, file: file, line: line)
            if insert.at < new.count {
                XCTAssertEqual(new[insert.at].key, insert.row.key, "insert index", file: file, line: line)
            }
        }
        for move in moves(ops) {
            XCTAssertLessThan(move.to, new.count, file: file, line: line)
            if move.to < new.count {
                XCTAssertEqual(new[move.to].key, move.key, "move index", file: file, line: line)
            }
        }
    }

    // MARK: Nothing changed

    func testIdenticalRowsProduceNoOps() throws {
        let old = rows(try TFx.golden())
        XCTAssertTrue(TrackerDiff.ops(from: old, to: old).isEmpty)
    }

    func testPresentingTheSameBoardTwiceProducesNoOps() throws {
        let first = rows(try TFx.golden())
        let second = rows(try TFx.golden())
        XCTAssertTrue(TrackerDiff.ops(from: first, to: second).isEmpty)
    }

    func testPresentingTheSameBoardTwiceProducesNoOpsUnderEveryFilter() throws {
        for filter in TrackerFilter.allCases {
            let first = rows(try TFx.golden(), filter: filter)
            let second = rows(try TFx.golden(), filter: filter)
            XCTAssertTrue(TrackerDiff.ops(from: first, to: second).isEmpty, "\(filter)")
        }
    }

    func testDiffingEmptyRowListsProducesNoOps() {
        XCTAssertTrue(TrackerDiff.ops(from: [], to: []).isEmpty)
    }

    // MARK: Content changes

    func testAStatusChangeOfOneItemIsExactlyOneUpdateForThatItem() throws {
        let old = rows(try TFx.golden())
        let new = rows(try TFx.edited { try $0.setStatus("revie-1111", "blocked") })
        let ops = TrackerDiff.ops(from: old, to: new)
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(touched(ops), ["item:revie-1111"])
        let row = try XCTUnwrap(updates(ops).first)
        XCTAssertEqual(row.item?.status, .blocked)
        XCTAssertEqual(row.item?.mark, "⊘")
    }

    func testATextOrOwnerChangeOfOneItemIsExactlyOneUpdateForThatItem() throws {
        let old = rows(try TFx.golden())
        let retitled = rows(try TFx.edited { try $0.setText("revie-1111", "Review queue job 9000") })
        XCTAssertEqual(touched(TrackerDiff.ops(from: old, to: retitled)), ["item:revie-1111"])
        let reassigned = rows(try TFx.edited { try $0.setOwner("revie-1111", "marty") })
        XCTAssertEqual(touched(TrackerDiff.ops(from: old, to: reassigned)), ["item:revie-1111"])
    }

    func testAnItemFinishedInASectionWithoutADoneGroupLeavesItsRowAndOpensTheGroup() throws {
        let old = rows(try TFx.golden())
        let new = rows(try TFx.edited { try $0.setStatus("revie-1111", "done") })
        let ops = TrackerDiff.ops(from: old, to: new)
        XCTAssertEqual(ops.count, 2)
        XCTAssertEqual(removes(ops), ["item:revie-1111"])
        let inserted = try XCTUnwrap(inserts(ops).first)
        XCTAssertEqual(inserted.row.key, "done:now")
        assertIndexesPointAtTheNewRows(ops, new: new)
    }

    func testAnItemFinishedInASectionWithADoneGroupUpdatesTheGroupsCount() throws {
        let old = rows(try TFx.golden())
        let new = rows(try TFx.edited { try $0.setStatus("repro-2554", "done") })
        let ops = TrackerDiff.ops(from: old, to: new)
        XCTAssertEqual(ops.count, 2)
        XCTAssertEqual(removes(ops), ["item:repro-2554"])
        XCTAssertEqual(updates(ops).map { $0.key }, ["done:findings"])
        guard case .doneGroup(let group) = try XCTUnwrap(updates(ops).first).content else {
            return XCTFail("the update is the Done group")
        }
        XCTAssertEqual(group.count, 6)
    }

    func testUnderOpenAnItemFinishedLeavesItsRowAndLowersItsSectionCount() throws {
        let old = rows(try TFx.golden(), filter: .open)
        let new = rows(try TFx.edited { try $0.setStatus("revie-1111", "done") }, filter: .open)
        let ops = TrackerDiff.ops(from: old, to: new)
        XCTAssertEqual(touched(ops), ["item:revie-1111", "section:now"])
        XCTAssertEqual(removes(ops), ["item:revie-1111"])
        guard case .section(let section) = try XCTUnwrap(updates(ops).first).content else {
            return XCTFail("the update is the section")
        }
        XCTAssertEqual(section.count, 9)
    }

    func testInsertingAnItemIsOneInsertAtItsPlaceAndOneSectionCountUpdate() throws {
        let old = rows(try TFx.golden())
        let new = rows(try TFx.edited { try $0.insertItem(id: "brand-new-1", section: "next") })
        let ops = TrackerDiff.ops(from: old, to: new)
        XCTAssertEqual(ops.count, 2)
        XCTAssertEqual(touched(ops), ["item:brand-new-1", "section:next"])
        let inserted = try XCTUnwrap(inserts(ops).first)
        XCTAssertEqual(inserted.row.key, "item:brand-new-1")
        XCTAssertEqual(inserted.at, try XCTUnwrap(TFx.rowIndex("section:next", in: new)) + 1,
                       "the new item sits directly under the Next heading")
        XCTAssertEqual(updates(ops).map { $0.key }, ["section:next"])
        assertIndexesPointAtTheNewRows(ops, new: new)
    }

    func testRemovingAnItemIsOneRemoveAndOneSectionCountUpdateWithNoMoves() throws {
        let old = rows(try TFx.golden())
        let new = rows(try TFx.edited { try $0.removeItem("audit-1407") })
        let ops = TrackerDiff.ops(from: old, to: new)
        XCTAssertEqual(ops.count, 2)
        XCTAssertEqual(removes(ops), ["item:audit-1407"])
        XCTAssertEqual(updates(ops).map { $0.key }, ["section:next"])
        XCTAssertTrue(moves(ops).isEmpty, "rows that only shift up are not moves")
    }

    func testChangingTheLogTouchesOnlyTheLogRow() throws {
        let old = rows(try TFx.golden())
        let new = rows(try TFx.edited { $0.setLog((1...13).map { "Claudia: logged event \($0)" }) })
        XCTAssertEqual(touched(TrackerDiff.ops(from: old, to: new)), ["log"])
    }

    func testAnOpenedFoldTouchesOnlyTheGroupAndInsertsItsItems() throws {
        let board = try TFx.golden()
        let old = TFx.present(board).rows
        let new = TFx.present(board, folds: TrackerFoldState(expandedDoneGroups: ["findings"])).rows
        let ops = TrackerDiff.ops(from: old, to: new)
        let expectedItems = ["triag-2591", "backf-2665", "audit-2739", "verif-2813", "revie-2887"].map { "item:\($0)" }
        XCTAssertEqual(touched(ops), Set(expectedItems + ["done:findings"]))
        XCTAssertEqual(inserts(ops).map { $0.row.key }, expectedItems)
        assertIndexesPointAtTheNewRows(ops, new: new)
    }

    // MARK: Reordering

    func testMovingOneItemToTheEndOfItsSectionIsASingleMove() throws {
        let old = rows(try TFx.golden())
        let new = rows(try TFx.edited { try $0.moveItem("rotat-1370", after: "triag-1703") })
        let ops = TrackerDiff.ops(from: old, to: new)
        XCTAssertEqual(ops.count, 1)
        let move = try XCTUnwrap(moves(ops).first)
        XCTAssertEqual(move.key, "item:rotat-1370")
        XCTAssertEqual(move.to, TFx.rowIndex("item:rotat-1370", in: new))
    }

    func testMovingOneItemToTheTopOfItsSectionIsASingleMove() throws {
        let old = rows(try TFx.golden())
        let new = rows(try TFx.edited { try $0.moveItem("triag-1703", before: "rotat-1370") })
        let ops = TrackerDiff.ops(from: old, to: new)
        XCTAssertEqual(ops.count, 1)
        let move = try XCTUnwrap(moves(ops).first)
        XCTAssertEqual(move.key, "item:triag-1703")
        XCTAssertEqual(move.to, TFx.rowIndex("item:triag-1703", in: new))
    }

    func testSwappingTwoAdjacentItemsIsASingleMoveOfOneOfThem() throws {
        let old = rows(try TFx.golden())
        let new = rows(try TFx.edited { try $0.moveItem("audit-1407", before: "rotat-1370") })
        let ops = TrackerDiff.ops(from: old, to: new)
        XCTAssertEqual(ops.count, 1)
        let movedKey = try XCTUnwrap(moves(ops).first).key
        XCTAssertTrue(["item:audit-1407", "item:rotat-1370"].contains(movedKey), movedKey)
    }

    func testAnItemMovedToAnotherSectionMovesAndUpdatesAloneAndBothSectionCountsUpdate() throws {
        let old = rows(try TFx.golden())
        let new = rows(try TFx.edited { try $0.moveItem("revie-1111", toSection: "next") })
        let ops = TrackerDiff.ops(from: old, to: new)
        XCTAssertEqual(touched(ops), ["item:revie-1111", "section:now", "section:next"])
        XCTAssertEqual(moves(ops).map { $0.key }, ["item:revie-1111"], "its neighbours do not move")
        XCTAssertEqual(updates(ops).filter { $0.key == "item:revie-1111" }.count, 1)
        let item = try XCTUnwrap(updates(ops).first(where: { $0.key == "item:revie-1111" })?.item)
        XCTAssertEqual(item.sectionId, "next")
        XCTAssertEqual(item.sectionTitle, "Next")
        assertIndexesPointAtTheNewRows(ops, new: new)
    }

    func testReorderCasesMoveOnlyTheRowsThatChangedOrder() {
        let table: [(name: String, old: [String], new: [String], moved: [String])] = [
            ("first to last", ["a", "b", "c", "d"], ["b", "c", "d", "a"], ["a"]),
            ("last to first", ["a", "b", "c", "d"], ["d", "a", "b", "c"], ["d"]),
            ("middle to end", ["a", "b", "c", "d", "e"], ["a", "c", "d", "e", "b"], ["b"]),
            ("middle to front", ["a", "b", "c", "d", "e"], ["c", "a", "b", "d", "e"], ["c"]),
            ("insert and remove only", ["a", "b", "c"], ["a", "x", "c"], []),
            ("insert at both ends", ["a", "b"], ["x", "a", "b", "y"], []),
            ("remove from both ends", ["a", "b", "c", "d"], ["b", "c"], []),
            ("moved while a neighbour is removed", ["a", "b", "c", "d"], ["b", "d", "a"], ["a"]),
        ]
        for row in table {
            let old = proseRows(row.old)
            let new = proseRows(row.new)
            let ops = TrackerDiff.ops(from: old, to: new)
            XCTAssertEqual(moves(ops).map { $0.key }.sorted(), row.moved.sorted(), row.name)
            XCTAssertTrue(updates(ops).isEmpty, "\(row.name): the rows' content did not change")
            assertIndexesPointAtTheNewRows(ops, new: new)
        }
    }

    // MARK: Synthetic inserts, removes and updates

    func testSyntheticInsertRemoveAndUpdateAreKeyed() {
        let old = [prose("a", "one"), prose("b", "two"), prose("c", "three")]
        let new = [prose("a", "one"), prose("b", "TWO"), prose("d", "four")]
        let ops = TrackerDiff.ops(from: old, to: new)
        XCTAssertEqual(removes(ops), ["c"])
        XCTAssertEqual(inserts(ops).map { $0.row.key }, ["d"])
        XCTAssertEqual(inserts(ops).map { $0.at }, [2])
        XCTAssertEqual(updates(ops), [prose("b", "TWO")])
        XCTAssertTrue(moves(ops).isEmpty)
    }

    func testRemovesComeBeforeInserts() {
        let old = proseRows(["a", "b", "c"])
        let new = proseRows(["x", "b", "y"])
        let ops = TrackerDiff.ops(from: old, to: new)
        let lastRemove = ops.lastIndex(where: { if case .remove = $0 { return true } else { return false } })
        let firstInsert = ops.firstIndex(where: { if case .insert = $0 { return true } else { return false } })
        XCTAssertNotNil(lastRemove)
        XCTAssertNotNil(firstInsert)
        if let lastRemove, let firstInsert {
            XCTAssertLessThan(lastRemove, firstInsert)
        }
    }

    func testEverythingNewIsInsertedAndEverythingGoneIsRemoved() {
        let rows = proseRows(["a", "b"])
        let fromNothing = TrackerDiff.ops(from: [], to: rows)
        XCTAssertEqual(inserts(fromNothing).map { $0.row.key }, ["a", "b"])
        XCTAssertEqual(inserts(fromNothing).map { $0.at }, [0, 1])
        let toNothing = TrackerDiff.ops(from: rows, to: [])
        XCTAssertEqual(removes(toNothing), ["a", "b"])
    }

    // MARK: Clock ticks

    func testALaterNowThatCrossesAMinuteBoundaryIsOnlyTimeUpdates() throws {
        let board = try TFx.golden()
        let old = rows(board, now: Date(timeIntervalSince1970: 1_760_548_000))
        let new = rows(board, now: Date(timeIntervalSince1970: 1_760_548_000 + 120))
        let ops = TrackerDiff.ops(from: old, to: new)
        XCTAssertFalse(ops.isEmpty, "items updated minutes ago read differently two minutes later")
        XCTAssertTrue(touched(ops).contains("item:audit-3183"), "4 m becomes 6 m")
        XCTAssertEqual(updates(ops).count, ops.count, "a tick only updates rows in place")
        for row in updates(ops) {
            let previous = try XCTUnwrap(old.first(where: { $0.key == row.key }), row.key)
            XCTAssertTrue(row.differsOnlyInTime(from: previous), "\(row.key) changed more than its time")
        }
        let tick = try XCTUnwrap(updates(ops).first(where: { $0.key == "item:audit-3183" })?.item)
        XCTAssertEqual(tick.relativeTime, "6 m")
    }

    func testAStatusChangeIsNotJustTime() throws {
        let old = rows(try TFx.golden())
        let new = rows(try TFx.edited { try $0.setStatus("revie-1111", "blocked") })
        let before = try XCTUnwrap(old.first(where: { $0.key == "item:revie-1111" }))
        let after = try XCTUnwrap(new.first(where: { $0.key == "item:revie-1111" }))
        XCTAssertFalse(after.differsOnlyInTime(from: before))
    }

    func testAStatusChangeTogetherWithATickIsNotJustTime() throws {
        let old = rows(try TFx.golden(), now: Date(timeIntervalSince1970: 1_760_548_000))
        let new = rows(try TFx.edited { try $0.setStatus("audit-3183", "blocked") },
                       now: Date(timeIntervalSince1970: 1_760_548_000 + 120))
        let before = try XCTUnwrap(old.first(where: { $0.key == "item:audit-3183" }))
        let after = try XCTUnwrap(new.first(where: { $0.key == "item:audit-3183" }))
        XCTAssertNotEqual(before.item?.relativeTime, after.item?.relativeTime, "the tick happened too")
        XCTAssertFalse(after.differsOnlyInTime(from: before))
    }

    func testTheAgentTouchingAnItemIsNotJustTime() throws {
        let old = rows(try TFx.golden())
        let new = rows(try TFx.edited { try $0.setUpdatedAt("audit-3183", epoch: 1_760_547_990) })
        let before = try XCTUnwrap(old.first(where: { $0.key == "item:audit-3183" }))
        let after = try XCTUnwrap(new.first(where: { $0.key == "item:audit-3183" }))
        XCTAssertNotEqual(before, after)
        XCTAssertFalse(after.differsOnlyInTime(from: before))
    }

    func testIdenticalRowsDifferInNothingNotEvenTime() throws {
        let all = rows(try TFx.golden())
        let item = try XCTUnwrap(all.first(where: { TFx.kind(of: $0) == .item }))
        XCTAssertFalse(item.differsOnlyInTime(from: item))
    }

    func testDifferentRowsAreNeverJustATick() throws {
        let all = rows(try TFx.golden())
        let items = all.filter { TFx.kind(of: $0) == .item }
        XCTAssertGreaterThan(items.count, 1)
        XCTAssertFalse(items[0].differsOnlyInTime(from: items[1]), "different keys")
        let section = try XCTUnwrap(all.first(where: { TFx.kind(of: $0) == .section }))
        XCTAssertFalse(section.differsOnlyInTime(from: section), "only item rows tick")
    }
}
