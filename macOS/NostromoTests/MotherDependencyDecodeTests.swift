import XCTest
import Foundation
import NostromoKit

// A job's `depends_on` and `dep_wait` come off disk written by other tools, so they are untrusted: every
// shape decodes quietly, never costs the job, and what is kept is bounded and printable.
final class MotherDependencyDecodeTests: XCTestCase {

    private func decode(_ extra: String) throws -> MotherJob {
        let json = #"{"id":"j9","state":"queued","repo":"r","isolation":"worktree","title":"t"\#(extra)}"#
        return try JSONDecoder().decode(MotherJobSlim.self, from: Data(json.utf8)).toMotherJob()
    }

    private let realWait = """
        {"dep_id":"20261113T221332Z-afae98a4","status":"wait","reason":"pr_open",\
        "pr_url":"https://github.com/o/r/pull/6233","checked_at":"2026-11-13T22:20:00Z"}
        """

    // MARK: - Hostile titles

    private let hostileTitle = "a\u{1B}[31mb\u{0}c\u{85}d\u{2028}e\u{2029}f\u{202E}g\u{2066}h\u{200E}i\u{200B}j\u{200C}k\u{200D}l\u{FEFF}m\nn\tp"

    private func assertClean(_ s: String, file: StaticString = #filePath, line: UInt = #line) {
        for scalar in s.unicodeScalars {
            let v = scalar.value
            let bad = v <= 0x1F || (0x7F...0x9F).contains(v) || v == 0x2028 || v == 0x2029 || v == 0x200E || v == 0x200F
                || (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v)
                || (0x200B...0x200D).contains(v) || v == 0xFEFF
            XCTAssertFalse(bad, "U+\(String(v, radix: 16, uppercase: true)) survived in \(s)", file: file, line: line)
        }
    }

    func testATitleLosesControlBidiAndZeroWidthCharactersWhenDecoded() throws {
        let json = #"{"id":"j9","state":"queued","repo":"r","isolation":"worktree","title":"\#(hostileTitle.unicodeScalars.map { String(format: "\\u%04x", $0.value) }.joined())"}"#
        let job = try JSONDecoder().decode(MotherJobSlim.self, from: Data(json.utf8)).toMotherJob()
        assertClean(job.title)
        XCTAssertTrue(job.title.hasPrefix("a"), job.title)
    }

    func testABoundedDependencyTitleLosesThemToo() {
        assertClean(MotherDependencyPresentation.boundedTitle(hostileTitle))
    }

    func testANormalTitleIsUnchanged() throws {
        let title = "Mother pane: DEPENDS ON section (PR #460) – déjà vu 日本語 🙂"
        XCTAssertEqual(MotherDependencyPresentation.boundedTitle(title), title)
        let json = #"{"id":"j9","state":"queued","repo":"r","isolation":"worktree","title":"\#(title)"}"#
        XCTAssertEqual(try JSONDecoder().decode(MotherJobSlim.self, from: Data(json.utf8)).toMotherJob().title, title)
    }

    // MARK: - Real shapes

    func testDependsOnAndTheRealDepWaitShapeBothDecode() throws {
        let job = try decode(#","depends_on":["20261113T221332Z-afae98a4","j-2"],"dep_wait":\#(realWait)"#)
        XCTAssertEqual(job.dependsOn, ["20261113T221332Z-afae98a4", "j-2"])
        let wait = try XCTUnwrap(job.depWait)
        XCTAssertEqual(wait.depId, "20261113T221332Z-afae98a4")
        XCTAssertEqual(wait.reason, "pr_open")
        XCTAssertEqual(wait.prURL, "https://github.com/o/r/pull/6233")
        XCTAssertFalse(wait.blocked, "status \"wait\" is waiting, not blocked")
    }

    func testStatusBlockedDecodesAsBlocked() throws {
        let job = try decode(#","dep_wait":{"dep_id":"d1","status":"blocked","reason":"dep_failed"}"#)
        let wait = try XCTUnwrap(job.depWait)
        XCTAssertTrue(wait.blocked)
        XCTAssertEqual(wait.reason, "dep_failed")
        XCTAssertNil(wait.prURL)
    }

    func testAbsentKeysGiveNoDependencies() throws {
        let job = try decode("")
        XCTAssertEqual(job.dependsOn, [])
        XCTAssertNil(job.depWait)
    }

    // MARK: - Malformed input never costs the job

    func testMalformedDependencyDataDecodesQuietlyAndTheJobStillDecodes() throws {
        let cases: [(String, [String], Bool)] = [
            (#","depends_on":"x""#, [], false),
            (#","depends_on":null"#, [], false),
            (#","depends_on":{"a":1}"#, [], false),
            (#","depends_on":[1,null,"a"]"#, ["a"], false),
            (#","depends_on":[["nested"],true,"b"]"#, ["b"], false),
            (#","dep_wait":"x""#, [], false),
            (#","dep_wait":null"#, [], false),
            (#","dep_wait":{}"#, [], false),
            (#","dep_wait":[]"#, [], false),
            (#","dep_wait":{"dep_id":7}"#, [], false),
            (#","dep_wait":{"dep_id":""}"#, [], false),
        ]
        for (extra, expectedIds, hasWait) in cases {
            let job = try decode(extra)
            XCTAssertEqual(job.id, "j9", extra)
            XCTAssertEqual(job.dependsOn, expectedIds, extra)
            XCTAssertEqual(job.depWait != nil, hasWait, extra)
        }
    }

    func testADepWaitWithWrongTypedFieldsKeepsTheIdAndDropsTheRest() throws {
        let job = try decode(#","dep_wait":{"dep_id":"d1","status":3,"reason":[1],"pr_url":false}"#)
        let wait = try XCTUnwrap(job.depWait)
        XCTAssertEqual(wait.depId, "d1")
        XCTAssertFalse(wait.blocked)
        XCTAssertEqual(wait.reason, "")
        XCTAssertNil(wait.prURL)
    }

    // MARK: - Bounds and cleaning

    func testOverLongIdReasonAndUrlAreBounded() throws {
        let longId = String(repeating: "a", count: 200)
        let longReason = String(repeating: "r", count: 200)
        let longURL = "https://github.com/o/r/pull/1" + String(repeating: "9", count: 600)
        let job = try decode(#","depends_on":["\#(longId)"],"dep_wait":{"dep_id":"\#(longId)","reason":"\#(longReason)","pr_url":"\#(longURL)"}"#)
        XCTAssertEqual(job.dependsOn.first?.count, 64)
        let wait = try XCTUnwrap(job.depWait)
        XCTAssertEqual(wait.depId.count, 64)
        XCTAssertEqual(wait.reason.count, 64)
        XCTAssertEqual(wait.prURL?.count, 300)
    }

    func testControlCharactersAreRemovedFromEveryKeptString() throws {
        let job = try decode(#","depends_on":["a\u0007b\nc\u001b[31m"],"dep_wait":{"dep_id":"x\ty\u0000z","reason":"pr\u0007_open","pr_url":"https://h/pull/1\n2"}"#)
        func clean(_ s: String) -> Bool { !s.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
        XCTAssertTrue(job.dependsOn.allSatisfy(clean), "\(job.dependsOn)")
        XCTAssertFalse(job.dependsOn.isEmpty)
        let wait = try XCTUnwrap(job.depWait)
        XCTAssertTrue(clean(wait.depId) && clean(wait.reason) && clean(wait.prURL ?? ""), "\(wait)")
        XCTAssertEqual(wait.reason, "pr_open")
    }

    func testSixtyIdsKeepFifty() throws {
        let ids = (0..<60).map { "\"dep-\($0)\"" }.joined(separator: ",")
        let job = try decode(#","depends_on":[\#(ids)]"#)
        XCTAssertEqual(job.dependsOn.count, 50)
        XCTAssertEqual(job.dependsOn.first, "dep-0", "the first ones are kept, in order")
        XCTAssertEqual(job.dependsOn.last, "dep-49")
    }

    func testIdsAreTrimmedAndDuplicatesCollapsed() throws {
        let job = try decode(#","depends_on":["  a ","a","b","","   ","b ","c"]"#)
        XCTAssertEqual(job.dependsOn, ["a", "b", "c"])
    }

    // MARK: - Event fold

    func testAStateChangeAwayFromQueuedKeepsDependsOnAndDropsDepWait() throws {
        let store = AppStore.shared
        addTeardownBlock { store.applyBrokerEventForTesting(.snapshot([])) }
        var queued = MotherJob(id: "fold-1", state: "queued", repo: "r", isolation: "none", title: "t",
                               createdAt: Date(), startedAt: nil, finishedAt: nil, planPath: nil,
                               question: nil, pausedReason: nil, adherenceStatus: nil, currentTier: nil)
        queued.dependsOn = ["dep-a", "dep-b"]
        queued.depWait = MotherDepWait(depId: "dep-a", blocked: false, reason: "pr_open", prURL: nil)

        func current() -> MotherJob? { store.motherJobs.first { $0.id == "fold-1" } }
        func settle(_ done: () -> Bool) {
            let deadline = Date().addingTimeInterval(3)
            while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }

        store.applyBrokerEventForTesting(.snapshot([queued]))
        settle { current() != nil }
        XCTAssertEqual(current()?.depWait?.depId, "dep-a", "precondition: a queued job keeps its dep_wait")

        store.applyBrokerEventForTesting(.stateChange(jobId: "fold-1", eventKind: "running",
                                                      question: nil, pausedReason: nil, toState: nil))
        settle { current()?.state == "running" }
        XCTAssertEqual(current()?.state, "running")
        XCTAssertEqual(current()?.dependsOn, ["dep-a", "dep-b"], "the dependencies stay")
        XCTAssertNil(current()?.depWait, "nothing waits once the job has left the queue")
    }
}
