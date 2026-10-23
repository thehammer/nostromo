// NostromoKit — ApprovalPagingTests.swift
//
// AP2b: `1 of 3`. Parallel requests for one focus page through one card, in arrival order.

import XCTest
@testable import NostromoKit

final class ApprovalPagingTests: XCTestCase {

    func testNoRequestsHasNoPage() {
        XCTAssertNil(ApprovalPaging.page(ids: [], current: nil))
        XCTAssertNil(ApprovalPaging.page(ids: [], current: "a"))
    }

    func testALoneRequestIsPageOneOfOneWithNoNeighbours() {
        let page = ApprovalPaging.page(ids: ["a"], current: "a")
        XCTAssertEqual(page, ApprovalPage(position: 1, count: 1, previousID: nil, nextID: nil, currentID: "a"))
        XCTAssertEqual(page?.label, "1 of 1")
    }

    func testTheFirstOfThreeHasNoPreviousAndTheSecondAsNext() {
        let page = ApprovalPaging.page(ids: ["a", "b", "c"], current: "a")
        XCTAssertEqual(page, ApprovalPage(position: 1, count: 3, previousID: nil, nextID: "b", currentID: "a"))
        XCTAssertEqual(page?.label, "1 of 3")
    }

    func testTheMiddleOfThreeHasBothNeighbours() {
        let page = ApprovalPaging.page(ids: ["a", "b", "c"], current: "b")
        XCTAssertEqual(page, ApprovalPage(position: 2, count: 3, previousID: "a", nextID: "c", currentID: "b"))
        XCTAssertEqual(page?.label, "2 of 3")
    }

    func testTheLastOfThreeHasNoNextAndDoesNotWrapToTheFirst() {
        let page = ApprovalPaging.page(ids: ["a", "b", "c"], current: "c")
        XCTAssertEqual(page, ApprovalPage(position: 3, count: 3, previousID: "b", nextID: nil, currentID: "c"))
        XCTAssertEqual(page?.label, "3 of 3")
    }

    func testNoCurrentShowsTheOldest() {
        let page = ApprovalPaging.page(ids: ["a", "b", "c"], current: nil)
        XCTAssertEqual(page?.currentID, "a")
        XCTAssertEqual(page?.position, 1)
    }

    func testACurrentThatIsNoLongerHeldShowsTheOldest() {
        let page = ApprovalPaging.page(ids: ["b", "c"], current: "gone")
        XCTAssertEqual(page, ApprovalPage(position: 1, count: 2, previousID: nil, nextID: "c", currentID: "b"))
    }

    func testArrivalOrderIsTheOrderGivenNotAlphabetical() {
        let page = ApprovalPaging.page(ids: ["z", "m", "a"], current: "m")
        XCTAssertEqual(page, ApprovalPage(position: 2, count: 3, previousID: "z", nextID: "a", currentID: "m"))
    }

    func testAnArrivalAfterTheCurrentOneKeepsTheCurrentAndGrowsTheCount() {
        let before = ApprovalPaging.page(ids: ["a", "b", "c"], current: "b")
        let after = ApprovalPaging.page(ids: ["a", "b", "c", "d"], current: "b")
        XCTAssertEqual(before?.currentID, "b")
        XCTAssertEqual(after?.currentID, "b")
        XCTAssertEqual(after?.position, 2)
        XCTAssertEqual(after?.count, 4)
        XCTAssertEqual(after?.label, "2 of 4")
    }

    func testWalkingNextThroughEveryPageVisitsEachOnceAndStopsAtTheEnd() {
        let ids = ["a", "b", "c", "d"]
        var seen: [String] = []
        var page = ApprovalPaging.page(ids: ids, current: nil)
        while let p = page {
            seen.append(p.currentID)
            page = p.nextID.flatMap { ApprovalPaging.page(ids: ids, current: $0) }
        }
        XCTAssertEqual(seen, ids)
    }

    func testWalkingPreviousFromTheEndVisitsEachOnceAndStopsAtTheStart() {
        let ids = ["a", "b", "c", "d"]
        var seen: [String] = []
        var page = ApprovalPaging.page(ids: ids, current: "d")
        while let p = page {
            seen.append(p.currentID)
            page = p.previousID.flatMap { ApprovalPaging.page(ids: ids, current: $0) }
        }
        XCTAssertEqual(seen, ids.reversed())
    }
}
