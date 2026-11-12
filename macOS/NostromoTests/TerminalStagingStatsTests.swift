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

    // MARK: Staging-only follows (S3b)

    private func followInvited(mode: String?, terminal: String = "term-9f3a-secret", follower: String = "claudia-secret-tag") -> String {
        let modeField = mode.map { #","mode":"\#($0)""# } ?? ""
        return #"{"ts":"2026-10-31T10:00:00Z","event":"follow_invited","terminal_id":"\#(terminal)","follower_tag":"\#(follower)"\#(modeField)}"#
    }

    private var stagingOnlyTrail: [String] {
        [
            followInvited(mode: "staging_only"),
            followInvited(mode: "full"),
            followInvited(mode: nil),
            followInvited(mode: "staging_only", terminal: "term-7c1d-secret", follower: "cody-secret-tag"),
            #"{"event":"follow_invited","mode":"staging_only""#,
            changed("term-9f3a-secret", "owner-secret", op: "stage"),
        ]
    }

    func testOnlyFollowInvitedLinesInTheStagingOnlyModeCountAsStagingOnlyFollows() {
        let counts = TerminalStagingStats.counts(lines: stagingOnlyTrail)

        XCTAssertEqual(counts.stagingOnlyFollows, 2)
        XCTAssertEqual(counts.malformedLines, 1, "a truncated line is malformed as before")
        XCTAssertEqual(counts.entriesStaged, 1, "the stage line still counts")
        XCTAssertEqual(counts.listsUsed, 1)
    }

    func testAFullAnUnmarkedAndAnUnknownModeNeverCountAsStagingOnly() {
        XCTAssertEqual(TerminalStagingStats.counts(lines: [followInvited(mode: "full"), followInvited(mode: nil),
                                                           followInvited(mode: "something_new"),
                                                           followInvited(mode: "STAGING_ONLY")]).stagingOnlyFollows, 0)
        XCTAssertEqual(TerminalStagingStats.counts(lines: [#"{"event":"follow_invited","mode":7}"#,
                                                           #"{"event":"follow_invited","mode":null}"#]).stagingOnlyFollows, 0)
    }

    func testTheStagingOnlyModeOnAnyOtherEventDoesNotCount() {
        let counts = TerminalStagingStats.counts(lines: [
            #"{"event":"follow_stopped","mode":"staging_only"}"#,
            #"{"event":"follow_resumed","mode":"staging_only"}"#,
            #"{"event":"staging_changed","op":"stage","mode":"staging_only","terminal_id":"t","tag":"a"}"#,
            #"{"event":"something_else","mode":"staging_only"}"#,
        ])
        XCTAssertEqual(counts.stagingOnlyFollows, 0)
        XCTAssertEqual(counts.malformedLines, 0)
    }

    func testAnEmptyTrailHasNoStagingOnlyFollows() {
        XCTAssertEqual(TerminalStagingStats.counts(lines: []).stagingOnlyFollows, 0)
        XCTAssertTrue(TerminalStagingStats.summary(auditDirectory: directory).contains("Staging-only follows granted: 0"))
    }

    func testTheSummaryStatesTheStagingOnlyFollowsFromAnAuditFileAndNamesNoTerminalOrFollower() throws {
        try write("terminal.jsonl", Array(stagingOnlyTrail.prefix(3)))
        try write("terminal-20261031T101010.jsonl", Array(stagingOnlyTrail.dropFirst(3)))

        let text = TerminalStagingStats.summary(auditDirectory: directory)

        XCTAssertTrue(text.contains("Staging-only follows granted: 2"), text)
        for secret in ["term-9f3a-secret", "term-7c1d-secret", "claudia-secret-tag", "cody-secret-tag", "owner-secret"] {
            XCTAssertFalse(text.contains(secret), "counts only: `\(secret)` leaked into:\n\(text)")
        }
    }

    func testTheStagingOnlyLineIsTheLastLineBeforeTheAuditFilesLine() throws {
        var counts = TerminalStagingStats.Counts()
        counts.stagingOnlyFollows = 4
        counts.filesRead = 2
        let lines = TerminalStagingStats.text(counts).split(separator: "\n").map(String.init)

        XCTAssertEqual(lines.count, 11, "one new line, no others: \(lines)")
        XCTAssertEqual(lines[lines.count - 2], "Staging-only follows granted: 4")
        XCTAssertTrue(try XCTUnwrap(lines.last).hasPrefix("Audit files read: 2"), "\(lines)")
        XCTAssertEqual(lines.filter { $0.contains("Staging-only follows granted") }.count, 1)
    }

    func testTheSummaryStillStatesTheOlderCountsWhenStagingOnlyFollowsAreInTheTrail() throws {
        try write("terminal.jsonl", stagingOnlyTrail + [inserted(first: true), refused("list_full")])
        let text = TerminalStagingStats.summary(auditDirectory: directory)

        for expected in ["Lists used: 1", "Inserts: 1", "list_full 1", "malformed lines skipped: 1"] {
            XCTAssertTrue(text.contains(expected), "missing `\(expected)` in:\n\(text)")
        }
    }
}
