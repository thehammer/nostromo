// NostromoKit — AuthoredPrsMergeUITests.swift
//
// What the My open PRs Overview says about Perri and about merging, as pure functions of a PR (features
// `authored_prs_perri_v1` and `authored_prs_merge_v1`): the "Perri approved" badge, the Merge button and the
// reason it is off, the one-step confirmation text, the notice an attempt leaves on a row, the words for every
// merge code, and how the row and group models thread the feature flags and the attempts through.
//
// The wire (the row fields, the request, the answer frame) and `mergeReadiness` have their own file
// (AuthoredPrsMergeTests.swift). The daemon enforces every rule again when it merges; here the question is only
// what the app offers and what it tells the person.
//
// Mutations this file is meant to catch:
//   1. The Merge button enabled without the Perri-current-head condition (no verdict, an older version, changes
//      requested, only comments)
//        -> testTheButtonIsEnabledForEveryInputExactlyWhenAllRulesHold,
//           testEachReasonTheButtonIsOffHasItsOwnWordsAndNeverAConfirmation
//   2. The Merge button enabled without the human-approval condition
//        -> testTheButtonIsEnabledForEveryInputExactlyWhenAllRulesHold, testEachReasonTheButtonIsOff...
//   3. The Merge button offered for a row that is not an open row of the READY group (draft group, waiting,
//      needs you, merged or closed)
//        -> testNoButtonOutsideTheReadyGroupOrOnARowThatIsNotOpen, testTheButtonIsEnabledForEveryInput...
//   4. The confirmation taking the PR's title unsanitised or uncapped (a newline, a bidi override or a control
//      character in a sentence the person is about to act on; 300 characters of it)
//        -> testTheConfirmationCleansTheTitleOfControlAndBidiCharacters, testTheConfirmationCapsALongTitleWithAnEllipsis,
//           testTheCapIsOnTheCleanedTitleNotTheRawOne
//   5. A badge shown for a stale non-approval (changes requested or a comment on an older version), for an
//      unknown verdict, or on a PR that is not open
//        -> testNoBadgeForNoVerdictAnUnknownVerdictAStaleNonApprovalOrAPrThatIsNotOpen
//   6. The button offered without the merge feature (or without the perri feature)
//        -> testRowHasNoBadgeWithoutPerriAndNoButtonWithoutBothFeatures, testGroupsThreadTheFeatureFlagsToTheirRows
//   7. A stale or newer attempt's notice shown on a row it does not apply to; a headChanged notice dropped
//      when the head did change
//        -> testNoticeStaysOnlyForTheHeadItWasAbout, testHeadChangedIsTheNoticeThatSurvivesAHeadChange
//   8. A merged attempt regrouping the row before a snapshot says so
//        -> testAnAttemptNeverMovesARowBetweenGroups
//   9. A merge code worded as another, or the daemon's string shown
//        -> testEveryMergeCodeHasItsExactWords
//  10. A verdict recorded by an agent other than `perri` (or by nobody the app can name) badged, spoken or
//      confirmed as Perri's
//      a. `recorder` ignoring the agent part
//        -> testAnApprovalRecordedByCodyIs..., testEveryKindOfBadgeNamesAnotherRecorder...,
//           testTheAgentNameIsMatchedExactly... (and their hostile twins)
//      b. the altered-value check dropped, so `per<ZWSP>ri:x` (or a cut, edge-spaced or bidi value) reads as perri
//        -> AuthoredPrsHostileRecorderTests (AuthoredPrsMergeTests.swift): testAZeroWidthCharacterInsidePerri...,
//           testBidiAndControlCharacters..., testAnEdgeSpace..., testAValueCutForLength...
//      c. the credit dropped from the confirmation sentence only
//        -> testAnApprovalRecordedByCodyIs..., testAValueThatIsNotAgentColonTag..., testAVeryLongCodyValueStaysBounded...
//      d. the credit dropped from the spoken label only
//        -> testAnApprovalRecordedByCodyIs..., testEveryKindOfBadgeSaysRecorderUnknown...,
//           testNoVerdictKindSpeaksAsPerriForAHostileRecorder

import XCTest
@testable import NostromoKit

// MARK: - Helpers

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let utc = TimeZone(identifier: "UTC")!

/// Perri's verdict, five minutes old by default.
private func verdict(_ verdict: AuthoredPrPerriVerdict = .approved, current: Bool = true, minutesAgo: Int? = 5,
                     by: String? = "perri:cody-pr-1") -> AuthoredPrPerri {
    AuthoredPrPerri(verdict: verdict, at: minutesAgo.map { t0.addingTimeInterval(-Double($0) * 60) }, by: by,
                    forCurrentHead: current)
}

/// A PR that may be merged: open, in READY, not a draft, green, approved by a human, Perri approved this head.
private func pr(_ number: Int = 458, title: String = "Fix the thing", group: AuthoredPrGroup = .ready,
                lifecycle: AuthoredPrLifecycle = .open, draft: Bool = false, baseRef: String? = "main",
                checks: AuthoredPrChecks = AuthoredPrChecks(state: .passing, passed: 3),
                review: AuthoredPrReview = AuthoredPrReview(state: .approved, logins: ["dana"]),
                perri: AuthoredPrPerri? = verdict(), head: String? = "0123abcd") -> AuthoredPr {
    AuthoredPr(repo: "thehammer/nostromo", number: number, url: "https://github.com/thehammer/nostromo/pull/\(number)",
               title: title, draft: draft, updatedAt: t0.addingTimeInterval(-7200), group: group, lifecycle: lifecycle,
               baseRef: baseRef, checks: checks, review: review, headShaShort: head, perri: perri)
}

private func badge(_ pr: AuthoredPr) -> AuthoredPrPerriBadge? { AuthoredPrsPresentation.perriBadge(pr, now: t0) }

private func button(_ pr: AuthoredPr, attempt: AuthoredPrMergeAttempt? = nil) -> AuthoredPrMergeButton? {
    AuthoredPrsPresentation.mergeButton(pr, attempt: attempt)
}

private func row(_ pr: AuthoredPr, perri: Bool = true, merge: Bool = true,
                 attempt: AuthoredPrMergeAttempt? = nil) -> AuthoredPrRowModel {
    AuthoredPrsPresentation.row(pr, now: t0, perri: perri, merge: merge, mergeAttempt: attempt)
}

private func attempt(_ progress: AuthoredPrMergeProgress, head: String = "0123abcd") -> AuthoredPrMergeAttempt {
    AuthoredPrMergeAttempt(head: head, progress: progress)
}

private let allCodes: [AuthoredPrMergeCode] = [
    .notFound, .notOpen, .draft, .notApproved, .checksNotGreen, .notMergeable, .blocked, .behind, .headChanged,
    .perriNotApproved, .perriStale, .tokenCannotMerge, .rateLimited, .unreachable, .busy, .notPermitted, .gestureRefused, .unknown,
]

// MARK: - The Perri badge

final class AuthoredPrsPerriBadgeTests: XCTestCase {

    func testAnApprovalOfThisHeadIsPerriTickWithItsTooltipAndSpokenLabel() throws {
        let b = try XCTUnwrap(badge(pr(perri: verdict(.approved))))
        XCTAssertEqual(b.kind, .approved)
        XCTAssertEqual(b.text, "Perri ✓")
        XCTAssertFalse(b.isMuted, "a current approval is shown at full strength")
        XCTAssertEqual(b.accessibilityLabel, "Perri approved this version")
        XCTAssertEqual(b.tooltip, "Approved 5m ago by perri:cody-pr-1 · head 0123abcd")
    }

    func testAnApprovalOfAnOlderHeadIsMutedSaysOlderAndThatANewPushNeedsANewReview() throws {
        let b = try XCTUnwrap(badge(pr(perri: verdict(.approved, current: false))))
        XCTAssertEqual(b.kind, .olderApproval)
        XCTAssertEqual(b.text, "Perri ✓ older")
        XCTAssertTrue(b.isMuted, "an old approval is not a current one: it is quieter")
        XCTAssertEqual(b.accessibilityLabel, "Perri approved an older version")
        XCTAssertEqual(b.tooltip, "Approved 5m ago by perri:cody-pr-1 for an older version of this PR. A new push needs a new review.")
    }

    func testChangesRequestedOfThisHeadIsPerriCross() throws {
        let b = try XCTUnwrap(badge(pr(perri: verdict(.changesRequested))))
        XCTAssertEqual(b.kind, .changesRequested)
        XCTAssertEqual(b.text, "Perri ✗")
        XCTAssertFalse(b.isMuted)
        XCTAssertEqual(b.accessibilityLabel, "Perri requested changes")
        XCTAssertEqual(b.tooltip, "Changes requested 5m ago by perri:cody-pr-1 · head 0123abcd")
    }

    func testACommentOfThisHeadIsPerriComments() throws {
        let b = try XCTUnwrap(badge(pr(perri: verdict(.comment))))
        XCTAssertEqual(b.kind, .comments)
        XCTAssertEqual(b.text, "Perri comments")
        XCTAssertFalse(b.isMuted)
        XCTAssertEqual(b.accessibilityLabel, "Perri left comments")
        XCTAssertEqual(b.tooltip, "Commented 5m ago by perri:cody-pr-1 · head 0123abcd")
    }

    func testColourIsNeverTheOnlySignalTheGlyphIsInTheText() throws {
        XCTAssertTrue(try XCTUnwrap(badge(pr(perri: verdict(.approved)))).text.contains("✓"))
        XCTAssertTrue(try XCTUnwrap(badge(pr(perri: verdict(.approved, current: false)))).text.contains("✓"))
        XCTAssertTrue(try XCTUnwrap(badge(pr(perri: verdict(.changesRequested)))).text.contains("✗"))
        // And the four are told apart by their words, not by colour.
        let texts = try [verdict(.approved), verdict(.approved, current: false), verdict(.changesRequested), verdict(.comment)]
            .map { try XCTUnwrap(badge(pr(perri: $0))).text }
        XCTAssertEqual(Set(texts).count, 4)
        let spoken = try [verdict(.approved), verdict(.approved, current: false), verdict(.changesRequested), verdict(.comment)]
            .map { try XCTUnwrap(badge(pr(perri: $0))).accessibilityLabel }
        XCTAssertEqual(Set(spoken).count, 4)
    }

    func testOnlyTheOlderApprovalIsMuted() throws {
        for (v, muted) in [(verdict(.approved), false), (verdict(.approved, current: false), true),
                           (verdict(.changesRequested), false), (verdict(.comment), false)] {
            XCTAssertEqual(try XCTUnwrap(badge(pr(perri: v))).isMuted, muted, "\(v)")
        }
    }

    func testNoBadgeForNoVerdictAnUnknownVerdictAStaleNonApprovalOrAPrThatIsNotOpen() {
        XCTAssertNil(badge(pr(perri: nil)), "no verdict")
        XCTAssertNil(badge(pr(perri: verdict(.unknown, current: true))), "a verdict this build does not know")
        XCTAssertNil(badge(pr(perri: verdict(.unknown, current: false))))
        // A non-approval of an older version says nothing about this one: no badge at all.
        XCTAssertNil(badge(pr(perri: verdict(.changesRequested, current: false))), "stale changes requested")
        XCTAssertNil(badge(pr(perri: verdict(.comment, current: false))), "stale comment")
        for lifecycle in [AuthoredPrLifecycle.merged, .closed, .unknown] {
            for v in [verdict(.approved), verdict(.approved, current: false), verdict(.changesRequested), verdict(.comment)] {
                XCTAssertNil(badge(pr(lifecycle: lifecycle, perri: v)), "a \(lifecycle) PR has no badge: \(v)")
            }
        }
    }

    func testTheBadgeIsAboutThePrNotTheGroupItIsIn() {
        for group in [AuthoredPrGroup.needsYou, .ready, .waiting, .draft, .unknown] {
            XCTAssertEqual(badge(pr(group: group, perri: verdict(.approved)))?.kind, .approved, "\(group)")
        }
    }

    func testTheTooltipSaysHowLongAgoLikeTheRowsAge() throws {
        for (minutes, words) in [(0, "0s"), (1, "1m"), (59, "59m"), (120, "2h"), (60 * 24 * 3, "3d")] {
            let b = try XCTUnwrap(badge(pr(perri: verdict(.approved, minutesAgo: minutes))))
            XCTAssertTrue(b.tooltip.contains("\(words) ago"), "\(minutes) min: \(b.tooltip)")
        }
        let tooltip = try XCTUnwrap(badge(pr(perri: verdict(.approved, minutesAgo: 120)))).tooltip
        XCTAssertEqual(tooltip, "Approved \(AuthoredPrsPresentation.age(from: t0.addingTimeInterval(-7200), now: t0)) ago by perri:cody-pr-1 · head 0123abcd",
                       "the same words the row's age uses")
    }

    func testTheTooltipOmitsEachPieceThatIsAbsent() throws {
        let noWho = try XCTUnwrap(badge(pr(perri: verdict(.approved, by: nil)))).tooltip
        XCTAssertFalse(noWho.contains(" by "), noWho)
        XCTAssertTrue(noWho.contains("5m ago"), noWho)
        XCTAssertTrue(noWho.contains("0123abcd"), noWho)

        let noWhen = try XCTUnwrap(badge(pr(perri: verdict(.approved, minutesAgo: nil)))).tooltip
        XCTAssertFalse(noWhen.contains("ago"), noWhen)
        XCTAssertTrue(noWhen.contains("perri:cody-pr-1"), noWhen)
        XCTAssertTrue(noWhen.contains("0123abcd"), noWhen)

        let noHead = try XCTUnwrap(badge(pr(perri: verdict(.approved), head: nil))).tooltip
        XCTAssertFalse(noHead.contains("head"), noHead)
        XCTAssertTrue(noHead.hasPrefix("Approved 5m ago by perri:cody-pr-1"), noHead)

        let bare = try XCTUnwrap(badge(pr(perri: verdict(.changesRequested, minutesAgo: nil, by: nil), head: nil))).tooltip
        XCTAssertTrue(bare.hasPrefix("Changes requested"), bare)
        XCTAssertFalse(bare.contains("ago") || bare.contains(" by ") || bare.contains("head"), bare)
        XCTAssertFalse(bare.hasSuffix(" "), "no dangling separator: \(bare.debugDescription)")
        XCTAssertFalse(bare.hasSuffix("·"), "no dangling separator: \(bare.debugDescription)")
    }

    func testTheOlderTooltipOmitsWhoAndWhenWhenAbsentButKeepsTheAdvice() throws {
        let tooltip = try XCTUnwrap(badge(pr(perri: verdict(.approved, current: false, minutesAgo: nil, by: nil)))).tooltip
        XCTAssertTrue(tooltip.contains("A new push needs a new review."), tooltip)
        XCTAssertFalse(tooltip.contains("ago") || tooltip.contains(" by "), tooltip)
    }

    func testTheValuesCrossAConcurrencyBoundary() async {
        // `Sendable`: this only compiles when each of these is.
        let b = badge(pr())
        let attempt = AuthoredPrMergeAttempt(head: "0123abcd", progress: .failed(.perriStale))
        let button = AuthoredPrsPresentation.mergeButton(pr())
        let result = await Task.detached { @Sendable () -> (AuthoredPrPerriBadge?, AuthoredPrMergeAttempt, AuthoredPrMergeButton?) in
            (b, attempt, button)
        }.value
        XCTAssertEqual(result.0, b)
        XCTAssertEqual(result.1, attempt)
        XCTAssertEqual(result.2, button)
    }
}

// MARK: - The Merge button

final class AuthoredPrsMergeButtonTests: XCTestCase {

    func testAReadyRowOffersAnEnabledMergeButtonThatSaysSquashAndHasTheConfirmation() throws {
        let b = try XCTUnwrap(button(pr()))
        XCTAssertEqual(b.state, .ready)
        XCTAssertTrue(b.isEnabled)
        XCTAssertEqual(b.title, "Merge")
        XCTAssertNil(b.reason)
        XCTAssertTrue(b.tooltip.contains("Squash"), "the person is told it is a squash merge: \(b.tooltip)")
        XCTAssertEqual(b.accessibilityLabel, "Merge PR 458")
        XCTAssertNotNil(b.confirmation, "only a ready button leads anywhere")
    }

    /// Every reason the button can be off, as (what is wrong, the PR, the words).
    private var unavailable: [(String, AuthoredPr, String)] {
        let needs = "Needs Perri's review"
        return [
            ("a draft", pr(draft: true), "Draft"),
            ("failing checks", pr(checks: AuthoredPrChecks(state: .failing, passed: 2, failed: 1)), "Checks not green"),
            ("pending checks", pr(checks: AuthoredPrChecks(state: .pending, pending: 1)), "Checks not green"),
            ("unknown checks", pr(checks: AuthoredPrChecks(state: .unknown)), "Checks not green"),
            ("no review", pr(review: AuthoredPrReview(state: .none)), "Waiting for human approval"),
            ("review requested", pr(review: AuthoredPrReview(state: .reviewRequested)), "Waiting for human approval"),
            ("changes requested by a human", pr(review: AuthoredPrReview(state: .changesRequested)), "Waiting for human approval"),
            ("an unknown review state", pr(review: AuthoredPrReview(state: .unknown)), "Waiting for human approval"),
            ("no verdict from Perri", pr(perri: nil), needs),
            ("Perri only commented", pr(perri: verdict(.comment)), needs),
            ("a verdict this build does not know", pr(perri: verdict(.unknown)), needs),
            ("an approval but no head to echo", pr(head: nil), needs),
            ("an approval of an older version", pr(perri: verdict(.approved, current: false)), "Perri approved an older version"),
            ("changes requested of an older version", pr(perri: verdict(.changesRequested, current: false)), needs),
            ("a comment on an older version", pr(perri: verdict(.comment, current: false)), needs),
            ("changes requested by Perri", pr(perri: verdict(.changesRequested)), "Perri requested changes"),
        ]
    }

    func testEachReasonTheButtonIsOffHasItsOwnWordsAndNeverAConfirmation() throws {
        for (what, pr, reason) in unavailable {
            let b = try XCTUnwrap(button(pr), what)
            XCTAssertEqual(b.state, .unavailable, what)
            XCTAssertFalse(b.isEnabled, "\(what): the button is off")
            XCTAssertEqual(b.reason, reason, what)
            XCTAssertEqual(b.title, "Merge", "\(what): it still says Merge; the reason is beside it")
            XCTAssertEqual(b.tooltip, reason, "\(what): hovering says why")
            XCTAssertEqual(b.accessibilityLabel, "Merge, unavailable: \(reason)", what)
            XCTAssertNil(b.confirmation, "\(what): nothing to confirm, so nothing can be merged from it")
        }
    }

    func testTheWordsOfTheReasonsAreAllDifferentWhereTheCausesAre() {
        let reasons = Set(unavailable.map { $0.2 })
        XCTAssertEqual(reasons, ["Draft", "Checks not green", "Waiting for human approval", "Needs Perri's review",
                                 "Perri approved an older version", "Perri requested changes"])
    }

    func testWhenSeveralReasonsHoldTheFirstInTheDocumentedOrderIsTheOneSaid() throws {
        let everything = pr(draft: true, checks: AuthoredPrChecks(state: .failing), review: AuthoredPrReview(state: .none), perri: nil)
        XCTAssertEqual(try XCTUnwrap(button(everything)).reason, "Draft")
        let noDraft = pr(checks: AuthoredPrChecks(state: .failing), review: AuthoredPrReview(state: .none), perri: nil)
        XCTAssertEqual(try XCTUnwrap(button(noDraft)).reason, "Checks not green")
        let green = pr(review: AuthoredPrReview(state: .none), perri: verdict(.changesRequested))
        XCTAssertEqual(try XCTUnwrap(button(green)).reason, "Waiting for human approval")
    }

    func testNoButtonOutsideTheReadyGroupOrOnARowThatIsNotOpen() {
        for group in [AuthoredPrGroup.needsYou, .waiting, .draft, .unknown] {
            XCTAssertNil(button(pr(group: group)), "a row in \(group) has no Merge button, however ready it looks")
        }
        for lifecycle in [AuthoredPrLifecycle.merged, .closed, .unknown] {
            XCTAssertNil(button(pr(lifecycle: lifecycle)), "a \(lifecycle) PR has none")
        }
    }

    /// Every combination of the inputs: the button is enabled exactly when all the rules allow it, so no input can
    /// be left out. It is present exactly for open rows of READY, and it has a confirmation exactly when enabled.
    func testTheButtonIsEnabledForEveryInputExactlyWhenAllRulesHold() {
        let lifecycles: [AuthoredPrLifecycle] = [.open, .merged, .closed, .unknown]
        let groups: [AuthoredPrGroup] = [.ready, .waiting, .needsYou]
        let checks: [AuthoredPrChecksState] = [.passing, .none, .failing, .pending, .unknown]
        let reviews: [AuthoredPrReviewState] = [.approved, .none, .changesRequested, .reviewRequested, .unknown]
        let verdicts: [AuthoredPrPerri?] = [nil] + [AuthoredPrPerriVerdict.approved, .changesRequested, .comment, .unknown]
            .flatMap { v in [true, false].map { AuthoredPrPerri(verdict: v, forCurrentHead: $0) } }
        for lifecycle in lifecycles { for group in groups { for draft in [false, true] { for c in checks { for r in reviews {
            for v in verdicts { for head in [String?.none, "0123abcd"] {
                let p = pr(group: group, lifecycle: lifecycle, draft: draft, checks: AuthoredPrChecks(state: c),
                           review: AuthoredPrReview(state: r), perri: v, head: head)
                let present = lifecycle == .open && group == .ready
                let allows = present && !draft && (c == .passing || c == .none) && r == .approved
                    && v?.verdict == .approved && v?.forCurrentHead == true && head != nil
                let b = button(p)
                let context = "\(lifecycle) \(group) draft:\(draft) \(c) \(r) \(String(describing: v)) head:\(String(describing: head))"
                XCTAssertEqual(b != nil, present, context)
                XCTAssertEqual(b?.isEnabled ?? false, allows, context)
                XCTAssertEqual(b?.confirmation != nil, allows, context)
                XCTAssertEqual(b?.state == .ready, allows, context)
            } }
        } } } } }
    }

    // MARK: Attempts

    func testAMergeInFlightShowsMergingAndIsOffAndHasNoConfirmation() throws {
        let b = try XCTUnwrap(button(pr(), attempt: attempt(.merging)))
        XCTAssertEqual(b.state, .merging)
        XCTAssertEqual(b.title, "Merging…")
        XCTAssertFalse(b.isEnabled, "a second press while the answer is pending does nothing")
        XCTAssertNil(b.confirmation, "and opens nothing")
        XCTAssertNil(b.reason)
        XCTAssertEqual(b.accessibilityLabel, "Merge PR 458, merging")
    }

    func testAMergedAttemptShowsMergedAndIsOff() throws {
        let b = try XCTUnwrap(button(pr(), attempt: attempt(.merged)))
        XCTAssertEqual(b.state, .merged)
        XCTAssertEqual(b.title, "Merged")
        XCTAssertFalse(b.isEnabled)
        XCTAssertNil(b.confirmation)
        XCTAssertEqual(b.accessibilityLabel, "Merged")
    }

    func testTheOverlayDoesNotDependOnTheHeadTheAttemptWasMadeAt() throws {
        // A push after the request left does not un-send it: the button stays in the state of the attempt.
        XCTAssertEqual(try XCTUnwrap(button(pr(head: "0bbbbbbb"), attempt: attempt(.merging, head: "0aaaaaaa"))).state, .merging)
        XCTAssertEqual(try XCTUnwrap(button(pr(head: "0bbbbbbb"), attempt: attempt(.merged, head: "0aaaaaaa"))).state, .merged)
    }

    func testAFailedAttemptLeavesTheButtonAsItWouldBeWithoutIt() {
        for code in allCodes {
            XCTAssertEqual(button(pr(), attempt: attempt(.failed(code))), button(pr()), "\(code): the notice is separate")
            let off = pr(draft: true)
            XCTAssertEqual(button(off, attempt: attempt(.failed(code))), button(off), "\(code)")
        }
    }

    func testAnAttemptDoesNotConjureAButtonWhereThereIsNone() {
        for progress in [AuthoredPrMergeProgress.merging, .merged, .failed(.blocked)] {
            XCTAssertNil(button(pr(group: .waiting), attempt: attempt(progress)), "\(progress): not in READY")
            XCTAssertNil(button(pr(lifecycle: .merged), attempt: attempt(progress)),
                         "\(progress): the PR is merged: the row says Merged and has no button")
            XCTAssertNil(button(pr(lifecycle: .closed), attempt: attempt(progress)), "\(progress)")
        }
    }
}

// MARK: - The confirmation

final class AuthoredPrsMergeConfirmationTests: XCTestCase {

    private func confirmation(_ p: AuthoredPr) throws -> AuthoredPrMergeConfirmation {
        try XCTUnwrap(try XCTUnwrap(button(p)).confirmation, "the row is ready")
    }

    func testTheMessageIsExactlyTheOneTheDesignSays() throws {
        let c = try confirmation(pr())
        XCTAssertEqual(c.message, "Squash and merge #458 Fix the thing into main? Head 0123abcd. Perri approved. Human approval: yes. Checks: green.")
        XCTAssertEqual(c.repo, "thehammer/nostromo")
        XCTAssertEqual(c.number, 458)
        XCTAssertEqual(c.expectedHeadShaShort, "0123abcd", "the head the person saw: what the request will carry")
        XCTAssertEqual(c.confirmTitle, "Merge")
        XCTAssertEqual(c.cancelTitle, "Cancel")
    }

    func testTheConfirmationIsAboutThisRowsOwnHead() throws {
        XCTAssertEqual(try confirmation(pr(head: "0aaaaaaa")).expectedHeadShaShort, "0aaaaaaa")
        XCTAssertEqual(try confirmation(pr(head: "0bbbbbbb")).expectedHeadShaShort, "0bbbbbbb")
        XCTAssertTrue(try confirmation(pr(head: "0bbbbbbb")).message.contains("Head 0bbbbbbb."))
        XCTAssertNotEqual(try confirmation(pr(head: "0aaaaaaa")), try confirmation(pr(head: "0bbbbbbb")))
    }

    func testAPrWithNoBaseSaysTheBaseBranch() throws {
        let c = try confirmation(pr(baseRef: nil))
        XCTAssertEqual(c.message, "Squash and merge #458 Fix the thing into the base branch? Head 0123abcd. Perri approved. Human approval: yes. Checks: green.")
    }

    func testAnotherBaseIsNamed() throws {
        let c = try confirmation(pr(baseRef: "release/2026-11"))
        XCTAssertTrue(c.message.contains(" into release/2026-11? "), c.message)
    }

    func testAPrWithNoChecksSaysChecksNone() throws {
        let c = try confirmation(pr(checks: AuthoredPrChecks(state: .none)))
        XCTAssertEqual(c.message, "Squash and merge #458 Fix the thing into main? Head 0123abcd. Perri approved. Human approval: yes. Checks: none.")
    }

    func testTheConfirmationCleansTheTitleOfControlAndBidiCharacters() throws {
        // A newline becomes a space; a bidi override, a zero-width space and a control character go.
        let raw = "Fix\u{202E}\nthe thing\u{7}\u{200B}!\u{0}"
        let c = try confirmation(pr(title: raw))
        XCTAssertEqual(c.message, "Squash and merge #458 Fix the thing! into main? Head 0123abcd. Perri approved. Human approval: yes. Checks: green.")
        for scalar in c.message.unicodeScalars {
            let category = scalar.properties.generalCategory
            XCTAssertFalse(category == .control || category == .format || category == .lineSeparator || category == .paragraphSeparator,
                           "U+\(String(scalar.value, radix: 16)) is in the sentence the person is about to act on")
        }
    }

    func testTheConfirmationTurnsTabsAndCarriageReturnsIntoSpacesAndTrims() throws {
        // `AuthoredPrsText.clean`: a tab, a CR and an LF each become one space; the ends are trimmed.
        let c = try confirmation(pr(title: "  a\tb\rc\r\nd  "))
        XCTAssertTrue(c.message.hasPrefix("Squash and merge #458 a b c  d into main? "), c.message.debugDescription)
        XCTAssertFalse(c.message.unicodeScalars.contains { $0 == "\n" || $0 == "\t" || $0 == "\r" }, c.message.debugDescription)
    }

    func testTheConfirmationCapsALongTitleWithAnEllipsis() throws {
        let c = try confirmation(pr(title: String(repeating: "x", count: 300)))
        let capped = String(repeating: "x", count: 80) + "…"
        XCTAssertEqual(c.message, "Squash and merge #458 \(capped) into main? Head 0123abcd. Perri approved. Human approval: yes. Checks: green.")
        XCTAssertLessThan(c.message.count, 200, "300 characters of someone else's words do not fill the dialog")
    }

    func testATitleOfExactlyTheCapIsNotEllipsised() throws {
        let eighty = String(repeating: "y", count: 80)
        XCTAssertTrue(try confirmation(pr(title: eighty)).message.contains(" \(eighty) into main? "))
        XCTAssertFalse(try confirmation(pr(title: eighty)).message.contains("…"))
        let eightyOne = String(repeating: "y", count: 81)
        XCTAssertTrue(try confirmation(pr(title: eightyOne)).message.contains(" \(eighty)… into main? "))
    }

    func testTheCapIsOnTheCleanedTitleNotTheRawOne() throws {
        // Seventy letters and twenty zero-width spaces: ninety characters raw, seventy once cleaned.
        let title = String(repeating: "z", count: 70) + String(repeating: "\u{200B}", count: 20)
        let c = try confirmation(pr(title: title))
        XCTAssertTrue(c.message.contains(" \(String(repeating: "z", count: 70)) into main? "), c.message)
        XCTAssertFalse(c.message.contains("…"), "nothing was cut, so nothing is marked as cut")
    }

    func testALongTitleWithControlCharactersIsCleanedAndCapped() throws {
        let raw = "\n\u{202E}" + String(repeating: "ab\u{7}", count: 150)
        let c = try confirmation(pr(title: raw))
        XCTAssertTrue(c.message.contains(String(repeating: "ab", count: 40) + "… into main? "), c.message)
        XCTAssertFalse(c.message.contains("\u{202E}") || c.message.contains("\u{7}") || c.message.contains("\n"))
    }

    func testTheConfirmationRemembersTheBaseItNamed() throws {
        XCTAssertEqual(try confirmation(pr(baseRef: "main")).base, "main")
        XCTAssertEqual(try confirmation(pr(baseRef: "release/2026-11")).base, "release/2026-11")
        XCTAssertNil(try confirmation(pr(baseRef: nil)).base, "the sentence says the base branch")
        XCTAssertNotEqual(try confirmation(pr(baseRef: "main")), try confirmation(pr(baseRef: "release")),
                          "a retarget is a different confirmation")
    }

    func testTheMessageNamesThePrByNumberAndNeverTheRepoOrTheUrl() throws {
        let c = try confirmation(pr(77, title: "Seventy-seven"))
        XCTAssertTrue(c.message.hasPrefix("Squash and merge #77 Seventy-seven into main?"), c.message)
        XCTAssertEqual(c.number, 77)
    }
}

// MARK: - The notice an attempt leaves on a row

final class AuthoredPrsMergeNoticeTests: XCTestCase {

    private func notice(_ p: AuthoredPr, _ a: AuthoredPrMergeAttempt?) -> String? {
        AuthoredPrsPresentation.mergeNotice(p, attempt: a)
    }

    func testAFailureShowsItsWordsOnTheRowItWasAbout() {
        for code in allCodes {
            XCTAssertEqual(notice(pr(), attempt(.failed(code))), AuthoredPrsMergeWords.failure(code), "\(code)")
        }
    }

    func testNoNoticeWithoutAFailure() {
        XCTAssertNil(notice(pr(), nil))
        XCTAssertNil(notice(pr(), attempt(.merging)))
        XCTAssertNil(notice(pr(), attempt(.merged)))
    }

    func testNoticeStaysOnlyForTheHeadItWasAbout() {
        // The head changed since: the failure was about another version, so it is not shown.
        for code in allCodes where code != .headChanged {
            XCTAssertNil(notice(pr(head: "0bbbbbbb"), attempt(.failed(code), head: "0aaaaaaa")), "\(code)")
            XCTAssertNil(notice(pr(head: nil), attempt(.failed(code), head: "0aaaaaaa")), "\(code): the head is not known now")
        }
        // The same head: shown.
        XCTAssertNotNil(notice(pr(head: "0aaaaaaa"), attempt(.failed(.blocked), head: "0aaaaaaa")))
    }

    func testHeadChangedIsTheNoticeThatSurvivesAHeadChange() {
        // "The PR changed since you looked" is exactly about the head having changed: it stays through it.
        XCTAssertEqual(notice(pr(head: "0bbbbbbb"), attempt(.failed(.headChanged), head: "0aaaaaaa")),
                       "The PR changed since you looked: review it again")
        XCTAssertEqual(notice(pr(head: nil), attempt(.failed(.headChanged), head: "0aaaaaaa")),
                       "The PR changed since you looked: review it again")
        XCTAssertNotNil(notice(pr(head: "0aaaaaaa"), attempt(.failed(.headChanged), head: "0aaaaaaa")))
    }

    func testNoNoticeOnARowThatIsNoLongerOpen() {
        for lifecycle in [AuthoredPrLifecycle.merged, .closed, .unknown] {
            for code in allCodes {
                XCTAssertNil(notice(pr(lifecycle: lifecycle), attempt(.failed(code))), "\(lifecycle) \(code)")
            }
        }
    }

    func testTheNoticeIsAboutTheRowNotItsGroup() {
        for group in [AuthoredPrGroup.needsYou, .ready, .waiting, .draft] {
            XCTAssertNotNil(notice(pr(group: group), attempt(.failed(.behind))), "\(group)")
        }
    }
}

// MARK: - The words

final class AuthoredPrsMergeFailureWordsTests: XCTestCase {

    func testNoWireCodeIsTheLocalGestureRefusal() {
        for wire in ["gesture_refused", "gestureRefused", "refused", "", "merge_was_refused"] {
            XCTAssertNotEqual(AuthoredPrMergeCode(wire: wire), .gestureRefused, "\(wire): only this app's own refusal is that")
        }
    }

    func testEveryMergeCodeHasItsExactWords() {
        let table: [(AuthoredPrMergeCode, String)] = [
            (.notFound, "This PR is no longer in your list, so it wasn't merged"),
            (.notOpen, "This PR is no longer open, so it wasn't merged"),
            (.draft, "This PR is a draft, so it wasn't merged"),
            (.notApproved, "No human reviewer has approved it, so it wasn't merged"),
            (.checksNotGreen, "Checks aren't green, so it wasn't merged"),
            (.notMergeable, "GitHub says it can't be merged (conflicts?)"),
            (.blocked, "GitHub's branch protection blocked it"),
            (.behind, "The branch is behind its base: update it first"),
            (.headChanged, "The PR changed since you looked: review it again"),
            (.perriNotApproved, "Perri hasn't approved this version"),
            (.perriStale, "Perri approved an older version: it needs a new review"),
            (.tokenCannotMerge, "Your GitHub token cannot merge"),
            (.rateLimited, "GitHub is rate limiting: try again later"),
            (.unreachable, "GitHub or Nostromo isn't reachable: check the PR before trying again"),
            (.busy, "A merge of this PR is already running"),
            (.notPermitted, "Nostromo refused the request"),
            (.gestureRefused, "Merge was refused: use the button"),
            (.unknown, "The merge failed"),
        ]
        XCTAssertEqual(table.count, allCodes.count, "every code is in the table")
        for (code, words) in table {
            XCTAssertEqual(AuthoredPrsMergeWords.failure(code), words, "\(code)")
        }
    }

    func testAnUnknownCodeFromTheDaemonIsTheGenericFailureAndNeverSuccess() {
        let words = AuthoredPrsMergeWords.failure(AuthoredPrMergeCode(wire: "something_new"))
        XCTAssertEqual(words, "The merge failed")
        XCTAssertFalse(words.contains("something_new"), "the daemon's own string is never shown")
    }

    func testNoFailureWordsReadAsASuccess() {
        for code in allCodes {
            let words = AuthoredPrsMergeWords.failure(code)
            XCTAssertFalse(words.hasPrefix("Merged") || words.hasPrefix("Done") || words.hasPrefix("Success"), words)
        }
    }

    func testTheNoticeOnARowIsTheWordsOfTheCodeTheDaemonSent() {
        let table: [(String, String)] = [
            ("perri_stale", "Perri approved an older version: it needs a new review"),
            ("blocked", "GitHub's branch protection blocked it"),
            ("head_changed", "The PR changed since you looked: review it again"),
            ("never_heard_of_it", "The merge failed"),
            ("not_operator_app", "Nostromo refused the request"),
        ]
        for (wire, words) in table {
            let a = attempt(.failed(AuthoredPrMergeCode(wire: wire)))
            XCTAssertEqual(AuthoredPrsPresentation.mergeNotice(pr(), attempt: a), words, wire)
        }
    }
}

// MARK: - The row model

final class AuthoredPrsMergeRowTests: XCTestCase {

    private var baseline: AuthoredPrRowModel { AuthoredPrsPresentation.row(pr(), now: t0) }

    func testTheHeadIsAlwaysCopiedToTheRowModel() {
        for (perri, merge) in [(false, false), (true, false), (false, true), (true, true)] {
            XCTAssertEqual(row(pr(head: "0123abcd"), perri: perri, merge: merge).headShaShort, "0123abcd", "perri:\(perri) merge:\(merge)")
            XCTAssertNil(row(pr(head: nil), perri: perri, merge: merge).headShaShort)
        }
    }

    func testRowHasNoBadgeWithoutPerriAndNoButtonWithoutBothFeatures() {
        let off = row(pr(), perri: false, merge: false)
        XCTAssertNil(off.perriBadge)
        XCTAssertNil(off.mergeButton)
        XCTAssertNil(off.mergeNotice)

        let perriOnly = row(pr(), perri: true, merge: false)
        XCTAssertNotNil(perriOnly.perriBadge, "Perri's verdict is shown whenever the daemon sends it")
        XCTAssertNil(perriOnly.mergeButton, "but there is no Merge verb to press: no dead control")

        let mergeOnly = row(pr(), perri: false, merge: true)
        XCTAssertNil(mergeOnly.perriBadge)
        XCTAssertNil(mergeOnly.mergeButton, "without Perri's verdict on rows the button cannot be judged: none")

        let both = row(pr(), perri: true, merge: true)
        XCTAssertNotNil(both.perriBadge)
        XCTAssertEqual(both.mergeButton?.state, .ready)
    }

    func testTheDefaultsAreTheOldDaemonsRow() {
        let plain = AuthoredPrsPresentation.row(pr(), now: t0)
        XCTAssertNil(plain.perriBadge)
        XCTAssertNil(plain.mergeButton)
        XCTAssertNil(plain.mergeNotice)
        XCTAssertEqual(plain.reviewLine, baseline.reviewLine)
    }

    func testAFailedAttemptShowsAsANoticeOnlyWithBothFeatures() {
        let failed = attempt(.failed(.blocked))
        XCTAssertEqual(row(pr(), attempt: failed).mergeNotice, "GitHub's branch protection blocked it")
        XCTAssertNil(row(pr(), perri: true, merge: false, attempt: failed).mergeNotice)
        XCTAssertNil(row(pr(), perri: false, merge: true, attempt: failed).mergeNotice)
        XCTAssertNil(row(pr(), perri: false, merge: false, attempt: failed).mergeNotice)
    }

    func testTheReviewLineSaysWhyTheButtonIsOffAndOnlyThen() throws {
        let plain = AuthoredPrsPresentation.row(pr(), now: t0).reviewLine
        XCTAssertEqual(plain, "Approved by dana")

        // Off: " · <reason>" at the end, after whatever counts the line already had.
        var off = pr(perri: nil)
        off.newComments = 2
        let base = AuthoredPrsPresentation.row(off, now: t0).reviewLine
        XCTAssertEqual(row(off).reviewLine, base + " · Needs Perri's review")
        XCTAssertEqual(row(off).reviewLine, "Approved by dana · 2 new comments · Needs Perri's review")

        for (_, p, reason) in [("draft", pr(draft: true), "Draft"),
                               ("red", pr(checks: AuthoredPrChecks(state: .failing, failed: 1)), "Checks not green"),
                               ("no human", pr(review: AuthoredPrReview(state: .none)), "Waiting for human approval"),
                               ("older", pr(perri: verdict(.approved, current: false)), "Perri approved an older version"),
                               ("changes", pr(perri: verdict(.changesRequested)), "Perri requested changes")] {
            let b = AuthoredPrsPresentation.row(p, now: t0).reviewLine
            XCTAssertEqual(row(p).reviewLine, "\(b) · \(reason)", reason)
        }

        // Ready, merging, merged and failed: the line is as it always was.
        for a in [nil, attempt(.merging), attempt(.merged), attempt(.failed(.behind))] {
            XCTAssertEqual(row(pr(), attempt: a).reviewLine, plain, "\(String(describing: a))")
        }
        // No button on the row (not READY, or a feature off): no reason either.
        XCTAssertEqual(row(pr(group: .waiting, perri: nil)).reviewLine,
                       AuthoredPrsPresentation.row(pr(group: .waiting, perri: nil), now: t0).reviewLine)
        XCTAssertEqual(row(off, perri: true, merge: false).reviewLine, base)
        XCTAssertEqual(row(off, perri: false, merge: true).reviewLine, base)
    }

    func testTheAccessibilityLabelGainsTheBadgeAndTheNotice() throws {
        let plain = AuthoredPrsPresentation.row(pr(), now: t0).accessibilityLabel
        let withBadge = row(pr()).accessibilityLabel
        XCTAssertEqual(withBadge, plain + ", Perri approved this version")

        let older = row(pr(perri: verdict(.approved, current: false))).accessibilityLabel
        XCTAssertTrue(older.hasSuffix(", Perri approved an older version"), older)

        let withNotice = row(pr(), attempt: attempt(.failed(.perriStale))).accessibilityLabel
        XCTAssertTrue(withNotice.hasPrefix(plain), withNotice)
        XCTAssertTrue(withNotice.contains(", Perri approved this version"), withNotice)
        XCTAssertTrue(withNotice.hasSuffix(", merge failed: Perri approved an older version: it needs a new review"), withNotice)

        // No verdict, no badge, no addition.
        XCTAssertEqual(row(pr(perri: nil)).accessibilityLabel,
                       AuthoredPrsPresentation.row(pr(perri: nil), now: t0).accessibilityLabel)
        // Perri off: nothing added.
        XCTAssertEqual(row(pr(), perri: false, merge: false).accessibilityLabel, plain)
    }

    func testTheHeadStillTheRowsOwnWhateverTheNewestSnapshotIs() {
        // A row built from one head keeps that head: the model never reaches for another.
        let a = row(pr(head: "0aaaaaaa"))
        let b = row(pr(head: "0bbbbbbb"))
        XCTAssertEqual(a.mergeButton?.confirmation?.expectedHeadShaShort, "0aaaaaaa")
        XCTAssertEqual(b.mergeButton?.confirmation?.expectedHeadShaShort, "0bbbbbbb")
        XCTAssertEqual(a.headShaShort, "0aaaaaaa")
    }

    func testAMergedRowHasNoButtonNoNoticeAndItsStatusSaysMerged() {
        let merged = pr(group: .waiting, lifecycle: .merged)
        let m = row(merged, attempt: attempt(.failed(.blocked)))
        XCTAssertNil(m.mergeButton)
        XCTAssertNil(m.mergeNotice)
        XCTAssertEqual(m.statusWord, "Merged")
        XCTAssertNil(m.perriBadge, "a merged PR has no badge")
    }
}

// MARK: - The group models

final class AuthoredPrsMergeGroupsTests: XCTestCase {

    private func shape(_ groups: [AuthoredPrsGroupModel]) -> [String] {
        groups.map { "\($0.group):\($0.rows.map(\.id).joined(separator: ","))" }
    }

    private func rows(_ groups: [AuthoredPrsGroupModel], _ group: AuthoredPrGroup) -> [AuthoredPrRowModel] {
        groups.first { $0.group == group }?.rows ?? []
    }

    func testGroupsThreadTheFeatureFlagsToTheirRows() throws {
        let ready = pr(1), waiting = pr(2, group: .waiting), needs = pr(3, group: .needsYou)
        let prs = [needs, ready, waiting]

        let off = AuthoredPrsPresentation.groups(prs, now: t0, timeZone: utc)
        XCTAssertTrue(off.flatMap(\.rows).allSatisfy { $0.mergeButton == nil && $0.perriBadge == nil }, "the defaults add nothing")

        let perriOnly = AuthoredPrsPresentation.groups(prs, now: t0, timeZone: utc, perri: true, merge: false)
        XCTAssertTrue(perriOnly.flatMap(\.rows).allSatisfy { $0.perriBadge != nil })
        XCTAssertTrue(perriOnly.flatMap(\.rows).allSatisfy { $0.mergeButton == nil }, "no Merge verb: no button")

        let mergeOnly = AuthoredPrsPresentation.groups(prs, now: t0, timeZone: utc, perri: false, merge: true)
        XCTAssertTrue(mergeOnly.flatMap(\.rows).allSatisfy { $0.mergeButton == nil && $0.perriBadge == nil })

        let both = AuthoredPrsPresentation.groups(prs, now: t0, timeZone: utc, perri: true, merge: true)
        XCTAssertEqual(rows(both, .ready).first?.mergeButton?.state, .ready)
        XCTAssertNil(rows(both, .waiting).first?.mergeButton, "only READY rows get the button")
        XCTAssertNil(rows(both, .needsYou).first?.mergeButton)
        XCTAssertNotNil(rows(both, .waiting).first?.perriBadge, "the badge is for every open row")
    }

    func testGroupsThreadEachRowsOwnAttemptKeyedByItsId() throws {
        let a = pr(1), b = pr(2), c = pr(3)
        let attempts: [String: AuthoredPrMergeAttempt] = [
            a.id: attempt(.merging),
            b.id: attempt(.failed(.behind)),
            "thehammer/nostromo#999": attempt(.merged),
        ]
        let groups = AuthoredPrsPresentation.groups([a, b, c], now: t0, timeZone: utc, perri: true, merge: true,
                                                    mergeAttempts: attempts)
        let ready = rows(groups, .ready)
        XCTAssertEqual(ready.map(\.id), [a.id, b.id, c.id])
        XCTAssertEqual(ready[0].mergeButton?.state, .merging)
        XCTAssertNil(ready[0].mergeNotice)
        XCTAssertEqual(ready[1].mergeButton?.state, .ready, "a failed attempt leaves the button")
        XCTAssertEqual(ready[1].mergeNotice, "The branch is behind its base: update it first")
        XCTAssertEqual(ready[2].mergeButton?.state, .ready, "no attempt for this one")
        XCTAssertNil(ready[2].mergeNotice)
    }

    func testAttemptsAreIgnoredWithoutBothFeatures() {
        let a = pr(1)
        let attempts = [a.id: attempt(.failed(.blocked))]
        for (perri, merge) in [(false, false), (true, false), (false, true)] {
            let groups = AuthoredPrsPresentation.groups([a], now: t0, timeZone: utc, perri: perri, merge: merge, mergeAttempts: attempts)
            XCTAssertNil(groups.first?.rows.first?.mergeNotice, "perri:\(perri) merge:\(merge)")
            XCTAssertNil(groups.first?.rows.first?.mergeButton)
        }
    }

    func testAnAttemptNeverMovesARowBetweenGroups() {
        // The group is the daemon's. An attempt, a success included, changes what the row says, never where it is.
        let prs = [pr(1), pr(2), pr(3, group: .waiting), pr(4, group: .needsYou)]
        let before = shape(AuthoredPrsPresentation.groups(prs, now: t0, timeZone: utc, perri: true, merge: true))
        XCTAssertEqual(before.count, 3, "precondition: three groups")
        for progress in [AuthoredPrMergeProgress.merging, .merged, .failed(.notOpen), .failed(.unknown)] {
            let attempts = Dictionary(uniqueKeysWithValues: prs.map { ($0.id, attempt(progress)) })
            let after = shape(AuthoredPrsPresentation.groups(prs, now: t0, timeZone: utc, perri: true, merge: true,
                                                             mergeAttempts: attempts))
            XCTAssertEqual(after, before, "\(progress)")
        }
    }

    func testAMergedAttemptIsKeptWhileTheSnapshotStillSaysOpenAndEndsWhenItSaysMerged() {
        let open = pr(1)
        let attempts = [open.id: attempt(.merged)]
        let still = AuthoredPrsPresentation.groups([open], now: t0, timeZone: utc, perri: true, merge: true, mergeAttempts: attempts)
        XCTAssertEqual(still.first?.rows.first?.mergeButton?.state, .merged, "Merged is kept until a snapshot says otherwise")
        XCTAssertEqual(still.first?.group, .ready, "and the row has not moved")

        var done = open
        done.lifecycle = .merged
        done.group = .waiting
        let after = AuthoredPrsPresentation.groups([done], now: t0, timeZone: utc, perri: true, merge: true, mergeAttempts: attempts)
        XCTAssertNil(after.first?.rows.first?.mergeButton, "the lifecycle left open: the real Merged status takes over")
        XCTAssertEqual(after.first?.rows.first?.statusWord, "Merged")
    }

    func testTheFlagsAndAttemptsDoNotChangeWhatTheGroupsAreOrHowManyRowsTheyHave() {
        let prs = (1...30).map { pr($0) } + [pr(100, group: .needsYou)]
        let plain = AuthoredPrsPresentation.groups(prs, now: t0, timeZone: utc)
        let merged = AuthoredPrsPresentation.groups(prs, now: t0, timeZone: utc, perri: true, merge: true,
                                                    mergeAttempts: [prs[0].id: attempt(.merging)])
        XCTAssertEqual(plain.map(\.group), merged.map(\.group))
        XCTAssertEqual(plain.map(\.count), merged.map(\.count))
        XCTAssertEqual(plain.map(\.hiddenCount), merged.map(\.hiddenCount))
        XCTAssertEqual(plain.map { $0.rows.map(\.id) }, merged.map { $0.rows.map(\.id) })
    }
}


// MARK: - Who recorded the verdict

/// The daemon writes `by` as `<agent>:<tag>` and any registered focus may record a verdict, so "Perri" is said
/// only when the agent part is exactly `perri`. Hostile values go through the real decoder in
/// AuthoredPrsHostileRecorderTests (AuthoredPrsMergeTests.swift).
final class AuthoredPrsRecorderTests: XCTestCase {

    private let unknownBadge = "Perri ✓ (recorder unknown)"
    private let unknownLabel = "Approval of this version, recorder unknown"
    private let unknownSentence = "Approval recorder unknown, not confirmed as Perri."

    private func message(_ perri: AuthoredPrPerri?) throws -> String {
        try XCTUnwrap(try XCTUnwrap(button(pr(perri: perri))).confirmation, "the row is ready").message
    }

    private func assertNoInvisibleScalars(_ text: String, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        for scalar in text.unicodeScalars {
            let category = scalar.properties.generalCategory
            XCTAssertFalse(category == .control || category == .format || category == .lineSeparator || category == .paragraphSeparator,
                           "\(what): U+\(String(scalar.value, radix: 16)) in \(text.debugDescription)", file: file, line: line)
        }
    }

    // perri

    func testAVerdictRecordedByPerriKeepsEveryBadgeLabelAndTheShortConfirmation() throws {
        for by in ["perri:cody-pr-1", "perri:x", "perri:a:b"] {
            XCTAssertEqual(try XCTUnwrap(badge(pr(perri: verdict(.approved, by: by)))).text, "Perri ✓", by)
            XCTAssertEqual(try XCTUnwrap(badge(pr(perri: verdict(.approved, by: by)))).accessibilityLabel,
                           "Perri approved this version", by)
            XCTAssertEqual(try XCTUnwrap(badge(pr(perri: verdict(.approved, current: false, by: by)))).text, "Perri ✓ older", by)
            XCTAssertEqual(try XCTUnwrap(badge(pr(perri: verdict(.changesRequested, by: by)))).text, "Perri ✗", by)
            XCTAssertEqual(try XCTUnwrap(badge(pr(perri: verdict(.comment, by: by)))).text, "Perri comments", by)
            XCTAssertEqual(try message(verdict(.approved, by: by)),
                           "Squash and merge #458 Fix the thing into main? Head 0123abcd. Perri approved. Human approval: yes. Checks: green.", by)
        }
    }

    // another agent

    func testAnApprovalRecordedByCodyIsBadgedSpokenAndConfirmedAsCodysNotPerris() throws {
        let b = try XCTUnwrap(badge(pr(perri: verdict(.approved, by: "cody:focus-x"))))
        XCTAssertEqual(b.kind, .approved)
        XCTAssertEqual(b.text, "Perri ✓ (by cody)")
        XCTAssertEqual(b.accessibilityLabel, "Approval of this version recorded by cody, not by Perri")
        XCTAssertEqual(b.tooltip, "Approved 5m ago by cody:focus-x · head 0123abcd")
        XCTAssertEqual(try message(verdict(.approved, by: "cody:focus-x")),
                       "Squash and merge #458 Fix the thing into main? Head 0123abcd. Approval recorded by cody:focus-x, not by Perri. Human approval: yes. Checks: green.")
    }

    func testEveryKindOfBadgeNamesAnotherRecorderAndNeverSpeaksAsPerri() throws {
        let cases: [(AuthoredPrPerri, AuthoredPrPerriBadge.Kind, String)] = [
            (verdict(.approved, by: "cody:focus-x"), .approved, "Perri ✓ (by cody)"),
            (verdict(.approved, current: false, by: "cody:focus-x"), .olderApproval, "Perri ✓ older (by cody)"),
            (verdict(.changesRequested, by: "cody:focus-x"), .changesRequested, "Perri ✗ (by cody)"),
            (verdict(.comment, by: "cody:focus-x"), .comments, "Perri comments (by cody)"),
        ]
        for (perri, kind, text) in cases {
            let b = try XCTUnwrap(badge(pr(perri: perri)), text)
            XCTAssertEqual(b.kind, kind, text)
            XCTAssertEqual(b.text, text)
            XCTAssertTrue(b.accessibilityLabel.contains("cody"), b.accessibilityLabel)
            XCTAssertTrue(b.accessibilityLabel.hasSuffix("recorded by cody, not by Perri"), b.accessibilityLabel)
            XCTAssertFalse(b.accessibilityLabel.hasPrefix("Perri "), "the spoken words must not begin as Perri's: \(b.accessibilityLabel)")
        }
    }

    func testAnOlderApprovalRecordedByCodyIsStillMutedAndSaysOlder() throws {
        let b = try XCTUnwrap(badge(pr(perri: verdict(.approved, current: false, by: "cody:focus-x"))))
        XCTAssertTrue(b.isMuted)
        XCTAssertTrue(b.accessibilityLabel.contains("older version"), b.accessibilityLabel)
        XCTAssertTrue(b.tooltip.contains("A new push needs a new review."), b.tooltip)
    }

    func testTheAgentNameIsMatchedExactlySoAnotherCaseOrALongerNameIsNotPerri() throws {
        for by in ["Perri:x", "PERRI:x", "perri2:x", "perri.x:y", "xperri:y", "perri_:y"] {
            let b = try XCTUnwrap(badge(pr(perri: verdict(.approved, by: by))), by)
            XCTAssertTrue(b.text.hasPrefix("Perri ✓ (by "), "\(by): \(b.text)")
            XCTAssertFalse(b.accessibilityLabel.hasPrefix("Perri approved"), "\(by): \(b.accessibilityLabel)")
            XCTAssertFalse(try message(verdict(.approved, by: by)).contains("Perri approved."), by)
        }
    }

    func testALongAgentNameIsCutInTheBadgeWithAnEllipsisButKeptInTheConfirmation() throws {
        let agent = String(repeating: "a", count: 30)
        let b = try XCTUnwrap(badge(pr(perri: verdict(.approved, by: "\(agent):t"))))
        XCTAssertEqual(b.text, "Perri ✓ (by \(String(repeating: "a", count: 16))…)")
        XCTAssertTrue(try message(verdict(.approved, by: "\(agent):t")).contains("Approval recorded by \(agent):t, not by Perri."))
        // 40 is the longest name read as a name.
        let edge = String(repeating: "b", count: 40)
        XCTAssertTrue(try XCTUnwrap(badge(pr(perri: verdict(.approved, by: "\(edge):t")))).text.hasPrefix("Perri ✓ (by "))
        XCTAssertEqual(try XCTUnwrap(badge(pr(perri: verdict(.approved, by: "\(edge)b:t")))).text, unknownBadge, "41 is not a name")
    }

    func testTheConfirmationCapsAVeryLongRecorderAndStaysBounded() throws {
        let by = "cody:" + String(repeating: "x", count: 500)
        let m = try message(verdict(.approved, by: by))
        XCTAssertTrue(m.contains("Approval recorded by cody:" + String(repeating: "x", count: 55) + "…, not by Perri."), m)
        XCTAssertLessThan(m.count, 300, "a recorder's name cannot swell the sentence the person acts on")
        let b = try XCTUnwrap(badge(pr(perri: verdict(.approved, by: by))))
        XCTAssertEqual(b.text, "Perri ✓ (by cody)")
    }

    // unknown

    func testAValueThatIsNotAgentColonTagIsRecorderUnknownEverywhere() throws {
        for by in ["perri-1", "perri", "perri:", ":tag", ":", "", "no colon at all", "a b:tag", "pérri:x", "cody/x:y",
                   "cody :x", String(repeating: "a", count: 41) + ":t"] {
            let b = try XCTUnwrap(badge(pr(perri: verdict(.approved, by: by))), by)
            XCTAssertEqual(b.text, unknownBadge, by.debugDescription)
            XCTAssertEqual(b.accessibilityLabel, unknownLabel, by.debugDescription)
            XCTAssertEqual(try message(verdict(.approved, by: by)),
                           "Squash and merge #458 Fix the thing into main? Head 0123abcd. \(unknownSentence) Human approval: yes. Checks: green.",
                           by.debugDescription)
        }
    }

    func testAnAbsentRecorderIsRecorderUnknownEverywhereAndTheTooltipSaysSo() throws {
        let b = try XCTUnwrap(badge(pr(perri: verdict(.approved, by: nil))))
        XCTAssertEqual(b.text, unknownBadge)
        XCTAssertEqual(b.accessibilityLabel, unknownLabel)
        XCTAssertEqual(b.tooltip, "Approved 5m ago (recorder unknown) · head 0123abcd")
        XCTAssertEqual(try message(verdict(.approved, by: nil)),
                       "Squash and merge #458 Fix the thing into main? Head 0123abcd. \(unknownSentence) Human approval: yes. Checks: green.")
    }

    func testEveryKindOfBadgeSaysRecorderUnknownWhenNobodyIsNamed() throws {
        let cases: [(AuthoredPrPerri, String)] = [
            (verdict(.approved, by: nil), "Perri ✓ (recorder unknown)"),
            (verdict(.approved, current: false, by: "perri-1"), "Perri ✓ older (recorder unknown)"),
            (verdict(.changesRequested, by: "perri"), "Perri ✗ (recorder unknown)"),
            (verdict(.comment, by: nil), "Perri comments (recorder unknown)"),
        ]
        for (perri, text) in cases {
            let b = try XCTUnwrap(badge(pr(perri: perri)), text)
            XCTAssertEqual(b.text, text)
            XCTAssertTrue(b.accessibilityLabel.hasSuffix(", recorder unknown"), b.accessibilityLabel)
            XCTAssertFalse(b.accessibilityLabel.hasPrefix("Perri "), b.accessibilityLabel)
        }
    }

    func testAPresentRecorderStillShowsInTheTooltipAsItAlwaysDid() throws {
        XCTAssertTrue(try XCTUnwrap(badge(pr(perri: verdict(.approved, by: "perri-1")))).tooltip.contains(" by perri-1"))
    }

    func testNothingInvisibleReachesTheBadgeLabelOrSentenceForBenignRecorders() throws {
        for by in ["perri:cody-pr-1", "cody:focus-x", "perri-1", nil] {
            let b = try XCTUnwrap(badge(pr(perri: verdict(.approved, by: by))))
            assertNoInvisibleScalars(b.text, "text")
            assertNoInvisibleScalars(b.accessibilityLabel, "label")
            assertNoInvisibleScalars(try message(verdict(.approved, by: by)), "confirmation")
        }
    }
}
