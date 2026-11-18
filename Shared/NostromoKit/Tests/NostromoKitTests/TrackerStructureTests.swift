// NostromoKit — TrackerStructureTests.swift
//
// T3b2: add, move and remove from the tracker pane (the pure half).
//
// - The add row: where the "+ Add item" row sits for each filter, that it is keyed `add:<section id>`, that it
//   is the same row whatever the section holds (so adding an item never rebuilds the row whose field is open).
// - `TrackerMoves`: where Move Up / Down / to a section, Undo and a drop land, given only the rows the view shows.
// - `TrackerDeferral`'s `exempt` rows: the user's own move or removal applies at once even on screen, the agent's
//   on-screen move of an item still waits, and moving one row past another does not make the other look moved.
//
// Boards come from `TrackerFixtures` (TrackerPresentationTests.swift): the 60-item golden board, edited as JSON and
// decoded by the real wire decoder. Pure: nothing reads the clock, a pasteboard or UserDefaults.
//
// What the tests are meant to catch, for whoever mutates the implementation to check them:
//  - Emit the add row under Waiting or Done, or under a banner: the placement tests fail.
//  - Put the add row after the Done group, or before the last open item: the order tests fail.
//  - Put the section's item count or last item id into the add row: the "never rebuilds" tests fail.
//  - Let a stub, a `moving:` copy or an expanded done item count as a neighbour: the neighbour tests fail.
//  - Make `drop` answer for the Done group, the dragged item itself or the slot it already sits in: the nil cases fail.
//  - Ignore `exempt` (or apply it to the agent's moves too): the exempt / still-held pairs fail.
//  - Ignore `editSupported` in the presenter: the read-only add-row tests fail.
//  - Let an exempt row that an agent also finished skip the done hold: the exempt-and-done tests fail.
//  - Put an item back beside a neighbour that is gone, moved or in another section, or prefer the one below: the place-hint tests fail.

import XCTest
@testable import NostromoKit

private typealias TFx = TrackerFixtures

private let nowIds = ["check-1000", "verif-1037", "retry-1074", "revie-1111", "draft-1148",
                      "close-1185", "repro-1222", "triag-1259", "docum-1296", "backf-1333"]
private let nextIds = ["rotat-1370", "audit-1407", "check-1444", "verif-1481", "retry-1518",
                       "revie-1555", "draft-1592", "close-1629", "repro-1666", "triag-1703"]
/// Findings holds open and done items interleaved: this is the open ones, in order.
private let findingsOpenIds = ["repro-2554", "docum-2628", "rotat-2702", "check-2776", "retry-2850"]
private let findingsDoneIds = ["triag-2591", "backf-2665", "audit-2739", "verif-2813", "revie-2887"]
private let allSectionIds = ["now", "next", "waiting-on-you", "done", "findings", "loose-ends"]
private let allSectionTitles = ["Now", "Next", "Waiting on you", "Done", "Findings", "Loose ends"]

private func dest(_ section: String, before: String? = nil, after: String? = nil) -> TrackerMoveDestination {
    TrackerMoveDestination(section: section, before: before, after: after)
}

private func rows(_ filter: TrackerFilter = .all, folds: TrackerFoldState = TrackerFoldState(),
                  file: StaticString = #filePath) throws -> [TrackerRow] {
    TFx.present(try TFx.golden(file: file), filter: filter, folds: folds).rows
}

private func index(_ key: String, _ rows: [TrackerRow]) -> Int? { TFx.rowIndex(key, in: rows) }

// MARK: - The add row

final class TrackerAddRowTests: XCTestCase {

    func testEverySectionEndsWithItsOwnAddRowUnderAll() throws {
        let r = try rows(.all)
        XCTAssertEqual(TFx.keys(TFx.rows(r, ofKind: .addItem)), allSectionIds.map { "add:\($0)" },
                       "one add row per section, in section order, keyed add:<section id>")
        var seen: [(id: String, title: String, label: String)] = []
        for row in r {
            guard case .addItem(let add) = row.content else { continue }
            XCTAssertEqual(row.key, TrackerRow.addKey(add.sectionId), "the key names the section")
            seen.append((add.sectionId, add.sectionTitle, add.accessibilityLabel))
        }
        XCTAssertEqual(seen.map { $0.id }, allSectionIds)
        XCTAssertEqual(seen.map { $0.title }, allSectionTitles)
        XCTAssertEqual(seen.map { $0.label }, allSectionTitles.map { "Add item to \($0)" },
                       "VoiceOver hears which section the row adds to")
        XCTAssertEqual(TrackerAddRow.label, "+ Add item")
        XCTAssertEqual(TrackerRow.addKey("now"), "add:now")
    }

    func testTheAddRowSitsAfterTheSectionsOpenItemsAndBeforeItsDoneGroup() throws {
        let r = try rows(.all)
        // Findings: open and done items interleaved in the file; the add row follows the last open one and the
        // Done group follows the add row.
        let lastOpen = try XCTUnwrap(index("item:\(findingsOpenIds.last ?? "")", r))
        let add = try XCTUnwrap(index("add:findings", r))
        let group = try XCTUnwrap(index("done:findings", r))
        XCTAssertEqual(add, lastOpen + 1, "the add row directly follows the last open item")
        XCTAssertEqual(group, add + 1, "the Done group comes after the add row, not before it")
        XCTAssertEqual(r[group + 1].key, "section:loose-ends", "and the group ends the section")

        // Next ends with prose after its items (the golden board's note); the add row still ends the section.
        let nextAdd = try XCTUnwrap(index("add:next", r))
        let lastNext = try XCTUnwrap(index("item:\(nextIds.last ?? "")", r))
        XCTAssertGreaterThan(nextAdd, lastNext, "after every open item of Next")
        XCTAssertEqual(r[nextAdd + 1].key, "section:waiting-on-you", "the add row is the last row of Next")

        // The first section's items all precede its add row.
        let nowAdd = try XCTUnwrap(index("add:now", r))
        for id in nowIds {
            let item = try XCTUnwrap(index("item:\(id)", r))
            XCTAssertLessThan(item, nowAdd, "\(id) is above Now's add row")
        }
        XCTAssertEqual(r[nowAdd + 1].key, "section:next")
    }

    func testAnAllDoneSectionStillEndsWithAnAddRowBeforeItsDoneGroup() throws {
        let r = try rows(.all)
        let start = try XCTUnwrap(index("section:done", r))
        let end = try XCTUnwrap(index("section:findings", r))
        XCTAssertEqual(TFx.keys(Array(r[start..<end])), ["section:done", "add:done", "done:done"])
    }

    func testTheLastSectionsAddRowComesBeforeTheLog() throws {
        let r = try rows(.all)
        let keys = TFx.keys(r)
        XCTAssertEqual(Array(keys.suffix(2)), ["add:loose-ends", "log"])
    }

    func testOpenShowsAnAddRowUnderEverySectionItShowsAndNoneUnderTheDroppedOne() throws {
        let r = try rows(.open)
        XCTAssertEqual(TFx.keys(TFx.rows(r, ofKind: .addItem)),
                       ["now", "next", "waiting-on-you", "findings", "loose-ends"].map { "add:\($0)" },
                       "the all-done Done section is not shown under Open, so it has no add row")
        XCTAssertNil(index("add:done", r))
        let findingsAdd = try XCTUnwrap(index("add:findings", r))
        for id in findingsOpenIds {
            let item = try XCTUnwrap(index("item:\(id)", r))
            XCTAssertLessThan(item, findingsAdd, "\(id) is above Findings' add row")
        }
        XCTAssertEqual(r[findingsAdd + 1].key, "section:loose-ends",
                       "under Open nothing (no Done group) sits between the add row and the next section")
    }

    func testWaitingAndDoneShowNoAddRow() throws {
        for filter in [TrackerFilter.waiting, .done] {
            XCTAssertTrue(TFx.rows(try rows(filter), ofKind: .addItem).isEmpty, "\(filter) never offers adding")
        }
    }

    func testABoardWithABannerHasNoAddRowUnderAllOrOpen() throws {
        let banners: [TFx.Obj] = [["type": "missing"],
                                  ["type": "unreadable", "line": 12, "reason": "duplicate_id"]]
        for banner in banners {
            let board = try TFx.edited { $0.setBanner(banner) }
            for filter in [TrackerFilter.all, .open] {
                let r = TFx.present(board, filter: filter).rows
                XCTAssertTrue(TFx.rows(r, ofKind: .addItem).isEmpty,
                              "\(filter) with banner \(banner): nothing can be added to a board that cannot be read")
                XCTAssertGreaterThan(TFx.items(r).count, 0, "the rows themselves are still shown")
            }
        }
    }

    func testAddRowsDoNotChangeCountsTheStripOrKeyUniqueness() throws {
        let board = try TFx.golden()
        let p = TFx.present(board)
        XCTAssertEqual(TFx.sections(p.rows).map(\.count), [10, 10, 10, 12, 10, 8], "the counts are items, not rows")
        XCTAssertEqual(p.strip.count, 10)
        XCTAssertFalse(p.strip.entries.contains { $0.key.hasPrefix("add:") })
        for filter in TrackerFilter.allCases {
            let keys = TFx.keys(TFx.present(board, filter: filter).rows)
            XCTAssertEqual(keys.count, Set(keys).count, "\(filter): keys stay unique with add rows")
        }
    }

    func testTheAddRowIsIdenticalWhateverItsSectionHoldsSoAddingAnItemNeverRebuildsIt() throws {
        let before = try rows(.all)
        let afterAdd = TFx.present(try TFx.edited { try $0.insertItem(id: "brand-0001", section: "next") }).rows
        let afterRemove = TFx.present(try TFx.edited { try $0.removeItem("audit-1407") }).rows
        let afterEmptyFill = TFx.present(try TFx.edited { try $0.insertItem(id: "brand-0002", section: "done") }).rows
        for sectionId in allSectionIds {
            let key = TrackerRow.addKey(sectionId)
            let original = try XCTUnwrap(before.first { $0.key == key })
            for (name, other) in [("an item added", afterAdd), ("an item removed", afterRemove), ("an item added to an all-done section", afterEmptyFill)] {
                XCTAssertEqual(other.first { $0.key == key }, original, "\(key) is the same row after \(name)")
            }
        }
        for (name, other) in [("added", afterAdd), ("removed", afterRemove), ("added to Done", afterEmptyFill)] {
            let touched = TrackerDiff.ops(from: before, to: other).map(\.key).filter { $0.hasPrefix("add:") }
            XCTAssertTrue(touched.isEmpty, "an item \(name): the diff leaves every add row alone, touched \(touched)")
        }
    }

    func testAnItemMovedBetweenSectionsLeavesBothAddRowsAlone() throws {
        let before = try rows(.all)
        let after = TFx.present(try TFx.edited { try $0.moveItem("revie-1111", toSection: "next") }).rows
        let touched = TrackerDiff.ops(from: before, to: after).map(\.key).filter { $0.hasPrefix("add:") }
        XCTAssertTrue(touched.isEmpty, "touched \(touched)")
    }

    // MARK: A daemon that does not take pane edits gets no add row

    private func present(_ filter: TrackerFilter, editSupported: Bool) throws -> [TrackerRow] {
        TrackerPresenter.present(board: try TFx.golden(), now: TFx.now, filter: filter, timeZone: TFx.utc,
                                 editSupported: editSupported).rows
    }

    func testWithoutEditSupportThereIsNoAddRowUnderAllOrOpenAndWithItThereIs() throws {
        for filter in [TrackerFilter.all, .open] {
            let readOnly = try present(filter, editSupported: false)
            XCTAssertTrue(TFx.rows(readOnly, ofKind: .addItem).isEmpty, "\(filter): an older daemon gets no half-working control")
            XCTAssertTrue(readOnly.allSatisfy { !$0.key.hasPrefix("add:") }, "\(filter): and no add key either")
            let editable = try present(filter, editSupported: true)
            XCTAssertEqual(TFx.rows(editable, ofKind: .addItem).count, filter == .all ? 6 : 5, "\(filter): with edit support it has them")
        }
    }

    func testTheReadOnlyBoardIsTheEditableBoardMinusItsAddRows() throws {
        for filter in TrackerFilter.allCases {
            let readOnly = try present(filter, editSupported: false)
            let editable = try present(filter, editSupported: true).filter { $0.key.hasPrefix("add:") == false }
            XCTAssertEqual(readOnly, editable, "\(filter): edit support adds the add rows and changes nothing else")
        }
    }
}

// MARK: - Where a move goes

final class TrackerMovesTests: XCTestCase {

    // MARK: Up and down

    func testUpGoesBeforeTheItemAboveAndIsNilOnTheFirstItem() throws {
        let r = try rows(.all)
        XCTAssertEqual(TrackerMoves.up("verif-1037", rows: r, filter: .all), dest("now", before: "check-1000"))
        XCTAssertEqual(TrackerMoves.up("backf-1333", rows: r, filter: .all), dest("now", before: "docum-1296"))
        XCTAssertNil(TrackerMoves.up("check-1000", rows: r, filter: .all), "nothing above the first item of a section")
        XCTAssertNil(TrackerMoves.up("rotat-1370", rows: r, filter: .all),
                     "the first item of Next has nothing above it: the last of Now is another section")
    }

    func testDownGoesAfterTheItemBelowAndIsNilOnTheLastItem() throws {
        let r = try rows(.all)
        XCTAssertEqual(TrackerMoves.down("verif-1037", rows: r, filter: .all), dest("now", after: "retry-1074"))
        XCTAssertEqual(TrackerMoves.down("close-1185", rows: r, filter: .all), dest("now", after: "repro-1222"))
        XCTAssertNil(TrackerMoves.down("backf-1333", rows: r, filter: .all), "nothing below the last item of a section")
        XCTAssertNil(TrackerMoves.down("triag-1703", rows: r, filter: .all))
    }

    func testUpAndDownAreNilForAnItemTheViewDoesNotList() throws {
        let r = try rows(.all)
        XCTAssertNil(TrackerMoves.up("nobody-0000", rows: r, filter: .all))
        XCTAssertNil(TrackerMoves.down("nobody-0000", rows: r, filter: .all))
        XCTAssertNil(TrackerMoves.up("triag-2591", rows: r, filter: .all), "a folded done item is not listed under All")
        XCTAssertNil(TrackerMoves.down("triag-2591", rows: r, filter: .all))
    }

    func testNeighboursAreTheOpenItemsTheViewShowsNeverTheDoneOnesBetweenThem() throws {
        // Findings holds done items between its open ones in the file; they are folded away under All.
        for filter in [TrackerFilter.all, .open] {
            let r = try rows(filter)
            XCTAssertEqual(TrackerMoves.up("docum-2628", rows: r, filter: filter), dest("findings", before: "repro-2554"), "\(filter)")
            XCTAssertEqual(TrackerMoves.down("repro-2554", rows: r, filter: filter), dest("findings", after: "docum-2628"), "\(filter)")
            XCTAssertEqual(TrackerMoves.down("check-2776", rows: r, filter: filter), dest("findings", after: "retry-2850"), "\(filter)")
            XCTAssertNil(TrackerMoves.down("retry-2850", rows: r, filter: filter), "\(filter): the last open item")
        }
    }

    func testAnExpandedDoneGroupsItemsAreNotNeighbours() throws {
        let folds = TrackerFoldState(expandedDoneGroups: ["findings"])
        let r = try rows(.all, folds: folds)
        XCTAssertNotNil(index("item:triag-2591", r), "setup: the done item is a row now")
        XCTAssertNil(TrackerMoves.down("retry-2850", rows: r, filter: .all), "the open items still end at retry-2850")
        XCTAssertEqual(TrackerMoves.lastItem(in: "findings", rows: r, filter: .all), "retry-2850")
        XCTAssertNil(TrackerMoves.up("triag-2591", rows: r, filter: .all))
        XCTAssertNil(TrackerMoves.drop("verif-1037", over: "item:triag-2591", lowerHalf: false, rows: r, filter: .all),
                     "a done item shown under the Done group is not a place to drop")
    }

    func testUnderDoneEveryShownItemIsANeighbour() throws {
        let r = try rows(.done)
        XCTAssertEqual(TrackerMoves.up("triag-2591", rows: r, filter: .done), nil, "the first done item of Findings")
        XCTAssertEqual(TrackerMoves.down("triag-2591", rows: r, filter: .done), dest("findings", after: "backf-2665"))
        XCTAssertEqual(TrackerMoves.up("backf-2665", rows: r, filter: .done), dest("findings", before: "triag-2591"))
        XCTAssertEqual(TrackerMoves.lastItem(in: "findings", rows: r, filter: .done), "revie-2887")
    }

    func testStubsAndMovingCopiesAreNeverNeighbours() throws {
        // An agent moves an on-screen item to Next: its old place shows a stub and Next shows a `moving:` copy.
        let before = TFx.present(try TFx.golden())
        let target = TFx.present(try TFx.edited { try $0.moveItem("revie-1111", toSection: "next") })
        var deferral = TrackerDeferral()
        let result = deferral.resolve(displayed: before.rows, target: target, visibleKeys: ["item:revie-1111"], selectedKey: nil)
        XCTAssertEqual(result.held.map(\.kind), [.moved], "setup: the move is held as a stub")
        XCTAssertNotNil(index("moving:revie-1111", result.rows), "setup: Next shows the live copy")
        let shown = result.rows

        XCTAssertEqual(TrackerMoves.up("draft-1148", rows: shown, filter: .all), dest("now", before: "retry-1074"),
                       "the stub between them is skipped")
        XCTAssertEqual(TrackerMoves.down("retry-1074", rows: shown, filter: .all), dest("now", after: "draft-1148"))
        XCTAssertNil(TrackerMoves.up("rotat-1370", rows: shown, filter: .all), "the moving: copy above it is no neighbour")
        XCTAssertEqual(TrackerMoves.origin(of: "draft-1148", rows: shown, filter: .all, fallbackSection: "now"),
                       dest("now", after: "retry-1074"))
        XCTAssertNil(TrackerMoves.drop("verif-1037", over: "moving:revie-1111", lowerHalf: false, rows: shown, filter: .all),
                     "not a place to drop")
        XCTAssertNil(TrackerMoves.drop("verif-1037", over: "item:revie-1111", lowerHalf: false, rows: shown, filter: .all),
                     "a stub is not a place to drop")
    }

    // MARK: Sections

    func testToSectionIsTheEndOfThatSection() {
        XCTAssertEqual(TrackerMoves.toSection("next"), dest("next"))
        XCTAssertNil(TrackerMoves.toSection("next").before)
        XCTAssertNil(TrackerMoves.toSection("next").after)
    }

    func testOtherSectionsAreEverySectionTheViewShowsExceptTheItemsOwn() throws {
        let all = TrackerMoves.otherSections(of: "revie-1111", rows: try rows(.all), filter: .all)
        XCTAssertEqual(all.map { $0.id }, ["next", "waiting-on-you", "done", "findings", "loose-ends"])
        XCTAssertEqual(all.map { $0.title }, ["Next", "Waiting on you", "Done", "Findings", "Loose ends"])
        let open = TrackerMoves.otherSections(of: "revie-1111", rows: try rows(.open), filter: .open)
        XCTAssertEqual(open.map { $0.id }, ["next", "waiting-on-you", "findings", "loose-ends"],
                       "the all-done section is not shown under Open, so it is not offered")
        let waiting = TrackerMoves.otherSections(of: "docum-1740", rows: try rows(.waiting), filter: .waiting)
        XCTAssertTrue(waiting.isEmpty, "only one section is shown, and it is the item's own")
        XCTAssertEqual(TrackerMoves.otherSections(of: "nobody-0000", rows: try rows(.all), filter: .all).count, 6,
                       "an item the view does not list is in no section: every section is offered")
    }

    // MARK: Origin and last item

    func testOriginIsAfterTheItemAboveElseBeforeTheItemBelowElseTheSectionsEnd() throws {
        let r = try rows(.all)
        XCTAssertEqual(TrackerMoves.origin(of: "draft-1148", rows: r, filter: .all, fallbackSection: "now"),
                       dest("now", after: "revie-1111"))
        XCTAssertEqual(TrackerMoves.origin(of: "check-1000", rows: r, filter: .all, fallbackSection: "now"),
                       dest("now", before: "verif-1037"), "the first item goes back before the one that was second")
        XCTAssertEqual(TrackerMoves.origin(of: "backf-1333", rows: r, filter: .all, fallbackSection: "now"),
                       dest("now", after: "docum-1296"))

        // The only open item of its section: the end of the section.
        let alone = TFx.present(try TFx.edited { edit in
            for id in nextIds.dropFirst() { try edit.removeItem(id) }
        }).rows
        XCTAssertEqual(TrackerMoves.origin(of: "rotat-1370", rows: alone, filter: .all, fallbackSection: "next"), dest("next"))
    }

    func testOriginOfAnItemTheViewDoesNotListIsTheFallbackSectionsEnd() throws {
        let r = try rows(.all)
        XCTAssertEqual(TrackerMoves.origin(of: "triag-2591", rows: r, filter: .all, fallbackSection: "findings"), dest("findings"))
        XCTAssertEqual(TrackerMoves.origin(of: "nobody-0000", rows: r, filter: .all, fallbackSection: "now"), dest("now"))
    }

    func testLastItemIsTheLastOpenItemTheViewShowsInTheSection() throws {
        let r = try rows(.all)
        XCTAssertEqual(TrackerMoves.lastItem(in: "now", rows: r, filter: .all), "backf-1333")
        XCTAssertEqual(TrackerMoves.lastItem(in: "next", rows: r, filter: .all), "triag-1703")
        XCTAssertEqual(TrackerMoves.lastItem(in: "findings", rows: r, filter: .all), "retry-2850",
                       "the file's last Findings item is a done one: a new item goes after the last open one")
        XCTAssertNil(TrackerMoves.lastItem(in: "done", rows: r, filter: .all), "an all-done section has no open item")
        XCTAssertNil(TrackerMoves.lastItem(in: "nowhere", rows: r, filter: .all))
    }

    // MARK: Drops

    func testDroppingBetweenTwoItemsLandsAfterTheUpperOneWithTheLineAtTheSeam() throws {
        let r = try rows(.all)
        let upperHalfOfLower = try XCTUnwrap(TrackerMoves.drop("verif-1037", over: "item:draft-1148", lowerHalf: false, rows: r, filter: .all))
        XCTAssertEqual(upperHalfOfLower.destination, dest("now", after: "revie-1111"))
        XCTAssertEqual(upperHalfOfLower.indicator, .above(rowKey: "item:draft-1148"))
        let lowerHalfOfUpper = try XCTUnwrap(TrackerMoves.drop("verif-1037", over: "item:revie-1111", lowerHalf: true, rows: r, filter: .all))
        XCTAssertEqual(lowerHalfOfUpper.destination, dest("now", after: "revie-1111"),
                       "the same seam from the other side: the same place")
        XCTAssertEqual(lowerHalfOfUpper.indicator, .below(rowKey: "item:revie-1111"))
    }

    func testDroppingOnTheFirstItemsUpperHalfGoesBeforeIt() throws {
        let r = try rows(.all)
        let drop = try XCTUnwrap(TrackerMoves.drop("verif-1037", over: "item:check-1000", lowerHalf: false, rows: r, filter: .all))
        XCTAssertEqual(drop.destination, dest("now", before: "check-1000"))
        XCTAssertEqual(drop.indicator, .above(rowKey: "item:check-1000"))
        let other = try XCTUnwrap(TrackerMoves.drop("rotat-1370", over: "item:check-1000", lowerHalf: false, rows: r, filter: .all))
        XCTAssertEqual(other.destination, dest("now", before: "check-1000"), "from another section too")
    }

    func testDroppingOnTheLastItemsLowerHalfGoesAfterIt() throws {
        let r = try rows(.all)
        let drop = try XCTUnwrap(TrackerMoves.drop("verif-1037", over: "item:backf-1333", lowerHalf: true, rows: r, filter: .all))
        XCTAssertEqual(drop.destination, dest("now", after: "backf-1333"))
        XCTAssertEqual(drop.indicator, .below(rowKey: "item:backf-1333"))
    }

    func testDroppingInAnotherSectionLandsBesideTheRowUnderThePointer() throws {
        let r = try rows(.all)
        let between = try XCTUnwrap(TrackerMoves.drop("verif-1037", over: "item:audit-1407", lowerHalf: true, rows: r, filter: .all))
        XCTAssertEqual(between.destination, dest("next", after: "audit-1407"))
        let top = try XCTUnwrap(TrackerMoves.drop("verif-1037", over: "item:rotat-1370", lowerHalf: false, rows: r, filter: .all))
        XCTAssertEqual(top.destination, dest("next", before: "rotat-1370"))
        XCTAssertEqual(top.indicator, .above(rowKey: "item:rotat-1370"))
    }

    func testDroppingOnAHeadingOrAnAddRowIsTheEndOfThatSectionWithTheLineAboveItsAddRow() throws {
        let r = try rows(.all)
        for key in ["section:next", "add:next"] {
            let drop = try XCTUnwrap(TrackerMoves.drop("verif-1037", over: key, lowerHalf: false, rows: r, filter: .all), key)
            XCTAssertEqual(drop.destination, dest("next"), "\(key): the end of Next's open items")
            XCTAssertEqual(drop.indicator, .above(rowKey: "add:next"), "\(key): the line sits on top of the add row")
            let lower = try XCTUnwrap(TrackerMoves.drop("verif-1037", over: key, lowerHalf: true, rows: r, filter: .all), key)
            XCTAssertEqual(lower.destination, dest("next"), "\(key): either half of the row means the same place")
        }
        // An all-done section has no open item: the heading still takes a drop and the item goes in alone.
        let intoDone = try XCTUnwrap(TrackerMoves.drop("verif-1037", over: "section:done", lowerHalf: false, rows: r, filter: .all))
        XCTAssertEqual(intoDone.destination, dest("done"))
        XCTAssertEqual(intoDone.indicator, .above(rowKey: "add:done"))
    }

    func testWithoutAnAddRowTheLineGoesUnderTheLastItemOrTheHeading() throws {
        let waiting = try rows(.waiting)
        let intoWaiting = try XCTUnwrap(TrackerMoves.drop("verif-1037", over: "section:waiting-on-you", lowerHalf: false,
                                                          rows: waiting, filter: .waiting))
        XCTAssertEqual(intoWaiting.destination, dest("waiting-on-you"))
        XCTAssertEqual(intoWaiting.indicator, .below(rowKey: "item:close-2073"), "no add row under Waiting: under the last item")

        // An empty section under All has its add row; with the add row gone (a banner) and no item, the heading.
        let bannerBoard = try TFx.edited { edit in
            edit.setBanner(["type": "missing"])
            for id in nextIds { try edit.removeItem(id) }
        }
        let bare = TFx.present(bannerBoard, filter: .all).rows
        let intoEmpty = try XCTUnwrap(TrackerMoves.drop("verif-1037", over: "section:next", lowerHalf: false, rows: bare, filter: .all))
        XCTAssertEqual(intoEmpty.indicator, .below(rowKey: "section:next"))
    }

    func testDroppingOnTheEndOfTheSectionTheItemIsAlreadyLastInIsNil() throws {
        let r = try rows(.all)
        XCTAssertNil(TrackerMoves.drop("backf-1333", over: "section:now", lowerHalf: false, rows: r, filter: .all))
        XCTAssertNil(TrackerMoves.drop("backf-1333", over: "add:now", lowerHalf: true, rows: r, filter: .all))
        XCTAssertNil(TrackerMoves.drop("backf-1333", over: "item:backf-1333", lowerHalf: true, rows: r, filter: .all))
    }

    func testDroppingOnTheDoneGroupProseTheLogOrAnUnknownRowIsNil() throws {
        let r = try rows(.all)
        XCTAssertNil(TrackerMoves.drop("verif-1037", over: "done:findings", lowerHalf: false, rows: r, filter: .all))
        XCTAssertNil(TrackerMoves.drop("verif-1037", over: "done:findings", lowerHalf: true, rows: r, filter: .all))
        XCTAssertNil(TrackerMoves.drop("verif-1037", over: "done:done", lowerHalf: true, rows: r, filter: .all))
        XCTAssertNil(TrackerMoves.drop("verif-1037", over: "log", lowerHalf: false, rows: r, filter: .all))
        for row in TFx.rows(r, ofKind: .prose) {
            XCTAssertNil(TrackerMoves.drop("verif-1037", over: row.key, lowerHalf: false, rows: r, filter: .all), row.key)
        }
        XCTAssertNil(TrackerMoves.drop("verif-1037", over: "item:nobody-0000", lowerHalf: false, rows: r, filter: .all))
    }

    func testDroppingOnItselfOrIntoTheSlotItAlreadyHasIsNil() throws {
        let r = try rows(.all)
        for lower in [false, true] {
            XCTAssertNil(TrackerMoves.drop("verif-1037", over: "item:verif-1037", lowerHalf: lower, rows: r, filter: .all),
                         "onto itself (lower half \(lower))")
        }
        XCTAssertNil(TrackerMoves.drop("verif-1037", over: "item:check-1000", lowerHalf: true, rows: r, filter: .all),
                     "the seam under the item above it is where it already is")
        XCTAssertNil(TrackerMoves.drop("verif-1037", over: "item:retry-1074", lowerHalf: false, rows: r, filter: .all),
                     "the seam above the item below it is where it already is")
        XCTAssertNil(TrackerMoves.drop("check-1000", over: "item:verif-1037", lowerHalf: false, rows: r, filter: .all),
                     "the first item dropped just above the second is where it already is")
        XCTAssertNotNil(TrackerMoves.drop("verif-1037", over: "item:check-1000", lowerHalf: false, rows: r, filter: .all),
                        "control: the seam above the first item is a real move")
        XCTAssertNotNil(TrackerMoves.drop("verif-1037", over: "item:retry-1074", lowerHalf: true, rows: r, filter: .all),
                        "control: the seam under the item below it is a real move")
    }

    func testUnderAFilterTheNeighboursAreTheVisibleRows() throws {
        // Under Open, Findings shows its five open items; the file's done items between them are not rows.
        let open = try rows(.open)
        let before = try XCTUnwrap(TrackerMoves.drop("revie-1111", over: "item:docum-2628", lowerHalf: false, rows: open, filter: .open))
        XCTAssertEqual(before.destination, dest("findings", after: "repro-2554"), "after the visible item above, not a hidden done one")
        XCTAssertEqual(before.indicator, .above(rowKey: "item:docum-2628"))

        // Under Done, the shown done items are the neighbours.
        let done = try rows(.done)
        let drop = try XCTUnwrap(TrackerMoves.drop("triag-2591", over: "item:revie-2887", lowerHalf: true, rows: done, filter: .done))
        XCTAssertEqual(drop.destination, dest("findings", after: "revie-2887"))
        XCTAssertEqual(drop.indicator, .below(rowKey: "item:revie-2887"))
        let toTop = try XCTUnwrap(TrackerMoves.drop("revie-2887", over: "item:triag-2591", lowerHalf: false, rows: done, filter: .done))
        XCTAssertEqual(toTop.destination, dest("findings", before: "triag-2591"))
    }

    func testEveryDropTheViewOffersNamesRowsThatAreThereAndNeverTheDraggedItemItself() throws {
        let board = try TFx.golden()
        let dragged = "verif-1037"
        let expanded = TrackerFoldState(expandedDoneGroups: ["done", "findings"])
        var offered = 0
        for filter in TrackerFilter.allCases {
            for folds in [TrackerFoldState(), expanded] {
                let r = TFx.present(board, filter: filter, folds: folds).rows
                let keys = Set(r.map(\.key))
                let sectionIds = Set(TFx.sections(r).map(\.id))
                for row in r {
                    for lower in [false, true] {
                        guard let drop = TrackerMoves.drop(dragged, over: row.key, lowerHalf: lower, rows: r, filter: filter) else { continue }
                        offered += 1
                        let d = drop.destination
                        let message = "\(filter) over \(row.key) lower \(lower)"
                        XCTAssertTrue(sectionIds.contains(d.section), "\(message): the section is one the view shows")
                        XCTAssertFalse(d.before != nil && d.after != nil, "\(message): before and after are never both named")
                        XCTAssertNotEqual(d.before, dragged, "\(message): never relative to itself")
                        XCTAssertNotEqual(d.after, dragged, "\(message): never relative to itself")
                        for neighbour in [d.before, d.after].compactMap({ $0 }) {
                            XCTAssertTrue(keys.contains("item:\(neighbour)"), "\(message): \(neighbour) is a row")
                        }
                        switch drop.indicator {
                        case .above(let key), .below(let key):
                            XCTAssertTrue(keys.contains(key), "\(message): the line sits on a row that is shown (\(key))")
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(offered, 100, "the property was checked over real drops")
    }

    func testTheMoveAndRestoreOpsCarryTheDestination() {
        let destination = dest("next", before: nil, after: "audit-1407")
        XCTAssertEqual(destination.moveOp("verif-1037"),
                       .move(id: "verif-1037", section: "next", before: nil, after: "audit-1407"))
        XCTAssertEqual(destination.restoreOp(source: "- [ ] x\n"),
                       .restore(source: "- [ ] x\n", section: "next", before: nil, after: "audit-1407"))
        XCTAssertEqual(dest("now", before: "check-1000").moveOp("a"),
                       .move(id: "a", section: "now", before: "check-1000", after: nil))
        XCTAssertEqual(dest("now").moveOp("a"), .move(id: "a", section: "now", before: nil, after: nil))
    }
}

// MARK: - The user's own change applies at once

final class TrackerDeferralExemptTests: XCTestCase {

    private func everyKey(_ rows: [TrackerRow]) -> Set<String> { Set(rows.map(\.key)) }

    func testAnAgentsReorderOfAnOnScreenItemStillWaits() throws {
        let before = TFx.present(try TFx.golden())
        let target = TFx.present(try TFx.edited { try $0.moveItem("rotat-1370", after: "triag-1703") })
        var deferral = TrackerDeferral()
        let result = deferral.resolve(displayed: before.rows, target: target, visibleKeys: everyKey(before.rows), heldKeys: [])
        XCTAssertEqual(result.held.map(\.kind), [.keptInPlace], "no exemption: the move is held")
        XCTAssertEqual(result.held.map(\.key), ["item:rotat-1370"])
        XCTAssertNotEqual(result.rows.map(\.key), target.rows.map(\.key), "the reader's view did not reorder")
    }

    func testAnExemptOnScreenReorderAppliesNow() throws {
        let before = TFx.present(try TFx.golden())
        let target = TFx.present(try TFx.edited { try $0.moveItem("rotat-1370", after: "triag-1703") })
        var deferral = TrackerDeferral()
        let result = deferral.resolve(displayed: before.rows, target: target, visibleKeys: everyKey(before.rows),
                                      heldKeys: [], exempt: ["item:rotat-1370"])
        XCTAssertTrue(result.held.isEmpty, "the user asked for this move: nothing is held")
        XCTAssertEqual(result.rows, target.rows, "the pane shows the new order at once")
        XCTAssertTrue(result.stubs.isEmpty)
        XCTAssertFalse(deferral.hasHeld)
    }

    func testMovingOneRowPastAnotherDoesNotMakeTheOtherLookMoved() throws {
        // The user moves audit-1407 above rotat-1370. As a list diff it is rotat-1370 that "moved": without the
        // exemption leaving the user's own row out of the comparison, the agent would be blamed for that row.
        let before = TFx.present(try TFx.golden())
        let target = TFx.present(try TFx.edited { try $0.moveItem("audit-1407", before: "rotat-1370") })
        var control = TrackerDeferral()
        let held = control.resolve(displayed: before.rows, target: target, visibleKeys: everyKey(before.rows), heldKeys: [])
        XCTAssertEqual(held.held.map(\.kind), [.keptInPlace], "control: with no exemption a neighbour is held")

        var deferral = TrackerDeferral()
        let result = deferral.resolve(displayed: before.rows, target: target, visibleKeys: everyKey(before.rows),
                                      heldKeys: [], exempt: ["item:audit-1407"])
        XCTAssertTrue(result.held.isEmpty, "the other row is not held for a move the user made: \(result.held.map(\.key))")
        XCTAssertEqual(result.rows, target.rows)
    }

    func testAnExemptOnScreenMoveToAnotherSectionLeavesNoStubAndNoMovingCopy() throws {
        let before = TFx.present(try TFx.golden())
        let target = TFx.present(try TFx.edited { try $0.moveItem("revie-1111", toSection: "next") })
        let key = "item:revie-1111"
        var control = TrackerDeferral()
        let held = control.resolve(displayed: before.rows, target: target, visibleKeys: [key], heldKeys: [])
        XCTAssertEqual(held.held.map(\.kind), [.moved], "control: an agent's move leaves a stub")

        var deferral = TrackerDeferral()
        let result = deferral.resolve(displayed: before.rows, target: target, visibleKeys: [key], heldKeys: [], exempt: [key])
        XCTAssertTrue(result.held.isEmpty)
        XCTAssertTrue(result.stubs.isEmpty, "no 'moved to Next' stub for a move the user just made")
        XCTAssertFalse(result.rows.contains { $0.key.hasPrefix(TrackerDeferral.movingPrefix) })
        XCTAssertEqual(result.rows, target.rows)
        XCTAssertEqual(result.rows.first { $0.key == key }?.item?.sectionId, "next")
    }

    func testAnExemptOnScreenRemovalLeavesNoRemovedStub() throws {
        let before = TFx.present(try TFx.golden())
        let target = TFx.present(try TFx.edited { try $0.removeItem("backf-1333") })
        let key = "item:backf-1333"
        var control = TrackerDeferral()
        let held = control.resolve(displayed: before.rows, target: target, visibleKeys: [key], heldKeys: [])
        XCTAssertEqual(held.held.map(\.kind), [.removed], "control: an agent's removal leaves a stub")

        var deferral = TrackerDeferral()
        let result = deferral.resolve(displayed: before.rows, target: target, visibleKeys: [key], heldKeys: [], exempt: [key])
        XCTAssertTrue(result.held.isEmpty)
        XCTAssertTrue(result.stubs.isEmpty)
        XCTAssertNil(index(key, result.rows), "the row goes at once")
        XCTAssertEqual(result.rows, target.rows)
    }

    func testTheExemptionIsForTheNamedRowsOnly() throws {
        // In one board the user removed backf-1333 (exempt) and the agent moved audit-1407 and finished verif-1037.
        let before = TFx.present(try TFx.golden())
        let target = TFx.present(try TFx.edited { edit in
            try edit.removeItem("backf-1333")
            try edit.moveItem("audit-1407", toSection: "findings")
            try edit.setStatus("verif-1037", "done")
        })
        var deferral = TrackerDeferral()
        let result = deferral.resolve(displayed: before.rows, target: target, visibleKeys: everyKey(before.rows),
                                      heldKeys: [], exempt: ["item:backf-1333"])
        XCTAssertEqual(Set(result.held.map(\.key)), ["item:audit-1407", "item:verif-1037"],
                       "the agent's changes wait; the user's does not")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: result.held.map { ($0.key, $0.kind) }),
                       ["item:audit-1407": .moved, "item:verif-1037": .doneInPlace])
        XCTAssertNil(index("item:backf-1333", result.rows), "the exempt removal applied")
    }

    func testAnExemptRowOffScreenIsJustAppliedLikeAnyOtherOffScreenChange() throws {
        let before = TFx.present(try TFx.golden())
        let target = TFx.present(try TFx.edited { try $0.removeItem("backf-1333") })
        var deferral = TrackerDeferral()
        let result = deferral.resolve(displayed: before.rows, target: target, visibleKeys: [], heldKeys: [],
                                      exempt: ["item:backf-1333"])
        XCTAssertEqual(result.rows, target.rows)
        XCTAssertTrue(result.held.isEmpty)
    }

    func testATextSelectionStillKeepsItsRowEvenWhenTheRowIsExempt() throws {
        let before = TFx.present(try TFx.golden())
        let target = TFx.present(try TFx.edited { try $0.removeItem("verif-1037") })
        let key = "item:verif-1037"
        var deferral = TrackerDeferral()
        let result = deferral.resolve(displayed: before.rows, target: target, visibleKeys: [key], heldKeys: [key], exempt: [key])
        XCTAssertEqual(result.held.map(\.kind), [.selection], "the selected text is never taken out from under the reader")
        XCTAssertNotNil(index(key, result.rows))
    }

    func testWithNoExemptionTheDeferralBehavesAsBefore() throws {
        let before = TFx.present(try TFx.golden())
        let target = TFx.present(try TFx.edited { edit in
            try edit.setStatus("verif-1037", "done")
            try edit.moveItem("revie-1111", toSection: "next")
            try edit.removeItem("backf-1333")
        })
        let visible = everyKey(before.rows)
        var legacy = TrackerDeferral()
        let old = legacy.resolve(displayed: before.rows, target: target, visibleKeys: visible, selectedKey: nil)
        var explicit = TrackerDeferral()
        let new = explicit.resolve(displayed: before.rows, target: target, visibleKeys: visible, heldKeys: [], exempt: [])
        XCTAssertEqual(old, new)
        XCTAssertEqual(new.held.map(\.kind), [.doneInPlace, .moved, .removed])
    }

    // MARK: An agent's tick beats the exemption

    func testAnExemptMoveOfAnItemTheAgentAlsoFinishedStaysWhereTheReaderSeesItStruckThrough() throws {
        let before = TFx.present(try TFx.golden())
        let key = "item:verif-1037"
        let target = TFx.present(try TFx.edited { edit in
            try edit.moveItem("verif-1037", after: "retry-1074")   // the user's own move (exempt) ...
            try edit.setStatus("verif-1037", "done")                // ... and an agent ticked it meanwhile
        })
        var control = TrackerDeferral()
        let plain = control.resolve(displayed: before.rows, target: target, visibleKeys: [key], heldKeys: [])
        XCTAssertEqual(plain.held.map(\.kind), [.doneInPlace], "control: with no exemption an agent's tick is held in place")

        var deferral = TrackerDeferral()
        let result = deferral.resolve(displayed: before.rows, target: target, visibleKeys: [key], heldKeys: [], exempt: [key])
        XCTAssertEqual(result.held.map(\.kind), [.doneInPlace], "a done item is held even when its row was exempt: \(result.held.map(\.key))")
        XCTAssertEqual(result.held.map(\.key), [key])
        let row = try XCTUnwrap(result.rows.first { $0.key == key }, "the row stays on screen where the reader had it")
        XCTAssertEqual(row.item?.isDone, true, "struck through, as every done fold does")
        XCTAssertEqual(index(key, result.rows), index(key, before.rows), "and it has not jumped")
    }

    func testAnExemptRowTheAgentFinishedIsHeldWhetherDoneItemsFoldAwayOrAreHiddenByTheFilter() throws {
        let before = TFx.present(try TFx.golden(), filter: .open)
        let key = "item:verif-1037"
        let target = TFx.present(try TFx.edited { try $0.setStatus("verif-1037", "done") }, filter: .open)
        XCTAssertNil(index(key, target.rows), "setup: under Open a done item is not a row of the target")
        var deferral = TrackerDeferral()
        let result = deferral.resolve(displayed: before.rows, target: target, visibleKeys: [key], heldKeys: [], exempt: [key])
        XCTAssertEqual(result.held.map(\.kind), [.doneInPlace])
        XCTAssertNotNil(index(key, result.rows))

        // Off screen the same change just applies, exemption or not.
        var offScreen = TrackerDeferral()
        let applied = offScreen.resolve(displayed: before.rows, target: target, visibleKeys: [], heldKeys: [], exempt: [key])
        XCTAssertTrue(applied.held.isEmpty)
        XCTAssertEqual(applied.rows, target.rows)
    }

    func testAnExemptMoveOrRemovalOfAnItemNobodyFinishedStillAppliesAtOnceNextToAFinishedOne() throws {
        let before = TFx.present(try TFx.golden())
        let target = TFx.present(try TFx.edited { edit in
            try edit.moveItem("rotat-1370", after: "triag-1703")    // the user's move
            try edit.removeItem("backf-1333")                        // the user's removal
            try edit.setStatus("verif-1037", "done")                 // an agent's tick (not exempt)
        })
        var deferral = TrackerDeferral()
        let result = deferral.resolve(displayed: before.rows, target: target, visibleKeys: everyKey(before.rows), heldKeys: [],
                                      exempt: ["item:rotat-1370", "item:backf-1333"])
        XCTAssertEqual(result.held.map(\.key), ["item:verif-1037"], "only the agent's tick waits")
        XCTAssertNil(index("item:backf-1333", result.rows), "the user's removal applied")
        let order = TFx.keys(result.rows).filter { $0.hasPrefix("item:") && nextIds.contains(String($0.dropFirst(5))) }
        XCTAssertEqual(order.last, "item:rotat-1370", "the user's move applied: it is last in Next")
    }

    func testOnceTheExemptionEndsTheAgentsNextMoveOfThatRowWaitsAgain() throws {
        // First push: the user's own move (exempt) applies. Second push, no exemption: the agent moves the same
        // on-screen item again and that one is held.
        let start = TFx.present(try TFx.golden())
        let ownMove = TFx.present(try TFx.edited { try $0.moveItem("rotat-1370", after: "triag-1703") })
        var deferral = TrackerDeferral()
        let first = deferral.resolve(displayed: start.rows, target: ownMove, visibleKeys: everyKey(start.rows),
                                     heldKeys: [], exempt: ["item:rotat-1370"])
        XCTAssertEqual(first.rows, ownMove.rows)

        let agentMove = TFx.present(try TFx.edited { edit in
            try edit.moveItem("rotat-1370", after: "triag-1703")
            try edit.moveItem("rotat-1370", before: "audit-1407")
        })
        let second = deferral.resolve(displayed: first.rows, target: agentMove, visibleKeys: everyKey(first.rows), heldKeys: [])
        XCTAssertFalse(second.held.isEmpty, "the same item moved by the agent is deferred again")
        XCTAssertNotEqual(second.rows.map(\.key), agentMove.rows.map(\.key))
    }
}

// MARK: - Where an undo puts an item back (worked out against the board as it is then)

final class TrackerPlaceHintTests: XCTestCase {

    private func hint(_ section: String, above: String? = nil, below: String? = nil) -> TrackerPlaceHint {
        TrackerPlaceHint(section: section, above: above, below: below)
    }

    // MARK: hint(of:)

    func testTheHintNamesTheSectionAndBothOpenNeighboursTheViewShows() throws {
        let r = try rows(.all)
        XCTAssertEqual(TrackerMoves.hint(of: "verif-1037", rows: r, filter: .all, fallbackSection: "now"),
                       hint("now", above: "check-1000", below: "retry-1074"))
        XCTAssertEqual(TrackerMoves.hint(of: "check-1000", rows: r, filter: .all, fallbackSection: "now"),
                       hint("now", above: nil, below: "verif-1037"), "nothing above the first item")
        XCTAssertEqual(TrackerMoves.hint(of: "backf-1333", rows: r, filter: .all, fallbackSection: "now"),
                       hint("now", above: "docum-1296", below: nil), "nothing below the last item")
        XCTAssertEqual(TrackerMoves.hint(of: "rotat-1370", rows: r, filter: .all, fallbackSection: "next"),
                       hint("next", above: nil, below: "audit-1407"),
                       "the last item of Now is another section's: not a neighbour")
    }

    func testTheHintSkipsDoneItemsLikeEveryOtherNeighbourAndNamesTheSectionOfTheItem() throws {
        let r = try rows(.all)
        // Findings interleaves open and done items; only open ones are neighbours.
        XCTAssertEqual(TrackerMoves.hint(of: "docum-2628", rows: r, filter: .all, fallbackSection: "findings"),
                       hint("findings", above: "repro-2554", below: "rotat-2702"))
    }

    func testTheHintOfAnItemTheViewDoesNotListIsJustTheFallbackSection() throws {
        let r = try rows(.all)
        XCTAssertEqual(TrackerMoves.hint(of: "triag-2591", rows: r, filter: .all, fallbackSection: "findings"), hint("findings"),
                       "a folded done item has no neighbours to name")
        XCTAssertEqual(TrackerMoves.hint(of: "nobody-0000", rows: r, filter: .all, fallbackSection: "now"), hint("now"))
    }

    func testAHintMadeFromAMoveDestinationIsAfterAndBeforeAsAboveAndBelow() {
        XCTAssertEqual(TrackerPlaceHint(dest("now", after: "check-1000")), hint("now", above: "check-1000"))
        XCTAssertEqual(TrackerPlaceHint(dest("now", before: "retry-1074")), hint("now", below: "retry-1074"))
        XCTAssertEqual(TrackerPlaceHint(dest("next")), hint("next"))
    }

    // MARK: place(_:)

    func testAnAboveNeighbourThatIsStillThereMeansAfterIt() throws {
        let r = try rows(.all)
        XCTAssertEqual(TrackerMoves.place(hint("now", above: "check-1000", below: "retry-1074"), rows: r, filter: .all),
                       dest("now", after: "check-1000"), "the item above wins when both are there")
        XCTAssertEqual(TrackerMoves.place(hint("now", above: "check-1000"), rows: r, filter: .all), dest("now", after: "check-1000"))
    }

    func testWhenTheAboveNeighbourIsGoneThePlaceIsBeforeTheBelowOne() throws {
        let r = TFx.present(try TFx.edited { try $0.removeItem("check-1000") }).rows
        XCTAssertEqual(TrackerMoves.place(hint("now", above: "check-1000", below: "verif-1037"), rows: r, filter: .all),
                       dest("now", before: "verif-1037"), "never an id that is gone")
    }

    func testWhenTheBelowNeighbourIsGoneAndTheAboveIsToo() throws {
        let r = TFx.present(try TFx.edited { edit in
            try edit.removeItem("check-1000")
            try edit.removeItem("verif-1037")
        }).rows
        XCTAssertEqual(TrackerMoves.place(hint("now", above: "check-1000", below: "verif-1037"), rows: r, filter: .all),
                       dest("now"), "both gone: the end of the section's open items")
        XCTAssertEqual(TrackerMoves.place(hint("now"), rows: r, filter: .all), dest("now"), "no neighbours at all: the end too")
    }

    func testAnAboveNeighbourThatMovedToAnotherSectionIsSkipped() throws {
        let r = TFx.present(try TFx.edited { try $0.moveItem("check-1000", toSection: "next") }).rows
        XCTAssertEqual(TrackerMoves.place(hint("now", above: "check-1000", below: "verif-1037"), rows: r, filter: .all),
                       dest("now", before: "verif-1037"), "it is no longer in Now's rows")
        let both = TFx.present(try TFx.edited { edit in
            try edit.moveItem("check-1000", toSection: "next")
            try edit.moveItem("verif-1037", toSection: "next")
        }).rows
        XCTAssertEqual(TrackerMoves.place(hint("now", above: "check-1000", below: "verif-1037"), rows: both, filter: .all), dest("now"))
    }

    func testANeighbourTheDaemonsBoardHasInAnotherSectionIsSkippedEvenIfTheViewStillShowsItHere() throws {
        // The rows on screen may hold a change back: the row is here, the daemon has it elsewhere.
        let r = try rows(.all)
        let gone: (String, String) -> Bool = { id, _ in id != "check-1000" }
        XCTAssertEqual(TrackerMoves.place(hint("now", above: "check-1000", below: "verif-1037"), rows: r, filter: .all, isInSection: gone),
                       dest("now", before: "verif-1037"))
        let neither: (String, String) -> Bool = { _, _ in false }
        XCTAssertEqual(TrackerMoves.place(hint("now", above: "check-1000", below: "verif-1037"), rows: r, filter: .all, isInSection: neither),
                       dest("now"))
        var asked: [String] = []
        _ = TrackerMoves.place(hint("now", above: "check-1000", below: "verif-1037"), rows: r, filter: .all) { id, section in
            asked.append("\(id)@\(section)")
            return true
        }
        XCTAssertTrue(asked.allSatisfy { $0.hasSuffix("@now") }, "the question is about the hint's own section: \(asked)")
    }

    func testADoneOrFoldedNeighbourIsNotAPlaceToPutAnItemNextTo() throws {
        let r = try rows(.all)
        XCTAssertEqual(TrackerMoves.place(hint("findings", above: "triag-2591", below: "docum-2628"), rows: r, filter: .all),
                       dest("findings", before: "docum-2628"), "triag-2591 is a done item the view folds away")
    }

    func testASectionTheViewDoesNotShowMeansThatSectionsEnd() throws {
        let waiting = try rows(.waiting)
        XCTAssertEqual(TrackerMoves.place(hint("now", above: "check-1000", below: "verif-1037"), rows: waiting, filter: .waiting),
                       dest("now"), "no rows of Now under this filter")
        let r = try rows(.all)
        XCTAssertEqual(TrackerMoves.place(hint("nowhere", above: "check-1000"), rows: r, filter: .all), dest("nowhere"))
    }

    func testTheNeighbourMustBeInTheHintsSectionNotJustOnTheBoard() throws {
        let r = try rows(.all)
        XCTAssertEqual(TrackerMoves.place(hint("next", above: "check-1000", below: "audit-1407"), rows: r, filter: .all),
                       dest("next", before: "audit-1407"), "check-1000 is in Now: not a place in Next")
    }
}
