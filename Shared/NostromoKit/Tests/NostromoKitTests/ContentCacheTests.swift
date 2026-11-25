// NostromoKit — ContentCacheTests.swift
//
// The phone's last-known content on disk (PRD-AC22, Q2, W11-8/9). What these guard:
//   * only an allow-listed handful of frame types is ever written, so mail, calendar and todos
//     (and session transcripts and pane content) cannot reach disk however the caller is written;
//   * `wipe()` leaves no file and nothing queued before it can bring the file back;
//   * writes are debounced and coalesced, and the file is excluded from backup.
//
// FileProtectionType.complete is iOS-only and is asserted by the hosted L5 test, not here.

import XCTest
@testable import NostromoKit

final class ContentCacheTests: XCTestCase {

    // 2027-01-15T08:00:00Z: a whole second, because the snapshot is stored as ISO-8601.
    private let savedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("content-cache.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContentCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dir = directory!
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: Helpers

    private func makeCache(debounce: TimeInterval = 60) -> ContentCache {
        ContentCache(url: url, debounce: debounce, now: { [savedAt] in savedAt })
    }

    private func data(_ json: String) -> Data { Data(json.utf8) }

    private func fileText() throws -> String { try String(contentsOf: url, encoding: .utf8) }

    private var fileExists: Bool { FileManager.default.fileExists(atPath: url.path) }

    private let motherJobs = #"{"type":"mother_jobs","jobs":[{"id":"j1","state":"running","title":"T"}]}"#
    private let sessions = #"{"type":"session_list_resp","sessions":[]}"#
    private let hosts = #"{"type":"hosts","hosts":[{"name":"kobe","egress":"work"}]}"#
    private func perri(_ tag: String, marker: String = "") -> String {
        #"{"type":"perri_state","tag":"\#(tag)","queue":[],"current":null,"m":"\#(marker)"}"#
    }

    // MARK: - Round trip

    func testRecordedFramesAreLoadedBackAfterAFlush() throws {
        let cache = makeCache()
        cache.record(host: nil, raw: data(motherJobs))
        cache.record(host: nil, raw: data(sessions))
        cache.record(host: nil, raw: data(hosts))
        cache.record(host: nil, raw: data(perri("perri")))
        cache.record(host: nil, raw: data(#"{"type":"focus_list_resp","focuses":[]}"#))
        cache.flush()

        let loaded = try XCTUnwrap(makeCache().load())
        XCTAssertEqual(Set(loaded.frames.map(\.type)),
                       ["mother_jobs", "session_list_resp", "hosts", "perri_state", "focus_list_resp"])
        XCTAssertEqual(loaded.frames.first { $0.type == "mother_jobs" }?.json, motherJobs)
    }

    func testThereIsNothingToLoadBeforeAnythingIsWritten() {
        XCTAssertNil(makeCache().load())
    }

    func testAnUnreadableFileLoadsAsNothing() throws {
        try Data("not json".utf8).write(to: url)
        XCTAssertNil(makeCache().load())
    }

    // MARK: - Allow-list

    func testOnlyTheAllowListedTypesAreKept() {
        XCTAssertEqual(ContentCache.cachedTypes,
                       ["mother_jobs", "perri_state", "focus_list_resp", "focus_registry_updated",
                        "session_list_resp", "hosts"])
    }

    func testMailCalendarTodosTranscriptsAndPaneContentAreNeverWritten() throws {
        let cache = makeCache()
        cache.record(host: nil, raw: data(motherJobs))   // something allowed, so a file exists
        cache.record(host: nil, raw: data(#"{"type":"fred_state","mailbox":{"m":"FRED-MARKER"},"calendar":{}}"#))
        cache.record(host: nil, raw: data(#"{"type":"teri_state","todos":{"items":[],"m":"TERI-MARKER"}}"#))
        cache.record(host: nil, raw: data(#"{"type":"pane_content","tag":"t","pane_id":"p","m":"PANE-MARKER"}"#))
        cache.record(host: nil, raw: data(#"{"type":"session_turns","tag":"t","turns":[],"m":"TURNS-MARKER"}"#))
        cache.record(host: "kobe", raw: data(#"{"type":"fred_state","m":"HOSTED-FRED-MARKER"}"#))
        cache.flush()

        let text = try fileText()
        for marker in ["fred_state", "teri_state", "pane_content", "session_turns",
                       "FRED-MARKER", "TERI-MARKER", "PANE-MARKER", "TURNS-MARKER"] {
            XCTAssertFalse(text.contains(marker), "\(marker) reached disk")
        }
        XCTAssertTrue(text.contains("mother_jobs"), "the allowed frame is there")
    }

    func testFramesThatAreNotJSONObjectsOrHaveNoTypeAreIgnored() {
        let cache = makeCache()
        cache.record(host: nil, raw: data("not json"))
        cache.record(host: nil, raw: data("[1,2,3]"))
        cache.record(host: nil, raw: data(#"{"jobs":[]}"#))
        cache.flush()
        XCTAssertFalse(fileExists, "nothing was recorded, so nothing is written")
    }

    // MARK: - Slots

    func testPerriStateIsKeptPerTagAndALaterFrameForATagReplacesIt() throws {
        let cache = makeCache()
        cache.record(host: nil, raw: data(perri("perri", marker: "first")))
        cache.record(host: nil, raw: data(perri("other")))
        cache.record(host: nil, raw: data(perri("perri", marker: "second")))
        cache.flush()

        let frames = try XCTUnwrap(makeCache().load()).frames.filter { $0.type == "perri_state" }
        XCTAssertEqual(frames.count, 2)
        let forPerri = try XCTUnwrap(frames.first { $0.key == "perri" })
        XCTAssertTrue(forPerri.json.contains("second"))
        XCTAssertFalse(forPerri.json.contains("first"))
    }

    func testFocusListAndFocusRegistryUpdateShareOneSlot() throws {
        let cache = makeCache()
        cache.record(host: nil, raw: data(#"{"type":"focus_list_resp","focuses":[],"m":"list"}"#))
        cache.record(host: nil, raw: data(#"{"type":"focus_registry_updated","focuses":[],"m":"update"}"#))
        cache.flush()

        let frames = try XCTUnwrap(makeCache().load()).frames
        XCTAssertEqual(frames.count, 1)
        XCTAssertTrue(frames[0].json.contains("update"), "The registry update is the later word")
    }

    func testHostQualifiedFramesAreKeptPerHost() throws {
        let cache = makeCache()
        cache.record(host: nil, raw: data(#"{"type":"mother_jobs","jobs":[],"m":"primary"}"#))
        cache.record(host: "kobe", raw: data(#"{"type":"mother_jobs","host":"kobe","jobs":[],"m":"kobe"}"#))
        cache.record(host: "studio", raw: data(#"{"type":"mother_jobs","host":"studio","jobs":[],"m":"studio"}"#))
        cache.flush()

        let frames = try XCTUnwrap(makeCache().load()).frames.filter { $0.type == "mother_jobs" }
        XCTAssertEqual(Set(frames.map { $0.host ?? "" }), ["", "kobe", "studio"])
        XCTAssertEqual(frames.count, 3)
    }

    // MARK: - Debounce

    func testRecordingSeveralFramesAndFlushingOnceWritesOneFileWithTheLatest() throws {
        let cache = makeCache(debounce: 60)
        cache.record(host: nil, raw: data(#"{"type":"mother_jobs","jobs":[],"m":"one"}"#))
        cache.record(host: nil, raw: data(#"{"type":"mother_jobs","jobs":[],"m":"two"}"#))
        cache.record(host: nil, raw: data(#"{"type":"mother_jobs","jobs":[],"m":"three"}"#))
        XCTAssertFalse(fileExists, "Writes are debounced: nothing is on disk before the window ends or a flush")

        cache.flush()

        let frames = try XCTUnwrap(makeCache().load()).frames
        XCTAssertEqual(frames.count, 1)
        XCTAssertTrue(frames[0].json.contains("three"))
    }

    func testTheDebounceWindowWritesWithoutAFlush() async throws {
        let cache = makeCache(debounce: 0.05)
        cache.record(host: nil, raw: data(motherJobs))
        let deadline = Date().addingTimeInterval(2)
        while !fileExists && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(fileExists, "A recorded frame is written when the debounce window ends")
    }

    // MARK: - Clock

    func testSavedAtComesFromTheInjectedClock() throws {
        let cache = makeCache()
        cache.record(host: nil, raw: data(motherJobs))
        cache.flush()
        XCTAssertEqual(try XCTUnwrap(makeCache().load()).savedAt, savedAt)
    }

    // MARK: - Backup

    func testTheFileIsExcludedFromBackup() throws {
        let cache = makeCache()
        cache.record(host: nil, raw: data(motherJobs))
        cache.flush()
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    // MARK: - Wipe

    func testWipeDeletesTheFile() throws {
        let cache = makeCache()
        cache.record(host: nil, raw: data(motherJobs))
        cache.flush()
        XCTAssertTrue(fileExists)

        cache.wipe()

        XCTAssertFalse(fileExists)
        XCTAssertNil(makeCache().load())
    }

    func testAFrameRecordedBeforeAWipeCannotRecreateTheFile() {
        let cache = makeCache(debounce: 60)
        cache.record(host: nil, raw: data(motherJobs))
        cache.wipe()
        cache.flush()
        XCTAssertFalse(fileExists, "wipe then flush must leave nothing")
    }

    func testAPendingDebouncedWriteIsCancelledByAWipe() async throws {
        let cache = makeCache(debounce: 0.1)
        cache.record(host: nil, raw: data(motherJobs))
        cache.wipe()
        // Absence can only be observed by waiting past the window the write was scheduled for.
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(fileExists, "A write scheduled before the wipe must not fire after it")
    }

    func testAfterAWipeFreshFramesAreWrittenAgain() throws {
        let cache = makeCache()
        cache.record(host: nil, raw: data(motherJobs))
        cache.flush()
        cache.wipe()
        cache.record(host: nil, raw: data(sessions))
        cache.flush()

        let frames = try XCTUnwrap(makeCache().load()).frames
        XCTAssertEqual(frames.map(\.type), ["session_list_resp"], "Only what arrived after the wipe is kept")
    }
}
