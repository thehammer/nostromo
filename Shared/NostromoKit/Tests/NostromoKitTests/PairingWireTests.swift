// NostromoKit — PairingWireTests.swift
//
// Wire fixtures for the device-pairing and satellite-host frames (W9, W10), as the phone decodes
// and encodes them. The JSON mirrors `src/ipc/protocol.rs`: if the daemon's wire changes, its Rust
// tests fail first and these must follow.
//
// `ServerMsg` is not `Equatable`, so each test matches the case it expects.

import XCTest
@testable import NostromoKit

final class PairingWireTests: XCTestCase {

    // MARK: Helpers

    private func decode(_ json: String) -> ServerMsg { ServerMsg.decode(from: Data(json.utf8)) }
    private func decodeHosted(_ json: String) -> HostedServerMsg { ServerMsg.decodeHosted(from: Data(json.utf8)) }

    private func wire<T: Encodable>(_ value: T) throws -> NSDictionary {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        return try XCTUnwrap(object as? NSDictionary)
    }

    // MARK: - pair_offer

    func testPairOfferDecodesWithKnowsDevice() {
        let msg = decode(#"{"type":"pair_offer","name_hint":"Hammer's Mac","server_id":"srv-1","challenge":"abc","knows_device":true}"#)
        guard case let .pairOffer(nameHint, serverId, challenge, knowsDevice) = msg else {
            return XCTFail("expected pairOffer, got \(msg)")
        }
        XCTAssertEqual(nameHint, "Hammer's Mac")
        XCTAssertEqual(serverId, "srv-1")
        XCTAssertEqual(challenge, "abc")
        XCTAssertEqual(knowsDevice, true)
    }

    func testPairOfferWithoutKnowsDeviceHasNilAndNotFalse() {
        let msg = decode(#"{"type":"pair_offer","name_hint":"Mac","server_id":"srv-1","challenge":"abc"}"#)
        guard case let .pairOffer(_, _, _, knowsDevice) = msg else { return XCTFail("expected pairOffer, got \(msg)") }
        XCTAssertNil(knowsDevice, "Absent means the server was not asked; it is not a no")
    }

    func testPairOfferKeepsAnExplicitFalseKnowsDevice() {
        let msg = decode(#"{"type":"pair_offer","name_hint":"Mac","server_id":"srv-1","challenge":"abc","knows_device":false}"#)
        guard case let .pairOffer(_, _, _, knowsDevice) = msg else { return XCTFail("expected pairOffer, got \(msg)") }
        XCTAssertEqual(knowsDevice, false)
    }

    func testPairOfferWithANullNameHintDecodes() {
        let msg = decode(#"{"type":"pair_offer","name_hint":null,"server_id":"srv-1","challenge":"abc"}"#)
        guard case let .pairOffer(nameHint, serverId, _, _) = msg else { return XCTFail("expected pairOffer, got \(msg)") }
        XCTAssertNil(nameHint)
        XCTAssertEqual(serverId, "srv-1")
    }

    func testPairOfferWithoutANameHintKeyDecodes() {
        let msg = decode(#"{"type":"pair_offer","server_id":"srv-1","challenge":"abc"}"#)
        guard case let .pairOffer(nameHint, _, _, _) = msg else { return XCTFail("expected pairOffer, got \(msg)") }
        XCTAssertNil(nameHint)
    }

    // MARK: - paired

    func testPairedDecodesAndTheTokenIsRedactedWhenPrinted() {
        let secret = "c2VjcmV0LXRva2VuLWZvci10aGUtd2lyZS1maXh0dXJl"
        let msg = decode(#"{"type":"paired","device_id":"dev-9","token":"\#(secret)","name":"Hammer's iPhone","server_id":"srv-1","replaced":true}"#)
        guard case let .paired(deviceId, token, name, serverId, replaced) = msg else {
            return XCTFail("expected paired, got \(msg)")
        }
        XCTAssertEqual(deviceId, "dev-9")
        XCTAssertEqual(token.value, secret)
        XCTAssertEqual(name, "Hammer's iPhone")
        XCTAssertEqual(serverId, "srv-1")
        XCTAssertTrue(replaced)

        var dumped = ""
        dump(msg, to: &dumped)
        for text in ["\(token)", String(reflecting: token), "\(msg)", String(reflecting: msg), dumped] {
            XCTAssertFalse(text.contains(secret), "The token leaked into: \(text.prefix(120))")
        }
    }

    func testPairedWithoutReplacedIsFalse() {
        let msg = decode(#"{"type":"paired","device_id":"dev-9","token":"t","name":"Phone","server_id":"srv-1"}"#)
        guard case let .paired(_, _, _, _, replaced) = msg else { return XCTFail("expected paired, got \(msg)") }
        XCTAssertFalse(replaced)
    }

    func testPairedMissingItsTokenIsNotAPairedFrame() {
        let msg = decode(#"{"type":"paired","device_id":"dev-9","name":"Phone","server_id":"srv-1"}"#)
        if case .paired = msg { XCTFail("a paired frame without a token must not decode as paired") }
    }

    // MARK: - pair_refused

    func testPairRefusedDecodesBothReasons() {
        guard case .pairRefused(let expired) = decode(#"{"type":"pair_refused","reason":"expired"}"#) else {
            return XCTFail("expected pairRefused")
        }
        XCTAssertEqual(expired, .expired)
        guard case .pairRefused(let invalid) = decode(#"{"type":"pair_refused","reason":"invalid"}"#) else {
            return XCTFail("expected pairRefused")
        }
        XCTAssertEqual(invalid, .invalid)
    }

    func testPairRefusedWithAnUnknownReasonIsInvalid() {
        guard case .pairRefused(let reason) = decode(#"{"type":"pair_refused","reason":"rate_limited"}"#) else {
            return XCTFail("expected pairRefused")
        }
        XCTAssertEqual(reason, .invalid)
    }

    // MARK: - unauthorized, device_unpaired

    func testUnauthorizedCarriesTheServersReason() {
        for reason in ["revoked", "unknown", "not_paired"] {
            guard case .unauthorized(let decoded) = decode(#"{"type":"unauthorized","reason":"\#(reason)"}"#) else {
                return XCTFail("expected unauthorized for \(reason)")
            }
            XCTAssertEqual(decoded, reason)
        }
    }

    func testDeviceUnpairedDecodes() {
        guard case .deviceUnpaired = decode(#"{"type":"device_unpaired"}"#) else {
            return XCTFail("expected deviceUnpaired")
        }
    }

    // MARK: - hosts, host_unavailable

    func testHostsDecodesEgressAndDefaultsAnAbsentOneToTheStrictWork() {
        let msg = decode("""
        {"type":"hosts","hosts":[
          {"name":"kobe","egress":"work","connected_since":"2026-11-01T10:00:00Z","last_seen":"2026-11-01T10:05:00Z"},
          {"name":"studio","egress":"personal","connected_since":"2026-11-01T10:00:00Z","last_seen":"2026-11-01T10:05:00Z"},
          {"name":"mini"}
        ]}
        """)
        guard case .hosts(let hosts) = msg else { return XCTFail("expected hosts, got \(msg)") }
        let connected = Date(timeIntervalSince1970: 1_793_527_200)   // 2026-11-01T10:00:00Z
        let seen = Date(timeIntervalSince1970: 1_793_527_500)        // 2026-11-01T10:05:00Z
        XCTAssertEqual(hosts, [
            HostInfoWire(name: "kobe", egress: .work, connectedSince: connected, lastSeen: seen),
            HostInfoWire(name: "studio", egress: .personal, connectedSince: connected, lastSeen: seen),
            HostInfoWire(name: "mini", egress: .work),
        ])
    }

    func testAnUnknownEgressIsTheStrictWork() {
        guard case .hosts(let hosts) = decode(#"{"type":"hosts","hosts":[{"name":"x","egress":"anything"}]}"#) else {
            return XCTFail("expected hosts")
        }
        XCTAssertEqual(hosts.first?.egress, .work)
    }

    func testAnEmptyHostsListDecodes() {
        guard case .hosts(let hosts) = decode(#"{"type":"hosts","hosts":[]}"#) else { return XCTFail("expected hosts") }
        XCTAssertTrue(hosts.isEmpty)
    }

    func testHostUnavailableDecodesEachKnownReason() {
        let cases: [(String, HostUnavailableReason)] = [
            ("not_connected", .notConnected),
            ("egress_metadata", .egressMetadata),
            ("busy", .busy),
            ("unavailable", .unavailable),
        ]
        for (raw, expected) in cases {
            guard case let .hostUnavailable(host, reason) = decode(#"{"type":"host_unavailable","host":"kobe","reason":"\#(raw)"}"#) else {
                return XCTFail("expected hostUnavailable for \(raw)")
            }
            XCTAssertEqual(host, "kobe")
            XCTAssertEqual(reason, expected, raw)
        }
    }

    func testHostUnavailableWithAnUnknownReasonIsUnavailable() {
        // The Rust decoder does the same: `HostUnavailableReason` has `#[serde(other)] Unavailable`.
        guard case let .hostUnavailable(host, reason) = decode(#"{"type":"host_unavailable","host":"kobe","reason":"on_fire"}"#) else {
            return XCTFail("expected hostUnavailable")
        }
        XCTAssertEqual(host, "kobe")
        XCTAssertEqual(reason, .unavailable)
    }

    // MARK: - withheld

    func testWithheldDecodesItsTopicsAndReason() {
        guard case let .withheld(topics, reason) = decode(#"{"type":"withheld","topics":["fred","teri","work"],"reason":"not_shared"}"#) else {
            return XCTFail("expected withheld")
        }
        XCTAssertEqual(topics, ["fred", "teri", "work"])
        XCTAssertEqual(reason, "not_shared")
    }

    // MARK: - decodeHosted

    func testADecodedFrameNamesTheHostItCameFrom() {
        let cases: [(String, String)] = [
            ("mother_jobs", #"{"type":"mother_jobs","jobs":[]%@}"#),
            ("session_list_resp", #"{"type":"session_list_resp","sessions":[]%@}"#),
            ("approval_pending", #"{"type":"approval_pending","tag":"cody-1","count":2%@}"#),
            ("decision_request", #"{"type":"decision_request","tag":"fred","request_id":"req-1","prompt":"Deploy?","choices":[{"id":"yes","label":"Yes"}]%@}"#),
        ]
        for (name, template) in cases {
            let without = decodeHosted(template.replacingOccurrences(of: "%@", with: ""))
            XCTAssertNil(without.host, "\(name) without host")
            let with = decodeHosted(template.replacingOccurrences(of: "%@", with: #","host":"kobe""#))
            XCTAssertEqual(with.host, "kobe", "\(name) with host")
        }
    }

    func testHostedFramesStillDecodeTheirMessage() {
        let jobs = decodeHosted(#"{"type":"mother_jobs","host":"kobe","jobs":[{"id":"j1","state":"running","title":"T"}]}"#)
        guard case .motherJobs(let decoded) = jobs.msg else { return XCTFail("expected motherJobs, got \(jobs.msg)") }
        XCTAssertEqual(decoded.map(\.id), ["j1"])

        let sessions = decodeHosted(#"{"type":"session_list_resp","host":"kobe","sessions":[]}"#)
        guard case .sessionListResp(let list) = sessions.msg else { return XCTFail("expected sessionListResp") }
        XCTAssertTrue(list.isEmpty)

        let decision = decodeHosted(#"{"type":"decision_request","host":"kobe","tag":"fred","request_id":"req-1","prompt":"Deploy?","choices":[{"id":"yes","label":"Yes"}]}"#)
        guard case let .decisionRequest(tag, requestId, prompt, _, choices, _) = decision.msg else {
            return XCTFail("expected decisionRequest, got \(decision.msg)")
        }
        XCTAssertEqual([tag, requestId, prompt], ["fred", "req-1", "Deploy?"])
        XCTAssertEqual(choices.map(\.id), ["yes"])
    }

    func testAnUnknownFrameKeepsItsHost() {
        let hosted = decodeHosted(#"{"type":"something_from_the_future","host":"kobe"}"#)
        XCTAssertEqual(hosted.host, "kobe")
        guard case .unknown = hosted.msg else { return XCTFail("expected unknown, got \(hosted.msg)") }
    }

    func testAMetadataOnlyWorkHostMotherJobsFrameDecodes() {
        // The shape a `work` satellite's primary publishes (`metadata_job` in `uplink_redact.rs`): the
        // id is a short ref, `title`/`repo` are present but empty, every free-text field is null, and
        // only fixed-vocabulary state remains.
        let frame = """
        {"type":"mother_jobs","host":"kobe","jobs":[{
          "id":"a1b2c3d4","state":"running","repo":"","isolation":"","title":"",
          "created_at":null,"started_at":null,"finished_at":null,"plan_path":null,"question":null,
          "paused_reason":null,"adherence_notes":null,"adherence_status":null,"current_tier":null,
          "current_activity":null,"kind":null,"phases":[],"cycles":[],
          "activity":"gating","crew_opt_in":true
        }]}
        """
        let hosted = decodeHosted(frame)
        XCTAssertEqual(hosted.host, "kobe")
        guard case .motherJobs(let jobs) = hosted.msg else {
            return XCTFail("a metadata-only work-host frame must decode, got \(hosted.msg)")
        }
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.id, "a1b2c3d4")
        XCTAssertEqual(jobs.first?.state, "running")
        XCTAssertEqual(jobs.first?.title, "")
        XCTAssertNil(jobs.first?.question)
        XCTAssertNil(jobs.first?.prUrl)
    }

    func testAMotherJobWithOnlyItsIdAndStateStillDecodes() {
        // A work host publishes metadata only (W10). Whatever free text it leaves out, including
        // the title, must not cost the whole `mother_jobs` frame (iOS decodes it all-or-nothing).
        let hosted = decodeHosted(#"{"type":"mother_jobs","host":"kobe","jobs":[{"id":"a1b2c3d4","state":"paused"},{"id":"e5f6a7b8","state":"queued"}]}"#)
        guard case .motherJobs(let jobs) = hosted.msg else {
            return XCTFail("a job with no title must not make the frame fail to decode, got \(hosted.msg)")
        }
        XCTAssertEqual(jobs.map(\.id), ["a1b2c3d4", "e5f6a7b8"])
        XCTAssertEqual(jobs.map(\.state), ["paused", "queued"])
        XCTAssertEqual(jobs.map(\.title), ["", ""])
    }

    // MARK: - welcomeFeatures

    func testWelcomeFeaturesListsWhatTheServerAdvertises() {
        let data = Data(#"{"type":"welcome","protocol_version":4,"daemon_pid":1,"features":["ws","pair","hosts"]}"#.utf8)
        XCTAssertEqual(ServerMsg.welcomeFeatures(from: data), ["ws", "pair", "hosts"])
    }

    func testWelcomeFeaturesIsEmptyWhenAbsentOrNotAWelcome() {
        XCTAssertEqual(ServerMsg.welcomeFeatures(from: Data(#"{"type":"welcome","protocol_version":4,"daemon_pid":1}"#.utf8)), [])
        XCTAssertEqual(ServerMsg.welcomeFeatures(from: Data(#"{"type":"pong","features":["ws"]}"#.utf8)), [])
        XCTAssertEqual(ServerMsg.welcomeFeatures(from: Data("not json".utf8)), [])
    }

    // MARK: - Client frames

    func testPairCheckEncodesToExactlyTheWireJSON() throws {
        XCTAssertEqual(try wire(ClientPairCheck(code: "123456")),
                       ["type": "pair_check", "code": "123456"] as NSDictionary)
        XCTAssertEqual(try wire(ClientPairCheck(code: "123456", proof: "p")),
                       ["type": "pair_check", "code": "123456", "proof": "p"] as NSDictionary)
    }

    func testPairEncodesToExactlyTheWireJSONAndReplaceDefaultsToFalse() throws {
        XCTAssertEqual(try wire(ClientPair(code: "123456", name: "Phone", kind: .iphone)),
                       ["type": "pair", "code": "123456", "name": "Phone", "kind": "iphone", "replace": false] as NSDictionary)
        XCTAssertEqual(try wire(ClientPair(code: "123456", name: "iPad", kind: .ipad, replace: true)),
                       ["type": "pair", "code": "123456", "name": "iPad", "kind": "ipad", "replace": true] as NSDictionary)
    }

    func testDeviceUnpairSelfEncodesToExactlyTheWireJSON() throws {
        XCTAssertEqual(try wire(ClientDeviceUnpairSelf()), ["type": "device_unpair_self"] as NSDictionary)
    }
}
