// NostromoKit — NeedsYouTests.swift
//
// The needs-you aggregate (MC4): one count of what is waiting on the person, built from
// independent producers, and the Mother producer's rules for what counts.

import XCTest
import NostromoKit

final class NeedsYouTests: XCTestCase {

    // MARK: - Builders

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    private func item(_ id: String, _ source: NeedsYouSource = .app, since: Date? = nil,
                      reason: NeedsYouReason = .other("x")) -> NeedsYouItem {
        NeedsYouItem(id: id, source: source, reason: reason, since: since)
    }

    private func job(_ id: String = "j1", state: String = "running", title: String = "A job",
                     originLabel: String? = nil, crew: MotherCrewState = MotherCrewState()) -> MotherJob {
        MotherJob(id: id, state: state, title: title, originLabel: originLabel, crew: crew)
    }

    private func decision(open: Bool = true, openedAt: String? = "2026-10-17T12:00:02.000Z") -> MotherDecision {
        MotherDecision(id: "d-1", kind: "gate_hold", options: [], openedAt: openedAt,
                       resolvedAt: open ? nil : "2026-10-17T12:30:00.000Z")
    }

    private func items(_ jobs: [MotherJob]) -> [NeedsYouItem] {
        MotherNeedsYouProducer.items(from: jobs)
    }

    // MARK: - Aggregator

    func testSnapshotCountsTotalPerFocusAndMother() {
        var agg = NeedsYouAggregator()
        agg.set(producer: "mother", items: [
            item("mother:j1:await", .motherJob("j1")),
            item("mother:j2:await", .motherJob("j2")),
        ])
        agg.set(producer: "decisions", items: [
            item("decisions:a", .focus("a")), item("decisions:a2", .focus("a")), item("decisions:b", .focus("b")),
        ])
        agg.set(producer: "approvals", items: [item("approvals:1", .app)])

        let snap = agg.snapshot
        XCTAssertEqual(snap.total, 6)
        XCTAssertEqual(snap.mother, 2)
        XCTAssertEqual(snap.perFocus, ["a": 2, "b": 1])
        XCTAssertEqual(snap.items.count, 6)
    }

    func testEmptyAggregatorIsTheEmptySnapshot() {
        let agg = NeedsYouAggregator()
        XCTAssertEqual(agg.snapshot, NeedsYouSnapshot.empty)
        XCTAssertEqual(NeedsYouSnapshot.empty.total, 0)
        XCTAssertTrue(NeedsYouSnapshot.empty.items.isEmpty)
    }

    func testItemsAreOrderedBySinceAscendingWithNilLastAndTiesById() {
        let early = date("2026-10-17T10:00:00Z")
        let late = date("2026-10-17T11:00:00Z")
        var agg = NeedsYouAggregator()
        agg.set(producer: "p", items: [
            item("p:nil-b"), item("p:late", since: late), item("p:tie-b", since: early),
            item("p:nil-a"), item("p:tie-a", since: early),
        ])
        XCTAssertEqual(agg.snapshot.items.map(\.id),
                       ["p:tie-a", "p:tie-b", "p:late", "p:nil-a", "p:nil-b"])
    }

    func testTheSameRawIdUnderTwoProducersStaysDistinct() {
        var agg = NeedsYouAggregator()
        agg.set(producer: "mother", items: [item("7")])
        agg.set(producer: "approvals", items: [item("7")])

        let ids = agg.snapshot.items.map(\.id)
        XCTAssertEqual(agg.snapshot.total, 2)
        XCTAssertEqual(Set(ids).count, 2, "\(ids)")
        XCTAssertEqual(Set(ids), ["mother:7", "approvals:7"])
    }

    func testAnIdAlreadyCarryingItsProducersPrefixIsNotPrefixedTwice() {
        var agg = NeedsYouAggregator()
        agg.set(producer: "mother", items: [item("mother:j1:await")])
        XCTAssertEqual(agg.snapshot.items.map(\.id), ["mother:j1:await"])
    }

    func testAnItemsProducerIsItsIdUpToTheFirstColon() {
        XCTAssertEqual(item("mother:j1:await").producer, "mother")
        XCTAssertEqual(item("decisions:tag").producer, "decisions")
    }

    func testSettingTheSameItemsAgainGivesAnEqualSnapshot() {
        var agg = NeedsYouAggregator()
        let list = [item("mother:j1:await", .motherJob("j1"), since: date("2026-10-17T10:00:00Z"))]
        let first = agg.set(producer: "mother", items: list)
        let second = agg.set(producer: "mother", items: list)
        XCTAssertEqual(first, second)
        XCTAssertEqual(second, agg.snapshot)
    }

    func testSettingAnEmptyListRemovesThatProducerOnly() {
        var agg = NeedsYouAggregator()
        agg.set(producer: "mother", items: [item("mother:j1:await", .motherJob("j1"))])
        agg.set(producer: "decisions", items: [item("decisions:a", .focus("a"))])

        let after = agg.set(producer: "mother", items: [])
        XCTAssertEqual(after.total, 1)
        XCTAssertEqual(after.mother, 0)
        XCTAssertEqual(after.items.map(\.id), ["decisions:a"])

        agg.set(producer: "decisions", items: [])
        XCTAssertEqual(agg.snapshot, NeedsYouSnapshot.empty)
    }

    func testReplacingAProducersItemsReplacesRatherThanAdds() {
        var agg = NeedsYouAggregator()
        agg.set(producer: "mother", items: [item("mother:j1:await", .motherJob("j1")),
                                            item("mother:j2:await", .motherJob("j2"))])
        agg.set(producer: "mother", items: [item("mother:j2:await", .motherJob("j2"))])
        XCTAssertEqual(agg.snapshot.items.map(\.id), ["mother:j2:await"])
    }

    // MARK: - Mother producer: awaiting jobs

    func testAPlainAwaitingJobYieldsOneAwaitItem() {
        let out = items([job("j1", state: "awaiting")])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].id, "mother:j1:await")
        XCTAssertEqual(out[0].source, .motherJob("j1"))
        XCTAssertEqual(out[0].reason, .motherAwaiting)
        XCTAssertFalse(out[0].sensitive)
        XCTAssertNil(out[0].since)
    }

    func testAGateHoldIsOneItemAndItsDecisionAttentionIsNotCountedTwice() {
        let crew = MotherCrewState(
            activity: "gate_hold", decision: decision(),
            attention: [MotherAttention(reason: .decisionAwaiting, since: "2026-10-17T12:00:02.000Z")])
        let out = items([job("j1", state: "awaiting", crew: crew)])
        XCTAssertEqual(out.map(\.id), ["mother:j1:await"])
        XCTAssertEqual(out[0].reason, .motherHold(.gatesExhausted))
    }

    func testAReviewHoldIsAReviewHold() {
        let crew = MotherCrewState(activity: "review_hold", decision: decision())
        let out = items([job("j1", state: "awaiting", crew: crew)])
        XCTAssertEqual(out.map(\.reason), [.motherHold(.reviewHold)])
    }

    func testAnOpenDecisionOnAnAwaitingJobIsADecisionHold() {
        let crew = MotherCrewState(decision: decision())
        let out = items([job("j1", state: "awaiting", crew: crew)])
        XCTAssertEqual(out.map(\.reason), [.motherHold(.decision)])
    }

    func testAResolvedDecisionDoesNotMakeAnAwaitingJobAHold() {
        let crew = MotherCrewState(decision: decision(open: false))
        let out = items([job("j1", state: "awaiting", crew: crew)])
        XCTAssertEqual(out.map(\.reason), [.motherAwaiting])
    }

    func testTheAwaitItemIsSinceTheOpenDecisionOpenedAt() {
        let crew = MotherCrewState(
            decision: decision(openedAt: "2026-10-17T12:00:02.500Z"),
            attention: [MotherAttention(reason: .decisionAwaiting, since: "2026-10-17T09:00:00Z")])
        let out = items([job("j1", state: "awaiting", crew: crew)])
        XCTAssertEqual(out.first?.since, date("2026-10-17T12:00:02.500Z"))
    }

    func testWithoutADecisionTheAwaitItemIsSinceTheDecisionAwaitingAttention() {
        let crew = MotherCrewState(
            attention: [MotherAttention(reason: .decisionAwaiting, since: "2026-10-17T09:00:00Z")])
        let out = items([job("j1", state: "awaiting", crew: crew)])
        XCTAssertEqual(out.map(\.id), ["mother:j1:await"])
        XCTAssertEqual(out.first?.since, date("2026-10-17T09:00:00Z"))
    }

    func testARunningJobWithOnlyADecisionAwaitingAttentionYieldsNothing() {
        let crew = MotherCrewState(
            attention: [MotherAttention(reason: .decisionAwaiting, since: "2026-10-17T09:00:00Z")])
        XCTAssertTrue(items([job("j1", state: "running", crew: crew)]).isEmpty)
    }

    func testJobsNotAwaitingAndWithNoAttentionYieldNothing() {
        let jobs = ["queued", "running", "succeeded", "failed", "cancelled"].map { job("j-\($0)", state: $0) }
        XCTAssertTrue(items(jobs).isEmpty)
    }

    // MARK: - Mother producer: attention flags

    func testAStalledBurningIncompleteRunningJobYieldsThreeItems() {
        let crew = MotherCrewState(attention: [
            MotherAttention(reason: .progressStalled, since: "2026-10-17T10:00:00Z"),
            MotherAttention(reason: .burnAhead, since: "2026-10-17T10:05:00Z"),
            MotherAttention(reason: .gatesIncomplete, since: "2026-10-17T10:10:00Z"),
        ])
        let out = items([job("j1", state: "running", crew: crew)])

        XCTAssertEqual(Set(out.map(\.id)), ["mother:j1:progress_stalled", "mother:j1:burn_ahead", "mother:j1:gates_incomplete"])
        XCTAssertEqual(out.count, 3)
        for entry in out { XCTAssertEqual(entry.source, .motherJob("j1")) }
        let byId = Dictionary(uniqueKeysWithValues: out.map { ($0.id, $0) })
        XCTAssertEqual(byId["mother:j1:progress_stalled"]?.reason, .motherAttention(.progressStalled))
        XCTAssertEqual(byId["mother:j1:burn_ahead"]?.reason, .motherAttention(.burnAhead))
        XCTAssertEqual(byId["mother:j1:gates_incomplete"]?.reason, .motherAttention(.gatesIncomplete))
    }

    func testAckedAttentionIsExcluded() {
        let crew = MotherCrewState(attention: [
            MotherAttention(reason: .progressStalled, since: "2026-10-17T10:00:00Z", acked: true),
            MotherAttention(reason: .burnAhead, since: "2026-10-17T10:05:00Z", acked: false),
        ])
        let out = items([job("j1", state: "running", crew: crew)])
        XCTAssertEqual(out.map(\.id), ["mother:j1:burn_ahead"])
    }

    func testAttentionOfATerminalJobIsExcluded() {
        let crew = MotherCrewState(attention: [
            MotherAttention(reason: .progressStalled, since: "2026-10-17T10:00:00Z"),
            MotherAttention(reason: .gatesIncomplete, since: "2026-10-17T10:00:00Z"),
        ])
        for state in ["succeeded", "failed", "cancelled"] {
            XCTAssertTrue(items([job("j-\(state)", state: state, crew: crew)]).isEmpty, state)
        }
    }

    func testAnUnknownEmptyReasonIsNotAnItem() {
        let crew = MotherCrewState(attention: [MotherAttention(reason: .unknown(""), since: nil)])
        XCTAssertTrue(items([job("j1", state: "running", crew: crew)]).isEmpty)
    }

    func testAnAwaitingJobWithAFlagYieldsTheAwaitItemAndTheFlag() {
        let crew = MotherCrewState(attention: [
            MotherAttention(reason: .decisionAwaiting, since: "2026-10-17T10:00:00Z"),
            MotherAttention(reason: .progressStalled, since: "2026-10-17T10:05:00Z"),
        ])
        let out = items([job("j1", state: "awaiting", crew: crew)])
        XCTAssertEqual(Set(out.map(\.id)), ["mother:j1:await", "mother:j1:progress_stalled"])
    }

    func testAttentionSinceParsesWithAndWithoutFractionalSeconds() {
        let crew = MotherCrewState(attention: [
            MotherAttention(reason: .progressStalled, since: "2026-10-17T10:00:00.250Z"),
            MotherAttention(reason: .burnAhead, since: "2026-10-17T10:05:00Z"),
            MotherAttention(reason: .gatesIncomplete, since: nil),
        ])
        let byId = Dictionary(uniqueKeysWithValues: items([job("j1", state: "running", crew: crew)]).map { ($0.id, $0) })
        XCTAssertEqual(byId["mother:j1:progress_stalled"]?.since, date("2026-10-17T10:00:00.250Z"))
        XCTAssertEqual(byId["mother:j1:burn_ahead"]?.since, date("2026-10-17T10:05:00Z"))
        XCTAssertNil(byId["mother:j1:gates_incomplete"]?.since)
    }

    // MARK: - Mother producer: sensitivity

    func testEveryItemOfAWorkSendJobIsSensitive() {
        let crew = MotherCrewState(attention: [MotherAttention(reason: .progressStalled, since: nil)])
        let out = items([job("j1", state: "awaiting", originLabel: "teri-send", crew: crew)])
        XCTAssertEqual(out.count, 2)
        XCTAssertTrue(out.allSatisfy(\.sensitive), "\(out)")
    }

    func testAJobFromAnyOtherOriginIsNotSensitive() {
        let crew = MotherCrewState(attention: [MotherAttention(reason: .progressStalled, since: nil)])
        let labels: [String?] = [nil, "cli", "teri-plan"]
        for label in labels {
            let out = items([job("j1", state: "awaiting", originLabel: label, crew: crew)])
            XCTAssertEqual(out.count, 2)
            XCTAssertTrue(out.allSatisfy { !$0.sensitive }, "\(String(describing: label))")
        }
    }

    // MARK: - Kit MotherJob origin

    func testTheJobDecodesItsOriginLabelFromTheNestedOrigin() throws {
        let json = #"{"id":"j","state":"awaiting","title":"t","origin":{"label":"teri-send"}}"#
        let decoded = try JSONDecoder().decode(MotherJob.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.originLabel, "teri-send")
    }

    func testAJobWithNoOriginHasNoOriginLabel() throws {
        let json = #"{"id":"j","state":"awaiting","title":"t"}"#
        let decoded = try JSONDecoder().decode(MotherJob.self, from: Data(json.utf8))
        XCTAssertNil(decoded.originLabel)
    }

    // MARK: - Decision producer

    func testDecisionProducerYieldsOneItemPerTagSortedByTag() {
        let out = DecisionNeedsYouProducer.items(attentionTags: ["b", "a"])
        XCTAssertEqual(out.map(\.id), ["decisions:a", "decisions:b"])
        XCTAssertEqual(out.map(\.source), [.focus("a"), .focus("b")])
        XCTAssertEqual(out.map(\.reason), [.decisionOpen, .decisionOpen])
        XCTAssertTrue(out.allSatisfy { !$0.sensitive })
    }

    func testDecisionProducerWithNoTagsYieldsNothing() {
        XCTAssertTrue(DecisionNeedsYouProducer.items(attentionTags: []).isEmpty)
    }

    func testProducerNames() {
        XCTAssertEqual(MotherNeedsYouProducer.name, "mother")
        XCTAssertEqual(DecisionNeedsYouProducer.name, "decisions")
    }
}
