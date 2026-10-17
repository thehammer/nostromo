// NostromoKit — MotherCrewWireTests.swift
//
// Mother's headless-crew contract as the shared Kit decodes it (MC1).
//
// The NDJSON fixtures in `tests/fixtures/mother-contract/` are byte-exact copies
// of Mother's published contract; the two `ipc_mother_jobs*.golden.json` files
// are the daemon's own `MotherJobs` frames (written by Rust tests). Every
// snapshot job must decode with the same concrete values the Rust fixture test
// asserts, and every `progress_updated` event as a `MotherProgress`.
//
// Leniency is per TOP-LEVEL job key (locked bet B2): a malformed `gates` (or
// `review_wave`, `progress`, ...) costs that key only; the job and every other
// key survive and `decodeIssues` names the key (never a value). Unknown enum
// values survive as `.unknown(raw)`.

import XCTest
@testable import NostromoKit

final class MotherCrewWireTests: XCTestCase {

    // MARK: - Fixture access

    /// `<repo>/tests/fixtures/mother-contract`, found from this file's location
    /// (`<repo>/Shared/NostromoKit/Tests/NostromoKitTests/`), the same
    /// `#filePath` pattern `FocusGroupingTests` uses.
    private static let contractDir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // NostromoKitTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // NostromoKit
        .deletingLastPathComponent()   // Shared
        .deletingLastPathComponent()   // <repo>
        .appendingPathComponent("tests/fixtures/mother-contract")

    private static let fixtureNames = ["gates_fix_pass", "lens_wave", "gate_hold_answered"]

    private func readFixture(_ file: String) throws -> Data {
        try Data(contentsOf: Self.contractDir.appendingPathComponent(file))
    }

    /// Every NDJSON line of `<name>.ndjson` as a JSON object.
    private func events(_ name: String) throws -> [[String: Any]] {
        let text = try String(contentsOf: Self.contractDir.appendingPathComponent("\(name).ndjson"), encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], "bad NDJSON line in \(name)")
        }
    }

    /// The raw job objects of every `snapshot` event in `name`, in file order.
    private func snapshotJobObjects(_ name: String) throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        for event in try events(name) where event["t"] as? String == "snapshot" {
            let data = try XCTUnwrap(event["data"] as? [String: Any])
            out += try XCTUnwrap(data["jobs"] as? [[String: Any]])
        }
        return out
    }

    private func decodeJobs(_ objects: [[String: Any]]) throws -> [MotherJob] {
        let data = try JSONSerialization.data(withJSONObject: objects)
        return try JSONDecoder().decode([MotherJob].self, from: data)
    }

    private func decodeJob(_ object: [String: Any]) throws -> MotherJob {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(MotherJob.self, from: data)
    }

    private func snapshotJobs(_ name: String) throws -> [MotherJob] {
        let objects = try snapshotJobObjects(name)
        XCTAssertFalse(objects.isEmpty, "\(name) has no snapshot job")
        let jobs = try decodeJobs(objects)
        XCTAssertEqual(jobs.count, objects.count)
        return jobs
    }

    private func job(_ id: String, in jobs: [MotherJob], file: StaticString = #filePath, line: UInt = #line) throws -> MotherJob {
        try XCTUnwrap(jobs.first { $0.id == id }, "\(id) not decoded", file: file, line: line)
    }

    private func jobObject(_ name: String, _ id: String) throws -> [String: Any] {
        try XCTUnwrap(try snapshotJobObjects(name).first { $0["id"] as? String == id }, "\(id) not in \(name)")
    }

    // MARK: - The contract's concrete values (shared by fixtures and goldens)

    private func assertGatesJob(_ jobs: [MotherJob], file: StaticString = #filePath, line: UInt = #line) throws {
        let j = try job("j-gates1", in: jobs, file: file, line: line)
        XCTAssertEqual(j.state, "running", file: file, line: line)
        XCTAssertEqual(j.crew.activity, "gating", file: file, line: line)
        XCTAssertTrue(j.crew.optedIn, file: file, line: line)
        XCTAssertEqual(j.crew.prUrl, "https://github.com/Carefeed/admin-portal/pull/4321", file: file, line: line)
        let gates = try XCTUnwrap(j.crew.gates, file: file, line: line)
        XCTAssertEqual(gates.attempt, 1, file: file, line: line)
        XCTAssertEqual(gates.maxAttempts, 3, file: file, line: line)
        XCTAssertEqual(gates.status, "running", file: file, line: line)
        XCTAssertEqual(gates.mode, "enforce", file: file, line: line)
        XCTAssertTrue(gates.results.isEmpty, file: file, line: line)
        XCTAssertFalse(gates.overridden, file: file, line: line)
        let progress = try XCTUnwrap(j.crew.progress, file: file, line: line)
        XCTAssertEqual(progress.pct, 55, file: file, line: line)
        XCTAssertEqual(progress.label, "Implementing", file: file, line: line)
        XCTAssertFalse(progress.paused, file: file, line: line)
        XCTAssertEqual(progress.eta?.basis, "fleet", file: file, line: line)
        XCTAssertEqual(progress.eta?.label, "5-15 min", file: file, line: line)
        XCTAssertEqual(progress.eta?.loS, 300, file: file, line: line)
        XCTAssertEqual(progress.eta?.hiS, 900, file: file, line: line)
        XCTAssertNil(j.crew.reviewWave, file: file, line: line)
        XCTAssertNil(j.crew.decision, file: file, line: line)
        XCTAssertEqual(j.crew.decodeIssues, [], file: file, line: line)
    }

    private func assertWaveJob(_ jobs: [MotherJob], file: StaticString = #filePath, line: UInt = #line) throws {
        let j = try job("j-wave1", in: jobs, file: file, line: line)
        XCTAssertEqual(j.crew.activity, "review_wave", file: file, line: line)
        XCTAssertTrue(j.crew.optedIn, file: file, line: line)
        let wave = try XCTUnwrap(j.crew.reviewWave, file: file, line: line)
        XCTAssertEqual(wave.cycle, 1, file: file, line: line)
        XCTAssertEqual(wave.cycleCap, 2, file: file, line: line)
        XCTAssertEqual(wave.lenses.count, 4, file: file, line: line)
        XCTAssertEqual(
            wave.lenses.map(\.reviewer),
            ["archie:adherence", "perri:correctness", "perri:phi-security", "perri:ops-infra"],
            file: file, line: line
        )
        let ops = try XCTUnwrap(wave.lenses.first { $0.reviewer == "perri:ops-infra" }, file: file, line: line)
        XCTAssertEqual(ops.state, .skipped, file: file, line: line)
        XCTAssertEqual(ops.skipReason, "path_scope", file: file, line: line)
        let adherence = try XCTUnwrap(wave.lenses.first { $0.reviewer == "archie:adherence" }, file: file, line: line)
        XCTAssertEqual(adherence.lens, "adherence", file: file, line: line)
        XCTAssertEqual(adherence.state, .pending, file: file, line: line)
        XCTAssertEqual(wave.claims, MotherClaims(verified: 0, refuted: 0, unverified: 0), file: file, line: line)
        XCTAssertEqual(j.crew.decodeIssues, [], file: file, line: line)
    }

    private func assertHoldJob(_ jobs: [MotherJob], file: StaticString = #filePath, line: UInt = #line) throws {
        let j = try job("j-hold1", in: jobs, file: file, line: line)
        XCTAssertEqual(j.state, "awaiting", file: file, line: line)
        XCTAssertEqual(j.crew.activity, "gate_hold", file: file, line: line)
        XCTAssertTrue(j.crew.optedIn, file: file, line: line)
        let decision = try XCTUnwrap(j.crew.decision, file: file, line: line)
        XCTAssertEqual(decision.id, "d-0001", file: file, line: line)
        XCTAssertEqual(decision.kind, "gate_hold", file: file, line: line)
        XCTAssertTrue(decision.isOpen, file: file, line: line)
        XCTAssertEqual(
            decision.options.map(\.id),
            [.resumeWithGuidance, .escalate, .overrideOpen, .cancel],
            file: file, line: line
        )
        for option in decision.options {
            XCTAssertEqual(option.takesText, option.id == .resumeWithGuidance, "takesText on \(option.id.raw)", file: file, line: line)
            XCTAssertFalse(option.label.isEmpty, file: file, line: line)
            XCTAssertFalse(option.consequence.isEmpty, file: file, line: line)
        }
        XCTAssertEqual(j.crew.attention.map(\.reason), [.decisionAwaiting], file: file, line: line)
        XCTAssertEqual(j.crew.attention.map(\.acked), [false], file: file, line: line)
        let gates = try XCTUnwrap(j.crew.gates, file: file, line: line)
        XCTAssertEqual(gates.status, "exhausted", file: file, line: line)
        XCTAssertEqual(gates.attempt, 3, file: file, line: line)
        XCTAssertEqual(gates.results.count, 1, file: file, line: line)
        XCTAssertEqual(gates.results.first?.name, "unit", file: file, line: line)
        XCTAssertEqual(gates.results.first?.result, .failed, file: file, line: line)
        XCTAssertEqual(gates.results.first?.blocking, true, file: file, line: line)
        XCTAssertEqual(gates.results.first?.durationS, 201, file: file, line: line)
        XCTAssertEqual(gates.results.first?.exitCode, 1, file: file, line: line)
        XCTAssertEqual(j.crew.decodeIssues, [], file: file, line: line)
    }

    // MARK: - Vendored fixtures

    func testGatesFixPassSnapshotDecodesWithTheContractValues() throws {
        try assertGatesJob(try snapshotJobs("gates_fix_pass"))
    }

    func testLensWaveSnapshotDecodesWithTheContractValues() throws {
        try assertWaveJob(try snapshotJobs("lens_wave"))
    }

    func testGateHoldSnapshotDecodesWithTheContractValues() throws {
        try assertHoldJob(try snapshotJobs("gate_hold_answered"))
    }

    func testEveryProgressUpdatedEventDecodesAsMotherProgress() throws {
        var seen = 0
        for name in Self.fixtureNames {
            for event in try events(name) where event["t"] as? String == "progress_updated" {
                let data = try JSONSerialization.data(withJSONObject: try XCTUnwrap(event["data"]))
                // `job` and `category` ride along in the event's data and must be ignored.
                let progress = try JSONDecoder().decode(MotherProgress.self, from: data)
                XCTAssertNotNil(progress.pct, name)
                XCTAssertNotNil(progress.eta, name)
                XCTAssertNotNil(progress.signals, name)
                seen += 1
            }
        }
        XCTAssertEqual(seen, 4)
    }

    func testGatesFixPassProgressEventsCarryTheDocumentedPercentagesAndGateSignal() throws {
        let progress = try events("gates_fix_pass")
            .filter { $0["t"] as? String == "progress_updated" }
            .map { try JSONDecoder().decode(MotherProgress.self, from: JSONSerialization.data(withJSONObject: $0["data"] as Any)) }
        XCTAssertEqual(progress.map(\.pct), [70, 62, 90, 95])
        XCTAssertEqual(progress[0].signals?.gates, MotherGateSignal(passed: 1, failed: 1, total: 3))
        XCTAssertEqual(progress[0].label, "Checking")
        XCTAssertEqual(progress[3].eta?.label, "under 2 min")
    }

    // MARK: - Per-key leniency

    /// A job carrying every crew key, built from the three fixtures.
    private func kitchenSink() throws -> [String: Any] {
        var j = try jobObject("gate_hold_answered", "j-hold1")
        j["review_wave"] = try jobObject("lens_wave", "j-wave1")["review_wave"]
        j["progress"] = try jobObject("gates_fix_pass", "j-gates1")["progress"]
        j["last_answer"] = ["source": "nostromo_app", "session": "s-1", "agent": "cody",
                            "option": "resume_with_guidance", "at": "2026-10-17T11:00:00.000Z"]
        // Same single reason as the plain `attention`, so the merged `attention`
        // reads the same whichever of the two keys is the broken one.
        j["attention_reasons"] = [["reason": "decision_awaiting", "since": "2026-10-17T12:00:02.000Z", "acked": false]]
        j["criteria_source"] = "checklist"
        return j
    }

    /// Replace the value at `path` (dictionary keys and array indices) in `node`.
    private func setting(_ node: Any, _ path: ArraySlice<Any>, to value: Any) -> Any {
        guard let head = path.first else { return value }
        if let key = head as? String, var dict = node as? [String: Any] {
            dict[key] = setting(dict[key] ?? NSNull(), path.dropFirst(), to: value)
            return dict
        }
        if let index = head as? Int, var array = node as? [Any] {
            array[index] = setting(array[index], path.dropFirst(), to: value)
            return array
        }
        preconditionFailure("bad mutation path \(path) in \(node)")
    }

    private func mutated(_ object: [String: Any], _ path: [Any], to value: Any) -> [String: Any] {
        setting(object, path[...], to: value) as! [String: Any]  // swiftlint:disable:this force_cast
    }

    /// Each crew key by contract name, compared field by field (never via
    /// `decodeIssues`, which is expected to differ).
    private let crewFields: [(name: String, same: (MotherCrewState, MotherCrewState) -> Bool)] = [
        ("crew_opt_in", { $0.optedIn == $1.optedIn }),
        ("activity", { $0.activity == $1.activity }),
        ("pr_url", { $0.prUrl == $1.prUrl }),
        ("gates", { $0.gates == $1.gates }),
        ("review_wave", { $0.reviewWave == $1.reviewWave }),
        ("decision", { $0.decision == $1.decision }),
        ("attention", { $0.attention == $1.attention }),
        ("last_answer", { $0.lastAnswer == $1.lastAnswer }),
        ("progress", { $0.progress == $1.progress }),
        ("criteria_source", { $0.criteriaSource == $1.criteriaSource }),
    ]

    /// Assert `after` equals `before` on every crew field except `brokenField`
    /// (nil for "none broken"), and that the job-level keys are untouched.
    private func assertOtherKeysIntact(
        _ before: MotherJob, _ after: MotherJob, brokenField: String?,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for field in crewFields where field.name != brokenField {
            XCTAssertTrue(field.same(before.crew, after.crew), "`\(field.name)` must be untouched by a broken `\(brokenField ?? "-")`", file: file, line: line)
        }
        XCTAssertEqual(before.title, after.title, file: file, line: line)
        XCTAssertEqual(before.state, after.state, file: file, line: line)
        XCTAssertEqual(before.repo, after.repo, file: file, line: line)
        XCTAssertEqual(before.prUrl, after.prUrl, file: file, line: line)
        XCTAssertEqual(before.question, after.question, file: file, line: line)
        XCTAssertEqual(before.createdAt, after.createdAt, file: file, line: line)
    }

    func testAGatesStringCostsOnlyTheGatesKey() throws {
        let original = try kitchenSink()
        let before = try decodeJob(original)
        let after = try decodeJob(mutated(original, ["gates"], to: "SECRET-PAYLOAD-123"))

        XCTAssertNil(after.crew.gates)
        XCTAssertEqual(after.crew.decodeIssues, ["gates"])
        XCTAssertFalse(after.crew.decodeIssues.joined().contains("SECRET-PAYLOAD-123"))
        assertOtherKeysIntact(before, after, brokenField: "gates")
        XCTAssertNotNil(after.crew.decision, "the decision beside it survives")
    }

    func testReviewWaveLensesThatAreANumberCostOnlyTheReviewWaveKey() throws {
        let original = try jobObject("lens_wave", "j-wave1")
        let before = try decodeJob(original)
        let after = try decodeJob(mutated(original, ["review_wave", "lenses"], to: 7))

        XCTAssertNil(after.crew.reviewWave)
        XCTAssertEqual(after.crew.decodeIssues, ["review_wave"])
        assertOtherKeysIntact(before, after, brokenField: "review_wave")
        XCTAssertEqual(after.crew.activity, "review_wave")
    }

    func testProgressEtaThatIsAnEmptyArrayCostsOnlyTheProgressKey() throws {
        let original = try jobObject("gates_fix_pass", "j-gates1")
        let before = try decodeJob(original)
        let after = try decodeJob(mutated(original, ["progress", "eta"], to: [Any]()))

        XCTAssertNil(after.crew.progress)
        XCTAssertEqual(after.crew.decodeIssues, ["progress"])
        assertOtherKeysIntact(before, after, brokenField: "progress")
        XCTAssertEqual(after.crew.gates?.attempt, 1, "gates survive a broken progress overlay")
    }

    func testAnUnknownGateResultValueSurvivesAsUnknownWithoutAnIssue() throws {
        let original = try jobObject("gate_hold_answered", "j-hold1")
        let before = try decodeJob(original)
        let after = try decodeJob(mutated(original, ["gates", "results", 0, "result"], to: "flaky"))

        XCTAssertEqual(after.crew.gates?.results.first?.result, .unknown("flaky"))
        XCTAssertEqual(after.crew.gates?.results.first?.result.raw, "flaky")
        XCTAssertEqual(after.crew.gates?.results.first?.name, "unit")
        XCTAssertEqual(after.crew.decodeIssues, [])
        assertOtherKeysIntact(before, after, brokenField: "gates")
    }

    func testAnUnknownDecisionOptionIdSurvivesAsUnknownWithoutAnIssue() throws {
        let original = try jobObject("gate_hold_answered", "j-hold1")
        let before = try decodeJob(original)
        let after = try decodeJob(mutated(original, ["decision", "options", 1, "id"], to: "future_option"))

        XCTAssertEqual(
            after.crew.decision?.options.map(\.id),
            [.resumeWithGuidance, .unknown("future_option"), .overrideOpen, .cancel]
        )
        XCTAssertEqual(after.crew.decodeIssues, [])
        assertOtherKeysIntact(before, after, brokenField: "decision")
    }

    func testProgressFlagsDecodeFromObjectsAndIgnoreTheirExtraDetail() throws {
        let original = try jobObject("gates_fix_pass", "j-gates1")
        let flags: [[String: Any]] = [["reason": "burn_ahead", "since": "2026-10-17T12:00:00.000Z", "detail": "x"]]
        let after = try decodeJob(mutated(original, ["progress", "flags"], to: flags))

        XCTAssertEqual(after.crew.decodeIssues, [])
        let progress = try XCTUnwrap(after.crew.progress)
        XCTAssertEqual(progress.flags, [MotherProgressFlag(reason: "burn_ahead", since: "2026-10-17T12:00:00.000Z")])
        XCTAssertEqual(progress.pct, 55)
        assertOtherKeysIntact(try decodeJob(original), after, brokenField: "progress")
    }

    func testProgressFlagsDecodeFromPlainStrings() throws {
        let original = try jobObject("gates_fix_pass", "j-gates1")
        let after = try decodeJob(mutated(original, ["progress", "flags"], to: ["stalled"]))

        XCTAssertEqual(after.crew.decodeIssues, [])
        let progress = try XCTUnwrap(after.crew.progress)
        XCTAssertEqual(progress.flags, [MotherProgressFlag(reason: "stalled", since: nil)])
        XCTAssertEqual(progress.pct, 55)
        assertOtherKeysIntact(try decodeJob(original), after, brokenField: "progress")
    }

    func testEveryCrewKeyIsLenientOnItsOwn() throws {
        // (contract key, wrong-shaped value, poison hidden in it, field that must fall back to its default)
        let cases: [(key: String, bad: Any, poison: String, brokenField: String, isDefault: (MotherCrewState) -> Bool)] = [
            ("activity", ["x": "SECRET-PAYLOAD-K1"], "SECRET-PAYLOAD-K1", "activity", { $0.activity == nil }),
            ("pr_url", ["SECRET-PAYLOAD-K2"], "SECRET-PAYLOAD-K2", "pr_url", { $0.prUrl == nil }),
            ("gates", "SECRET-PAYLOAD-K3", "SECRET-PAYLOAD-K3", "gates", { $0.gates == nil }),
            ("review_wave", ["SECRET-PAYLOAD-K4"], "SECRET-PAYLOAD-K4", "review_wave", { $0.reviewWave == nil }),
            ("decision", "SECRET-PAYLOAD-K5", "SECRET-PAYLOAD-K5", "decision", { $0.decision == nil }),
            ("last_answer", "SECRET-PAYLOAD-K8", "SECRET-PAYLOAD-K8", "last_answer", { $0.lastAnswer == nil }),
            ("progress", ["SECRET-PAYLOAD-K9"], "SECRET-PAYLOAD-K9", "progress", { $0.progress == nil }),
            ("criteria_source", ["SECRET-PAYLOAD-K10"], "SECRET-PAYLOAD-K10", "criteria_source", { $0.criteriaSource == nil }),
        ]
        let original = try kitchenSink()
        let before = try decodeJob(original)
        for field in crewFields {
            XCTAssertTrue(field.name == "crew_opt_in" || !isEmpty(before.crew, field.name), "the kitchen-sink job must populate `\(field.name)`")
        }
        for c in cases {
            let after = try decodeJob(mutated(original, [c.key], to: c.bad))
            XCTAssertTrue(c.isDefault(after.crew), "`\(c.key)` must fall back to its default")
            XCTAssertEqual(after.crew.decodeIssues, [c.key])
            XCTAssertFalse(after.crew.decodeIssues.joined().contains(c.poison))
            assertOtherKeysIntact(before, after, brokenField: c.brokenField)
        }
    }

    func testABrokenAttentionKeyNeverHidesTheOtherAttentionKey() throws {
        let original = try kitchenSink()
        let before = try decodeJob(original)

        let derivedBroken = try decodeJob(mutated(original, ["attention_reasons"], to: "SECRET-PAYLOAD-A1"))
        XCTAssertEqual(derivedBroken.crew.decodeIssues, ["attention_reasons"])
        XCTAssertEqual(derivedBroken.crew.attention.map(\.reason), [.decisionAwaiting], "falls back to plain `attention`")
        assertOtherKeysIntact(before, derivedBroken, brokenField: nil)

        let plainBroken = try decodeJob(mutated(original, ["attention"], to: "SECRET-PAYLOAD-A2"))
        XCTAssertEqual(plainBroken.crew.decodeIssues, ["attention"])
        XCTAssertEqual(plainBroken.crew.attention.map(\.reason), [.decisionAwaiting], "keeps `attention_reasons`")
        assertOtherKeysIntact(before, plainBroken, brokenField: nil)

        var both = original
        both["attention"] = "x"
        both["attention_reasons"] = "y"
        let bothBroken = try decodeJob(both)
        XCTAssertEqual(Set(bothBroken.crew.decodeIssues), ["attention", "attention_reasons"])
        XCTAssertEqual(bothBroken.crew.attention, [])
        XCTAssertEqual(bothBroken.id, "j-hold1")
    }

    private func isEmpty(_ crew: MotherCrewState, _ field: String) -> Bool {
        switch field {
        case "activity": return crew.activity == nil
        case "pr_url": return crew.prUrl == nil
        case "gates": return crew.gates == nil
        case "review_wave": return crew.reviewWave == nil
        case "decision": return crew.decision == nil
        case "attention": return crew.attention.isEmpty
        case "last_answer": return crew.lastAnswer == nil
        case "progress": return crew.progress == nil
        case "criteria_source": return crew.criteriaSource == nil
        default: return false
        }
    }

    func testUnknownEnumLikeValuesSurviveAsUnknownWithoutIssues() throws {
        var j = try kitchenSink()
        j = mutated(j, ["review_wave", "lenses", 0, "state"], to: "teleporting")
        j = mutated(j, ["gates", "results", 0, "result"], to: "flaky")
        j["attention"] = [["reason": "future_reason", "since": "2026-10-17T12:00:02.000Z"]]
        j["attention_reasons"] = [Any]()
        j["activity"] = "future_activity"
        let job = try decodeJob(j)

        XCTAssertEqual(job.crew.decodeIssues, [])
        XCTAssertEqual(job.crew.activity, "future_activity")
        XCTAssertEqual(job.crew.reviewWave?.lenses.first?.state, .unknown("teleporting"))
        XCTAssertEqual(job.crew.reviewWave?.lenses.first?.state.raw, "teleporting")
        XCTAssertEqual(job.crew.gates?.results.first?.result, .unknown("flaky"))
        XCTAssertEqual(job.crew.attention.map(\.reason), [.unknown("future_reason")])
        XCTAssertEqual(job.crew.attention.first?.reason.raw, "future_reason")
    }

    func testKnownEnumValuesRoundTripTheirRawStrings() {
        XCTAssertEqual(MotherGateResult("passed"), .passed)
        XCTAssertEqual(MotherGateResult("unavailable"), .unavailable)
        XCTAssertEqual(MotherGateResult.failed.raw, "failed")
        XCTAssertEqual(MotherLensState("running"), .running)
        XCTAssertEqual(MotherLensState.error.raw, "error")
        XCTAssertEqual(MotherDecisionOptionID("override_open"), .overrideOpen)
        XCTAssertEqual(MotherDecisionOptionID.resumeWithGuidance.raw, "resume_with_guidance")
        XCTAssertEqual(MotherAttentionReason("progress_stalled"), .progressStalled)
        XCTAssertEqual(MotherAttentionReason("burn_ahead"), .burnAhead)
        XCTAssertEqual(MotherAttentionReason("gates_incomplete"), .gatesIncomplete)
        XCTAssertEqual(MotherAttentionReason.decisionAwaiting.raw, "decision_awaiting")
        XCTAssertEqual(MotherGateResult("nonsense"), .unknown("nonsense"))
    }

    // MARK: - Attention and opt-in

    func testAttentionReasonsArePreferredOverAttentionAndCarryAcked() throws {
        var j = try jobObject("gate_hold_answered", "j-hold1")
        j["attention_reasons"] = [
            ["reason": "progress_stalled", "since": "2026-10-17T12:00:00.000Z", "acked": false],
            ["reason": "burn_ahead", "since": "2026-10-17T12:00:00.000Z", "acked": true],
        ]
        let job = try decodeJob(j)
        XCTAssertEqual(job.crew.attention.map(\.reason), [.progressStalled, .burnAhead])
        XCTAssertEqual(job.crew.attention.map(\.acked), [false, true])
        XCTAssertEqual(job.crew.decodeIssues, [])
    }

    func testAnEmptyAttentionReasonsListFallsBackToAttentionWithAckedFalse() throws {
        var j = try jobObject("gate_hold_answered", "j-hold1")
        j["attention_reasons"] = [Any]()
        let job = try decodeJob(j)
        XCTAssertEqual(job.crew.attention.map(\.reason), [.decisionAwaiting])
        XCTAssertEqual(job.crew.attention.map(\.acked), [false], "acked absent reads as not acknowledged")
    }

    func testCrewPresenceOrTheDaemonsOptInFlagMeansOptedIn() throws {
        let base: [String: Any] = ["id": "optin", "state": "running", "title": "t"]
        func decode(_ extra: [String: Any]) throws -> MotherJob { try decodeJob(base.merging(extra) { $1 }) }

        XCTAssertTrue(try decode(["crew": ["mode": "enforce"]]).crew.optedIn, "broker form")
        XCTAssertTrue(try decode(["crew": [String: Any]()]).crew.optedIn, "an empty crew object still opts in")
        XCTAssertTrue(try decode(["crew_opt_in": true]).crew.optedIn, "daemon IPC form")
        XCTAssertFalse(try decode(["crew_opt_in": false]).crew.optedIn)
        XCTAssertFalse(try decode(["crew": NSNull()]).crew.optedIn)
        XCTAssertFalse(try decode([:]).crew.optedIn)
    }

    func testAJobWithoutCrewKeysHasAnEmptyCrewState() throws {
        let job = try decodeJob(["id": "plain", "state": "queued", "title": "t"])
        XCTAssertEqual(job.crew, MotherCrewState())
        XCTAssertFalse(job.crew.optedIn)
        XCTAssertEqual(job.crew.decodeIssues, [])
        XCTAssertEqual(MotherJob(id: "x", state: "queued", title: "t").crew, MotherCrewState(), "memberwise init defaults to empty crew")
    }

    // MARK: - Encode / decode

    func testEveryFixtureJobSurvivesAnEncodeDecodeRoundTrip() throws {
        for name in Self.fixtureNames {
            for original in try snapshotJobs(name) {
                let data = try JSONEncoder().encode(original)
                let again = try JSONDecoder().decode(MotherJob.self, from: data)
                XCTAssertEqual(again, original, "\(name)/\(original.id) changed across encode/decode")
            }
        }
    }

    func testEncodedCrewKeysAreFlatSnakeCaseAndNeverIncludeACrewBlob() throws {
        let original = try job("j-hold1", in: try snapshotJobs("gate_hold_answered"))
        let data = try JSONEncoder().encode(original)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(dict["crew_opt_in"] as? Bool, true)
        XCTAssertNil(dict["crew"])
        XCTAssertEqual(dict["activity"] as? String, "gate_hold")
        XCTAssertNotNil(dict["gates"] as? [String: Any])
        XCTAssertEqual((dict["decision"] as? [String: Any])?["id"] as? String, "d-0001")
        let attention = try XCTUnwrap(dict["attention"] as? [[String: Any]])
        XCTAssertEqual(attention.first?["reason"] as? String, "decision_awaiting")
        let options = try XCTUnwrap((dict["decision"] as? [String: Any])?["options"] as? [[String: Any]])
        XCTAssertEqual(options.first?["takes_text"] as? Bool, true, "contract key names, not Swift property names")
    }

    func testAJobWithoutCrewDataEncodesNoCrewKeys() throws {
        let data = try JSONEncoder().encode(MotherJob(id: "p", state: "queued", title: "t"))
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["crew", "crew_opt_in", "activity", "gates", "review_wave", "decision",
                    "attention", "attention_reasons", "last_answer", "progress", "criteria_source"] {
            XCTAssertNil(dict[key], "`\(key)` must be absent for a job without crew data")
        }
    }

    // MARK: - Cross-language goldens (written by the Rust daemon's tests)

    /// The `jobs` array of a `{"type": "mother_jobs", "jobs": [...]}` frame, found
    /// without depending on any other key of the frame.
    private func jobsOfFrame(_ file: String) throws -> [MotherJob] {
        let root = try JSONSerialization.jsonObject(with: try readFixture(file))
        let frame = try XCTUnwrap(root as? [String: Any], "\(file) is not a JSON object")
        XCTAssertEqual(frame["type"] as? String, "mother_jobs", file)
        let jobs = try XCTUnwrap(frame["jobs"] as? [[String: Any]], "\(file) has no jobs array")
        return try decodeJobs(jobs)
    }

    func testTheDaemonsMotherJobsGoldenDecodesToTheSameContractValues() throws {
        let jobs = try jobsOfFrame("ipc_mother_jobs.golden.json")
        XCTAssertEqual(jobs.map(\.id), ["j-gates1", "j-wave1", "j-hold1"])
        try assertGatesJob(jobs)
        try assertWaveJob(jobs)
        try assertHoldJob(jobs)
        XCTAssertTrue(jobs.allSatisfy { $0.crew.optedIn }, "the daemon marks opt-in with crew_opt_in")
    }

    func testTheGoldenAgreesWithTheVendoredFixtureJobsOnEveryCrewKey() throws {
        var fromFixtures: [MotherJob] = []
        for name in Self.fixtureNames { fromFixtures += try snapshotJobs(name) }
        let fromGolden = try jobsOfFrame("ipc_mother_jobs.golden.json")
        // Only the crew state is compared: the daemon re-renders the job-level
        // timestamps (`...00.000Z` becomes `...00Z`), which is not crew data.
        XCTAssertEqual(fromGolden.map(\.crew), fromFixtures.map(\.crew), "daemon wire form and Mother's wire form must read the same")
        XCTAssertEqual(fromGolden.map(\.id), fromFixtures.map(\.id))
    }

    func testTheGoldenForJobsWithoutCrewDataDecodesToEmptyCrewState() throws {
        let jobs = try jobsOfFrame("ipc_mother_jobs_plain.golden.json")
        XCTAssertGreaterThanOrEqual(jobs.count, 5)
        XCTAssertGreaterThanOrEqual(Set(jobs.map(\.state)).count, 5, "the plain golden covers several states")
        for j in jobs {
            XCTAssertEqual(j.crew, MotherCrewState(), "\(j.id) must carry no crew data")
        }
    }
}
