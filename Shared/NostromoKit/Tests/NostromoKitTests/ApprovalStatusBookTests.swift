// NostromoKit — ApprovalStatusBookTests.swift
//
// AP2b: the latest approval status per tool call, bounded per focus, least recently updated first.

import XCTest
@testable import NostromoKit

final class ApprovalStatusBookTests: XCTestCase {

    // MARK: - set / status

    func testARecordedStatusIsReadBackByToolUseId() {
        var book = ApprovalStatusBook()
        book.set(.awaiting, toolUseId: "t1", tag: "cody")
        XCTAssertEqual(book.status(toolUseId: "t1"), .awaiting)
    }

    func testAnUnknownCallHasNoStatus() {
        let book = ApprovalStatusBook()
        XCTAssertNil(book.status(toolUseId: "nope"))
    }

    func testTheLatestStatusOfACallReplacesTheEarlierOne() {
        var book = ApprovalStatusBook()
        book.set(.awaiting, toolUseId: "t1", tag: "cody")
        book.set(.approved(atMs: 5), toolUseId: "t1", tag: "cody")
        XCTAssertEqual(book.status(toolUseId: "t1"), .approved(atMs: 5))
        XCTAssertEqual(book.count(tag: "cody"), 1)
    }

    func testAStatusIsFoundWhicheverFocusItWasRecordedFor() {
        var book = ApprovalStatusBook()
        book.set(.deniedByYou, toolUseId: "t1", tag: "cody")
        book.set(.blockedByGuard, toolUseId: "t2", tag: "ada")
        XCTAssertEqual(book.status(toolUseId: "t1"), .deniedByYou)
        XCTAssertEqual(book.status(toolUseId: "t2"), .blockedByGuard)
    }

    func testWithdrawnForgetsTheCall() {
        var book = ApprovalStatusBook()
        book.set(.awaiting, toolUseId: "t1", tag: "cody")
        book.set(.awaiting, toolUseId: "t2", tag: "cody")
        book.set(.withdrawn, toolUseId: "t1", tag: "cody")
        XCTAssertNil(book.status(toolUseId: "t1"))
        XCTAssertEqual(book.count(tag: "cody"), 1)
        XCTAssertEqual(book.status(toolUseId: "t2"), .awaiting)
    }

    func testWithdrawingACallThatWasNeverRecordedChangesNothing() {
        var book = ApprovalStatusBook()
        book.set(.awaiting, toolUseId: "t1", tag: "cody")
        book.set(.withdrawn, toolUseId: "ghost", tag: "cody")
        XCTAssertEqual(book.count(tag: "cody"), 1)
        XCTAssertNil(book.status(toolUseId: "ghost"))
    }

    // MARK: - bounds

    func testTheDefaultCapacityIsFiveHundredPerFocus() {
        XCTAssertEqual(ApprovalStatusBook.capacityPerTag, 500)
    }

    func testSixHundredCallsForOneFocusKeepTheNewestFiveHundred() {
        var book = ApprovalStatusBook()
        for i in 0..<600 { book.set(.deniedByYou, toolUseId: "t\(i)", tag: "cody") }
        XCTAssertEqual(book.count(tag: "cody"), 500)
        for i in 0..<100 { XCTAssertNil(book.status(toolUseId: "t\(i)"), "t\(i) should be gone") }
        for i in 100..<600 { XCTAssertEqual(book.status(toolUseId: "t\(i)"), .deniedByYou, "t\(i) should remain") }
    }

    func testTheCapacityCanBeChosen() {
        var book = ApprovalStatusBook(capacityPerTag: 3)
        for i in 0..<5 { book.set(.deniedByYou, toolUseId: "t\(i)", tag: "cody") }
        XCTAssertEqual(book.count(tag: "cody"), 3)
        XCTAssertNil(book.status(toolUseId: "t0"))
        XCTAssertNil(book.status(toolUseId: "t1"))
        XCTAssertNotNil(book.status(toolUseId: "t4"))
    }

    func testUpdatingACallRefreshesItSoItOutlivesOlderOnes() {
        var book = ApprovalStatusBook(capacityPerTag: 3)
        book.set(.awaiting, toolUseId: "a", tag: "cody")
        book.set(.awaiting, toolUseId: "b", tag: "cody")
        book.set(.awaiting, toolUseId: "c", tag: "cody")
        book.set(.approved(atMs: 1), toolUseId: "a", tag: "cody")   // a is now the most recent
        book.set(.awaiting, toolUseId: "d", tag: "cody")            // evicts the least recently updated: b
        XCTAssertNil(book.status(toolUseId: "b"))
        XCTAssertEqual(book.status(toolUseId: "a"), .approved(atMs: 1))
        XCTAssertEqual(book.status(toolUseId: "c"), .awaiting)
        XCTAssertEqual(book.status(toolUseId: "d"), .awaiting)
    }

    func testAnotherFocusCallsDoNotEvictThisFocusCalls() {
        var book = ApprovalStatusBook(capacityPerTag: 3)
        for i in 0..<3 { book.set(.deniedByYou, toolUseId: "cody\(i)", tag: "cody") }
        for i in 0..<10 { book.set(.deniedByYou, toolUseId: "ada\(i)", tag: "ada") }
        XCTAssertEqual(book.count(tag: "cody"), 3)
        XCTAssertEqual(book.count(tag: "ada"), 3)
        for i in 0..<3 { XCTAssertNotNil(book.status(toolUseId: "cody\(i)")) }
    }

    func testCountOfAFocusWithNothingIsZero() {
        var book = ApprovalStatusBook()
        book.set(.awaiting, toolUseId: "t1", tag: "cody")
        XCTAssertEqual(book.count(tag: "ada"), 0)
    }

    // MARK: - headline

    func testTheHeadlineIsAwaitingWhenAnyListedCallAwaits() {
        var book = ApprovalStatusBook()
        book.set(.awaiting, toolUseId: "a", tag: "cody")
        book.set(.approved(atMs: 9), toolUseId: "b", tag: "cody")   // later, but awaiting still wins
        XCTAssertEqual(book.headline(toolUseIds: ["a", "b"]), .awaiting)
        XCTAssertEqual(book.headline(toolUseIds: ["b", "a"]), .awaiting)
    }

    func testTheHeadlineIsTheMostRecentlyUpdatedWhenNoneAwaits() {
        var book = ApprovalStatusBook()
        book.set(.approved(atMs: 1), toolUseId: "a", tag: "cody")
        book.set(.deniedByYou, toolUseId: "b", tag: "cody")
        XCTAssertEqual(book.headline(toolUseIds: ["a", "b"]), .deniedByYou)
        XCTAssertEqual(book.headline(toolUseIds: ["b", "a"]), .deniedByYou)
    }

    func testTheHeadlineFollowsAnEarlierCallThatWasUpdatedLast() {
        var book = ApprovalStatusBook()
        book.set(.awaiting, toolUseId: "a", tag: "cody")
        book.set(.awaiting, toolUseId: "b", tag: "cody")
        book.set(.deniedByYou, toolUseId: "b", tag: "cody")
        book.set(.approved(atMs: 7), toolUseId: "a", tag: "cody")
        XCTAssertEqual(book.headline(toolUseIds: ["a", "b"]), .approved(atMs: 7))
    }

    func testTheHeadlineIgnoresCallsThatAreNotListed() {
        var book = ApprovalStatusBook()
        book.set(.awaiting, toolUseId: "other", tag: "cody")
        book.set(.approved(atMs: 1), toolUseId: "a", tag: "cody")
        XCTAssertEqual(book.headline(toolUseIds: ["a"]), .approved(atMs: 1))
    }

    func testTheHeadlineIgnoresListedCallsThatHaveNoStatus() {
        var book = ApprovalStatusBook()
        book.set(.deniedByYou, toolUseId: "a", tag: "cody")
        XCTAssertEqual(book.headline(toolUseIds: ["a", "unknown", "also-unknown"]), .deniedByYou)
    }

    func testTheHeadlineIsNilWhenNoListedCallHasAStatus() {
        var book = ApprovalStatusBook()
        book.set(.awaiting, toolUseId: "other", tag: "cody")
        XCTAssertNil(book.headline(toolUseIds: ["a", "b"]))
        XCTAssertNil(book.headline(toolUseIds: []))
        XCTAssertNil(ApprovalStatusBook().headline(toolUseIds: ["a"]))
    }

    func testTheHeadlineSpansFociWhenTheCallsAreListedTogether() {
        var book = ApprovalStatusBook()
        book.set(.approved(atMs: 1), toolUseId: "a", tag: "cody")
        book.set(.blockedByGuard, toolUseId: "b", tag: "ada")
        XCTAssertEqual(book.headline(toolUseIds: ["a", "b"]), .blockedByGuard)
    }

    func testAForgottenCallIsNoLongerInTheHeadline() {
        var book = ApprovalStatusBook()
        book.set(.approved(atMs: 1), toolUseId: "a", tag: "cody")
        book.set(.awaiting, toolUseId: "b", tag: "cody")
        book.set(.withdrawn, toolUseId: "b", tag: "cody")
        XCTAssertEqual(book.headline(toolUseIds: ["a", "b"]), .approved(atMs: 1))
    }
}
