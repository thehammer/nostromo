import XCTest
@testable import NostromoKit

final class PushWireTests: XCTestCase {

    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    // MARK: - Verbs

    func testRegisterPushEncodesTheDaemonsShape() throws {
        let json = try object(ClientRegisterPush(apnsToken: "ab12", environment: .sandbox, tz: "America/Chicago"))
        XCTAssertEqual(json["type"] as? String, "register_push")
        XCTAssertEqual(json["apns_token"] as? String, "ab12")
        XCTAssertEqual(json["environment"] as? String, "sandbox")
        XCTAssertEqual(json["tz"] as? String, "America/Chicago")
        XCTAssertEqual((json["capabilities"] as? [String: Any])?["nse_withdraw"] as? Bool, false)
    }

    func testTheOtherPushVerbsEncodeTheirType() throws {
        XCTAssertEqual(try object(ClientPushSentLog())["type"] as? String, "push_sent_log")
        XCTAssertEqual(try object(ClientPushWaiting())["type"] as? String, "push_waiting")
        XCTAssertEqual(try object(ClientSetPushPrefs(prefs: .default))["type"] as? String, "set_push_prefs")
    }

    func testTurningTheEveningSummaryOffSendsAnExplicitNull() throws {
        // Leaving the key out would mean "the default (17:30)" to the daemon.
        var prefs = PushPrefsWire.default
        prefs.eveningSummary = nil
        let data = try JSONEncoder().encode(ClientSetPushPrefs(prefs: prefs))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"evening_summary\":null"), text)
        let on = try JSONEncoder().encode(ClientSetPushPrefs(prefs: .default))
        XCTAssertTrue(try XCTUnwrap(String(data: on, encoding: .utf8)).contains("\"evening_summary\":\"17:30\""))
    }

    func testPrefsRoundTripAndAnAbsentEveningSummaryIsTheDefault() throws {
        var prefs = PushPrefsWire(kinds: PushKindsWire(mother: true, decision: false, review: true),
                                  quiet: PushQuietWire(start: "21:00", end: "06:30", enabled: false),
                                  eveningSummary: nil, tz: "Asia/Tokyo")
        let back = try JSONDecoder().decode(PushPrefsWire.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(back, prefs)
        prefs.eveningSummary = "18:00"
        XCTAssertEqual(try JSONDecoder().decode(PushPrefsWire.self, from: JSONEncoder().encode(prefs)), prefs)
        let bare = try JSONDecoder().decode(PushPrefsWire.self, from: Data("{\"tz\":\"UTC\"}".utf8))
        XCTAssertEqual(bare.eveningSummary, "17:30")
        XCTAssertEqual(bare.kinds, PushKindsWire())
    }

    func testThePushVerbsAreAllowedOverTheSocketAndTheyAreNotNetworkVerbs() {
        for type in ["register_push", "set_push_prefs", "push_sent_log", "push_waiting"] {
            XCTAssertTrue(OutboundPolicy.allows(type: type), type)
            XCTAssertTrue(OutboundPolicy.pairedDeviceTypes.contains(type), type)
            // They are not in the daemon's NETWORK_ALLOWED list, which `allowedTypes` mirrors.
            XCTAssertFalse(OutboundPolicy.allowedTypes.contains(type), type)
        }
        for refused in ["decision_answer", "approval_answer", "mother_action", "mother_resume", "operator_presence"] {
            XCTAssertFalse(OutboundPolicy.allows(type: refused), refused)
        }
    }

    // MARK: - Frames

    private func decode(_ json: String) -> ServerMsg { ServerMsg.decode(from: Data(json.utf8)) }

    func testPushStatusDecodes() throws {
        let msg = decode("""
        {"type":"push_status","prefs":{"kinds":{"mother":true,"decision":false,"review":true},
         "quiet":{"start":"22:00","end":"07:00","enabled":true},"evening_summary":null,"tz":"America/Chicago"},
         "host_classes":{"sendai":"personal","kobe":"work"},"work_owners":["Carefeed"],
         "last_ok_at":"2026-11-26T18:00:00Z","failing_since":"2026-11-26T19:14:00.500Z","future_field":1}
        """)
        guard case .pushStatus(let status) = msg else { return XCTFail("\(msg)") }
        XCTAssertFalse(status.prefs.kinds.decision)
        XCTAssertNil(status.prefs.eveningSummary)
        XCTAssertEqual(status.prefs.tz, "America/Chicago")
        XCTAssertEqual(status.hostClasses, ["sendai": .personal, "kobe": .work])
        XCTAssertEqual(status.workOwners, ["Carefeed"])
        XCTAssertNotNil(status.lastOkAt)
        XCTAssertNotNil(status.failingSince)
    }

    func testPushWaitingDecodesAndSkipsRowsItCannotRead() {
        let msg = decode("""
        {"type":"push_waiting","badge":3,"items":[
         {"item_ref":"aa","kind":"mother","host":"kobe","ref":"Job 3f9a1c2e"},
         {"item_ref":"bb","kind":"decision","host":"tokyo"},
         {"item_ref":"cc","kind":"calendar","host":"tokyo"},
         {"kind":"review","host":"tokyo"}]}
        """)
        guard case .pushWaiting(let items, let badge) = msg else { return XCTFail("\(msg)") }
        XCTAssertEqual(badge, 3)
        XCTAssertEqual(items.map(\.itemRef), ["aa", "bb"])
        XCTAssertEqual(items.first?.ref, "Job 3f9a1c2e")
        XCTAssertNil(items.last?.ref)
    }

    func testPushSentLogDecodesAnUnknownOutcomeAsOther() {
        let msg = decode("""
        {"type":"push_sent_log","entries":[
         {"ts":"2026-11-26T18:00:00Z","kind":"mother","host":"kobe","title":"Mother · kobe",
          "body":"Job 3f9a1c2e asked a question","outcome":"delivered_to_apple"},
         {"ts":"2026-11-26T18:01:00Z","kind":"summary","host":"all","title":"Waiting for you",
          "body":"3 items · 3 on kobe","outcome":"something_new"}]}
        """)
        guard case .pushSentLog(let entries) = msg else { return XCTFail("\(msg)") }
        XCTAssertEqual(entries.map(\.outcome), [.deliveredToApple, .other])
        XCTAssertEqual(entries.first?.title, "Mother · kobe")
        XCTAssertEqual(PushOutcomeWire.skippedResolvedInGrace.label, "Skipped: resolved during grace delay")
    }

    // MARK: - Pure helpers

    func testStaleItemsAreThoseNoLongerWaitingAndASummaryStays() {
        let waiting = [PushWaitingItemWire(itemRef: "live", kind: .mother, host: "kobe", ref: nil)]
        let delivered = [
            PushPayload(item: "live", kind: .mother, host: "kobe"),
            PushPayload(item: "gone", kind: .review, host: "kobe"),
            PushPayload(item: "summary", kind: .summary, host: "all"),
        ]
        XCTAssertEqual(PushModel.staleItems(delivered: delivered, waiting: waiting), ["gone"])
    }

    func testTheBannerAppearsOnlyAfterFifteenMinutes() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let since = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(PushModel.bannerText(failingSince: nil, now: since, timeZone: utc))
        XCTAssertNil(PushModel.bannerText(failingSince: since, now: since.addingTimeInterval(15 * 60), timeZone: utc))
        let text = try XCTUnwrap(PushModel.bannerText(failingSince: since, now: since.addingTimeInterval(15 * 60 + 1), timeZone: utc))
        XCTAssertTrue(text.hasPrefix("Notifications haven't been delivered since "), text)
        XCTAssertTrue(text.hasSuffix("am") || text.hasSuffix("pm"), text)
    }

    func testWorkHostsAreEveryHostNotClassifiedPersonal() {
        let classes: [String: HostClassWire] = ["sendai": .personal, "kobe": .work]
        XCTAssertEqual(PushModel.workHosts(in: classes, seen: ["kobe", "tokyo", "sendai"]), ["kobe", "tokyo"])
    }
}
