// NostromoKit — PersistedRulesWireTests.swift
//
// AP6 wire: the `approval_rules` frame, the `allow_always` decision, the three rule-management
// frames, and the request/refusal fields that came with them. Lenient on the way in (an unknown
// value never fails the frame), exact on the way out.

import XCTest
@testable import NostromoKit

final class PersistedRulesWireTests: XCTestCase {
    typealias Fx = ApprovalFixtures

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func encoded<T: Encodable>(_ value: T) throws -> NSDictionary {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    // MARK: inbound

    func testTheRulesFrameDecodesRulesTheQuarantineAndThePath() throws {
        let frame = try decode(ApprovalRulesFrame.self, #"""
        {"type":"approval_rules","path":"/Users/h/.nostromo/approvals/rules.json",
         "rules":[{"id":"r1","rule_text":"Bash(ls /a/b)","summary":"s","kind":"exact","scope":"repo","root":"/Users/h/Code/x",
                   "created_at_ms":5,"created_from_request_id":"req-9","uses":2,"active":true},
                  {"id":"r2","rule_text":"Bash(rm -rf /a/:*)","summary":"s","kind":"path_prefix","scope":"all_repos",
                   "created_at_ms":6,"created_from_request_id":"req-10","uses":0,"active":false,"inactive_reason":"path_changed"}],
         "quarantined":{"reason":"external_change","file_sha256":"abc123",
                        "rules_in_file":[{"id":"q1","rule_text":"Bash(ls)","kind":"exact","scope":"all_repos","active":true}]}}
        """#)
        XCTAssertEqual(frame.path, "/Users/h/.nostromo/approvals/rules.json")
        XCTAssertEqual(frame.rules.map(\.id), ["r1", "r2"])
        XCTAssertEqual(frame.rules[0], PersistedRule(id: "r1", ruleText: "Bash(ls /a/b)", summary: "s", kind: .exact, scope: .repo,
                                                     root: "/Users/h/Code/x", createdAtMs: 5, createdFromRequestId: "req-9",
                                                     uses: 2, active: true, inactiveReason: nil))
        XCTAssertEqual(frame.rules[1].scope, .allRepos)
        XCTAssertEqual(frame.rules[1].kind, .pathPrefix)
        XCTAssertFalse(frame.rules[1].active)
        XCTAssertEqual(frame.rules[1].inactiveReason, "path_changed")
        let q = try XCTUnwrap(frame.quarantined)
        XCTAssertEqual(q.reason, "external_change")
        XCTAssertEqual(q.fileSha256, "abc123")
        XCTAssertEqual(q.rulesInFile.map(\.id), ["q1"])
    }

    func testTheRulesFrameWithoutAQuarantineDecodesWithNone() throws {
        let frame = try decode(ApprovalRulesFrame.self, #"{"type":"approval_rules","path":"/p","rules":[]}"#)
        XCTAssertEqual(frame.rules, [])
        XCTAssertNil(frame.quarantined)
    }

    func testARuleOfAKindThisBuildDoesNotKnowDecodesAndOneItCannotReadIsDroppedNotFatal() throws {
        let frame = try decode(ApprovalRulesFrame.self, #"""
        {"type":"approval_rules","path":"/p","rules":[
          {"id":"a","rule_text":"Bash(x)","kind":"future_kind","scope":"repo","active":true},
          {"id":"b","rule_text":"Bash(y)","kind":"exact","scope":"future_scope","active":true},
          {"id":"c"},
          "junk",
          {"id":"d","rule_text":"Bash(z)","kind":"exact","scope":"all_repos","active":true}]}
        """#)
        XCTAssertEqual(frame.rules.map(\.id), ["a", "d"])
        XCTAssertEqual(frame.rules[0].kind, .unknown)
    }

    func testAnUnknownOptionAndAnUnknownRefusalCodeDecodeWithoutFailingTheFrame() throws {
        let refused = try decode(ApprovalAnswerRefusedFrame.self,
                                 #"{"type":"approval_answer_refused","request_id":"r","code":"future_code","reason":"x"}"#)
        XCTAssertEqual(refused.code, .unknown)
        let request = try Fx.request(input: ["command": "ls"], display: Fx.bashCase("simple_rm").display(),
                                     options: ["allow_once", "allow_always", "allow_forever_and_ever"])
        XCTAssertEqual(request.options, [.allowOnce, .allowAlways, .unknown])
    }

    func testTheNewRefusalCodesAndTheirReasonDecode() throws {
        for (raw, code) in [("rule_refused", ApprovalAnswerRefusalCode.ruleRefused),
                            ("rule_write_failed", .ruleWriteFailed), ("rules_quarantined", .rulesQuarantined),
                            ("rule_limit", .ruleLimit)] {
            let f = try decode(ApprovalAnswerRefusedFrame.self,
                               #"{"type":"approval_answer_refused","request_id":"r1","code":"\#(raw)"}"#)
            XCTAssertEqual(f.code, code, raw)
            XCTAssertNil(f.reason, raw)
        }
        let withReason = try decode(ApprovalAnswerRefusedFrame.self,
            #"{"type":"approval_answer_refused","request_id":"r1","code":"rule_refused","reason":"That rule is too broad"}"#)
        XCTAssertEqual(withReason.reason, "That rule is too broad")
    }

    func testARequestCarriesTheRepoRootAndWhetherItIsGitAndAbsentMeansNilAndFalse() throws {
        let with = try Fx.request(input: ["command": "ls"], display: Fx.bashCase("simple_rm").display(),
                                  repoRoot: "/Users/h/Code/x", repoIsGit: true)
        XCTAssertEqual(with.repoRoot, "/Users/h/Code/x")
        XCTAssertTrue(with.repoIsGit)
        let folder = try Fx.request(input: ["command": "ls"], display: Fx.bashCase("simple_rm").display(),
                                    repoRoot: "/tmp/y", repoIsGit: false)
        XCTAssertEqual(folder.repoRoot, "/tmp/y")
        XCTAssertFalse(folder.repoIsGit)
        let without = try Fx.request(input: ["command": "ls"], display: Fx.bashCase("simple_rm").display())
        XCTAssertNil(without.repoRoot)
        XCTAssertFalse(without.repoIsGit)
    }

    // MARK: outbound

    func testAnAllowAlwaysDecisionEncodesExactlyForBothScopes() throws {
        XCTAssertEqual(try encoded(ApprovalDecisionWire(kind: .allowAlways, candidateId: "c1", ruleText: "Bash(ls /a/b)", scope: .repo)),
                       ["kind": "allow_always", "candidate_id": "c1", "rule_text": "Bash(ls /a/b)", "scope": "repo"] as NSDictionary)
        XCTAssertEqual(try encoded(ApprovalDecisionWire(kind: .allowAlways, candidateId: "c1", ruleText: "Bash(ls /a/b)", scope: .allRepos)),
                       ["kind": "allow_always", "candidate_id": "c1", "rule_text": "Bash(ls /a/b)", "scope": "all_repos"] as NSDictionary)
        // The other decisions carry no scope.
        XCTAssertNil(try encoded(ApprovalDecisionWire(kind: .allowSession, candidateId: "c", ruleText: "t"))["scope"])
        XCTAssertEqual(Set((try encoded(ApprovalDecisionWire(kind: .allowOnce))).allKeys as! [String]), ["kind"])
    }

    func testTheRuleManagementFramesEncodeExactly() throws {
        XCTAssertEqual(try encoded(ClientApprovalRemoveRule(ruleId: "r1", operatorNonce: "n")),
                       ["type": "approval_remove_rule", "rule_id": "r1", "operator_nonce": "n"] as NSDictionary)
        XCTAssertEqual(try encoded(ClientApprovalRemoveRule(ruleId: "r1", operatorNonce: nil)),
                       ["type": "approval_remove_rule", "rule_id": "r1"] as NSDictionary)
        XCTAssertEqual(try encoded(ClientApprovalRulesKeep(fileSha256: "abc", operatorNonce: "n")),
                       ["type": "approval_rules_keep", "file_sha256": "abc", "operator_nonce": "n"] as NSDictionary)
        XCTAssertEqual(try encoded(ClientApprovalRulesKeep(fileSha256: "abc", operatorNonce: nil)),
                       ["type": "approval_rules_keep", "file_sha256": "abc"] as NSDictionary)
        XCTAssertEqual(try encoded(ClientApprovalRulesDiscard(operatorNonce: "n")),
                       ["type": "approval_rules_discard", "operator_nonce": "n"] as NSDictionary)
        XCTAssertEqual(try encoded(ClientApprovalRulesDiscard(operatorNonce: nil)),
                       ["type": "approval_rules_discard"] as NSDictionary)
    }

    func testAnAllowAlwaysAnswerFrameCarriesTheDecisionInsideTheAnswer() throws {
        let answer = ClientApprovalAnswer(
            requestId: "r1",
            decision: ApprovalDecisionWire(kind: .allowAlways, candidateId: "c1", ruleText: "Bash(ls)", scope: .repo),
            windowId: "w", operatorNonce: "n")
        let o = try encoded(answer)
        XCTAssertEqual(o["type"] as? String, "approval_answer")
        XCTAssertEqual((o["decision"] as? NSDictionary)?["scope"] as? String, "repo")
    }
}
