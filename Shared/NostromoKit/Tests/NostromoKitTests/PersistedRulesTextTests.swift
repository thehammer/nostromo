// NostromoKit — PersistedRulesTextTests.swift
//
// AP6 ("Always allow…"): the words of the confirmation step and the Rules list, and what the card
// offers. Pure behaviour, from outside: the strings are the contract the human reads before
// they write a rule that outlives the session.

import XCTest
@testable import NostromoKit

final class PersistedRulesTextTests: XCTestCase {
    typealias Fx = ApprovalFixtures
    private let home = "/Users/h"
    private let utc = TimeZone(identifier: "UTC")!

    // MARK: confirmation

    func testTheConfirmationNamesTheFileTheScopeAndThatSettingsAreUntouched() {
        XCTAssertEqual(PersistedRulesText.destinationLine, "Write this rule to ~/.nostromo/approvals/rules.json")
        XCTAssertEqual(PersistedRulesText.settingsUnchangedLine, "Your ~/.claude/settings.json is not changed")
        XCTAssertEqual(PersistedRulesText.affectsLine(scopeDescription: "~/Code/x"),
                       "Every Nostromo session in ~/Code/x will run this without asking")
        XCTAssertEqual(PersistedRulesText.affectsLine(scopeDescription: "all repositories"),
                       "Every Nostromo session in all repositories will run this without asking")
    }

    func testScopeTitlesSayRepositoryFolderOrAllRepositories() {
        XCTAssertEqual(PersistedRulesText.scopeTitle(.repo, repoRoot: "/Users/h/Code/x", repoIsGit: true, home: home),
                       "This repository (~/Code/x)")
        XCTAssertEqual(PersistedRulesText.scopeTitle(.repo, repoRoot: "/Users/h/Code/x", repoIsGit: false, home: home),
                       "This folder (~/Code/x)")
        XCTAssertEqual(PersistedRulesText.scopeTitle(.repo, repoRoot: "/opt/y", repoIsGit: true, home: home),
                       "This repository (/opt/y)")
        XCTAssertEqual(PersistedRulesText.scopeTitle(.allRepos, repoRoot: "/Users/h/Code/x", repoIsGit: true, home: home),
                       "All repositories")
    }

    func testTheRepositoryScopeIsOfferedOnlyWhenTheDaemonSentARoot() {
        XCTAssertTrue(PersistedRulesText.offersRepoScope(repoRoot: "/Users/h/Code/x"))
        XCTAssertFalse(PersistedRulesText.offersRepoScope(repoRoot: nil))
        XCTAssertFalse(PersistedRulesText.offersRepoScope(repoRoot: ""))
    }

    func testTheExactCandidateIsAlwaysFirstWhateverOrderTheDaemonSentThem() throws {
        let request = try Fx.request(input: ["command": "rm -rf ~/Library/Caches/a"],
                                     display: Fx.bashCase("simple_rm").display(),
                                     options: Fx.alwaysOptions,
                                     sessionRuleCandidates: Array(Fx.cacheCandidates.reversed()))
        let ordered = PersistedRulesText.orderedCandidates(request.sessionRuleCandidates)
        XCTAssertEqual(ordered.map(\.id), ["c-exact", "c-prefix"])
        XCTAssertEqual(PersistedRulesText.orderedCandidates([]), [])
    }

    func testCopyRulePutsTheRuleAsShown() throws {
        let candidate = ApprovalSessionRuleCandidate(id: "c", ruleText: "Bash(ls /a/b)", summary: "s", kind: .exact)
        XCTAssertEqual(PersistedRulesText.copyText(for: candidate), "Bash(ls /a/b)")
    }

    func testEachRuleRefusalHasItsOwnWordsAndAnOtherCodeHasNone() {
        XCTAssertEqual(PersistedRulesText.refusalText(code: .ruleRefused, reason: "Too broad: Bash(*)"), "Too broad: Bash(*)")
        XCTAssertEqual(PersistedRulesText.refusalText(code: .ruleRefused, reason: nil), "Nostromo will not keep this rule.")
        XCTAssertEqual(PersistedRulesText.refusalText(code: .ruleRefused, reason: ""), "Nostromo will not keep this rule.")
        XCTAssertEqual(PersistedRulesText.refusalText(code: .ruleWriteFailed, reason: nil),
                       "The rules file could not be written. Nothing was allowed.")
        XCTAssertEqual(PersistedRulesText.refusalText(code: .rulesQuarantined, reason: nil),
                       "The rules file changed outside Nostromo. Review it in Approval Rules first.")
        XCTAssertEqual(PersistedRulesText.refusalText(code: .ruleLimit, reason: nil),
                       "There are 200 rules already. Remove one in Approval Rules first.")
        XCTAssertEqual(PersistedRulesText.refusalText(code: .invalidRule, reason: nil),
                       "That rule is not one of this request's choices.")
        XCTAssertNil(PersistedRulesText.refusalText(code: .alreadyResolved, reason: nil))
    }

    // MARK: Rules list

    func testTheQuarantineBannerIsExactlyTheContractedSentence() {
        XCTAssertEqual(PersistedRulesText.quarantineBanner,
                       "Rules file changed outside Nostromo; rules are off until you review them")
    }

    func testEveryQuarantineReasonReadsInWordsAndAnUnknownOneStillDoes() {
        for reason in ["external_change", "hash_mismatch", "parse_error", "unsupported_version", "bad_mode", "symlink",
                       "too_large", "too_many_rules", "duplicate_ids", "something_new"] {
            XCTAssertFalse(PersistedRulesText.quarantineReasonText(reason).isEmpty, reason)
        }
        XCTAssertNotEqual(PersistedRulesText.quarantineReasonText("symlink"),
                          PersistedRulesText.quarantineReasonText("parse_error"))
    }

    func testARuleRowDetailNamesScopeCreatedUsesAndState() {
        // 2025-10-09 14:47 UTC
        let ms: UInt64 = 1_760_021_220_000
        let now = Date(timeIntervalSince1970: TimeInterval(ms) / 1000 + 60)
        let rule = PersistedRule(id: "r1", ruleText: "Bash(ls)", scope: .repo, root: "/Users/h/Code/x",
                                 createdAtMs: ms, uses: 3, active: true)
        XCTAssertEqual(PersistedRulesText.detailText(rule, home: home, now: now, timeZone: utc),
                       "Repository: ~/Code/x · created 2:47 pm · used 3 times · active")
        let other = PersistedRule(id: "r2", ruleText: "Bash(ls)", scope: .allRepos, createdAtMs: ms, uses: 1, active: true)
        XCTAssertEqual(PersistedRulesText.scopeText(other, home: home), "All repositories")
        XCTAssertEqual(PersistedRulesText.usesText(1), "used 1 time")
        XCTAssertEqual(PersistedRulesText.usesText(0), "used 0 times")
        // Another day: the day is shown.
        XCTAssertEqual(PersistedRulesText.createdText(atMs: ms, now: now.addingTimeInterval(86_400 * 2), timeZone: utc),
                       "created oct 9, 2:47 pm")
    }

    func testAnInactiveRuleSaysWhyAndAnUnknownReasonStillSaysSomething() {
        let gone = PersistedRule(id: "r", ruleText: "Bash(ls)", active: false, inactiveReason: "no_longer_offered")
        XCTAssertEqual(PersistedRulesText.stateText(gone), "inactive: Nostromo no longer offers this rule")
        let moved = PersistedRule(id: "r", ruleText: "Bash(ls)", active: false, inactiveReason: "path_changed")
        XCTAssertEqual(PersistedRulesText.stateText(moved), "inactive: a path it covers has changed")
        let odd = PersistedRule(id: "r", ruleText: "Bash(ls)", active: false, inactiveReason: "future")
        XCTAssertEqual(PersistedRulesText.stateText(odd), "inactive: it did not pass Nostromo's checks")
        let on = PersistedRule(id: "r", ruleText: "Bash(ls)", active: true)
        XCTAssertEqual(PersistedRulesText.stateText(on), "active")
    }

    func testTheReviewSaysWhereEachRuleAppliesAndWhetherItWouldStayActive() {
        let home = "/Users/me"
        let on = PersistedRule(id: "a", ruleText: "Bash(ls)", scope: .repo, root: "/Users/me/Code/x", active: true)
        let off = PersistedRule(id: "b", ruleText: "Bash(rm)", scope: .repo, root: "/Users/me/Code/x", active: false, inactiveReason: "path_changed")
        let all = PersistedRule(id: "c", ruleText: "Bash(rm)", scope: .allRepos, active: true)
        let unconfirmed = PersistedRule(id: "d", ruleText: "Bash(rm)", scope: .allRepos, active: false, inactiveReason: "scope_unconfirmed")
        let bad = PersistedRule(id: "e", ruleText: "Bash(rm)", scope: .repo, root: "/", active: false, inactiveReason: "bad_scope")
        XCTAssertEqual(PersistedRulesText.reviewText(on, home: home), "Repository: ~/Code/x · would stay active")
        XCTAssertEqual(PersistedRulesText.reviewText(off, home: home),
                       "Repository: ~/Code/x · would stay inactive: a path it covers has changed")
        XCTAssertEqual(PersistedRulesText.reviewText(all, home: home), "ALL repositories · would stay active")
        XCTAssertEqual(PersistedRulesText.reviewText(unconfirmed, home: home),
                       "ALL repositories · would stay inactive: it applies to all repositories and has not been confirmed again")
        XCTAssertEqual(PersistedRulesText.reviewText(bad, home: home),
                       "Repository: / · would stay inactive: its repository folder is not valid here")
    }

    func testRemoveHasAnAccessibilityLabelNamingTheRule() {
        XCTAssertEqual(PersistedRulesText.removeAccessibilityLabel(PersistedRule(id: "a", ruleText: "Bash(ls)")),
                       "Remove rule Bash(ls)")
    }

    // MARK: what the card offers

    private func bash(options: [String] = Fx.alwaysOptions, reasonKind: String = "ask_rule", flags: [String: Bool] = [:],
                      candidates: [Fx.Obj] = Fx.cacheCandidates) throws -> ApprovalRequestWire {
        try Fx.request(input: ["command": "rm -rf ~/Library/Caches/a"], display: Fx.bashCase("simple_rm").display(),
                       reasonKind: reasonKind, flags: flags, options: options, sessionRuleCandidates: candidates,
                       repoRoot: "/Users/h/Code/x", repoIsGit: true)
    }

    func testAlwaysAllowIsOfferedOnlyWhenListedWithAllowOnceAndACandidateOnAPlainBashRequest() throws {
        let offered = ApprovalCardOptions(request: try bash())
        XCTAssertTrue(offered.offersAllowAlways)
        XCTAssertEqual(offered.alwaysRules.map(\.id), ["c-exact", "c-prefix"])

        XCTAssertFalse(ApprovalCardOptions(request: try bash(options: Fx.sessionOptions)).offersAllowAlways, "not listed")
        XCTAssertFalse(ApprovalCardOptions(request: try bash(candidates: [])).offersAllowAlways, "no candidate")
        XCTAssertFalse(ApprovalCardOptions(request: try bash(options: ["deny", "allow_always"])).offersAllowAlways,
                       "never offered without allow_once")
        // Candidates that do not decode are dropped, never guessed.
        let junk = ApprovalCardOptions(request: try bash(candidates: [["id": "c2"]]))
        XCTAssertFalse(junk.offersAllowAlways)
    }

    func testAlwaysAllowIsNeverOfferedForSafetyChecksSettingsWritesOrNoAlwaysAllowOrInteractionOnlyRequests() throws {
        XCTAssertFalse(ApprovalCardOptions(request: try bash(reasonKind: "safety_check")).offersAllowAlways)
        XCTAssertFalse(ApprovalCardOptions(request: try bash(reasonKind: "settings_write")).offersAllowAlways)
        XCTAssertFalse(ApprovalCardOptions(request: try bash(flags: ["suppress_always_allow_rule": true])).offersAllowAlways)
        let interaction = ApprovalCardOptions(request: try bash(flags: ["requires_user_interaction": true]))
        XCTAssertFalse(interaction.offersAllowAlways)
        XCTAssertTrue(interaction.alwaysRules.isEmpty)
    }

    func testAlwaysAllowIsNeverOfferedOnAQuestionRequest() throws {
        let options = ApprovalCardOptions(request: try Fx.askUserQuestionRequest(options: Fx.askUserQuestionOptions + ["allow_always"]))
        XCTAssertFalse(options.offersAllowAlways)
        XCTAssertEqual(options.controls, [.deny, .answerQuestions])
    }

    func testAlwaysAllowAddsNoButton() throws {
        let with = ApprovalCardOptions(request: try bash())
        XCTAssertEqual(with.controls, [.deny, .denyWithNote, .denyAndStop, .allowOnce, .allowSession])
        let alwaysOnly = ApprovalCardOptions(request: try bash(options: Fx.allOptions + ["allow_always"]))
        XCTAssertTrue(alwaysOnly.offersAllowAlways)
        XCTAssertEqual(alwaysOnly.controls, [.deny, .denyWithNote, .denyAndStop, .allowOnce])
        XCTAssertFalse(ApprovalControl.allCases.map(\.rawValue).contains("allow_always"))
    }
}
