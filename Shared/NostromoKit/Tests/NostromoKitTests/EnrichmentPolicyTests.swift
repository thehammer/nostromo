// EnrichmentPolicyTests.swift
//
// When the Notification Service Extension may ask the primary for a notification's detail line (W16).
// The rule, as the operator experiences it: only a notification that still needs them (not the
// replacement that says it no longer does), about a Mother job, a decision or a review (never the
// evening Summary), from a host they classified `personal`, and that they have not switched details
// off for. A host the phone does not know is a work host. A decision on a personal host IS enriched.

import XCTest
@testable import NostromoKit

final class EnrichmentPolicyTests: XCTestCase {

    private let kinds: [PushPayload.Kind] = [.mother, .decision, .review, .summary]
    /// A host's class as the phone last heard it; `nil` is a host that is not in the last `push_status`.
    private let hostClassChoices: [HostClassWire?] = [HostClassWire.personal, HostClassWire.work, nil]

    private func payload(_ kind: PushPayload.Kind, host: String = "sendai", resolved: Bool = false) -> PushPayload {
        PushPayload(item: "item-1", kind: kind, host: host, ref: nil, resolved: resolved)
    }

    // MARK: - The matrix

    func testOnlyAWaitingMotherDecisionOrReviewOnAnEnabledPersonalHostEnriches() {
        var checked = 0
        for kind in kinds {
            for hostClass in hostClassChoices {
                for switchedOff in [false, true] {
                    for resolved in [false, true] {
                        let classes: [String: HostClassWire] = hostClass.map { ["sendai": $0] } ?? [:]
                        let prefs = EnrichmentPrefs(disabledHosts: switchedOff ? ["sendai"] : [])
                        let actual = EnrichmentPolicy.shouldEnrich(payload: payload(kind, resolved: resolved),
                                                                   hostClasses: classes, prefs: prefs)
                        let expected = kind != .summary && hostClass == .personal && !switchedOff && !resolved
                        let label = "kind=\(kind) class=\(String(describing: hostClass)) off=\(switchedOff) resolved=\(resolved)"
                        XCTAssertEqual(actual, expected, label)
                        checked += 1
                    }
                }
            }
        }
        XCTAssertEqual(checked, 48, "4 kinds x 3 classes x 2 switches x 2 resolved")
    }

    func testADecisionOnAPersonalHostIsEnriched() {
        XCTAssertTrue(EnrichmentPolicy.shouldEnrich(payload: payload(.decision),
                                                    hostClasses: ["sendai": .personal],
                                                    prefs: EnrichmentPrefs()))
    }

    func testAReplacementIsNeverEnrichedEvenOnAPersonalHost() {
        for kind in [PushPayload.Kind.mother, .decision, .review] {
            XCTAssertFalse(EnrichmentPolicy.shouldEnrich(payload: payload(kind, resolved: true),
                                                         hostClasses: ["sendai": .personal],
                                                         prefs: EnrichmentPrefs()), "\(kind)")
        }
    }

    func testAHostThePhoneHasNotHeardOfCountsAsWork() {
        XCTAssertFalse(EnrichmentPolicy.shouldEnrich(payload: payload(.mother, host: "tokyo"),
                                                     hostClasses: [:], prefs: EnrichmentPrefs()))
        XCTAssertFalse(EnrichmentPolicy.shouldEnrich(payload: payload(.mother, host: "tokyo"),
                                                     hostClasses: ["sendai": .personal], prefs: EnrichmentPrefs()),
                       "another host being personal says nothing about this one")
    }

    func testTheSwitchIsPerHost() {
        let classes: [String: HostClassWire] = ["sendai": .personal, "tokyo": .personal]
        let prefs = EnrichmentPrefs(disabledHosts: ["sendai"])
        XCTAssertFalse(EnrichmentPolicy.shouldEnrich(payload: payload(.review, host: "sendai"),
                                                     hostClasses: classes, prefs: prefs))
        XCTAssertTrue(EnrichmentPolicy.shouldEnrich(payload: payload(.review, host: "tokyo"),
                                                    hostClasses: classes, prefs: prefs))
    }

    // MARK: - The switches

    func testPersonalHostsAreOnByDefaultAndOnlyAHostSwitchedOffIsRecorded() {
        var prefs = EnrichmentPrefs()
        XCTAssertTrue(prefs.isEnabled(host: "sendai"))
        XCTAssertTrue(prefs.disabledHosts.isEmpty)

        prefs.set(host: "sendai", enabled: false)
        XCTAssertFalse(prefs.isEnabled(host: "sendai"))
        XCTAssertTrue(prefs.isEnabled(host: "tokyo"))
        XCTAssertEqual(prefs.disabledHosts, ["sendai"])

        prefs.set(host: "sendai", enabled: true)
        XCTAssertTrue(prefs.isEnabled(host: "sendai"))
        XCTAssertTrue(prefs.disabledHosts.isEmpty, "switching back on forgets the host")
    }

    func testThePrefsRoundTripThroughJSON() throws {
        let prefs = EnrichmentPrefs(disabledHosts: ["sendai", "tokyo"])
        let back = try JSONDecoder().decode(EnrichmentPrefs.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(back, prefs)
    }
}
