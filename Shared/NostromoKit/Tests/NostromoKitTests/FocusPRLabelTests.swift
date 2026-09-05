// NostromoKit — FocusPRLabelTests.swift
//
// Pure value tests for `FocusPRLabel` (W8 — per-focus-pr-indicator).
//
// The core contract this wedge stands on: every focus's secondary line must
// render a NON-nil, NON-empty string — "#1234 · repo-name" when a PR is
// under review, or the explicit `FocusPRLabel.noPR` string otherwise — never
// blank, never nil, and with the PR number in the untruncatable leading
// position so a narrow sidebar's `.byTruncatingTail` can only ever eat into
// the repo name, never the identifying number.
//
// No host app needed — `FocusPRLabel` is a plain enum of static functions
// over `String?`/`Int?`, so these are ordinary XCTest value assertions.

import XCTest
@testable import NostromoKit

final class FocusPRLabelTests: XCTestCase {

    // MARK: - label(repo:number:) — both present

    func testLabelWithRepoAndNumberRendersNumberFirstThenShortRepo() {
        let label = FocusPRLabel.label(repo: "Carefeed/admin-portal", number: 1234)
        XCTAssertEqual(label, "#1234 · admin-portal",
                       "label must render exactly '#<number> · <short repo>', number first")
    }

    // MARK: - label(repo:number:) — either missing renders noPR

    func testLabelWithNilRepoRendersNoPR() {
        XCTAssertEqual(FocusPRLabel.label(repo: nil, number: 1234), FocusPRLabel.noPR,
                       "a PR number with no repo must render the explicit no-PR string, not a partial label")
    }

    func testLabelWithNilNumberRendersNoPR() {
        XCTAssertEqual(FocusPRLabel.label(repo: "Carefeed/admin-portal", number: nil), FocusPRLabel.noPR,
                       "a repo with no PR number must render the explicit no-PR string, not a partial label")
    }

    func testLabelWithBothNilRendersNoPR() {
        XCTAssertEqual(FocusPRLabel.label(repo: nil, number: nil), FocusPRLabel.noPR)
    }

    // MARK: - Truncation safety: the number is always in the leading, untruncatable position

    func testLabelWithAVeryLongRepoNameStillLeadsWithTheNumber() {
        let longRepo = "Carefeed/" + String(repeating: "x", count: 200)
        let label = FocusPRLabel.label(repo: longRepo, number: 42)
        XCTAssertTrue(label.hasPrefix("#42 · "), """
            the PR number must always occupy the untruncatable leading position — a long repo \
            name must never push the number itself out of a `.byTruncatingTail` sidebar's visible \
            prefix. Got: \(label)
            """)
    }

    // MARK: - shortRepo

    func testShortRepoStripsEverythingUpToAndIncludingTheLastSlash() {
        XCTAssertEqual(FocusPRLabel.shortRepo("Carefeed/admin-portal"), "admin-portal")
    }

    func testShortRepoWithNoSlashReturnsInputUnchanged() {
        XCTAssertEqual(FocusPRLabel.shortRepo("standalone"), "standalone",
                       "a repo string with no '/' must be returned unchanged, not mangled")
    }

    // MARK: - secondary(repo:number:fallback:) — PR always wins over fallback

    func testSecondaryPrefersThePrLabelOverANonEmptyFallback() {
        let secondary = FocusPRLabel.secondary(
            repo: "Carefeed/admin-portal", number: 1234, fallback: "Working on login flow"
        )
        XCTAssertEqual(
            secondary, FocusPRLabel.label(repo: "Carefeed/admin-portal", number: 1234),
            "a PR under review must always win over a session-summary/tag-prefix fallback"
        )
        XCTAssertNotEqual(secondary, "Working on login flow")
    }

    // MARK: - secondary — no PR, non-empty fallback wins

    func testSecondaryReturnsTheFallbackVerbatimWhenNoPrIsPresent() {
        let secondary = FocusPRLabel.secondary(repo: nil, number: nil, fallback: "Working on login flow")
        XCTAssertEqual(secondary, "Working on login flow")
    }

    // MARK: - secondary — no PR, nil fallback -> noPR

    func testSecondaryReturnsNoPRWhenNeitherPrNorFallbackArePresent() {
        let secondary = FocusPRLabel.secondary(repo: nil, number: nil, fallback: nil)
        XCTAssertEqual(secondary, FocusPRLabel.noPR)
    }

    // MARK: - secondary — no PR, empty-string fallback treated as absent

    func testSecondaryTreatsAnEmptyStringFallbackAsAbsent() {
        let secondary = FocusPRLabel.secondary(repo: nil, number: nil, fallback: "")
        XCTAssertEqual(secondary, FocusPRLabel.noPR,
                       "an empty-string fallback must never be rendered verbatim as a blank line — it must fall through to noPR")
    }

    // MARK: - secondary is never "" — the row-height-stability property, asserted explicitly

    func testSecondaryIsNeverAnEmptyStringAcrossTheWholeInputMatrix() {
        let repos: [String?] = [nil, "", "Carefeed/admin-portal"]
        let numbers: [Int?] = [nil, 0, 1234]
        let fallbacks: [String?] = [nil, "", "some summary"]

        for repo in repos {
            for number in numbers {
                for fallback in fallbacks {
                    let secondary = FocusPRLabel.secondary(repo: repo, number: number, fallback: fallback)
                    XCTAssertFalse(secondary.isEmpty, """
                        secondary(repo: \(String(describing: repo)), number: \(String(describing: number)), \
                        fallback: \(String(describing: fallback))) returned an empty string — this is the \
                        property row-height stability depends on: a blank secondary line changes a row's \
                        rendered height.
                        """)
                }
            }
        }
    }

    // MARK: - Per-focus isolation, restated at the value level

    func testTwoIndependentFocusesWithDifferentPRsProduceDifferentLabelsRegardlessOfCallOrder() {
        let focusA = FocusPRLabel.label(repo: "Carefeed/admin-portal", number: 1234)
        let focusB = FocusPRLabel.label(repo: "Carefeed/referral-monitor", number: 5678)

        XCTAssertNotEqual(focusA, focusB, "two focuses with different PRs must render different labels")
        XCTAssertEqual(focusA, "#1234 · admin-portal", "focus A's own label must be correct independent of focus B's call")
        XCTAssertEqual(focusB, "#5678 · referral-monitor", "focus B's own label must be correct independent of focus A's call")
    }

    func testTwoIndependentFocusesWithDifferentPRsProduceDifferentSecondariesRegardlessOfCallOrder() {
        let secondaryA = FocusPRLabel.secondary(repo: "Carefeed/admin-portal", number: 1234, fallback: "fallback A")
        let secondaryB = FocusPRLabel.secondary(repo: "Carefeed/referral-monitor", number: 5678, fallback: "fallback B")

        XCTAssertNotEqual(secondaryA, secondaryB, "two focuses' resolved secondaries must never collapse to the same value just because they were computed back to back")
    }
}
