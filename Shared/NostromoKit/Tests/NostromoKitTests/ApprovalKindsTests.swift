// NostromoKit — ApprovalKindsTests.swift
//
// What the approval card offers for each kind of request, who it says is asking,
// and the words VoiceOver gets (AP2a). Covers PRD criteria 27 (focus starts on
// Deny), 29 (options match the request kind) and 30 (subagent and MCP naming),
// and the "Accessibility and appearance" wording.

import XCTest
@testable import NostromoKit

final class ApprovalKindsTests: XCTestCase {

    // MARK: - Options per kind

    func testANormalRequestOffersDenyDenyWithNoteDenyAndStopThenAllowOnceInThatOrder() throws {
        let options = ApprovalCardOptions(request: try bash())
        XCTAssertEqual(options.controls, [.deny, .denyWithNote, .denyAndStop, .allowOnce])
        XCTAssertNil(options.notice)
        XCTAssertTrue(options.offersAllowOnce)
    }

    func testTheOrderOfTheControlsDoesNotDependOnTheOrderTheDaemonListedThem() throws {
        let options = ApprovalCardOptions(request: try bash(options: ["deny_with_note", "allow_once", "deny_and_stop", "deny"]))
        XCTAssertEqual(options.controls, [.deny, .denyWithNote, .denyAndStop, .allowOnce])
    }

    func testASafetyCheckOffersOnlyDenyDenyAndStopAndAllowOnce() throws {
        let options = ApprovalCardOptions(request: try bash(reasonKind: "safety_check", reasonText: "Dangerous removal",
                                                           options: ["allow_once", "deny", "deny_and_stop"]))
        XCTAssertEqual(options.controls, [.deny, .denyAndStop, .allowOnce])
        XCTAssertNil(options.notice)
    }

    func testASettingsFileWriteOffersOnlyDenyDenyAndStopAndAllowOnce() throws {
        let options = ApprovalCardOptions(request: try bash(reasonKind: "settings_write",
                                                           reasonText: "Changes a Claude settings file",
                                                           options: ["allow_once", "deny", "deny_and_stop"]))
        XCTAssertEqual(options.controls, [.deny, .denyAndStop, .allowOnce])
    }

    func testASafetyCheckOrSettingsWriteAddsNothingEvenIfTheDaemonListsMoreThanThisBuildKnows() throws {
        for kind in ["safety_check", "settings_write"] {
            let options = ApprovalCardOptions(request: try bash(
                reasonKind: kind,
                options: ["allow_once", "allow_session", "remember_always", "deny", "deny_and_stop"]))
            XCTAssertEqual(options.controls, [.deny, .denyAndStop, .allowOnce], kind)
        }
    }

    func testARequestWithSuppressAlwaysAllowRuleOffersTheSameControlsAndNothingExtra() throws {
        let options = ApprovalCardOptions(request: try bash(flags: ["suppress_always_allow_rule": true]))
        XCTAssertEqual(options.controls, [.deny, .denyWithNote, .denyAndStop, .allowOnce])
        XCTAssertNil(options.notice)
    }

    func testThereIsNoRememberControlAndNoControlBeyondTheFourEverCanBeOffered() throws {
        XCTAssertEqual(Set(ApprovalControl.allCases), [.deny, .denyWithNote, .denyAndStop, .allowOnce])
        XCTAssertEqual(ApprovalControl.allCases.count, 4)
        for control in ApprovalControl.allCases {
            let raw = control.rawValue.lowercased()
            XCTAssertFalse(raw.contains("remember") || raw.contains("session") || raw.contains("always"), raw)
        }
        // Whatever the daemon lists, only those four can come back.
        let allowed: Set<ApprovalControl> = Set(ApprovalControl.allCases)
        let hostile = try bash(options: ["allow_once", "allow_session", "remember_always", "allow_always", "deny",
                                         "deny_and_stop", "deny_with_note"])
        XCTAssertTrue(Set(ApprovalCardOptions(request: hostile).controls).isSubset(of: allowed))
        XCTAssertEqual(ApprovalCardOptions(request: hostile).controls, [.deny, .denyWithNote, .denyAndStop, .allowOnce])
    }

    func testARequestThatNeedsClaudeCodesOwnInterfaceOffersDenyOnlyWithTheExplanation() throws {
        let options = ApprovalCardOptions(request: try bash(flags: ["requires_user_interaction": true]))
        XCTAssertEqual(options.controls, [.deny])
        XCTAssertEqual(options.notice, "This tool needs Claude Code's own interface; Nostromo can't approve it")
        XCTAssertFalse(options.offersAllowOnce)
    }

    func testRequiresUserInteractionOffersDenyOnlyEvenWhenTheDaemonListedAllowOnce() throws {
        let options = ApprovalCardOptions(request: try bash(
            flags: ["requires_user_interaction": true],
            options: ["allow_once", "deny", "deny_and_stop", "deny_with_note"]))
        XCTAssertEqual(options.controls, [.deny])
        XCTAssertFalse(options.controls.contains(.allowOnce))
    }

    func testAllowOnceIsNotOfferedWhenTheDaemonDidNotListIt() throws {
        let options = ApprovalCardOptions(request: try bash(options: ["deny", "deny_and_stop"]))
        XCTAssertEqual(options.controls, [.deny, .denyAndStop])
        XCTAssertFalse(options.offersAllowOnce)
    }

    func testDenyIsOfferedEvenWhenTheDaemonListedNoOptions() throws {
        let options = ApprovalCardOptions(request: try bash(options: []))
        XCTAssertEqual(options.controls, [.deny])
        XCTAssertFalse(options.offersAllowOnce)
    }

    func testDenyIsOfferedAndNothingElseWhenEveryOptionIsOneThisBuildDoesNotKnow() throws {
        let options = ApprovalCardOptions(request: try bash(options: ["allow_session", "allow_forever"]))
        XCTAssertEqual(options.controls, [.deny])
    }

    // MARK: - Where keyboard focus starts

    func testFocusStartsOnDenyWhenTheCliSaidDefaultToNo() throws {
        XCTAssertTrue(ApprovalCardOptions(request: try bash(flags: ["default_to_no": true])).defaultsToDeny)
    }

    func testFocusStartsOnDenyWhenTheInputHasInvisibleCharacters() throws {
        let request = try Fx.bashCase("bidi").request()
        XCTAssertTrue(ApprovalCardOptions(request: request).defaultsToDeny)
    }

    func testFocusStillStartsOnDenyWhenTheFrameUnderReportsInvisibleCharacters() throws {
        let fixture = Fx.bashCase("bidi")
        let request = try Fx.request(input: ["command": fixture.command], display: fixture.display(invisibleCount: 0))
        XCTAssertEqual(request.display.invisibleCount, 0, "precondition: the frame says none")
        XCTAssertTrue(ApprovalCardOptions(request: request).defaultsToDeny)
    }

    func testFocusDoesNotStartOnDenyForAnOrdinaryRequest() throws {
        XCTAssertFalse(ApprovalCardOptions(request: try Fx.bashCase("simple_rm").request()).defaultsToDeny)
        XCTAssertFalse(ApprovalCardOptions(request: try Fx.bashCase("cyrillic").request()).defaultsToDeny,
                       "a look-alike is tinted and hoverable, but is not an invisible character")
    }

    // MARK: - The header

    func testTheHeadlineNamesTheAgentAndTheTool() throws {
        XCTAssertEqual(ApprovalKinds.headline(for: try bash()), "Cody wants to run Bash")
    }

    func testASubagentRequestNamesTheSubagentAndItsParent() throws {
        let request = try bash(subagent: ["agent_id": "agent_abc", "agent_type": "redd"])
        XCTAssertEqual(ApprovalKinds.headline(for: request), "redd (subagent of Cody) wants to run Bash")
    }

    func testASubagentWithNoTypeIsNamedByItsId() throws {
        let request = try bash(subagent: ["agent_id": "agent_abc"])
        XCTAssertEqual(ApprovalKinds.headline(for: request), "agent_abc (subagent of Cody) wants to run Bash")
    }

    func testASubagentWithAnEmptyTypeIsNamedByItsId() throws {
        let request = try bash(subagent: ["agent_id": "agent_abc", "agent_type": ""])
        XCTAssertEqual(ApprovalKinds.headline(for: request), "agent_abc (subagent of Cody) wants to run Bash")
    }

    func testAnEditIsDescribedAsEditingAFile() throws {
        XCTAssertEqual(ApprovalKinds.headline(for: try Fx.editRequest()), "Cody wants to edit a file")
    }

    func testAWriteIsDescribedAsWritingAFile() throws {
        XCTAssertEqual(ApprovalKinds.headline(for: try Fx.writeRequest()), "Cody wants to write a file")
    }

    func testANotebookEditIsDescribedAsEditingANotebook() throws {
        XCTAssertEqual(ApprovalKinds.headline(for: try Fx.notebookEditRequest()), "Cody wants to edit a notebook")
    }

    func testAnMcpToolIsNamedByItsFullToolName() throws {
        let request = try Fx.request(toolKind: "mcp", toolName: "mcp__slack__post_message",
                                     displayName: "Post message",
                                     mcp: ["server": "slack", "tool": "post_message"],
                                     input: ["text": "hi"],
                                     display: Fx.display(lines: Fx.jsonDisplayLines("{\n  \"text\": \"hi\"\n}")))
        XCTAssertEqual(ApprovalKinds.headline(for: request), "Cody wants to use mcp__slack__post_message")
    }

    func testAnyOtherToolIsNamedByItsDisplayName() throws {
        XCTAssertEqual(ApprovalKinds.headline(for: try Fx.otherToolRequest()), "Cody wants to use WebFetch")
    }

    func testTheAgentsNameIsCapitalised() throws {
        XCTAssertEqual(ApprovalKinds.headline(for: try bash(agentName: "marty")), "Marty wants to run Bash")
    }

    // MARK: - What VoiceOver hears

    func testTheAnnouncementCountsCommandsWhenThereAreSeveral() throws {
        let request = try Fx.bashCase("compound").request()
        XCTAssertEqual(ApprovalKinds.announcement(for: request),
                       "Approval needed: Cody wants to run Bash, 2 commands")
    }

    func testTheAnnouncementHasNoCountForASingleCommand() throws {
        XCTAssertEqual(ApprovalKinds.announcement(for: try Fx.bashCase("simple_rm").request()),
                       "Approval needed: Cody wants to run Bash")
    }

    func testTheAnnouncementHasNoCountWhenTheFrameHasNone() throws {
        XCTAssertEqual(ApprovalKinds.announcement(for: try Fx.writeRequest()),
                       "Approval needed: Cody wants to write a file")
    }

    func testTheCommandCountLineSaysHowManyCommandsWhenThereAreSeveral() throws {
        XCTAssertEqual(ApprovalKinds.commandCountLine(for: try Fx.bashCase("compound").request()), "2 commands")
        XCTAssertEqual(ApprovalKinds.commandCountLine(for: try Fx.bashCase("compound_fixture").request()), "3 commands")
    }

    func testThereIsNoCommandCountLineForOneCommandOrForNoCount() throws {
        XCTAssertNil(ApprovalKinds.commandCountLine(for: try Fx.bashCase("simple_rm").request()))
        XCTAssertNil(ApprovalKinds.commandCountLine(for: try Fx.writeRequest()))
    }

    func testAllowOnceIsLabelledWithTheFirstCommandAndHowManyMoreThereAre() {
        XCTAssertEqual(ApprovalKinds.allowOnceAccessibilityLabel(summary: "rm -rf build/", commandCount: 2),
                       "Allow once: rm -rf build/ and 1 more command")
        XCTAssertEqual(ApprovalKinds.allowOnceAccessibilityLabel(summary: "rm -rf build/", commandCount: 3),
                       "Allow once: rm -rf build/ and 2 more commands")
    }

    func testAllowOnceHasNoMoreSuffixForASingleCommandOrNoCount() {
        XCTAssertEqual(ApprovalKinds.allowOnceAccessibilityLabel(summary: "rm -rf build/", commandCount: 1),
                       "Allow once: rm -rf build/")
        XCTAssertEqual(ApprovalKinds.allowOnceAccessibilityLabel(summary: "rm -rf build/", commandCount: nil),
                       "Allow once: rm -rf build/")
    }

    // MARK: - Home shown as ~

    func testTheHomeDirectoryIsShownAsTilde() {
        XCTAssertEqual(ApprovalKinds.homeAbbreviated("/Users/hammer/Code/nostromo-wt/ba3", home: "/Users/hammer"),
                       "~/Code/nostromo-wt/ba3")
        XCTAssertEqual(ApprovalKinds.homeAbbreviated("/Users/hammer", home: "/Users/hammer"), "~")
    }

    func testAPathOutsideHomeIsShownInFull() {
        XCTAssertEqual(ApprovalKinds.homeAbbreviated("/tmp/x", home: "/Users/hammer"), "/tmp/x")
    }

    func testASiblingDirectoryThatSharesTheHomePrefixIsNotAbbreviated() {
        XCTAssertEqual(ApprovalKinds.homeAbbreviated("/Users/hammerhead/x", home: "/Users/hammer"),
                       "/Users/hammerhead/x")
    }

    func testAnEmptyOrRootHomeLeavesThePathAlone() {
        XCTAssertEqual(ApprovalKinds.homeAbbreviated("/tmp/x", home: ""), "/tmp/x")
        XCTAssertEqual(ApprovalKinds.homeAbbreviated("/tmp/x", home: "/"), "/tmp/x")
    }

    // MARK: - Hidden characters anywhere the card shows make Deny the default (N1, N3)

    /// A Bash request for `ls` whose daemon display says no invisible characters, with `input` extra fields and context.
    private func lsRequest(extra: Fx.Obj = [:], agentName: String = "cody", cwd: String? = nil,
                           reasonText: String = "your rule Bash(rm:*) in ~/.claude/settings.json",
                           description: String? = nil) throws -> ApprovalRequestWire {
        var input: Fx.Obj = ["command": "ls"]
        for (key, value) in extra { input[key] = value }
        return try Fx.request(agentName: agentName, input: input,
                              display: Fx.display(lines: Fx.plainBashLines("ls"), commandCount: 1),
                              cwd: cwd, reasonText: reasonText, description: description)
    }

    func testFocusStartsOnDenyWhenAnOtherFieldOfABashInputHasAnInvisibleCharacter() throws {
        let request = try lsRequest(extra: ["timeout": 1, "note": "a\u{202E}b"])
        XCTAssertEqual(request.display.invisibleCount, 0, "precondition: the frame's display of the command says none")
        XCTAssertTrue(ApprovalCardOptions(request: request).defaultsToDeny,
                      "the card shows the other fields, so their hidden characters count")

        let plain = try lsRequest(extra: ["timeout": 1, "note": "ab"])
        XCTAssertFalse(ApprovalCardOptions(request: plain).defaultsToDeny, "the same request without the character")
    }

    func testFocusStartsOnDenyWhenTheTextAroundTheInputHasAHiddenCharacter() throws {
        let cases: [(name: String, request: ApprovalRequestWire)] = [
            ("the agent's claim", try lsRequest(description: "clean\u{202E}up")),
            ("the reason", try lsRequest(reasonText: "your rule \u{202E}x")),
            ("the directory", try lsRequest(cwd: "/tmp/\u{202E}x")),
            ("the agent's name", try lsRequest(agentName: "co\u{202E}dy")),
            ("a tab in the claim", try lsRequest(description: "a\tb")),
            ("a zero-width space in the reason", try lsRequest(reasonText: "why\u{200B}not")),
        ]
        for item in cases {
            XCTAssertEqual(item.request.display.invisibleCount, 0, "\(item.name): precondition: the display of the input says none")
            XCTAssertTrue(ApprovalCardOptions(request: item.request).defaultsToDeny, item.name)
        }
    }

    func testFocusDoesNotStartOnDenyForPlainContextTextEvenWithALineFeedAndAccents() throws {
        let request = try lsRequest(cwd: "/tmp/caf\u{00E9}", reasonText: "your rule “Bash(rm:*)”",
                                    description: "first line\nsecond line \u{1F642}")
        XCTAssertFalse(ApprovalCardOptions(request: request).defaultsToDeny)
    }

    // MARK: - Helpers

    /// A Bash request for `rm -rf build/` with the given kind, flags, options and agent.
    private func bash(agentName: String = "cody",
                      subagent: Fx.Obj? = nil,
                      reasonKind: String = "ask_rule",
                      reasonText: String = "your rule Bash(rm:*) in ~/.claude/settings.json",
                      flags: [String: Bool] = [:],
                      options: [String] = Fx.allOptions) throws -> ApprovalRequestWire {
        let fixture = Fx.bashCase("simple_rm")
        return try Fx.request(agentName: agentName, subagent: subagent,
                              input: ["command": fixture.command], display: fixture.display(),
                              reasonKind: reasonKind, reasonText: reasonText,
                              flags: flags, options: options)
    }
}
