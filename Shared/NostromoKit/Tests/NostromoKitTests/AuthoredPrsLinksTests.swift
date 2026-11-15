// NostromoKit — AuthoredPrsLinksTests.swift
//
// The only URL the Overview ever opens for a PR: `https://github.com/<repo>/pull/<number>`, rebuilt from the
// row's own repo and number, and only when the daemon-sent url agrees with them.
//
// Mutations (run by hand), and the test that fails for each:
//   1. the url's owner/repo are not compared with `repo` -> testAUrlNamingAnotherRepoOrOwnerIsRefused
//   2. the url's number is not compared with `number`    -> testAUrlWithAnotherNumberIsRefused
//   3. owner/repo compared case-sensitively               -> testOwnerAndRepoMatchCaseInsensitively
//   4. the returned URL is `URL(string: url)` instead of rebuilt from repo+number
//        -> testTheOpenedUrlIsRebuiltFromRepoAndNumber
//   5. the `\z` anchor loosened to `$` (a trailing newline passes) -> testHostileShapesAreRefused
//   6. the `https` / `github.com` prefix loosened (http, a lookalike host, userinfo) -> testHostileShapesAreRefused
//   7. leading zeros tolerated (`Int(n) == number` alone) -> testALeadingZeroNumberIsRefused

import XCTest
@testable import NostromoKit

final class AuthoredPrsLinksTests: XCTestCase {

    private let repo = "carefeed/portal"
    private let good = "https://github.com/carefeed/portal/pull/42"

    private func open(_ url: String, repo: String? = nil, number: Int = 42) -> URL? {
        AuthoredPrsLinks.pullRequestURL(url, repo: repo ?? self.repo, number: number)
    }

    func testAnExactUrlThatAgreesWithTheRowOpens() {
        XCTAssertEqual(open(good), URL(string: good))
    }

    func testAUrlNamingAnotherRepoOrOwnerIsRefused() {
        XCTAssertNil(open("https://github.com/carefeed/other/pull/42"), "same owner, different repo")
        XCTAssertNil(open("https://github.com/someone/portal/pull/42"), "different owner, same repo")
        XCTAssertNil(open("https://github.com/someone/other/pull/42"))
        XCTAssertNil(open(good, repo: "carefeed/other"), "the row's repo is the authority")
    }

    func testAUrlWithAnotherNumberIsRefused() {
        XCTAssertNil(open("https://github.com/carefeed/portal/pull/43"))
        XCTAssertNil(open(good, number: 41))
    }

    func testAZeroOrNegativeNumberIsRefused() {
        XCTAssertNil(open("https://github.com/carefeed/portal/pull/0", number: 0))
        XCTAssertNil(open("https://github.com/carefeed/portal/pull/1", number: -1))
    }

    func testALeadingZeroNumberIsRefused() {
        XCTAssertNil(open("https://github.com/carefeed/portal/pull/042"))
        XCTAssertNil(open("https://github.com/carefeed/portal/pull/0042", number: 42))
    }

    func testOwnerAndRepoMatchCaseInsensitively() {
        XCTAssertNotNil(open("https://github.com/CareFeed/Portal/pull/42"), "url upper-cased")
        XCTAssertNotNil(open(good, repo: "CAREFEED/PORTAL"), "row upper-cased")
    }

    func testTheOpenedUrlIsRebuiltFromRepoAndNumber() {
        XCTAssertEqual(open("https://github.com/CareFeed/Portal/pull/42", repo: "carefeed/portal"),
                       URL(string: "https://github.com/carefeed/portal/pull/42"),
                       "the row's spelling, not the wire's")
    }

    func testHostileShapesAreRefused() {
        let bad = [
            "http://github.com/carefeed/portal/pull/42",
            "https://github.com.evil.com/carefeed/portal/pull/42",
            "https://evil.com/github.com/carefeed/portal/pull/42",
            "https://user@github.com/carefeed/portal/pull/42",
            "https://github.com@evil.com/carefeed/portal/pull/42",
            "https://github.com:8443/carefeed/portal/pull/42",
            "https://github.com/carefeed/portal/pull/42/files",
            "https://github.com/carefeed/portal/pull/42/",
            "https://github.com/carefeed/portal/pull/42?x=1",
            "https://github.com/carefeed/portal/pull/42#files",
            "https://github.com/carefeed/portal/pull/42\n",
            " https://github.com/carefeed/portal/pull/42",
            "https://github.com/carefeed/portal/issues/42",
            "javascript:alert(1)",
            "",
        ]
        for url in bad { XCTAssertNil(open(url), "must not open: \(url.debugDescription)") }
    }

    func testARowWhoseRepoIsNotOwnerSlashNameIsRefused() {
        XCTAssertNil(open(good, repo: "portal"))
        XCTAssertNil(open(good, repo: "carefeed/portal/extra"))
        XCTAssertNil(open(good, repo: ""))
    }
}
