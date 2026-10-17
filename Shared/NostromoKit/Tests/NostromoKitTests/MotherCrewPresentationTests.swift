// NostromoKit — MotherCrewPresentationTests.swift
//
// The pure presentation models for Mother's headless-crew data (MC1): the
// one-line progress indicator, gate rows, lens rows, attention badges and the
// "held for you" summary. No UI framework involved.
//
// Pinned strings (the progress line, `gates n/N`, the incomplete note, the
// claims line, badge labels, hold kinds) are asserted exactly; everything else
// asserts the row id / kind / glyph / title exactly and the detail and
// accessibility text by the segments it must contain. Every user-facing string
// must have a non-empty accessibility variant, and no state may be glyph-only:
// the state's word is in both detail and accessibility.

import XCTest
@testable import NostromoKit

final class MotherCrewPresentationTests: XCTestCase {

    // MARK: - Builders

    private func eta(_ label: String?, basis: String? = "fleet") -> MotherProgressEta {
        MotherProgressEta(label: label, basis: basis)
    }

    private func progress(
        pct: Int? = 55,
        label: String? = "Implementing",
        gates: MotherGateSignal? = nil,
        eta: MotherProgressEta? = nil,
        paused: Bool = false
    ) -> MotherProgress {
        MotherProgress(
            pct: pct,
            label: label,
            signals: gates.map { MotherProgressSignals(gates: $0) },
            eta: eta,
            paused: paused
        )
    }

    private func gate(
        _ name: String,
        _ result: MotherGateResult,
        blocking: Bool = true,
        durationS: Int? = nil,
        exitCode: Int? = nil,
        unavailableReason: String? = nil
    ) -> MotherGateResultEntry {
        MotherGateResultEntry(
            name: name, result: result, blocking: blocking,
            durationS: durationS, exitCode: exitCode, unavailableReason: unavailableReason
        )
    }

    private func lens(
        _ reviewer: String,
        _ state: MotherLensState,
        blocking: Int = 0,
        advisory: Int = 0,
        skipReason: String? = nil,
        cost: Double? = nil
    ) -> MotherLensEntry {
        MotherLensEntry(
            reviewer: reviewer,
            lens: reviewer.split(separator: ":").last.map(String.init) ?? reviewer,
            state: state,
            skipReason: skipReason,
            findings: MotherLensFindings(blocking: blocking, advisory: advisory),
            costUsd: cost
        )
    }

    private func assertAllAccessible(_ rows: [MotherCrewRow], file: StaticString = #filePath, line: UInt = #line) {
        for row in rows {
            XCTAssertFalse(row.accessibility.isEmpty, "\(row.id) has no accessibility text", file: file, line: line)
            XCTAssertFalse(row.title.isEmpty, "\(row.id) has no title", file: file, line: line)
            if row.kind != .header {
                XCTAssertFalse(row.glyph.isEmpty, "\(row.id) has no glyph", file: file, line: line)
            }
        }
    }

    // MARK: - Progress line

    func testProgressLineWithGateSignalAndFleetEta() throws {
        let line = try XCTUnwrap(MotherProgressLine.make(
            progress: progress(gates: MotherGateSignal(passed: 1, failed: 0, total: 3), eta: eta("5-15 min")),
            gates: nil
        ))
        XCTAssertEqual(line.text, "≈55% · gates 1/3 · ETA ~5-15 min")
        XCTAssertEqual(line.accessibility, "About 55 percent. 1 of 3 gates passed. Estimated 5 to 15 minutes.")
    }

    func testProgressLineOmitsTheGatesSegmentWhenThereIsNoGateSignal() throws {
        let line = try XCTUnwrap(MotherProgressLine.make(progress: progress(eta: eta("5-15 min")), gates: nil))
        XCTAssertEqual(line.text, "≈55% · ETA ~5-15 min")
        XCTAssertEqual(line.accessibility, "About 55 percent. Estimated 5 to 15 minutes.")
        XCTAssertFalse(line.accessibility.contains("gates"))
    }

    func testProgressLineIgnoresAGateSignalWithTotalZero() throws {
        let line = try XCTUnwrap(MotherProgressLine.make(
            progress: progress(gates: MotherGateSignal(passed: 0, failed: 0, total: 0), eta: eta("5-15 min")),
            gates: nil
        ))
        XCTAssertEqual(line.text, "≈55% · ETA ~5-15 min")
    }

    func testProgressLineDerivesTheGateCountFromTheGatesWhenTheOverlayHasNoSignal() throws {
        // lint passed, unit failed, static not run yet: 1 passed of 3.
        let gates = MotherGates(
            attempt: 1, maxAttempts: 3,
            results: [gate("lint", .passed), gate("unit", .failed)],
            notRun: ["static"]
        )
        let line = try XCTUnwrap(MotherProgressLine.make(progress: progress(eta: eta("5-15 min")), gates: gates))
        XCTAssertEqual(line.text, "≈55% · gates 1/3 · ETA ~5-15 min")
        XCTAssertTrue(line.accessibility.contains("1 of 3 gates passed"), line.accessibility)
    }

    func testTheOverlaysGateSignalWinsOverTheGatesArgument() throws {
        let gates = MotherGates(results: [gate("lint", .passed)], notRun: [])
        let line = try XCTUnwrap(MotherProgressLine.make(
            progress: progress(gates: MotherGateSignal(passed: 2, failed: 0, total: 3), eta: eta("1-4 min")),
            gates: gates
        ))
        XCTAssertEqual(line.text, "≈55% · gates 2/3 · ETA ~1-4 min")
    }

    func testProgressLineOmitsGatesWhenTheGatesArgumentHasNoResultsAndThereIsNoSignal() throws {
        let line = try XCTUnwrap(MotherProgressLine.make(
            progress: progress(eta: eta("5-15 min")),
            gates: MotherGates(attempt: 1, maxAttempts: 3, results: [], notRun: [])
        ))
        XCTAssertEqual(line.text, "≈55% · ETA ~5-15 min")
    }

    func testEtaUnknownWhenThereIsNoEstimate() throws {
        let none = try XCTUnwrap(MotherProgressLine.make(progress: progress(eta: nil), gates: nil))
        XCTAssertEqual(none.text, "≈55% · ETA ?")
        XCTAssertTrue(none.accessibility.contains("Estimated time unknown."), none.accessibility)
        XCTAssertEqual(none.accessibility, "About 55 percent. Estimated time unknown.")
    }

    func testEtaUnknownWhenTheBasisIsNoneEvenIfALabelIsPresent() throws {
        let line = try XCTUnwrap(MotherProgressLine.make(progress: progress(eta: eta("5-15 min", basis: "none")), gates: nil))
        XCTAssertEqual(line.text, "≈55% · ETA ?")
        XCTAssertTrue(line.accessibility.contains("Estimated time unknown."), line.accessibility)
    }

    func testEtaUnknownWhenTheLabelIsMissingOrEmpty() throws {
        for label in [nil, ""] as [String?] {
            let line = try XCTUnwrap(MotherProgressLine.make(progress: progress(eta: eta(label)), gates: nil))
            XCTAssertEqual(line.text, "≈55% · ETA ?", "label \(String(describing: label))")
        }
    }

    func testEtaLabelNotStartingWithADigitIsShownAsIs() throws {
        let line = try XCTUnwrap(MotherProgressLine.make(progress: progress(pct: 95, eta: eta("under 2 min")), gates: nil))
        XCTAssertEqual(line.text, "≈95% · ETA under 2 min")
        XCTAssertTrue(line.accessibility.contains("Estimated under 2 minutes."), line.accessibility)
        XCTAssertTrue(line.accessibility.hasPrefix("About 95 percent."), line.accessibility)
    }

    func testPausedShowsMothersLabelVerbatim() throws {
        let line = try XCTUnwrap(MotherProgressLine.make(
            progress: progress(label: "paused · quota", gates: MotherGateSignal(passed: 1, failed: 0, total: 3), eta: eta("5-15 min"), paused: true),
            gates: nil
        ))
        XCTAssertEqual(line.text, "paused · quota")
        XCTAssertEqual(line.accessibility, "Paused. paused · quota")
    }

    func testPausedWithoutAPercentageStillShowsTheLabel() throws {
        let line = try XCTUnwrap(MotherProgressLine.make(progress: progress(pct: nil, label: "paused · quota", paused: true), gates: nil))
        XCTAssertEqual(line.text, "paused · quota")
    }

    func testPausedWithoutALabelSaysPaused() throws {
        let line = try XCTUnwrap(MotherProgressLine.make(progress: progress(label: nil, paused: true), gates: nil))
        XCTAssertEqual(line.text, "Paused")
        XCTAssertTrue(line.accessibility.hasPrefix("Paused"), line.accessibility)
    }

    func testNoProgressLineWithoutProgressOrWithoutAPercentage() {
        XCTAssertNil(MotherProgressLine.make(progress: nil, gates: nil))
        XCTAssertNil(MotherProgressLine.make(progress: nil, gates: MotherGates(results: [gate("lint", .passed)])))
        XCTAssertNil(MotherProgressLine.make(progress: progress(pct: nil, eta: eta("5-15 min")), gates: nil))
    }

    // MARK: - Gate rows

    func testNoGatesNoRows() {
        XCTAssertEqual(MotherGateRows.make(nil), [])
    }

    func testGateRowsForAMixedRun() {
        let gates = MotherGates(
            status: "failed", attempt: 1, maxAttempts: 3,
            results: [
                gate("lint", .passed, durationS: 42, exitCode: 0),
                gate("unit", .failed, durationS: 188, exitCode: 1),
                gate("static", .skipped, blocking: false),
            ]
        )
        let rows = MotherGateRows.make(gates)
        XCTAssertEqual(rows.map(\.id), ["gates:header", "gate:lint", "gate:unit", "gate:static"])
        XCTAssertEqual(rows.map(\.kind), [.header, .item, .item, .item])
        assertAllAccessible(rows)

        XCTAssertEqual(rows[0].title, "gates 1/3")

        XCTAssertEqual(rows[1].glyph, "✓")
        XCTAssertEqual(rows[1].title, "lint")
        for segment in ["passed", "42s", "blocking", "attempt 1/3"] {
            XCTAssertTrue(rows[1].detail.contains(segment), "lint detail \(rows[1].detail) lacks \(segment)")
        }
        XCTAssertFalse(rows[1].detail.contains("exit"), "exit code is shown for failed gates only: \(rows[1].detail)")
        XCTAssertTrue(rows[1].accessibility.contains("passed"), rows[1].accessibility)
        XCTAssertTrue(rows[1].accessibility.contains("lint"), rows[1].accessibility)

        XCTAssertEqual(rows[2].glyph, "✗")
        XCTAssertEqual(rows[2].title, "unit")
        for segment in ["failed", "3m 08s", "exit 1", "blocking", "attempt 1/3"] {
            XCTAssertTrue(rows[2].detail.contains(segment), "unit detail \(rows[2].detail) lacks \(segment)")
        }
        XCTAssertTrue(rows[2].accessibility.contains("failed"), rows[2].accessibility)

        XCTAssertEqual(rows[3].glyph, "–")
        XCTAssertEqual(rows[3].title, "static")
        XCTAssertTrue(rows[3].detail.contains("skipped"), rows[3].detail)
        XCTAssertTrue(rows[3].detail.contains("advisory"), rows[3].detail)
        XCTAssertFalse(rows[3].detail.contains("blocking"), rows[3].detail)
        XCTAssertTrue(rows[3].accessibility.contains("skipped"), rows[3].accessibility)
    }

    func testGateDetailSegmentsAreJoinedWithMiddleDots() throws {
        let rows = MotherGateRows.make(MotherGates(
            status: "failed", attempt: 2, maxAttempts: 3,
            results: [gate("unit", .failed, durationS: 188, exitCode: 1)]
        ))
        let detail = rows[1].detail
        XCTAssertTrue(detail.contains(" · "), detail)
        let segments = detail.components(separatedBy: " · ")
        XCTAssertEqual(segments.first, "failed", "the result word leads: \(detail)")
        XCTAssertEqual(segments.last, "attempt 2/3", "the attempt closes: \(detail)")
    }

    func testGateDurationFormatting() {
        let rows = MotherGateRows.make(MotherGates(results: [
            gate("a", .passed, durationS: 42),
            gate("b", .passed, durationS: 188),
        ]))
        XCTAssertTrue(rows[1].detail.contains("42s"), rows[1].detail)
        XCTAssertTrue(rows[2].detail.contains("3m 08s"), rows[2].detail)
    }

    func testGateHeaderIsJustGatesWhenAttemptOrMaxAttemptsIsMissing() {
        XCTAssertEqual(MotherGateRows.make(MotherGates(attempt: 2, maxAttempts: nil, results: [gate("lint", .passed)]))[0].title, "gates")
        XCTAssertEqual(MotherGateRows.make(MotherGates(attempt: nil, maxAttempts: 3, results: [gate("lint", .passed)]))[0].title, "gates")
        XCTAssertEqual(MotherGateRows.make(MotherGates(attempt: 2, maxAttempts: 3, results: [gate("lint", .passed)]))[0].title, "gates 2/3")
    }

    func testGateRowsForUnavailableAndUnknownResultsUseTheQuestionMarkAndTheirWord() {
        let rows = MotherGateRows.make(MotherGates(
            attempt: 1, maxAttempts: 3,
            results: [
                gate("e2e", .unavailable, unavailableReason: "no_runner"),
                gate("perf", .unknown("flaky")),
            ]
        ))
        XCTAssertEqual(rows.map(\.id).prefix(3), ["gates:header", "gate:e2e", "gate:perf"])
        let e2e = rows[1], perf = rows[2]
        XCTAssertEqual(e2e.glyph, "?")
        XCTAssertTrue(e2e.detail.contains("unavailable"), e2e.detail)
        XCTAssertTrue(e2e.accessibility.contains("unavailable"), e2e.accessibility)
        XCTAssertFalse(e2e.detail.contains("exit"), e2e.detail)
        XCTAssertEqual(perf.glyph, "?")
        XCTAssertTrue(perf.detail.contains("flaky"), "an unknown result shows its raw value: \(perf.detail)")
        XCTAssertTrue(perf.accessibility.contains("flaky"), perf.accessibility)
        assertAllAccessible(rows)
    }

    func testExitCodeIsShownOnlyForFailedGates() {
        let rows = MotherGateRows.make(MotherGates(results: [
            gate("ok", .passed, exitCode: 0),
            gate("bad", .failed, exitCode: 2),
            gate("nocode", .failed, exitCode: nil),
        ]))
        XCTAssertFalse(rows[1].detail.contains("exit"), rows[1].detail)
        XCTAssertTrue(rows[2].detail.contains("exit 2"), rows[2].detail)
        XCTAssertFalse(rows[3].detail.contains("exit"), rows[3].detail)
    }

    func testIncompleteNoteListsNotRunAndUnavailableGatesDeduped() {
        // not_run: lint, unit; unit is also unavailable (deduped); static is unavailable.
        let gates = MotherGates(
            status: "incomplete", attempt: 1, maxAttempts: 3,
            results: [gate("unit", .unavailable), gate("static", .unavailable), gate("fmt", .passed)],
            notRun: ["lint", "unit"]
        )
        let rows = MotherGateRows.make(gates)
        let note = rows.last
        XCTAssertEqual(note?.id, "gates:incomplete")
        XCTAssertEqual(note?.kind, .note)
        XCTAssertEqual(note?.glyph, "?")
        XCTAssertEqual(note?.title, "Gates incomplete: lint, unit, static")
        XCTAssertFalse(note?.accessibility.isEmpty ?? true)
        XCTAssertEqual(rows.filter { $0.kind == .note }.count, 1)
        assertAllAccessible(rows)
    }

    func testIncompleteNoteNamesNotRunGatesInOrder() {
        let rows = MotherGateRows.make(MotherGates(
            status: "incomplete", attempt: 1, maxAttempts: 3,
            results: [gate("static", .passed)], notRun: ["lint", "unit"]
        ))
        XCTAssertEqual(rows.last?.title, "Gates incomplete: lint, unit")
    }

    func testIncompleteNoteAppearsWhenOnlyNotRunIsNonEmpty() {
        let rows = MotherGateRows.make(MotherGates(status: "running", results: [gate("a", .passed)], notRun: ["b"]))
        XCTAssertEqual(rows.last?.id, "gates:incomplete")
        XCTAssertEqual(rows.last?.title, "Gates incomplete: b")
    }

    func testIncompleteNoteAppearsWhenOnlyAGateIsUnavailable() {
        let rows = MotherGateRows.make(MotherGates(status: "passed", results: [gate("a", .unavailable)], notRun: []))
        XCTAssertEqual(rows.last?.id, "gates:incomplete")
        XCTAssertEqual(rows.last?.title, "Gates incomplete: a")
    }

    func testIncompleteStatusWithNoNamesSaysJustGatesIncomplete() {
        let rows = MotherGateRows.make(MotherGates(status: "incomplete", results: [gate("a", .passed)], notRun: []))
        XCTAssertEqual(rows.last?.id, "gates:incomplete")
        XCTAssertEqual(rows.last?.title, "Gates incomplete")
        XCTAssertEqual(rows.last?.kind, .note)
    }

    func testNoIncompleteNoteForACleanRun() {
        let rows = MotherGateRows.make(MotherGates(
            status: "passed", attempt: 2, maxAttempts: 3,
            results: [gate("lint", .passed), gate("unit", .passed)], notRun: []
        ))
        XCTAssertEqual(rows.map(\.id), ["gates:header", "gate:lint", "gate:unit"])
        XCTAssertFalse(rows.contains { $0.kind == .note })
    }

    // MARK: - Lens rows

    private func fullWave() -> MotherReviewWave {
        MotherReviewWave(
            status: "running", cycle: 1, cycleCap: 2,
            lenses: [
                lens("archie:adherence", .done),
                lens("perri:correctness", .done, blocking: 0, advisory: 2, cost: 0.42),
                lens("perri:ops-infra", .skipped, skipReason: "path_scope"),
            ],
            adherence: MotherAdherence(state: "done", verdict: "pass"),
            coverageGaps: 3,
            claims: MotherClaims(verified: 2, refuted: 0, unverified: 0)
        )
    }

    func testNoWaveNoLensRows() {
        XCTAssertEqual(MotherLensRows.make(nil), [])
    }

    func testLensRowsForAFullWaveInOrder() {
        let rows = MotherLensRows.make(fullWave())
        XCTAssertEqual(rows.map(\.id), [
            "lenses:header", "lens:archie:adherence", "lens:perri:correctness", "lens:perri:ops-infra",
            "lenses:adherence", "lenses:claims", "lenses:gaps",
        ])
        XCTAssertEqual(rows.map(\.kind), [.header, .item, .item, .item, .note, .note, .note])
        XCTAssertTrue(rows[0].title.contains("cycle 1/2"), rows[0].title)
        assertAllAccessible(rows)
    }

    func testLensItemShowsGlyphStateCountsAndCost() {
        let rows = MotherLensRows.make(fullWave())
        let correctness = rows[2]
        XCTAssertEqual(correctness.title, "perri:correctness")
        XCTAssertEqual(correctness.glyph, "✓")
        for segment in ["done", "0 blocking · 2 advisory", "$0.42"] {
            XCTAssertTrue(correctness.detail.contains(segment), "\(correctness.detail) lacks \(segment)")
        }
        XCTAssertTrue(correctness.accessibility.contains("done"), correctness.accessibility)
        XCTAssertTrue(correctness.accessibility.contains("perri:correctness"), correctness.accessibility)
    }

    func testCostIsHiddenWhenZeroOrUnknown() {
        let wave = MotherReviewWave(cycle: 1, cycleCap: 2, lenses: [
            lens("a:one", .done, cost: 0), lens("a:two", .done, cost: nil),
        ])
        let rows = MotherLensRows.make(wave)
        XCTAssertFalse(rows[1].detail.contains("$"), rows[1].detail)
        XCTAssertFalse(rows[2].detail.contains("$"), rows[2].detail)
    }

    func testLensGlyphsPerState() {
        let wave = MotherReviewWave(cycle: 1, cycleCap: 2, lenses: [
            lens("a:pending", .pending), lens("a:running", .running), lens("a:done", .done),
            lens("a:skipped", .skipped, skipReason: "posture"), lens("a:error", .error), lens("a:odd", .unknown("teleporting")),
        ])
        let rows = MotherLensRows.make(wave)
        XCTAssertEqual(rows.dropFirst().prefix(6).map(\.glyph), ["·", "…", "✓", "–", "✗", "?"])
        let words = ["pending", "running", "done", "skipped", "error", "teleporting"]
        for (row, word) in zip(rows.dropFirst().prefix(6), words) {
            XCTAssertTrue(row.detail.contains(word), "\(row.id) detail \(row.detail) lacks \(word)")
            XCTAssertTrue(row.accessibility.contains(word), "\(row.id) accessibility \(row.accessibility) lacks \(word)")
        }
        assertAllAccessible(rows)
    }

    func testSkippedLensShowsItsReasonInWordsAndNoFindingCounts() {
        let reasons: [(String, String)] = [
            ("path_scope", "no matching files"),
            ("posture", "not needed for this repo"),
            ("budget", "over budget"),
            ("removed_by_plan", "removed by the plan"),
            ("brand_new_reason", "brand_new_reason"),
        ]
        for (raw, words) in reasons {
            let rows = MotherLensRows.make(MotherReviewWave(cycle: 1, cycleCap: 2, lenses: [lens("perri:ops-infra", .skipped, skipReason: raw)]))
            let row = rows[1]
            XCTAssertTrue(row.detail.contains(words), "\(raw): \(row.detail)")
            XCTAssertTrue(row.accessibility.contains(words), "\(raw): \(row.accessibility)")
            XCTAssertTrue(row.detail.contains("skipped"), row.detail)
            XCTAssertFalse(row.detail.contains("blocking") || row.detail.contains("advisory"), "skipped lenses show no counts: \(row.detail)")
            // "budget" is itself part of "over budget", so only codes that aren't can be checked.
            if raw != words && !words.contains(raw) {
                XCTAssertFalse(row.detail.contains(raw), "the raw code must not leak when there are words: \(row.detail)")
            }
        }
    }

    func testAdherenceNoteShowsStateAndVerdict() {
        let rows = MotherLensRows.make(fullWave())
        let note = rows.first { $0.id == "lenses:adherence" }
        XCTAssertEqual(note?.kind, .note)
        XCTAssertTrue(note?.title.contains("Adherence: done") ?? false, note?.title ?? "nil")
        XCTAssertTrue(note?.title.contains("pass") ?? false, note?.title ?? "nil")

        let noVerdict = MotherLensRows.make(MotherReviewWave(cycle: 1, cycleCap: 2, lenses: [], adherence: MotherAdherence(state: "pending", verdict: nil)))
        let pending = noVerdict.first { $0.id == "lenses:adherence" }
        XCTAssertTrue(pending?.title.contains("Adherence: pending") ?? false, pending?.title ?? "nil")
        XCTAssertFalse(pending?.accessibility.isEmpty ?? true)
    }

    func testClaimsLineSaysFoundAndNotFoundNeverCorrect() {
        let rows = MotherLensRows.make(fullWave())
        let claims = rows.first { $0.id == "lenses:claims" }
        XCTAssertEqual(claims?.kind, .note)
        XCTAssertEqual(claims?.title, "citations found 2 · not found 0 · unverified 0")
        XCTAssertFalse(claims?.accessibility.isEmpty ?? true)

        let refuted = MotherLensRows.make(MotherReviewWave(cycle: 1, cycleCap: 2, lenses: [], claims: MotherClaims(verified: 5, refuted: 3, unverified: 1)))
        XCTAssertEqual(refuted.first { $0.id == "lenses:claims" }?.title, "citations found 5 · not found 3 · unverified 1")

        // "correct" as a word (the reviewer is called perri:correctness; that is a name, not a claim verdict).
        let word = try! NSRegularExpression(pattern: "\\bcorrect\\b", options: .caseInsensitive)  // swiftlint:disable:this force_try
        for row in rows + refuted {
            for text in [row.title, row.detail, row.accessibility] {
                let range = NSRange(text.startIndex..., in: text)
                XCTAssertNil(word.firstMatch(in: text, range: range), "\"correct\" must not appear in \(row.id): \(text)")
            }
        }
    }

    func testClaimsAreAbsentWhenTheWaveHasNoClaimCounts() {
        let rows = MotherLensRows.make(MotherReviewWave(cycle: 1, cycleCap: 2, lenses: [lens("a:one", .done)], claims: nil))
        XCTAssertFalse(rows.contains { $0.id == "lenses:claims" })
    }

    func testCoverageGapsNoteOnlyWhenThereAreGaps() {
        let rows = MotherLensRows.make(fullWave())
        let gaps = rows.first { $0.id == "lenses:gaps" }
        XCTAssertEqual(gaps?.title, "Coverage gaps: 3")
        XCTAssertEqual(gaps?.kind, .note)
        XCTAssertFalse(gaps?.accessibility.isEmpty ?? true)

        for none in [0, nil] as [Int?] {
            let wave = MotherReviewWave(cycle: 1, cycleCap: 2, lenses: [lens("a:one", .done)], coverageGaps: none)
            XCTAssertFalse(MotherLensRows.make(wave).contains { $0.id == "lenses:gaps" }, "coverage_gaps \(String(describing: none))")
        }
    }

    // MARK: - Attention badges

    private func attention(_ reasons: [(MotherAttentionReason, Bool)]) -> [MotherAttention] {
        reasons.map { MotherAttention(reason: $0.0, since: "2026-10-17T12:00:00.000Z", acked: $0.1) }
    }

    func testNoAttentionNoBadges() {
        XCTAssertEqual(MotherAttentionBadges.make([]), [])
    }

    func testBadgesUseFixedOrderAndShortLabels() {
        // Deliberately shuffled input.
        let badges = MotherAttentionBadges.make(attention([
            (.burnAhead, false), (.progressStalled, false), (.decisionAwaiting, false), (.gatesIncomplete, false),
        ]))
        XCTAssertEqual(badges.map(\.reason), [.decisionAwaiting, .gatesIncomplete, .progressStalled, .burnAhead])
        XCTAssertEqual(badges.map(\.label), ["Needs decision", "Gates incomplete", "Stalled", "Burning ahead"])
        XCTAssertEqual(badges.map(\.acked), [false, false, false, false])
        for badge in badges {
            XCTAssertFalse(badge.accessibility.isEmpty, badge.label)
            XCTAssertTrue(badge.accessibility.contains(badge.label) || badge.accessibility.lowercased().contains(badge.label.lowercased()), "\(badge.label): \(badge.accessibility)")
        }
    }

    func testUnknownReasonsFollowTheKnownOnesAndLabelThemselvesWithTheRawValue() {
        let badges = MotherAttentionBadges.make(attention([
            (.unknown("future_reason"), false), (.burnAhead, false), (.decisionAwaiting, false),
        ]))
        XCTAssertEqual(badges.map(\.reason), [.decisionAwaiting, .burnAhead, .unknown("future_reason")])
        XCTAssertEqual(badges.last?.label, "future_reason")
        XCTAssertFalse(badges.last?.accessibility.isEmpty ?? true)
    }

    func testAckedReasonsAreStillReturnedMarkedAcknowledged() throws {
        let badges = MotherAttentionBadges.make(attention([(.progressStalled, true), (.decisionAwaiting, false)]))
        XCTAssertEqual(badges.count, 2)
        let stalled = try XCTUnwrap(badges.first { $0.reason == .progressStalled })
        XCTAssertTrue(stalled.acked)
        XCTAssertEqual(stalled.label, "Stalled")
        XCTAssertTrue(stalled.accessibility.lowercased().contains("acknowledged"), stalled.accessibility)
        let decision = try XCTUnwrap(badges.first { $0.reason == .decisionAwaiting })
        XCTAssertFalse(decision.acked)
        XCTAssertFalse(decision.accessibility.isEmpty)
    }

    func testDuplicateReasonsCollapseIntoOneBadge() {
        let badges = MotherAttentionBadges.make(attention([(.burnAhead, false), (.burnAhead, false), (.decisionAwaiting, false), (.decisionAwaiting, false)]))
        XCTAssertEqual(badges.map(\.reason), [.decisionAwaiting, .burnAhead])
    }

    // MARK: - Hold summary

    private func holdDecision(kind: String = "gate_hold", resolvedAt: String? = nil) -> MotherDecision {
        MotherDecision(
            id: "d-0001", kind: kind,
            options: [
                MotherDecisionOption(id: .resumeWithGuidance, label: "Resume with guidance", consequence: "Worker resumes in the same session with your note; gates re-run.", takesText: true),
                MotherDecisionOption(id: .escalate, label: "Escalate", consequence: "Re-run one tier up.", takesText: false),
                MotherDecisionOption(id: .overrideOpen, label: "Override and open", consequence: "Mark the PR ready with red gates recorded as overridden.", takesText: false),
                MotherDecisionOption(id: .cancel, label: "Cancel", consequence: "Stop the job.", takesText: false),
            ],
            openedAt: "2026-10-17T12:00:02.000Z", resolvedAt: resolvedAt
        )
    }

    private func job(state: String, activity: String? = nil, decision: MotherDecision? = nil, question: String? = "Gate attempts are exhausted (3 of 3).") -> MotherJob {
        MotherJob(
            id: "j-hold1", state: state, title: "Backfill invoice totals", question: question,
            crew: MotherCrewState(optedIn: true, activity: activity, decision: decision)
        )
    }

    func testGateHoldSummaryCarriesKindQuestionAndOptionsInMothersOrder() throws {
        let summary = try XCTUnwrap(MotherHoldSummary.make(job(state: "awaiting", activity: "gate_hold", decision: holdDecision())))
        XCTAssertEqual(summary.kind, "Gates exhausted")
        XCTAssertEqual(summary.question, "Gate attempts are exhausted (3 of 3).")
        XCTAssertEqual(summary.options.map(\.id), [.resumeWithGuidance, .escalate, .overrideOpen, .cancel])
        XCTAssertEqual(summary.options.map(\.label), ["Resume with guidance", "Escalate", "Override and open", "Cancel"])
        XCTAssertEqual(summary.options.map(\.takesText), [true, false, false, false])
        XCTAssertEqual(summary.options[1].consequence, "Re-run one tier up.")
        XCTAssertFalse(summary.accessibility.isEmpty)
        for option in summary.options {
            XCTAssertFalse(option.accessibility.isEmpty, option.label)
            XCTAssertTrue(option.accessibility.contains(option.label), option.accessibility)
        }
    }

    func testReviewHoldSummaryKind() throws {
        let summary = try XCTUnwrap(MotherHoldSummary.make(job(state: "awaiting", activity: "review_hold", decision: holdDecision(kind: "review_hold"))))
        XCTAssertEqual(summary.kind, "Review hold")
    }

    func testAHoldActivityWithoutADecisionStillSummarisesWithNoOptions() throws {
        let gate = try XCTUnwrap(MotherHoldSummary.make(job(state: "awaiting", activity: "gate_hold")))
        XCTAssertEqual(gate.kind, "Gates exhausted")
        XCTAssertEqual(gate.options, [])
        XCTAssertFalse(gate.accessibility.isEmpty)
        let review = try XCTUnwrap(MotherHoldSummary.make(job(state: "awaiting", activity: "review_hold")))
        XCTAssertEqual(review.kind, "Review hold")
        XCTAssertEqual(review.options, [])
    }

    func testAnOpenDecisionOnARunningJobIsAGenericDecisionNeeded() throws {
        let summary = try XCTUnwrap(MotherHoldSummary.make(job(state: "running", activity: "gating", decision: holdDecision(kind: "future_kind"), question: nil)))
        XCTAssertEqual(summary.kind, "Decision needed")
        XCTAssertNil(summary.question)
        XCTAssertEqual(summary.options.count, 4)
    }

    func testNoSummaryUnlessHeldForTheOperator() {
        XCTAssertNil(MotherHoldSummary.make(job(state: "running")), "running, no decision")
        XCTAssertNil(MotherHoldSummary.make(job(state: "running", activity: "gate_hold")), "hold activity needs state awaiting")
        XCTAssertNil(MotherHoldSummary.make(job(state: "awaiting", activity: "gating")), "awaiting with an unrelated activity and no decision")
        XCTAssertNil(MotherHoldSummary.make(job(state: "awaiting")), "a plain `mother await` question is not a crew hold")
        XCTAssertNil(MotherHoldSummary.make(job(state: "running", decision: holdDecision(resolvedAt: "2026-10-17T12:05:00.000Z"))), "a resolved decision holds nothing")
        XCTAssertNil(MotherHoldSummary.make(MotherJob(id: "plain", state: "queued", title: "t")))
    }

    // MARK: - Job row model

    func testJobRowModelDefaultsCarryNoProgressOrBadges() {
        let row = MotherJobRowModel(id: "j", state: "running", title: "t")
        XCTAssertNil(row.progressLine)
        XCTAssertEqual(row.attentionBadges, [])
    }

    func testJobRowModelStillBuildsFromTheExistingSevenArguments() {
        let row = MotherJobRowModel(
            id: "j", state: "awaiting", title: "t", repo: "r", branch: "b",
            question: "q?", relativeTimestamp: "5m ago"
        )
        XCTAssertEqual(row.repo, "r")
        XCTAssertEqual(row.relativeTimestamp, "5m ago")
        XCTAssertNil(row.progressLine)
        XCTAssertTrue(row.attentionBadges.isEmpty)
        XCTAssertFalse(row.isDone)
    }

    func testJobRowModelCarriesAProgressLineAndBadgeLabels() {
        let row = MotherJobRowModel(
            id: "j", state: "running", title: "t",
            progressLine: "≈55% · ETA ~5-15 min", attentionBadges: ["Needs decision", "Stalled"]
        )
        XCTAssertEqual(row.progressLine, "≈55% · ETA ~5-15 min")
        XCTAssertEqual(row.attentionBadges, ["Needs decision", "Stalled"])
        XCTAssertNotEqual(row, MotherJobRowModel(id: "j", state: "running", title: "t"))
    }
}
