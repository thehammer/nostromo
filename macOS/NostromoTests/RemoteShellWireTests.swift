import XCTest

// The remote-shell wire (`RemoteShellWire.swift`) against the JSON the daemon's serde produces
// (`src/ipc/protocol.rs`: `remote_shell_client_messages_round_trip_with_their_wire_names`,
// `remote_shell_targets_*`, `remote_shell_confirm_request_round_trips_for_an_agent_and_for_the_user`,
// `remote_shell_resolved_round_trips_with_and_without_a_reason`).

final class RemoteShellWireTests: XCTestCase {

    private let target = TerminalTarget(project: "admin-portal", environment: "production",
                                        service: "scheduler", shellType: "shell")

    private func object(_ message: RemoteShellClientMessage) throws -> [String: Any] {
        let data = try XCTUnwrap(message.encoded())
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: Client messages

    func testEveryClientMessageCarriesItsWireName() throws {
        let cases: [(RemoteShellClientMessage, String)] = [
            (.targetsRequest, "remote_shell_targets_request"),
            (.open(tag: "core-1", target: target), "remote_shell_open"),
            (.answer(requestId: "r1", decision: .connect), "remote_shell_answer"),
        ]
        for (message, name) in cases {
            XCTAssertEqual(message.wireType, name)
            XCTAssertEqual(try object(message)["type"] as? String, name)
        }
    }

    func testTheTargetsRequestIsJustItsType() throws {
        let v = try object(.targetsRequest)
        XCTAssertEqual(Set(v.keys), ["type"])
    }

    func testOpenCarriesTheTagAndTheFourTargetFieldsFlat() throws {
        let v = try object(.open(tag: "core-1", target: target))
        XCTAssertEqual(v["tag"] as? String, "core-1")
        XCTAssertEqual(v["project"] as? String, "admin-portal")
        XCTAssertEqual(v["environment"] as? String, "production")
        XCTAssertEqual(v["service"] as? String, "scheduler")
        XCTAssertEqual(v["shell_type"] as? String, "shell")
        XCTAssertEqual(Set(v.keys), ["type", "tag", "project", "environment", "service", "shell_type"])
    }

    func testAnAnswerCarriesTheDecisionAndNeverInvitesAFollow() throws {
        let cases: [(RemoteShellDecision, String)] = [(.connect, "connect"), (.cancel, "cancel"), (.dismiss, "dismiss")]
        for (decision, name) in cases {
            let v = try object(.answer(requestId: "r1", decision: decision))
            XCTAssertEqual(v["request_id"] as? String, "r1")
            XCTAssertEqual(v["decision"] as? String, name)
            XCTAssertEqual(v["invite_follow"] as? Bool, false, "invite_follow is always false in this slice (\(name))")
        }
    }

    func testJsonObjectAndEncodedAgree() throws {
        let message = RemoteShellClientMessage.answer(requestId: "r9", decision: .cancel)
        let fromData = try object(message)
        XCTAssertEqual(NSDictionary(dictionary: fromData), NSDictionary(dictionary: message.jsonObject))
    }

    // MARK: Confirm request

    func testAnAgentsConfirmRequestDecodesAndIgnoresTheAdditiveKeys() throws {
        let request = try decode(RemoteShellConfirmRequest.self, """
        {"type":"remote_shell_confirm_request","request_id":"r1","tag":"core-1",
         "target":{"project":"admin-portal","environment":"production","service":"scheduler","shell_type":"shell"},
         "requested_by":{"kind":"focus","tag":"core-1","agent":"cody"},
         "reason":"look at the scheduler","expires_at":"2026-10-25T12:00:00Z",
         "shell_command":"/bin/bash","profile":"prod-profile","cluster":"prod-ecs"}
        """)
        XCTAssertEqual(request, RemoteShellConfirmRequest(
            requestId: "r1", tag: "core-1", target: target,
            requestedBy: RemoteShellRequester(kind: "focus", tag: "core-1", agent: "cody"),
            reason: "look at the scheduler", expiresAt: "2026-10-25T12:00:00Z"))
    }

    func testAUsersConfirmRequestHasNoReasonTagOrAgent() throws {
        let request = try decode(RemoteShellConfirmRequest.self, """
        {"type":"remote_shell_confirm_request","request_id":"r2",
         "target":{"project":"admin-portal","environment":"production","service":"scheduler","shell_type":"shell"},
         "requested_by":{"kind":"user"},"expires_at":"2026-10-25T12:00:00Z"}
        """)
        XCTAssertEqual(request.requestId, "r2")
        XCTAssertNil(request.tag)
        XCTAssertNil(request.reason)
        XCTAssertEqual(request.requestedBy, RemoteShellRequester(kind: "user", tag: nil, agent: nil))
        XCTAssertEqual(request.target, target)
    }

    // MARK: Targets

    func testConfiguredTargetsDecodeProjectsShellTypesAndRepoPaths() throws {
        let targets = try decode(RemoteShellTargets.self, """
        {"type":"remote_shell_targets","configured":true,
         "projects":[
           {"name":"admin-portal","default_service":"portal","environments":[
              {"name":"production","services":["portal","scheduler"]},
              {"name":"demo","services":[]}]},
           {"name":"p","environments":[]}],
         "shell_types":["shell","console","tinker"],
         "repo_paths":{"admin-portal":["~/Code/admin-portal"],"p":[]}}
        """)
        XCTAssertTrue(targets.configured)
        XCTAssertNil(targets.problem)
        XCTAssertEqual(targets.projects, [
            RemoteShellProject(name: "admin-portal", defaultService: "portal", environments: [
                RemoteShellEnvironment(name: "production", services: ["portal", "scheduler"]),
                RemoteShellEnvironment(name: "demo", services: [])]),
            RemoteShellProject(name: "p", defaultService: nil, environments: []),
        ])
        XCTAssertEqual(targets.shellTypes, ["shell", "console", "tinker"])
        XCTAssertEqual(targets.repoPaths, ["admin-portal": ["~/Code/admin-portal"], "p": []])
    }

    func testUnconfiguredTargetsCarryTheProblem() throws {
        let targets = try decode(RemoteShellTargets.self, """
        {"type":"remote_shell_targets","configured":false,"problem":"no ECS config.json found",
         "projects":[],"shell_types":[]}
        """)
        XCTAssertFalse(targets.configured)
        XCTAssertEqual(targets.problem, "no ECS config.json found")
        XCTAssertEqual(targets.projects, [])
    }

    func testATargetsFrameWithOnlyConfiguredStillDecodes() throws {
        let targets = try decode(RemoteShellTargets.self, #"{"type":"remote_shell_targets","configured":false}"#)
        XCTAssertEqual(targets, RemoteShellTargets(configured: false))
        XCTAssertEqual(targets.projects, [])
        XCTAssertEqual(targets.shellTypes, [])
        XCTAssertEqual(targets.repoPaths, [:])
    }

    // MARK: Resolved

    func testAConnectedResolutionHasNoReasonOrRemedy() throws {
        let resolved = try decode(RemoteShellResolved.self,
                                  #"{"type":"remote_shell_resolved","request_id":"r1","outcome":"connected"}"#)
        XCTAssertEqual(resolved, RemoteShellResolved(requestId: "r1", outcome: "connected"))
        XCTAssertNil(resolved.reason)
        XCTAssertNil(resolved.remedy)
        XCTAssertNil(resolved.detail)
    }

    func testAFailedConnectionCarriesReasonRemedyAndDetail() throws {
        let resolved = try decode(RemoteShellResolved.self, """
        {"type":"remote_shell_resolved","request_id":"r1","outcome":"connect_failed",
         "reason":"sso_expired","remedy":"Run aws sso login","detail":"first line"}
        """)
        XCTAssertEqual(resolved, RemoteShellResolved(requestId: "r1", outcome: "connect_failed",
                                                     reason: "sso_expired", remedy: "Run aws sso login",
                                                     detail: "first line"))
    }
}
