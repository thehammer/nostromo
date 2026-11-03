// NostromoKit — MotherQuotaWireTests.swift
//
// Mother's quota gate as the shared Kit decodes and words it.
//
// The contract is Mother's golden fixture, vendored byte-exact as
// `tests/fixtures/mother-contract/quota_block.json` (Mother #106): the `quota` block of a subscribe
// snapshot, of the `quota` event and of the `quota-gate` ack, and the `quota-gate` command envelopes.
// Nostromo decodes exactly that block, so every concrete value below is the fixture's.
//
// Behaviour pinned here:
//   - the whole block decodes, for each of the three gate states;
//   - a gate string this build does not know is `.unknown`, never a crash and never a guess;
//   - a missing or non-object block is "quota status unavailable" (nil), not an empty quota;
//   - a missing `windows` (or one malformed window) costs the windows, not the block;
//   - a `quota-gate` command carries the state and the origin `nostromo` and no job id, and is the
//     fixture's `request` envelope's data;
//   - hostile numbers (huge, negative, past Int64, strings like "NaN") never trap: a window with a bad
//     percentage is dropped, a bad feed age or reset time is nil, the rest of the block stands;
//   - the strip's words: `5h 15% / 90 · resets 8:40 pm CT`, `7d 100% / 90 · paused · resets Thu 8 pm CT`
//     (`over cap, gate off` instead of `paused` while the gate is off), the badge texts (a stale feed with the
//     gate on says Mother is not limiting work), and the stale-feed text. Reset times end in a zone label.
//
// Times are explicit: every wording test passes its own `now` and `America/Chicago`.

import XCTest
@testable import NostromoKit

final class MotherQuotaWireTests: XCTestCase {

    // MARK: - Fixture access

    /// `<repo>/tests/fixtures/mother-contract`, found from this file's location (the `#filePath` pattern
    /// `MotherCrewWireTests` uses).
    private static let contractDir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // NostromoKitTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // NostromoKit
        .deletingLastPathComponent()   // Shared
        .deletingLastPathComponent()   // <repo>
        .appendingPathComponent("tests/fixtures/mother-contract")

    private func fixture() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.contractDir.appendingPathComponent("quota_block.json"))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The fixture's `quota_block` as a JSON object (`off_until_reset`, bishop feed, 7d over its cap).
    private func block() throws -> [String: Any] {
        try XCTUnwrap(try fixture()["quota_block"] as? [String: Any], "fixture has no quota_block")
    }

    /// The fixture's block with `edit` applied.
    private func block(_ edit: (inout [String: Any]) -> Void) throws -> [String: Any] {
        var object = try block()
        edit(&object)
        return object
    }

    private func decoded(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> MotherQuota {
        try XCTUnwrap(MotherQuota.decode(try block(edit)), "the block did not decode")
    }

    private func date(_ epoch: TimeInterval) -> Date { Date(timeIntervalSince1970: epoch) }

    // 2026-11-02 19:11:00 UTC = 1:11 pm in Chicago (CST), the fixture snapshot's own time.
    private let now = Date(timeIntervalSince1970: 1_793_646_660)
    private let chicago = TimeZone(identifier: "America/Chicago")!

    private func word(_ quota: MotherQuota) -> String {
        MotherQuotaPresentation.badgeText(quota, now: now, timeZone: chicago)
    }

    // MARK: - The golden fixture

    func testTheGoldenFixtureDecodesToItsConcreteValues() throws {
        let quota = try decoded()

        XCTAssertEqual(quota.gate, .offUntilReset)
        XCTAssertEqual(quota.until, date(1_793_658_600))
        XCTAssertEqual(quota.changedAt, "2026-11-02T19:10:13.486Z")
        XCTAssertEqual(quota.changedBy, "broker:nostromo")
        XCTAssertEqual(quota.source, .bishop)
        XCTAssertEqual(quota.feedAgeSeconds, 42)
        XCTAssertFalse(quota.stale)
        XCTAssertFalse(quota.capInvalid)
        XCTAssertEqual(quota.fiveHour, MotherQuotaWindow(usedPct: 23, capPct: 90, resetsAt: date(1_793_658_600)))
        XCTAssertEqual(quota.sevenDay, MotherQuotaWindow(usedPct: 100, capPct: 90, resetsAt: date(1_793_930_400)))
    }

    func testTheBlockDecodesTheSameFromItsRawJSONBytes() throws {
        let bytes = try JSONSerialization.data(withJSONObject: try block())
        XCTAssertEqual(MotherQuota.decode(json: bytes), try decoded())
        XCTAssertNil(MotherQuota.decode(json: Data("not json".utf8)))
        XCTAssertNil(MotherQuota.decode(json: Data("[]".utf8)), "an array is not a quota block")
    }

    func testTheOkAckCarriesTheBlockTheClientReads() throws {
        // The ack's `data.quota` is the same block (the fixture writes it as a placeholder; the block is the value).
        let envelopes = try XCTUnwrap(try fixture()["command_envelopes"] as? [String: Any])
        let ack = try XCTUnwrap(envelopes["ok_ack"] as? [String: Any])
        XCTAssertEqual(ack["dir"] as? String, "ack")
        XCTAssertEqual(ack["t"] as? String, "quota-gate")
        let data = try XCTUnwrap(ack["data"] as? [String: Any])
        XCTAssertEqual(data["ok"] as? Bool, true)
        XCTAssertEqual(data["state"] as? String, "off_until_reset")
        XCTAssertEqual(MotherQuotaGate(wire: data["state"] as? String), try decoded().gate,
                       "the ack's state names the gate its block reports")
    }

    func testFieldsTheKitDoesNotKnowAreIgnored() throws {
        let extra = try decoded { $0["future_key"] = ["a": 1]; $0["changed_by"] = "auto:reset" }
        var expected = try decoded()
        expected.changedBy = "auto:reset"
        XCTAssertEqual(extra, expected, "an additive key from a newer Mother costs nothing")
    }

    // MARK: - The three gate states

    func testGateOnDecodesWithNoUntil() throws {
        let quota = try decoded { $0["gate"] = "on"; $0["until"] = NSNull() }
        XCTAssertEqual(quota.gate, .on)
        XCTAssertNil(quota.until)
        XCTAssertFalse(quota.gate.isOff)
        XCTAssertFalse(quota.gate.isUnknown)
    }

    func testGateOffDecodesWithNoUntilAndCountsAsOff() throws {
        let quota = try decoded { $0["gate"] = "off"; $0["until"] = NSNull() }
        XCTAssertEqual(quota.gate, .off)
        XCTAssertNil(quota.until)
        XCTAssertTrue(quota.gate.isOff)
    }

    func testGateOffUntilResetCarriesItsUntilAndCountsAsOff() throws {
        let quota = try decoded()
        XCTAssertEqual(quota.gate, .offUntilReset)
        XCTAssertEqual(quota.until, date(1_793_658_600))
        XCTAssertTrue(quota.gate.isOff)
    }

    func testAnAbsentUntilKeyIsNilLikeANullOne() throws {
        let quota = try decoded { $0.removeValue(forKey: "until") }
        XCTAssertNil(quota.until)
        XCTAssertEqual(quota.gate, .offUntilReset, "the gate itself is unaffected")
    }

    func testNeverChangedHasNoChangedAtOrBy() throws {
        let quota = try decoded { $0["changed_at"] = NSNull(); $0["changed_by"] = NSNull() }
        XCTAssertNil(quota.changedAt)
        XCTAssertNil(quota.changedBy)
    }

    // MARK: - An unknown gate

    func testAnUnknownGateStringIsUnknownNeverACrashOrAGuess() throws {
        let quota = try decoded { $0["gate"] = "paused_for_review" }
        XCTAssertEqual(quota.gate, .unknown("paused_for_review"))
        XCTAssertTrue(quota.gate.isUnknown)
        XCTAssertFalse(quota.gate.isOff, "an unknown state is not claimed to be off")
        XCTAssertEqual(word(quota), "Gate unknown")
        XCTAssertEqual(quota.fiveHour?.usedPct, 23, "the rest of the block still decodes")
    }

    func testAMissingOrNonStringGateIsUnknownToo() throws {
        let missing = try decoded { $0.removeValue(forKey: "gate") }
        XCTAssertTrue(missing.gate.isUnknown)
        XCTAssertEqual(word(missing), "Gate unknown")

        let number = try decoded { $0["gate"] = 3 }
        XCTAssertTrue(number.gate.isUnknown)

        let empty = try decoded { $0["gate"] = "" }
        XCTAssertTrue(empty.gate.isUnknown)
        XCTAssertEqual(MotherQuotaGate(wire: nil), .unknown(""))
    }

    func testGateWireStringsAreExactAndCaseSensitive() {
        XCTAssertEqual(MotherQuotaGate(wire: "on"), .on)
        XCTAssertEqual(MotherQuotaGate(wire: "off"), .off)
        XCTAssertEqual(MotherQuotaGate(wire: "off_until_reset"), .offUntilReset)
        XCTAssertTrue(MotherQuotaGate(wire: "ON").isUnknown)
        XCTAssertTrue(MotherQuotaGate(wire: "off-until-reset").isUnknown)
    }

    // MARK: - Stale feed, source, cap

    func testAStaleFeedWithAnAgeSaysHowManyMinutes() throws {
        let quota = try decoded { $0["stale"] = true; $0["feed_age_s"] = 725; $0["source"] = "none" }
        XCTAssertTrue(quota.stale)
        XCTAssertEqual(quota.source, MotherQuota.Source.none)
        XCTAssertEqual(MotherQuotaPresentation.staleText(quota), "Quota feed stale (12m)")
    }

    func testAStaleFeedRoundsMinutesDownAndNeverShowsANegativeAge() throws {
        let fresh = try decoded { $0["stale"] = true; $0["feed_age_s"] = 59 }
        XCTAssertEqual(MotherQuotaPresentation.staleText(fresh), "Quota feed stale (0m)")
        let hour = try decoded { $0["stale"] = true; $0["feed_age_s"] = 3600 }
        XCTAssertEqual(MotherQuotaPresentation.staleText(hour), "Quota feed stale (60m)")
        let skewed = try decoded { $0["stale"] = true; $0["feed_age_s"] = -30 }
        XCTAssertEqual(MotherQuotaPresentation.staleText(skewed), "Quota feed stale (0m)")
    }

    func testAStaleFeedWithNoUsableFileHasNoAge() throws {
        let quota = try decoded { $0["stale"] = true; $0["feed_age_s"] = NSNull(); $0["source"] = "none" }
        XCTAssertNil(quota.feedAgeSeconds)
        XCTAssertEqual(MotherQuotaPresentation.staleText(quota), "Quota feed stale")
    }

    func testAFreshFeedHasNoStaleText() throws {
        XCTAssertNil(MotherQuotaPresentation.staleText(try decoded()))
        let oldButNotStale = try decoded { $0["feed_age_s"] = 5000 }
        XCTAssertNil(MotherQuotaPresentation.staleText(oldButNotStale), "stale is Mother's flag, not an age threshold")
    }

    func testSourcesDecodeAndAnUnknownOneSurvives() throws {
        XCTAssertEqual(try decoded { $0["source"] = "cache" }.source, .cache)
        XCTAssertEqual(try decoded { $0["source"] = "bishop" }.source, .bishop)
        XCTAssertEqual(try decoded { $0["source"] = "none" }.source, MotherQuota.Source.none)
        XCTAssertEqual(try decoded { $0["source"] = "satellite" }.source, .unknown("satellite"))
    }

    func testCapInvalidIsReadAndDefaultsToFalse() throws {
        XCTAssertTrue(try decoded { $0["cap_invalid"] = true }.capInvalid)
        XCTAssertFalse(try decoded { $0.removeValue(forKey: "cap_invalid") }.capInvalid)
        XCTAssertEqual(MotherQuotaPresentation.capInvalidText, "cap invalid, using 90")
    }

    // MARK: - Absent or unreadable blocks

    func testAnAbsentBlockIsNilNotAnEmptyQuota() {
        XCTAssertNil(MotherQuota.decode(nil))
    }

    func testANonObjectBlockIsNil() {
        XCTAssertNil(MotherQuota.decode(NSNull()))
        XCTAssertNil(MotherQuota.decode("<quota_block>"), "a string (the fixture's own placeholder) is not a block")
        XCTAssertNil(MotherQuota.decode(42))
        XCTAssertNil(MotherQuota.decode(true))
        XCTAssertNil(MotherQuota.decode([["gate": "on"]]), "an array is not a block")
    }

    func testAnEmptyObjectIsABlockWithAnUnknownGate() {
        let quota = MotherQuota.decode([String: Any]())
        XCTAssertNotNil(quota, "an object is a block: the broker did send quota status")
        XCTAssertEqual(quota?.gate, .unknown(""))
        XCTAssertNil(quota?.fiveHour)
        XCTAssertNil(quota?.sevenDay)
    }

    // MARK: - Windows

    func testMissingWindowsKeepTheRestOfTheBlock() throws {
        let quota = try decoded { $0.removeValue(forKey: "windows") }
        XCTAssertNil(quota.fiveHour)
        XCTAssertNil(quota.sevenDay)
        XCTAssertEqual(quota.gate, .offUntilReset)
        XCTAssertEqual(quota.until, date(1_793_658_600))
    }

    func testOneMissingWindowLeavesTheOther() throws {
        let quota = try decoded {
            var windows = $0["windows"] as? [String: Any] ?? [:]
            windows.removeValue(forKey: "five_hour")
            $0["windows"] = windows
        }
        XCTAssertNil(quota.fiveHour)
        XCTAssertEqual(quota.sevenDay?.usedPct, 100)
    }

    func testAMalformedWindowCostsThatWindowOnly() throws {
        let quota = try decoded {
            var windows = $0["windows"] as? [String: Any] ?? [:]
            windows["five_hour"] = ["used_pct": "lots", "cap_pct": 90]
            $0["windows"] = windows
        }
        XCTAssertNil(quota.fiveHour)
        XCTAssertEqual(quota.sevenDay, MotherQuotaWindow(usedPct: 100, capPct: 90, resetsAt: date(1_793_930_400)))
    }

    func testAWindowWithNoResetTimeKeepsItsPercentages() throws {
        let quota = try decoded {
            $0["windows"] = ["five_hour": ["used_pct": 0.0, "cap_pct": 90, "resets_at": NSNull()]]
        }
        XCTAssertEqual(quota.fiveHour, MotherQuotaWindow(usedPct: 0, capPct: 90, resetsAt: nil))
    }

    /// Real wire bytes, not a Swift dictionary: JSON `0` and `1` arrive as `NSNumber`s that can also be read as a
    /// `Bool`, and an expired window really does report `used_pct` 0 (the fixture's doc says so).
    func testZeroAndOneAreNumbersWhenTheyComeOffTheWire() throws {
        for (zero, one) in [("0", "1"), ("0.0", "1.0")] {
            let json = """
            {"gate":"on","feed_age_s":\(zero),"stale":false,"windows":{
              "five_hour":{"used_pct":\(zero),"cap_pct":90,"resets_at":null},
              "seven_day":{"used_pct":\(one),"cap_pct":90,"resets_at":1793930400}}}
            """
            let quota = try XCTUnwrap(MotherQuota.decode(json: Data(json.utf8)), "\(zero)/\(one)")
            XCTAssertEqual(quota.fiveHour, MotherQuotaWindow(usedPct: 0, capPct: 90, resetsAt: nil),
                           "an expired window (used_pct \(zero)) is still a window")
            XCTAssertEqual(quota.sevenDay?.usedPct, 1, "used_pct \(one) is one percent")
            XCTAssertEqual(quota.feedAgeSeconds, 0, "feed_age_s \(zero) is a fresh feed, not a missing age")
        }
    }

    func testAJSONBooleanIsNotANumber() throws {
        let json = #"{"gate":"on","feed_age_s":true,"windows":{"five_hour":{"used_pct":true,"cap_pct":90}}}"#
        let quota = try XCTUnwrap(MotherQuota.decode(json: Data(json.utf8)))
        XCTAssertNil(quota.fiveHour)
        XCTAssertNil(quota.feedAgeSeconds)
    }

    func testAWindowIsOverCapAtTheCapAndAbove() {
        XCTAssertFalse(MotherQuotaWindow(usedPct: 89.9, capPct: 90, resetsAt: nil).isOverCap)
        XCTAssertTrue(MotherQuotaWindow(usedPct: 90, capPct: 90, resetsAt: nil).isOverCap)
        XCTAssertTrue(MotherQuotaWindow(usedPct: 100, capPct: 90, resetsAt: nil).isOverCap)
    }

    // MARK: - The command

    func testEveryRequestIsAWireStateNamedForTheThreeGateStates() {
        XCTAssertEqual(Set(MotherQuotaGateRequest.allCases.map(\.rawValue)), ["on", "off", "off_until_reset"])
        XCTAssertEqual(MotherQuotaGateRequest.on.resultingGate, .on)
        XCTAssertEqual(MotherQuotaGateRequest.off.resultingGate, .off)
        XCTAssertEqual(MotherQuotaGateRequest.offUntilReset.resultingGate, .offUntilReset)
        XCTAssertFalse(MotherQuotaGateRequest.on.isTurningOff)
        XCTAssertTrue(MotherQuotaGateRequest.off.isTurningOff)
        XCTAssertTrue(MotherQuotaGateRequest.offUntilReset.isTurningOff)
    }

    func testEveryRequestsCommandDataIsItsStateAndTheNostromoOriginAndNothingElse() throws {
        for request in MotherQuotaGateRequest.allCases {
            let data = request.commandData
            XCTAssertEqual(Set(data.keys), ["state", "origin"], "\(request): no job id, nothing else")
            XCTAssertEqual(data["state"], request.rawValue)
            XCTAssertEqual(data["origin"], "nostromo")

            // And it survives JSON, as an envelope's data does.
            let envelope: [String: Any] = ["v": 1, "dir": "cmd", "t": "quota-gate", "id": "q", "data": data]
            let bytes = try JSONSerialization.data(withJSONObject: envelope)
            let back = try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let backData = try XCTUnwrap(back["data"] as? [String: Any])
            XCTAssertEqual(backData["state"] as? String, request.rawValue)
            XCTAssertEqual(backData["origin"] as? String, "nostromo")
            XCTAssertNil(backData["job"])
        }
    }

    func testTheOffUntilResetRequestIsTheFixturesRequestEnvelopesData() throws {
        let envelopes = try XCTUnwrap(try fixture()["command_envelopes"] as? [String: Any])
        let request = try XCTUnwrap(envelopes["request"] as? [String: Any])
        XCTAssertEqual(request["t"] as? String, "quota-gate")
        XCTAssertEqual(request["dir"] as? String, "cmd")
        let data = try XCTUnwrap(request["data"] as? [String: String])
        XCTAssertEqual(data, MotherQuotaGateRequest.offUntilReset.commandData)
        XCTAssertEqual(MotherQuotaGateRequest(rawValue: try XCTUnwrap(data["state"])), .offUntilReset)
    }

    func testAStateTheBrokerRefusesIsNotARequestThisBuildCanMake() throws {
        let envelopes = try XCTUnwrap(try fixture()["command_envelopes"] as? [String: Any])
        let rejected = try XCTUnwrap(envelopes["rejected_request"] as? [String: Any])
        let data = try XCTUnwrap(rejected["data"] as? [String: String])
        XCTAssertEqual(data["state"], "sometimes")
        XCTAssertNil(MotherQuotaGateRequest(rawValue: "sometimes"), "the control can only ask for the three states")
    }

    // MARK: - Presentation: the windows

    private func windowText(_ label: String, used: Double, cap: Double = 90, resets: TimeInterval?,
                            now: Date? = nil) -> String {
        MotherQuotaPresentation.windowText(
            label: label,
            MotherQuotaWindow(usedPct: used, capPct: cap, resetsAt: resets.map(date)),
            now: now ?? self.now, timeZone: chicago)
    }

    func testAWindowUnderItsCapReadsUsedOverCapAndResetTime() {
        XCTAssertEqual(windowText("5h", used: 15, resets: 1_793_673_600), "5h 15% / 90 · resets 8:40 pm CT")
    }

    func testAWindowOverItsCapSaysPausedAndNamesTheResetDay() {
        XCTAssertEqual(windowText("7d", used: 100, resets: 1_793_930_400), "7d 100% / 90 · paused · resets Thu 8 pm CT")
    }

    func testTheFixturesWindowsReadTheWayTheStripShowsThem() throws {
        let quota = try decoded()
        XCTAssertEqual(MotherQuotaPresentation.windowText(label: "5h", try XCTUnwrap(quota.fiveHour),
                                                          now: now, timeZone: chicago),
                       "5h 23% / 90 · resets 4:30 pm CT")
        XCTAssertEqual(MotherQuotaPresentation.windowText(label: "7d", try XCTUnwrap(quota.sevenDay),
                                                          now: now, timeZone: chicago),
                       "7d 100% / 90 · paused · resets Thu 8 pm CT")
    }

    func testAWindowExactlyAtItsCapIsPaused() {
        XCTAssertEqual(windowText("5h", used: 90, resets: nil), "5h 90% / 90 · paused")
        XCTAssertEqual(windowText("5h", used: 89, resets: nil), "5h 89% / 90")
    }

    func testAWindowWithNoResetTimeOmitsTheResetClause() {
        XCTAssertEqual(windowText("5h", used: 15, resets: nil), "5h 15% / 90")
    }

    func testUsedPercentRoundsAndAFractionalCapKeepsItsFraction() {
        XCTAssertEqual(windowText("5h", used: 14.6, resets: nil), "5h 15% / 90")
        XCTAssertEqual(windowText("5h", used: 10, cap: 87.5, resets: nil), "5h 10% / 87.5")
    }

    func testResetTimesReadInTheGivenZoneOnTheHourWithoutMinutes() {
        // Noon today, 12:05 am tomorrow (Tue), 9:05 am the day after tomorrow, midnight tomorrow.
        XCTAssertEqual(MotherQuotaPresentation.resetTime(date(1_793_642_400), now: now, timeZone: chicago), "12 pm CT")
        XCTAssertEqual(MotherQuotaPresentation.resetTime(date(1_793_685_600), now: now, timeZone: chicago), "Tue 12 am CT")
        XCTAssertEqual(MotherQuotaPresentation.resetTime(date(1_793_685_900), now: now, timeZone: chicago), "Tue 12:05 am CT")
        XCTAssertEqual(MotherQuotaPresentation.resetTime(date(1_793_718_300), now: now, timeZone: chicago), "Tue 9:05 am CT")
    }

    func testTheSameInstantReadsDifferentlyInAnotherZone() {
        // 22:30 UTC Monday: 4:30 pm in Chicago, 10:30 pm in UTC. Each reading names its zone.
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(MotherQuotaPresentation.resetTime(date(1_793_658_600), now: now, timeZone: chicago), "4:30 pm CT")
        XCTAssertEqual(MotherQuotaPresentation.resetTime(date(1_793_658_600), now: now, timeZone: utc), "10:30 pm UTC")
    }

    // The gate's state decides what "over cap" means: only with the gate on is Mother holding anything.

    func testAnOverCapWindowSaysPausedOnlyWhileTheGateIsOn() {
        let window = MotherQuotaWindow(usedPct: 100, capPct: 90, resetsAt: date(1_793_930_400))
        let text = { (gate: MotherQuotaGate) in
            MotherQuotaPresentation.windowText(label: "7d", window, now: self.now, timeZone: self.chicago, gate: gate)
        }

        XCTAssertEqual(text(.on), "7d 100% / 90 · paused · resets Thu 8 pm CT")
        XCTAssertEqual(text(.off), "7d 100% / 90 · over cap, gate off · resets Thu 8 pm CT")
        XCTAssertEqual(text(.offUntilReset), "7d 100% / 90 · over cap, gate off · resets Thu 8 pm CT")
        XCTAssertFalse(text(.off).contains("paused"), "nothing is paused with the gate off")
        XCTAssertFalse(text(.offUntilReset).contains("paused"))
    }

    func testAWindowUnderItsCapReadsTheSameWhateverTheGate() {
        let window = MotherQuotaWindow(usedPct: 15, capPct: 90, resetsAt: date(1_793_673_600))
        for gate in [MotherQuotaGate.on, .off, .offUntilReset] {
            XCTAssertEqual(MotherQuotaPresentation.windowText(label: "5h", window, now: now, timeZone: chicago, gate: gate),
                           "5h 15% / 90 · resets 8:40 pm CT", "\(gate)")
        }
    }

    // MARK: - Presentation: zones

    func testResetTimesDefaultToCentralTimeWhateverTheMachinesZone() throws {
        XCTAssertEqual(MotherQuotaPresentation.displayTimeZone.identifier, "America/Chicago")
        // No zone passed: the same text on any machine.
        let window = MotherQuotaWindow(usedPct: 23, capPct: 90, resetsAt: date(1_793_658_600))
        XCTAssertEqual(MotherQuotaPresentation.windowText(label: "5h", window, now: now),
                       "5h 23% / 90 · resets 4:30 pm CT")
        XCTAssertEqual(MotherQuotaPresentation.badgeText(try decoded(), now: now),
                       "Gate off until reset (resets 4:30 pm CT)")
    }

    func testTheCentralZoneLabelIsCTInSummerToo() {
        // 2026-07-01 18:00 UTC is 1 pm CDT; noon CDT is "now". The label is the region's, not "CDT".
        let summerNow = date(1_782_925_200)
        XCTAssertEqual(MotherQuotaPresentation.resetTime(date(1_782_928_800), now: summerNow, timeZone: chicago), "1 pm CT")
    }

    func testTheSpokenOffUntilResetNamesTheZoneToo() throws {
        let spoken = MotherQuotaPresentation.badgeSpokenText(try decoded(), now: now, timeZone: chicago)
        XCTAssertTrue(spoken.contains("until 4:30 pm CT"), spoken)
    }

    // MARK: - Presentation: a stale feed with the gate on

    func testAStaleFeedWithTheGateOnDoesNotClaimMotherHoldsWork() throws {
        let stale = try decoded { $0["gate"] = "on"; $0["until"] = NSNull(); $0["stale"] = true }
        XCTAssertEqual(word(stale), "Gate on, feed stale: Mother is not limiting work")
        XCTAssertEqual(MotherQuotaPresentation.staleGateOnText, "Gate on, feed stale: Mother is not limiting work")

        let spoken = MotherQuotaPresentation.badgeSpokenText(stale, now: now, timeZone: chicago)
        XCTAssertTrue(spoken.contains("stale"), spoken)
        XCTAssertTrue(spoken.contains("not limiting work"), spoken)
        XCTAssertFalse(spoken.contains("holds work"), spoken)
        XCTAssertFalse(spoken.hasPrefix("Warning"), "the gate is not off")
    }

    func testAFreshFeedWithTheGateOnStillSaysMotherHoldsWork() throws {
        let fresh = try decoded { $0["gate"] = "on"; $0["until"] = NSNull(); $0["stale"] = false }
        XCTAssertEqual(word(fresh), "Gate on")
        XCTAssertTrue(MotherQuotaPresentation.badgeSpokenText(fresh, now: now, timeZone: chicago).contains("holds work"))
    }

    func testStaleDoesNotChangeTheOffBadges() throws {
        let off = try decoded { $0["gate"] = "off"; $0["until"] = NSNull(); $0["stale"] = true }
        XCTAssertEqual(word(off), "Gate OFF")
        let untilReset = try decoded { $0["stale"] = true }
        XCTAssertEqual(word(untilReset), "Gate off until reset (resets 4:30 pm CT)")
    }

    // MARK: - Hostile numbers

    /// A block's JSON with one field swapped for a raw JSON literal; the seven-day window stays sound, so each
    /// case also shows that a bad field costs only itself.
    private func wire(feedAge: String = "42", used: String = "23", cap: String = "90", resets: String = "1793658600",
                      until: String = "null") -> String {
        """
        {"gate":"off_until_reset","until":\(until),"stale":true,"feed_age_s":\(feedAge),
         "windows":{"five_hour":{"used_pct":\(used),"cap_pct":\(cap),"resets_at":\(resets)},
                    "seven_day":{"used_pct":50,"cap_pct":90,"resets_at":1793930400}}}
        """
    }

    /// What the app's decoder is handed for these bytes: the parsed JSON, or nil where the bytes do not parse at
    /// all (a number out of the parser's range), in which case the decoder is never reached.
    private func parsed(_ json: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(json.utf8))
    }

    /// Number literals (raw JSON) that no real Mother sends: huge, past the Double range, past Int64, negative.
    private let hostileNumbers = ["1e30", "-1e30", "1e400", "-1e400", "1e23", "100000000000000000000000",
                                  "-100000000000000000000000", "1e308", "-1"]
    /// Strings a careless producer could write for a number.
    private let hostileStrings = ["\"NaN\"", "\"Infinity\"", "\"-Infinity\"", "\"1e400\"", "\"\""]

    func testAHostileUsedOrCapPercentageDropsThatWindowOnly() throws {
        for literal in hostileNumbers + hostileStrings {
            for (field, json) in [("used_pct", wire(used: literal)), ("cap_pct", wire(cap: literal))] {
                guard let object = parsed(json) else { continue }
                let quota = try XCTUnwrap(MotherQuota.decode(object), "\(field) = \(literal): the block still decodes")
                XCTAssertNil(quota.fiveHour, "\(field) = \(literal): the window is dropped")
                XCTAssertEqual(quota.sevenDay, MotherQuotaWindow(usedPct: 50, capPct: 90, resetsAt: date(1_793_930_400)),
                               "\(field) = \(literal): the other window is untouched")
                XCTAssertEqual(quota.gate, .offUntilReset)
            }
        }
    }

    func testNonFiniteNumbersInTheDictionaryAreDroppedToo() throws {
        for value in [Double.nan, .infinity, -.infinity] {
            let block: [String: Any] = [
                "gate": "on", "feed_age_s": value, "until": value, "stale": true,
                "windows": ["five_hour": ["used_pct": value, "cap_pct": 90, "resets_at": value],
                            "seven_day": ["used_pct": 10, "cap_pct": value]],
            ]
            let quota = try XCTUnwrap(MotherQuota.decode(block), "\(value)")
            XCTAssertNil(quota.fiveHour, "\(value)")
            XCTAssertNil(quota.sevenDay, "\(value)")
            XCTAssertNil(quota.feedAgeSeconds, "\(value)")
            XCTAssertNil(quota.until, "\(value)")
        }
    }

    func testAHostileFeedAgeIsNilAndTheBlockStands() throws {
        for literal in hostileNumbers.filter({ $0 != "-1" }) + hostileStrings {
            guard let object = parsed(wire(feedAge: literal)) else { continue }
            let quota = try XCTUnwrap(MotherQuota.decode(object), "feed_age_s = \(literal)")
            XCTAssertNil(quota.feedAgeSeconds, "feed_age_s = \(literal)")
            XCTAssertEqual(MotherQuotaPresentation.staleText(quota), "Quota feed stale", "no usable age, so none is shown")
            XCTAssertEqual(quota.fiveHour?.usedPct, 23, "feed_age_s = \(literal): the windows are untouched")
        }
        let ordinary = try XCTUnwrap(MotherQuota.decode(try XCTUnwrap(parsed(wire(feedAge: "725")))))
        XCTAssertEqual(ordinary.feedAgeSeconds, 725)
    }

    func testAHostileResetTimeIsNilAndTheWindowKeepsItsPercentages() throws {
        for literal in hostileNumbers + hostileStrings {
            guard let object = parsed(wire(resets: literal)) else { continue }
            let quota = try XCTUnwrap(MotherQuota.decode(object), "resets_at = \(literal)")
            XCTAssertEqual(quota.fiveHour, MotherQuotaWindow(usedPct: 23, capPct: 90, resetsAt: nil), "resets_at = \(literal)")
            let text = MotherQuotaPresentation.windowText(label: "5h", try XCTUnwrap(quota.fiveHour), now: now, timeZone: chicago)
            XCTAssertEqual(text, "5h 23% / 90", "no reset time is shown for one that cannot be read")
        }
    }

    func testAHostileUntilIsNilAndTheBadgeStillSaysWhatItIs() throws {
        for literal in hostileNumbers + hostileStrings {
            guard let object = parsed(wire(until: literal)) else { continue }
            let quota = try XCTUnwrap(MotherQuota.decode(object), "until = \(literal)")
            XCTAssertNil(quota.until, "until = \(literal)")
            XCTAssertEqual(quota.gate, .offUntilReset)
            XCTAssertEqual(word(quota), "Gate off until reset", "until = \(literal)")
        }
    }

    func testEveryHostileFieldAtOnceStillDecodesThePartsThatAreSound() throws {
        let json = wire(feedAge: "100000000000000000000000", used: "1e30", cap: "-1e400", resets: "1e30", until: "-1e30")
        let object = try XCTUnwrap(parsed(json))
        let quota = try XCTUnwrap(MotherQuota.decode(object))

        XCTAssertEqual(quota.gate, .offUntilReset)
        XCTAssertNil(quota.feedAgeSeconds)
        XCTAssertNil(quota.until)
        XCTAssertNil(quota.fiveHour)
        XCTAssertEqual(quota.sevenDay?.usedPct, 50)
        // And every wording over it is fine.
        _ = word(quota)
        _ = MotherQuotaPresentation.badgeSpokenText(quota, now: now, timeZone: chicago)
        _ = MotherQuotaPresentation.staleText(quota)
    }

    func testAHostileNumberFromRawBytesNeverTrapsTheByteDecoder() {
        for literal in hostileNumbers + hostileStrings {
            _ = MotherQuota.decode(json: Data(wire(feedAge: literal, used: literal, cap: literal, resets: literal,
                                                   until: literal).utf8))
        }
    }

    func testANumberOffTheWireThatIsLargeButUsableIsKept() throws {
        // More than 100% used is a real thing (a window over its cap); a long feed age is real too.
        let quota = try XCTUnwrap(MotherQuota.decode(try XCTUnwrap(parsed(wire(feedAge: "86400", used: "250")))))
        XCTAssertEqual(quota.fiveHour?.usedPct, 250)
        XCTAssertEqual(quota.feedAgeSeconds, 86_400)
        XCTAssertEqual(MotherQuotaPresentation.staleText(quota), "Quota feed stale (1440m)")
    }

    func testOddButValidNumbersNeverTrapThePresentation() {
        let odd: [Double] = [1e14, 1e15, 1e19, 1e300, 123_456_789.5, 0.0000001, .infinity, -.infinity, .nan]
        for value in odd {
            let window = MotherQuotaWindow(usedPct: value, capPct: 90, resetsAt: nil)
            let text = MotherQuotaPresentation.windowText(label: "5h", window, now: now, timeZone: chicago)
            XCTAssertTrue(text.hasPrefix("5h "), "\(value): \(text)")
            let capped = MotherQuotaWindow(usedPct: 10, capPct: value, resetsAt: nil)
            XCTAssertTrue(MotherQuotaPresentation.windowText(label: "7d", capped, now: now, timeZone: chicago).hasPrefix("7d "))
        }
        let huge = MotherQuotaWindow(usedPct: 1e14, capPct: 90, resetsAt: nil)
        XCTAssertTrue(MotherQuotaPresentation.windowText(label: "5h", huge, now: now, timeZone: chicago).contains("paused"))
    }

    func testOddButValidTimesAndAgesNeverTrapThePresentation() throws {
        // The farthest and nearest instants the decoder admits, and ages at the Int extremes.
        for epoch in [0.0, 1.0, 1e12] {
            let window = MotherQuotaWindow(usedPct: 10, capPct: 90, resetsAt: date(epoch))
            XCTAssertTrue(MotherQuotaPresentation.windowText(label: "5h", window, now: now, timeZone: chicago).contains("resets"))
            var quota = try decoded { $0["gate"] = "off_until_reset" }
            quota.until = date(epoch)
            XCTAssertTrue(word(quota).hasPrefix("Gate off until reset"))
        }
        for age in [Int.max, Int.min, 0, -1] {
            var quota = try decoded { $0["stale"] = true }
            quota.feedAgeSeconds = age
            XCTAssertNotNil(MotherQuotaPresentation.staleText(quota), "\(age)")
        }
    }

    // MARK: - Presentation: the badge

    func testTheBadgeIsQuietWhenOnAndLoudWhenOff() throws {
        XCTAssertEqual(word(try decoded { $0["gate"] = "on"; $0["until"] = NSNull() }), "Gate on")
        XCTAssertEqual(word(try decoded { $0["gate"] = "off"; $0["until"] = NSNull() }), "Gate OFF")
    }

    func testTheOffUntilResetBadgeNamesWhenItEnds() throws {
        XCTAssertEqual(word(try decoded()), "Gate off until reset (resets 4:30 pm CT)")
        let later = try decoded { $0["until"] = 1_793_930_400 }
        XCTAssertEqual(word(later), "Gate off until reset (resets Thu 8 pm CT)")
    }

    func testTheOffUntilResetBadgeWithNoUntilStillSaysWhatItIs() throws {
        let quota = try decoded { $0["until"] = NSNull() }
        XCTAssertEqual(word(quota), "Gate off until reset")
    }

    func testBothOffStatesAreSpokenAsWarningsAndOnIsNot() throws {
        let off = try decoded { $0["gate"] = "off"; $0["until"] = NSNull() }
        let untilReset = try decoded()
        let on = try decoded { $0["gate"] = "on"; $0["until"] = NSNull() }
        for quota in [off, untilReset] {
            let spoken = MotherQuotaPresentation.badgeSpokenText(quota, now: now, timeZone: chicago)
            XCTAssertTrue(spoken.hasPrefix("Warning"), spoken)
            XCTAssertTrue(spoken.contains("off"), spoken)
        }
        XCTAssertTrue(MotherQuotaPresentation.badgeSpokenText(untilReset, now: now, timeZone: chicago).contains("4:30 pm CT"))
        XCTAssertFalse(MotherQuotaPresentation.badgeSpokenText(on, now: now, timeZone: chicago).hasPrefix("Warning"))
    }

    // MARK: - Presentation: the control's words

    func testTheControlsOptionsAreNamedAndSpokenFor() {
        XCTAssertEqual(MotherQuotaPresentation.optionTitle(.on), "On")
        XCTAssertEqual(MotherQuotaPresentation.optionTitle(.off), "Off")
        XCTAssertEqual(MotherQuotaPresentation.optionTitle(.offUntilReset), "Off until next reset")
        XCTAssertEqual(MotherQuotaPresentation.optionSpokenLabel(.on), "Turn quota gate on")
        XCTAssertEqual(MotherQuotaPresentation.optionSpokenLabel(.off), "Turn quota gate off")
        XCTAssertEqual(MotherQuotaPresentation.optionSpokenLabel(.offUntilReset), "Turn quota gate off until the next reset")
    }

    func testTheArmedStateAsksAndNamesWhatWillHappen() {
        XCTAssertEqual(MotherQuotaPresentation.armedPrompt, "Turn gate off? Click again to confirm")
        XCTAssertEqual(MotherQuotaPresentation.armedTitle(.off), "Off?")
        XCTAssertEqual(MotherQuotaPresentation.armedTitle(.offUntilReset), "Off until next reset?")
        for request in [MotherQuotaGateRequest.off, .offUntilReset] {
            let spoken = MotherQuotaPresentation.armedSpokenLabel(request)
            XCTAssertTrue(spoken.hasPrefix("Confirm"), spoken)
            XCTAssertTrue(spoken.contains("again"), "it says a second activation is needed: \(spoken)")
        }
        XCTAssertTrue(MotherQuotaPresentation.armedSpokenLabel(.offUntilReset).contains("until the next reset"))
    }
}
