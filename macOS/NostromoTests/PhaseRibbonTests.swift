import XCTest
// JobPhase, JobCycle, JobPhaseState, MotherJob, MotherJobSlim,
// PhaseRibbonModel, PhaseRibbonToken are compiled into this target directly
// (logic test — no host app, same as MotherBrokerClientTests).

// MARK: - PhaseRibbonTests

/// Unit tests for Wedge C phase-ribbon decode + view model.
///
/// Four decode tests (pipeline/flat/absent/unknown-state) and four ribbon-model
/// tests (mixed states / findings / pipeline label / no-data → nil).
final class PhaseRibbonTests: XCTestCase {

    // Decoder that mirrors MotherBrokerClient's ISO8601 date strategy.
    private static let decoder: JSONDecoder = {
        let d        = JSONDecoder()
        let fmtFrac  = ISO8601DateFormatter()
        fmtFrac.formatOptions  = [.withInternetDateTime, .withFractionalSeconds]
        let fmtBasic = ISO8601DateFormatter()
        fmtBasic.formatOptions = [.withInternetDateTime]
        d.dateDecodingStrategy = .custom { dec in
            let c   = try dec.singleValueContainer()
            let str = try c.decode(String.self)
            if let d = fmtFrac.date(from: str)  { return d }
            if let d = fmtBasic.date(from: str) { return d }
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Cannot parse date: \(str)")
        }
        return d
    }()

    /// Decode a JSON string into MotherJob via the slim decoder (same path the broker uses).
    private func decodeJob(_ json: String) throws -> MotherJob {
        let data = json.data(using: .utf8)!
        let slim = try Self.decoder.decode(MotherJobSlim.self, from: data)
        return slim.toMotherJob()
    }

    // ──────────────────────────────────────────────────────────────────────────
    // DECODE TEST 1: Pipeline job — all cycles and phases decoded correctly.
    // ──────────────────────────────────────────────────────────────────────────

    func testDecoding_pipelineJob_allCyclesDecoded() throws {
        let json = """
        {
          "id":"pipeline-1","state":"running","repo":"r","isolation":"none","title":"T",
          "kind":"pipeline",
          "cycles":[
            {
              "cycle":1,
              "phases":[
                {"agent":"redd","request_type":"test","state":"completed",
                 "started_at":"2026-06-01T10:00:00.000Z",
                 "finished_at":"2026-06-01T10:01:00.000Z","findings":null},
                {"agent":"cody","request_type":"code","state":"completed",
                 "started_at":"2026-06-01T10:01:00.000Z",
                 "finished_at":"2026-06-01T10:02:00.000Z","findings":null},
                {"agent":"perri","request_type":"review","state":"running",
                 "started_at":"2026-06-01T10:02:00.000Z",
                 "finished_at":null,"findings":3}
              ]
            }
          ],
          "phases":[]
        }
        """
        let job = try decodeJob(json)
        XCTAssertEqual(job.kind,          "pipeline")
        XCTAssertEqual(job.cycles.count,  1)
        let cycle = job.cycles[0]
        XCTAssertEqual(cycle.cycle,          1)
        XCTAssertEqual(cycle.phases.count,   3)
        XCTAssertEqual(cycle.phases[0].agent, "redd")
        XCTAssertEqual(cycle.phases[0].state, .completed)
        XCTAssertNil(cycle.phases[0].findings,  "null findings → nil")
        XCTAssertNotNil(cycle.phases[0].startedAt, "started_at should parse")
        XCTAssertEqual(cycle.phases[2].agent,     "perri")
        XCTAssertEqual(cycle.phases[2].state,     .running)
        XCTAssertEqual(cycle.phases[2].findings,  3)
    }

    // ──────────────────────────────────────────────────────────────────────────
    // DECODE TEST 2: Flat (non-pipeline) job — phases array decoded.
    // ──────────────────────────────────────────────────────────────────────────

    func testDecoding_flatJob_phasesDecoded() throws {
        let json = """
        {
          "id":"flat-1","state":"running","repo":"r","isolation":"none","title":"T",
          "phases":[
            {"agent":"redd","request_type":"test","state":"completed"},
            {"agent":"cody","request_type":"code","state":"running"},
            {"agent":"marty","request_type":"refactor","state":"pending"}
          ]
        }
        """
        let job = try decodeJob(json)
        XCTAssertNil(job.kind)
        XCTAssertEqual(job.phases.count,   3)
        XCTAssertEqual(job.phases[0].agent, "redd")
        XCTAssertEqual(job.phases[0].state, .completed)
        XCTAssertEqual(job.phases[1].state, .running)
        XCTAssertEqual(job.phases[2].state, .pending)
        XCTAssertTrue(job.cycles.isEmpty,  "flat job has no cycles")
    }

    // ──────────────────────────────────────────────────────────────────────────
    // DECODE TEST 3: Absent phases/cycles (pre-Wedge-C job) — must not throw.
    // ──────────────────────────────────────────────────────────────────────────

    func testDecoding_absentPhasesAndCycles_noThrow() throws {
        let json = """
        {"id":"old-1","state":"succeeded","repo":"r","isolation":"none","title":"T"}
        """
        let job = try decodeJob(json)
        XCTAssertTrue(job.phases.isEmpty,  "absent phases → empty array")
        XCTAssertTrue(job.cycles.isEmpty,  "absent cycles → empty array")
        XCTAssertNil(job.kind)
    }

    // ──────────────────────────────────────────────────────────────────────────
    // DECODE TEST 4: Unknown state string — silently defaults to .pending.
    // ──────────────────────────────────────────────────────────────────────────

    func testDecoding_unknownPhaseState_defaultsPending() throws {
        let json = """
        {
          "id":"j","state":"running","repo":"r","isolation":"none","title":"T",
          "phases":[
            {"agent":"ada","state":"exploded"},
            {"agent":"cody","state":"in_progress_v99"}
          ]
        }
        """
        let job = try decodeJob(json)
        XCTAssertEqual(job.phases.count, 2)
        XCTAssertEqual(job.phases[0].state, .pending,
                       "unknown state 'exploded' should default to .pending")
        XCTAssertEqual(job.phases[1].state, .pending,
                       "unknown state 'in_progress_v99' should default to .pending")
    }

    // ──────────────────────────────────────────────────────────────────────────
    // RIBBON TEST 5: Completed / running / pending mix → correct tokens.
    // ──────────────────────────────────────────────────────────────────────────

    func testRibbonModel_mixedStates_correctTokens() {
        let job = MotherJob(
            id: "j", state: "running", repo: "r", isolation: "none", title: "T",
            createdAt: nil, startedAt: nil, finishedAt: nil,
            planPath: nil, question: nil, pausedReason: nil,
            adherenceStatus: nil, currentTier: nil,
            phases: [
                JobPhase(agent: "redd",  state: .completed),
                JobPhase(agent: "cody",  state: .running),
                JobPhase(agent: "marty", state: .pending),
            ]
        )
        guard let ribbon = job.phaseRibbonModel else {
            XCTFail("expected non-nil ribbon for flat-phase job"); return
        }
        XCTAssertNil(ribbon.cycleLabel, "flat job should have no cycle label")
        XCTAssertEqual(ribbon.tokens.count, 3)
        XCTAssertEqual(ribbon.tokens[0], PhaseRibbonToken(text: "redd✓",  state: .completed))
        XCTAssertEqual(ribbon.tokens[1], PhaseRibbonToken(text: "cody⟳",  state: .running))
        XCTAssertEqual(ribbon.tokens[2], PhaseRibbonToken(text: "marty·", state: .pending))
    }

    // ──────────────────────────────────────────────────────────────────────────
    // RIBBON TEST 6: Findings count > 0 appears in label; 0 is suppressed.
    // ──────────────────────────────────────────────────────────────────────────

    func testRibbonModel_findingsCount_appearsInLabel() {
        let job = MotherJob(
            id: "j", state: "running", repo: "r", isolation: "none", title: "T",
            createdAt: nil, startedAt: nil, finishedAt: nil,
            planPath: nil, question: nil, pausedReason: nil,
            adherenceStatus: nil, currentTier: nil,
            phases: [
                JobPhase(agent: "ada",   state: .completed, findings: 2),
                JobPhase(agent: "perri", state: .running,   findings: 5),
                JobPhase(agent: "redd",  state: .completed, findings: nil),
            ]
        )
        guard let ribbon = job.phaseRibbonModel else {
            XCTFail("expected non-nil ribbon"); return
        }
        XCTAssertEqual(ribbon.tokens[0].text, "ada✓(2)",   "findings > 0 appends (N)")
        XCTAssertEqual(ribbon.tokens[1].text, "perri⟳(5)", "running with findings")
        XCTAssertEqual(ribbon.tokens[2].text, "redd✓",     "nil findings → no suffix")
    }

    // ──────────────────────────────────────────────────────────────────────────
    // RIBBON TEST 7: Pipeline job shows last (current) cycle + cycle label.
    // ──────────────────────────────────────────────────────────────────────────

    func testRibbonModel_pipelineJob_showsLastCycleWithLabel() {
        let job = MotherJob(
            id: "j", state: "running", repo: "r", isolation: "none", title: "T",
            createdAt: nil, startedAt: nil, finishedAt: nil,
            planPath: nil, question: nil, pausedReason: nil,
            adherenceStatus: nil, currentTier: nil,
            kind: "pipeline",
            cycles: [
                JobCycle(cycle: 1, phases: [
                    JobPhase(agent: "redd", state: .completed),
                ]),
                JobCycle(cycle: 2, phases: [
                    JobPhase(agent: "redd",  state: .completed),
                    JobPhase(agent: "cody",  state: .running),
                    JobPhase(agent: "perri", state: .pending),
                ]),
            ]
        )
        guard let ribbon = job.phaseRibbonModel else {
            XCTFail("expected non-nil ribbon for pipeline job"); return
        }
        XCTAssertEqual(ribbon.cycleLabel,    "cycle 2", "shows last (current) cycle number")
        XCTAssertEqual(ribbon.tokens.count,  3)
        XCTAssertEqual(ribbon.tokens[0].text, "redd✓")
        XCTAssertEqual(ribbon.tokens[1].text, "cody⟳")
        XCTAssertEqual(ribbon.tokens[2].text, "perri·")
    }

    // ──────────────────────────────────────────────────────────────────────────
    // RIBBON TEST 8: No phase data → nil ribbon; must not crash.
    // ──────────────────────────────────────────────────────────────────────────

    func testRibbonModel_noPhaseData_returnsNil() {
        let job = MotherJob(
            id: "j", state: "succeeded", repo: "r", isolation: "none", title: "T",
            createdAt: nil, startedAt: nil, finishedAt: nil,
            planPath: nil, question: nil, pausedReason: nil,
            adherenceStatus: nil, currentTier: nil
            // No kind / phases / cycles — defaults apply
        )
        XCTAssertNil(job.phaseRibbonModel,
                     "job with no phase data must return nil ribbon without crashing")
    }
}
