import XCTest
import AppKit

// PR #223 review fix-up: a healthy source can still have something worth
// saying (Sentry shows only the first 300 issues per search). A `.fresh` status
// or `.empty` status with a reason shows that reason as an informational note
// (no retry); with no reason the banner stays hidden as before.

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

    func testTheEmptyStateIsHiddenWithoutAReasonAndShowsAReasonAsANote() {
        XCTAssertNil(SourceStateBanner.content(
            state: .empty, updatedAt: nil, reason: nil, retryAt: nil, sourceName: "Sentry", now: now))
        XCTAssertEqual(
            SourceStateBanner.content(
                state: .empty, updatedAt: nil, reason: truncation, retryAt: nil, sourceName: "Sentry", now: now),
            SourceStateBanner.Content(message: "Sentry: \(truncation)", showsRetry: false))
    }

    /// What the daemon says when Jira answered the search with zero issues but rejected
    /// the token on `GET /myself` (src/data/work/jira.rs `rejected_reason(401)`).
    private let jiraRejectedToken = "Jira rejected the API token (401): create a new one and update "
        + "ATLASSIAN_API_TOKEN (check ATLASSIAN_USER_EMAIL too) in ~/.claude/credentials/.env."

    func testARejectedJiraTokenShowsAsUnauthenticatedWithWhatToDoNotAsEmpty() throws {
        let content = try XCTUnwrap(SourceStateBanner.content(
            state: .unauthenticated, updatedAt: nil, reason: jiraRejectedToken, retryAt: nil,
            sourceName: "Jira", now: now))

        XCTAssertEqual(content.message, "Jira: \(jiraRejectedToken)")
        XCTAssertTrue(content.message.contains("rejected the API token"), content.message)
        XCTAssertTrue(content.message.contains("create a new one"), content.message)
        XCTAssertTrue(content.message.contains("ATLASSIAN_API_TOKEN"), content.message)
        XCTAssertFalse(content.showsRetry, "a bad token is fixed in the credentials file, not by Retry")
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
