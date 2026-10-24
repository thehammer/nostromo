// NostromoKit — TrackerDeferralTests.swift
//
// The deferred fold / move / remove rule (T1, design contract §9; PRD 18 and 21): text never
// vanishes from under the reader. `displayed` is what the previous presentation put on screen,
// `target` is what the board now says, `visibleKeys` are the rows intersecting the viewport and
// `selectedKey` the row holding a text selection.
//
// - an on-screen item that becomes done stays where it is (struck through) until it leaves the
//   viewport, the pane is reopened (`releaseAll`) or the user clicks its Done group (`releaseDone`);
// - an on-screen item moved to another section shows in its new section at once under
//   `moving:<id>` while a "moved to <Section>" stub keeps its old key and place;
// - an on-screen removed item leaves a "removed" stub in its place;
// - a selected row keeps its content, whatever else changes.
//
// Fixtures and board edits come from `TrackerFixtures` (TrackerPresentationTests.swift).

import XCTest
@testable import NostromoKit

private typealias TFx = TrackerFixtures

final class TrackerDeferralTests: XCTestCase {

    // MARK: Helpers

    private typealias Scenario = (before: TrackerPresentation, target: TrackerPresentation)

    /// The golden board as first shown, and what it becomes after `change`.
    private func scenario(filter: TrackerFilter = .all,
                          _ change: (inout TFx.Edit) throws -> Void) throws -> Scenario {
        let before = TFx.present(try TFx.golden(), filter: filter)
        let target = TFx.present(try TFx.edited(change), filter: filter)
        return (before, target)
    }

    private func keys(_ rows: [TrackerRow]) -> [String] {
        rows.map { $0.key }
    }

    private func everyKey(_ rows: [TrackerRow]) -> Set<String> {
        Set(rows.map { $0.key })
    }

    private func assertUniqueKeys(_ rows: [TrackerRow], _ message: String = "",
                                  file: StaticString = #filePath, line: UInt = #line) {
        let all = keys(rows)
        XCTAssertEqual(all.count, Set(all).count, "row keys are unique \(message)", file: file, line: line)
    }

    private func stub(in row: TrackerRow) -> TrackerStubRow? {
        if case .stub(let stub) = row.content { return stub }
        return nil
    }

    // MARK: An on-screen item set to done

    func testAnOnScreenItemSetToDoneStaysAtItsIndexAsADoneItemRow() throws {
        let s = try scenario { try $0.setStatus("verif-1037", "done") }
        let key = "item:verif-1037"
        XCTAssertNotNil(s.target.foldedItems["verif-1037"], "the board folds it")
        let oldIndex = try XCTUnwrap(TFx.rowIndex(key, in: s.before.rows))

        var deferral = TrackerDeferral()
        let result = deferral.resolve(displayed: s.before.rows, target: s.target, visibleKeys: [key], selectedKey: nil)

        XCTAssertEqual(result.held.map { $0.key }, [key])
        XCTAssertEqual(result.held.map { $0.kind }, [.doneInPlace])
        XCTAssertEqual(result.rows[oldIndex].key, key, "still at its index")
        guard case .item(let shown) = result.rows[oldIndex].content else { return XCTFail("still an item row") }
        XCTAssertEqual(shown.status, .done)
        XCTAssertEqual(shown.mark, "✓")
        XCTAssertEqual(shown.text, "Verify webhook retries")
        XCTAssertEqual(result.stubs.count, 1)
        XCTAssertTrue(deferral.hasHeld)
        XCTAssertEqual(deferral.held, result.held)
        assertUniqueKeys(result.rows)
    }

    func testRowsOtherThanTheHeldOneFollowTheTargetImmediately() throws {
        let s = try scenario { edit in
            try edit.setStatus("verif-1037", "done")
            try edit.setStatus("revie-1111", "blocked")
        }
        var deferral = TrackerDeferral()
        let result = deferral.resolve(displayed: s.before.rows, target: s.target,
                                      visibleKeys: everyKey(s.before.rows), selectedKey: nil)
        XCTAssertEqual(result.held.map { $0.key }, ["item:verif-1037"])
        let other = try XCTUnwrap(result.rows.first(where: { $0.key == "item:revie-1111" }))
        XCTAssertEqual(other.item?.status, .blocked, "an update that needs no hold applies now")
        XCTAssertTrue(result.applyNow.contains(where: { $0.key == "item:revie-1111" }))
    }

    func testAHeldDoneItemFoldsOnTheNextResolveOnceItLeavesTheViewport() throws {
        let s = try scenario { try $0.setStatus("verif-1037", "done") }
        let key = "item:verif-1037"
        var deferral = TrackerDeferral()
        let first = deferral.resolve(displayed: s.before.rows, target: s.target, visibleKeys: [key], selectedKey: nil)

        let second = deferral.resolve(displayed: first.rows, target: s.target, visibleKeys: [], selectedKey: nil)
        XCTAssertEqual(second.rows, s.target.rows)
        XCTAssertTrue(second.held.isEmpty)
        XCTAssertFalse(deferral.hasHeld)
        XCTAssertTrue(second.applyNow.contains(.remove(key: key)), "the row leaves the display")
        XCTAssertNil(TFx.rowIndex(key, in: second.rows))
    }

    func testAHeldDoneItemStaysHeldWhileItIsStillOnScreen() throws {
        let s = try scenario { try $0.setStatus("verif-1037", "done") }
        let key = "item:verif-1037"
        var deferral = TrackerDeferral()
        let first = deferral.resolve(displayed: s.before.rows, target: s.target, visibleKeys: [key], selectedKey: nil)
        let second = deferral.resolve(displayed: first.rows, target: s.target, visibleKeys: [key], selectedKey: nil)
        XCTAssertEqual(second.rows, first.rows)
        XCTAssertTrue(second.applyNow.isEmpty, "nothing to do while it is on screen")
        XCTAssertEqual(second.held, first.held)
    }

    func testAnOffScreenItemSetToDoneFoldsAtOnceWithoutAHold() throws {
        let s = try scenario { try $0.setStatus("verif-1037", "done") }
        var deferral = TrackerDeferral()
        let result = deferral.resolve(displayed: s.before.rows, target: s.target,
                                      visibleKeys: ["section:now", "item:check-1000"], selectedKey: nil)
        XCTAssertEqual(result.rows, s.target.rows)
        XCTAssertTrue(result.held.isEmpty)
        XCTAssertTrue(result.stubs.isEmpty)
        XCTAssertFalse(deferral.hasHeld)
        XCTAssertNil(TFx.rowIndex("item:verif-1037", in: result.rows))
        XCTAssertTrue(result.applyNow.contains(.remove(key: "item:verif-1037")))
    }

    func testAnItemFinishedAndFiledUnderDoneInOneWriteIsHeldInPlaceToo() throws {
        let s = try scenario { edit in
            try edit.setStatus("verif-1037", "done")
            try edit.moveItem("verif-1037", toSection: "done")
        }
        let key = "item:verif-1037"
        let oldIndex = try XCTUnwrap(TFx.rowIndex(key, in: s.before.rows))
        var deferral = TrackerDeferral()
        let result = deferral.resolve(displayed: s.before.rows, target: s.target, visibleKeys: [key], selectedKey: nil)
        XCTAssertEqual(result.held.map { $0.kind }, [.doneInPlace])
        XCTAssertEqual(result.rows[oldIndex].key, key)
        XCTAssertEqual(result.rows[oldIndex].item?.status, .done)

        // Clicking the Done group it was filed under releases it.
        deferral.releaseDone(section: "done")
        let released = deferral.resolve(displayed: result.rows, target: s.target, visibleKeys: [key], selectedKey: nil)
        XCTAssertEqual(released.rows, s.target.rows)
    }

    // MARK: Release: Done group click and reopen

    func testClickingTheSectionsDoneGroupReleasesAnOnScreenDoneItemImmediately() throws {
        let s = try scenario { try $0.setStatus("verif-1037", "done") }
        let key = "item:verif-1037"
        var deferral = TrackerDeferral()
        deferral.releaseDone(section: "now")
        let result = deferral.resolve(displayed: s.before.rows, target: s.target, visibleKeys: [key], selectedKey: nil)
        XCTAssertTrue(result.held.isEmpty)
        XCTAssertEqual(result.rows, s.target.rows)
        XCTAssertFalse(deferral.hasHeld)
    }

    func testClickingAnotherSectionsDoneGroupDoesNotReleaseIt() throws {
        let s = try scenario { try $0.setStatus("verif-1037", "done") }
        let key = "item:verif-1037"
        var deferral = TrackerDeferral()
        deferral.releaseDone(section: "next")
        let result = deferral.resolve(displayed: s.before.rows, target: s.target, visibleKeys: [key], selectedKey: nil)
        XCTAssertEqual(result.held.map { $0.kind }, [.doneInPlace])
    }

    func testReleaseAllReleasesDoneMovedAndRemovedHoldsImmediately() throws {
        let s = try scenario { edit in
            try edit.setStatus("verif-1037", "done")
            try edit.moveItem("revie-1111", toSection: "next")
            try edit.removeItem("backf-1333")
        }
        let visible = everyKey(s.before.rows)

        var holding = TrackerDeferral()
        let held = holding.resolve(displayed: s.before.rows, target: s.target, visibleKeys: visible, selectedKey: nil)
        XCTAssertEqual(held.held.map { $0.kind }, [.doneInPlace, .moved, .removed], "in display order")
        XCTAssertEqual(held.held.map { $0.key }, ["item:verif-1037", "item:revie-1111", "item:backf-1333"])
        assertUniqueKeys(held.rows, "with three holds")

        var reopened = TrackerDeferral()
        reopened.releaseAll()
        let result = reopened.resolve(displayed: s.before.rows, target: s.target, visibleKeys: visible, selectedKey: nil)
        XCTAssertEqual(result.rows, s.target.rows)
        XCTAssertTrue(result.held.isEmpty)
        XCTAssertTrue(result.stubs.isEmpty)
        XCTAssertFalse(reopened.hasHeld)
    }

    func testReleaseAllIsOneShot() throws {
        let s = try scenario { try $0.setStatus("verif-1037", "done") }
        let key = "item:verif-1037"
        var deferral = TrackerDeferral()
        deferral.releaseAll()
        let once = deferral.resolve(displayed: s.before.rows, target: s.target, visibleKeys: [key], selectedKey: nil)
        XCTAssertTrue(once.held.isEmpty)

        let again = deferral.resolve(displayed: s.before.rows, target: s.target, visibleKeys: [key], selectedKey: nil)
        XCTAssertEqual(again.held.map { $0.kind }, [.doneInPlace], "a release is one-shot")
    }

    func testReleaseDoneIsOneShot() throws {
        let s = try scenario { try $0.setStatus("verif-1037", "done") }
        let key = "item:verif-1037"
        var deferral = TrackerDeferral()
        deferral.releaseDone(section: "now")
        _ = deferral.resolve(displayed: s.before.rows, target: s.target, visibleKeys: [key], selectedKey: nil)
        let again = deferral.resolve(displayed: s.before.rows, target: s.target, visibleKeys: [key], selectedKey: nil)
        XCTAssertEqual(again.held.map { $0.kind }, [.doneInPlace])
    }

    // MARK: An on-screen item moved to another section

    func testAnOnScreenItemMovedToAnotherSectionLeavesAStubAndAppearsInTheNewSectionAtOnce() throws {
        let s = try scenario { try $0.moveItem("revie-1111", toSection: "next") }
        let key = "item:revie-1111"
        let oldIndex = try XCTUnwrap(TFx.rowIndex(key, in: s.before.rows))

        var deferral = TrackerDeferral()
        let result = deferral.resolve(displayed: s.before.rows, target: s.target, visibleKeys: [key], selectedKey: nil)

        XCTAssertEqual(result.held.map { $0.kind }, [.moved])
        XCTAssertEqual(result.held.map { $0.key }, [key])

        // The old place keeps its key and says where the item went.
        XCTAssertEqual(result.rows[oldIndex].key, key)
        let stub = try XCTUnwrap(self.stub(in: result.rows[oldIndex]), "a stub holds the place")
        XCTAssertEqual(stub.text, "moved to Next")
        XCTAssertEqual(stub.kind, .movedTo(sectionTitle: "Next"))
        XCTAssertEqual(stub.item, s.before.rows[oldIndex].item, "the stub shows the item as it was last shown")
        XCTAssertEqual(result.stubs.map { $0.key }, [key])

        // The live item is already in its new section, under a temporary key.
        let movingKey = "moving:revie-1111"
        let nextHeading = try XCTUnwrap(TFx.rowIndex("section:next", in: result.rows))
        let waitingHeading = try XCTUnwrap(TFx.rowIndex("section:waiting-on-you", in: result.rows))
        let movingIndex = try XCTUnwrap(TFx.rowIndex(movingKey, in: result.rows))
        XCTAssertGreaterThan(movingIndex, nextHeading)
        XCTAssertLessThan(movingIndex, waitingHeading)
        let live = try XCTUnwrap(result.rows[movingIndex].item)
        XCTAssertEqual(live.id, "revie-1111")
        XCTAssertEqual(live.sectionId, "next")
        XCTAssertEqual(live.sectionTitle, "Next")

        // The old key names only the stub; the live copy has its own key.
        XCTAssertEqual(result.rows.filter { $0.key == key }.count, 1)
        assertUniqueKeys(result.rows)
        XCTAssertTrue(deferral.hasHeld)
    }

    func testAMovedItemsStubConvergesAndRenamesTheLiveRowOnceItsOldPlaceIsOffScreen() throws {
        let s = try scenario { try $0.moveItem("revie-1111", toSection: "next") }
        let key = "item:revie-1111"
        var deferral = TrackerDeferral()
        let first = deferral.resolve(displayed: s.before.rows, target: s.target, visibleKeys: [key], selectedKey: nil)

        let second = deferral.resolve(displayed: first.rows, target: s.target, visibleKeys: [], selectedKey: nil)
        XCTAssertEqual(second.rows, s.target.rows, "the display converges on the board")
        XCTAssertTrue(second.held.isEmpty)
        XCTAssertFalse(deferral.hasHeld)
        XCTAssertEqual(second.renamed, ["moving:revie-1111": "item:revie-1111"])
        XCTAssertNil(TFx.rowIndex("moving:revie-1111", in: second.rows))
        let landed = try XCTUnwrap(second.rows.first(where: { $0.key == key })?.item)
        XCTAssertEqual(landed.sectionId, "next", "the key is back, now in the new section")
    }

    func testAMovedItemsStubStaysWhileItsOldPlaceIsStillOnScreen() throws {
        let s = try scenario { try $0.moveItem("revie-1111", toSection: "next") }
        let key = "item:revie-1111"
        var deferral = TrackerDeferral()
        let first = deferral.resolve(displayed: s.before.rows, target: s.target, visibleKeys: [key], selectedKey: nil)
        let second = deferral.resolve(displayed: first.rows, target: s.target, visibleKeys: [key], selectedKey: nil)
        XCTAssertEqual(second.rows, first.rows)
        XCTAssertTrue(second.applyNow.isEmpty)
        XCTAssertTrue(second.renamed.isEmpty)
        XCTAssertEqual(second.held.map { $0.kind }, [.moved])
    }

    func testAnOffScreenItemMovedToAnotherSectionMovesAtOnceWithNoStub() throws {
        let s = try scenario { try $0.moveItem("revie-1111", toSection: "next") }
        var deferral = TrackerDeferral()
        let result = deferral.resolve(displayed: s.before.rows, target: s.target,
                                      visibleKeys: ["section:now"], selectedKey: nil)
        XCTAssertEqual(result.rows, s.target.rows)
        XCTAssertTrue(result.held.isEmpty)
        XCTAssertTrue(result.renamed.isEmpty)
        XCTAssertFalse(keys(result.rows).contains(where: { $0.hasPrefix("moving:") }))
    }

    // MARK: An on-screen removed item

    func testAnOnScreenRemovedItemLeavesARemovedStubInItsPlace() throws {
        let s = try scenario { try $0.removeItem("verif-1037") }
        let key = "item:verif-1037"
        let oldIndex = try XCTUnwrap(TFx.rowIndex(key, in: s.before.rows))
        var deferral = TrackerDeferral()
        let result = deferral.resolve(displayed: s.before.rows, target: s.target, visibleKeys: [key], selectedKey: nil)

        XCTAssertEqual(result.held.map { $0.kind }, [.removed])
        XCTAssertEqual(result.rows[oldIndex].key, key, "same key at the same index")
        let stub = try XCTUnwrap(self.stub(in: result.rows[oldIndex]))
        XCTAssertEqual(stub.text, "removed")
        XCTAssertEqual(stub.kind, .removed)
        XCTAssertEqual(stub.item.id, "verif-1037")
        XCTAssertEqual(result.stubs.map { $0.key }, [key])
        assertUniqueKeys(result.rows)
    }

    func testARemovedItemsStubGoesOnceItsPlaceIsOffScreen() throws {
        let s = try scenario { try $0.removeItem("verif-1037") }
        let key = "item:verif-1037"
        var deferral = TrackerDeferral()
        let first = deferral.resolve(displayed: s.before.rows, target: s.target, visibleKeys: [key], selectedKey: nil)

        let stillThere = deferral.resolve(displayed: first.rows, target: s.target, visibleKeys: [key], selectedKey: nil)
        XCTAssertEqual(stillThere.rows, first.rows)
        XCTAssertTrue(stillThere.applyNow.isEmpty)

        let gone = deferral.resolve(displayed: first.rows, target: s.target, visibleKeys: [], selectedKey: nil)
        XCTAssertEqual(gone.rows, s.target.rows)
        XCTAssertTrue(gone.held.isEmpty)
        XCTAssertTrue(gone.applyNow.contains(.remove(key: key)))
    }

    func testAnOffScreenRemovedItemIsRemovedAtOnce() throws {
        let s = try scenario { try $0.removeItem("verif-1037") }
        var deferral = TrackerDeferral()
        let result = deferral.resolve(displayed: s.before.rows, target: s.target,
                                      visibleKeys: ["item:check-1000"], selectedKey: nil)
        XCTAssertEqual(result.rows, s.target.rows)
        XCTAssertTrue(result.held.isEmpty)
        XCTAssertTrue(result.stubs.isEmpty)
    }

    // MARK: Selection

    func testASelectedItemsContentUpdateIsHeldWhileTenOthersApplyImmediately() throws {
        let nextIds = TFx.wireItems(try TFx.golden()).filter { $0.section == "next" }.map { $0.id }
        XCTAssertEqual(nextIds.count, 10)
        let s = try scenario { edit in
            try edit.setText("check-1000", "Check referral 4411 duplicate (edited by the agent)")
            for id in nextIds { try edit.setStatus(id, "in-progress") }
        }
        let selected = "item:check-1000"
        let beforeRow = try XCTUnwrap(s.before.rows.first(where: { $0.key == selected }))
        XCTAssertNotEqual(beforeRow, s.target.rows.first(where: { $0.key == selected }), "the board changed it")

        var deferral = TrackerDeferral()
        let result = deferral.resolve(displayed: s.before.rows, target: s.target,
                                      visibleKeys: everyKey(s.before.rows), selectedKey: selected)

        XCTAssertEqual(result.held.map { $0.kind }, [.selection])
        XCTAssertEqual(result.held.map { $0.key }, [selected])
        XCTAssertEqual(result.rows.first(where: { $0.key == selected }), beforeRow, "the selected row is unchanged")
        XCTAssertTrue(result.stubs.isEmpty, "a selection hold is not a stub")

        let applied = Set(result.applyNow.map { $0.key })
        for id in nextIds {
            XCTAssertTrue(applied.contains("item:\(id)"), "\(id) updates now")
            XCTAssertEqual(result.rows.first(where: { $0.key == "item:\(id)" })?.item?.status, .inProgress, id)
        }
        XCTAssertFalse(applied.contains(selected), "the selected key is never touched")
        for op in result.applyNow {
            if case .update = op { continue }
            XCTFail("only in-place updates were expected, got \(op)")
        }
    }

    func testTheHeldSelectionUpdateAppliesOnTheNextResolveAfterTheSelectionClears() throws {
        let s = try scenario { try $0.setText("check-1000", "Check referral 4411 duplicate (edited by the agent)") }
        let selected = "item:check-1000"
        let visible = everyKey(s.before.rows)
        var deferral = TrackerDeferral()
        let held = deferral.resolve(displayed: s.before.rows, target: s.target, visibleKeys: visible, selectedKey: selected)
        XCTAssertEqual(held.held.map { $0.kind }, [.selection])

        let stillSelected = deferral.resolve(displayed: held.rows, target: s.target, visibleKeys: visible,
                                             selectedKey: selected)
        XCTAssertEqual(stillSelected.rows, held.rows)
        XCTAssertTrue(stillSelected.applyNow.isEmpty)

        let cleared = deferral.resolve(displayed: held.rows, target: s.target, visibleKeys: visible, selectedKey: nil)
        XCTAssertEqual(cleared.rows, s.target.rows)
        XCTAssertTrue(cleared.held.isEmpty)
        XCTAssertFalse(deferral.hasHeld)
        let update = try XCTUnwrap(cleared.applyNow.first(where: { $0.key == selected }))
        guard case .update(let row) = update else { return XCTFail("the held change is an update") }
        XCTAssertEqual(row.item?.text, "Check referral 4411 duplicate (edited by the agent)")
    }

    func testASelectionIsHeldEvenWhenItsRowIsOffScreen() throws {
        let s = try scenario { try $0.setText("check-1000", "Check referral 4411 duplicate (edited by the agent)") }
        let selected = "item:check-1000"
        var deferral = TrackerDeferral()
        let result = deferral.resolve(displayed: s.before.rows, target: s.target, visibleKeys: [], selectedKey: selected)
        XCTAssertEqual(result.held.map { $0.kind }, [.selection])
        XCTAssertEqual(result.rows.first(where: { $0.key == selected }),
                       s.before.rows.first(where: { $0.key == selected }))
    }

    func testASelectedRowThatDidNotChangeHoldsNothing() throws {
        let s = try scenario { try $0.setStatus("revie-1111", "blocked") }
        var deferral = TrackerDeferral()
        let result = deferral.resolve(displayed: s.before.rows, target: s.target,
                                      visibleKeys: everyKey(s.before.rows), selectedKey: "item:check-1000")
        XCTAssertTrue(result.held.isEmpty)
        XCTAssertEqual(result.rows, s.target.rows)
    }

    // MARK: Nothing to hold

    func testNothingChangedMeansNothingToApplyAndNothingHeld() throws {
        let board = try TFx.golden()
        let displayed = TFx.present(board)
        let target = TFx.present(try TFx.golden())
        var deferral = TrackerDeferral()
        for selected in [nil, "item:check-1000"] as [String?] {
            let result = deferral.resolve(displayed: displayed.rows, target: target,
                                          visibleKeys: everyKey(displayed.rows), selectedKey: selected)
            XCTAssertTrue(result.applyNow.isEmpty)
            XCTAssertTrue(result.held.isEmpty)
            XCTAssertTrue(result.stubs.isEmpty)
            XCTAssertTrue(result.renamed.isEmpty)
            XCTAssertEqual(result.rows, displayed.rows)
        }
        XCTAssertFalse(deferral.hasHeld)
    }

    func testNothingVisibleMeansEveryChangeAppliesNow() throws {
        let s = try scenario { edit in
            try edit.setStatus("verif-1037", "done")
            try edit.moveItem("revie-1111", toSection: "next")
            try edit.removeItem("backf-1333")
            try edit.setStatus("rotat-1370", "blocked")
        }
        var deferral = TrackerDeferral()
        let result = deferral.resolve(displayed: s.before.rows, target: s.target, visibleKeys: [], selectedKey: nil)
        XCTAssertEqual(result.rows, s.target.rows)
        XCTAssertEqual(result.applyNow, TrackerDiff.ops(from: s.before.rows, to: s.target.rows))
        XCTAssertTrue(result.held.isEmpty)
        XCTAssertTrue(result.stubs.isEmpty)
        XCTAssertTrue(result.renamed.isEmpty)
        XCTAssertFalse(deferral.hasHeld)
    }

    func testChangesToRowsThatAreNotItemsAreNeverHeld() throws {
        let s = try scenario { $0.setLog((1...13).map { "Claudia: logged event \($0)" }) }
        var deferral = TrackerDeferral()
        let result = deferral.resolve(displayed: s.before.rows, target: s.target,
                                      visibleKeys: everyKey(s.before.rows), selectedKey: nil)
        XCTAssertTrue(result.held.isEmpty)
        XCTAssertEqual(result.rows, s.target.rows)
        XCTAssertEqual(Set(result.applyNow.map { $0.key }), ["log"])
    }

    func testSeveralHoldsAtOnceEachKeepTheirOwnPlace() throws {
        let s = try scenario { edit in
            try edit.setStatus("verif-1037", "done")
            try edit.moveItem("revie-1111", toSection: "next")
            try edit.removeItem("backf-1333")
        }
        let doneKey = "item:verif-1037", moveKey = "item:revie-1111", removeKey = "item:backf-1333"
        let indexes = try [doneKey, moveKey, removeKey].map { try XCTUnwrap(TFx.rowIndex($0, in: s.before.rows)) }
        var deferral = TrackerDeferral()
        let result = deferral.resolve(displayed: s.before.rows, target: s.target,
                                      visibleKeys: everyKey(s.before.rows), selectedKey: nil)
        XCTAssertEqual(result.held.count, 3)
        XCTAssertEqual(result.stubs.count, 3)
        XCTAssertEqual([doneKey, moveKey, removeKey].map { key in TFx.rowIndex(key, in: result.rows) },
                       indexes.map { Optional($0) })
        XCTAssertEqual(result.rows[indexes[0]].item?.status, .done)
        XCTAssertEqual(stub(in: result.rows[indexes[1]])?.text, "moved to Next")
        XCTAssertEqual(stub(in: result.rows[indexes[2]])?.text, "removed")
        assertUniqueKeys(result.rows)
    }
}

// MARK: - Moves within a section, open Done groups, selections that move (review edge cases)

final class TrackerDeferralInSectionTests: XCTestCase {

    private func index(_ key: String, _ rows: [TrackerRow]) -> Int? {
        rows.firstIndex { $0.key == key }
    }

    func testAnOnScreenItemMovedWithinItsSectionStaysWhereTheReaderIsUntilOffScreen() throws {
        let before = TFx.present(try TFx.golden())
        let target = TFx.present(try TFx.edited { try $0.moveItem("check-1000", after: "backf-1333") })
        let key = "item:check-1000"
        let oldIndex = try XCTUnwrap(index(key, before.rows))
        XCTAssertNotEqual(index(key, target.rows), oldIndex, "the board moved it")

        var deferral = TrackerDeferral()
        let held = deferral.resolve(displayed: before.rows, target: target, visibleKeys: [key], selectedKey: nil)
        XCTAssertEqual(held.held.map(\.kind), [.keptInPlace])
        XCTAssertEqual(index(key, held.rows), oldIndex, "still where the reader saw it")
        XCTAssertEqual(held.rows.filter { $0.key.hasSuffix("check-1000") }.count, 1, "shown once")
        XCTAssertFalse(held.applyNow.contains { if case .move = $0 { return true } else { return false } },
                       "nothing on screen moves")

        let released = deferral.resolve(displayed: held.rows, target: target, visibleKeys: [], selectedKey: nil)
        XCTAssertEqual(released.rows, target.rows)
    }

    func testAnOnScreenItemSetToDoneInsideAnOpenDoneGroupStaysInPlace() throws {
        let folds = TrackerFoldState(expandedDoneGroups: ["findings"])
        let before = TFx.present(try TFx.golden(), folds: folds)
        let target = TFx.present(try TFx.edited { try $0.setStatus("repro-2554", "done") }, folds: folds)
        let key = "item:repro-2554"
        let oldIndex = try XCTUnwrap(index(key, before.rows))

        var deferral = TrackerDeferral()
        let result = deferral.resolve(displayed: before.rows, target: target, visibleKeys: [key], selectedKey: nil)
        XCTAssertEqual(result.held.map(\.kind), [.doneInPlace])
        XCTAssertEqual(index(key, result.rows), oldIndex)
        XCTAssertEqual(result.rows[oldIndex].item?.status, .done, "struck through in place")
        guard case .doneGroup(let group)? = result.rows.first(where: { $0.key == "done:findings" })?.content else {
            return XCTFail("the Findings Done group is still shown")
        }
        XCTAssertFalse(group.itemIds.contains("repro-2554"), "not counted until it folds")
    }

    func testASelectedItemMovedToAnotherSectionKeepsItsPlaceAndContent() throws {
        let before = TFx.present(try TFx.golden())
        let target = TFx.present(try TFx.edited { try $0.moveItem("verif-1037", toSection: "next") })
        let key = "item:verif-1037"
        let oldIndex = try XCTUnwrap(index(key, before.rows))

        var deferral = TrackerDeferral()
        let result = deferral.resolve(displayed: before.rows, target: target, visibleKeys: [key], selectedKey: key)
        XCTAssertEqual(result.held.map(\.kind), [.selection])
        XCTAssertEqual(index(key, result.rows), oldIndex, "the selected row stays put")
        XCTAssertEqual(result.rows[oldIndex], before.rows[oldIndex], "with the content the selection is in")
        XCTAssertNotNil(index("moving:verif-1037", result.rows), "the live item shows in Next meanwhile")
        XCTAssertEqual(Set(result.rows.map(\.key)).count, result.rows.count)
    }

    func testReleasingEverythingKeepsTheSelectedRow() throws {
        let before = TFx.present(try TFx.golden())
        let target = TFx.present(try TFx.edited { try $0.setText("verif-1037", "Verify webhook retries again") })
        let key = "item:verif-1037"
        var deferral = TrackerDeferral()
        deferral.releaseAll()
        let result = deferral.resolve(displayed: before.rows, target: target, visibleKeys: [key], selectedKey: key)
        XCTAssertEqual(result.held.map(\.kind), [.selection])
        XCTAssertEqual(result.rows.first { $0.key == key }, before.rows.first { $0.key == key })
    }

    func testAHeldRowStaysUnderItsOwnSectionWhenTheRowAboveItMovesAway() throws {
        // Next's first item moves to Findings in the same write that removes Next's second (on screen).
        let before = TFx.present(try TFx.golden())
        let target = TFx.present(try TFx.edited { edit in
            try edit.moveItem("rotat-1370", toSection: "findings")
            try edit.removeItem("audit-1407")
        })
        var deferral = TrackerDeferral()
        let result = deferral.resolve(displayed: before.rows, target: target, visibleKeys: ["item:audit-1407"], selectedKey: nil)
        let stubIndex = try XCTUnwrap(index("item:audit-1407", result.rows))
        let heading = try XCTUnwrap(index("section:next", result.rows))
        let nextHeading = try XCTUnwrap(index("section:waiting-on-you", result.rows))
        XCTAssertTrue(heading < stubIndex && stubIndex < nextHeading, "the removed stub stays under Next")
    }
}
