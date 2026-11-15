// NostromoKit — AuthoredPrsHandoffTests.swift
//
// The hand-off half of "My open PRs" (feature `authored_prs_notify_v1`): the wire verbs (preview, notify,
// start session, link), the words for every failure code, the button each fixable row gets, the picker's
// entries, the "needs you" reason and the producer that raises one waiting pill per PR the daemon marks.
//
// The goldens under `tests/fixtures/authored_prs/` are written by the daemon's own Rust types. Reading and
// writing them here keeps the Kit honest about what the daemon really sends and expects.
//
// Mutations this file is meant to catch:
//   1. Encode a preview target as a bare string, or send `"tag": null` on unlink
//        -> testPreviewRequestEncodesLikeTheGolden..., testUnlinkOmitsTheTag
//   2. A failure code worded as the generic fallback, or the daemon's `changed` not recognised
//        -> testEveryFailureCodeHasItsOwnWords
//   3. A Tell button on a draft, on a non-Needs-you row or on a row with nothing to fix
//        -> testNoButtonOn...
//   4. The ambiguous picker offering a closed candidate, or the unknown picker not putting the repo's focuses first
//        -> testAmbiguousPicker..., testUnknownPicker...
//   5. The producer raising a pill the daemon did not mark, or on a draft / ambiguous / closed / unknown owner
//        -> testProducer...

import XCTest
@testable import NostromoKit

// MARK: - Helpers

private func iso(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

/// The golden snapshot's own generated_at.
private let now = iso("2026-11-14T12:00:00Z")

private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // NostromoKitTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // NostromoKit
        .deletingLastPathComponent()   // Shared
        .deletingLastPathComponent()   // <repo>
        .appendingPathComponent("tests/fixtures/authored_prs/\(name)")
}

private func fixture(_ name: String) throws -> Data { try Data(contentsOf: fixtureURL(name)) }

private func jsonObject(_ data: Data) throws -> NSDictionary {
    try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
}

private func assertEncodes<M: Encodable>(_ message: M, like golden: String,
                                         file: StaticString = #filePath, line: UInt = #line) throws {
    let encoded = try jsonObject(try JSONEncoder().encode(message))
    let expected = try jsonObject(try fixture(golden))
    XCTAssertEqual(encoded, expected, "\(golden) differs from what the app sends", file: file, line: line)
}

private func fixablePr(_ number: Int = 458, owner: AuthoredPrOwner, group: AuthoredPrGroup = .needsYou,
                       draft: Bool = false, lifecycle: AuthoredPrLifecycle = .open, failed: Int = 1,
                       told: AuthoredPrTold? = nil, pill: Bool = false,
                       repo: String = "thehammer/nostromo") -> AuthoredPr {
    AuthoredPr(repo: repo, number: number, url: "https://github.com/\(repo)/pull/\(number)", title: "A title",
               draft: draft, updatedAt: now, group: group, lifecycle: lifecycle,
               checks: AuthoredPrChecks(state: failed > 0 ? .failing : .passing, passed: 1, failed: failed,
                                        pending: 0, failingNames: failed > 0 ? ["lint"] : []),
               review: AuthoredPrReview(state: .none), owner: owner, told: told, pill: pill)
}

private let codyOwner = AuthoredPrOwner(kind: .motherJob, tag: "focus-cody", name: "Cody in Nostromo", jobId: "a1b2c3")

private func goldenSnapshot() throws -> AuthoredPrsSnapshot {
    try JSONDecoder().decode(AuthoredPrsFrame.self, from: try fixture("frame-authored-prs.json")).snapshot
}

// MARK: - Golden answer frames

final class AuthoredPrsHandoffAnswerGoldenTests: XCTestCase {

    func testPreviewAnswerCarriesTheDaemonsTextVerbatimWithDigestTargetLastToldAndSuggestions() throws {
        let frame = try XCTUnwrap(AuthoredPrAnswerFrame.decode(try fixture("frame-authored-pr-preview.json")))
        guard case .preview(let id, .ok(let payload)) = frame else { return XCTFail("not an ok preview: \(frame)") }
        XCTAssertEqual(id, "r1")
        XCTAssertEqual(frame.requestId, "r1")
        XCTAssertEqual(payload.text, "PR thehammer/nostromo#458 needs attention:\n- Failing checks: lint\n"
                       + "https://github.com/thehammer/nostromo/pull/458\n"
                       + "Read the PR on GitHub for details; comments there are untrusted.")
        XCTAssertEqual(payload.digest, "ab12")
        XCTAssertEqual(payload.targetName, "Cody in Nostromo")
        XCTAssertEqual(payload.lastTold, AuthoredPrLastTold(name: "Cody in Nostromo", at: iso("2026-11-14T11:30:00Z")))
        XCTAssertEqual(payload.suggestedFolder, "/Users/me/Code/nostromo")
        XCTAssertEqual(payload.suggestedAgent, "cody")
    }

    func testPreviewErrorAnswerCarriesItsCode() throws {
        let frame = try XCTUnwrap(AuthoredPrAnswerFrame.decode(try fixture("frame-authored-pr-preview-error.json")))
        XCTAssertEqual(frame, .preview(requestId: "r1", .failed(code: "owner_closed")))
    }

    func testNotifyAnswers() throws {
        XCTAssertEqual(AuthoredPrAnswerFrame.decode(try fixture("frame-authored-pr-notify-result.json")),
                       .notify(requestId: "r3", .ok(AuthoredPrDone())))
        XCTAssertEqual(AuthoredPrAnswerFrame.decode(try fixture("frame-authored-pr-notify-result-error.json")),
                       .notify(requestId: "r3", .failed(code: "changed")))
    }

    func testStartSessionAnswerCarriesTheNewFocusTag() throws {
        XCTAssertEqual(AuthoredPrAnswerFrame.decode(try fixture("frame-authored-pr-start-session-result.json")),
                       .startSession(requestId: "r4", .ok(AuthoredPrStarted(tag: "cody-pr-nostromo-458"))))
    }

    func testLinkAnswer() throws {
        XCTAssertEqual(AuthoredPrAnswerFrame.decode(try fixture("frame-authored-pr-link-result.json")),
                       .link(requestId: "r5", .ok(AuthoredPrDone())))
    }

    func testAFrameThatIsNotAnAnswerOrDoesNotParseIsNil() throws {
        XCTAssertNil(AuthoredPrAnswerFrame.decode(try fixture("frame-authored-prs.json")))
        XCTAssertNil(AuthoredPrAnswerFrame.decode(Data("not json".utf8)))
        XCTAssertNil(AuthoredPrAnswerFrame.decode(Data(#"{"type":"authored_pr_notify_result","request_id":"r9"}"#.utf8)))
    }

    func testAnErrorWithNoCodeStillFailsRatherThanSucceeding() throws {
        let data = Data(#"{"type":"authored_pr_link_result","request_id":"r9","result":{"status":"err","value":{}}}"#.utf8)
        guard case .link("r9", .failed) = try XCTUnwrap(AuthoredPrAnswerFrame.decode(data)) else {
            return XCTFail("an err status must never decode as ok")
        }
    }

    func testAPreviewWithoutLastToldOrSuggestionsDecodes() throws {
        let data = Data(#"{"type":"authored_pr_preview","request_id":"r7","result":{"status":"ok","value":{"text":"hi","digest":"d"}}}"#.utf8)
        guard case .preview("r7", .ok(let payload)) = try XCTUnwrap(AuthoredPrAnswerFrame.decode(data)) else {
            return XCTFail("did not decode")
        }
        XCTAssertEqual(payload.text, "hi")
        XCTAssertNil(payload.lastTold)
        XCTAssertNil(payload.suggestedFolder)
        XCTAssertNil(payload.suggestedAgent)
    }
}

// MARK: - Golden requests

final class AuthoredPrsHandoffRequestGoldenTests: XCTestCase {

    func testPreviewRequestForAFocusEncodesLikeTheGoldenWithTheTagAsTarget() throws {
        try assertEncodes(ClientAuthoredPrPreviewRequest(requestId: "r1", repo: "thehammer/nostromo", number: 458,
                                                         target: .focus(tag: "focus-nostromo")),
                          like: "frame-authored-pr-preview-request.json")
    }

    func testPreviewRequestForANewSessionEncodesLikeTheGoldenWithNewSessionTrue() throws {
        try assertEncodes(ClientAuthoredPrPreviewRequest(requestId: "r2", repo: "thehammer/nostromo", number: 458,
                                                         target: .newSession),
                          like: "frame-authored-pr-preview-request-new-session.json")
    }

    func testNotifyEncodesLikeTheGolden() throws {
        try assertEncodes(ClientAuthoredPrNotify(requestId: "r3", repo: "thehammer/nostromo", number: 458,
                                                 tag: "focus-nostromo", digest: "ab12"),
                          like: "frame-authored-pr-notify.json")
    }

    func testStartSessionEncodesLikeTheGolden() throws {
        try assertEncodes(ClientAuthoredPrStartSession(requestId: "r4", repo: "thehammer/nostromo", number: 458,
                                                       folder: "/Users/me/Code/nostromo", agent: "cody", digest: "ab12"),
                          like: "frame-authored-pr-start-session.json")
    }

    func testLinkEncodesLikeTheGolden() throws {
        try assertEncodes(ClientAuthoredPrLink(requestId: "r5", repo: "thehammer/nostromo", number: 458,
                                               tag: "focus-nostromo"),
                          like: "frame-authored-pr-link.json")
    }

    func testUnlinkOmitsTheTag() throws {
        let message = ClientAuthoredPrLink(requestId: "r6", repo: "thehammer/nostromo", number: 458, tag: nil)
        try assertEncodes(message, like: "frame-authored-pr-unlink.json")
        let encoded = try jsonObject(try JSONEncoder().encode(message))
        XCTAssertNil(encoded["tag"], "unlink must not send a tag at all, not even null")
    }
}

// MARK: - The snapshot's new fields

final class AuthoredPrsHandoffSnapshotTests: XCTestCase {

    func testToldDecodesOnTheReadyRowAndPillOnTheNeedsYouRow() throws {
        let s = try goldenSnapshot()
        let needsYou = try XCTUnwrap(s.prs.first { $0.number == 101 })
        XCTAssertTrue(needsYou.pill)
        XCTAssertNil(needsYou.told)

        let ready = try XCTUnwrap(s.prs.first { $0.number == 202 })
        XCTAssertEqual(ready.told, AuthoredPrTold(tag: "focus-nostromo", name: "Nostromo daemon",
                                                  at: iso("2026-11-14T11:30:00Z")))
        XCTAssertFalse(ready.pill)
    }

    func testEveryOtherGoldenRowHasNoToldAndNoPill() throws {
        for pr in try goldenSnapshot().prs where pr.number != 101 && pr.number != 202 {
            XCTAssertNil(pr.told, "PR #\(pr.number)")
            XCTAssertFalse(pr.pill, "PR #\(pr.number)")
        }
    }

    func testCandidatesCarryHowTheyWereFound() throws {
        let ambiguous = try XCTUnwrap(try goldenSnapshot().prs.first { $0.number == 404 })
        XCTAssertEqual(ambiguous.owner.candidates.map(\.via), [.motherJob, .onBranch])
    }

    func testAnUnknownViaIsLenient() throws {
        let data = Data("""
        {"type":"authored_prs","snapshot":{"prs":[{"repo":"o/r","number":1,"title":"T","group":"needs_you","lifecycle":"open",
        "owner":{"kind":"ambiguous","candidates":[{"tag":"a","name":"A","via":"telepathy"}]}}]}}
        """.utf8)
        let s = try JSONDecoder().decode(AuthoredPrsFrame.self, from: data).snapshot
        XCTAssertEqual(s.prs.first?.owner.candidates.first?.via, .unknown)
    }

    func testAnOlderDaemonsRowWithoutToldOrPillDecodesWithNilAndFalse() throws {
        let data = Data("""
        {"type":"authored_prs","snapshot":{"prs":[{"repo":"o/r","number":1,"title":"T","group":"needs_you","lifecycle":"open",
        "owner":{"kind":"linked","tag":"t","name":"N"}}]}}
        """.utf8)
        let pr = try XCTUnwrap(try JSONDecoder().decode(AuthoredPrsFrame.self, from: data).snapshot.prs.first)
        XCTAssertNil(pr.told)
        XCTAssertFalse(pr.pill)
    }
}

// MARK: - Failure words

final class AuthoredPrsHandoffWordsTests: XCTestCase {

    func testEveryFailureCodeHasItsOwnWords() {
        let expected: [String: String] = [
            "unknown_pr": "Couldn't send: this PR is no longer in the list",
            "nothing_to_fix": "Couldn't send: nothing on this PR needs fixing now",
            "owner_closed": "That focus is closed",
            "unknown_focus": "Couldn't send: that focus isn't open",
            "not_running": "Couldn't send: that focus's session isn't running",
            "bad_folder": "Couldn't start: choose an existing folder",
            "unknown_agent": "Couldn't start: that agent isn't available",
            "already_open": "Couldn't start: a session for this PR is already open",
            "start_failed": "Couldn't start the session",
            "not_operator_app": "Couldn't send: Nostromo refused the request",
            "requires_secure_connection": "Couldn't send: Nostromo refused the request",
            "unavailable": "Couldn't send: this Nostromo can't hand PRs off",
            "changed": "The PR changed; check the message again",
        ]
        for (code, words) in expected {
            XCTAssertEqual(AuthoredPrsHandoffWords.failure(code: code), words, code)
        }
    }

    func testAnUnknownCodeIsNamedRatherThanHidden() {
        XCTAssertEqual(AuthoredPrsHandoffWords.failure(code: "weird"), "Couldn't send (weird)")
    }

    func testUnreachableAndChangedConstants() {
        XCTAssertEqual(AuthoredPrsHandoffWords.unreachable, "Couldn't send: Nostromo isn't reachable")
        XCTAssertEqual(AuthoredPrsHandoffWords.changed, "The PR changed; check the message again")
    }

    func testTheFeatureFlagIsTheDaemonsName() {
        XCTAssertEqual(authoredPrsNotifyFeature, "authored_prs_notify_v1")
    }
}

// MARK: - The button on a row

final class AuthoredPrsTellButtonModelTests: XCTestCase {

    private func button(_ pr: AuthoredPr) -> AuthoredPrTellButton? {
        AuthoredPrsPresentation.row(pr, now: now, handoff: true).tellButton
    }

    func testAMotherJobOwnerWithATagIsToldByItsFirstName() throws {
        let b = try XCTUnwrap(button(fixablePr(owner: codyOwner)))
        XCTAssertEqual(b.title, "Tell Cody")
        XCTAssertEqual(b.action, .tell(tag: "focus-cody"))
        XCTAssertEqual(b.accessibilityLabel, "Tell Cody about PR 458")
    }

    func testALinkedOwnerWithATagIsToldByItsFirstName() throws {
        let b = try XCTUnwrap(button(fixablePr(owner: AuthoredPrOwner(kind: .linked, tag: "focus-n", name: "Nostromo daemon"))))
        XCTAssertEqual(b.title, "Tell Nostromo")
        XCTAssertEqual(b.action, .tell(tag: "focus-n"))
    }

    func testAnOnBranchOwnerWithATagIsToldByItsFirstName() throws {
        let b = try XCTUnwrap(button(fixablePr(owner: AuthoredPrOwner(kind: .onBranch, tag: "focus-w", name: "Widgets"))))
        XCTAssertEqual(b.title, "Tell Widgets")
        XCTAssertEqual(b.action, .tell(tag: "focus-w"))
    }

    func testAnAmbiguousOwnerChoosesAFocus() throws {
        let owner = AuthoredPrOwner(kind: .ambiguous, candidates: [AuthoredPrCandidate(tag: "a", name: "A")])
        let b = try XCTUnwrap(button(fixablePr(owner: owner)))
        XCTAssertEqual(b.title, "Choose focus…")
        XCTAssertEqual(b.action, .choose)
        XCTAssertEqual(b.accessibilityLabel, "Choose focus for PR 458")
    }

    func testAnUnknownOwnerChoosesAFocus() throws {
        let b = try XCTUnwrap(button(fixablePr(owner: .unknown)))
        XCTAssertEqual(b.title, "Choose focus…")
        XCTAssertEqual(b.action, .choose)
    }

    func testAClosedOwnerStartsASession() throws {
        let b = try XCTUnwrap(button(fixablePr(owner: AuthoredPrOwner(kind: .closed, tag: "gone", name: "Gone"))))
        XCTAssertEqual(b.title, "Start a session…")
        XCTAssertEqual(b.action, .start)
        XCTAssertEqual(b.accessibilityLabel, "Start a session for PR 458")
    }

    func testNoButtonOnADraft() {
        XCTAssertNil(button(fixablePr(owner: codyOwner, group: .draft, draft: true)))
    }

    func testNoButtonOutsideNeedsYou() {
        XCTAssertNil(button(fixablePr(owner: codyOwner, group: .ready)))
        XCTAssertNil(button(fixablePr(owner: codyOwner, group: .waiting)))
    }

    func testNoButtonWhenThereIsNothingToFix() {
        XCTAssertNil(button(fixablePr(owner: codyOwner, failed: 0)))
    }

    func testNoButtonOnAMergedPr() {
        XCTAssertNil(button(fixablePr(owner: codyOwner, lifecycle: .merged)))
    }

    func testChangesRequestedCommentsAndThreadsAreEachSomethingToFix() throws {
        func pr(_ configure: (inout AuthoredPr) -> Void) -> AuthoredPr {
            var p = fixablePr(owner: codyOwner, failed: 0)
            configure(&p)
            return p
        }
        XCTAssertNotNil(button(pr { $0.review = AuthoredPrReview(state: .changesRequested) }))
        XCTAssertNotNil(button(pr { $0.newComments = 1 }))
        XCTAssertNotNil(button(pr { $0.unresolvedThreads = 1 }))
    }

    func testARowBuiltWithoutHandoffHasNoButtonAndNoToldText() {
        let told = AuthoredPrTold(tag: "focus-cody", name: "Cody in Nostromo", at: now.addingTimeInterval(-60))
        let row = AuthoredPrsPresentation.row(fixablePr(owner: codyOwner, told: told), now: now)
        XCTAssertNil(row.tellButton)
        XCTAssertNil(row.toldText)
        XCTAssertFalse(row.accessibilityLabel.contains("Told"))
    }

    func testARowWithHandoffSaysWhoWasToldAndWhenAndVoiceOverHearsIt() {
        let told = AuthoredPrTold(tag: "focus-cody", name: "Cody in Nostromo", at: now.addingTimeInterval(-60))
        let row = AuthoredPrsPresentation.row(fixablePr(owner: codyOwner, told: told), now: now, handoff: true)
        XCTAssertEqual(row.toldText, "Told Cody 1m ago")
        XCTAssertTrue(row.accessibilityLabel.hasSuffix(", Told Cody 1m ago"))
    }

    func testToldTextIsNilWhenNobodyWasTold() {
        XCTAssertNil(AuthoredPrsPresentation.toldText(nil, now: now))
        XCTAssertNil(AuthoredPrsPresentation.row(fixablePr(owner: codyOwner), now: now, handoff: true).toldText)
    }

    func testToldTextUsesTheFirstWordOfTheName() {
        let told = AuthoredPrTold(tag: "t", name: "Cody in Nostromo", at: now.addingTimeInterval(-59 * 60))
        XCTAssertEqual(AuthoredPrsPresentation.toldText(told, now: now), "Told Cody 59m ago")
    }

    func testGroupsPassHandoffThroughToTheirRows() throws {
        let prs = [fixablePr(owner: codyOwner)]
        let off = AuthoredPrsPresentation.groups(prs, now: now, timeZone: TimeZone(identifier: "America/Chicago")!)
        let on = AuthoredPrsPresentation.groups(prs, now: now, timeZone: TimeZone(identifier: "America/Chicago")!, handoff: true)
        XCTAssertNil(off.first?.rows.first?.tellButton)
        XCTAssertEqual(on.first?.rows.first?.tellButton?.title, "Tell Cody")
    }

    func testLastToldLine() {
        XCTAssertEqual(AuthoredPrsPresentation.lastToldLine(nil, now: now), "Last told: never")
        XCTAssertEqual(AuthoredPrsPresentation.lastToldLine(AuthoredPrLastTold(name: "Cody in Nostromo", at: nil), now: now),
                       "Last told: never")
        XCTAssertEqual(AuthoredPrsPresentation.lastToldLine(
            AuthoredPrLastTold(name: "Cody in Nostromo", at: now.addingTimeInterval(-60)), now: now),
                       "Last told: 1m ago (Cody)")
    }
}

// MARK: - The picker

final class AuthoredPrsPickerEntriesTests: XCTestCase {

    private let startTitle = "Start a session…"

    func testAmbiguousListsOnlyOpenCandidatesWithHowEachWasFoundAndStartLast() {
        let owner = AuthoredPrOwner(kind: .ambiguous, candidates: [
            AuthoredPrCandidate(tag: "alpha", name: "Alpha", via: .motherJob, jobId: "a1b2c3"),
            AuthoredPrCandidate(tag: "beta", name: "Beta", via: .onBranch),
            AuthoredPrCandidate(tag: "gamma", name: "Gamma", via: .linked),
            AuthoredPrCandidate(tag: "delta", name: "Delta", via: .linked, closed: true),
            AuthoredPrCandidate(tag: "epsilon", name: "Epsilon", via: .onBranch),   // not open in the app
        ])
        let open = ["alpha", "beta", "gamma", "delta"].map { AuthoredPrPickerFocus(tag: $0, name: $0.capitalized) }
        let entries = AuthoredPrsPicker.entries(for: fixablePr(owner: owner), openFocuses: open)

        XCTAssertEqual(entries.map(\.title), ["Alpha", "Beta", "Gamma", startTitle])
        XCTAssertEqual(entries.map(\.detail), ["Mother job a1b2c3", "On branch", "Linked", nil])
        XCTAssertEqual(entries.map(\.kind), [.focus(tag: "alpha"), .focus(tag: "beta"), .focus(tag: "gamma"), .startSession])
    }

    func testAnAmbiguousPrWhoseCandidatesAreAllClosedStillOffersStart() {
        let owner = AuthoredPrOwner(kind: .ambiguous, candidates: [AuthoredPrCandidate(tag: "a", name: "A", closed: true)])
        let entries = AuthoredPrsPicker.entries(for: fixablePr(owner: owner), openFocuses: [AuthoredPrPickerFocus(tag: "a", name: "A")])
        XCTAssertEqual(entries.map(\.kind), [.startSession])
    }

    func testUnknownListsEveryOpenFocusWithTheRepoNamedOnesFirstThenStart() {
        let open = [
            AuthoredPrPickerFocus(tag: "t1", name: "Other", repoName: "widgets"),
            AuthoredPrPickerFocus(tag: "t2", name: "Mine", repoName: "nostromo"),
            AuthoredPrPickerFocus(tag: "t3", name: "No project", repoName: nil),
            AuthoredPrPickerFocus(tag: "t4", name: "Also mine", repoName: "Nostromo"),
        ]
        let entries = AuthoredPrsPicker.entries(for: fixablePr(owner: .unknown, repo: "thehammer/nostromo"), openFocuses: open)
        XCTAssertEqual(entries.map(\.title), ["Mine", "Also mine", "Other", "No project", startTitle])
        XCTAssertEqual(entries.last?.kind, .startSession)
    }

    func testUnknownWithNoOpenFocusesOffersOnlyStart() {
        let entries = AuthoredPrsPicker.entries(for: fixablePr(owner: .unknown), openFocuses: [])
        XCTAssertEqual(entries.map(\.kind), [.startSession])
        XCTAssertEqual(entries.first?.title, startTitle)
    }

    func testAFocusWithNoNameIsShownByItsTag() {
        let entries = AuthoredPrsPicker.entries(for: fixablePr(owner: .unknown),
                                                openFocuses: [AuthoredPrPickerFocus(tag: "focus-x", name: "")])
        XCTAssertEqual(entries.first?.title, "focus-x")
    }
}

// MARK: - Needs-you

final class AuthoredPrsNeedsYouReasonTests: XCTestCase {

    func testPrAttentionIsSpokenWithItsNumber() {
        XCTAssertEqual(NeedsYouReason.prAttention(number: 458).spokenText, "PR #458 needs attention")
    }

    func testOtherReasonsHaveNoSpokenTextOfTheirOwn() {
        XCTAssertNil(NeedsYouReason.trackerWaiting.spokenText)
    }
}

final class AuthoredPrNeedsYouProducerTests: XCTestCase {

    private func items(_ prs: [AuthoredPr]) -> [NeedsYouItem] {
        AuthoredPrNeedsYouProducer.items(from: AuthoredPrsSnapshot(prs: prs))
    }

    func testOnePillRowWithAnOpenOwnerRaisesOneWaitingItemOnThatFocus() throws {
        let item = try XCTUnwrap(items([fixablePr(458, owner: codyOwner, pill: true)]).first)
        XCTAssertEqual(item.id, "authored-pr:focus-cody:thehammer/nostromo#458")
        XCTAssertEqual(item.source, .focus("focus-cody"))
        XCTAssertEqual(item.reason, .prAttention(number: 458))
        XCTAssertTrue(item.id.hasPrefix("\(AuthoredPrNeedsYouProducer.name):"))
    }

    func testEveryOpenOwnerKindWithATagRaisesOne() {
        for kind in [AuthoredPrOwnerKind.motherJob, .linked, .onBranch] {
            let owner = AuthoredPrOwner(kind: kind, tag: "t", name: "N")
            XCTAssertEqual(items([fixablePr(owner: owner, pill: true)]).count, 1, "\(kind)")
        }
    }

    func testARowTheDaemonDidNotMarkRaisesNothing() {
        XCTAssertTrue(items([fixablePr(owner: codyOwner, pill: false)]).isEmpty)
    }

    func testADraftRaisesNothing() {
        XCTAssertTrue(items([fixablePr(owner: codyOwner, group: .draft, draft: true, pill: true)]).isEmpty)
    }

    func testAmbiguousClosedAndUnknownOwnersRaiseNothing() {
        let ambiguous = AuthoredPrOwner(kind: .ambiguous, tag: "t", candidates: [AuthoredPrCandidate(tag: "t", name: "T")])
        let closed = AuthoredPrOwner(kind: .closed, tag: "t", name: "Gone")
        for owner in [ambiguous, closed, AuthoredPrOwner.unknown] {
            XCTAssertTrue(items([fixablePr(owner: owner, pill: true)]).isEmpty, "\(owner.kind)")
        }
    }

    func testAMergedPrRaisesNothing() {
        XCTAssertTrue(items([fixablePr(owner: codyOwner, lifecycle: .merged, pill: true)]).isEmpty)
    }

    func testAnOwnerWithoutATagRaisesNothing() {
        XCTAssertTrue(items([fixablePr(owner: AuthoredPrOwner(kind: .linked, tag: nil, name: "N"), pill: true)]).isEmpty)
    }

    func testNoSnapshotRaisesNothing() {
        XCTAssertTrue(AuthoredPrNeedsYouProducer.items(from: nil).isEmpty)
    }

    func testTwoMarkedPrsOnOneFocusRaiseTwoItemsWithDistinctIds() {
        let two = items([fixablePr(458, owner: codyOwner, pill: true), fixablePr(459, owner: codyOwner, pill: true)])
        XCTAssertEqual(two.count, 2)
        XCTAssertEqual(Set(two.map(\.id)).count, 2)
    }

    func testTheGoldenFrameRaisesExactlyTheMarkedMotherJobRow() throws {
        let raised = AuthoredPrNeedsYouProducer.items(from: try goldenSnapshot())
        XCTAssertEqual(raised.map(\.id), ["authored-pr:focus-portal:Carefeed/admin-portal#101"])
    }
}
