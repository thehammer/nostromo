import XCTest
import AppKit

// PR #223 review fix-up: a healthy source can still have something worth
// saying (Sentry shows only the first 300 issues per search). A `.fresh` status
// with a reason now shows that reason as a note; with no reason, and for the
// positive empty state, the banner stays hidden as before.

final class SourceStateBannerNoteTests: XCTestCase {
    private let truncation = "Showing the first 300 issues per search; narrow with a project filter."
    private let now = ISO8601DateFormatter().date(from: "2026-10-09T15:00:00Z")!

    func testAFreshStatusWithAReasonShowsItAsANoteWithoutRetry() {
        let content = SourceStateBanner.content(
            state: .fresh, updatedAt: nil, reason: truncation, retryAt: nil, sourceName: "Sentry", now: now)

        XCTAssertEqual(content, SourceStateBanner.Content(message: "Sentry: \(truncation)", showsRetry: false))
    }

    func testTheNoteNamesTheSourceItBelongsTo() {
        let content = SourceStateBanner.content(
            state: .fresh, updatedAt: nil, reason: "partial results", retryAt: nil, sourceName: "Jira", now: now)

        XCTAssertEqual(content?.message, "Jira: partial results")
    }

    func testTheStatusOverloadAgreesWithTheStateOverload() {
        let status = SourceStatus(source: .sentry, state: .fresh, reason: truncation, count: 300)

        let content = SourceStateBanner.content(for: status, sourceName: "Sentry", now: now)

        XCTAssertEqual(content, SourceStateBanner.Content(message: "Sentry: \(truncation)", showsRetry: false))
    }

    func testAFreshStatusWithoutAReasonStaysHidden() {
        XCTAssertNil(SourceStateBanner.content(
            state: .fresh, updatedAt: nil, reason: nil, retryAt: nil, sourceName: "Sentry", now: now))
        XCTAssertNil(SourceStateBanner.content(
            for: SourceStatus(source: .sentry, state: .fresh, count: 3), sourceName: "Sentry", now: now))
    }

    func testAFreshStatusWithAnEmptyReasonStaysHidden() {
        XCTAssertNil(SourceStateBanner.content(
            state: .fresh, updatedAt: nil, reason: "", retryAt: nil, sourceName: "Sentry", now: now))
    }

    func testTheEmptyStateStaysHiddenWithOrWithoutAReason() {
        XCTAssertNil(SourceStateBanner.content(
            state: .empty, updatedAt: nil, reason: nil, retryAt: nil, sourceName: "Sentry", now: now))
        XCTAssertNil(SourceStateBanner.content(
            state: .empty, updatedAt: nil, reason: truncation, retryAt: nil, sourceName: "Sentry", now: now))
    }

    func testTheOtherStatesAreUnchanged() {
        func message(_ state: SourceState, reason: String?) -> String? {
            SourceStateBanner.content(state: state, updatedAt: nil, reason: reason, retryAt: nil,
                                      sourceName: "Sentry", now: now)?.message
        }
        XCTAssertEqual(message(.loading, reason: nil), "Loading Sentry…")
        XCTAssertEqual(message(.error, reason: "boom"), "Sentry failed: boom")
        XCTAssertEqual(message(.unauthenticated, reason: "401"), "Sentry: 401")
        XCTAssertEqual(message(.notConfigured, reason: nil), "Sentry: not set up")
        XCTAssertEqual(SourceStateBanner.content(state: .error, updatedAt: nil, reason: "boom", retryAt: nil,
                                                 sourceName: "Sentry", now: now)?.showsRetry, true)
    }

    func testTheBannerViewShowsTheNoteAndHidesAgainWhenItGoesAway() {
        let banner = SourceStateBanner()

        banner.show(status: SourceStatus(source: .sentry, state: .fresh, reason: truncation, count: 300),
                    sourceName: "Sentry", now: now)
        XCTAssertFalse(banner.isHidden)
        XCTAssertEqual(banner.content?.message, "Sentry: \(truncation)")

        banner.show(status: SourceStatus(source: .sentry, state: .fresh, count: 12), sourceName: "Sentry", now: now)
        XCTAssertTrue(banner.isHidden)
        XCTAssertNil(banner.content)
    }
}
