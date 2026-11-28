// NostromoKit — ContentCacheHostedTests.swift
//
// What the content cache keeps of a satellite host's frames (W11 slice 2): its Focuses and Perri
// state, and the decisions and approval counts it holds for the operator. What these guard:
//   * a decision or approval frame is kept ONLY when it names a host, keyed per (host, request id)
//     or (host, tag), so two hosts never overwrite one another; the same frame with no host (the
//     primary's own) never reaches disk;
//   * `decision_resolved` for a host removes that host's decision, from memory and from disk (the
//     file goes when nothing else is held); with no host, or for another host, it changes nothing;
//   * a work-shaped frame is stored as its own JSON and nothing else is added;
//   * nothing else the primary does not cache (mail, calendar, todos) becomes cacheable because a
//     host name is attached;
//   * `wipe()` still deletes everything once hosted frames have been recorded.
//
// The allow-list for frames without a host (`cachedTypes`) is pinned by `ContentCacheTests`.

import XCTest
@testable import NostromoKit

final class ContentCacheHostedTests: XCTestCase {

    // 2027-01-15T08:00:00Z: a whole second, because the snapshot is stored as ISO-8601.
    private let savedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("content-cache.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContentCacheHostedTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dir = directory!
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: Helpers

    private func makeCache() -> ContentCache {
        ContentCache(url: url, debounce: 60, now: { [savedAt] in savedAt })
    }

    private var fileExists: Bool { FileManager.default.fileExists(atPath: url.path) }
    private func fileText() -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    private func data(_ json: String) -> Data { Data(json.utf8) }

    private func decisionRequest(_ id: String, tag: String = "cody-1", marker: String = "") -> String {
        #"{"type":"decision_request","tag":"\#(tag)","request_id":"\#(id)","prompt":"\#(marker)","choices":[]}"#
    }
    private func decisionResolved(_ id: String, tag: String = "cody-1") -> String {
        #"{"type":"decision_resolved","tag":"\#(tag)","request_id":"\#(id)","resolution":"answered"}"#
    }
    private func approval(_ tag: String, count: Int = 1) -> String {
        #"{"type":"approval_pending","tag":"\#(tag)","count":\#(count)}"#
    }
    private func perri(_ tag: String, marker: String = "") -> String {
        #"{"type":"perri_state","tag":"\#(tag)","queue":[],"current":null,"m":"\#(marker)"}"#
    }
    private let focusList = #"{"type":"focus_list_resp","focuses":[]}"#
    private let focusRegistry = #"{"type":"focus_registry_updated","focuses":[]}"#
    private let motherJobs = #"{"type":"mother_jobs","jobs":[{"id":"j1","state":"running","title":"T"}]}"#

    private struct Slot: Hashable, CustomStringConvertible {
        let type: String
        let host: String?
        let key: String?
        var description: String { "\(type)|\(host ?? "-")|\(key ?? "-")" }
    }

    /// What the file holds, as (type, host, key) slots, read the way a relaunch reads it.
    private func slots() throws -> Set<Slot> {
        let snapshot = try XCTUnwrap(makeCache().load(), "the cache file should hold a snapshot")
        return Set(snapshot.frames.map { Slot(type: $0.type, host: $0.host, key: $0.key) })
    }

    private func repoRootFixture(_ name: String) throws -> Data {
        var root = URL(fileURLWithPath: "\(#filePath)")
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let file = root.appendingPathComponent("tests/fixtures/hosts/\(name)")
        guard FileManager.default.fileExists(atPath: file.path) else {
            XCTFail("fixture not found at \(file.path)")
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: file)
    }

    // MARK: - The allow-lists

    func testTheHostedOnlyTypesAreExactlyDecisionRequestAndApprovalPending() {
        XCTAssertEqual(ContentCache.hostedOnlyTypes, ["decision_request", "approval_pending"])
    }

    func testNothingHostedOnlyOrResolvedIsOnTheAllowListForFramesWithoutAHost() {
        for type in ["decision_request", "approval_pending", "decision_resolved"] {
            XCTAssertFalse(ContentCache.cachedTypes.contains(type), "\(type) must not be cacheable without a host")
        }
        XCTAssertEqual(ContentCache.cachedTypes,
                       ["mother_jobs", "perri_state", "focus_list_resp", "focus_registry_updated",
                        "session_list_resp", "hosts"], "The original allow-list is unchanged")
    }

    // MARK: - Hosted decisions and approvals are kept per host

    func testAHostsDecisionsAndApprovalsAreKeptPerHostAndRequestIdOrTag() throws {
        let cache = makeCache()
        cache.record(host: "kobe", raw: data(decisionRequest("req-1", tag: "f-1")))
        cache.record(host: "kobe", raw: data(decisionRequest("req-2", tag: "f-2")))
        cache.record(host: "studio", raw: data(decisionRequest("req-1", tag: "cody-1")))
        cache.record(host: "kobe", raw: data(approval("f-1")))
        cache.record(host: "kobe", raw: data(approval("f-2")))
        cache.record(host: "studio", raw: data(approval("f-1")))
        cache.flush()

        XCTAssertEqual(try slots(), [
            Slot(type: "decision_request", host: "kobe", key: "req-1"),
            Slot(type: "decision_request", host: "kobe", key: "req-2"),
            Slot(type: "decision_request", host: "studio", key: "req-1"),
            Slot(type: "approval_pending", host: "kobe", key: "f-1"),
            Slot(type: "approval_pending", host: "kobe", key: "f-2"),
            Slot(type: "approval_pending", host: "studio", key: "f-1"),
        ])
    }

    func testTheSameHostAndKeyIsReplacedByTheLaterFrame() throws {
        let cache = makeCache()
        cache.record(host: "kobe", raw: data(approval("f-1", count: 1)))
        cache.record(host: "kobe", raw: data(approval("f-1", count: 4)))
        cache.record(host: "kobe", raw: data(decisionRequest("req-1", marker: "OLD")))
        cache.record(host: "kobe", raw: data(decisionRequest("req-1", marker: "NEW")))
        cache.flush()

        let snapshot = try XCTUnwrap(makeCache().load())
        XCTAssertEqual(snapshot.frames.count, 2)
        XCTAssertTrue(try XCTUnwrap(snapshot.frames.first { $0.type == "approval_pending" }).json.contains(#""count":4"#))
        let decision = try XCTUnwrap(snapshot.frames.first { $0.type == "decision_request" })
        XCTAssertTrue(decision.json.contains("NEW"))
        XCTAssertFalse(decision.json.contains("OLD"))
    }

    func testTheSameFramesWithNoHostAreNeverWritten() throws {
        let cache = makeCache()
        cache.record(host: nil, raw: data(decisionRequest("req-1", marker: "PRIMARY-DECISION-MARKER")))
        cache.record(host: nil, raw: data(approval("cody-1", count: 7)))
        cache.record(host: nil, raw: data(perri("perri")))   // proves the file is written at all
        cache.flush()

        XCTAssertEqual(try slots(), [Slot(type: "perri_state", host: nil, key: "perri")])
        XCTAssertFalse(fileText().contains("PRIMARY-DECISION-MARKER"), "The primary's own decision never reaches disk")
        XCTAssertFalse(fileText().contains("approval_pending"))
    }

    func testFramesWithNoHostAloneLeaveNoFile() {
        let cache = makeCache()
        cache.record(host: nil, raw: data(decisionRequest("req-1")))
        cache.record(host: nil, raw: data(approval("cody-1")))
        cache.flush()

        XCTAssertFalse(fileExists)
    }

    // MARK: - decision_resolved

    func testAResolvedDecisionForAHostIsRemovedAndTheFileGoesWhenNothingElseIsHeld() throws {
        let cache = makeCache()
        cache.record(host: "kobe", raw: data(decisionRequest("req-1")))
        cache.flush()
        XCTAssertTrue(fileExists, "the decision must reach disk first")

        cache.record(host: "kobe", raw: data(decisionResolved("req-1")))
        cache.flush()

        XCTAssertFalse(fileExists, "A resolved decision must not outlive its resolution on disk")
        XCTAssertNil(makeCache().load())
    }

    func testAResolvedDecisionIsRemovedFromAFileThatHoldsOtherFrames() throws {
        let cache = makeCache()
        cache.record(host: nil, raw: data(perri("perri")))
        cache.record(host: "kobe", raw: data(decisionRequest("req-1", marker: "RESOLVED-MARKER")))
        cache.record(host: "kobe", raw: data(decisionRequest("req-2")))
        cache.record(host: "kobe", raw: data(approval("cody-1")))
        cache.flush()

        cache.record(host: "kobe", raw: data(decisionResolved("req-1")))
        cache.flush()

        XCTAssertEqual(try slots(), [
            Slot(type: "perri_state", host: nil, key: "perri"),
            Slot(type: "decision_request", host: "kobe", key: "req-2"),
            Slot(type: "approval_pending", host: "kobe", key: "cody-1"),
        ], "Only the resolved request goes, not its host's other decision or approvals")
        XCTAssertFalse(fileText().contains("RESOLVED-MARKER"))
    }

    func testAResolvedDecisionWithNoHostChangesNothing() throws {
        let cache = makeCache()
        cache.record(host: "kobe", raw: data(decisionRequest("req-1")))
        cache.flush()

        cache.record(host: nil, raw: data(decisionResolved("req-1")))
        cache.flush()

        XCTAssertEqual(try slots(), [Slot(type: "decision_request", host: "kobe", key: "req-1")],
                       "The primary resolving its own request says nothing about a satellite's")
    }

    func testAResolvedIdForOneHostDoesNotRemoveAnotherHostsDecisionWithTheSameId() throws {
        let cache = makeCache()
        cache.record(host: "kobe", raw: data(decisionRequest("req-0a1b2c3d", tag: "f-48a0007a")))
        cache.record(host: "studio", raw: data(decisionRequest("req-0a1b2c3d", tag: "cody-1a2b3c4d")))
        cache.flush()

        cache.record(host: "kobe", raw: data(decisionResolved("req-0a1b2c3d", tag: "f-48a0007a")))
        cache.flush()

        XCTAssertEqual(try slots(), [Slot(type: "decision_request", host: "studio", key: "req-0a1b2c3d")])
    }

    func testAResolutionForAnIdNothingHoldsChangesNothingAndLeavesTheFile() throws {
        let cache = makeCache()
        cache.record(host: "kobe", raw: data(decisionRequest("req-1")))
        cache.flush()

        cache.record(host: "kobe", raw: data(decisionResolved("req-unknown")))
        cache.record(host: "studio", raw: data(decisionResolved("req-1")))
        cache.flush()

        XCTAssertEqual(try slots(), [Slot(type: "decision_request", host: "kobe", key: "req-1")])
    }

    func testAResolutionIsNeverStoredAsAFrame() throws {
        let cache = makeCache()
        cache.record(host: "kobe", raw: data(perri("f-1")))
        cache.record(host: "kobe", raw: data(decisionResolved("req-1")))
        cache.flush()

        XCTAssertEqual(try slots(), [Slot(type: "perri_state", host: "kobe", key: "f-1")])
        XCTAssertFalse(fileText().contains("decision_resolved"))
    }

    func testAResolvedDecisionIsAbsentAfterARelaunchThatThenSeesItsResolution() throws {
        let first = makeCache()
        first.record(host: "kobe", raw: data(decisionRequest("req-1")))
        first.record(host: "studio", raw: data(decisionRequest("req-2")))
        first.flush()

        // The app relaunches (reads the file), then the host reports req-1 resolved.
        let relaunched = makeCache()
        XCTAssertEqual(try XCTUnwrap(relaunched.load()).frames.count, 2)
        relaunched.record(host: "kobe", raw: data(decisionResolved("req-1")))
        relaunched.flush()

        XCTAssertEqual(try slots(), [Slot(type: "decision_request", host: "studio", key: "req-2")])
    }

    // MARK: - Perri and focus frames of a host

    func testAHostsPerriStateIsKeptPerHostAndPerTagBesideThePrimarys() throws {
        let cache = makeCache()
        cache.record(host: nil, raw: data(perri("t1")))
        cache.record(host: "kobe", raw: data(perri("t1")))
        cache.record(host: "kobe", raw: data(perri("t2")))
        cache.record(host: "studio", raw: data(perri("t1")))
        cache.flush()

        XCTAssertEqual(try slots(), [
            Slot(type: "perri_state", host: nil, key: "t1"),
            Slot(type: "perri_state", host: "kobe", key: "t1"),
            Slot(type: "perri_state", host: "kobe", key: "t2"),
            Slot(type: "perri_state", host: "studio", key: "t1"),
        ])
    }

    func testAHostsFocusListIsKeptPerHostAndARegistryUpdateReplacesIt() throws {
        let cache = makeCache()
        cache.record(host: nil, raw: data(focusList))
        cache.record(host: "kobe", raw: data(focusList))
        cache.record(host: "studio", raw: data(focusList))
        cache.record(host: "kobe", raw: data(focusRegistry))
        cache.flush()

        XCTAssertEqual(try slots(), [
            Slot(type: "focus_list_resp", host: nil, key: nil),
            Slot(type: "focus_list_resp", host: "kobe", key: nil),
            Slot(type: "focus_list_resp", host: "studio", key: nil),
        ], "A registry update shares its host's focus list slot")
    }

    // MARK: - Nothing else becomes cacheable

    func testAHostNameDoesNotMakeMailCalendarTodosOrTranscriptsCacheable() throws {
        let cache = makeCache()
        let frames = [
            #"{"type":"fred_state","mailbox":{"unread_count":0,"items":[],"stale":false},"calendar":{"events":[],"sweater":"sage","stale":false}}"#,
            #"{"type":"teri_state","todos":{"items":[],"stale":false}}"#,
            #"{"type":"session_turns","tag":"cody-1","turns":[]}"#,
            #"{"type":"pane_content","tag":"cody-1","pane_id":"p"}"#,
            #"{"type":"mother_peek","job_id":"j1","todos":[]}"#,
        ]
        for frame in frames { cache.record(host: "kobe", raw: data(frame)) }
        cache.record(host: "kobe", raw: data(perri("f-1")))   // proves the file is written at all
        cache.flush()

        XCTAssertEqual(try slots(), [Slot(type: "perri_state", host: "kobe", key: "f-1")])
        let text = fileText()
        for type in ["fred_state", "teri_state", "session_turns", "pane_content", "mother_peek"] {
            XCTAssertFalse(text.contains(type), "\(type) must not reach disk")
        }
    }

    func testAWorkShapedFrameIsStoredAsItsOwnJsonAndNothingIsAddedToIt() throws {
        let raw = try repoRootFixture("decision_request.work.json")
        let hosted = ServerMsg.decodeHosted(from: raw)
        XCTAssertEqual(hosted.host, "kobe")

        let cache = makeCache()
        cache.record(host: hosted.host, raw: raw)
        cache.flush()

        let snapshot = try XCTUnwrap(makeCache().load())
        XCTAssertEqual(snapshot.frames.count, 1)
        let frame = try XCTUnwrap(snapshot.frames.first)
        XCTAssertEqual(frame.json, String(data: raw, encoding: .utf8), "Exactly the JSON the host sent")
        XCTAssertEqual(frame.type, "decision_request")
        XCTAssertEqual(frame.host, "kobe")
        XCTAssertEqual(frame.key, "req-0a1b2c3d")
        XCTAssertEqual(snapshot.savedAt, savedAt)
    }

    func testTheRealHostedFixturesAreAllKeptUnderTheirHostAndNothingOfThePersonalOnesLeaksIntoTheWorkOnes() throws {
        let cache = makeCache()
        for kind in ["work", "personal"] {
            for name in ["perri_state", "focus_registry_updated", "decision_request", "approval_pending"] {
                let raw = try repoRootFixture("\(name).\(kind).json")
                cache.record(host: ServerMsg.decodeHosted(from: raw).host, raw: raw)
            }
        }
        cache.flush()

        XCTAssertEqual(try slots(), [
            Slot(type: "perri_state", host: "kobe", key: "f-33acb7de"),
            Slot(type: "focus_list_resp", host: "kobe", key: nil),
            Slot(type: "decision_request", host: "kobe", key: "req-0a1b2c3d"),
            Slot(type: "approval_pending", host: "kobe", key: "f-48a0007a"),
            Slot(type: "perri_state", host: "studio", key: "perri"),
            Slot(type: "focus_list_resp", host: "studio", key: nil),
            Slot(type: "decision_request", host: "studio", key: "req-0a1b2c3d"),
            Slot(type: "approval_pending", host: "studio", key: "cody-1a2b3c4d"),
        ])
        let snapshot = try XCTUnwrap(makeCache().load())
        for frame in snapshot.frames where frame.host == "kobe" {
            XCTAssertFalse(frame.json.contains("carefeed"), "Kobe's frame is kobe's own JSON: \(frame.type)")
            XCTAssertFalse(frame.json.contains("Ship the export"), "Kobe's frame is kobe's own JSON: \(frame.type)")
        }
    }

    // MARK: - wipe

    func testWipeDeletesHostedFramesToo() throws {
        let cache = makeCache()
        cache.record(host: "kobe", raw: data(decisionRequest("req-1")))
        cache.record(host: "kobe", raw: data(approval("f-1")))
        cache.record(host: "kobe", raw: data(perri("f-1")))
        cache.flush()
        XCTAssertTrue(fileExists)

        cache.wipe()

        XCTAssertFalse(fileExists)
        XCTAssertNil(makeCache().load())
        cache.flush()
        XCTAssertFalse(fileExists, "Nothing recorded before the wipe comes back")
    }

    func testAHostedFramePendingWhenWipeRunsIsNeverWritten() throws {
        let cache = makeCache()
        cache.record(host: "kobe", raw: data(decisionRequest("req-1", marker: "PENDING-MARKER")))

        cache.wipe()
        cache.flush()

        XCTAssertFalse(fileExists)
        XCTAssertFalse(fileText().contains("PENDING-MARKER"))
    }
}
