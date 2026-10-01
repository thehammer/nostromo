// NostromoKit — FocusGroupingTests.swift
//
// Behavioural tests for `buildFocusRows(_:prFor:)` (W8 —
// per-focus-pr-indicator). `FocusGrouping.swift` compiles directly into this
// test target, so these drive the real grouping/labelling logic — not a
// textual scan.
//
// `FocusMeta` has no hand-written initializer, only `Decodable` — so, same
// as `DaemonStoreTests.swift`'s `ActivityEvent`/`ActivityStreamWire`
// fixtures, this uses the compiler-synthesized memberwise init directly,
// which is reachable here because `@testable import` widens `internal`
// (the synthesized init's real access level on a `public` struct with no
// explicit `init`) to visible.

import XCTest
@testable import NostromoKit

final class FocusGroupingTests: XCTestCase {

    // MARK: - Fixture helper

    private func makeFocus(
        tag: String,
        agentName: String,
        projectName: String? = nil,
        org: String? = "Carefeed",
        isBuiltIn: Bool = false,
        sessionSummary: String? = nil
    ) -> FocusMeta {
        FocusMeta(
            tag: tag,
            displayName: agentName.capitalized,
            agentName: agentName,
            projectName: projectName,
            org: org,
            isBuiltIn: isBuiltIn,
            sessionSummary: sessionSummary
        )
    }

    private func focusRows(_ rows: [FocusRow]) -> [(meta: FocusMeta, secondary: String?)] {
        rows.compactMap { row in
            guard case let .focus(meta, _, secondary, _) = row else { return nil }
            return (meta, secondary)
        }
    }

    // MARK: - D6: every row's secondary is non-nil and non-empty with the default (no-PR) prFor

    func testEveryFocusRowGetsANonNilNonEmptySecondaryWithNoPRsAnywhere() {
        let builtIn = makeFocus(tag: "fred", agentName: "fred", isBuiltIn: true)
        let solo = makeFocus(tag: "cody-solo", agentName: "cody", projectName: "admin-portal")
        let groupA = makeFocus(tag: "cody-group", agentName: "cody", projectName: "nostromo")
        let groupB = makeFocus(tag: "redd-group", agentName: "redd", projectName: "nostromo")

        let rows = buildFocusRows([builtIn, solo, groupA, groupB])
        let focuses = focusRows(rows)

        XCTAssertFalse(focuses.isEmpty, "sanity check: the fixture must actually produce .focus rows")
        for (meta, secondary) in focuses {
            XCTAssertNotNil(secondary, "focus '\(meta.tag)' has a nil secondary — every row must render one (D6)")
            XCTAssertNotEqual(secondary, "", "focus '\(meta.tag)' has an empty-string secondary — this would still change row height")
        }
    }

    // MARK: - D5: a PR wins over an existing sessionSummary

    func testAFocusWithAPrShowsThePrLabelEvenWhenItAlsoHasASessionSummary() {
        let focus = makeFocus(
            tag: "cody-1", agentName: "cody", projectName: "admin-portal",
            sessionSummary: "Working on login flow"
        )
        let rows = buildFocusRows([focus]) { tag in
            tag == "cody-1" ? (repo: "Carefeed/admin-portal", number: 1234) : (nil, nil)
        }

        let focuses = focusRows(rows)
        XCTAssertEqual(focuses.count, 1)
        XCTAssertEqual(
            focuses[0].secondary,
            NostromoKit.FocusPRLabel.label(repo: "Carefeed/admin-portal", number: 1234),
            "a PR under review must win over an existing sessionSummary"
        )
        XCTAssertNotEqual(focuses[0].secondary, "Working on login flow")
    }

    // MARK: - Existing behavior preserved: no PR + sessionSummary shows the summary

    func testAFocusWithNoPrButASessionSummaryStillShowsTheSummary() {
        // sessionSummary is only ever consulted by buildFocusRows as a
        // fallback for INDENTED rows within a multi-focus repo group (a
        // solo-repo row hard-codes `secondary: nil` regardless of summary,
        // both before and after this wedge — see FocusGrouping.swift's
        // solo-count branch) — so this needs a second focus sharing the
        // same repo to land in that branch at all.
        let focus = makeFocus(
            tag: "cody-2", agentName: "cody", projectName: "admin-portal",
            sessionSummary: "Working on login flow"
        )
        let sibling = makeFocus(tag: "redd-2", agentName: "redd", projectName: "admin-portal")
        let rows = buildFocusRows([focus, sibling]) { _ in (nil, nil) }

        let focuses = Dictionary(uniqueKeysWithValues: focusRows(rows).map { ($0.meta.tag, $0.secondary) })
        XCTAssertEqual(focuses["cody-2"], "Working on login flow")
    }

    // MARK: - Isolation: two focuses' PRs never bleed into each other or a third, PR-less focus

    func testTwoFocusesWithDifferentPrsProduceDifferentSecondariesAndLeaveAThirdUnaffected() {
        let focusA = makeFocus(tag: "focus-a", agentName: "cody", projectName: "admin-portal")
        let focusB = makeFocus(tag: "focus-b", agentName: "redd", projectName: "referral-monitor")
        let focusC = makeFocus(tag: "focus-c", agentName: "ada", projectName: "nostromo")

        let rows = buildFocusRows([focusA, focusB, focusC]) { tag in
            switch tag {
            case "focus-a": return (repo: "Carefeed/admin-portal", number: 100)
            case "focus-b": return (repo: "Carefeed/referral-monitor", number: 200)
            default: return (nil, nil)
            }
        }

        let focuses = Dictionary(uniqueKeysWithValues: focusRows(rows).map { ($0.meta.tag, $0.secondary) })

        XCTAssertEqual(focuses["focus-a"], "#100 · admin-portal")
        XCTAssertEqual(focuses["focus-b"], "#200 · referral-monitor")
        XCTAssertNotEqual(focuses["focus-a"], focuses["focus-b"], "two different focuses' PRs must never collapse to the same secondary")

        XCTAssertEqual(focuses["focus-c"], NostromoKit.FocusPRLabel.noPR, "a PR-less, summary-less focus must be unaffected by two other focuses each having their own PR")
    }

    // MARK: - Regression guard: FocusGrouping.swift must never read the machine-wide activeFocusAgentTag global

    func testFocusGroupingSourceNeverReferencesActiveFocusAgentTag() throws {
        let source = try Self.focusGroupingSource()
        XCTAssertFalse(source.contains("activeFocusAgentTag"), """
            FocusGrouping.swift must never read AppStore.activeFocusAgentTag — that property is a \
            single global clobbered by whichever window last switched focus, and the whole point \
            of the per-focus PR label is that it must render identically no matter which window \
            asks. `prFor` must be the only source of PR data this function ever consults.
            """)
    }

    // MARK: - Source helper

    private static func focusGroupingSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)      // …/Shared/NostromoKit/Tests/NostromoKitTests/FocusGroupingTests.swift
            .deletingLastPathComponent()                // …/Tests/NostromoKitTests
            .deletingLastPathComponent()                // …/Tests
            .deletingLastPathComponent()                // …/NostromoKit
            .appendingPathComponent("Sources/NostromoKit/Store/FocusGrouping.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
