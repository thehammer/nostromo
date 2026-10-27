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
                         reason: String? = nil) -> RemoteShellConfirmRequest {
        RemoteShellConfirmRequest(requestId: id, tag: tag, target: target ?? self.target,
                                  requestedBy: RemoteShellRequester(kind: kind, tag: requesterTag, agent: agent),
                                  reason: reason, expiresAt: "2026-10-25T12:00:00Z")
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

    func testAUserRequestHasNoRequesterLineEvenWithAReason() {
        XCTAssertNil(model(request(kind: "user")).requesterLine)
        XCTAssertNil(model(request(kind: "user", reason: "because")).requesterLine)
    }

    func testAnAgentRequestNamesTheAgentTheFocusAndTheReason() {
        XCTAssertEqual(model(agentRequest(reason: "Check stuck jobs on the scheduler")).requesterLine,
                       "Requested by cody in Core: \"Check stuck jobs on the scheduler\"")
    }

    func testAnAgentRequestWithoutAReasonOmitsTheSuffix() {
        XCTAssertEqual(model(agentRequest(reason: nil)).requesterLine, "Requested by cody in Core")
        XCTAssertEqual(model(agentRequest(reason: "")).requesterLine, "Requested by cody in Core")
        XCTAssertEqual(model(agentRequest(reason: " \n\t ")).requesterLine, "Requested by cody in Core")
    }

    func testTheFocusLabelFallsBackToTheRawTagThenToAFocus() {
        XCTAssertEqual(model(agentRequest(reason: nil), labels: [:]).requesterLine, "Requested by cody in core-1")
        XCTAssertEqual(model(request(kind: "focus", agent: "cody")).requesterLine, "Requested by cody in a focus")
    }

    func testTheRequestsTagIsPreferredOverTheRequestersTag() {
        let r = request(tag: "core-1", kind: "focus", requesterTag: "other-9", agent: "cody")
        XCTAssertEqual(model(r, labels: ["core-1": "Core", "other-9": "Other"]).requesterLine, "Requested by cody in Core")
        let onlyRequester = request(kind: "focus", requesterTag: "other-9", agent: "cody")
        XCTAssertEqual(model(onlyRequester, labels: ["other-9": "Other"]).requesterLine, "Requested by cody in Other")
    }

    func testAMissingAgentNameIsAnAgent() {
        let r = request(tag: "core-1", kind: "focus")
        XCTAssertEqual(model(r).requesterLine, "Requested by an agent in Core")
    }

    func testTheAgentNameIsShownVerbatim() {
        let r = request(tag: "core-1", kind: "focus", agent: "Cody <b>X</b>")
        XCTAssertEqual(model(r).requesterLine, "Requested by Cody <b>X</b> in Core")
    }

    func testALongReasonIsCutToTwoHundredCharactersEndingInAnEllipsis() throws {
        let line = try XCTUnwrap(model(agentRequest(reason: String(repeating: "a", count: 300))).requesterLine)
        let quoted = String(line.drop(while: { $0 != "\"" }))
        let reason = String(quoted.dropFirst().dropLast())
        XCTAssertEqual(reason.count, RemoteShellStore.reasonLimit)
        XCTAssertEqual(reason, String(repeating: "a", count: 199) + "\u{2026}")
    }

    func testAReasonOfExactlyTheLimitIsNotCut() throws {
        let exact = String(repeating: "b", count: RemoteShellStore.reasonLimit)
        let line = try XCTUnwrap(model(agentRequest(reason: exact)).requesterLine)
        XCTAssertTrue(line.hasSuffix("\"\(exact)\""), line)
        XCTAssertFalse(line.contains("\u{2026}"))
    }

    func testNewlinesAndControlCharactersBecomeSingleSpaces() {
        let line = model(agentRequest(reason: "  look\n\nat   the\tscheduler\u{1b}[31m now\r\n ")).requesterLine
        XCTAssertEqual(line, "Requested by cody in Core: \"look at the scheduler [31m now\"")
    }

    func testMarkupInAReasonStaysVerbatim() {
        XCTAssertEqual(model(agentRequest(reason: "<b>x</b> and **x**")).requesterLine,
                       "Requested by cody in Core: \"<b>x</b> and **x**\"")
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
