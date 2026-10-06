// NostromoKit — PRSelectionTests.swift

import XCTest
@testable import NostromoKit

final class PRSelectionTests: XCTestCase {

    private let selected = PRRef(repo: "Carefeed/admin-portal", number: 5100)

    func testTheSelectedPrIsMarked() {
        XCTAssertTrue(PRSelection.isMarked(repo: "Carefeed/admin-portal", number: 5100,
                                           addressMarked: false, selected: selected))
    }

    func testAnotherPrIsNotMarked() {
        XCTAssertFalse(PRSelection.isMarked(repo: "Carefeed/admin-portal", number: 5101,
                                            addressMarked: false, selected: selected))
    }

    func testTheSameNumberInAnotherRepoIsADifferentPrAndIsNotMarked() {
        // #5100 exists in many repos. The highlight must follow repo AND number.
        XCTAssertFalse(PRSelection.isMarked(repo: "Carefeed/payments", number: 5100,
                                            addressMarked: false, selected: selected))
    }

    func testNothingSelectedMarksNothing() {
        XCTAssertFalse(PRSelection.isMarked(repo: "Carefeed/admin-portal", number: 5100,
                                            addressMarked: false, selected: nil))
    }

    func testAnAgentAddressedRowStaysMarkedRegardlessOfSelection() {
        // The pre-existing queue_row anchor mark must not be lost to the new rule.
        XCTAssertTrue(PRSelection.isMarked(repo: "Carefeed/payments", number: 1,
                                           addressMarked: true, selected: nil))
        XCTAssertTrue(PRSelection.isMarked(repo: "Carefeed/payments", number: 1,
                                           addressMarked: true, selected: selected))
    }
}
