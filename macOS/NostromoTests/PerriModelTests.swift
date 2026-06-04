import XCTest
import AppKit
// CiState, CiCheck, PRDetail, PRQueueItem are compiled into this target directly
// (logic test — no host app, same as MotherBrokerClientTests).

// MARK: - PerriModelTests

/// Unit tests for Perri model decoding and diff-line classification.
final class PerriModelTests: XCTestCase {

    // MARK: - CiState.from(ciStateString:)

    func testCiStateFromKnownValues() {
        XCTAssertEqual(CiState.from(ciStateString: "unknown"),  .unknown)
        XCTAssertEqual(CiState.from(ciStateString: "pending"),  .pending)
        XCTAssertEqual(CiState.from(ciStateString: "success"),  .success)
        XCTAssertEqual(CiState.from(ciStateString: "failure"),  .failure)
    }

    func testCiStateFromCaseInsensitive() {
        XCTAssertEqual(CiState.from(ciStateString: "SUCCESS"),  .success)
        XCTAssertEqual(CiState.from(ciStateString: "Failure"),  .failure)
        XCTAssertEqual(CiState.from(ciStateString: "PENDING"),  .pending)
        XCTAssertEqual(CiState.from(ciStateString: "Unknown"),  .unknown)
    }

    func testCiStateFromNilReturnsUnknown() {
        XCTAssertEqual(CiState.from(ciStateString: nil), .unknown)
    }

    func testCiStateFromUnrecognisedStringReturnsUnknown() {
        XCTAssertEqual(CiState.from(ciStateString: ""), .unknown)
        XCTAssertEqual(CiState.from(ciStateString: "n/a"), .unknown)
        XCTAssertEqual(CiState.from(ciStateString: "skipped"), .unknown)
    }

    // MARK: - PRDetail decode

    private static let decoder = JSONDecoder()

    func testPRDetailDecodeFullPayload() throws {
        let json = """
        {
            "pr_number": 42,
            "repo": "acme/web",
            "title": "feat: auth",
            "author": "alice",
            "url": "https://github.com/acme/web/pull/42",
            "diff": "+hello\\n-world",
            "diff_too_large": false,
            "ci_checks": [
                {"name": "lint", "state": "success"},
                {"name": "tests", "state": "failure", "detail": "assert failed"}
            ],
            "additions": 10,
            "deletions": 3,
            "changed_files": 2,
            "head_sha": "abc123",
            "stale": false
        }
        """
        let data   = json.data(using: .utf8)!
        let detail = try Self.decoder.decode(PRDetail.self, from: data)

        XCTAssertEqual(detail.prNumber, 42)
        XCTAssertEqual(detail.repo, "acme/web")
        XCTAssertEqual(detail.title, "feat: auth")
        XCTAssertEqual(detail.author, "alice")
        XCTAssertEqual(detail.diff, "+hello\n-world")
        XCTAssertFalse(detail.diffTooLarge)
        XCTAssertEqual(detail.additions, 10)
        XCTAssertEqual(detail.deletions, 3)
        XCTAssertEqual(detail.changedFiles, 2)
        XCTAssertEqual(detail.headSha, "abc123")
        XCTAssertNil(detail.error)

        XCTAssertEqual(detail.ciChecks.count, 2)
        let lint = detail.ciChecks[0]
        XCTAssertEqual(lint.name, "lint")
        XCTAssertEqual(lint.state, .success)
        XCTAssertNil(lint.detail)

        let tests = detail.ciChecks[1]
        XCTAssertEqual(tests.name, "tests")
        XCTAssertEqual(tests.state, .failure)
        XCTAssertEqual(tests.detail, "assert failed")
    }

    func testPRDetailDecodeMissingOptionalFieldsDefaultSafely() throws {
        // Minimal payload — all optional / defaulted fields absent.
        let json = """
        {
            "repo": "acme/web",
            "title": "t",
            "author": "bob",
            "url": "https://github.com/acme/web/pull/1",
            "diff": ""
        }
        """
        let data   = json.data(using: .utf8)!
        let detail = try Self.decoder.decode(PRDetail.self, from: data)

        XCTAssertNil(detail.prNumber)
        XCTAssertFalse(detail.diffTooLarge)
        XCTAssertEqual(detail.additions, 0)
        XCTAssertEqual(detail.deletions, 0)
        XCTAssertEqual(detail.changedFiles, 0)
        XCTAssertEqual(detail.headSha, "")
        XCTAssertEqual(detail.ciChecks, [])
        XCTAssertNil(detail.error)
    }

    func testPRDetailDecodeWithError() throws {
        let json = """
        {
            "repo": "acme/web",
            "title": "",
            "author": "",
            "url": "",
            "diff": "",
            "error": "rate limit exceeded"
        }
        """
        let data   = json.data(using: .utf8)!
        let detail = try Self.decoder.decode(PRDetail.self, from: data)
        XCTAssertEqual(detail.error, "rate limit exceeded")
    }

    func testPRDetailDecodeUnknownCiStateFieldDefaultsToUnknown() throws {
        let json = """
        {
            "repo": "r",
            "title": "t",
            "author": "a",
            "url": "u",
            "diff": "",
            "ci_checks": [{"name": "foo", "state": "in_progress"}]
        }
        """
        let data   = json.data(using: .utf8)!
        let detail = try Self.decoder.decode(PRDetail.self, from: data)
        XCTAssertEqual(detail.ciChecks[0].state, .unknown)
    }

    // MARK: - diffLineColor

    func testDiffLineColorAddition() {
        XCTAssertEqual(diffLineColor("+added line"), Theme.sage)
    }

    func testDiffLineColorDeletion() {
        XCTAssertEqual(diffLineColor("-removed line"), Theme.redSweater)
    }

    func testDiffLineColorHunkHeader() {
        XCTAssertEqual(diffLineColor("@@ -1,3 +1,4 @@"), Theme.fgMuted)
    }

    func testDiffLineColorFileHeaderPlusPlus() {
        // +++ lines (file headers) are coloured as additions — matches TUI.
        XCTAssertEqual(diffLineColor("+++ b/src/main.rs"), Theme.sage)
    }

    func testDiffLineColorFileHeaderMinusMinus() {
        XCTAssertEqual(diffLineColor("--- a/src/main.rs"), Theme.redSweater)
    }

    func testDiffLineColorContextLine() {
        XCTAssertEqual(diffLineColor(" unchanged context"), Theme.fg)
    }

    func testDiffLineColorEmptyLine() {
        XCTAssertEqual(diffLineColor(""), Theme.fg)
    }
}

// Make CiCheck Equatable for test assertions.
extension CiCheck: Equatable {
    public static func == (lhs: CiCheck, rhs: CiCheck) -> Bool {
        lhs.name == rhs.name && lhs.state == rhs.state && lhs.detail == rhs.detail
    }
}
