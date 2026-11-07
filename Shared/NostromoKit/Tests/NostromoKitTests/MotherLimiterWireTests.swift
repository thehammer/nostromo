// NostromoKit — MotherLimiterWireTests.swift
//
// Mother's backpressure limiter block as the shared Kit decodes and words it.
//
// The contract is Mother's golden fixture, vendored as `tests/fixtures/mother-contract/limiter_block.json`:
// the `limiter` key of a subscribe snapshot and of each `limiter` event. Its `_doc` defines every field, so
// every concrete value below is the fixture's.
//
// Behaviour pinned here:
//   - the whole block decodes, field by field; the `off` block is exactly `{"v":1,"mode":"off"}`;
//   - an enum string this build does not know is `.unknown`, never a crash and never a guess;
//   - a missing or non-object block is nil (an older Mother), not an empty limiter;
//   - a missing value is nil, never a guessed default; a JSON boolean is not a number;
//   - the words: the strip line (observe says "would", enforce says "allowed"), the not-running text, the
//     detail rows, and a waiting job's text.

import XCTest
@testable import NostromoKit

final class MotherLimiterWireTests: XCTestCase {

    // MARK: - Fixture access

    private static let contractDir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // NostromoKitTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // NostromoKit
        .deletingLastPathComponent()   // Shared
        .deletingLastPathComponent()   // <repo>
        .appendingPathComponent("tests/fixtures/mother-contract")

    private func fixture() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.contractDir.appendingPathComponent("limiter_block.json"))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The fixture's `limiter_block` as a JSON object.
    private func block() throws -> [String: Any] {
        try XCTUnwrap(try fixture()["limiter_block"] as? [String: Any], "fixture has no limiter_block")
    }

    private func block(_ edit: (inout [String: Any]) -> Void) throws -> [String: Any] {
        var object = try block()
        edit(&object)
        return object
    }

    private func decoded(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> MotherLimiter {
        try XCTUnwrap(MotherLimiter.decode(try block(edit)), "the block did not decode")
    }

    private func decode(json: String) throws -> MotherLimiter {
        try XCTUnwrap(MotherLimiter.decode(json: Data(json.utf8)), "did not decode: \(json)")
    }

    private func rows(_ limiter: MotherLimiter) -> [String: String] {
        Dictionary(MotherLimiterPresentation.detailRows(limiter).map { ($0.title, $0.value) },
                   uniquingKeysWith: { first, _ in first })
    }

    // MARK: - The golden fixture

    func testTheGoldenFixtureDecodesToItsConcreteValues() throws {
        let l = try decoded()

        XCTAssertEqual(l.version, 1)
        XCTAssertEqual(l.mode, .observe)
        XCTAssertEqual(l.ageSeconds, 4)
        XCTAssertFalse(l.stale)
        XCTAssertNil(l.fault)
        XCTAssertFalse(l.isNotRunning)
        XCTAssertTrue(l.isShown)

        XCTAssertEqual(l.concurrency, MotherLimiter.Concurrency(
            ceiling: 5, allowed: 3, effective: 4, state: .backoff, detail: "cut 6m ago after 429; +1 in 9m"))
        XCTAssertEqual(l.burn, MotherLimiter.Burn(
            fleetUsdPerMin: 0.84, sustainableUsdPerMin: 0.61, pace: 1.38, window: .fiveHour, calibrated: true))
        XCTAssertEqual(l.reserve, MotherLimiter.Reserve(pct: 15, holding: false, enforceable: true))
        XCTAssertEqual(l.interactive, MotherLimiter.Interactive(state: .ok, pctPerHour: 4.2))
        XCTAssertEqual(l.overageInUse, false)
        XCTAssertEqual(l.gate, .on)
        XCTAssertEqual(l.lastDistress, MotherLimiter.Distress(
            at: "2026-11-06T22:10:03Z", agoSeconds: 360, kind: "api_retry", status: "429",
            jobId: "20261106-221000-example"))
        XCTAssertEqual(l.distress24h, 1)
        XCTAssertEqual(l.waiting, [MotherLimiter.Waiting(
            id: "20261106-221200-example", code: "next", reason: "next to start", source: "dispatch",
            advisory: false, would: MotherLimiter.Would(code: "reserve", reason: "reserve held for interactive work"),
            since: "2026-11-06T22:12:00Z")])
    }

    func testTheBlockDecodesTheSameFromItsRawJSONBytes() throws {
        let bytes = try JSONSerialization.data(withJSONObject: try block())
        XCTAssertEqual(MotherLimiter.decode(json: bytes), try decoded())
        XCTAssertNil(MotherLimiter.decode(json: Data("not json".utf8)))
        XCTAssertNil(MotherLimiter.decode(json: Data("[]".utf8)), "an array is not a limiter block")
    }

    func testASnapshotsDataCarriesTheBlockUnderLimiter() throws {
        // The fixture writes `limiter` as a placeholder string; the block is the value.
        let envelope = try XCTUnwrap(try fixture()["snapshot_envelope"] as? [String: Any])
        XCTAssertEqual(envelope["t"] as? String, "snapshot")
        var data = try XCTUnwrap(envelope["data"] as? [String: Any])
        XCTAssertEqual(data["limiter"] as? String, "<limiter_block>")
        XCTAssertNil(MotherLimiter.decode(data["limiter"]), "the placeholder string is not a block")

        data["limiter"] = try block()
        XCTAssertEqual(MotherLimiter.decode(data["limiter"]), try decoded())
    }

    func testALimiterEventsDataCarriesTheBlockUnderLimiter() throws {
        let envelope = try XCTUnwrap(try fixture()["event_envelope"] as? [String: Any])
        XCTAssertEqual(envelope["t"] as? String, "limiter")
        var data = try XCTUnwrap(envelope["data"] as? [String: Any])
        XCTAssertEqual(data["category"] as? String, "limiter")
        data["limiter"] = try block()
        XCTAssertEqual(MotherLimiter.decode(data["limiter"]), try decoded())
    }

    func testFieldsTheKitDoesNotKnowAreIgnored() throws {
        let extra = try decoded {
            $0["future_key"] = ["a": 1]
            var c = $0["concurrency"] as? [String: Any] ?? [:]
            c["future"] = "x"
            $0["concurrency"] = c
        }
        XCTAssertEqual(extra, try decoded(), "an additive key from a newer Mother costs nothing")
    }

    func testTheWaitingEntryForAJobIsFoundById() throws {
        let l = try decoded()
        XCTAssertEqual(l.waitingEntry(for: "20261106-221200-example")?.code, "next")
        XCTAssertNil(l.waitingEntry(for: "nope"))
    }

    // MARK: - Mode off

    func testTheOffBlockIsNotShownAndHasNothingElse() throws {
        let l = try decode(json: #"{"v":1,"mode":"off"}"#)
        XCTAssertEqual(l.version, 1)
        XCTAssertEqual(l.mode, .off)
        XCTAssertFalse(l.isShown)
        XCTAssertFalse(l.stale)
        XCTAssertNil(l.fault)
        XCTAssertNil(l.ageSeconds)
        XCTAssertNil(l.concurrency)
        XCTAssertNil(l.burn)
        XCTAssertNil(l.reserve)
        XCTAssertNil(l.interactive)
        XCTAssertNil(l.overageInUse)
        XCTAssertNil(l.gate)
        XCTAssertNil(l.lastDistress)
        XCTAssertNil(l.distress24h)
        XCTAssertEqual(l.waiting, [])
        XCTAssertEqual(MotherLimiterPresentation.lineText(l), "")
        XCTAssertTrue(MotherLimiterPresentation.detailRows(l).isEmpty)
    }

    // MARK: - Stale and fault

    func testStaleWithNoTickEverHasNoSubBlocks() throws {
        let l = try decode(json: #"{"v":1,"mode":"observe","age_s":null,"stale":true,"fault":null,"concurrency":null,"burn":null,"reserve":null,"interactive":null,"waiting":[]}"#)
        XCTAssertTrue(l.stale)
        XCTAssertNil(l.ageSeconds)
        XCTAssertNil(l.concurrency)
        XCTAssertNil(l.burn)
        XCTAssertNil(l.reserve)
        XCTAssertNil(l.interactive)
        XCTAssertTrue(l.isNotRunning)
        XCTAssertEqual(MotherLimiterPresentation.lineText(l), "Limiter (observe) · limiter not running — fixed concurrency")
    }

    func testAFaultCarriesItsWhyAndMeansNotRunning() throws {
        let l = try decoded { $0["fault"] = ["at": "2026-11-06T22:00:00Z", "why": "state.json unreadable"] }
        XCTAssertEqual(l.fault, "state.json unreadable")
        XCTAssertFalse(l.stale)
        XCTAssertTrue(l.isNotRunning)
        XCTAssertEqual(MotherLimiterPresentation.lineText(l), "Limiter (observe) · limiter not running — fixed concurrency")
        XCTAssertEqual(rows(l)["Status"], "limiter not running — fixed concurrency (state.json unreadable)")
    }

    func testAFaultWithNoWhyStillCountsAsAFault() throws {
        let l = try decoded { $0["fault"] = [String: Any]() }
        XCTAssertNotNil(l.fault)
        XCTAssertTrue(l.isNotRunning)
        let empty = try decoded { $0["fault"] = ["why": ""] }
        XCTAssertNotNil(empty.fault)
    }

    func testANonObjectFaultIsNoFault() throws {
        XCTAssertNil(try decoded { $0["fault"] = NSNull() }.fault)
        XCTAssertNil(try decoded { $0["fault"] = "boom" }.fault)
        XCTAssertNil(try decoded { $0.removeValue(forKey: "fault") }.fault)
    }

    func testStaleReadsInDetailRowsAndStaleWinsOverNumbers() throws {
        let l = try decoded { $0["stale"] = true }
        XCTAssertEqual(rows(l)["Status"], "limiter not running — fixed concurrency")
        XCTAssertEqual(MotherLimiterPresentation.lineText(l), "Limiter (observe) · limiter not running — fixed concurrency")
        XCTAssertFalse(MotherLimiterPresentation.lineText(l).contains("would allow"))
    }

    func testEnforceStaleReadsWithoutTheObserveLabel() throws {
        let l = try decoded { $0["mode"] = "enforce"; $0["stale"] = true }
        XCTAssertEqual(MotherLimiterPresentation.lineText(l), "Limiter · limiter not running — fixed concurrency")
    }

    // MARK: - Missing values stay nil

    func testNilBurnNumbersStayNil() throws {
        let l = try decoded {
            $0["burn"] = ["fleet_usd_per_min": NSNull(), "sustainable_usd_per_min": NSNull(), "pace": NSNull(),
                          "window": "seven_day", "calibrated": false]
        }
        XCTAssertEqual(l.burn, MotherLimiter.Burn(fleetUsdPerMin: nil, sustainableUsdPerMin: nil, pace: nil,
                                                  window: .sevenDay, calibrated: false))
        XCTAssertEqual(rows(l)["Burn"], "not calibrated yet")
    }

    func testABurnWithNothingToSayReadsUnknown() throws {
        let l = try decoded { $0["burn"] = ["window": "five_hour", "calibrated": true] }
        XCTAssertNil(l.burn?.fleetUsdPerMin)
        XCTAssertNil(l.burn?.sustainableUsdPerMin)
        XCTAssertNil(l.burn?.pace)
        XCTAssertEqual(rows(l)["Burn"], "unknown")
    }

    func testAnEmptyObservableBlockHasNoGuessedDefaults() throws {
        let l = try decode(json: #"{"mode":"observe"}"#)
        XCTAssertNil(l.version)
        XCTAssertNil(l.ageSeconds)
        XCTAssertFalse(l.stale)
        XCTAssertNil(l.fault)
        XCTAssertNil(l.concurrency)
        XCTAssertNil(l.burn)
        XCTAssertNil(l.reserve)
        XCTAssertNil(l.interactive)
        XCTAssertNil(l.overageInUse)
        XCTAssertNil(l.gate)
        XCTAssertNil(l.lastDistress)
        XCTAssertNil(l.distress24h)
        XCTAssertEqual(l.waiting, [])
        XCTAssertEqual(MotherLimiterPresentation.lineText(l), "Limiter (observe)")
    }

    func testNullLastDistressIsNilAndEmptyDetailIsNil() throws {
        let l = try decoded {
            $0["last_distress"] = NSNull()
            var c = $0["concurrency"] as? [String: Any] ?? [:]
            c["detail"] = ""
            $0["concurrency"] = c
        }
        XCTAssertNil(l.lastDistress)
        XCTAssertNil(l.concurrency?.detail)
        XCTAssertEqual(rows(l)["Last distress"], "none", "a 24h count with no last distress says none")
    }

    func testZeroAndOneAreNumbersOffTheWire() throws {
        let l = try decode(json: #"{"v":1,"mode":"observe","age_s":0,"distress_24h":0,"reserve":{"pct":0,"holding":true},"burn":{"pace":1}}"#)
        XCTAssertEqual(l.ageSeconds, 0, "age_s 0 is a fresh tick, not a missing age")
        XCTAssertEqual(l.distress24h, 0)
        XCTAssertEqual(l.reserve?.pct, 0)
        XCTAssertEqual(l.reserve?.holding, true)
        XCTAssertEqual(l.burn?.pace, 1)
    }

    func testAJSONBooleanIsNotANumber() throws {
        let l = try decode(json: #"{"v":true,"mode":"observe","age_s":true,"distress_24h":false,"concurrency":{"ceiling":true,"allowed":false,"effective":true},"burn":{"pace":true,"fleet_usd_per_min":false},"last_distress":{"ago_s":true,"status":true}}"#)
        XCTAssertNil(l.version)
        XCTAssertNil(l.ageSeconds)
        XCTAssertNil(l.distress24h)
        XCTAssertNil(l.concurrency?.ceiling)
        XCTAssertNil(l.concurrency?.allowed)
        XCTAssertNil(l.concurrency?.effective)
        XCTAssertNil(l.burn?.pace)
        XCTAssertNil(l.burn?.fleetUsdPerMin)
        XCTAssertNil(l.lastDistress?.agoSeconds)
        XCTAssertNil(l.lastDistress?.status, "a boolean status is neither a code nor a reason")
    }

    func testHostileNumbersAreNilAndTheRestOfTheBlockStands() throws {
        let l = try decoded {
            $0["age_s"] = 1e30
            $0["distress_24h"] = "NaN"
            var b = $0["burn"] as? [String: Any] ?? [:]
            b["pace"] = Double.infinity
            $0["burn"] = b
        }
        XCTAssertNil(l.ageSeconds)
        XCTAssertNil(l.distress24h)
        XCTAssertNil(l.burn?.pace)
        XCTAssertEqual(l.burn?.fleetUsdPerMin, 0.84)
        XCTAssertEqual(l.concurrency?.allowed, 3)
    }

    // MARK: - Unknown enums

    func testAnUnknownModeIsUnknownAndNotShown() throws {
        let l = try decoded { $0["mode"] = "paused" }
        XCTAssertEqual(l.mode, .unknown("paused"))
        XCTAssertFalse(l.isShown)
        XCTAssertEqual(MotherLimiterPresentation.lineText(l), "")
        XCTAssertEqual(l.concurrency?.allowed, 3, "the rest of the block still decodes")
    }

    func testAMissingOrNonStringModeIsUnknownToo() throws {
        XCTAssertEqual(try decoded { $0.removeValue(forKey: "mode") }.mode, .unknown(""))
        XCTAssertEqual(try decoded { $0["mode"] = 3 }.mode, .unknown(""))
    }

    func testEnforceModeIsShown() throws {
        let l = try decoded { $0["mode"] = "enforce" }
        XCTAssertEqual(l.mode, .enforce)
        XCTAssertTrue(l.isShown)
    }

    func testWireStringsAreExactAndCaseSensitive() {
        XCTAssertEqual(MotherLimiter.Mode(wire: "off"), .off)
        XCTAssertEqual(MotherLimiter.Mode(wire: "observe"), .observe)
        XCTAssertEqual(MotherLimiter.Mode(wire: "enforce"), .enforce)
        XCTAssertEqual(MotherLimiter.Mode(wire: "Observe"), .unknown("Observe"))
        XCTAssertEqual(MotherLimiter.Mode(wire: nil), .unknown(""))

        XCTAssertEqual(MotherLimiter.ConcurrencyState(wire: "steady"), .steady)
        XCTAssertEqual(MotherLimiter.ConcurrencyState(wire: "backoff"), .backoff)
        XCTAssertEqual(MotherLimiter.ConcurrencyState(wire: "ramp"), .ramp)
        XCTAssertEqual(MotherLimiter.ConcurrencyState(wire: "uncalibrated"), .uncalibrated)
        XCTAssertEqual(MotherLimiter.ConcurrencyState(wire: "Steady"), .unknown("Steady"))

        XCTAssertEqual(MotherLimiter.BurnWindow(wire: "five_hour"), .fiveHour)
        XCTAssertEqual(MotherLimiter.BurnWindow(wire: "seven_day"), .sevenDay)
        XCTAssertEqual(MotherLimiter.BurnWindow(wire: "5h"), .unknown("5h"))

        XCTAssertEqual(MotherLimiter.InteractiveState(wire: "ok"), .ok)
        XCTAssertEqual(MotherLimiter.InteractiveState(wire: "high"), .high)
        XCTAssertEqual(MotherLimiter.InteractiveState(wire: "unknown"), .unknownState)
        XCTAssertEqual(MotherLimiter.InteractiveState(wire: "elevated"), .unknown("elevated"))
    }

    func testUnknownNestedEnumStringsAreUnknownNeverACrash() throws {
        let l = try decoded {
            var c = $0["concurrency"] as? [String: Any] ?? [:]
            c["state"] = "thrashing"
            $0["concurrency"] = c
            var b = $0["burn"] as? [String: Any] ?? [:]
            b["window"] = "hourly"
            $0["burn"] = b
            $0["interactive"] = ["state": "elevated", "pct_per_hour": 9]
            $0["gate"] = "paused_for_review"
        }
        XCTAssertEqual(l.concurrency?.state, .unknown("thrashing"))
        XCTAssertEqual(l.burn?.window, .unknown("hourly"))
        XCTAssertEqual(l.interactive?.state, .unknown("elevated"))
        XCTAssertEqual(l.gate, .unknown("paused_for_review"))
        XCTAssertEqual(MotherLimiterPresentation.stateText(try XCTUnwrap(l.concurrency)),
                       "thrashing: cut 6m ago after 429; +1 in 9m")
        let r = rows(l)
        XCTAssertEqual(r["Burn"], "$0.84/min vs $0.61/min sustainable · pace 1.38×", "an unknown window names no window")
        XCTAssertEqual(r["Interactive"], "elevated · 9%/h")
        XCTAssertEqual(r["Gate"], "paused_for_review")
    }

    func testAMissingStateReadsAsStateUnknown() throws {
        let l = try decoded {
            var c = $0["concurrency"] as? [String: Any] ?? [:]
            c.removeValue(forKey: "state")
            c["detail"] = NSNull()
            $0["concurrency"] = c
        }
        XCTAssertEqual(l.concurrency?.state, .unknown(""))
        XCTAssertEqual(MotherLimiterPresentation.stateText(try XCTUnwrap(l.concurrency)), "state unknown")
    }

    // MARK: - Absent or unreadable blocks

    func testAnAbsentBlockIsNil() {
        XCTAssertNil(MotherLimiter.decode(nil))
    }

    func testANonObjectBlockIsNil() {
        XCTAssertNil(MotherLimiter.decode(NSNull()))
        XCTAssertNil(MotherLimiter.decode("<limiter_block>"), "a string (the fixture's own placeholder) is not a block")
        XCTAssertNil(MotherLimiter.decode(42))
        XCTAssertNil(MotherLimiter.decode(true))
        XCTAssertNil(MotherLimiter.decode([["mode": "observe"]]), "an array is not a block")
        let none: [String: Any]? = nil
        XCTAssertNil(MotherLimiter.decode(none))
    }

    func testAnEmptyObjectIsABlockWithAnUnknownMode() {
        let l = MotherLimiter.decode([String: Any]())
        XCTAssertNotNil(l)
        XCTAssertEqual(l?.mode, .unknown(""))
        XCTAssertEqual(l?.waiting, [])
    }

    // MARK: - Status as a number or a string

    func testStatusGivenAsANumberReadsAsItsDigits() throws {
        let l = try decoded { $0["last_distress"] = ["status": 429, "kind": "api_retry", "ago_s": 360] }
        XCTAssertEqual(l.lastDistress?.status, "429")
        let fraction = try decoded { $0["last_distress"] = ["status": 503.0] }
        XCTAssertEqual(fraction.lastDistress?.status, "503")
    }

    func testStatusGivenAsAStringStaysAsSent() throws {
        let l = try decoded { $0["last_distress"] = ["status": "overloaded", "kind": "result_error", "ago_s": 30] }
        XCTAssertEqual(l.lastDistress?.status, "overloaded")
        XCTAssertEqual(MotherLimiterPresentation.lineText(l).hasSuffix("last overloaded 30s ago"), true)
    }

    func testAMissingOrEmptyStatusFallsBackToTheKindInWords() throws {
        let l = try decoded { $0["last_distress"] = ["status": "", "kind": "rate_limit_rejected", "ago_s": 120] }
        XCTAssertNil(l.lastDistress?.status)
        XCTAssertEqual(MotherLimiterPresentation.distressName(try XCTUnwrap(l.lastDistress)), "rate limit rejected")
        XCTAssertTrue(MotherLimiterPresentation.lineText(l).hasSuffix("last rate limit rejected 2m ago"))

        let bare = try decoded { $0["last_distress"] = [String: Any]() }
        XCTAssertEqual(MotherLimiterPresentation.distressName(try XCTUnwrap(bare.lastDistress)), "distress")
        XCTAssertTrue(MotherLimiterPresentation.lineText(bare).hasSuffix("last distress (time unknown)"))
    }

    // MARK: - Waiting

    func testWaitingEntriesWithoutAnIdAreDropped() throws {
        let l = try decoded {
            $0["waiting"] = [
                ["code": "dep_wait", "reason": "waiting on a dependency"],
                ["id": "", "code": "dep_wait", "reason": "empty id"],
                ["id": "job-a", "code": "backoff", "reason": "backing off"],
            ] as [[String: Any]]
        }
        XCTAssertEqual(l.waiting.map(\.id), ["job-a"])
    }

    func testWaitingEntriesWithoutAReasonAreDropped() throws {
        let l = try decoded {
            $0["waiting"] = [["id": "job-a", "code": "next"], ["id": "job-b", "code": "next", "reason": ""]]
        }
        XCTAssertEqual(l.waiting, [])
    }

    func testAWaitingEntryDefaultsItsOptionalFieldsHonestly() throws {
        let l = try decoded { $0["waiting"] = [["id": "job-a", "reason": "slot taken"]] }
        XCTAssertEqual(l.waiting, [MotherLimiter.Waiting(id: "job-a", code: "", reason: "slot taken", source: nil,
                                                         advisory: false, would: nil, since: nil)])
    }

    func testAWouldWithoutAReasonIsNoWould() throws {
        let l = try decoded {
            $0["waiting"] = [["id": "job-a", "reason": "slot taken", "would": ["code": "ramp"]] as [String: Any]]
        }
        XCTAssertNil(l.waiting.first?.would)
        let nullWould = try decoded {
            $0["waiting"] = [["id": "job-a", "reason": "slot taken", "would": NSNull()] as [String: Any]]
        }
        XCTAssertNil(nullWould.waiting.first?.would)
    }

    func testAnAdvisoryWaitingEntryIsRead() throws {
        let l = try decoded {
            $0["waiting"] = [["id": "job-a", "reason": "quota over cap", "code": "quota_over_cap",
                              "source": "limiter", "advisory": true] as [String: Any]]
        }
        XCTAssertEqual(l.waiting.first?.advisory, true)
        XCTAssertEqual(l.waiting.first?.source, "limiter")
    }

    func testAMissingWaitingListIsEmpty() throws {
        XCTAssertEqual(try decoded { $0.removeValue(forKey: "waiting") }.waiting, [])
        XCTAssertEqual(try decoded { $0["waiting"] = NSNull() }.waiting, [])
    }

    // MARK: - decodeWait (a job record's limiter.wait)

    func testDecodeWaitWithAWould() throws {
        let wait = try XCTUnwrap(MotherLimiter.decodeWait([
            "code": "next", "reason": "next to start", "source": "dispatch", "advisory": false,
            "would": ["code": "reserve", "reason": "reserve held for interactive work"],
            "since": "2026-11-06T22:12:00Z",
        ] as [String: Any]))
        XCTAssertEqual(wait.id, "", "a job record's wait names no id")
        XCTAssertEqual(wait.code, "next")
        XCTAssertEqual(wait.reason, "next to start")
        XCTAssertEqual(wait.source, "dispatch")
        XCTAssertEqual(wait.would, MotherLimiter.Would(code: "reserve", reason: "reserve held for interactive work"))
        XCTAssertEqual(wait.since, "2026-11-06T22:12:00Z")
    }

    func testDecodeWaitWithoutAWould() throws {
        let wait = try XCTUnwrap(MotherLimiter.decodeWait(["code": "dep_wait", "reason": "waiting on a dependency"]))
        XCTAssertNil(wait.would)
        XCTAssertEqual(wait.reason, "waiting on a dependency")
        XCTAssertFalse(wait.advisory)
    }

    func testDecodeWaitIsNilWhenAbsentOrWithoutAReason() {
        XCTAssertNil(MotherLimiter.decodeWait(nil))
        XCTAssertNil(MotherLimiter.decodeWait(NSNull()))
        XCTAssertNil(MotherLimiter.decodeWait("next"))
        XCTAssertNil(MotherLimiter.decodeWait(["code": "next"]))
        XCTAssertNil(MotherLimiter.decodeWait(["code": "next", "reason": ""]))
    }

    // MARK: - Presentation: the strip line

    func testTheFixtureReadsTheWayTheStripShowsIt() throws {
        let text = MotherLimiterPresentation.lineText(try decoded())
        XCTAssertTrue(text.contains("would allow 3 of 5"), text)
        XCTAssertTrue(text.contains("4 running"), text)
        XCTAssertTrue(text.contains("backoff: cut 6m ago after 429; +1 in 9m"), text)
        XCTAssertTrue(text.contains("last 429 6m ago"), text)
        XCTAssertEqual(text, "Limiter (observe) · would allow 3 of 5 · 4 running · backoff: cut 6m ago after 429; +1 in 9m · last 429 6m ago")
    }

    func testEnforceSaysAllowedNotWould() throws {
        let text = MotherLimiterPresentation.lineText(try decoded { $0["mode"] = "enforce" })
        XCTAssertTrue(text.contains("3 of 5 allowed"), text)
        XCTAssertFalse(text.contains("would"), text)
        XCTAssertFalse(text.contains("(observe)"), text)
        XCTAssertTrue(text.hasPrefix("Limiter · "), text)
    }

    func testASteadyStateAddsNoStateClauseAndNoDistressAddsNoDistressClause() throws {
        let l = try decoded {
            var c = $0["concurrency"] as? [String: Any] ?? [:]
            c["state"] = "steady"
            c["detail"] = ""
            $0["concurrency"] = c
            $0["last_distress"] = NSNull()
        }
        XCTAssertEqual(MotherLimiterPresentation.lineText(l), "Limiter (observe) · would allow 3 of 5 · 4 running")
    }

    func testAnAllowedCountWithNoCeilingOmitsTheOf() throws {
        let l = try decoded {
            $0["concurrency"] = ["allowed": 3, "state": "steady"]
            $0["last_distress"] = NSNull()
        }
        XCTAssertEqual(MotherLimiterPresentation.lineText(l), "Limiter (observe) · would allow 3")
    }

    func testStateTextWithAndWithoutDetail() {
        func c(_ state: MotherLimiter.ConcurrencyState, _ detail: String?) -> MotherLimiter.Concurrency {
            MotherLimiter.Concurrency(ceiling: 5, allowed: 3, effective: 4, state: state, detail: detail)
        }
        XCTAssertNil(MotherLimiterPresentation.stateText(c(.steady, "ignored")))
        XCTAssertEqual(MotherLimiterPresentation.stateText(c(.backoff, "+1 in 9m")), "backoff: +1 in 9m")
        XCTAssertEqual(MotherLimiterPresentation.stateText(c(.ramp, nil)), "ramp")
        XCTAssertEqual(MotherLimiterPresentation.stateText(c(.uncalibrated, nil)), "uncalibrated")
    }

    // MARK: - Presentation: ago

    func testAgoReadsSecondsMinutesHoursDays() {
        XCTAssertEqual(MotherLimiterPresentation.ago(0), "0s ago")
        XCTAssertEqual(MotherLimiterPresentation.ago(45), "45s ago")
        XCTAssertEqual(MotherLimiterPresentation.ago(59), "59s ago")
        XCTAssertEqual(MotherLimiterPresentation.ago(60), "1m ago")
        XCTAssertEqual(MotherLimiterPresentation.ago(360), "6m ago")
        XCTAssertEqual(MotherLimiterPresentation.ago(3599), "59m ago")
        XCTAssertEqual(MotherLimiterPresentation.ago(3600), "1h ago")
        XCTAssertEqual(MotherLimiterPresentation.ago(7200), "2h ago")
        XCTAssertEqual(MotherLimiterPresentation.ago(86_400), "1d ago")
        XCTAssertEqual(MotherLimiterPresentation.ago(172_800), "2d ago")
    }

    func testAgoNeverShowsANegativeAndNamesAnUnknownAge() {
        XCTAssertEqual(MotherLimiterPresentation.ago(-30), "0s ago")
        XCTAssertEqual(MotherLimiterPresentation.ago(nil), "(time unknown)")
        _ = MotherLimiterPresentation.ago(Int.max)
        _ = MotherLimiterPresentation.ago(Int.min + 1)
    }

    // MARK: - Presentation: detail rows

    func testTheFixturesDetailRows() throws {
        let titles = MotherLimiterPresentation.detailRows(try decoded()).map(\.title)
        XCTAssertEqual(titles, ["Mode", "Burn", "Reserve", "Interactive", "Overage", "Gate", "Last distress", "Distress, 24h"])

        let r = rows(try decoded())
        XCTAssertEqual(r["Mode"], "observe: shows what the limiter would do, dispatch is unchanged")
        XCTAssertEqual(r["Burn"], "$0.84/min vs $0.61/min sustainable · pace 1.38× (5h window)")
        XCTAssertEqual(r["Reserve"], "15% of 5h kept for interactive · not holding")
        XCTAssertEqual(r["Interactive"], "ok · 4.2%/h")
        XCTAssertEqual(r["Overage"], "not in use")
        XCTAssertEqual(r["Gate"], "on")
        XCTAssertEqual(r["Last distress"], "429 · 6m ago · api retry · job 20261106-221000-example")
        XCTAssertEqual(r["Distress, 24h"], "1")
        XCTAssertNil(r["Status"], "a running limiter has no status row")
    }

    func testEnforceHasNoObserveModeRow() throws {
        XCTAssertNil(rows(try decoded { $0["mode"] = "enforce" })["Mode"])
    }

    func testDetailRowsLeaveOutWhatTheBlockDidNotCarry() throws {
        let l = try decode(json: #"{"v":1,"mode":"enforce","gate":"off_until_reset","overage_in_use":true}"#)
        XCTAssertEqual(MotherLimiterPresentation.detailRows(l).map(\.title), ["Overage", "Gate"])
        let r = rows(l)
        XCTAssertEqual(r["Overage"], "in use")
        XCTAssertEqual(r["Gate"], "off until reset")
    }

    func testAReserveThatIsHoldingOrAdvisoryIsSaidSo() throws {
        let holding = try decoded { $0["reserve"] = ["pct": 15, "holding": true, "enforceable": false] }
        XCTAssertEqual(rows(holding)["Reserve"],
                       "15% of 5h kept for interactive · holding · advisory (not enforceable now)")
    }

    func testAnInteractiveStateWithNoRateIsJustTheState() throws {
        let l = try decoded { $0["interactive"] = ["state": "high", "pct_per_hour": NSNull()] }
        XCTAssertEqual(rows(l)["Interactive"], "high")
        let unknown = try decoded { $0["interactive"] = ["state": "unknown"] }
        XCTAssertEqual(rows(unknown)["Interactive"], "unknown")
    }

    func testBurnWithOnlyAFleetRateAndSevenDayPace() throws {
        let l = try decoded {
            $0["burn"] = ["fleet_usd_per_min": 0.5, "pace": 0.8, "window": "seven_day", "calibrated": true]
        }
        XCTAssertEqual(rows(l)["Burn"], "$0.50/min · pace 0.80× (7d window)")
    }

    func testDistressWithNoLastOneAndNoCountHasNoRow() throws {
        let l = try decoded { $0["last_distress"] = NSNull(); $0.removeValue(forKey: "distress_24h") }
        XCTAssertNil(rows(l)["Last distress"])
        XCTAssertNil(rows(l)["Distress, 24h"])
    }

    // MARK: - Presentation: not running and off

    func testNotRunningReadsTheFixedConcurrencyText() {
        XCTAssertEqual(MotherLimiterPresentation.notRunningText, "limiter not running — fixed concurrency")
    }

    func testOffReadsAsNothing() throws {
        XCTAssertEqual(MotherLimiterPresentation.lineText(try XCTUnwrap(MotherLimiter.decode(["v": 1, "mode": "off"]))), "")
        XCTAssertEqual(MotherLimiterPresentation.lineText(try decoded { $0["mode"] = "off" }), "")
    }

    // MARK: - Presentation: a waiting job

    func testAWaitingJobWithADifferingWouldSaysBoth() throws {
        let wait = try XCTUnwrap(try decoded().waiting.first)
        XCTAssertEqual(MotherLimiterPresentation.waitText(wait),
                       "Waiting: next to start (would: reserve held for interactive work)")
    }

    func testAWaitingJobWithNoWouldSaysOnlyItsReason() throws {
        var wait = try XCTUnwrap(try decoded().waiting.first)
        wait.would = nil
        XCTAssertEqual(MotherLimiterPresentation.waitText(wait), "Waiting: next to start")
    }

    func testAWouldThatMatchesTheReasonIsNotRepeated() throws {
        var wait = try XCTUnwrap(try decoded().waiting.first)
        wait.would = MotherLimiter.Would(code: "reserve", reason: "next to start")
        XCTAssertEqual(MotherLimiterPresentation.waitText(wait), "Waiting: next to start")
    }
}
