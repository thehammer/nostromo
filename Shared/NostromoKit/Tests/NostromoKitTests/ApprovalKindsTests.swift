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

    func testThereIsNoRememberControlAndNoControlBeyondTheFourAndSubmitEverCanBeOffered() throws {
        // AP2c added Submit (`answer_questions`) for an AskUserQuestion the daemon can take answers for. It is the only
        // addition: nothing that remembers, persists or allows for a session or for good.
        XCTAssertEqual(Set(ApprovalControl.allCases), [.deny, .denyWithNote, .denyAndStop, .allowOnce, .answerQuestions])
        XCTAssertEqual(ApprovalControl.allCases.count, 5)
        XCTAssertEqual(ApprovalControl.answerQuestions.rawValue, "answer_questions")
        for control in ApprovalControl.allCases {
            let raw = control.rawValue.lowercased()
            XCTAssertFalse(raw.contains("remember") || raw.contains("session") || raw.contains("always"), raw)
        }
        // Whatever the daemon lists for an ordinary tool, only the original four can come back.
        let allowed: Set<ApprovalControl> = [.deny, .denyWithNote, .denyAndStop, .allowOnce]
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

    // MARK: - AskUserQuestion (AP2c)

    func testAnAnswerableQuestionRequestOffersDenyAndSubmitAndNothingElse() throws {
        let options = ApprovalCardOptions(request: try Fx.askUserQuestionRequest())
        XCTAssertEqual(options.controls, [.deny, .answerQuestions])
        XCTAssertNil(options.notice, "the card can answer it: there is nothing to apologise for")
        XCTAssertFalse(options.offersAllowOnce)
    }

    func testAQuestionRequestCarriesItsQuestionsForTheForm() throws {
        let options = ApprovalCardOptions(request: try Fx.askUserQuestionRequest())
        let questions = try XCTUnwrap(options.questions)
        XCTAssertEqual(questions.map(\.question), ["Which database should we use?", "Which features do you want to enable?"])
        XCTAssertEqual(questions.map(\.header), ["Database", "Features"])
        XCTAssertEqual(questions.map(\.multiSelect), [false, true])
        XCTAssertEqual(questions.map { $0.options.map(\.label) }, [["Postgres", "SQLite"], ["Caching", "Metrics", "Tracing"]])
        XCTAssertEqual(questions, ApprovalQuestions.parse(try Fx.askUserQuestionRequest().input))
    }

    func testAQuestionRequestIsSubmittableWhateverTheRequiresUserInteractionFlagSays() throws {
        for flag in [true, false] {
            let options = ApprovalCardOptions(request: try Fx.askUserQuestionRequest(flags: ["requires_user_interaction": flag]))
            XCTAssertEqual(options.controls, [.deny, .answerQuestions], "requires_user_interaction \(flag)")
            XCTAssertNil(options.notice, "requires_user_interaction \(flag)")
            XCTAssertNotNil(options.questions, "requires_user_interaction \(flag)")
        }
    }

    func testAQuestionRequestOffersOnlyWhatAnswerableQuestionsNeedEvenIfTheDaemonListedMore() throws {
        for listed in [Fx.askUserQuestionOptions, ["answer_questions"], ["deny", "answer_questions"],
                       ["answer_questions", "allow_once", "allow_session", "remember_always", "deny_and_stop", "deny_with_note"]] {
            let options = ApprovalCardOptions(request: try Fx.askUserQuestionRequest(options: listed))
            XCTAssertEqual(options.controls, [.deny, .answerQuestions], "\(listed)")
            XCTAssertFalse(options.controls.contains(.allowOnce), "\(listed)")
            XCTAssertFalse(options.controls.contains(.denyAndStop), "\(listed)")
            XCTAssertFalse(options.controls.contains(.denyWithNote), "\(listed)")
        }
    }

    func testAnAskUserQuestionTheDaemonDidNotOfferAnswersForKeepsDenyOnlyAndTheInteractionNotice() throws {
        let options = ApprovalCardOptions(request: try Fx.askUserQuestionRequest(options: Fx.allOptions))
        XCTAssertEqual(options.controls, [.deny])
        XCTAssertEqual(options.notice, "This tool needs Claude Code's own interface; Nostromo can't approve it")
        XCTAssertNil(options.questions)
    }

    func testAnAskUserQuestionTheDaemonListedWithoutAnswerQuestionsEvenWithAGoodInputIsNotSubmittable() throws {
        for listed in [[String](), ["deny"], ["allow_once", "deny", "deny_and_stop"]] {
            let options = ApprovalCardOptions(request: try Fx.askUserQuestionRequest(options: listed))
            XCTAssertEqual(options.controls.contains(.answerQuestions), false, "\(listed)")
            XCTAssertNil(options.questions, "\(listed)")
            XCTAssertEqual(options.notice, "This tool needs Claude Code's own interface; Nostromo can't approve it", "\(listed)")
        }
    }

    func testAnAskUserQuestionWithAnInputThisBuildCannotAnswerKeepsDenyOnlyAndTheNoticeEvenIfAnswersWereListed() throws {
        let b = Fx.askOption("B"), a = Fx.askOption("A")
        let unanswerable: [(String, Fx.Obj)] = [
            ("a text question", ["questions": [["question": "Name?", "kind": "text", "options": [a, b]] as Fx.Obj]]),
            ("a number question", ["questions": [["question": "How many?", "kind": "number", "options": [a, b]] as Fx.Obj]]),
            ("five questions", ["questions": (1 ... 5).map { Fx.askQuestion("Q\($0)?", options: [a, b]) }]),
            ("no questions", ["questions": [Fx.Obj]()]),
            ("one option", ["questions": [Fx.askQuestion("Q?", options: [a])]]),
            ("five options", ["questions": [Fx.askQuestion("Q?", options: (1 ... 5).map { Fx.askOption("O\($0)") })]]),
            ("duplicate labels", ["questions": [Fx.askQuestion("Q?", options: [a, a])]]),
            ("duplicate question texts", ["questions": [Fx.askQuestion("Q?", options: [a, b]), Fx.askQuestion("Q?", options: [a, b])]]),
            ("the single-question shape", ["question": "Which one?"]),
            ("no input", [:]),
        ]
        for (name, input) in unanswerable {
            let options = ApprovalCardOptions(request: try Fx.askUserQuestionRequest(input: input))
            XCTAssertEqual(options.controls, [.deny], name)
            XCTAssertNil(options.questions, name)
            XCTAssertEqual(options.notice, "This tool needs Claude Code's own interface; Nostromo can't approve it", name)
        }
    }

    func testAnUnanswerableQuestionRequestWithoutTheInteractionFlagIsLikeAnyOtherTool() throws {
        let options = ApprovalCardOptions(request: try Fx.askUserQuestionRequest(
            input: ["question": "Which one?"], flags: ["requires_user_interaction": false]))
        XCTAssertEqual(options.controls, [.deny, .denyWithNote, .denyAndStop, .allowOnce], "nothing about this build's change touches it")
        XCTAssertNil(options.questions)
        XCTAssertNil(options.notice)
    }

    func testOnlyTheAskUserQuestionToolCanBeSubmittableWhateverTheDaemonListsAndWhateverTheInputLooksLike() throws {
        let good: Fx.Obj = ["questions": Fx.askUserQuestionFixtureQuestions]
        for toolName in ["WebFetch", "Bash", "mcp__x__AskUserQuestion", "askuserquestion", "AskUserQuestion2", "Task"] {
            let options = ApprovalCardOptions(request: try Fx.askUserQuestionRequest(input: good, toolName: toolName))
            XCTAssertFalse(options.controls.contains(.answerQuestions), toolName)
            XCTAssertNil(options.questions, toolName)
        }
    }

    func testABashRequestThatListsAnswerQuestionsIsUnchanged() throws {
        let normal = ApprovalCardOptions(request: try bash(options: Fx.askUserQuestionOptions))
        XCTAssertEqual(normal.controls, [.deny, .denyWithNote, .denyAndStop, .allowOnce])
        XCTAssertNil(normal.questions)
        XCTAssertNil(normal.notice)

        let interaction = ApprovalCardOptions(request: try bash(flags: ["requires_user_interaction": true],
                                                                options: Fx.askUserQuestionOptions))
        XCTAssertEqual(interaction.controls, [.deny])
        XCTAssertEqual(interaction.notice, "This tool needs Claude Code's own interface; Nostromo can't approve it")
        XCTAssertNil(interaction.questions)
    }

    func testOrdinaryRequestsHaveNoQuestions() throws {
        for request in [try bash(), try Fx.editRequest(), try Fx.writeRequest(), try Fx.mcpRequest(), try Fx.otherToolRequest(),
                        try Fx.notebookEditRequest()] {
            XCTAssertNil(ApprovalCardOptions(request: request).questions, request.toolName)
        }
    }

    func testTheHeadlineOfAQuestionRequestSaysTheAgentWantsToAskYouAQuestion() throws {
        let request = try Fx.askUserQuestionRequest()
        XCTAssertEqual(ApprovalKinds.headline(for: request), "Cody wants to ask you a question")
        XCTAssertEqual(ApprovalKinds.announcement(for: request), "Approval needed: Cody wants to ask you a question")
        XCTAssertEqual(ApprovalKinds.headline(for: try Fx.askUserQuestionRequest(agentName: "marty")),
                       "Marty wants to ask you a question")
    }

    func testTheHeadlineOfAnAskUserQuestionNamesTheQuestionEvenWhenItCannotBeAnswered() throws {
        // The tool, not the daemon's offer, decides how it is described.
        XCTAssertEqual(ApprovalKinds.headline(for: try Fx.askUserQuestionRequest(options: Fx.allOptions)),
                       "Cody wants to ask you a question")
    }

    func testOtherToolsKeepTheirHeadlines() throws {
        XCTAssertEqual(ApprovalKinds.headline(for: try Fx.otherToolRequest()), "Cody wants to use WebFetch")
        XCTAssertEqual(ApprovalKinds.headline(for: try bash()), "Cody wants to run Bash")
        XCTAssertEqual(ApprovalKinds.headline(for: try Fx.askUserQuestionRequest(input: ["questions": Fx.askUserQuestionFixtureQuestions],
                                                                                 toolName: "WebFetch")),
                       "Cody wants to use WebFetch")
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
