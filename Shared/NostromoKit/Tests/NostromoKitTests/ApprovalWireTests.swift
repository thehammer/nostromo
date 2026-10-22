// NostromoKit — ApprovalWireTests.swift
//
// Wire-level tests for the permission-approval frames (AP0b). The golden JSON
// below is copied from the Rust tests in `src/ipc/protocol.rs`
// (`FULL_APPROVAL_WIRE_JSON`, `MINIMAL_APPROVAL_WIRE_JSON` and the per-frame
// goldens): if the daemon's wire changes, those fail first, and these must be
// updated to match.

import XCTest
@testable import NostromoKit

final class ApprovalWireTests: XCTestCase {

    // MARK: - Golden JSON (from the Rust tests)

    static let fullRequest = #"""
    {
        "request_id": "11111111-2222-3333-4444-555555555555",
        "tag": "cody-1",
        "tool_use_id": "toolu_1",
        "agent": { "name": "cody", "subagent": { "agent_id": "agent_abc", "agent_type": "general-purpose" } },
        "tool_name": "mcp__slack__post_message",
        "display_name": "Post message",
        "tool_kind": "mcp",
        "mcp": { "server": "slack", "tool": "post_message" },
        "input": { "channel": "#eng", "text": "hi", "nested": { "a": [1, 2, { "b": null }] } },
        "display": {
            "lines": [
                { "number": 1, "kind": "json", "segments": [
                    { "text": "{", "kind": "plain" },
                    { "text": "⟨U+202E RLO⟩", "kind": "invisible", "cp": 8238 },
                    { "text": "é", "kind": "non_ascii", "cp": 233 }
                ] },
                { "number": 2, "kind": "command", "cont": true, "segments": [ { "text": "&&", "kind": "separator" } ] }
            ],
            "command_count": 2,
            "invisible_count": 1,
            "non_ascii_count": 1,
            "unparsed": false
        },
        "cwd": "/work/proj",
        "reason": {
            "kind": "ask_rule",
            "text": "your rule Bash(rm:*) in ~/.claude/settings.json",
            "rule": { "rule": "Bash(rm:*)", "source_path": "~/.claude/settings.json", "found_by": "nostromo" }
        },
        "flags": {
            "default_to_no": true,
            "suppress_always_allow_rule": false,
            "requires_user_interaction": true,
            "classifier_approvable": false
        },
        "description": "post a message",
        "options": ["allow_once", "deny", "deny_and_stop", "deny_with_note"],
        "session_rule_candidates": [],
        "created_at_ms": 1760000000000,
        "deadline_at_ms": 1760000900000
    }
    """#

    static let minimalRequest = #"""
    {
        "request_id": "r-min",
        "tag": "t",
        "tool_use_id": "toolu_2",
        "agent": { "name": "cody" },
        "tool_name": "Bash",
        "display_name": "Bash",
        "tool_kind": "bash",
        "input": { "command": "ls" },
        "display": { "lines": [], "invisible_count": 0, "non_ascii_count": 0, "unparsed": false },
        "reason": { "kind": "other", "text": "Claude Code asked for approval" },
        "flags": {
            "default_to_no": false,
            "suppress_always_allow_rule": false,
            "requires_user_interaction": false,
            "classifier_approvable": false
        },
        "options": ["allow_once", "deny"],
        "session_rule_candidates": [],
        "created_at_ms": 1,
        "deadline_at_ms": 2
    }
    """#

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func encode<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - approval_request

    func testAFullyPopulatedRequestDecodesEveryField() throws {
        let r = try decode(ApprovalRequestWire.self, Self.fullRequest)
        XCTAssertEqual(r.requestId, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(r.id, r.requestId)
        XCTAssertEqual(r.tag, "cody-1")
        XCTAssertEqual(r.toolUseId, "toolu_1")
        XCTAssertEqual(r.agent, ApprovalAgent(name: "cody", subagent: ApprovalSubagent(agentId: "agent_abc", agentType: "general-purpose")))
        XCTAssertEqual(r.toolName, "mcp__slack__post_message")
        XCTAssertEqual(r.displayName, "Post message")
        XCTAssertEqual(r.toolKind, .mcp)
        XCTAssertEqual(r.mcp, ApprovalMcpTool(server: "slack", tool: "post_message"))
        XCTAssertEqual(r.cwd, "/work/proj")
        XCTAssertEqual(r.description, "post a message")
        XCTAssertEqual(r.options, [.allowOnce, .deny, .denyAndStop, .denyWithNote])
        XCTAssertEqual(r.sessionRuleCandidates, [])
        XCTAssertEqual(r.createdAtMs, 1_760_000_000_000)
        XCTAssertEqual(r.deadlineAtMs, 1_760_000_900_000)
        XCTAssertEqual(r.flags, ApprovalFlags(defaultToNo: true, suppressAlwaysAllowRule: false,
                                              requiresUserInteraction: true, classifierApprovable: false))
        XCTAssertEqual(r.reason.kind, .askRule)
        XCTAssertEqual(r.reason.rule, ApprovalFoundRule(rule: "Bash(rm:*)", sourcePath: "~/.claude/settings.json", foundBy: "nostromo"))
    }

    func testTheToolInputIsKeptAsReceivedIncludingNestingAndNull() throws {
        let r = try decode(ApprovalRequestWire.self, Self.fullRequest)
        let expected: ApprovalJSON = .object([
            "channel": .string("#eng"),
            "text": .string("hi"),
            "nested": .object(["a": .array([.int(1), .int(2), .object(["b": .null])])]),
        ])
        XCTAssertEqual(r.input, expected)
    }

    func testTheDisplayKeepsEverySegmentWithItsCodePointAndTheContFlag() throws {
        let r = try decode(ApprovalRequestWire.self, Self.fullRequest)
        XCTAssertEqual(r.display.commandCount, 2)
        XCTAssertEqual(r.display.invisibleCount, 1)
        XCTAssertEqual(r.display.nonAsciiCount, 1)
        XCTAssertFalse(r.display.unparsed)
        XCTAssertEqual(r.display.lines.count, 2)
        let first = r.display.lines[0]
        XCTAssertEqual(first.number, 1)
        XCTAssertEqual(first.kind, .json)
        XCTAssertFalse(first.cont, "an absent `cont` is false")
        XCTAssertEqual(first.segments.map(\.kind), [.plain, .invisible, .nonAscii])
        XCTAssertEqual(first.segments.map(\.cp), [nil, 8238, 233])
        XCTAssertEqual(first.segments[1].text, "⟨U+202E RLO⟩")
        let second = r.display.lines[1]
        XCTAssertEqual(second.kind, .command)
        XCTAssertTrue(second.cont)
        XCTAssertEqual(second.segments.map(\.kind), [.separator])
    }

    func testARequestWithOnlyTheRequiredFieldsDecodes() throws {
        let r = try decode(ApprovalRequestWire.self, Self.minimalRequest)
        XCTAssertEqual(r.requestId, "r-min")
        XCTAssertNil(r.agent.subagent)
        XCTAssertNil(r.mcp)
        XCTAssertNil(r.cwd)
        XCTAssertNil(r.description)
        XCTAssertNil(r.display.commandCount)
        XCTAssertNil(r.reason.rule)
        XCTAssertEqual(r.toolKind, .bash)
        XCTAssertEqual(r.options, [.allowOnce, .deny])
        XCTAssertEqual(r.flags, ApprovalFlags(defaultToNo: false, suppressAlwaysAllowRule: false,
                                              requiresUserInteraction: false, classifierApprovable: false))
    }

    func testValuesThisBuildDoesNotKnowFallBackInsteadOfFailingTheFrame() throws {
        let json = Self.minimalRequest
            .replacingOccurrences(of: #""tool_kind": "bash""#, with: #""tool_kind": "future_kind""#)
            .replacingOccurrences(of: #""options": ["allow_once", "deny"]"#, with: #""options": ["allow_once", "allow_session"]"#)
            .replacingOccurrences(of: #""kind": "other""#, with: #""kind": "future_reason""#)
        let r = try decode(ApprovalRequestWire.self, json)
        XCTAssertEqual(r.toolKind, .other)
        XCTAssertEqual(r.options, [.allowOnce, .unknown])
        XCTAssertEqual(r.reason.kind, .other)
    }

    func testTheRequestFrameAndTheSnapshotFrameDecode() throws {
        let frame = try decode(ApprovalRequestFrame.self,
                               #"{"type":"approval_request","tag":"cody-1","request":\#(Self.fullRequest)}"#)
        XCTAssertEqual(frame.tag, "cody-1")
        XCTAssertEqual(frame.request.tag, "cody-1", "the request carries its own tag, for the snapshot")

        let snap = try decode(ApprovalsSnapshotFrame.self,
                              #"{"type":"approvals_snapshot","requests":[\#(Self.fullRequest),\#(Self.minimalRequest)]}"#)
        XCTAssertEqual(snap.requests.map(\.requestId), ["11111111-2222-3333-4444-555555555555", "r-min"])

        let empty = try decode(ApprovalsSnapshotFrame.self, #"{"type":"approvals_snapshot","requests":[]}"#)
        XCTAssertTrue(empty.requests.isEmpty)
    }

    // MARK: - the small frames

    func testApprovalResolvedWithAndWithoutAWindow() throws {
        let answered = try decode(ApprovalResolvedFrame.self,
            #"{"type":"approval_resolved","tag":"cody-1","request_id":"r1","outcome":"allowed_once","by_window":"win-1","at_ms":1760000000123}"#)
        XCTAssertEqual(answered, ApprovalResolvedFrame(tag: "cody-1", requestId: "r1", outcome: "allowed_once",
                                                       byWindow: "win-1", atMs: 1_760_000_000_123))
        let timedOut = try decode(ApprovalResolvedFrame.self,
            #"{"type":"approval_resolved","tag":"cody-1","request_id":"r1","outcome":"timed_out","at_ms":7}"#)
        XCTAssertNil(timedOut.byWindow)
        XCTAssertEqual(timedOut.outcome, "timed_out")
    }

    func testApprovalPendingIsATagAndACount() throws {
        let f = try decode(ApprovalPendingFrame.self, #"{"type":"approval_pending","tag":"cody-1","count":2}"#)
        XCTAssertEqual(f, ApprovalPendingFrame(tag: "cody-1", count: 2))
    }

    func testApprovalGuardBlockedCarriesOnlyTheSummary() throws {
        let f = try decode(ApprovalGuardBlockedFrame.self,
            #"{"type":"approval_guard_blocked","tag":"cody-1","tool_use_id":"toolu_9","entry_id":"entry-1","at_ms":5,"summary":"Bash ecs_connect"}"#)
        XCTAssertEqual(f, ApprovalGuardBlockedFrame(tag: "cody-1", toolUseId: "toolu_9", entryId: "entry-1",
                                                    atMs: 5, summary: "Bash ecs_connect"))
    }

    func testApprovalAnswerRefusedEveryCodeAndTheOutcome() throws {
        let late = try decode(ApprovalAnswerRefusedFrame.self,
            #"{"type":"approval_answer_refused","request_id":"r1","code":"already_resolved","outcome":"allowed_once"}"#)
        XCTAssertEqual(late.code, .alreadyResolved)
        XCTAssertEqual(late.outcome, "allowed_once")
        for (name, code) in [("requires_secure_connection", ApprovalAnswerRefusalCode.requiresSecureConnection),
                             ("not_operator_app", .notOperatorApp),
                             ("already_resolved", .alreadyResolved),
                             ("unknown_request", .unknownRequest),
                             ("a_future_code", .unknown)] {
            let f = try decode(ApprovalAnswerRefusedFrame.self,
                #"{"type":"approval_answer_refused","request_id":"r1","code":"\#(name)"}"#)
            XCTAssertEqual(f.code, code, name)
            XCTAssertNil(f.outcome)
        }
    }

    // MARK: - outbound frames

    func testApprovalAnswerEncodesTheDaemonsKeys() throws {
        let allow = try encode(ClientApprovalAnswer(requestId: "r1", decision: ApprovalDecisionWire(kind: .allowOnce),
                                                    windowId: "win-1", operatorNonce: "ab12"))
        XCTAssertEqual(allow["type"] as? String, "approval_answer")
        XCTAssertEqual(allow["request_id"] as? String, "r1")
        XCTAssertEqual(allow["window_id"] as? String, "win-1")
        XCTAssertEqual(allow["operator_nonce"] as? String, "ab12")
        let decision = try XCTUnwrap(allow["decision"] as? [String: Any])
        XCTAssertEqual(decision["kind"] as? String, "allow_once")
        XCTAssertNil(decision["note"], "no note, no key")

        let deny = try encode(ClientApprovalAnswer(requestId: "r1", decision: ApprovalDecisionWire(kind: .deny, note: "use /tmp/y"),
                                                   windowId: "win-1", operatorNonce: nil))
        XCTAssertNil(deny["operator_nonce"], "no nonce, no key (the daemon then refuses it)")
        let denyDecision = try XCTUnwrap(deny["decision"] as? [String: Any])
        XCTAssertEqual(denyDecision["kind"] as? String, "deny")
        XCTAssertEqual(denyDecision["note"] as? String, "use /tmp/y")

        let stop = try encode(ClientApprovalAnswer(requestId: "r1", decision: ApprovalDecisionWire(kind: .denyAndStop),
                                                   windowId: "w", operatorNonce: nil))
        XCTAssertEqual((stop["decision"] as? [String: Any])?["kind"] as? String, "deny_and_stop")
    }

    func testRefusalReportEncodesTheDaemonsKeys() throws {
        let with = try encode(ClientApprovalRefusalReport(requestId: "r1", control: "allow_once", channel: .appControl))
        XCTAssertEqual(with["type"] as? String, "approval_refusal_report")
        XCTAssertEqual(with["request_id"] as? String, "r1")
        XCTAssertEqual(with["control"] as? String, "allow_once")
        XCTAssertEqual(with["channel"] as? String, "app_control")
        let without = try encode(ClientApprovalRefusalReport(requestId: nil, control: "deny", channel: .accessibility))
        XCTAssertNil(without["request_id"])
        XCTAssertEqual(without["channel"] as? String, "accessibility")
        XCTAssertEqual(try encode(ClientApprovalRefusalReport(requestId: nil, control: "x", channel: .unknown))["channel"] as? String, "unknown")
    }

    // MARK: - AskUserQuestion (AP2c)

    /// Sorted keys and unescaped slashes: the exact bytes, comparable as a string.
    private func exactJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    func testAnswerQuestionsIsAListedOptionAndStillOnlyWhatTheDaemonListed() throws {
        let json = Self.minimalRequest
            .replacingOccurrences(of: #""options": ["allow_once", "deny"]"#,
                                  with: #""options": ["allow_once", "deny", "answer_questions"]"#)
        XCTAssertEqual(try decode(ApprovalRequestWire.self, json).options, [.allowOnce, .deny, .answerQuestions])
        XCTAssertEqual(ApprovalOption.answerQuestions.rawValue, "answer_questions")

        let mixed = Self.minimalRequest
            .replacingOccurrences(of: #""options": ["allow_once", "deny"]"#,
                                  with: #""options": ["answer_questions", "answer_something_new"]"#)
        XCTAssertEqual(try decode(ApprovalRequestWire.self, mixed).options, [.answerQuestions, .unknown],
                       "an option this build does not know still falls back instead of failing the frame")
    }

    func testAnAskUserQuestionRequestDecodesWithItsInputKeptAsReceived() throws {
        let request = try Fx.askUserQuestionRequest()
        XCTAssertEqual(request.toolName, "AskUserQuestion")
        XCTAssertTrue(request.flags.requiresUserInteraction)
        XCTAssertEqual(request.options, [.allowOnce, .deny, .denyAndStop, .denyWithNote, .answerQuestions])
        guard case .object(let input) = request.input, case .array(let questions)? = input["questions"] else {
            return XCTFail("the input keeps its `questions` array: \(request.input)")
        }
        XCTAssertEqual(questions.count, 2)
    }

    func testTheInvalidAnswerRefusalDecodesAndOtherCodesStillDo() throws {
        let f = try decode(ApprovalAnswerRefusedFrame.self,
            #"{"type":"approval_answer_refused","request_id":"r1","code":"invalid_answer"}"#)
        XCTAssertEqual(f.code, .invalidAnswer)
        XCTAssertEqual(f.requestId, "r1")
        XCTAssertNil(f.outcome)
        XCTAssertEqual(ApprovalAnswerRefusalCode.invalidAnswer.rawValue, "invalid_answer")
        XCTAssertEqual(try decode(ApprovalAnswerRefusedFrame.self,
            #"{"type":"approval_answer_refused","request_id":"r1","code":"already_resolved","outcome":"answered"}"#).outcome,
                       "answered", "the outcome of a request answered elsewhere")
        XCTAssertEqual(try decode(ApprovalAnswerRefusedFrame.self,
            #"{"type":"approval_answer_refused","request_id":"r1","code":"invalid_answer_v2"}"#).code, .unknown)
    }

    func testAnAnsweredResolutionDecodes() throws {
        let f = try decode(ApprovalResolvedFrame.self,
            #"{"type":"approval_resolved","tag":"cody-1","request_id":"r1","outcome":"answered","by_window":"win-1","at_ms":9}"#)
        XCTAssertEqual(f.outcome, "answered")
        XCTAssertEqual(f.byWindow, "win-1")
    }

    func testTheAnswerQuestionsDecisionEncodesTheDaemonsExactJSON() throws {
        let decision = ApprovalDecisionWire(kind: .answerQuestions, answers: [
            ApprovalQuestionAnswer(question: "Q", selected: ["A"], other: "x"),
        ])
        XCTAssertEqual(try exactJSON(decision),
                       #"{"answers":[{"other":"x","question":"Q","selected":["A"]}],"kind":"answer_questions"}"#)
    }

    func testAnAnswerWithNoOtherTextHasNoOtherKeyAndAnOtherOnlyAnswerHasAnEmptySelectedList() throws {
        let decision = ApprovalDecisionWire(kind: .answerQuestions, answers: [
            ApprovalQuestionAnswer(question: "Which database should we use?", selected: ["Postgres"], other: nil),
            ApprovalQuestionAnswer(question: "Which features do you want to enable?", selected: ["Caching", "Tracing"], other: nil),
            ApprovalQuestionAnswer(question: "Anything else?", selected: [], other: "Logging"),
        ])
        let expected = #"{"answers":["#
            + #"{"question":"Which database should we use?","selected":["Postgres"]},"#
            + #"{"question":"Which features do you want to enable?","selected":["Caching","Tracing"]},"#
            + #"{"other":"Logging","question":"Anything else?","selected":[]}"#
            + #"],"kind":"answer_questions"}"#
        XCTAssertEqual(try exactJSON(decision), expected)
    }

    func testAnswerTextSurvivesEncodingByteForByte() throws {
        let text = "  Say \"hi\"\\ / é \u{1F642}\ttab\nnewline \u{200B} "
        let decision = ApprovalDecisionWire(kind: .answerQuestions, answers: [
            ApprovalQuestionAnswer(question: text, selected: [text + "1", text + "2"], other: text),
        ])
        let object = try encode(decision)
        let answers = try XCTUnwrap(object["answers"] as? [[String: Any]])
        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(answers[0]["question"] as? String, text)
        XCTAssertEqual(answers[0]["selected"] as? [String], [text + "1", text + "2"])
        XCTAssertEqual(answers[0]["other"] as? String, text, "the encoder never trims, folds or drops a character")
    }

    func testAnswerQuestionsGoesOutInTheFullApprovalAnswerFrame() throws {
        let frame = ClientApprovalAnswer(
            requestId: "r1",
            decision: ApprovalDecisionWire(kind: .answerQuestions, answers: [
                ApprovalQuestionAnswer(question: "Q", selected: ["A"], other: "x"),
            ]),
            windowId: "win-1", operatorNonce: "ab12")
        let expected = #"{"decision":{"answers":[{"other":"x","question":"Q","selected":["A"]}],"kind":"answer_questions"},"#
            + #""operator_nonce":"ab12","request_id":"r1","type":"approval_answer","window_id":"win-1"}"#
        XCTAssertEqual(try exactJSON(frame), expected)
    }

    func testTheExistingDecisionsEncodeWithoutAnAnswersKey() throws {
        for kind in [ApprovalDecisionKind.allowOnce, .deny, .denyAndStop] {
            let decision = try encode(ApprovalDecisionWire(kind: kind))
            XCTAssertEqual(Set(decision.keys), ["kind"], "\(kind)")
        }
        let withNote = try encode(ApprovalDecisionWire(kind: .deny, note: "use /tmp/y"))
        XCTAssertEqual(Set(withNote.keys), ["kind", "note"])
        XCTAssertEqual(try exactJSON(ApprovalDecisionWire(kind: .deny)), #"{"kind":"deny"}"#)
        XCTAssertEqual(try exactJSON(ApprovalDecisionWire(kind: .allowOnce)), #"{"kind":"allow_once"}"#)
        let frame = try encode(ClientApprovalAnswer(requestId: "r1", decision: ApprovalDecisionWire(kind: .deny),
                                                    windowId: "w", operatorNonce: nil))
        XCTAssertNil((frame["decision"] as? [String: Any])?["answers"])
    }

    func testDecisionsWithAndWithoutAnswersAreNotEqual() {
        let one = ApprovalQuestionAnswer(question: "Q", selected: ["A"], other: nil)
        XCTAssertEqual(ApprovalDecisionWire(kind: .answerQuestions, answers: [one]),
                       ApprovalDecisionWire(kind: .answerQuestions, answers: [one]))
        XCTAssertNotEqual(ApprovalDecisionWire(kind: .answerQuestions, answers: [one]),
                          ApprovalDecisionWire(kind: .answerQuestions, answers: [ApprovalQuestionAnswer(question: "Q", selected: ["B"], other: nil)]))
        XCTAssertNotEqual(ApprovalDecisionWire(kind: .answerQuestions, answers: [one]), ApprovalDecisionWire(kind: .answerQuestions))
        XCTAssertEqual(ApprovalDecisionWire(kind: .deny), ApprovalDecisionWire(kind: .deny, note: nil, answers: nil))
    }

    // MARK: - subscribe

    func testSubscribeEncodesRendersApprovalsAndDefaultsToFalse() throws {
        let plain = try encode(ClientSubscribe(topics: [], rendersDecisions: true))
        XCTAssertEqual(plain["renders_approvals"] as? Bool, false,
                       "present and false on the wire, not omitted: this client does not present approvals")
        let presenter = try encode(ClientSubscribe(topics: [], rendersDecisions: true, rendersApprovals: true))
        XCTAssertEqual(presenter["renders_approvals"] as? Bool, true)
        XCTAssertEqual(presenter["renders_decisions"] as? Bool, true)
    }
}
