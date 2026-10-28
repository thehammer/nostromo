import XCTest

// `RemoteShellStore`: the confirm sheet's model, answer-once, resolution outcomes and the phrases
// the failure sheet and the closed toast show. Pure; the transport is a recording closure.

final class RemoteShellStoreTests: XCTestCase {

    private var sent: [RemoteShellClientMessage] = []
    private var store: RemoteShellStore!

    private let target = TerminalTarget(project: "admin-portal", environment: "production",
                                        service: "scheduler", shellType: "shell")

    override func setUp() {
        super.setUp()
        sent = []
        store = RemoteShellStore(transport: { [unowned self] in self.sent.append($0) })
    }

    private func request(id: String = "r1", tag: String? = nil, target: TerminalTarget? = nil,
                         kind: String = "user", requesterTag: String? = nil, agent: String? = nil,
                         reason: String? = nil, shellCommand: String? = nil, profile: String? = nil,
                         cluster: String? = nil) -> RemoteShellConfirmRequest {
        RemoteShellConfirmRequest(requestId: id, tag: tag, target: target ?? self.target,
                                  requestedBy: RemoteShellRequester(kind: kind, tag: requesterTag, agent: agent),
                                  reason: reason, expiresAt: "2026-10-25T12:00:00Z",
                                  shellCommand: shellCommand, profile: profile, cluster: cluster)
    }

    private func model(_ r: RemoteShellConfirmRequest,
                       labels: [String: String] = ["core-1": "Core"]) -> RemoteShellSheetModel {
        RemoteShellStore.sheetModel(for: r, focusLabel: { labels[$0] })
    }

    private func agentRequest(reason: String?) -> RemoteShellConfirmRequest {
        request(tag: "core-1", kind: "focus", requesterTag: "core-1", agent: "cody", reason: reason)
    }

    // MARK: Sheet model

    func testTheTitleAndSubtitleNameTheEnvironmentProjectServiceAndShell() {
        let m = model(request())
        XCTAssertEqual(m.title, "Connect to PRODUCTION")
        XCTAssertEqual(m.environment, "PRODUCTION")
        XCTAssertEqual(m.subtitle, "admin-portal \u{00B7} scheduler \u{00B7} shell")
    }

    func testEveryEnvironmentIsUppercasedInItsOwnName() {
        for env in ["production", "canada", "demo", "staging"] {
            let t = TerminalTarget(project: "p", environment: env, service: "s", shellType: "shell")
            let m = model(request(target: t))
            XCTAssertEqual(m.title, "Connect to \(env.uppercased())")
            XCTAssertEqual(m.environment, env.uppercased())
        }
    }

    func testAUserRequestHasNoRequestedByAndNoReasonEvenWithOne() {
        XCTAssertNil(model(request(kind: "user")).requestedBy)
        XCTAssertNil(model(request(kind: "user", reason: "because")).requestedBy)
        XCTAssertNil(model(request(kind: "user", reason: "because")).reason)
    }

    func testAnAgentRequestNamesTheAgentAndTheFocusWithoutTheReason() {
        let m = model(agentRequest(reason: "Check stuck jobs on the scheduler"))
        XCTAssertEqual(m.requestedBy, "Requested by cody in Core")
        XCTAssertEqual(m.reason, "Check stuck jobs on the scheduler")
    }

    func testAnAgentRequestWithoutAUsableReasonHasNoReason() {
        for reason in [nil, "", " \n\t "] as [String?] {
            let m = model(agentRequest(reason: reason))
            XCTAssertEqual(m.requestedBy, "Requested by cody in Core")
            XCTAssertNil(m.reason, "reason: \(String(describing: reason))")
        }
    }

    func testTheFocusLabelFallsBackToTheRawTagThenToAFocus() {
        XCTAssertEqual(model(agentRequest(reason: nil), labels: [:]).requestedBy, "Requested by cody in core-1")
        XCTAssertEqual(model(request(kind: "focus", agent: "cody")).requestedBy, "Requested by cody in a focus")
    }

    func testTheRequestsTagIsPreferredOverTheRequestersTag() {
        let r = request(tag: "core-1", kind: "focus", requesterTag: "other-9", agent: "cody")
        XCTAssertEqual(model(r, labels: ["core-1": "Core", "other-9": "Other"]).requestedBy, "Requested by cody in Core")
        let onlyRequester = request(kind: "focus", requesterTag: "other-9", agent: "cody")
        XCTAssertEqual(model(onlyRequester, labels: ["other-9": "Other"]).requestedBy, "Requested by cody in Other")
    }

    func testAMissingAgentNameIsAnAgent() {
        let r = request(tag: "core-1", kind: "focus")
        XCTAssertEqual(model(r).requestedBy, "Requested by an agent in Core")
    }

    func testAnAgentNameThatIsEmptyOrOnlyInvisibleCharactersIsAnAgent() {
        for name in ["", "   ", "\n", "\u{200B}\u{202E} \u{FEFF}"] {
            let r = request(tag: "core-1", kind: "focus", agent: name)
            XCTAssertEqual(model(r).requestedBy, "Requested by an agent in Core", "agent: \(name.debugDescription)")
        }
    }

    func testTheAgentNameIsShownVerbatim() {
        let r = request(tag: "core-1", kind: "focus", agent: "Cody <b>X</b>")
        XCTAssertEqual(model(r).requestedBy, "Requested by Cody <b>X</b> in Core")
    }

    func testAnAgentNameWithANewlineCannotBreakTheRequestedByLineApart() {
        let r = request(tag: "core-1", kind: "focus", agent: "cody\nin Prod\u{2028}Requested by root\u{2029}x")
        let line = model(r).requestedBy
        XCTAssertEqual(line, "Requested by cody in Prod Requested by root x in Core")
        XCTAssertFalse(line?.contains(where: { $0.isNewline }) ?? true, "the line must be one line")
    }

    func testAnAgentNameWithAQuoteStaysOnOneLineBetweenTheFixedWords() throws {
        let r = request(tag: "core-1", kind: "focus", agent: "co\"dy\"")
        let line = try XCTUnwrap(model(r).requestedBy)
        XCTAssertTrue(line.hasPrefix("Requested by "), line)
        XCTAssertTrue(line.hasSuffix(" in Core"), line)
        XCTAssertFalse(line.contains(where: { $0.isNewline }), line)
    }

    func testFormatCharactersAreRemovedFromTheAgentName() {
        let r = request(tag: "core-1", kind: "focus", agent: "co\u{202E}dy\u{200B}\u{FEFF}")
        XCTAssertEqual(model(r).requestedBy, "Requested by cody in Core")
    }

    func testAnAgentNameOverFortyCharactersIsCutToFortyEndingInAnEllipsis() {
        XCTAssertEqual(RemoteShellStore.agentNameLimit, 40)
        let r = request(tag: "core-1", kind: "focus", agent: String(repeating: "n", count: 50))
        XCTAssertEqual(model(r).requestedBy, "Requested by \(String(repeating: "n", count: 39))\u{2026} in Core")
    }

    func testAnAgentNameOfExactlyFortyCharactersIsNotCut() {
        let exact = String(repeating: "n", count: RemoteShellStore.agentNameLimit)
        let r = request(tag: "core-1", kind: "focus", agent: exact)
        XCTAssertEqual(model(r).requestedBy, "Requested by \(exact) in Core")
    }

    func testFormatCharactersAreRemovedFromTheFocusName() {
        let m = model(agentRequest(reason: nil), labels: ["core-1": "Co\u{202E}re\u{200B}\u{FEFF}"])
        XCTAssertEqual(m.requestedBy, "Requested by cody in Core")
    }

    func testAFocusNameWithNewlinesStaysOnOneLine() {
        let m = model(agentRequest(reason: nil), labels: ["core-1": "Co\nre"])
        XCTAssertEqual(m.requestedBy, "Requested by cody in Co re")
    }

    func testAFocusNameOverSixtyCharactersIsCutToSixtyEndingInAnEllipsis() {
        XCTAssertEqual(RemoteShellStore.focusNameLimit, 60)
        let m = model(agentRequest(reason: nil), labels: ["core-1": String(repeating: "f", count: 80)])
        XCTAssertEqual(m.requestedBy, "Requested by cody in \(String(repeating: "f", count: 59))\u{2026}")
    }

    func testAFocusNameOfExactlySixtyCharactersIsNotCut() {
        let exact = String(repeating: "f", count: RemoteShellStore.focusNameLimit)
        let m = model(agentRequest(reason: nil), labels: ["core-1": exact])
        XCTAssertEqual(m.requestedBy, "Requested by cody in \(exact)")
    }

    func testAFocusNameThatIsEmptyAfterSanitisingFallsBackToTheRawTag() {
        for label in ["", "  \n ", "\u{200B}\u{202E}"] {
            let m = model(agentRequest(reason: nil), labels: ["core-1": label])
            XCTAssertEqual(m.requestedBy, "Requested by cody in core-1", "label: \(label.debugDescription)")
        }
    }

    func testALongReasonIsCutToTwoHundredCharactersEndingInAnEllipsis() throws {
        let reason = try XCTUnwrap(model(agentRequest(reason: String(repeating: "a", count: 300))).reason)
        XCTAssertEqual(RemoteShellStore.reasonLimit, 200)
        XCTAssertEqual(reason.count, RemoteShellStore.reasonLimit)
        XCTAssertEqual(reason, String(repeating: "a", count: 199) + "\u{2026}")
    }

    func testAReasonOfExactlyTheLimitIsNotCut() {
        let exact = String(repeating: "b", count: RemoteShellStore.reasonLimit)
        XCTAssertEqual(model(agentRequest(reason: exact)).reason, exact)
    }

    func testNewlinesAndControlCharactersInAReasonBecomeSingleSpaces() {
        let m = model(agentRequest(reason: "  look\n\nat   the\tscheduler\u{1b}[31m now\r\n \u{2028}\u{2029}x "))
        XCTAssertEqual(m.reason, "look at the scheduler [31m now x")
    }

    func testMarkupInAReasonStaysVerbatim() {
        XCTAssertEqual(model(agentRequest(reason: "<b>x</b> and **x**")).reason, "<b>x</b> and **x**")
    }

    func testAReasonContainingQuotesIsReturnedUnmodified() {
        XCTAssertEqual(model(agentRequest(reason: "say \"hi\" then \"bye\"")).reason, "say \"hi\" then \"bye\"")
    }

    func testFormatCharactersAreRemovedFromAReason() {
        XCTAssertEqual(model(agentRequest(reason: "pay\u{202E}load\u{200B}x\u{FEFF}")).reason, "payloadx")
        XCTAssertEqual(model(agentRequest(reason: "a \u{200B} b \u{2066}c\u{061C}")).reason, "a b c")
    }

    func testAReasonThatIsOnlyFormatCharactersHasNoReason() {
        XCTAssertNil(model(agentRequest(reason: "\u{202E}\u{200B}\u{FEFF}")).reason)
        XCTAssertNil(model(agentRequest(reason: " \u{200B} \n\u{202E} ")).reason)
    }

    func testTheTitleAndSubtitleAreNeverTruncatedByTheModel() {
        let longName = String(repeating: "x", count: 120)
        let t = TerminalTarget(project: longName, environment: String(repeating: "e", count: 90),
                               service: "service " + longName, shellType: "shell")
        let m = model(request(target: t))
        XCTAssertEqual(m.title, "Connect to \(String(repeating: "E", count: 90))")
        XCTAssertEqual(m.subtitle, "\(longName) \u{00B7} service \(longName) \u{00B7} shell")
        XCTAssertFalse(m.title.contains("\u{2026}") || m.subtitle.contains("\u{2026}"))
    }

    // MARK: What will run (details)

    func testTheDetailsAreAlwaysCommandProfileClusterInThatOrder() {
        let m = model(request(shellCommand: "/bin/bash -l", profile: "prod-profile", cluster: "prod-ecs"))
        XCTAssertEqual(m.details, [
            RemoteShellDetail(label: "Command", value: "/bin/bash -l"),
            RemoteShellDetail(label: "Profile", value: "prod-profile"),
            RemoteShellDetail(label: "Cluster", value: "prod-ecs"),
        ])
    }

    func testTheDetailsTextHoldsTheCommandProfileAndClusterTogether() {
        let m = model(request(shellCommand: "php artisan tinker", profile: "prod-profile", cluster: "prod-ecs"))
        let text = m.details.map { "\($0.label) \($0.value)" }.joined(separator: "\n")
        XCTAssertTrue(text.contains("php artisan tinker"), text)
        XCTAssertTrue(text.contains("prod-profile"), text)
        XCTAssertTrue(text.contains("prod-ecs"), text)
    }

    func testThereAreThreeDetailRowsForEveryRequesterKindAndEnvironment() {
        for kind in ["user", "focus"] {
            for env in ["production", "canada", "demo"] {
                let t = TerminalTarget(project: "p", environment: env, service: "s", shellType: "shell")
                let m = model(request(target: t, kind: kind, shellCommand: "sh"))
                XCTAssertEqual(m.details.map(\.label), ["Command", "Profile", "Cluster"], "\(kind)/\(env)")
            }
        }
    }

    func testAMissingOrEmptyProfileSaysNoneConfigured() {
        XCTAssertEqual(RemoteShellStore.profileMissingText, "(none configured)")
        for profile in [nil, ""] as [String?] {
            let m = model(request(shellCommand: "sh", profile: profile, cluster: "c"))
            XCTAssertEqual(m.details[1], RemoteShellDetail(label: "Profile", value: "(none configured)"))
        }
    }

    func testAMissingOrEmptyClusterSaysNotProvided() {
        XCTAssertEqual(RemoteShellStore.clusterMissingText, "(not provided)")
        for cluster in [nil, ""] as [String?] {
            let m = model(request(shellCommand: "sh", profile: "p", cluster: cluster))
            XCTAssertEqual(m.details[2], RemoteShellDetail(label: "Cluster", value: "(not provided)"))
        }
    }

    func testALongCommandWithNoSpacesIsShownWholeAndVerbatim() {
        let command = String(repeating: "c", count: 1_000)
        let m = model(request(shellCommand: command))
        XCTAssertEqual(m.details[0], RemoteShellDetail(label: "Command", value: command))
        XCTAssertEqual(m.details[0].value.count, 1_000)
    }

    func testALongMultiWordCommandIsShownWholeAndVerbatim() {
        let command = (0..<150).map { "--flag-\($0)=value-\($0)" }.joined(separator: " ")
        XCTAssertGreaterThan(command.count, 1_000)
        let m = model(request(shellCommand: command))
        XCTAssertEqual(m.details[0].value, command)
        XCTAssertFalse(m.details[0].value.contains("\u{2026}"))
    }

    func testAMissingCommandIsSaidSoAndBlocksConnecting() {
        XCTAssertEqual(RemoteShellStore.commandMissingText, "(not provided by the daemon)")
        for command in [nil, "", "   ", " \n\t "] as [String?] {
            let m = model(request(shellCommand: command))
            XCTAssertEqual(m.details[0], RemoteShellDetail(label: "Command", value: "(not provided by the daemon)"),
                           "command: \(String(describing: command))")
            let blocked = m.connectBlockedReason
            XCTAssertNotNil(blocked, "command: \(String(describing: command))")
            XCTAssertFalse(blocked?.isEmpty ?? true)
            XCTAssertTrue(blocked?.lowercased().contains("command") ?? false, blocked ?? "")
        }
    }

    func testAKnownCommandDoesNotBlockConnecting() {
        XCTAssertNil(model(request(shellCommand: "/bin/bash")).connectBlockedReason)
        XCTAssertNil(model(request(tag: "core-1", kind: "focus", agent: "cody", reason: "why",
                                   shellCommand: "/bin/bash")).connectBlockedReason)
    }

    func testAMissingCommandBlocksEveryEnvironmentAndRequesterKind() {
        for kind in ["user", "focus"] {
            for env in ["production", "canada", "demo", "staging"] {
                let t = TerminalTarget(project: "p", environment: env, service: "s", shellType: "shell")
                XCTAssertNotNil(model(request(target: t, kind: kind)).connectBlockedReason, "\(kind)/\(env)")
                XCTAssertNil(model(request(target: t, kind: kind, shellCommand: "sh")).connectBlockedReason, "\(kind)/\(env)")
            }
        }
    }

    // MARK: Phrases

    func testFailureReasonsHaveHumanPhrases() {
        let expected: [String: String] = [
            "sso_expired": "AWS SSO session expired",
            "session_manager_plugin_missing": "The Session Manager plugin is not installed",
            "profile_not_configured": "No AWS profile is set up for this environment",
            "no_running_task": "No task is running for this service",
            "exec_not_enabled": "ECS Exec is not enabled for this service",
            "access_denied": "AWS denied access to this task",
            "target_not_connected": "The task is not ready for exec",
            "connect_timeout": "The session did not start in time",
            "aws_cli_missing": "The AWS CLI is not installed",
            "aws_error": "The AWS CLI reported an error",
        ]
        for (code, phrase) in expected { XCTAssertEqual(RemoteShellStore.failureReasonText(code), phrase, code) }
    }

    func testAnUnknownOrMissingFailureReasonIsGeneric() {
        XCTAssertEqual(RemoteShellStore.failureReasonText("not_available"), "The connection could not be made")
        XCTAssertEqual(RemoteShellStore.failureReasonText(""), "The connection could not be made")
        XCTAssertEqual(RemoteShellStore.failureReasonText(nil), "The connection could not be made")
    }

    func testClosePhrases() {
        let expected: [String: String] = [
            "remote_exit": "remote session ended", "idle_timeout": "idle for 15 minutes", "user_closed": "closed",
            "network": "connection lost", "sso_expired": "AWS SSO session expired",
            "daemon_stopped": "Nostromo daemon restarted",
        ]
        for (code, phrase) in expected { XCTAssertEqual(RemoteShellStore.closePhrase(code), phrase, code) }
        XCTAssertEqual(RemoteShellStore.closePhrase("something_new"), "ended")
        XCTAssertEqual(RemoteShellStore.closePhrase(nil), "ended")
    }

    // MARK: Closed toast

    private func closed(kind: TerminalKind = .ecs, reason: String = "remote_exit", exitCode: Int? = 0,
                        target: TerminalTarget?) -> TerminalClosedInfo {
        TerminalClosedInfo(terminalId: "t1", tag: "core-1", paneId: "terminal-a", label: "Terminal",
                           kind: kind, reason: reason, exitCode: exitCode, target: target)
    }

    func testTheClosedToastNamesTheTargetTheReasonAndTheExitCode() {
        XCTAssertEqual(RemoteShellStore.closedToastMessage(for: closed(target: target)),
                       "production \u{00B7} admin-portal \u{00B7} scheduler shell closed: remote session ended, exit 0")
    }

    func testTheClosedToastOmitsTheExitCodeWhenThereIsNone() {
        XCTAssertEqual(RemoteShellStore.closedToastMessage(for: closed(reason: "network", exitCode: nil, target: target)),
                       "production \u{00B7} admin-portal \u{00B7} scheduler shell closed: connection lost")
    }

    func testTheClosedToastUsesTheShellTypeAndAnUnknownReasonPhrase() {
        let console = TerminalTarget(project: "admin-portal", environment: "production",
                                     service: "scheduler", shellType: "console")
        XCTAssertEqual(RemoteShellStore.closedToastMessage(for: closed(reason: "weird", exitCode: 137, target: console)),
                       "production \u{00B7} admin-portal \u{00B7} scheduler console closed: ended, exit 137")
    }

    func testNoClosedToastForALocalTerminalOrAnEcsTerminalWithoutATarget() {
        XCTAssertNil(RemoteShellStore.closedToastMessage(for: closed(kind: .local, target: target)))
        XCTAssertNil(RemoteShellStore.closedToastMessage(for: closed(kind: .unknown, target: target)))
        XCTAssertNil(RemoteShellStore.closedToastMessage(for: closed(target: nil)))
    }

    // MARK: Sending

    func testOpenAndTargetsRequestGoThroughTheTransport() {
        store.requestTargets()
        store.open(tag: "core-1", target: target)
        XCTAssertEqual(sent, [.targetsRequest, .open(tag: "core-1", target: target)])
    }

    func testSetTargetsKeepsTheLatestTargets() {
        let t = RemoteShellTargets(configured: false, problem: "nope")
        store.setTargets(t)
        XCTAssertEqual(store.targets, t)
    }

    // MARK: Follow checkbox (3c)

    func testAnAgentsRequestOffersToLetThatAgentFollow() {
        let m = model(request(tag: "core-1", kind: "focus", requesterTag: "core-1", agent: "cody"))
        XCTAssertEqual(m.followCheckboxTitle, "Let cody follow this shell's output")
    }

    func testTheFollowBoxIsAccompaniedByTheSentenceNamingTheEnvironmentInCapitalsAndTheAgent() {
        let m = model(request(tag: "core-1", kind: "focus", requesterTag: "core-1", agent: "cody"))
        let environment = target.environment.uppercased()
        XCTAssertEqual(m.followWarning, "Output from \(environment) will be sent to cody's model.")
        XCTAssertNil(model(request(kind: "user", agent: "cody")).followWarning)
    }

    func testARequestTheUserOpenedOffersNoFollowBox() {
        XCTAssertNil(model(request(kind: "user")).followCheckboxTitle)
        XCTAssertNil(model(request(kind: "user", agent: "cody")).followCheckboxTitle)
    }

    func testNoOtherKindOfRequesterOffersAFollowBox() {
        for kind in ["system", "", "agent", "Focus", "unknown"] {
            XCTAssertNil(model(request(kind: kind, agent: "cody")).followCheckboxTitle, "kind: \(kind)")
        }
    }

    func testTheFollowBoxNamesTheAgentSanitisedAndLimitedLikeTheRequesterLine() {
        let long = String(repeating: "n", count: 50)
        XCTAssertEqual(model(request(kind: "focus", agent: long)).followCheckboxTitle,
                       "Let \(String(repeating: "n", count: 39))\u{2026} follow this shell's output")
        XCTAssertEqual(model(request(kind: "focus", agent: "co\u{202E}dy\u{200B}")).followCheckboxTitle,
                       "Let cody follow this shell's output")
        let multi = model(request(kind: "focus", agent: "cody\nfollow\u{2028}x")).followCheckboxTitle ?? ""
        XCTAssertFalse(multi.contains(where: { $0.isNewline }), "the title must be one line: \(multi.debugDescription)")
    }

    func testTheFollowBoxCallsAnUnnamedAgentTheAgent() {
        for name in [nil, "", "  ", "\u{200B}\u{202E}"] as [String?] {
            XCTAssertEqual(model(request(kind: "focus", agent: name)).followCheckboxTitle,
                           "Let the agent follow this shell's output", "agent: \(String(describing: name))")
        }
    }

    // MARK: Answer once

    func testEachDecisionProducesItsAnswerFrame() {
        for decision in [RemoteShellDecision.connect, .cancel, .dismiss] {
            sent = []
            let id = "r-\(decision.rawValue)"
            XCTAssertTrue(store.answer(requestId: id, decision: decision))
            XCTAssertEqual(sent, [.answer(requestId: id, decision: decision)])
            let data = sent.first?.encoded()
            let v = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            XCTAssertEqual(v?["decision"] as? String, decision.rawValue)
            XCTAssertEqual(v?["invite_follow"] as? Bool, false)
        }
    }

    func testConnectWithTheFollowBoxTickedInvitesAFollow() {
        XCTAssertTrue(store.answer(requestId: "r1", decision: .connect, inviteFollow: true))
        XCTAssertEqual(sent, [.answer(requestId: "r1", decision: .connect, inviteFollow: true)])
    }

    func testConnectWithoutTheFollowBoxNeverInvitesAFollow() {
        XCTAssertTrue(store.answer(requestId: "r1", decision: .connect))
        XCTAssertTrue(store.answer(requestId: "r2", decision: .connect, inviteFollow: false))
        XCTAssertEqual(sent, [.answer(requestId: "r1", decision: .connect, inviteFollow: false),
                              .answer(requestId: "r2", decision: .connect, inviteFollow: false)])
    }

    func testCancelAndDismissNeverCarryAnInviteEvenIfAskedTo() {
        XCTAssertTrue(store.answer(requestId: "r1", decision: .cancel, inviteFollow: true))
        XCTAssertTrue(store.answer(requestId: "r2", decision: .dismiss, inviteFollow: true))
        XCTAssertEqual(sent, [.answer(requestId: "r1", decision: .cancel, inviteFollow: false),
                              .answer(requestId: "r2", decision: .dismiss, inviteFollow: false)])
    }

    func testAnAnswerWithTheFollowBoxStillOnlyGoesOnce() {
        XCTAssertTrue(store.answer(requestId: "r1", decision: .connect, inviteFollow: true))
        XCTAssertFalse(store.answer(requestId: "r1", decision: .connect, inviteFollow: true))
        XCTAssertFalse(store.answer(requestId: "r1", decision: .cancel, inviteFollow: true))
        XCTAssertEqual(sent, [.answer(requestId: "r1", decision: .connect, inviteFollow: true)])
    }

    func testAnsweringConnectTwiceSendsOneFrame() {
        XCTAssertTrue(store.answer(requestId: "r1", decision: .connect))
        XCTAssertFalse(store.answer(requestId: "r1", decision: .connect))
        XCTAssertEqual(sent, [.answer(requestId: "r1", decision: .connect)])
    }

    func testConnectAfterCancelSendsNothing() {
        XCTAssertTrue(store.answer(requestId: "r1", decision: .cancel))
        XCTAssertFalse(store.answer(requestId: "r1", decision: .connect))
        XCTAssertEqual(sent, [.answer(requestId: "r1", decision: .cancel)])
    }

    func testAnotherRequestIdIsIndependent() {
        XCTAssertTrue(store.answer(requestId: "r1", decision: .cancel))
        XCTAssertTrue(store.answer(requestId: "r2", decision: .connect))
        XCTAssertEqual(sent.count, 2)
    }

    func testConnectAfterTheRequestWasResolvedSendsNothing() {
        _ = store.resolve(RemoteShellResolved(requestId: "r1", outcome: "cancelled"), target: nil)
        XCTAssertFalse(store.answer(requestId: "r1", decision: .connect))
        XCTAssertTrue(sent.isEmpty, "sent: \(sent)")
    }

    // MARK: Pending

    func testPresentingMakesTheRequestPendingAndANewerOneReplacesIt() {
        store.present(request(id: "r1"))
        XCTAssertEqual(store.pending?.requestId, "r1")
        store.present(request(id: "r2"))
        XCTAssertEqual(store.pending?.requestId, "r2")
    }

    func testAnsweringThePendingRequestClearsIt() {
        store.present(request(id: "r1"))
        _ = store.answer(requestId: "r1", decision: .cancel)
        XCTAssertNil(store.pending)
    }

    func testAnsweringAnotherRequestLeavesThePendingOneAlone() {
        store.present(request(id: "r2"))
        _ = store.answer(requestId: "r1", decision: .cancel)
        XCTAssertEqual(store.pending?.requestId, "r2")
    }

    func testResolvingThePendingRequestClearsItAndAnotherIdDoesNot() {
        store.present(request(id: "r1"))
        _ = store.resolve(RemoteShellResolved(requestId: "other", outcome: "connected"), target: nil)
        XCTAssertEqual(store.pending?.requestId, "r1")
        _ = store.resolve(RemoteShellResolved(requestId: "r1", outcome: "connected"), target: nil)
        XCTAssertNil(store.pending)
    }

    // MARK: Resolve

    func testConnectedCancelledAndDismissedJustCloseTheSheet() {
        for outcome in ["connected", "cancelled", "dismissed"] {
            XCTAssertEqual(store.resolve(RemoteShellResolved(requestId: "r-\(outcome)", outcome: outcome), target: target),
                           .closeSheet, outcome)
        }
    }

    func testAnUnknownOutcomeJustClosesTheSheet() {
        XCTAssertEqual(store.resolve(RemoteShellResolved(requestId: "r1", outcome: "from_the_future"), target: nil), .closeSheet)
        XCTAssertEqual(store.resolve(RemoteShellResolved(requestId: "r2", outcome: ""), target: nil), .closeSheet)
    }

    func testTimedOutIsItsOwnResolution() {
        XCTAssertEqual(store.resolve(RemoteShellResolved(requestId: "r1", outcome: "timed_out"), target: target), .timedOut)
    }

    func testAFailedConnectionCarriesHeadingReasonRemedyAndDetail() {
        let resolved = RemoteShellResolved(requestId: "r1", outcome: "connect_failed", reason: "sso_expired",
                                           remedy: "Run aws sso login", detail: "token expired")
        XCTAssertEqual(store.resolve(resolved, target: target),
                       .failed(RemoteShellFailure(
                        heading: "Couldn't connect to PRODUCTION \u{00B7} admin-portal \u{00B7} scheduler",
                        reason: "AWS SSO session expired", remedy: "Run aws sso login", detail: "token expired")))
    }

    func testAnEmptyRemedyAndDetailBecomeNil() {
        let resolved = RemoteShellResolved(requestId: "r1", outcome: "connect_failed", reason: "aws_error",
                                           remedy: "", detail: "")
        guard case .failed(let failure) = store.resolve(resolved, target: target) else {
            return XCTFail("expected .failed")
        }
        XCTAssertNil(failure.remedy)
        XCTAssertNil(failure.detail)
        XCTAssertEqual(failure.reason, "The AWS CLI reported an error")
    }

    func testAFailureWithoutATargetHasABareHeadingAndAGenericReason() {
        let resolved = RemoteShellResolved(requestId: "r1", outcome: "connect_failed", reason: "not_available")
        XCTAssertEqual(store.resolve(resolved, target: nil),
                       .failed(RemoteShellFailure(heading: "Couldn't connect",
                                                  reason: "The connection could not be made",
                                                  remedy: nil, detail: nil)))
    }

    func testAFailureWithoutAReasonDoesNotTrap() {
        let resolved = RemoteShellResolved(requestId: "r1", outcome: "connect_failed")
        guard case .failed(let failure) = store.resolve(resolved, target: target) else {
            return XCTFail("expected .failed")
        }
        XCTAssertEqual(failure.reason, "The connection could not be made")
    }
    // MARK: What a pane shows while it connects

    func testAConnectingPaneNamesTheEnvironmentProjectAndServiceAsReceived() {
        XCTAssertEqual(RemoteShellStore.connectingMessage(for: target),
                       "Connecting to \(target.environment) \u{00B7} \(target.project) \u{00B7} \(target.service)\u{2026}")
        XCTAssertEqual(RemoteShellStore.connectingMessage(for: TerminalTarget(project: "admin-portal", environment: "production",
                                                                              service: "scheduler", shellType: "shell")),
                       "Connecting to production \u{00B7} admin-portal \u{00B7} scheduler\u{2026}")
    }
}
