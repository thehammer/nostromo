// NostromoKit — ObjCExceptionGuardTests.swift
//
// Swift cannot catch an NSException, and AppKit raises them for things like
// "NSWindowStyleMaskFullScreen cleared on a window outside of a full screen
// transition" (macOS 27). The guard is what turns such a raise into a value the app
// can log instead of dying.

import XCTest
import Foundation
import NostromoKit

final class ObjCExceptionGuardTests: XCTestCase {

    func test_a_body_that_does_not_throw_yields_no_caught_exception() {
        XCTAssertNil(ObjCExceptionGuard.catching { _ = 1 + 1 })
    }

    func test_a_raised_NSException_is_returned_with_its_name_and_reason() {
        let caught = ObjCExceptionGuard.catching {
            NSException(name: .genericException, reason: "x", userInfo: nil).raise()
        }

        XCTAssertEqual(caught, CaughtObjCException(name: NSExceptionName.genericException.rawValue, reason: "x"))
        XCTAssertEqual(caught?.name, "NSGenericException")
        XCTAssertEqual(caught?.reason, "x")
    }

    func test_an_exception_raised_without_a_reason_has_a_nil_reason() {
        let caught = ObjCExceptionGuard.catching {
            NSException(name: .invalidArgumentException, reason: nil, userInfo: nil).raise()
        }

        XCTAssertEqual(caught?.name, NSExceptionName.invalidArgumentException.rawValue)
        XCTAssertNil(caught?.reason)
    }

    func test_the_body_runs_exactly_once_whether_or_not_it_throws() {
        var quietRuns = 0
        _ = ObjCExceptionGuard.catching { quietRuns += 1 }
        XCTAssertEqual(quietRuns, 1)

        var throwingRuns = 0
        _ = ObjCExceptionGuard.catching {
            throwingRuns += 1
            NSException(name: .genericException, reason: "x", userInfo: nil).raise()
        }
        XCTAssertEqual(throwingRuns, 1, "a caught exception must not cause the body to be retried")
    }

    func test_the_guard_keeps_working_after_it_has_caught_an_exception() {
        let first = ObjCExceptionGuard.catching {
            NSException(name: .genericException, reason: "first", userInfo: nil).raise()
        }
        XCTAssertEqual(first?.reason, "first")

        XCTAssertNil(ObjCExceptionGuard.catching { _ = 0 }, "a later quiet body is not reported as throwing")

        let second = ObjCExceptionGuard.catching {
            NSException(name: .rangeException, reason: "second", userInfo: nil).raise()
        }
        XCTAssertEqual(second, CaughtObjCException(name: NSExceptionName.rangeException.rawValue, reason: "second"))
    }

    func test_effects_the_body_made_before_raising_are_kept() {
        var steps: [String] = []
        _ = ObjCExceptionGuard.catching {
            steps.append("before")
            NSException(name: .genericException, reason: "x", userInfo: nil).raise()
        }
        steps.append("after")
        XCTAssertEqual(steps, ["before", "after"])
    }
}
