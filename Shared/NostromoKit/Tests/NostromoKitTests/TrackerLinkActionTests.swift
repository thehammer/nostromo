import XCTest
@testable import NostromoKit

// T6: what a tracker link chip does, the live-source (`bound`) wire shape and the stale footnote.
final class TrackerLinkActionTests: XCTestCase {

    private func link(_ text: String, _ url: String? = nil, _ kind: TrackerLinkKindWire) -> TrackerLinkWire {
        TrackerLinkWire(text: text, url: url, kind: kind)
    }

    func testPrTicketAndFileLinksAreOpenedByTheDaemonWhateverTheirUrl() {
        XCTAssertEqual(TrackerLinkAction.action(for: link("PR #253", "https://github.com/a/b/pull/253", .pr), index: 2),
                       .openInPane(index: 2))
        XCTAssertEqual(TrackerLinkAction.action(for: link("CORE-2841", nil, .jira), index: 0), .openInPane(index: 0))
        XCTAssertEqual(TrackerLinkAction.action(for: link("index.md:42", nil, .file), index: 1), .openInPane(index: 1))
    }

    func testOtherLinksOpenTheirHttpUrlAndNothingElse() {
        XCTAssertEqual(TrackerLinkAction.action(for: link("run 9912", "https://ci.example.com/9912", .run), index: 0),
                       .openURL(URL(string: "https://ci.example.com/9912")!))
        XCTAssertEqual(TrackerLinkAction.action(for: link("Sentry PORTAL-1F2", nil, .sentry), index: 0), .inert)
        for hostile in ["javascript:alert(1)", "file:///etc/passwd", "x-apple.systempreferences:", "https://", "not a url"] {
            XCTAssertEqual(TrackerLinkAction.action(for: link("x", hostile, .url), index: 0), .inert, hostile)
        }
    }

    func testTheBoundFieldDecodesAndAnOldStringShapeIsIgnoredNotFatal() throws {
        func item(_ bound: String) throws -> TrackerItemWire {
            let json = #"{"id":"a","section":"now","status":"todo","bound":\#(bound),"source":""}"#
            return try JSONDecoder().decode(TrackerItemWire.self, from: Data(json.utf8))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let json = #"{"id":"a","bound":{"source":"mother.job","as_of":"2025-10-15T16:42:00Z","badly_stale":true}}"#
        let bound = try decoder.decode(TrackerItemWire.self, from: Data(json.utf8)).bound
        XCTAssertEqual(bound?.source, "mother.job")
        XCTAssertEqual(bound?.badlyStale, true)
        XCTAssertNotNil(bound?.asOf)
        XCTAssertNil(try item(#""mother.job/x""#).bound, "a shape this client doesn't know is no binding")
        XCTAssertNil(try item("null").bound)
    }

    func testTheFootnoteShowsOnlyForABadlyStaleSourceInTheGivenTimeZone() {
        let utc = TimeZone(identifier: "UTC")!
        let asOf = Date(timeIntervalSince1970: 1_760_546_520) // 2025-10-15T16:42:00Z
        XCTAssertNil(TrackerBoundFootnote.text(nil, timeZone: utc))
        XCTAssertNil(TrackerBoundFootnote.text(TrackerBoundWire(source: "pr.ci", asOf: asOf, badlyStale: false), timeZone: utc))
        XCTAssertEqual(TrackerBoundFootnote.text(TrackerBoundWire(source: "pr.ci", asOf: asOf, badlyStale: true), timeZone: utc),
                       "as of 16:42")
        XCTAssertEqual(TrackerBoundFootnote.text(TrackerBoundWire(source: "pr.ci", asOf: asOf, badlyStale: true),
                                                 timeZone: TimeZone(identifier: "America/Chicago")!), "as of 11:42")
        XCTAssertEqual(TrackerBoundFootnote.text(TrackerBoundWire(source: "pr.ci", asOf: nil, badlyStale: true), timeZone: utc),
                       "no report yet")
    }
}
