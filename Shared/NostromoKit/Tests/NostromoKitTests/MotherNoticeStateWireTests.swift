// NostromoKit — MotherNoticeStateWireTests.swift
//
// Mother focus v2, MF6: the `mother_notice_state` frame, `mother_notice_settings_set`, and
// `MotherJob.nostromo.notice`. All of them are additive and tolerant: an unknown reason or mode is
// kept as sent, one malformed entry costs only itself, and a bad `notice` never costs the job's
// annotation.

import XCTest
@testable import NostromoKit

final class MotherNoticeStateWireTests: XCTestCase {

    // MARK: - Helpers

    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func decodeState(_ json: String) throws -> MotherNoticeStateWire? {
        MotherNoticeStateWire.decode(from: try object(json))
    }

    private func encodedObject(_ frame: ClientMotherNoticeSettingsSet) throws -> [String: Any] {
        let data = try JSONEncoder().encode(frame)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private let fullFrame = """
    {"type":"mother_notice_state","enabled":true,"focuses":[
      {"tag":"claudia-1","mode":"quiet","held":{"count":2,"reason":"cap"},"chain_held":false,
       "wakes_by_day":[{"day":"2026-10-30","count":4},{"day":"2026-10-31","count":1}]},
      {"tag":"ada-2","mode":"wake","chain_held":true,"wakes_by_day":[]}
    ]}
    """

    // MARK: - mother_notice_state

    func testDecodesEnabledModesHeldChainHeldAndWakesByDay() throws {
        let s = try XCTUnwrap(try decodeState(fullFrame))
        XCTAssertTrue(s.enabled)
        XCTAssertEqual(s.focuses.count, 2)
        let claudia = try XCTUnwrap(s.focus(tag: "claudia-1"))
        XCTAssertEqual(claudia.mode, .quiet)
        XCTAssertEqual(claudia.held, MotherNoticeHeld(count: 2, reason: "cap"))
        XCTAssertFalse(claudia.chainHeld)
        XCTAssertEqual(claudia.wakesByDay, [MotherNoticeDayCount(day: "2026-10-30", count: 4),
                                            MotherNoticeDayCount(day: "2026-10-31", count: 1)])
        let ada = try XCTUnwrap(s.focus(tag: "ada-2"))
        XCTAssertTrue(ada.chainHeld)
        XCTAssertNil(ada.held)
    }

    func testDisabledFrameDecodesAsDisabled() throws {
        let s = try XCTUnwrap(try decodeState(#"{"enabled":false,"focuses":[]}"#))
        XCTAssertFalse(s.enabled)
        XCTAssertTrue(s.focuses.isEmpty)
    }

    func testAFrameWithoutAnEnabledFlagIsNotAState() throws {
        XCTAssertNil(try decodeState(#"{"focuses":[]}"#))
        XCTAssertNil(try decodeState(#"{"enabled":"yes","focuses":[]}"#))
    }

    func testAMalformedFocusEntryIsSkippedAndTheOthersSurvive() throws {
        let s = try XCTUnwrap(try decodeState("""
        {"enabled":true,"focuses":[
          7, "junk", {"mode":"off"}, {"tag":42},
          {"tag":"good-1","mode":"off"}
        ]}
        """))
        XCTAssertEqual(s.focuses.map(\.tag), ["good-1"])
        XCTAssertEqual(s.mode(forTag: "good-1"), .off)
    }

    func testAMissingOrWrongTypedFocusesListIsEmptyNotAFailure() throws {
        XCTAssertEqual(try XCTUnwrap(try decodeState(#"{"enabled":true}"#)).focuses.count, 0)
        XCTAssertEqual(try XCTUnwrap(try decodeState(#"{"enabled":true,"focuses":"x"}"#)).focuses.count, 0)
    }

    func testUnknownModeAndUnknownHeldReasonAreKeptAsSent() throws {
        let s = try XCTUnwrap(try decodeState("""
        {"enabled":true,"focuses":[
          {"tag":"t1","mode":"turbo","held":{"count":1,"reason":"solar_flare"},"chain_held":false}
        ]}
        """))
        let f = try XCTUnwrap(s.focus(tag: "t1"))
        XCTAssertEqual(f.mode, .other("turbo"))
        XCTAssertEqual(f.mode.rawValue, "turbo")
        XCTAssertEqual(f.held?.reason, "solar_flare")
        XCTAssertNil(f.heldBarReason, "an unknown reason is not a held bar")
    }

    func testModeDefaultsToWakeForAnUnlistedFocus() throws {
        let s = try XCTUnwrap(try decodeState(fullFrame))
        XCTAssertEqual(s.mode(forTag: "never-heard-of-it"), .wake)
        XCTAssertNil(s.focus(tag: "never-heard-of-it"))
    }

    func testModeWireWordsRoundTrip() {
        XCTAssertEqual(MotherNoticeMode.wake.rawValue, "wake")
        XCTAssertEqual(MotherNoticeMode.quiet.rawValue, "quiet")
        XCTAssertEqual(MotherNoticeMode.off.rawValue, "off")
    }

    // MARK: - Held bar reason

    func testHeldBarReasonIsLoopGuardWhenChainHeldAndCapWhenHeldForCap() throws {
        let s = try XCTUnwrap(try decodeState(fullFrame))
        XCTAssertEqual(try XCTUnwrap(s.focus(tag: "ada-2")).heldBarReason, .loopGuard)
        XCTAssertEqual(try XCTUnwrap(s.focus(tag: "claudia-1")).heldBarReason, .cap)
    }

    func testHeldBarReasonIsNilForAFocusThatIsNotHeldOrHeldForAnotherReason() throws {
        let s = try XCTUnwrap(try decodeState("""
        {"enabled":true,"focuses":[
          {"tag":"a","mode":"wake","chain_held":false},
          {"tag":"b","mode":"wake","held":{"count":3,"reason":"batching"},"chain_held":false}
        ]}
        """))
        XCTAssertNil(try XCTUnwrap(s.focus(tag: "a")).heldBarReason)
        XCTAssertNil(try XCTUnwrap(s.focus(tag: "b")).heldBarReason)
    }

    func testLoopGuardWinsWhenAFocusIsBothChainHeldAndCapHeld() throws {
        let s = try XCTUnwrap(try decodeState("""
        {"enabled":true,"focuses":[
          {"tag":"a","mode":"wake","held":{"count":1,"reason":"cap"},"chain_held":true}]}
        """))
        XCTAssertEqual(try XCTUnwrap(s.focus(tag: "a")).heldBarReason, .loopGuard)
    }

    func testRemovingATagDropsOnlyThatFocus() throws {
        let s = try XCTUnwrap(try decodeState(fullFrame))
        let r = s.removing(tag: "claudia-1")
        XCTAssertNil(r.focus(tag: "claudia-1"))
        XCTAssertNotNil(r.focus(tag: "ada-2"))
        XCTAssertEqual(r.enabled, s.enabled)
    }

    // MARK: - mother_notice_settings_set

    func testFocusSettingFrameCarriesTypeScopeTagAndModeOnly() throws {
        let o = try encodedObject(ClientMotherNoticeSettingsSet(scope: .focus, tag: "claudia-1", mode: "quiet"))
        XCTAssertEqual(o["type"] as? String, "mother_notice_settings_set")
        XCTAssertEqual(o["scope"] as? String, "focus")
        XCTAssertEqual(o["tag"] as? String, "claudia-1")
        XCTAssertEqual(o["mode"] as? String, "quiet")
        XCTAssertNil(o["enabled"], "a nil field is omitted, not null")
    }

    func testGlobalSettingFrameCarriesTypeScopeAndEnabledOnly() throws {
        let o = try encodedObject(ClientMotherNoticeSettingsSet(scope: .global, enabled: false))
        XCTAssertEqual(o["type"] as? String, "mother_notice_settings_set")
        XCTAssertEqual(o["scope"] as? String, "global")
        XCTAssertEqual(o["enabled"] as? Bool, false)
        XCTAssertNil(o["tag"])
        XCTAssertNil(o["mode"])
    }

    // MARK: - nostromo.notice

    private func decodeAnnotation(_ json: String) throws -> MotherJobAnnotation {
        try JSONDecoder().decode(MotherJobAnnotation.self, from: Data(json.utf8))
    }

    func testNoticeDecodesStatusReasonLastStateTimeAndHistory() throws {
        let a = try decodeAnnotation("""
        {"origin":{"kind":"focus","focus_tag":"t1"},
         "notice":{"status":"held","reason":"batching","last_state":"succeeded","at_ms":1700000000000,
                   "history":[
                     {"states":["pr_opened","succeeded"],"status":"told","wake":true,"at_ms":1699999000000},
                     {"states":["succeeded"],"status":"held","reason":"batching","wake":false,"at_ms":1700000000000}]}}
        """)
        let n = try XCTUnwrap(a.notice)
        XCTAssertEqual(n.status, .held)
        XCTAssertEqual(n.reason, "batching")
        XCTAssertEqual(n.lastState, "succeeded")
        XCTAssertEqual(n.atMs, 1_700_000_000_000)
        XCTAssertEqual(n.history.count, 2)
        XCTAssertEqual(n.history[0].states, ["pr_opened", "succeeded"])
        XCTAssertEqual(n.history[0].status, .told)
        XCTAssertTrue(n.history[0].wake)
        XCTAssertEqual(n.history[1].reason, "batching")
        XCTAssertFalse(n.history[1].wake)
    }

    func testEveryNoticeStatusDecodesAndAnUnknownOneReadsAsNone() throws {
        let table: [(String, MotherNoticeStatus)] = [
            ("told", .told), ("held", .held), ("dropped", .dropped), ("not_sent", .notSent),
            ("none", .none), ("teleported", .none),
        ]
        for (wire, expected) in table {
            let a = try decodeAnnotation(#"{"notice":{"status":"\#(wire)"}}"#)
            XCTAssertEqual(a.notice?.status, expected, wire)
        }
    }

    func testAMalformedHistoryEntryIsSkippedAndTheRestKept() throws {
        let a = try decodeAnnotation("""
        {"notice":{"status":"told","history":[
          7, "junk", null,
          {"states":["succeeded"],"status":"told","wake":true,"at_ms":5}
        ]}}
        """)
        let n = try XCTUnwrap(a.notice)
        XCTAssertEqual(n.status, .told)
        XCTAssertEqual(n.history.count, 1)
        XCTAssertEqual(n.history[0].atMs, 5)
    }

    func testAWrongTypedFieldCostsOnlyItself() throws {
        let a = try decodeAnnotation(#"{"notice":{"status":"told","reason":7,"at_ms":"soon","history":"nope"}}"#)
        let n = try XCTUnwrap(a.notice)
        XCTAssertEqual(n.status, .told)
        XCTAssertNil(n.reason)
        XCTAssertNil(n.atMs)
        XCTAssertTrue(n.history.isEmpty)
    }

    func testAMalformedNoticeNeverCostsTheOriginOrTheAnnotation() throws {
        for bad in ["\"oops\"", "7", "[1,2]", "null", "true"] {
            let a = try decodeAnnotation(
                #"{"origin":{"kind":"focus","focus_tag":"t1","focus_name":"Claudia"},"notify":"wake","notice":\#(bad)}"#)
            XCTAssertEqual(a.origin?.kind, .focus, bad)
            XCTAssertEqual(a.origin?.focusTag, "t1", bad)
            XCTAssertEqual(a.notify, "wake", bad)
            XCTAssertNil(a.notice, bad)
        }
    }

    func testAnAnnotationWithNoNoticeHasNone() throws {
        XCTAssertNil(try decodeAnnotation(#"{"origin":{"kind":"you"}}"#).notice)
    }
}
