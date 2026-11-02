import XCTest
import Foundation

// `TerminalStagingStats`: the content-free staging numbers (PRD "Metrics") from the terminal audit trail.
//
//   * Every listed count is computed from a fixture trail: `terminal.jsonl` and its rotated siblings
//     `terminal-<stamp>[-N].jsonl`; malformed lines are skipped and counted.
//   * The trail is read only: nothing is written, and unrelated files in the folder are not read.
//   * Counts only: the summary never carries a command, a note, a terminal id or an owner.

final class TerminalStagingStatsTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("staging-stats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func write(_ name: String, _ lines: [String]) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func changed(_ terminal: String, _ owner: String, op: String, by: String = "agent", unused: Int = 0) -> String {
        #"{"ts":"2026-10-31T10:00:00Z","event":"staging_changed","terminal_id":"\#(terminal)","tag":"\#(owner)","op":"\#(op)","by":"\#(by)","entries":1,"bytes":3,"unused":\#(unused)}"#
    }

    private func inserted(first: Bool, confirmed: Bool = false) -> String {
        #"{"ts":"2026-10-31T10:00:00Z","event":"staging_inserted","terminal_id":"t1","entry_number":1,"bytes":3,"confirmed":\#(confirmed),"first":\#(first)}"#
    }

    private func refused(_ code: String) -> String {
        #"{"ts":"2026-10-31T10:00:00Z","event":"staging_refused","terminal_id":"t1","tag":"owner-a","op":"stage","code":"\#(code)"}"#
    }

    private func ui(_ name: String) -> String {
        #"{"ts":"2026-10-31T10:00:00Z","event":"staging_ui_event","terminal_id":"t1","ui_event":"\#(name)"}"#
    }

    private func writeFixtureTrail() throws {
        try write("terminal.jsonl", [
            changed("t1", "owner-a", op: "stage"), changed("t1", "owner-a", op: "stage"), changed("t2", "owner-a", op: "stage"),
            inserted(first: true), inserted(first: false),
            changed("t1", "owner-a", op: "archive", by: "user"),
            refused("list_full"),
            ui("just_changed"),
            "this is not json",
        ])
        try write("terminal-20261031T101010.jsonl", [
            changed("t1", "owner-b", op: "stage"),
            inserted(first: true, confirmed: true),
            changed("t1", "owner-b", op: "remove", unused: 2), changed("t1", "owner-b", op: "clear", by: "user", unused: 1),
            changed("t1", "owner-b", op: "archive", by: "user"), changed("t1", "owner-b", op: "archive", by: "auto"),
            refused("rate_limited"), refused("rate_limited"), refused("something_else"),
            ui("confirm_cancelled"), ui("just_changed"), ui("just_changed"), ui("unknown_event"),
            #"{"event":1}"#,
        ])
        try write("terminal-20261031T101010-1.jsonl", [inserted(first: false)])
        try write("not-the-terminal-trail.jsonl", [changed("t9", "owner-z", op: "stage")])
    }

    func testEveryListedCountIsComputedFromTheFixtureTrailIncludingRotatedFilesAndMalformedLines() throws {
        try writeFixtureTrail()
        let counts = TerminalStagingStats.counts(files: TerminalStagingStats.auditFiles(in: directory))

        XCTAssertEqual(counts.filesRead, 3, "terminal.jsonl and its two rotated siblings; nothing else")
        XCTAssertEqual(counts.listsUsed, 3, "distinct terminal + owner with a stage: (t1,a) (t2,a) (t1,b)")
        XCTAssertEqual(counts.entriesStaged, 4)
        XCTAssertEqual(counts.inserts, 4)
        XCTAssertEqual(counts.firstInserts, 2, "entries inserted at least once")
        XCTAssertEqual(counts.unused, 3)
        XCTAssertEqual(counts.archivedManual, 2)
        XCTAssertEqual(counts.archivedAuto, 1)
        XCTAssertEqual(counts.listFull, 1)
        XCTAssertEqual(counts.rateLimited, 2)
        XCTAssertEqual(counts.confirmsInserted, 1)
        XCTAssertEqual(counts.confirmsCancelled, 1)
        XCTAssertEqual(counts.justChanged, 3)
        XCTAssertEqual(counts.malformedLines, 2, "a line that is not JSON and one with no event name")
    }

    func testTheSummaryTextStatesEveryCountAndNothingElse() throws {
        try writeFixtureTrail()
        let text = TerminalStagingStats.summary(auditDirectory: directory)
        for expected in ["Lists used: 3", "Inserts: 4 (1.3 per list)", "Staged entries inserted at least once: 2 of 4 (50%)",
                         "Removed or cleared unused: 3", "Archived: 2 manual, 1 auto", "list_full 1, rate_limited 2",
                         "Destructive confirms: 1 inserted, 1 cancelled", "Just changed (refused within the reading delay): 3",
                         "malformed lines skipped: 2"] {
            XCTAssertTrue(text.contains(expected), "missing `\(expected)` in:\n\(text)")
        }
        XCTAssertFalse(text.contains("owner-a") || text.contains("t1"), "no terminal id or owner")
    }

    func testAnEmptyTrailSaysNotAvailableInsteadOfDividingByZero() {
        let text = TerminalStagingStats.summary(auditDirectory: directory)
        XCTAssertTrue(text.contains("Lists used: 0"), text)
        XCTAssertTrue(text.contains("(n/a)"), text)
    }

    func testTheTrailIsReadOnly() throws {
        try writeFixtureTrail()
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        let sizes = try before.map { try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent($0).path)[.size] as? Int }
        _ = TerminalStagingStats.summary(auditDirectory: directory)
        let after = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(before, after, "no file was created or removed")
        XCTAssertEqual(try after.map { try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent($0).path)[.size] as? Int }, sizes)
    }

    func testTheAuditFilesAreTheCurrentOneAndItsRotatedSiblingsOnly() throws {
        try writeFixtureTrail()
        XCTAssertEqual(TerminalStagingStats.auditFiles(in: directory).map(\.lastPathComponent),
                       ["terminal-20261031T101010-1.jsonl", "terminal-20261031T101010.jsonl", "terminal.jsonl"])
    }

    func testNoCommandTextInAnAuditLineEverReachesTheSummary() {
        let secret = "php artisan queue:flush --token=hunter2"
        let counts = TerminalStagingStats.counts(lines: [
            #"{"event":"staging_changed","terminal_id":"t","tag":"a","op":"stage","by":"agent","entries":1,"bytes":3,"unused":0,"command":"\#(secret)"}"#,
        ])
        XCTAssertFalse(TerminalStagingStats.text(counts).contains("hunter2"))
    }
}
