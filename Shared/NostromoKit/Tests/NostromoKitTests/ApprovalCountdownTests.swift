// NostromoKit — ApprovalCountdownTests.swift
//
// The card's "denies in 14:32" text (AP2a). Pure functions over the request's
// deadline and a clock reading, so no test here waits or reads the wall clock.

import XCTest
@testable import NostromoKit

final class ApprovalCountdownTests: XCTestCase {

    // MARK: - clock(seconds:)

    func testTheClockReadsMinutesAndTwoDigitSeconds() {
        XCTAssertEqual(ApprovalCountdown.clock(seconds: 872), "14:32")
        XCTAssertEqual(ApprovalCountdown.clock(seconds: 5), "0:05")
        XCTAssertEqual(ApprovalCountdown.clock(seconds: 59), "0:59")
        XCTAssertEqual(ApprovalCountdown.clock(seconds: 60), "1:00")
    }

    func testTheClockReadsZeroAsZero() {
        XCTAssertEqual(ApprovalCountdown.clock(seconds: 0), "0:00")
    }

    func testAFreshFifteenMinuteRequestReadsFifteenZeroZero() {
        XCTAssertEqual(ApprovalCountdown.clock(seconds: 900), "15:00")
    }

    func testMinutesAreNotCappedSoAnHourReadsSixtyZeroZero() {
        XCTAssertEqual(ApprovalCountdown.clock(seconds: 3600), "60:00")
    }

    func testANegativeNumberOfSecondsReadsZero() {
        XCTAssertEqual(ApprovalCountdown.clock(seconds: -1), "0:00")
        XCTAssertEqual(ApprovalCountdown.clock(seconds: -872), "0:00")
        XCTAssertEqual(ApprovalCountdown.clock(seconds: Int.min), "0:00")
    }

    func testMinutesBeyondThirtyTwoBitsStillRenderCorrectly() {
        XCTAssertEqual(ApprovalCountdown.clock(seconds: 1_000_000_000_000), "16666666666:40")
    }

    func testTheLargestNumberOfSecondsDoesNotTrapAndReadsMinutesAndSeconds() {
        let text = ApprovalCountdown.clock(seconds: Int.max)
        XCTAssertEqual(text, "153722867280912930:07")
    }

    // MARK: - label

    func testTheLabelSaysWhenTheRequestDenies() {
        XCTAssertEqual(ApprovalCountdown.label(seconds: 872), "denies in 14:32")
        XCTAssertEqual(ApprovalCountdown.label(seconds: 0), "denies in 0:00")
        XCTAssertEqual(ApprovalCountdown.label(seconds: -5), "denies in 0:00")
    }

    func testTheLabelFromADeadlineAndAClockReading() {
        XCTAssertEqual(ApprovalCountdown.label(deadlineAtMs: 1_760_000_872_000, nowMs: 1_760_000_000_000),
                       "denies in 14:32")
        XCTAssertEqual(ApprovalCountdown.label(deadlineAtMs: 1_760_000_900_000, nowMs: 1_760_000_000_000),
                       "denies in 15:00")
    }

    func testTheLabelReadsZeroZeroOnlyOnceTheDeadlineHasPassed() {
        XCTAssertEqual(ApprovalCountdown.label(deadlineAtMs: 1_000, nowMs: 999), "denies in 0:01")
        XCTAssertEqual(ApprovalCountdown.label(deadlineAtMs: 1_000, nowMs: 1_000), "denies in 0:00")
        XCTAssertEqual(ApprovalCountdown.label(deadlineAtMs: 1_000, nowMs: 1_001), "denies in 0:00")
    }

    // MARK: - secondsLeft

    func testSecondsLeftRoundsUp() {
        XCTAssertEqual(ApprovalCountdown.secondsLeft(deadlineAtMs: 1_001, nowMs: 1_000), 1, "1 ms left")
        XCTAssertEqual(ApprovalCountdown.secondsLeft(deadlineAtMs: 1_999, nowMs: 1_000), 1, "999 ms left")
        XCTAssertEqual(ApprovalCountdown.secondsLeft(deadlineAtMs: 2_000, nowMs: 1_000), 1, "exactly 1 s left")
        XCTAssertEqual(ApprovalCountdown.secondsLeft(deadlineAtMs: 2_001, nowMs: 1_000), 2, "1001 ms left")
    }

    func testAFreshFifteenMinuteDeadlineIsNineHundredSeconds() {
        let now: UInt64 = 1_760_000_000_000
        XCTAssertEqual(ApprovalCountdown.secondsLeft(deadlineAtMs: now + 900_000, nowMs: now), 900)
        XCTAssertEqual(ApprovalCountdown.secondsLeft(deadlineAtMs: now + 900_001, nowMs: now), 901)
        XCTAssertEqual(ApprovalCountdown.secondsLeft(deadlineAtMs: now + 899_999, nowMs: now), 900)
    }

    func testSecondsLeftIsZeroWhenTheDeadlineIsNowOrHasPassed() {
        XCTAssertEqual(ApprovalCountdown.secondsLeft(deadlineAtMs: 5_000, nowMs: 5_000), 0)
        XCTAssertEqual(ApprovalCountdown.secondsLeft(deadlineAtMs: 5_000, nowMs: 5_001), 0)
        XCTAssertEqual(ApprovalCountdown.secondsLeft(deadlineAtMs: 5_000, nowMs: 900_000), 0)
        XCTAssertEqual(ApprovalCountdown.secondsLeft(deadlineAtMs: 0, nowMs: 0), 0)
        XCTAssertEqual(ApprovalCountdown.secondsLeft(deadlineAtMs: 0, nowMs: UInt64.max), 0)
    }

    func testSecondsLeftIsNeverNegative() {
        for (deadline, now) in [(UInt64(0), UInt64(1)), (10, 11_000), (1_000, 1_000_000_000_000)] {
            XCTAssertGreaterThanOrEqual(ApprovalCountdown.secondsLeft(deadlineAtMs: deadline, nowMs: now), 0)
        }
    }

    func testAHugeDeadlineDoesNotTrap() {
        // 2^64 - 1 ms is about 585 million years; the answer is still a whole number of seconds.
        XCTAssertEqual(ApprovalCountdown.secondsLeft(deadlineAtMs: UInt64.max, nowMs: 0), 18_446_744_073_709_552)
        XCTAssertEqual(ApprovalCountdown.secondsLeft(deadlineAtMs: UInt64.max, nowMs: 1), 18_446_744_073_709_552)
        XCTAssertEqual(ApprovalCountdown.secondsLeft(deadlineAtMs: UInt64.max, nowMs: UInt64.max - 1), 1)
        XCTAssertEqual(ApprovalCountdown.secondsLeft(deadlineAtMs: UInt64.max, nowMs: UInt64.max), 0)
    }

    func testAHugeDeadlineStillProducesALabel() {
        let label = ApprovalCountdown.label(deadlineAtMs: UInt64.max, nowMs: 0)
        XCTAssertTrue(label.hasPrefix("denies in "), label)
    }
}
