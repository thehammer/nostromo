import XCTest

// WindowPlacementLog.swift is compiled into this target directly. Every test
// writes under a unique temp directory — never the real ~/.nostromo.

final class WindowPlacementLogTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowPlacementLogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        try super.tearDownWithError()
    }

    // MARK: Helpers

    private var logURL: URL { tempRoot.appendingPathComponent("logs/window-placement.log") }

    private func contents(of url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func fileSize(of url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    private func lines(of url: URL) -> [String] {
        contents(of: url).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// Message text with a zero-padded sequence number so order is easy to assert.
    private func numbered(_ i: Int) -> String { "event-\(String(format: "%05d", i))" }

    // MARK: Appending

    func test_a_logged_event_is_appended_as_a_line_with_its_scope_tag_and_message() {
        let log = WindowPlacementLog(fileURL: logURL)

        log.log("launch", "screen#1 uuid=ABC main=true")
        log.flush()

        let written = lines(of: logURL)
        XCTAssertEqual(written.count, 1)
        XCTAssertTrue(written[0].contains("[launch]"), "scope tag missing: \(written[0])")
        XCTAssertTrue(written[0].hasSuffix("screen#1 uuid=ABC main=true"), "message missing: \(written[0])")
    }

    func test_each_line_starts_with_a_timestamp_before_the_scope_tag() {
        let log = WindowPlacementLog(fileURL: logURL)

        log.log("launch", "hello")
        log.flush()

        let line = lines(of: logURL)[0]
        let beforeScope = line.components(separatedBy: " [launch]")[0]
        XCTAssertFalse(beforeScope.isEmpty)
        XCTAssertNotNil(ISO8601DateFormatter().date(from: String(beforeScope.prefix(19)) + "Z"),
                        "expected an ISO-8601 timestamp prefix, got: \(beforeScope)")
    }

    func test_events_keep_their_order_and_their_own_scopes() {
        let log = WindowPlacementLog(fileURL: logURL)

        log.log("launch", "first")
        log.log("win#0 → UUID-A", "second")
        log.log("win#1 → UUID-B", "third", warning: true)
        log.flush()

        let written = lines(of: logURL)
        XCTAssertEqual(written.count, 3)
        XCTAssertTrue(written[0].contains("[launch]") && written[0].hasSuffix("first"))
        XCTAssertTrue(written[1].contains("[win#0 → UUID-A]") && written[1].hasSuffix("second"))
        XCTAssertTrue(written[2].contains("[win#1 → UUID-B]") && written[2].hasSuffix("third"))
    }

    func test_warnings_are_written_to_the_file_like_any_other_event() {
        let log = WindowPlacementLog(fileURL: logURL)

        log.log("win#0", "WARNING: not on target", warning: true)
        log.flush()

        XCTAssertTrue(contents(of: logURL).contains("WARNING: not on target"))
    }

    func test_logging_appends_to_an_existing_file_rather_than_replacing_it() {
        let first = WindowPlacementLog(fileURL: logURL)
        first.log("launch", "from first instance")
        first.flush()

        // A new instance (e.g. the next app launch) on the same file.
        let second = WindowPlacementLog(fileURL: logURL)
        second.log("launch", "from second instance")
        second.flush()

        let text = contents(of: logURL)
        XCTAssertTrue(text.contains("from first instance"))
        XCTAssertTrue(text.contains("from second instance"))
    }

    func test_every_line_ends_with_a_newline() {
        let log = WindowPlacementLog(fileURL: logURL)

        log.log("launch", "a")
        log.log("launch", "b")
        log.flush()

        XCTAssertTrue(contents(of: logURL).hasSuffix("\n"))
        XCTAssertEqual(lines(of: logURL).count, 2)
    }

    // MARK: Directory creation

    func test_missing_intermediate_directories_are_created() {
        let deep = tempRoot.appendingPathComponent("a/b/c/logs/window-placement.log")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("a").path))
        let log = WindowPlacementLog(fileURL: deep)

        log.log("launch", "hello")
        log.flush()

        XCTAssertTrue(FileManager.default.fileExists(atPath: deep.path))
        XCTAssertTrue(contents(of: deep).contains("hello"))
    }

    func test_constructing_the_log_does_not_touch_the_disk_until_something_is_logged() {
        _ = WindowPlacementLog(fileURL: logURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.path))
    }

    // MARK: Size cap

    func test_the_file_never_exceeds_the_byte_cap_after_flush() {
        let cap = 2_000
        let log = WindowPlacementLog(fileURL: logURL, maxBytes: cap)

        for i in 0..<500 {
            log.log("win#0", numbered(i))
        }
        log.flush()

        let size = fileSize(of: logURL)
        XCTAssertGreaterThan(size, 0)
        XCTAssertLessThanOrEqual(size, cap)
    }

    func test_the_cap_holds_at_every_point_while_writing_not_just_at_the_end() {
        let cap = 1_500
        let log = WindowPlacementLog(fileURL: logURL, maxBytes: cap)

        for i in 0..<300 {
            log.log("win#0", numbered(i))
            if i % 25 == 0 {
                log.flush()
                XCTAssertLessThanOrEqual(fileSize(of: logURL), cap, "over the cap after \(i + 1) events")
            }
        }
    }

    func test_the_newest_lines_are_kept_and_the_oldest_are_dropped() {
        let cap = 2_000
        let count = 500
        let log = WindowPlacementLog(fileURL: logURL, maxBytes: cap)

        for i in 0..<count { log.log("win#0", numbered(i)) }
        log.flush()

        let text = contents(of: logURL)
        XCTAssertTrue(text.contains(numbered(count - 1)), "the newest line must survive trimming")
        XCTAssertFalse(text.contains(numbered(0)), "the oldest line must have been dropped")
    }

    func test_retained_lines_are_a_contiguous_run_ending_at_the_newest() {
        let cap = 2_000
        let count = 500
        let log = WindowPlacementLog(fileURL: logURL, maxBytes: cap)

        for i in 0..<count { log.log("win#0", numbered(i)) }
        log.flush()

        let indices = lines(of: logURL).compactMap { line -> Int? in
            guard let range = line.range(of: "event-") else { return nil }
            return Int(line[range.upperBound...])
        }
        XCTAssertFalse(indices.isEmpty)
        XCTAssertEqual(indices.last, count - 1)
        XCTAssertEqual(indices, Array(indices[0]...(count - 1)), "no gaps or reordering in what is kept")
    }

    func test_after_trimming_the_file_starts_on_a_whole_line() {
        let cap = 2_000
        let log = WindowPlacementLog(fileURL: logURL, maxBytes: cap)

        for i in 0..<500 { log.log("win#0", numbered(i)) }
        log.flush()

        let all = lines(of: logURL)
        XCTAssertFalse(all.isEmpty)
        for line in all {
            // A whole line begins with its timestamp and has its scope tag and complete message.
            XCTAssertTrue(line.contains("[win#0] event-"), "partial line found: \(line)")
        }
        XCTAssertNotNil(ISO8601DateFormatter().date(from: String(all[0].prefix(19)) + "Z"),
                        "first retained line should start with a timestamp: \(all[0])")
    }

    func test_logging_continues_normally_after_a_trim() {
        let cap = 2_000
        let log = WindowPlacementLog(fileURL: logURL, maxBytes: cap)
        for i in 0..<500 { log.log("win#0", numbered(i)) }
        log.flush()

        log.log("launch", "after-trim")
        log.flush()

        XCTAssertTrue(contents(of: logURL).hasSuffix("after-trim\n"))
        XCTAssertLessThanOrEqual(fileSize(of: logURL), cap)
    }

    func test_a_log_under_the_cap_is_left_untouched() {
        let log = WindowPlacementLog(fileURL: logURL, maxBytes: 100_000)

        for i in 0..<20 { log.log("win#0", numbered(i)) }
        log.flush()

        let text = contents(of: logURL)
        for i in 0..<20 {
            XCTAssertTrue(text.contains(numbered(i)), "\(numbered(i)) should not have been dropped")
        }
    }

    func test_the_default_cap_is_256_kib() {
        XCTAssertEqual(WindowPlacementLog.defaultMaxBytes, 256 * 1024)
    }

    func test_the_default_file_location_is_under_the_users_dot_nostromo_logs_directory() {
        let path = WindowPlacementLog.defaultFileURL.path
        XCTAssertTrue(path.hasSuffix("/.nostromo/logs/window-placement.log"), path)
    }
}
