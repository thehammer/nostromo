// NostromoKit — MotherCrewPanelModelTests.swift
//
// What the Mother panel shows for one job (MC2), as a pure value: the progress line, the gate
// and lens rows, the hold summary, attention badges, the breakdown and the panel's height.
//
// The height tests are the no-layout-churn contract: a value changing inside the same rows
// (a gate going running -> passed, the percentage moving) must not change the height, and a
// row appearing changes it by exactly one row. The Mac hosts the panel at a height computed
// from this model, so a surprise here is a visible jump there.
//
// Jobs come from the vendored contract fixtures in `tests/fixtures/mother-contract/`.

import XCTest
@testable import NostromoKit

final class MotherCrewPanelModelTests: XCTestCase {

    // MARK: - Fixture access

    private static let contractDir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // NostromoKitTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // NostromoKit
        .deletingLastPathComponent()   // Shared
        .deletingLastPathComponent()   // <repo>
        .appendingPathComponent("tests/fixtures/mother-contract")

    /// The snapshot job `id` from `<name>.ndjson`.
    private func fixtureJob(_ name: String, _ id: String) throws -> MotherJob {
        let text = try String(contentsOf: Self.contractDir.appendingPathComponent("\(name).ndjson"), encoding: .utf8)
        for line in text.split(separator: "\n") {
            guard let event = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  event["t"] as? String == "snapshot",
                  let data = event["data"] as? [String: Any],
                  let jobs = data["jobs"] as? [[String: Any]],
                  let raw = jobs.first(where: { $0["id"] as? String == id })
            else { continue }
            return try JSONDecoder().decode(MotherJob.self, from: JSONSerialization.data(withJSONObject: raw))
        }
        throw FixtureJobMissing(name: name, id: id)
    }

    private struct FixtureJobMissing: Error, CustomStringConvertible {
        let name: String
        let id: String
        var description: String { "job \(id) not found in \(name).ndjson" }
    }

    private func gatesJob() throws -> MotherJob { try fixtureJob("gates_fix_pass", "j-gates1") }
    private func waveJob() throws -> MotherJob { try fixtureJob("lens_wave", "j-wave1") }
    private func holdJob() throws -> MotherJob { try fixtureJob("gate_hold_answered", "j-hold1") }

    /// `job` with its crew state rewritten.
    private func with(_ job: MotherJob, _ edit: (inout MotherCrewState) -> Void) -> MotherJob {
        var crew = job.crew
        edit(&crew)
        return MotherJob(id: job.id, state: job.state, title: job.title, repo: job.repo,
                         question: job.question, crew: crew)
    }

    private func gate(_ name: String, _ result: MotherGateResult, durationS: Int? = nil, exitCode: Int? = nil) -> MotherGateResultEntry {
        MotherGateResultEntry(name: name, result: result, blocking: true, durationS: durationS, exitCode: exitCode)
    }

    private func row(_ id: String, in rows: [MotherCrewRow], file: StaticString = #filePath, line: UInt = #line) throws -> MotherCrewRow {
        try XCTUnwrap(rows.first { $0.id == id }, "no row \(id) in \(rows.map(\.id))", file: file, line: line)
    }

    private func allRows(_ model: MotherCrewPanelModel) -> [MotherCrewRow] {
        model.gates + model.lenses + (model.progress?.breakdown ?? [])
    }

    // MARK: - Progress line

    func testGatesJobShowsTheProgressLineWithMothersEtaBand() throws {
        let job = try gatesJob()
        let model = MotherCrewPanelModel.make(job: job)

        XCTAssertEqual(model.progress?.line, "≈55% · ETA ~5-15 min")
        // The same text the list rows use.
        XCTAssertEqual(MotherProgressLine.make(progress: job.crew.progress, gates: job.crew.gates)?.text,
                       "≈55% · ETA ~5-15 min")
        XCTAssertFalse(try XCTUnwrap(model.progress).accessibility.isEmpty)
    }

    func testJobWithoutCrewDataIsAnEmptyModelWithNoHeight() {
        let model = MotherCrewPanelModel.make(job: MotherJob(id: "plain", state: "running", title: "Plain"))
        XCTAssertTrue(model.isEmpty)
        XCTAssertEqual(model.height(breakdownExpanded: false), 0)
        XCTAssertEqual(model.height(breakdownExpanded: true), 0)
        XCTAssertFalse(model.hasDetails)
    }

    // MARK: - Gates

    func testGateRowsShowEachGatesResultWordAndTheAttempt() throws {
        let job = with(try gatesJob()) {
            $0.gates?.results = [self.gate("lint", .passed, durationS: 42), self.gate("unit", .failed, durationS: 188, exitCode: 1)]
        }
        let rows = MotherCrewPanelModel.make(job: job).gates

        XCTAssertEqual(rows.map(\.id), ["gates:header", "gate:lint", "gate:unit"])
        XCTAssertEqual(rows[0].title, "gates 1/3")
        XCTAssertEqual(rows[0].detail, "running")
        XCTAssertTrue(rows[1].detail.contains("passed"), rows[1].detail)
        XCTAssertTrue(rows[2].detail.contains("failed"), rows[2].detail)
        XCTAssertTrue(rows[2].detail.contains("exit 1"), rows[2].detail)
        // A glyph and a word, never a glyph alone.
        XCTAssertFalse(rows[1].glyph.isEmpty)
        XCTAssertNotEqual(rows[1].glyph, rows[2].glyph)
    }

    func testGatesThatDidNotRunAreNamedAndNeverCountedAsPassed() throws {
        let job = with(try gatesJob()) {
            $0.gates?.status = "incomplete"
            $0.gates?.results = [self.gate("lint", .passed)]
            $0.gates?.notRun = ["static", "unit"]
        }
        let model = MotherCrewPanelModel.make(job: job)

        let note = try row("gates:incomplete", in: model.gates)
        XCTAssertEqual(note.title, "Gates incomplete: static, unit")
        XCTAssertTrue(note.accessibility.contains("not counted as passed"), note.accessibility)
    }

    // MARK: - Review wave

    func testLensWaveShowsASkippedLensWithItsReasonAndClaimsAsCitationsNotCorrectness() throws {
        let model = MotherCrewPanelModel.make(job: try waveJob())

        XCTAssertEqual(model.lenses.first?.id, "lenses:header")
        XCTAssertEqual(model.lenses.first?.title, "Review wave cycle 1/2 · running")

        let ops = try row("lens:perri:ops-infra", in: model.lenses)
        XCTAssertTrue(ops.detail.contains("skipped"), ops.detail)
        XCTAssertTrue(ops.detail.contains("not in scope"), ops.detail)

        let pending = try row("lens:perri:correctness", in: model.lenses)
        XCTAssertTrue(pending.detail.contains("pending"), pending.detail)

        let claims = try row("lenses:claims", in: model.lenses)
        XCTAssertTrue(claims.title.contains("citations found"), claims.title)
        XCTAssertFalse(claims.title.lowercased().contains("verified correct"), claims.title)
        XCTAssertFalse(claims.accessibility.lowercased().contains("verified correct"), claims.accessibility)
    }

    // MARK: - Hold

    func testGateHoldShowsMothersFourOptionsWithTheirConsequences() throws {
        let job = try holdJob()
        let model = MotherCrewPanelModel.make(job: job)

        let hold = try XCTUnwrap(model.hold)
        XCTAssertEqual(hold.kind, "Gates exhausted")
        XCTAssertEqual(hold.options.map(\.id), [.resumeWithGuidance, .escalate, .overrideOpen, .cancel])
        XCTAssertEqual(hold.options.map(\.label), ["Resume with guidance", "Escalate", "Override and open", "Cancel"])
        XCTAssertEqual(hold.options.count, 4)
        for option in hold.options {
            XCTAssertFalse(option.consequence.isEmpty, option.label)
            XCTAssertTrue(option.accessibility.contains(option.consequence), option.accessibility)
        }
        XCTAssertEqual(hold.options.map(\.takesText), [true, false, false, false])
        XCTAssertEqual(hold.question, job.question)
    }

    func testAJobThatIsNotHeldHasNoHold() throws {
        XCTAssertNil(MotherCrewPanelModel.make(job: try gatesJob()).hold)
        XCTAssertNil(MotherCrewPanelModel.make(job: try waveJob()).hold)
    }

    // MARK: - Attention

    func testAttentionBadgesAreOrderedAcknowledgedOnesStayAndAreMarked() throws {
        let job = with(try gatesJob()) {
            $0.attention = [
                MotherAttention(reason: .burnAhead),
                MotherAttention(reason: .progressStalled, acked: true),
                MotherAttention(reason: .decisionAwaiting),
            ]
        }
        let badges = MotherCrewPanelModel.make(job: job).badges

        XCTAssertEqual(badges.map(\.label), ["Needs decision", "Stalled", "Burning ahead"])
        XCTAssertEqual(badges.map(\.acked), [false, true, false])
        XCTAssertTrue(badges[1].accessibility.contains("acknowledged"), badges[1].accessibility)
        XCTAssertFalse(badges[0].accessibility.contains("acknowledged"))
    }

    func testTheHoldJobCarriesTheNeedsDecisionBadge() throws {
        let badges = MotherCrewPanelModel.make(job: try holdJob()).badges
        XCTAssertEqual(badges.map(\.label), ["Needs decision"])
    }

    // MARK: - Breakdown

    private func jobWithFullProgress(etaBasis: String?) throws -> MotherJob {
        with(try gatesJob()) {
            $0.progress?.signals?.gates = MotherGateSignal(passed: 1, failed: 1, total: 3)
            if let etaBasis {
                $0.progress?.eta?.basis = etaBasis
            } else {
                $0.progress?.eta = nil
            }
        }
    }

    func testBreakdownListsStageGatesActiveTimeAndCostThenTheEtaBasis() throws {
        let model = MotherCrewPanelModel.make(job: try jobWithFullProgress(etaBasis: "fleet"))
        let rows = try XCTUnwrap(model.progress).breakdown

        XCTAssertEqual(rows.map(\.title), ["Stage", "Gates", "Active time", "Cost so far", "ETA basis"])
        XCTAssertEqual(rows[0].detail, "implement")
        XCTAssertEqual(rows[1].detail, "1 passed, 1 failed, of 3")
        XCTAssertEqual(rows[2].detail, "7m 00s")
        XCTAssertEqual(rows[3].detail, "$1.12")
    }

    func testEtaBasisIsSaidInPlainWords() throws {
        func basisText(_ basis: String?) throws -> String {
            let rows = try XCTUnwrap(MotherCrewPanelModel.make(job: try jobWithFullProgress(etaBasis: basis)).progress).breakdown
            return try row("progress:eta", in: rows).detail
        }
        XCTAssertEqual(try basisText("repo"), "from this repo's history")
        XCTAssertEqual(try basisText("fleet"), "from all repos")
        XCTAssertEqual(try basisText("none"), "not enough history")
        XCTAssertEqual(try basisText(nil), "not enough history")
        // The row is always the last one, so it never moves the others.
        let rows = try XCTUnwrap(MotherCrewPanelModel.make(job: try jobWithFullProgress(etaBasis: "repo")).progress).breakdown
        XCTAssertEqual(rows.last?.title, "ETA basis")
    }

    // MARK: - Height (no layout churn)

    /// Built from rows, so the expected height is arithmetic on the metrics and nothing else.
    private func knownModel() -> (model: MotherCrewPanelModel, expected: CGFloat, breakdownCount: Int) {
        func item(_ id: String) -> MotherCrewRow {
            MotherCrewRow(id: id, kind: .item, glyph: "·", title: id, detail: "d", accessibility: id)
        }
        let breakdown = [item("b1"), item("b2"), item("b3")]
        let option = { (id: MotherDecisionOptionID, consequence: String) in
            MotherHoldSummary.Option(id: id, label: id.raw, consequence: consequence, takesText: false, accessibility: id.raw)
        }
        let hold = MotherHoldSummary(
            kind: "Gates exhausted", question: nil,
            options: [option(.escalate, "Re-run one tier up."), option(.cancel, "")],
            accessibility: "Gates exhausted. 2 options."
        )
        let model = MotherCrewPanelModel(
            progress: MotherCrewPanelModel.Progress(line: "≈10%", accessibility: "10 percent", breakdown: breakdown),
            gates: [item("g1"), item("g2"), item("g3")],
            lenses: [item("l1"), item("l2")],
            badges: [MotherAttentionBadge(reason: .decisionAwaiting, label: "Needs decision", acked: false, accessibility: "Needs decision")],
            hold: hold,
            hasDetails: true
        )
        let row = MotherCrewPanelMetrics.row
        let sections: [CGFloat] = [
            row * 1,                                            // progress line (breakdown collapsed)
            row * 3,                                            // gates
            row * 2,                                            // lenses
            row * 1,                                            // badges share one row
            row * 3 + MotherCrewPanelMetrics.consequence * 1,   // hold: title + 2 options, one consequence
        ]
        let expected = sections.reduce(0, +) + MotherCrewPanelMetrics.gap * CGFloat(sections.count - 1)
        return (model, expected, breakdown.count)
    }

    func testHeightIsTheSumOfRowAndGapMetrics() {
        let known = knownModel()
        XCTAssertEqual(known.model.height(breakdownExpanded: false), known.expected)
    }

    func testExpandingTheBreakdownAddsExactlyOneRowPerBreakdownEntry() {
        let known = knownModel()
        XCTAssertEqual(known.model.height(breakdownExpanded: true) - known.model.height(breakdownExpanded: false),
                       CGFloat(known.breakdownCount) * MotherCrewPanelMetrics.row)
    }

    func testAGateChangingItsResultWordKeepsTheHeight() throws {
        func height(_ result: MotherGateResult) throws -> CGFloat {
            let job = with(try gatesJob()) {
                $0.gates?.results = [self.gate("lint", .passed, durationS: 42), self.gate("unit", result, durationS: 10)]
            }
            return MotherCrewPanelModel.make(job: job).height(breakdownExpanded: false)
        }
        let running = try height(.unknown("running"))
        XCTAssertEqual(try height(.passed), running)
        XCTAssertEqual(try height(.failed), running)
        XCTAssertEqual(try height(.skipped), running)
    }

    func testProgressMovingKeepsTheHeightAndANewGateRowAddsExactlyOneRow() throws {
        func model(pct: Int, etaLabel: String, gates: [MotherGateResultEntry]) throws -> MotherCrewPanelModel {
            MotherCrewPanelModel.make(job: with(try gatesJob()) {
                $0.progress?.pct = pct
                $0.progress?.eta?.label = etaLabel
                $0.gates?.results = gates
            })
        }
        let two = [gate("lint", .passed), gate("unit", .passed)]
        let base = try model(pct: 10, etaLabel: "5-15 min", gates: two)
        let moved = try model(pct: 99, etaLabel: "under 2 min", gates: two)
        XCTAssertEqual(moved.height(breakdownExpanded: false), base.height(breakdownExpanded: false))
        XCTAssertEqual(moved.height(breakdownExpanded: true), base.height(breakdownExpanded: true))

        let three = try model(pct: 10, etaLabel: "5-15 min", gates: two + [gate("static", .passed)])
        XCTAssertEqual(three.height(breakdownExpanded: false) - base.height(breakdownExpanded: false),
                       MotherCrewPanelMetrics.row)
    }

    func testTheFirstCrewDataTakesTheHeightFromZeroToTheModelsHeight() throws {
        let empty = MotherCrewPanelModel.make(job: MotherJob(id: "j", state: "running", title: "T"))
        let first = MotherCrewPanelModel.make(job: try gatesJob())
        XCTAssertEqual(empty.height(breakdownExpanded: false), 0)
        XCTAssertGreaterThan(first.height(breakdownExpanded: false), 0)
    }

    // MARK: - Accessibility (every row reads as one VoiceOver element)

    func testEveryRowOfEveryFixtureModelHasAnAccessibilityString() throws {
        var jobs = [try gatesJob(), try waveJob(), try holdJob(), try jobWithFullProgress(etaBasis: "repo")]
        jobs.append(with(try gatesJob()) {
            $0.gates?.status = "incomplete"
            $0.gates?.results = [self.gate("lint", .unknown("weird")), self.gate("unit", .failed, exitCode: 2), self.gate("e2e", .unavailable)]
            $0.gates?.notRun = ["static"]
        })
        for job in jobs {
            let model = MotherCrewPanelModel.make(job: job)
            let rows = allRows(model)
            XCTAssertFalse(rows.isEmpty, job.id)
            for r in rows {
                XCTAssertFalse(r.accessibility.isEmpty, "\(job.id): row \(r.id) has no accessibility text")
            }
            if let progress = model.progress { XCTAssertFalse(progress.accessibility.isEmpty, job.id) }
            for badge in model.badges { XCTAssertFalse(badge.accessibility.isEmpty, job.id) }
            if let hold = model.hold {
                XCTAssertFalse(hold.accessibility.isEmpty, job.id)
                for option in hold.options { XCTAssertFalse(option.accessibility.isEmpty, job.id) }
            }
        }
    }

    // MARK: - Job row (MC2-6)

    func testARowReservesItsProgressLineOnlyWhenTheHostDrawsItAndTheJobIsActive() {
        for state in ["running", "awaiting", "queued", "ready", "succeeded", "failed", "cancelled"] {
            let off = MotherJobRowModel(id: "j", state: state, title: "T")
            XCTAssertFalse(off.reservesProgressLine, "default model, state \(state)")

            let on = MotherJobRowModel(id: "j", state: state, title: "T", showsProgressLine: true)
            XCTAssertEqual(on.reservesProgressLine, state == "running" || state == "awaiting", "showsProgressLine, state \(state)")
        }
    }
}
