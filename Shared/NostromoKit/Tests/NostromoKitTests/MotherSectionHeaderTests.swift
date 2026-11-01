// NostromoKit — MotherSectionHeaderTests.swift
//
// The condensed Mother list's section header is one compact line: the state in capitals, then the count.

import XCTest
@testable import NostromoKit

final class MotherSectionHeaderTests: XCTestCase {

    func testTheHeaderIsTheUppercasedStateThenTheCount() {
        XCTAssertEqual(MotherSectionHeader.headerText(state: "running", count: 3), "RUNNING 3")
    }

    func testEveryStateNameIsUppercased() {
        for (state, expected) in [("running", "RUNNING"), ("awaiting", "AWAITING"), ("queued", "QUEUED"),
                                  ("succeeded", "SUCCEEDED"), ("failed", "FAILED"), ("cancelled", "CANCELLED"),
                                  ("ready", "READY")] {
            XCTAssertEqual(MotherSectionHeader.headerText(state: state, count: 2), "\(expected) 2")
        }
    }

    func testCountsOfZeroOneAndTwelveAreWrittenAsPlainNumbers() {
        XCTAssertEqual(MotherSectionHeader.headerText(state: "queued", count: 0), "QUEUED 0")
        XCTAssertEqual(MotherSectionHeader.headerText(state: "queued", count: 1), "QUEUED 1")
        XCTAssertEqual(MotherSectionHeader.headerText(state: "queued", count: 12), "QUEUED 12")
    }

    func testAMixedCaseStateIsUppercased() {
        XCTAssertEqual(MotherSectionHeader.headerText(state: "Awaiting", count: 4), "AWAITING 4")
    }
}
