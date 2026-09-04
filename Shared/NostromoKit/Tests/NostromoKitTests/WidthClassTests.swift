// NostromoKit — WidthClassTests.swift
//
// Behavioural tests for `WidthClass.from(isRegular:)` (W6 —
// ios-curated-view-parity): the one place the "nil-or-false-means-compact"
// rule is pinned down as a tested function rather than an inline `?? .compact`
// at the SwiftUI call site (`DynamicFocusView`'s
// `horizontalSizeClass.map { $0 == .regular }`). Small on purpose — the
// whole point is that "an iPad in a narrow multitasking window presents the
// compact layout" is exactly the `nil`/`false` case, and it must not
// silently rot into an untested one-liner the next time this call site is
// touched.
import XCTest
@testable import NostromoKit

final class WidthClassTests: XCTestCase {

    // MARK: - The nil/false-means-compact rule

    func testNoHorizontalSizeClassReportedAtAllMapsToCompact() {
        XCTAssertEqual(
            WidthClass.from(isRegular: nil), .compact,
            "SwiftUI reporting no size class (nil) must present the same layout as a phone — this is the narrow-multitasking-window case the PRD requires"
        )
    }

    func testACompactHorizontalSizeClassMapsToCompact() {
        XCTAssertEqual(WidthClass.from(isRegular: false), .compact)
    }

    // MARK: - The one case that yields the regular presentation

    func testARegularHorizontalSizeClassMapsToRegular() {
        XCTAssertEqual(WidthClass.from(isRegular: true), .regular)
    }
}
