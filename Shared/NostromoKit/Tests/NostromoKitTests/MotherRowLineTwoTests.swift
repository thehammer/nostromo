// NostromoKit — MotherRowLineTwoTests.swift
//
// Mother focus v2, MF5: line two of a condensed Mother job row.
//
//   origin · repo · state fact · cost                         ⚑ badges   [notified slot]
//
// What the contract says, by width (the available width of line two):
//
//   >= 340   everything that fits is shown: origin, repo, state fact, cost, labelled badges
//   <  340   the cost is never shown
//   <  260   neither repo nor cost; each badge collapses to a bare "⚑"
//   always   origin and state fact are non-empty; cost goes before repo when space is short; when
//            the line is too long the state fact is truncated first (with "…"), then the origin
//
// The state fact is one capped, sanitised fact per state; the VoiceOver label is
// `<State>. <title>. From <origin>. <fact>.` then the badges.
//
// Widths are exact because `measure` is injected: a fake that charges 6 pt per character.

import XCTest
@testable import NostromoKit

final class MotherRowLineTwoTests: XCTestCase {

    // MARK: - Helpers

    private let measure: (String) -> CGFloat = { CGFloat($0.count) * 6 }
    private let widths: [CGFloat] = [220, 259, 260, 339, 340, 600]

    private var you: MotherOriginDisplay {
        MotherOriginDisplay.make(
            annotation: MotherJobAnnotation(origin: MotherOriginView(
                kind: .you, focusTag: nil, nameSnapshot: nil, focusName: nil)),
            currentName: { _ in nil })
    }

    private func model(
        state: String,
        title: String = "Fix the login flow",
        repo: String? = "nostromo",
        question: String? = nil,
        progressLine: String? = nil,
        badges: [String] = [],
        origin: MotherOriginDisplay? = nil,
        prNumber: Int? = nil,
        prMerged: Bool = false,
        failureReason: String? = nil,
        cost: String? = nil
    ) -> MotherJobRowModel {
        MotherJobRowModel(
            id: "job-1", state: state, title: title, repo: repo, question: question,
            progressLine: progressLine, attentionBadges: badges, showsProgressLine: true,
            origin: origin ?? you, prNumber: prNumber, prMerged: prMerged,
            failureReason: failureReason, cost: cost)
    }

    private func compose(_ m: MotherJobRowModel, _ width: CGFloat) -> MotherRowLineTwo {
        MotherRowLineTwo.compose(model: m, availableWidth: width, measure: measure)
    }

    /// One model per state, each carrying a repo, a cost, and the facts its state shows.
    private func everyState() -> [(name: String, model: MotherJobRowModel)] {
        [
            ("running", model(state: "running", progressLine: "≈60% · gates 2/3 · ETA ~5-15 min", cost: "$2.14")),
            ("awaiting", model(state: "awaiting", question: "Which branch should I target?", cost: "$0.80")),
            ("succeeded", model(state: "succeeded", prNumber: 907, cost: "$2.14")),
            ("failed", model(state: "failed", failureReason: "gate 2 failed: tests", cost: "$1.00")),
            ("cancelled", model(state: "cancelled", cost: "$0.10")),
            ("queued", model(state: "queued")),
            ("ready", model(state: "ready")),
            ("merged", model(state: "succeeded", prNumber: 907, prMerged: true, cost: "$2.14")),
        ]
    }

    // MARK: - Origin and state fact are always there

    func testOriginAndStateFactAreNonEmptyForEveryStateAtEveryWidth() {
        for (name, m) in everyState() {
            for w in widths {
                let line = compose(m, w)
                XCTAssertFalse(line.origin.isEmpty, "\(name) @\(w): origin is empty")
                XCTAssertFalse(line.stateFact.isEmpty, "\(name) @\(w): state fact is empty")
            }
        }
    }

    func testOriginAndStateFactAreNonEmptyEvenWhenBothAreHostileAndHuge() {
        let hostile = MotherOriginDisplay.make(
            annotation: MotherJobAnnotation(origin: MotherOriginView(
                kind: .focus, focusTag: "claudia-ABCDEF12",
                nameSnapshot: String(repeating: "W", count: 200), focusName: nil)),
            currentName: { _ in nil })
        let m = model(state: "awaiting", question: String(repeating: "Q", count: 200),
                      badges: ["Needs decision", "Stalled"], origin: hostile)
        for w in widths {
            let line = compose(m, w)
            XCTAssertFalse(line.origin.isEmpty, "@\(w): origin is empty")
            XCTAssertFalse(line.stateFact.isEmpty, "@\(w): state fact is empty")
        }
    }

    // MARK: - Segments by width

    func testAtOrAbove340EverythingThatFitsIsShown() {
        let m = model(state: "succeeded", badges: ["Stalled"], prNumber: 907, cost: "$2.14")
        for w: CGFloat in [340, 600] {
            let line = compose(m, w)
            XCTAssertEqual(line.origin, "You", "@\(w)")
            XCTAssertEqual(line.repo, "nostromo", "@\(w)")
            XCTAssertEqual(line.stateFact, "PR #907", "@\(w)")
            XCTAssertEqual(line.cost, "$2.14", "@\(w)")
            XCTAssertEqual(line.badges, ["⚑ Stalled"], "@\(w)")
            XCTAssertFalse(line.badgesCollapsed, "@\(w)")
        }
    }

    func testBelow340TheCostIsNeverShownButTheRepoIs() {
        let m = model(state: "succeeded", prNumber: 907, cost: "$2.14")
        for w: CGFloat in [339, 300, 260] {
            let line = compose(m, w)
            XCTAssertNil(line.cost, "@\(w): the cost is dropped under 340")
            XCTAssertEqual(line.repo, "nostromo", "@\(w): the repo still fits and stays")
        }
    }

    func testBelow260NeitherRepoNorCostIsShown() {
        let m = model(state: "succeeded", prNumber: 907, cost: "$2.14")
        for w: CGFloat in [259, 220] {
            let line = compose(m, w)
            XCTAssertNil(line.repo, "@\(w)")
            XCTAssertNil(line.cost, "@\(w)")
            XCTAssertEqual(line.origin, "You", "@\(w)")
            XCTAssertEqual(line.stateFact, "PR #907", "@\(w)")
        }
    }

    func testCostIsDroppedBeforeTheRepoWhenSpaceIsShort() {
        // At 340 the budget is 326 pt (slot 14). origin 3 + repo 32 + fact 7 + cost 5 chars plus three
        // separators is 336 pt: too long. Without the cost it is 288 pt: fits.
        let m = model(state: "succeeded", repo: String(repeating: "r", count: 32), prNumber: 907, cost: "$2.14")
        let line = compose(m, 340)
        XCTAssertNil(line.cost, "the cost goes first")
        XCTAssertEqual(line.repo, String(repeating: "r", count: 32), "the repo survives the cost")
    }

    func testTheRepoIsDroppedWhenItStillDoesNotFitWithoutTheCost() {
        let m = model(state: "succeeded", repo: String(repeating: "r", count: 60), prNumber: 907, cost: "$2.14")
        let line = compose(m, 340)
        XCTAssertNil(line.cost)
        XCTAssertNil(line.repo)
        XCTAssertEqual(line.origin, "You")
        XCTAssertEqual(line.stateFact, "PR #907", "dropping the repo makes room: nothing needs truncating")
    }

    func testTheSameLongRepoAndCostAreAllShownWhenThereIsRoom() {
        let m = model(state: "succeeded", repo: String(repeating: "r", count: 60), prNumber: 907, cost: "$2.14")
        let line = compose(m, 600)
        XCTAssertEqual(line.repo?.count, 60)
        XCTAssertEqual(line.cost, "$2.14")
    }

    func testAJobWithNoRepoOrCostHasNeitherSegment() {
        let line = compose(model(state: "queued", repo: nil), 600)
        XCTAssertNil(line.repo)
        XCTAssertNil(line.cost)
    }

    // MARK: - Badges

    func testBadgesAreLabelledAt260AndAboveWhenTheyFit() {
        let line = compose(model(state: "running", progressLine: "≈60% · gates 2/3", badges: ["Stalled"]), 260)
        XCTAssertEqual(line.badges, ["⚑ Stalled"])
        XCTAssertFalse(line.badgesCollapsed)
    }

    func testBadgesCollapseToABareFlagBelow260() {
        let m = model(state: "running", progressLine: "≈60% · gates 2/3", badges: ["Stalled", "Burning"])
        for w: CGFloat in [259, 220] {
            let line = compose(m, w)
            XCTAssertEqual(line.badges, ["⚑", "⚑"], "@\(w): one bare flag per badge")
            XCTAssertTrue(line.badgesCollapsed, "@\(w)")
        }
    }

    func testAJobWithNoBadgesShowsNoneAtAnyWidth() {
        for w in widths {
            let line = compose(model(state: "queued"), w)
            XCTAssertTrue(line.badges.isEmpty, "@\(w)")
            XCTAssertFalse(line.badgesCollapsed, "@\(w)")
        }
    }

    // MARK: - Truncation: the fact first, then the origin

    func testALongFactIsTruncatedWithAnEllipsisBeforeTheOriginIs() {
        // 40-character fact (240 pt) and a 3-character origin at 260: the fact gives way.
        let m = model(state: "awaiting", repo: nil, question: String(repeating: "Q", count: 60))
        let line = compose(m, 260)
        XCTAssertEqual(line.origin, "You", "the origin is untouched while the fact can give way")
        XCTAssertTrue(line.stateFact.hasSuffix("…"), "a truncated fact ends with an ellipsis: \(line.stateFact)")
        XCTAssertLessThan(line.stateFact.count, 40)
        XCTAssertFalse(line.stateFact.isEmpty)
    }

    func testALongOriginIsTruncatedOnlyAfterTheFactHasGivenWay() {
        let origin = MotherOriginDisplay.make(
            annotation: MotherJobAnnotation(origin: MotherOriginView(
                kind: .focus, focusTag: "claudia-ABCDEF12",
                nameSnapshot: String(repeating: "O", count: 60), focusName: nil)),
            currentName: { _ in nil })
        let m = model(state: "awaiting", repo: nil, question: String(repeating: "Q", count: 60), origin: origin)
        let line = compose(m, 220)
        XCTAssertTrue(line.stateFact.hasSuffix("…"), "the fact is truncated: \(line.stateFact)")
        XCTAssertTrue(line.origin.hasSuffix("…"), "the origin is truncated too, last: \(line.origin)")
        XCTAssertFalse(line.origin.isEmpty)
        XCTAssertFalse(line.stateFact.isEmpty)
    }

    func testWhatIsDrawnNeverExceedsTheWidthBesideTheBadgesAndTheReservedSlot() {
        let m = model(state: "awaiting", question: String(repeating: "Q", count: 60),
                      badges: ["Needs decision"], cost: "$2.14")
        for w in widths {
            let line = compose(m, w)
            let parts = [line.origin, line.repo, line.stateFact, line.cost].compactMap { $0 }
            let left = parts.map(measure).reduce(0, +) + measure(MotherRowLineTwo.separator) * CGFloat(parts.count - 1)
            let badges = line.badges.map(measure).reduce(0, +)
                + MotherRowLineTwo.badgeSpacing * CGFloat(max(0, line.badges.count - 1))
            let right = MotherRowLineTwo.notifiedSlotWidth + (line.badges.isEmpty ? 0 : badges + MotherRowLineTwo.badgeSpacing)
            XCTAssertLessThanOrEqual(left + right, w, "@\(w): line two overflows its width")
        }
    }

    func testANarrowWidthLeavesAFactThatFitsUntouched() {
        let line = compose(model(state: "succeeded", prNumber: 907), 220)
        XCTAssertEqual(line.stateFact, "PR #907")
        XCTAssertEqual(line.origin, "You")
    }

    // MARK: - State facts

    func testRunningFactIsProgressWithoutItsEta() {
        let m = model(state: "running", progressLine: "≈60% · gates 2/3 · ETA ~5-15 min")
        XCTAssertEqual(MotherRowLineTwo.stateFact(for: m), "≈60% · gates 2/3")
        XCTAssertEqual(compose(m, 600).stateFact, "≈60% · gates 2/3")
    }

    func testRunningWithNoProgressSaysRunning() {
        XCTAssertEqual(MotherRowLineTwo.stateFact(for: model(state: "running")), "running")
    }

    func testSucceededFactNamesThePullRequest() {
        XCTAssertEqual(MotherRowLineTwo.stateFact(for: model(state: "succeeded", prNumber: 907)), "PR #907")
        XCTAssertEqual(MotherRowLineTwo.stateFact(for: model(state: "succeeded", prNumber: 907, prMerged: true)),
                       "PR #907 merged")
        XCTAssertEqual(MotherRowLineTwo.stateFact(for: model(state: "succeeded")), "succeeded",
                       "no PR: just the state")
    }

    func testFailedFactCarriesTheReason() {
        XCTAssertEqual(MotherRowLineTwo.stateFact(for: model(state: "failed", failureReason: "tests red")),
                       "failed: tests red")
        XCTAssertEqual(MotherRowLineTwo.stateFact(for: model(state: "failed")), "failed")
        XCTAssertEqual(MotherRowLineTwo.stateFact(for: model(state: "failed", failureReason: "  \n ")), "failed")
    }

    func testAwaitingFactIsTheQuestionOrTheWordAwaiting() {
        XCTAssertEqual(MotherRowLineTwo.stateFact(for: model(state: "awaiting", question: "Which branch?")),
                       "Which branch?")
        XCTAssertEqual(MotherRowLineTwo.stateFact(for: model(state: "awaiting")), "awaiting")
    }

    func testCancelledQueuedAndReadyFactsAreTheStateItself() {
        for s in ["cancelled", "queued", "ready"] {
            XCTAssertEqual(MotherRowLineTwo.stateFact(for: model(state: s)), s)
        }
    }

    func testAnUnknownStateStillGetsANonEmptySanitisedFact() {
        XCTAssertEqual(MotherRowLineTwo.stateFact(for: model(state: "paused")), "paused")
        let hostile = MotherRowLineTwo.stateFact(for: model(state: HostileContent.kitchenSink))
        XCTAssertFalse(hostile.isEmpty)
        XCTAssertFalse(hostile.unicodeScalars.contains(where: HostileContent.isForbiddenOnARow))
    }

    // MARK: - Untrusted text in the fact

    func testAQuestionIsSanitisedAndCappedAt40Characters() {
        for hostile in HostileContent.all {
            let fact = MotherRowLineTwo.stateFact(for: model(state: "awaiting", question: hostile))
            XCTAssertLessThanOrEqual(fact.count, MotherRowLineTwo.factCap)
            XCTAssertFalse(fact.isEmpty)
            XCTAssertFalse(fact.unicodeScalars.contains(where: HostileContent.isForbiddenOnARow),
                           "a forbidden scalar reached the fact for: \(hostile.prefix(30))")
        }
    }

    func testAFailureReasonIsSanitisedAndCappedAt40Characters() {
        for hostile in HostileContent.all {
            let fact = MotherRowLineTwo.stateFact(for: model(state: "failed", failureReason: hostile))
            XCTAssertFalse(fact.isEmpty)
            XCTAssertTrue(fact.hasPrefix("failed"))
            XCTAssertLessThanOrEqual(fact.count, "failed: ".count + MotherRowLineTwo.factCap)
            XCTAssertFalse(fact.unicodeScalars.contains(where: HostileContent.isForbiddenOnARow),
                           "a forbidden scalar reached the fact for: \(hostile.prefix(30))")
        }
    }

    func testAMultiLineQuestionBecomesOneLine() {
        let fact = MotherRowLineTwo.stateFact(for: model(state: "awaiting", question: "first line\nsecond line\r\nthird"))
        XCTAssertFalse(fact.contains("\n"))
        XCTAssertFalse(fact.contains("\r"))
        XCTAssertTrue(fact.contains("first line"))
    }

    func testHostileRepoAndBadgesAreSanitisedOnTheComposedLine() {
        let m = model(state: "running", repo: HostileContent.kitchenSink,
                      badges: [HostileContent.ansiColour, HostileContent.bidi])
        for w in widths {
            let line = compose(m, w)
            let all = [line.origin, line.repo ?? "", line.stateFact, line.cost ?? ""] + line.badges
            for s in all {
                XCTAssertFalse(s.unicodeScalars.contains(where: HostileContent.isForbiddenOnARow), "@\(w): \(s)")
            }
        }
    }

    // MARK: - VoiceOver

    func testTheSpokenLabelReadsStateTitleOriginFact() {
        let m = model(state: "running", title: "Fix login", progressLine: "≈60% · gates 2/3 · ETA ~5-15 min")
        XCTAssertEqual(MotherRowLineTwo.accessibilityLabel(model: m), "Running. Fix login. From You. ≈60% · gates 2/3.")
    }

    func testTheSpokenLabelEndsWithTheBadges() {
        let m = model(state: "awaiting", title: "Ship it", question: "Which branch?", badges: ["Needs decision", "Stalled"])
        XCTAssertEqual(MotherRowLineTwo.accessibilityLabel(model: m),
                       "Awaiting. Ship it. From You. Which branch?. Needs decision. Stalled.")
    }

    func testTheSpokenLabelForASucceededJobNamesThePullRequest() {
        let m = model(state: "succeeded", title: "Ship it", prNumber: 907, prMerged: true)
        XCTAssertEqual(MotherRowLineTwo.accessibilityLabel(model: m), "Succeeded. Ship it. From You. PR #907 merged.")
    }

    func testTheSpokenLabelDoesNotDependOnTheWidth() {
        // It is built from the model alone: the spoken form never loses a segment to a narrow column.
        let m = model(state: "succeeded", title: "Ship it", prNumber: 907, cost: "$2.14")
        XCTAssertEqual(MotherRowLineTwo.accessibilityLabel(model: m), "Succeeded. Ship it. From You. PR #907.")
    }

    func testTheSpokenLabelIsSanitised() {
        let m = model(state: "awaiting", title: HostileContent.kitchenSink, question: HostileContent.kitchenSink,
                      badges: [])
        let label = MotherRowLineTwo.accessibilityLabel(model: m)
        XCTAssertFalse(label.unicodeScalars.contains(where: HostileContent.isForbiddenOnARow))
    }

    func testAnEmptyTitleIsSpokenAsTheJobId() {
        let m = model(state: "queued", title: "")
        XCTAssertEqual(MotherRowLineTwo.accessibilityLabel(model: m), "Queued. job-1. From You. queued.")
    }
}

// MARK: - The row model's new fields

final class MotherJobRowModelLineTwoFieldsTests: XCTestCase {

    func testTheNewFieldsDefaultToNothing() {
        let m = MotherJobRowModel(id: "j", state: "queued", title: "t")
        XCTAssertNil(m.prNumber)
        XCTAssertFalse(m.prMerged)
        XCTAssertNil(m.failureReason)
        XCTAssertNil(m.cost)
    }

    func testTheNewFieldsAreCarried() {
        let m = MotherJobRowModel(id: "j", state: "failed", title: "t", prNumber: 9, prMerged: true,
                                  failureReason: "boom", cost: "$1.00")
        XCTAssertEqual(m.prNumber, 9)
        XCTAssertTrue(m.prMerged)
        XCTAssertEqual(m.failureReason, "boom")
        XCTAssertEqual(m.cost, "$1.00")
    }

    func testTheRegularSpokenSummaryIgnoresTheNewFields() {
        let origin = MotherOriginDisplay.unknown
        let plain = MotherJobRowModel(id: "j", state: "running", title: "Fix login", repo: "nostromo",
                                      progressLine: "≈60% · gates 2/3", attentionBadges: ["Stalled"],
                                      showsProgressLine: true, origin: origin)
        let rich = MotherJobRowModel(id: "j", state: "running", title: "Fix login", repo: "nostromo",
                                     progressLine: "≈60% · gates 2/3", attentionBadges: ["Stalled"],
                                     showsProgressLine: true, origin: origin,
                                     prNumber: 907, prMerged: true, failureReason: "boom", cost: "$2.14")
        XCTAssertEqual(rich.accessibilitySummary, plain.accessibilitySummary)
        XCTAssertEqual(plain.accessibilitySummary,
                       "Fix login. From origin unknown. nostromo. ≈60% · gates 2/3. Stalled.")
    }

    func testTwoModelsDifferingOnlyInTheNewFieldsAreNotEqual() {
        let a = MotherJobRowModel(id: "j", state: "succeeded", title: "t")
        let b = MotherJobRowModel(id: "j", state: "succeeded", title: "t", prNumber: 1)
        XCTAssertNotEqual(a, b)
    }
}
