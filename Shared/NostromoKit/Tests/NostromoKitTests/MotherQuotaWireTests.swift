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
//   - the strip's words: `5h 15% / 90 · resets 8:40 pm`, `7d 100% / 90 · paused · resets Thu 8 pm`,
//     the badge texts, and the stale-feed text.
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
        XCTAssertEqual(windowText("5h", used: 15, resets: 1_793_673_600), "5h 15% / 90 · resets 8:40 pm")
    }

    func testAWindowOverItsCapSaysPausedAndNamesTheResetDay() {
        XCTAssertEqual(windowText("7d", used: 100, resets: 1_793_930_400), "7d 100% / 90 · paused · resets Thu 8 pm")
    }

    func testTheFixturesWindowsReadTheWayTheStripShowsThem() throws {
        let quota = try decoded()
        XCTAssertEqual(MotherQuotaPresentation.windowText(label: "5h", try XCTUnwrap(quota.fiveHour),
                                                          now: now, timeZone: chicago),
                       "5h 23% / 90 · resets 4:30 pm")
        XCTAssertEqual(MotherQuotaPresentation.windowText(label: "7d", try XCTUnwrap(quota.sevenDay),
                                                          now: now, timeZone: chicago),
                       "7d 100% / 90 · paused · resets Thu 8 pm")
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
        XCTAssertEqual(MotherQuotaPresentation.resetTime(date(1_793_642_400), now: now, timeZone: chicago), "12 pm")
        XCTAssertEqual(MotherQuotaPresentation.resetTime(date(1_793_685_600), now: now, timeZone: chicago), "Tue 12 am")
        XCTAssertEqual(MotherQuotaPresentation.resetTime(date(1_793_685_900), now: now, timeZone: chicago), "Tue 12:05 am")
        XCTAssertEqual(MotherQuotaPresentation.resetTime(date(1_793_718_300), now: now, timeZone: chicago), "Tue 9:05 am")
    }

    func testTheSameInstantReadsDifferentlyInAnotherZone() {
        // 22:30 UTC Monday: 4:30 pm in Chicago, 10:30 pm in UTC.
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(MotherQuotaPresentation.resetTime(date(1_793_658_600), now: now, timeZone: chicago), "4:30 pm")
        XCTAssertEqual(MotherQuotaPresentation.resetTime(date(1_793_658_600), now: now, timeZone: utc), "10:30 pm")
    }

    // MARK: - Presentation: the badge

    func testTheBadgeIsQuietWhenOnAndLoudWhenOff() throws {
        XCTAssertEqual(word(try decoded { $0["gate"] = "on"; $0["until"] = NSNull() }), "Gate on")
        XCTAssertEqual(word(try decoded { $0["gate"] = "off"; $0["until"] = NSNull() }), "Gate OFF")
    }

    func testTheOffUntilResetBadgeNamesWhenItEnds() throws {
        XCTAssertEqual(word(try decoded()), "Gate off until reset (resets 4:30 pm)")
        let later = try decoded { $0["until"] = 1_793_930_400 }
        XCTAssertEqual(word(later), "Gate off until reset (resets Thu 8 pm)")
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
        XCTAssertTrue(MotherQuotaPresentation.badgeSpokenText(untilReset, now: now, timeZone: chicago).contains("4:30 pm"))
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
