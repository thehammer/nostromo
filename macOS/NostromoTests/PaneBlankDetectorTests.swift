import XCTest
import AppKit
import Combine

// A Claude transcript pane (`ReplView`) sometimes goes blank, then redraws. Detection and
// capture only: four rules notice the blank, a content-free JSON capture is written once per
// incident, and a manual "Capture render state now" always works.
//
// Part 1 tests the pure detector (no windows, no clocks: time is passed in).
// Part 2 tests the capture file helpers.
// Part 3 drives a REAL `ReplView` in an offscreen window, delivering turns the way the daemon
// does, and drives time with explicit `nowMs` / `wall` arguments (never sleeping).
final class PaneBlankDetectorTests: XCTestCase {

    // MARK: - Detector fixtures

    private func sample(_ nowMs: Double,
                        visible: Bool = true,
                        turns: Int = 10,
                        views: Int = 0,
                        docHeight: Double = 5000,
                        viewport: Double = 800,
                        clears: Int = 0) -> PaneBlankDetector.Sample {
        PaneBlankDetector.Sample(nowMs: nowMs, isVisible: visible, retainedTurns: turns,
                                 visibleTurnViews: views, documentHeight: docHeight,
                                 viewportHeight: viewport, transcriptClears: clears)
    }

    /// An evaluation that sees turns retained, on screen, with nothing materialized in view.
    private func empty(_ t: Double) -> PaneBlankDetector.Sample { sample(t, views: 0) }
    /// A healthy evaluation: turn views are in the visible region.
    private func healthy(_ t: Double) -> PaneBlankDetector.Sample { sample(t, views: 3) }

    private func rules(_ hits: [PaneBlankDetector.Hit]) -> [PaneBlankDetector.Rule] { hits.map(\.rule) }

    // MARK: - Rule (a): empty viewport

    func testAnEmptyVisibleRegionSeenForThreeEvaluationsOverAtLeast300msIsABlank() {
        var detector = PaneBlankDetector()
        XCTAssertEqual(rules(detector.evaluate(empty(0))), [])
        XCTAssertEqual(rules(detector.evaluate(empty(150))), [])
        let hits = detector.evaluate(empty(350))
        XCTAssertEqual(rules(hits), [.emptyViewport])
        XCTAssertEqual(hits.first?.severity, .blank)
    }

    func testTwoEmptyEvaluationsAreNotEnough() {
        var detector = PaneBlankDetector()
        XCTAssertEqual(rules(detector.evaluate(empty(0))), [])
        XCTAssertEqual(rules(detector.evaluate(empty(1000))), [], "two sightings, however far apart, are not three")
    }

    func testThreeEmptyEvaluationsInsideLessThan300msAreNotYetABlank() {
        var detector = PaneBlankDetector()
        XCTAssertEqual(rules(detector.evaluate(empty(0))), [])
        XCTAssertEqual(rules(detector.evaluate(empty(100))), [])
        XCTAssertEqual(rules(detector.evaluate(empty(200))), [], "span 200 ms is below the 300 ms minimum")
        XCTAssertEqual(rules(detector.evaluate(empty(300))), [.emptyViewport], "span reaches 300 ms: now it is a blank")
    }

    func testABlankFiresOnceAndNotAgainUntilTheRegionHasBeenSeenNonEmpty() {
        var detector = PaneBlankDetector()
        _ = detector.evaluate(empty(0))
        _ = detector.evaluate(empty(150))
        XCTAssertEqual(rules(detector.evaluate(empty(350))), [.emptyViewport])
        XCTAssertEqual(rules(detector.evaluate(empty(500))), [], "same incident")
        XCTAssertEqual(rules(detector.evaluate(empty(650))), [], "same incident")
        XCTAssertEqual(rules(detector.evaluate(empty(5000))), [], "same incident, however long it lasts")

        XCTAssertEqual(rules(detector.evaluate(healthy(5100))), [], "the pane redrew")
        _ = detector.evaluate(empty(6000))
        _ = detector.evaluate(empty(6150))
        XCTAssertEqual(rules(detector.evaluate(empty(6350))), [.emptyViewport], "a new incident is a new hit")
    }

    func testATransientSingleEmptyEvaluationIsNotABlank() {
        var detector = PaneBlankDetector()
        XCTAssertEqual(rules(detector.evaluate(healthy(0))), [])
        XCTAssertEqual(rules(detector.evaluate(empty(250))), [], "one empty frame between healthy ones")
        XCTAssertEqual(rules(detector.evaluate(healthy(500))), [])
        XCTAssertEqual(rules(detector.evaluate(empty(750))), [])
        XCTAssertEqual(rules(detector.evaluate(healthy(1000))), [])
        XCTAssertEqual(rules(detector.evaluate(empty(1250))), [])
        XCTAssertEqual(rules(detector.evaluate(empty(1500))), [], "never three empty in a row")
        XCTAssertEqual(rules(detector.evaluate(healthy(1750))), [])
    }

    func testAPaneThatIsNotOnScreenIsNeverBlank() {
        var detector = PaneBlankDetector()
        for t in stride(from: 0.0, through: 3000, by: 250) {
            XCTAssertEqual(rules(detector.evaluate(sample(t, visible: false, views: 0))), [],
                           "a hidden tab or occluded window legitimately has nothing in view (t=\(t))")
        }
    }

    func testAGenuinelyEmptyTranscriptIsNeverBlank() {
        var detector = PaneBlankDetector()
        for t in stride(from: 0.0, through: 3000, by: 250) {
            XCTAssertEqual(rules(detector.evaluate(sample(t, turns: 0, views: 0, docHeight: 0))), [],
                           "nothing to show is not a blank (t=\(t))")
        }
    }

    func testNormalScrollingAndStreamingWithTurnViewsInViewIsNeverBlank() {
        var detector = PaneBlankDetector()
        for (i, t) in stride(from: 0.0, through: 3000, by: 100).enumerated() {
            XCTAssertEqual(rules(detector.evaluate(sample(t, views: 1 + i % 4, docHeight: 5000 + Double(i) * 30))), [])
        }
    }

    func testLeavingTheScreenInTheMiddleOfARunStartsTheCountAgain() {
        var detector = PaneBlankDetector()
        _ = detector.evaluate(empty(0))
        _ = detector.evaluate(empty(200))
        _ = detector.evaluate(sample(250, visible: false, views: 0))
        XCTAssertEqual(rules(detector.evaluate(empty(400))), [], "the earlier sightings no longer count")
        XCTAssertEqual(rules(detector.evaluate(empty(500))), [])
        XCTAssertEqual(rules(detector.evaluate(empty(800))), [.emptyViewport], "three fresh sightings over 400 ms")
    }

    func testAnEmptyViewportDuringADeliberateShedIsNotABlankUntilItOutlastsTwoSeconds() {
        var detector = PaneBlankDetector()
        func shedding(_ t: Double) -> PaneBlankDetector.Sample {
            var s = empty(t)
            s.shedInFlight = true
            return s
        }
        XCTAssertEqual(PaneBlankDetector.emptyViewportShedGraceMs, 2_000)
        // Far more than three evaluations over far more than 300 ms: still expected, a shed is in flight.
        for t in stride(from: 0.0, through: 1_900, by: 100) { XCTAssertTrue(detector.evaluate(shedding(t)).isEmpty, "t=\(t)") }
        // The blank outlasted the bound: now it is one.
        XCTAssertEqual(rules(detector.evaluate(shedding(2_000))), [.emptyViewport])
    }

    func testTheSameEmptyViewportWithNoShedInFlightFiresAtThreeHundredMilliseconds() {
        var detector = PaneBlankDetector()
        XCTAssertTrue(detector.evaluate(empty(0)).isEmpty)
        XCTAssertTrue(detector.evaluate(empty(150)).isEmpty)
        XCTAssertEqual(rules(detector.evaluate(empty(350))), [.emptyViewport])
    }

    func testAnEmptyRunThatBeganDuringAShedStaysUnderTheGraceAfterTheCompactionLands() {
        var detector = PaneBlankDetector()
        var shedding = empty(0)
        shedding.shedInFlight = true
        XCTAssertTrue(detector.evaluate(shedding).isEmpty)
        shedding.nowMs = 500
        XCTAssertTrue(detector.evaluate(shedding).isEmpty)
        // The compaction landed (flag false) but the rebuild pass has not run yet: still the shed's blank.
        for t in [600.0, 700, 900, 1_200, 1_900] { XCTAssertTrue(detector.evaluate(empty(t)).isEmpty, "t=\(t)") }
        XCTAssertEqual(rules(detector.evaluate(empty(2_000))), [.emptyViewport], "outlasting two seconds is a blank")
    }

    func testTheShedGraceDoesNotLeakIntoALaterEmptyRun() {
        var detector = PaneBlankDetector()
        var shedding = empty(0)
        shedding.shedInFlight = true
        _ = detector.evaluate(shedding)
        XCTAssertTrue(detector.evaluate(healthy(100)).isEmpty)   // the rebuild landed: the run is over
        XCTAssertTrue(detector.evaluate(empty(1_000)).isEmpty)
        XCTAssertTrue(detector.evaluate(empty(1_150)).isEmpty)
        XCTAssertEqual(rules(detector.evaluate(empty(1_350))), [.emptyViewport], "an ordinary blank fires at 300 ms again")
    }

    func testAShedThatLandsAndFillsTheViewportNeverFires() {
        var detector = PaneBlankDetector()
        var s = empty(0)
        s.shedInFlight = true
        for t in stride(from: 0.0, through: 1_000, by: 100) { s.nowMs = t; XCTAssertTrue(detector.evaluate(s).isEmpty) }
        XCTAssertTrue(detector.evaluate(healthy(1_100)).isEmpty)
        for t in stride(from: 1_200.0, through: 4_000, by: 100) { XCTAssertTrue(detector.evaluate(healthy(t)).isEmpty) }
    }

    // MARK: - Rule (b): height collapse and recovery

    /// Establishes a stable height of `height` over two evaluations.
    private func stable(_ detector: inout PaneBlankDetector, height: Double = 5000, viewport: Double = 800,
                        turns: Int = 10, at t: Double = 0) {
        _ = detector.evaluate(sample(t, turns: turns, views: 3, docHeight: height, viewport: viewport))
        _ = detector.evaluate(sample(t + 100, turns: turns, views: 3, docHeight: height, viewport: viewport))
    }

    func testAHeightThatCollapsesBelowHalfAndBelowTheViewportThenRecoversIsABlank() {
        var detector = PaneBlankDetector()
        stable(&detector)
        XCTAssertEqual(rules(detector.evaluate(sample(200, views: 3, docHeight: 100))), [], "collapse alone is not yet a hit")
        XCTAssertEqual(rules(detector.evaluate(sample(400, views: 3, docHeight: 100))), [])
        let hits = detector.evaluate(sample(900, views: 3, docHeight: 5000))
        XCTAssertEqual(rules(hits), [.heightCollapse], "it came back: the collapse was not real")
        XCTAssertEqual(hits.first?.severity, .blank)
    }

    func testRecoveryToHalfOfTheOldHeightCounts() {
        var detector = PaneBlankDetector()
        stable(&detector)
        _ = detector.evaluate(sample(200, views: 3, docHeight: 100))
        XCTAssertEqual(rules(detector.evaluate(sample(500, views: 3, docHeight: 2600))), [.heightCollapse])
    }

    func testACollapseThatStaysCollapsedForMoreThanTenSecondsIsAGenuineShrink() {
        var detector = PaneBlankDetector()
        stable(&detector)
        XCTAssertEqual(rules(detector.evaluate(sample(200, views: 3, docHeight: 100))), [])
        XCTAssertEqual(rules(detector.evaluate(sample(11_000, views: 3, docHeight: 100))), [], "still small after 10 s")
        XCTAssertEqual(rules(detector.evaluate(sample(11_500, views: 3, docHeight: 5000))), [],
                       "growing back much later is not the blank-then-redraw signature")
    }

    func testACollapseAccompaniedByATranscriptClearIsAGenuineClear() {
        var detector = PaneBlankDetector()
        stable(&detector)
        XCTAssertEqual(rules(detector.evaluate(sample(200, views: 3, docHeight: 100))), [])
        XCTAssertEqual(rules(detector.evaluate(sample(300, views: 3, docHeight: 100, clears: 1))), [],
                       "the user cleared the transcript")
        XCTAssertEqual(rules(detector.evaluate(sample(500, views: 3, docHeight: 5000, clears: 1))), [])
    }

    func testAClearedTranscriptWithNoTurnsLeftIsNotACollapse() {
        var detector = PaneBlankDetector()
        stable(&detector)
        XCTAssertEqual(rules(detector.evaluate(sample(200, turns: 0, views: 0, docHeight: 0))), [])
        XCTAssertEqual(rules(detector.evaluate(sample(500, turns: 10, views: 3, docHeight: 5000))), [])
    }

    func testAReflowThatTheCallerRebaselinedIsNotACollapse() {
        var detector = PaneBlankDetector()
        stable(&detector)
        detector.rebaselineHeight()                                  // a width change or fold toggle
        XCTAssertEqual(rules(detector.evaluate(sample(200, views: 3, docHeight: 100))), [])
        XCTAssertEqual(rules(detector.evaluate(sample(500, views: 3, docHeight: 5000))), [],
                       "after a rebaseline the small height is the new normal, not a collapse")
    }

    func testRebaseliningWhileACollapseIsArmedDisarmsIt() {
        var detector = PaneBlankDetector()
        stable(&detector)
        XCTAssertEqual(rules(detector.evaluate(sample(200, views: 3, docHeight: 100))), [])
        detector.rebaselineHeight()
        XCTAssertEqual(rules(detector.evaluate(sample(500, views: 3, docHeight: 5000))), [])
    }

    func testADropThatStaysAboveTheViewportIsNotACollapse() {
        var detector = PaneBlankDetector()
        stable(&detector, height: 5000, viewport: 800)
        // 5000 -> 900 is a drop of more than half, but the document still fills the viewport.
        XCTAssertEqual(rules(detector.evaluate(sample(200, views: 3, docHeight: 900, viewport: 800))), [])
        XCTAssertEqual(rules(detector.evaluate(sample(500, views: 3, docHeight: 5000, viewport: 800))), [])
    }

    func testADropOfFortyPercentIsNotACollapse() {
        var detector = PaneBlankDetector()
        stable(&detector, height: 1000, viewport: 800)
        // 1000 -> 600 is below the viewport but only a 40% drop.
        XCTAssertEqual(rules(detector.evaluate(sample(200, views: 3, docHeight: 600, viewport: 800))), [])
        XCTAssertEqual(rules(detector.evaluate(sample(500, views: 3, docHeight: 1000, viewport: 800))), [])
    }

    func testADropOfSixtyPercentBelowTheViewportThenRecoveringIsABlank() {
        var detector = PaneBlankDetector()
        stable(&detector, height: 1000, viewport: 800)
        XCTAssertEqual(rules(detector.evaluate(sample(200, views: 3, docHeight: 400, viewport: 800))), [])
        XCTAssertEqual(rules(detector.evaluate(sample(500, views: 3, docHeight: 1000, viewport: 800))), [.heightCollapse])
    }

    func testAPreviouslyShortDocumentCannotCollapse() {
        var detector = PaneBlankDetector()
        stable(&detector, height: 300, viewport: 800)          // the transcript never filled the viewport
        XCTAssertEqual(rules(detector.evaluate(sample(200, views: 3, docHeight: 50, viewport: 800))), [])
        XCTAssertEqual(rules(detector.evaluate(sample(500, views: 3, docHeight: 300, viewport: 800))), [])
    }

    // MARK: - Rule (c): a draw pass that paints no turn rows

    func testADrawThatPaintsNoRowsWhileTurnsAreRetainedAndNothingIsQueuedIsABlank() {
        var detector = PaneBlankDetector()
        let hit = detector.noteDraw(nowMs: 100, isVisible: true, retainedTurns: 10, rowsPainted: 0, renderPending: false)
        XCTAssertEqual(hit?.rule, .zeroRowDraw)
        XCTAssertEqual(hit?.severity, .blank)
    }

    func testADrawThatPaintsRowsIsFine() {
        var detector = PaneBlankDetector()
        XCTAssertNil(detector.noteDraw(nowMs: 100, isVisible: true, retainedTurns: 10, rowsPainted: 3, renderPending: false))
    }

    func testAZeroRowDrawWithARepairAlreadyQueuedIsNotReported() {
        var detector = PaneBlankDetector()
        XCTAssertNil(detector.noteDraw(nowMs: 100, isVisible: true, retainedTurns: 10, rowsPainted: 0, renderPending: true))
    }

    func testAZeroRowDrawOfAPaneThatIsNotOnScreenIsNotReported() {
        var detector = PaneBlankDetector()
        XCTAssertNil(detector.noteDraw(nowMs: 100, isVisible: false, retainedTurns: 10, rowsPainted: 0, renderPending: false))
    }

    func testAZeroRowDrawOfAnEmptyTranscriptIsNotReported() {
        var detector = PaneBlankDetector()
        XCTAssertNil(detector.noteDraw(nowMs: 100, isVisible: true, retainedTurns: 0, rowsPainted: 0, renderPending: false))
    }

    func testABlankThatKeepsBeingDrawnIsOneHitUntilARowIsPainted() {
        var detector = PaneBlankDetector()
        XCTAssertNotNil(detector.noteDraw(nowMs: 0, isVisible: true, retainedTurns: 10, rowsPainted: 0, renderPending: false))
        // Drawn again at display rate while it stays blank: still the same incident.
        for t in stride(from: 16.0, to: 4_000, by: 16) {
            XCTAssertNil(detector.noteDraw(nowMs: t, isVisible: true, retainedTurns: 10, rowsPainted: 0, renderPending: false))
        }
        // Rows come back, then it blanks again: a new incident.
        XCTAssertNil(detector.noteDraw(nowMs: 4_100, isVisible: true, retainedTurns: 10, rowsPainted: 2, renderPending: false))
        XCTAssertNotNil(detector.noteDraw(nowMs: 4_200, isVisible: true, retainedTurns: 10, rowsPainted: 0, renderPending: false))
    }

    func testAPersistentBlankIsReportedAgainOnceTheRefractoryPeriodPasses() {
        var detector = PaneBlankDetector()
        XCTAssertNotNil(detector.noteDraw(nowMs: 0, isVisible: true, retainedTurns: 10, rowsPainted: 0, renderPending: false))
        XCTAssertNil(detector.noteDraw(nowMs: PaneBlankDetector.zeroRowDrawRefractoryMs - 1, isVisible: true,
                                       retainedTurns: 10, rowsPainted: 0, renderPending: false))
        XCTAssertNotNil(detector.noteDraw(nowMs: PaneBlankDetector.zeroRowDrawRefractoryMs, isVisible: true,
                                          retainedTurns: 10, rowsPainted: 0, renderPending: false))
    }

    // MARK: - Rule (d): main-thread stall

    func testAStallLongerThan250msOnAVisiblePaneIsReportedAsAStall() {
        var detector = PaneBlankDetector()
        let hit = detector.noteStall(ms: 251, isVisible: true)
        XCTAssertEqual(hit?.rule, .mainThreadStall)
        XCTAssertEqual(hit?.severity, .stall)
        XCTAssertEqual(PaneBlankDetector.stallThresholdMs, 250)
    }

    func testAStallOfExactly250msIsNotReported() {
        var detector = PaneBlankDetector()
        XCTAssertNil(detector.noteStall(ms: 250, isVisible: true))
        XCTAssertNil(detector.noteStall(ms: 40, isVisible: true))
    }

    func testAStallOnAPaneThatIsNotOnScreenIsNotReported() {
        var detector = PaneBlankDetector()
        XCTAssertNil(detector.noteStall(ms: 5000, isVisible: false))
    }

    // MARK: - Capture file helpers

    private func tempDirectory() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pane-blank-tests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15T08:00:00Z

    private func wall(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    private func captureNames(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("pane-blank-") && $0.hasSuffix(".json") }
            .sorted()
    }

    private func permissions(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
    }

    func testTheTagHashIsEightStableLowercaseHexCharactersThatDifferPerTag() {
        let hash = PaneBlankCapture.tagHash("perri")
        XCTAssertEqual(hash.count, 8)
        XCTAssertTrue(hash.allSatisfy { "0123456789abcdef".contains($0) }, hash)
        XCTAssertEqual(PaneBlankCapture.tagHash("perri"), hash, "stable across calls")
        XCTAssertNotEqual(PaneBlankCapture.tagHash("cody"), hash)
        XCTAssertFalse(hash.contains("perri"))
    }

    func testTheFileNameIsSortableUTCAndCarriesThePaneHash() {
        let name = PaneBlankCapture.fileName(tagHash: "0a1b2c3d", at: t0)
        XCTAssertEqual(name, "pane-blank-0a1b2c3d-20270115T080000Z.json")
        XCTAssertEqual(PaneBlankCapture.filePrefix, "pane-blank-")
        XCTAssertEqual(PaneBlankCapture.fileSuffix, ".json")
        XCTAssertLessThan(name, PaneBlankCapture.fileName(tagHash: "0a1b2c3d", at: wall(1)),
                          "later captures sort after earlier ones")
    }

    func testWritingCreatesAPrivateDirectoryAndAPrivateFile() throws {
        let dir = tempDirectory().appendingPathComponent("nested", isDirectory: true)
        let url = try XCTUnwrap(PaneBlankCapture.write(["schema": 1], tagHash: "0a1b2c3d", directory: dir, now: t0))
        XCTAssertEqual(permissions(url), 0o600, "the file is owner read/write only")
        XCTAssertEqual(permissions(dir), 0o700, "the directory is owner only")
        XCTAssertEqual(url.lastPathComponent, PaneBlankCapture.fileName(tagHash: "0a1b2c3d", at: t0))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual((object?["schema"] as? NSNumber)?.intValue, 1)
    }

    func testTwoCapturesInTheSameSecondBothSurvive() throws {
        let dir = tempDirectory()
        let first = try XCTUnwrap(PaneBlankCapture.write(["n": 1], tagHash: "0a1b2c3d", directory: dir, now: t0))
        let second = try XCTUnwrap(PaneBlankCapture.write(["n": 2], tagHash: "0a1b2c3d", directory: dir, now: t0))
        XCTAssertNotEqual(first, second, "a same-second name collision gets a suffix, it never overwrites")
        XCTAssertEqual(captureNames(in: dir).count, 2)
        let firstObject = try JSONSerialization.jsonObject(with: Data(contentsOf: first)) as? [String: Any]
        XCTAssertEqual((firstObject?["n"] as? NSNumber)?.intValue, 1, "the first capture is untouched")
    }

    func testOnlyTheNewestEightCapturesAreKeptAcrossPanes() throws {
        let dir = tempDirectory()
        for i in 0 ..< 12 {
            let hash = i % 2 == 0 ? "aaaaaaaa" : "bbbbbbbb"
            PaneBlankCapture.write(["i": i], tagHash: hash, directory: dir, now: wall(Double(i)))
        }
        XCTAssertEqual(PaneBlankCapture.keepNewest, 8)
        var expected: [String] = []
        for i in 4 ..< 12 {
            expected.append(PaneBlankCapture.fileName(tagHash: i % 2 == 0 ? "aaaaaaaa" : "bbbbbbbb", at: wall(Double(i))))
        }
        XCTAssertEqual(Set(captureNames(in: dir)), Set(expected), "the newest eight over all panes remain")
    }

    func testPruningTouchesNothingButCaptureFiles() throws {
        let dir = tempDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let unrelated = ["notes.txt", "layout-overflow-0a1b2c3d-20270101T000000Z.json",
                         "pane-blank-notes.txt", "overflow.log"]
        for name in unrelated { try Data("keep".utf8).write(to: dir.appendingPathComponent(name)) }
        for i in 0 ..< 11 {
            try Data("{}".utf8).write(to: dir.appendingPathComponent(
                PaneBlankCapture.fileName(tagHash: "0a1b2c3d", at: wall(Double(i)))))
        }

        PaneBlankCapture.prune(directory: dir)

        XCTAssertEqual(captureNames(in: dir).count, 8)
        XCTAssertEqual(captureNames(in: dir).first, PaneBlankCapture.fileName(tagHash: "0a1b2c3d", at: wall(3)))
        for name in unrelated {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path),
                          "\(name) is not a capture and must not be touched")
        }
    }

    func testLatestPathFindsTheNewestCaptureOfThatPaneOnly() throws {
        let dir = tempDirectory()
        XCTAssertNil(PaneBlankCapture.latestPath(in: dir), "no directory, no capture")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertNil(PaneBlankCapture.latestPath(in: dir), "empty directory, no capture")

        PaneBlankCapture.write([:], tagHash: "aaaaaaaa", directory: dir, now: wall(10))
        PaneBlankCapture.write([:], tagHash: "bbbbbbbb", directory: dir, now: wall(20))
        PaneBlankCapture.write([:], tagHash: "aaaaaaaa", directory: dir, now: wall(30))
        PaneBlankCapture.write([:], tagHash: "bbbbbbbb", directory: dir, now: wall(15))

        func name(_ path: String?) -> String? { path.map { ($0 as NSString).lastPathComponent } }
        XCTAssertEqual(name(PaneBlankCapture.latestPath(tagHash: "aaaaaaaa", in: dir)),
                       PaneBlankCapture.fileName(tagHash: "aaaaaaaa", at: wall(30)))
        XCTAssertEqual(name(PaneBlankCapture.latestPath(tagHash: "bbbbbbbb", in: dir)),
                       PaneBlankCapture.fileName(tagHash: "bbbbbbbb", at: wall(20)),
                       "newest by the UTC stamp, for that pane only")
        XCTAssertEqual(name(PaneBlankCapture.latestPath(in: dir)),
                       PaneBlankCapture.fileName(tagHash: "aaaaaaaa", at: wall(30)),
                       "no pane given: the newest of all")
        XCTAssertNil(PaneBlankCapture.latestPath(tagHash: "cccccccc", in: dir))
    }

    // MARK: - Real pane rig

    private final class FixedWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private struct Pane {
        let repl: ReplView
        let window: NSWindow
        let tag: String
        let dir: URL
        var watch: PaneRenderWatch { repl.renderWatch }
    }

    private var client: NostromodClient { AppStore.shared.client }

    /// A real transcript pane in an offscreen (alpha 0) window. Captures go to a fresh temp
    /// directory, and "is on screen" is forced true, because offscreen occlusion is unreliable.
    private func makePane(windowTitle: String? = nil,
                          size: NSSize = NSSize(width: 900, height: 700)) -> Pane {
        let tag = "pbd-\(UUID().uuidString)"
        let dir = tempDirectory()
        let repl = ReplView(tag: tag)
        repl.renderWatch.captureDirectory = dir
        repl.renderWatch.visibilityOverride = true

        let window = FixedWindow(contentRect: NSRect(origin: NSPoint(x: 60, y: 60), size: size),
                                 styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        if let windowTitle { window.title = windowTitle }
        repl.frame = NSRect(origin: .zero, size: size)
        repl.autoresizingMask = [.width, .height]
        window.contentView = repl
        window.alphaValue = 0
        window.orderFront(nil)
        addTeardownBlock {
            // A finished test's pane must not answer a later test's "capture every visible pane".
            repl.renderWatch.visibilityOverride = false
            window.orderOut(nil)
            window.contentView = nil
        }
        settle(window)
        return Pane(repl: repl, window: window, tag: tag, dir: dir)
    }

    private func settle(_ window: NSWindow) {
        for _ in 0 ..< 4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    private func pump(_ pane: Pane, _ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        pane.window.contentView?.layoutSubtreeIfNeeded()
        pane.window.displayIfNeeded()
    }

    @discardableResult
    private func waitUntil(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("condition not met within \(timeout)s", file: file, line: line)
                return false
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return true
    }

    // MARK: Delivering turns (the way the daemon does)

    private static let base = Date(timeIntervalSince1970: 1_780_000_000)
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func timestamp(_ seq: Int) -> String { Self.iso.string(from: Self.base.addingTimeInterval(Double(seq))) }

    private static let prose = "The transcript keeps a long paragraph of ordinary words so that each turn is tall enough to matter. "

    private func turn(_ i: Int, user: String? = nil, blocks: [DaemonTurnBlock]? = nil, complete: Bool = true) -> DaemonTurn {
        DaemonTurn(id: "turn-\(i)",
                   userInput: user ?? "question number \(i)",
                   timestamp: timestamp(i),
                   blocks: blocks ?? [.text(String(repeating: Self.prose, count: 6))],
                   isComplete: complete)
    }

    private func deliver(_ pane: Pane, turns: [DaemonTurn]) {
        client.messages.send(.sessionSpawned(tag: pane.tag, sessionId: "session-\(pane.tag)"))
        client.messages.send(.sessionTurns(tag: pane.tag, turns: turns))
    }

    /// Delivers `count` ordinary turns and waits until the pane has turn views on screen.
    private func makeMaterializedPane(turns count: Int = 40, windowTitle: String? = nil,
                                      file: StaticString = #filePath, line: UInt = #line) -> Pane {
        let pane = makePane(windowTitle: windowTitle)
        deliver(pane, turns: (0 ..< count).map { turn($0) })
        waitUntil(file: file, line: line) {
            self.pump(pane, 0.02)
            return pane.repl.visibleTurnViewCount > 0
        }
        pump(pane)
        return pane
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews { if let found = scrollView(in: sub) { return found } }
        return nil
    }

    // MARK: Observing files

    private func files(_ pane: Pane) -> [String] { captureNames(in: pane.dir) }

    private func report(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: Any], "the capture is not a JSON object", file: file, line: line)
    }

    private func newestCapture(_ pane: Pane) throws -> URL {
        let name = try XCTUnwrap(files(pane).last, "no capture file was written")
        return pane.dir.appendingPathComponent(name)
    }

    // MARK: - Scenarios: each rule on a real pane

    func testScenarioA_AllTurnViewsGoMissingAndAnEmptyViewportIsCapturedOnce() throws {
        let pane = makeMaterializedPane()
        XCTAssertGreaterThan(pane.repl.visibleTurnViewCount, 0, "precondition: the pane starts with turns in view")

        pane.repl.evictAllTurnViewsForTesting()
        XCTAssertEqual(pane.repl.visibleTurnViewCount, 0, "the blank has been simulated")

        let t = PaneRenderWatch.monotonicMs()
        XCTAssertTrue(pane.watch.evaluate(nowMs: t, wall: wall(0)).isEmpty)
        XCTAssertTrue(pane.watch.evaluate(nowMs: t + 150, wall: wall(0)).isEmpty)
        let hits = pane.watch.evaluate(nowMs: t + 350, wall: wall(1))

        XCTAssertEqual(hits.map(\.rule), [.emptyViewport])
        XCTAssertEqual(files(pane).count, 1, "one incident, one capture")
        XCTAssertEqual(pane.watch.captureCount, 1)
        XCTAssertNotNil(pane.watch.lastCaptureURL)

        let json = try report(try newestCapture(pane))
        XCTAssertEqual(json["trigger"] as? String, "auto")
        XCTAssertEqual(json["rule"] as? String, "empty-viewport")
        XCTAssertEqual(json["reason"] as? String, "empty-viewport")
        XCTAssertEqual(json["severity"] as? String, "blank")

        // The same incident goes on: still one file.
        _ = pane.watch.evaluate(nowMs: t + 500, wall: wall(2))
        _ = pane.watch.evaluate(nowMs: t + 650, wall: wall(3))
        XCTAssertEqual(files(pane).count, 1)
    }

    func testScenarioB_TheDocumentHeightCollapsesThenRecoversAndIsCaptured() throws {
        let pane = makeMaterializedPane()
        let t = PaneRenderWatch.monotonicMs()

        pane.watch.documentHeightOverride = 10_000
        XCTAssertTrue(pane.watch.evaluate(nowMs: t, wall: wall(0)).isEmpty)
        XCTAssertTrue(pane.watch.evaluate(nowMs: t + 100, wall: wall(0)).isEmpty)

        pane.watch.documentHeightOverride = 100          // far below the viewport and under half the old height
        XCTAssertTrue(pane.watch.evaluate(nowMs: t + 200, wall: wall(0)).isEmpty, "collapse alone is not a hit")
        XCTAssertTrue(pane.watch.evaluate(nowMs: t + 400, wall: wall(0)).isEmpty)

        pane.watch.documentHeightOverride = 10_000       // it comes back within ten seconds
        let hits = pane.watch.evaluate(nowMs: t + 900, wall: wall(1))

        XCTAssertEqual(hits.map(\.rule), [.heightCollapse])
        XCTAssertEqual(files(pane).count, 1)
        let json = try report(try newestCapture(pane))
        XCTAssertEqual(json["rule"] as? String, "height-collapse")
        XCTAssertEqual(json["severity"] as? String, "blank")
    }

    func testScenarioC_ADrawPassThatPaintsNoRowsIsCaptured() throws {
        let pane = makeMaterializedPane()
        pane.repl.evictAllTurnViewsForTesting()

        let hits = pane.repl.simulateDrawPassForTesting(nowMs: PaneRenderWatch.monotonicMs(), wall: wall(0))

        XCTAssertEqual(hits.map(\.rule), [.zeroRowDraw])
        XCTAssertEqual(files(pane).count, 1)
        XCTAssertEqual(try report(try newestCapture(pane))["rule"] as? String, "zero-row-draw")
    }

    func testScenarioC_ADrawPassOverMaterializedRowsIsQuiet() {
        let pane = makeMaterializedPane()
        let hits = pane.repl.simulateDrawPassForTesting(nowMs: PaneRenderWatch.monotonicMs(), wall: wall(0))
        XCTAssertTrue(hits.isEmpty)
        XCTAssertTrue(files(pane).isEmpty)
    }

    /// The proof that rule (c) has a heartbeat at all: every other rule-(c) test feeds a simulated draw.
    /// This one lets AppKit draw the real document view in an ordered-in, layer-backed window.
    func testTheRealDocumentViewDrawHeartbeatFiresWhenAppKitDisplaysTheDirtiedView() {
        let pane = makeMaterializedPane()
        pane.watch.automaticEvaluation = true
        addTeardownBlock { pane.watch.automaticEvaluation = false }
        XCTAssertTrue(pane.window.isVisible, "the window is ordered in, so AppKit really displays it")
        XCTAssertTrue(pane.repl.layer != nil, "the pane is layer-backed")

        let beforeCount = pane.repl.documentWillDrawCount
        func drawsRecorded() -> Int {
            pane.watch.recorder.events.filter { $0.kind == .draw }.reduce(0) { $0 + $1.coalescedCount }
        }
        let drawsBefore = drawsRecorded()

        // Dirty the document view, then run real display passes. Nothing here calls the heartbeat.
        for _ in 0 ..< 5 {
            pane.repl.dirtyDocumentViewForTesting()
            pane.window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            if pane.repl.documentWillDrawCount > beforeCount { break }
        }

        XCTAssertGreaterThan(pane.repl.documentWillDrawCount, beforeCount,
                             "AppKit never called viewWillDraw on the document view: the heartbeat is dead")
        XCTAssertGreaterThan(drawsRecorded(), drawsBefore, "the heartbeat fired but no .draw event was recorded")
    }

    func testScenarioD_AFourHundredMillisecondStallIsCapturedAsAStall() throws {
        let pane = makeMaterializedPane()

        let hits = pane.watch.noteStall(ms: 400, nowMs: PaneRenderWatch.monotonicMs(), wall: wall(0))

        XCTAssertEqual(hits.map(\.rule), [.mainThreadStall])
        XCTAssertEqual(files(pane).count, 1)
        let json = try report(try newestCapture(pane))
        XCTAssertEqual(json["rule"] as? String, "main-thread-stall")
        XCTAssertEqual(json["severity"] as? String, "stall")
        XCTAssertEqual(json["trigger"] as? String, "auto")
    }

    func testAShortStallIsIgnored() {
        let pane = makeMaterializedPane()
        XCTAssertTrue(pane.watch.noteStall(ms: 200, nowMs: PaneRenderWatch.monotonicMs(), wall: wall(0)).isEmpty)
        XCTAssertTrue(files(pane).isEmpty)
    }

    // MARK: - Scenario 5: false-positive guards on a real pane

    /// A healthy pane must say nothing: no hits, no files. Every guard below ends here.
    private func assertQuiet(_ pane: Pane, _ hits: [PaneBlankDetector.Hit], _ what: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(hits.isEmpty, "\(what) raised \(hits.map(\.rule.rawValue))", file: file, line: line)
        XCTAssertTrue(files(pane).isEmpty, "\(what) wrote a capture: \(files(pane))", file: file, line: line)
    }

    func testNormalStreamingRaisesNothing() {
        let pane = makeMaterializedPane(turns: 6)
        var now = PaneRenderWatch.monotonicMs()
        var hits: [PaneBlankDetector.Hit] = []

        client.messages.send(.sessionTurnDelta(tag: pane.tag, delta: .turnStarted(turn(100, complete: false))))
        for i in 0 ..< 30 {
            client.messages.send(.sessionTurnDelta(tag: pane.tag, delta: .blockAppended(
                turnId: "turn-100", block: .text("streamed paragraph \(i). " + Self.prose))))
            pump(pane, 0.02)
            now += 250
            hits += pane.watch.evaluate(nowMs: now, wall: wall(Double(i)))
            hits += pane.repl.simulateDrawPassForTesting(nowMs: now, wall: wall(Double(i)))
        }
        client.messages.send(.sessionTurnDelta(tag: pane.tag, delta: .turnCompleted(
            turnId: "turn-100", summary: DaemonResultSummary(durationMs: 1, costUsd: 0, isError: false), contextTokens: nil)))
        pump(pane)
        now += 250
        hits += pane.watch.evaluate(nowMs: now, wall: wall(99))

        assertQuiet(pane, hits, "streaming")
    }

    func testScrollingUpAndDownAcrossTheTranscriptRaisesNothing() throws {
        let pane = makeMaterializedPane(turns: 60)
        let scroll = try XCTUnwrap(scrollView(in: pane.repl), "the pane has a scroll view")
        let clip = scroll.contentView
        let docHeight = try XCTUnwrap(scroll.documentView).frame.height
        let maxY = max(0, docHeight - clip.bounds.height)
        XCTAssertGreaterThan(maxY, 1000, "precondition: the transcript is much taller than the viewport")

        var now = PaneRenderWatch.monotonicMs()
        var hits: [PaneBlankDetector.Hit] = []
        let offsets = Array(stride(from: maxY, through: 0, by: -250)) + Array(stride(from: 0, through: maxY, by: 250))
        for (i, y) in offsets.enumerated() {
            clip.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(clip)
            pump(pane, 0.03)
            now += 250
            hits += pane.watch.evaluate(nowMs: now, wall: wall(Double(i)))
            hits += pane.repl.simulateDrawPassForTesting(nowMs: now, wall: wall(Double(i)))
        }

        assertQuiet(pane, hits, "scrolling")
    }

    func testResizingTheWindowRaisesNothing() {
        let pane = makeMaterializedPane(turns: 40)
        var now = PaneRenderWatch.monotonicMs()
        var hits: [PaneBlankDetector.Hit] = []

        let sizes: [NSSize] = [NSSize(width: 1100, height: 760), NSSize(width: 640, height: 500),
                               NSSize(width: 900, height: 700), NSSize(width: 480, height: 900),
                               NSSize(width: 1200, height: 600), NSSize(width: 900, height: 700)]
        for (i, size) in sizes.enumerated() {
            pane.window.setContentSize(size)
            for step in 0 ..< 4 {
                pump(pane, 0.03)
                now += 250
                hits += pane.watch.evaluate(nowMs: now, wall: wall(Double(i * 10 + step)))
            }
        }

        assertQuiet(pane, hits, "resizing")
    }

    func testSwitchingAwayFromThePaneRaisesNothingEvenThoughItsViewsAreReleased() {
        let pane = makeMaterializedPane()
        pane.watch.visibilityOverride = false          // another tab is showing
        pane.repl.evictAllTurnViewsForTesting()
        var now = PaneRenderWatch.monotonicMs()
        var hits: [PaneBlankDetector.Hit] = []

        for i in 0 ..< 20 {
            now += 250
            hits += pane.watch.evaluate(nowMs: now, wall: wall(Double(i)))
            hits += pane.repl.simulateDrawPassForTesting(nowMs: now, wall: wall(Double(i)))
            hits += pane.watch.noteStall(ms: 900, nowMs: now, wall: wall(Double(i)))
        }

        assertQuiet(pane, hits, "a hidden pane")
    }

    func testAGenuinelyEmptyTranscriptRaisesNothing() {
        let pane = makePane()
        deliver(pane, turns: [])
        pump(pane, 0.2)
        var now = PaneRenderWatch.monotonicMs()
        var hits: [PaneBlankDetector.Hit] = []

        for i in 0 ..< 20 {
            pump(pane, 0.01)
            now += 250
            hits += pane.watch.evaluate(nowMs: now, wall: wall(Double(i)))
            hits += pane.repl.simulateDrawPassForTesting(nowMs: now, wall: wall(Double(i)))
        }

        assertQuiet(pane, hits, "an empty transcript")
    }

    // MARK: - Scenario 6: captures are content-free

    func testACaptureNeverContainsTurnTextToolArgumentsPathsTitlesOrTheTag() throws {
        let userSentinel = "SENTINEL-USER-1d4b"
        let textSentinel = "SENTINEL-TEXT-7f3a"
        let argsSentinel = "SENTINEL-ARGS-9c1e"
        let pathSentinel = "/Users/SENTINEL/secret.txt"
        let titleSentinel = "SENTINEL-TITLE-5b2d"

        let pane = makePane(windowTitle: titleSentinel)
        let blocks: [DaemonTurnBlock] = [
            .text("\(textSentinel) said something. " + Self.prose),
            .toolCall(toolName: "Read", inputSummary: "\(argsSentinel) \(pathSentinel)",
                      inputFull: "{\"file_path\":\"\(pathSentinel)\",\"note\":\"\(argsSentinel)\"}"),
            .toolResult(content: "\(textSentinel) result of \(pathSentinel)", isError: false),
        ]
        deliver(pane, turns: (0 ..< 12).map { turn($0, user: "\(userSentinel) \($0)", blocks: blocks) })
        waitUntil { self.pump(pane, 0.02); return pane.repl.visibleTurnViewCount > 0 }

        // One automatic capture (a stall) and one manual capture, both after content was shown.
        _ = pane.watch.noteStall(ms: 500, nowMs: PaneRenderWatch.monotonicMs(), wall: wall(0))
        _ = pane.watch.captureNow(nowMs: PaneRenderWatch.monotonicMs() + 10, wall: wall(5))
        XCTAssertEqual(files(pane).count, 2)

        for name in files(pane) {
            let url = pane.dir.appendingPathComponent(name)
            let bytes = try Data(contentsOf: url)
            let text = String(decoding: bytes, as: UTF8.self)
            for sentinel in [userSentinel, textSentinel, argsSentinel, pathSentinel, titleSentinel, "SENTINEL", pane.tag] {
                XCTAssertFalse(text.contains(sentinel), "\(name) leaks '\(sentinel)'")
            }
            XCTAssertNil(try report(url)["tag"], "the pane is identified only by the hash in the file name")
            XCTAssertTrue(name.contains(PaneBlankCapture.tagHash(pane.tag)), "\(name) carries the pane's tag hash")
            XCTAssertFalse(name.contains(pane.tag))
            XCTAssertEqual(permissions(url), 0o600, "\(name) is owner read/write only")
        }
        XCTAssertEqual(permissions(pane.dir), 0o700, "the capture directory is owner only")
    }

    // MARK: - Capture file shape

    func testACaptureHasTheDocumentedShape() throws {
        let pane = makeMaterializedPane()
        let url = try XCTUnwrap(pane.watch.captureNow(nowMs: PaneRenderWatch.monotonicMs(), wall: wall(0)))
        let json = try report(url)

        XCTAssertEqual((json["schema"] as? NSNumber)?.intValue, 1)
        XCTAssertNotNil(json["capturedAtUTC"] as? String)
        XCTAssertNotNil(json["detail"] as? [String: Any], "detail is an object, possibly empty")

        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertFalse(events.isEmpty)
        XCTAssertLessThanOrEqual(events.count, 200)
        let seqs = events.compactMap { ($0["seq"] as? NSNumber)?.doubleValue }
        XCTAssertEqual(seqs.count, events.count)
        XCTAssertEqual(seqs, seqs.sorted(), "events are oldest first")

        let diagnostics = try XCTUnwrap(json["diagnostics"] as? [String: Any])
        for key in ["retainedTurns", "materializedViews", "visibleTurnViews", "estimatedDocHeight",
                    "transcriptClears", "slowMeasures", "worstMeasureMs", "viewportHeight"] {
            XCTAssertNotNil(diagnostics[key] as? NSNumber, "diagnostics.\(key) is missing")
        }
        XCTAssertGreaterThan((diagnostics["retainedTurns"] as? NSNumber)?.intValue ?? 0, 0)

        let window = try XCTUnwrap(json["window"] as? [String: Any], "the pane is in a window")
        let frame = try XCTUnwrap(window["frame"] as? [String: Any])
        for key in ["x", "y", "w", "h"] { XCTAssertNotNil(frame[key] as? NSNumber, "window.frame.\(key)") }
        for key in ["screenIndex", "isKey", "occluded", "alpha", "fullscreen"] {
            XCTAssertNotNil(window[key], "window.\(key) is missing")
        }

        let app = try XCTUnwrap(json["app"] as? [String: Any])
        for key in ["uptimeSeconds", "build", "pid"] { XCTAssertNotNil(app[key], "app.\(key) is missing") }
    }

    // MARK: - Scenario 7: rate limiting

    func testOneAutomaticBlankCapturePerFiveMinutesAndStallsAreLimitedSeparately() throws {
        let pane = makeMaterializedPane()
        pane.repl.evictAllTurnViewsForTesting()
        let t = PaneRenderWatch.monotonicMs()
        XCTAssertEqual(PaneRenderWatch.minCaptureIntervalMs, 300_000)

        _ = pane.watch.evaluate(nowMs: t, wall: wall(0))
        _ = pane.watch.evaluate(nowMs: t + 150, wall: wall(0))
        XCTAssertEqual(pane.watch.evaluate(nowMs: t + 350, wall: wall(1)).map(\.rule), [.emptyViewport])
        XCTAssertEqual(files(pane).count, 1)

        // A second blank within five minutes is still reported, but writes nothing.
        let second = pane.repl.simulateDrawPassForTesting(nowMs: t + 10_000, wall: wall(20))
        XCTAssertEqual(second.map(\.rule), [.zeroRowDraw], "the hit is still returned when rate limited")
        XCTAssertEqual(files(pane).count, 1, "rate limited: no second file inside 300 s")
        XCTAssertEqual(pane.watch.captureCount, 1)

        // A stall is a different bucket: it still writes inside the window.
        XCTAssertEqual(pane.watch.noteStall(ms: 400, nowMs: t + 20_000, wall: wall(30)).map(\.rule), [.mainThreadStall])
        XCTAssertEqual(files(pane).count, 2, "stall hits are limited independently of blank hits")

        // A second stall inside its own window writes nothing.
        XCTAssertEqual(pane.watch.noteStall(ms: 400, nowMs: t + 30_000, wall: wall(40)).count, 1)
        XCTAssertEqual(files(pane).count, 2)

        // After five minutes a blank is captured again.
        let later = pane.repl.simulateDrawPassForTesting(nowMs: t + 400_000, wall: wall(500))
        XCTAssertEqual(later.map(\.rule), [.zeroRowDraw])
        XCTAssertEqual(files(pane).count, 3, "past 300 s a new incident writes again")
        XCTAssertEqual(pane.watch.captureCount, 3)
    }

    // MARK: - Scenario 8: pruning on a real pane

    func testTenManualCapturesLeaveTheNewestEight() throws {
        let pane = makeMaterializedPane()
        let t = PaneRenderWatch.monotonicMs()
        for i in 0 ..< 10 {
            XCTAssertNotNil(pane.watch.captureNow(nowMs: t + Double(i), wall: wall(Double(i))))
        }

        let hash = PaneBlankCapture.tagHash(pane.tag)
        let expected = (2 ..< 10).map { PaneBlankCapture.fileName(tagHash: hash, at: wall(Double($0)), manual: true) }
        XCTAssertEqual(files(pane), expected, "exactly the newest eight remain")
        XCTAssertEqual(pane.watch.captureCount, 10, "captureCount counts files written, pruned or not")
    }

    func testManualCapturesHaveTheirOwnCapAndCannotEvictAutomaticOnes() throws {
        let dir = tempDirectory()
        // Three automatic captures, then a dozen manual ones that are all newer.
        for i in 0 ..< 3 { PaneBlankCapture.write(["i": i], tagHash: "aaaaaaaa", directory: dir, now: wall(Double(i))) }
        for i in 10 ..< 22 {
            PaneBlankCapture.write(["i": i], tagHash: "aaaaaaaa", directory: dir, now: wall(Double(i)), manual: true)
        }
        let names = captureNames(in: dir)
        let automatic = names.filter { !$0.contains("-manual") }
        let manual = names.filter { $0.contains("-manual") }
        XCTAssertEqual(automatic, (0 ..< 3).map { PaneBlankCapture.fileName(tagHash: "aaaaaaaa", at: wall(Double($0))) },
                       "manual presses did not evict the automatic evidence")
        XCTAssertEqual(manual, (14 ..< 22).map { PaneBlankCapture.fileName(tagHash: "aaaaaaaa", at: wall(Double($0)), manual: true) },
                       "the newest eight manual captures remain")
    }

    func testAutomaticCapturesAreStillCappedAtEightWhenManualOnesExist() throws {
        let dir = tempDirectory()
        PaneBlankCapture.write([:], tagHash: "bbbbbbbb", directory: dir, now: wall(0), manual: true)
        for i in 1 ..< 13 { PaneBlankCapture.write([:], tagHash: "aaaaaaaa", directory: dir, now: wall(Double(i))) }
        let names = captureNames(in: dir)
        XCTAssertEqual(names.filter { !$0.contains("-manual") }.count, 8)
        XCTAssertEqual(names.filter { $0.contains("-manual") }.count, 1)
    }

    func testLatestPathSeesManualAndAutomaticCapturesAndSameSecondManualsBothSurvive() throws {
        let dir = tempDirectory()
        PaneBlankCapture.write([:], tagHash: "aaaaaaaa", directory: dir, now: wall(1))
        let m1 = try XCTUnwrap(PaneBlankCapture.write([:], tagHash: "aaaaaaaa", directory: dir, now: wall(5), manual: true))
        let m2 = try XCTUnwrap(PaneBlankCapture.write([:], tagHash: "aaaaaaaa", directory: dir, now: wall(5), manual: true))
        XCTAssertNotEqual(m1, m2)
        XCTAssertEqual(PaneBlankCapture.latestPath(tagHash: "aaaaaaaa", in: dir), m2.path)
        XCTAssertEqual(captureNames(in: dir).count, 3)
    }

    // MARK: - Scenario 9: manual capture

    func testManualCaptureAlwaysWritesAndNeverUsesUpTheRateLimit() throws {
        let pane = makeMaterializedPane()
        let t = PaneRenderWatch.monotonicMs()

        let first = try XCTUnwrap(pane.watch.captureNow(nowMs: t, wall: wall(0)))
        let second = try XCTUnwrap(pane.watch.captureNow(nowMs: t + 5, wall: wall(1)))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(files(pane).count, 2, "manual captures are not rate limited")

        let json = try report(first)
        XCTAssertEqual(json["trigger"] as? String, "manual")
        XCTAssertEqual(json["reason"] as? String, "manual")
        XCTAssertEqual(json["rule"] as? String, "manual")
        XCTAssertEqual(json["severity"] as? String, "manual")
        XCTAssertEqual(pane.watch.lastCaptureURL, second)

        // And a manual capture does not count against the automatic limit.
        pane.repl.evictAllTurnViewsForTesting()
        XCTAssertEqual(pane.repl.simulateDrawPassForTesting(nowMs: t + 100, wall: wall(10)).map(\.rule), [.zeroRowDraw])
        XCTAssertEqual(files(pane).count, 3, "the first automatic capture still goes out after manual ones")
    }

    func testManualCaptureWorksEvenWhenThePaneIsNotVisible() throws {
        let pane = makeMaterializedPane()
        pane.watch.visibilityOverride = false
        let url = try XCTUnwrap(pane.watch.captureNow(nowMs: PaneRenderWatch.monotonicMs(), wall: wall(0)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testCaptureAllVisibleWritesForEveryVisiblePaneAndSkipsOthers() throws {
        let one = makeMaterializedPane(turns: 10)
        let two = makeMaterializedPane(turns: 10)
        let hidden = makeMaterializedPane(turns: 10)
        hidden.watch.visibilityOverride = false

        let urls = PaneRenderWatch.captureAllVisible(nowMs: PaneRenderWatch.monotonicMs(), wall: wall(0))

        XCTAssertEqual(files(one).count, 1, "a visible pane is captured")
        XCTAssertEqual(files(two).count, 1, "every visible pane is captured")
        XCTAssertTrue(files(hidden).isEmpty, "a pane that is not on screen is skipped")
        let written = Set(urls.map { $0.standardizedFileURL.path })
        for pane in [one, two] {
            let path = pane.dir.appendingPathComponent(files(pane)[0]).standardizedFileURL.path
            XCTAssertTrue(written.contains(path), "the returned URLs include \(path)")
            XCTAssertEqual(try report(pane.dir.appendingPathComponent(files(pane)[0]))["trigger"] as? String, "manual")
        }

        // Asking again straight away still writes: manual capture bypasses the rate limit.
        _ = PaneRenderWatch.captureAllVisible(nowMs: PaneRenderWatch.monotonicMs() + 5, wall: wall(1))
        XCTAssertEqual(files(one).count, 2)
        XCTAssertEqual(files(two).count, 2)
        XCTAssertTrue(files(hidden).isEmpty)
    }

    // MARK: - Scenario 10 (pane level): latestPath for a real pane

    func testLatestPathForARealPaneReturnsItsNewestCaptureOnly() throws {
        let pane = makeMaterializedPane()
        let t = PaneRenderWatch.monotonicMs()
        _ = pane.watch.captureNow(nowMs: t, wall: wall(0))
        let newest = try XCTUnwrap(pane.watch.captureNow(nowMs: t + 5, wall: wall(7)))

        let hash = PaneBlankCapture.tagHash(pane.tag)
        let found = try XCTUnwrap(PaneBlankCapture.latestPath(tagHash: hash, in: pane.dir))
        XCTAssertEqual(URL(fileURLWithPath: found).lastPathComponent, newest.lastPathComponent)
        XCTAssertNil(PaneBlankCapture.latestPath(tagHash: PaneBlankCapture.tagHash(pane.tag + "-other"), in: pane.dir))
    }

    // MARK: - Scenario 11: the recorder of a real pane

    func testAPaneRecordsWhatItDidAsItsTurnsMaterialize() {
        let pane = makeMaterializedPane()
        let recorder = pane.repl.renderWatch.recorder

        XCTAssertGreaterThan(recorder.count, 0)
        XCTAssertLessThanOrEqual(recorder.count, 200)
        let kinds = Set(recorder.events.map(\.kind))
        XCTAssertTrue(kinds.contains(.viewsMaterialized), "kinds seen: \(kinds)")
        XCTAssertTrue(kinds.contains(.docHeight), "kinds seen: \(kinds)")
    }

    func testAPaneThatChurnsKeepsItsRecorderBounded() throws {
        let pane = makeMaterializedPane(turns: 60)
        let scroll = try XCTUnwrap(scrollView(in: pane.repl))
        let clip = scroll.contentView
        let maxY = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
        for i in 0 ..< 120 {
            clip.scroll(to: NSPoint(x: 0, y: maxY * Double(i % 10) / 10))
            scroll.reflectScrolledClipView(clip)
            if i % 10 == 0 { pump(pane, 0.01) }
        }
        XCTAssertLessThanOrEqual(pane.repl.renderWatch.recorder.count, 200)
    }

    // MARK: - A stall storm cannot evict the evidence

    func testThreeHundredStallsLeaveTheEarlierStructuralEventsInTheRingAndTheCapture() throws {
        let pane = makeMaterializedPane()
        pane.watch.automaticEvaluation = true
        addTeardownBlock { pane.watch.automaticEvaluation = false }
        let recorder = pane.watch.recorder

        // The structural history that led up to the blank, recorded after the pane has settled.
        let history: [PaneFlightRecorder.Kind] = [.viewsEvicted, .windowChange, .docHeight, .viewsEvicted, .windowChange, .docHeight]
        for (i, kind) in history.enumerated() { recorder.record(kind, reason: .scroll, Double(i), 1, 2, 3) }
        let firstHistorySeq = recorder.totalRecorded - UInt64(history.count) + 1
        let before = recorder.totalRecorded

        // 300 stalls, each over the threshold, over ten minutes of simulated clock; three different
        // routes in: the pane's run-loop stall hook, a slow measurement and the detector entry point.
        let t = PaneRenderWatch.monotonicMs()
        for i in 0 ..< 300 {
            _ = pane.watch.mainThreadStalled(ms: 300 + Double(i), mayCapture: false)
            recorder.recordCoalesced(.measureStall, minIntervalMs: PaneRenderWatch.stallRecordIntervalMs, 300, Double(i))
            _ = pane.watch.noteStall(ms: 300 + Double(i), nowMs: t + Double(i) * 10, wall: wall(Double(i)), capture: false)
        }

        // The storm took a handful of slots (one stall, one measure stall, one hit), not hundreds.
        XCTAssertLessThanOrEqual(recorder.totalRecorded - before, 6, "events recorded by 900 stall notifications")
        let seqs = Set(recorder.events.map(\.seq))
        for offset in 0 ..< UInt64(history.count) {
            XCTAssertTrue(seqs.contains(firstHistorySeq + offset), "structural event \(offset) was evicted by the storm")
        }
        let hits = recorder.events.filter { $0.kind == .detectorHit }
        XCTAssertLessThanOrEqual(hits.count, 1, "a stall storm is one detectorHit event, not one per stall")
        XCTAssertTrue(recorder.events.contains { $0.kind == .runLoopStall && $0.coalescedCount > 1 },
                      "the run-loop stalls were coalesced and say how many")
        XCTAssertFalse(recorder.events.contains { $0.kind == .measureStall && $0.b == -1 },
                       "a run-loop stall is no longer a measureStall with turnIndex -1")

        // And the capture written afterwards still contains the history and says what was suppressed.
        let url = try XCTUnwrap(pane.watch.captureNow(nowMs: t + 5_000, wall: wall(400)))
        let json = try report(url)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        let captured = Set(events.compactMap { ($0["seq"] as? NSNumber)?.uint64Value })
        for offset in 0 ..< UInt64(history.count) {
            XCTAssertTrue(captured.contains(firstHistorySeq + offset), "capture lost structural event \(offset)")
        }
        let suppressed = try XCTUnwrap(json["suppressedHits"] as? [String: Any])
        XCTAssertGreaterThanOrEqual((suppressed["main-thread-stall"] as? NSNumber)?.intValue ?? 0, 250)
    }

    func testAHitIsRecordedAgainOnceItsRecordIntervalPasses() {
        let pane = makeMaterializedPane()
        let t = PaneRenderWatch.monotonicMs()
        _ = pane.watch.noteStall(ms: 400, nowMs: t, wall: wall(0), capture: false)
        _ = pane.watch.noteStall(ms: 400, nowMs: t + 1_000, wall: wall(1), capture: false)
        XCTAssertEqual(pane.watch.recorder.events.filter { $0.kind == .detectorHit }.count, 1)
        _ = pane.watch.noteStall(ms: 400, nowMs: t + PaneRenderWatch.hitRecordIntervalMs + 1, wall: wall(10), capture: false)
        XCTAssertEqual(pane.watch.recorder.events.filter { $0.kind == .detectorHit }.count, 2)
    }

    func testDifferentRulesAreRecordedIndependently() {
        let pane = makeMaterializedPane()
        let t = PaneRenderWatch.monotonicMs()
        _ = pane.watch.noteStall(ms: 400, nowMs: t, wall: wall(0), capture: false)
        pane.repl.evictAllTurnViewsForTesting()
        _ = pane.repl.simulateDrawPassForTesting(nowMs: t + 10, wall: wall(0))
        let codes = pane.watch.recorder.events.filter { $0.kind == .detectorHit }.map(\.a)
        XCTAssertEqual(codes, [PaneBlankDetector.Rule.mainThreadStall.code, PaneBlankDetector.Rule.zeroRowDraw.code],
                       "a stall does not hide a blank that follows it")
    }

    // MARK: - No OS free text in a capture

    /// Every key a capture may contain, at any depth. A new field that is not on this list fails here,
    /// so a free-text field (a screen name, a title) cannot be added silently.
    private static let allowedCaptureKeys: Set<String> = Set([
        // top level
        "schema", "capturedAtUTC", "trigger", "reason", "rule", "severity", "detail", "suppressedHits", "events",
        "app", "screens", "diagnostics", "pane", "window", "memory",
        // memory (`MemorySummary`: numbers, and category names from a fixed vocabulary)
        "physicalFootprintBytes", "mallocBlocksInUse", "mallocBytesInUse", "categories", "name", "dirtyBytes",
        // app, screens, window
        "uptimeSeconds", "build", "pid", "index", "frame", "scale", "x", "y", "w", "h",
        "screenIndex", "isKey", "occluded", "alpha", "fullscreen",
        // diagnostics
        "retainedTurns", "materializedViews", "visibleTurnViews", "estimatedDocHeight", "transcriptClears",
        "slowMeasures", "worstMeasureMs", "viewportHeight",
        // pane geometry
        "paneWidth", "paneHeight", "scrollViewWidth", "scrollViewHeight", "clipOriginY", "clipWidth",
        "documentFrameHeight", "virtualizerCount", "passPending", "materializing", "contentDirty", "followingTail",
        // detail (every rule) and suppressedHits (rule names)
        "evaluations", "emptyForMs", "documentHeight", "heightBefore", "heightCollapsedTo", "heightAfter",
        "collapsedForMs", "stallMs", "atMs",
        "empty-viewport", "height-collapse", "zero-row-draw", "main-thread-stall", "manual",
        // events
        "seq", "kind", "tMs", "wall", "n",
    ]).union(PaneFlightRecorder.Kind.allCases.flatMap(\.fieldNames))

    private func allKeys(in value: Any) -> Set<String> {
        if let dict = value as? [String: Any] {
            return dict.reduce(into: Set(dict.keys)) { $0.formUnion(allKeys(in: $1.value)) }
        }
        if let array = value as? [Any] { return array.reduce(into: Set<String>()) { $0.formUnion(allKeys(in: $1)) } }
        return []
    }

    private func stringValues(in value: Any) -> [String] {
        if let dict = value as? [String: Any] { return dict.values.flatMap { stringValues(in: $0) } }
        if let array = value as? [Any] { return array.flatMap { stringValues(in: $0) } }
        if let string = value as? String { return [string] }
        return []
    }

    func testACaptureContainsOnlyWhitelistedKeysAndFixedNames() throws {
        let titleSentinel = "SENTINEL-TITLE-77aa"
        let pane = makePane(windowTitle: titleSentinel)
        deliver(pane, turns: (0 ..< 12).map { turn($0) })
        waitUntil { self.pump(pane, 0.02); return pane.repl.visibleTurnViewCount > 0 }
        pane.repl.evictAllTurnViewsForTesting()
        _ = pane.watch.noteStall(ms: 400, nowMs: PaneRenderWatch.monotonicMs(), wall: wall(0))
        _ = pane.repl.simulateDrawPassForTesting(nowMs: PaneRenderWatch.monotonicMs() + 10, wall: wall(1))
        _ = pane.watch.captureNow(nowMs: PaneRenderWatch.monotonicMs() + 20, wall: wall(2))
        XCTAssertEqual(files(pane).count, 3)

        let fixedNames: Set<String> =
            Set(["auto", "manual"]) .union(["empty-viewport", "height-collapse", "zero-row-draw", "main-thread-stall"])
            .union(["blank", "stall"])
            .union(PaneFlightRecorder.Kind.allCases.map(\.name))
            .union(["none", "scroll", "resize", "clear", "splice", "shed", "fold", "manual", "test"])
            .union(MemorySummary.fixedCategoryNames)
        let stamp = try NSRegularExpression(pattern: #"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z$"#)
        let buildString = try NSRegularExpression(pattern: #"^[0-9A-Za-z.+-]+ \([0-9A-Za-z.+-]+\)$"#)
        let unnamedVMTag = try NSRegularExpression(pattern: #"^VM tag \d+$"#)
        let screenNames = NSScreen.screens.map(\.localizedName).filter { !$0.isEmpty }

        for name in files(pane) {
            let url = pane.dir.appendingPathComponent(name)
            let json = try report(url)
            let unexpected = allKeys(in: json).subtracting(Self.allowedCaptureKeys)
            XCTAssertTrue(unexpected.isEmpty, "\(name) has fields that are not on the whitelist: \(unexpected.sorted())")

            // Every string in the file is a timestamp, the build string or one of the fixed names.
            for value in stringValues(in: json) {
                let range = NSRange(value.startIndex..., in: value)
                let ok = fixedNames.contains(value)
                    || stamp.firstMatch(in: value, range: range) != nil
                    || buildString.firstMatch(in: value, range: range) != nil
                    || unnamedVMTag.firstMatch(in: value, range: range) != nil
                XCTAssertTrue(ok, "\(name) holds a string that is not a fixed name: '\(value)'")
            }

            let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            for screenName in screenNames { XCTAssertFalse(text.contains(screenName), "\(name) leaks the screen name '\(screenName)'") }
            XCTAssertFalse(text.contains("localizedName"))
            XCTAssertFalse(text.contains(titleSentinel))
        }

        let json = try report(try newestCapture(pane))
        let screens = try XCTUnwrap(json["screens"] as? [[String: Any]])
        for (i, screen) in screens.enumerated() {
            XCTAssertEqual((screen["index"] as? NSNumber)?.intValue, i)
            XCTAssertEqual(Set(screen.keys), ["index", "frame", "scale"], "a screen is its index, frame and scale")
        }
        let window = try XCTUnwrap(json["window"] as? [String: Any])
        XCTAssertNotNil((window["screenIndex"] as? NSNumber)?.intValue)
    }

    // MARK: - Timer backoff

    func testTheTimerBacksOffToOneSecondWhileHealthyAndReturnsToFastOnAnyEvent() {
        let pane = makeMaterializedPane()
        let watch = pane.watch
        watch.automaticEvaluation = true
        addTeardownBlock { watch.automaticEvaluation = false }
        XCTAssertEqual(watch.timerIntervalMs, 250, "a visible pane starts at 250 ms")

        for tick in 1 ... PaneRenderWatch.calmTicksBeforeBackoff {
            XCTAssertEqual(watch.timerIntervalMs, 250, "still fast before tick \(tick)")
            watch.timerTick()
        }
        XCTAssertEqual(watch.timerIntervalMs, PaneRenderWatch.idleEvaluationIntervalMs, "backed off after a healthy stretch")
        XCTAssertEqual(PaneRenderWatch.idleEvaluationIntervalMs, 1_000)

        watch.timerTick()
        XCTAssertEqual(watch.timerIntervalMs, 1_000, "and stays there while nothing happens")

        watch.requestEvaluation()
        XCTAssertEqual(watch.timerIntervalMs, 250, "an event puts it back at 250 ms")
    }

    func testAnActivityBetweenTicksKeepsTheTimerFast() {
        let pane = makeMaterializedPane()
        let watch = pane.watch
        watch.automaticEvaluation = true
        addTeardownBlock { watch.automaticEvaluation = false }
        for _ in 0 ..< 3 * PaneRenderWatch.calmTicksBeforeBackoff {
            watch.requestEvaluation()   // something is going on in every interval
            watch.timerTick()
        }
        XCTAssertEqual(watch.timerIntervalMs, 250)
    }

    func testASuspiciousPaneNeverBacksOffAndAHitReturnsAnIdleTimerToFast() {
        let pane = makeMaterializedPane()
        let watch = pane.watch
        watch.automaticEvaluation = true
        addTeardownBlock { watch.automaticEvaluation = false }

        // A blank in the making (no views, turns retained): every tick is suspicious.
        pane.repl.evictAllTurnViewsForTesting()
        for _ in 0 ..< 3 * PaneRenderWatch.calmTicksBeforeBackoff { watch.timerTick() }
        XCTAssertEqual(watch.timerIntervalMs, 250, "an empty viewport keeps the timer fast")

        // A healthy pane that has backed off, then a stall hit.
        let healthyPane = makeMaterializedPane()
        let healthy = healthyPane.watch
        healthy.automaticEvaluation = true
        addTeardownBlock { healthy.automaticEvaluation = false }
        for _ in 0 ... PaneRenderWatch.calmTicksBeforeBackoff { healthy.timerTick() }
        XCTAssertEqual(healthy.timerIntervalMs, 1_000)
        _ = healthy.noteStall(ms: 400, nowMs: PaneRenderWatch.monotonicMs(), wall: wall(0), capture: false)
        XCTAssertEqual(healthy.timerIntervalMs, 250, "a detector hit returns the timer to 250 ms")
    }

    func testAPaneThatIsNotVisibleHasNoTimerAtAll() {
        let pane = makeMaterializedPane()
        pane.watch.automaticEvaluation = true
        addTeardownBlock { pane.watch.automaticEvaluation = false }
        pane.watch.visibilityOverride = false
        pane.watch.updateScheduling()
        XCTAssertNil(pane.watch.timerIntervalMs)
    }

    // MARK: - Shed in flight on a real pane

    func testAnEmptyViewportOnARealPaneWhileAShedIsInFlightIsOnlyReportedAfterTwoSeconds() {
        let pane = makeMaterializedPane()
        pane.repl.evictAllTurnViewsForTesting()
        XCTAssertFalse(pane.repl.isShedInFlight)
        let t = PaneRenderWatch.monotonicMs()
        // Forced (a real shed's compaction cannot be held open here): the sequence that fires at 350 ms
        // without a shed in flight stays quiet.
        pane.watch.shedInFlightOverride = true
        XCTAssertTrue(pane.watch.evaluate(nowMs: t, wall: wall(0)).isEmpty)
        XCTAssertTrue(pane.watch.evaluate(nowMs: t + 150, wall: wall(0)).isEmpty)
        XCTAssertTrue(pane.watch.evaluate(nowMs: t + 350, wall: wall(1)).isEmpty)
        XCTAssertTrue(pane.watch.evaluate(nowMs: t + 1_500, wall: wall(2)).isEmpty)
        XCTAssertTrue(files(pane).isEmpty)
        XCTAssertEqual(pane.watch.evaluate(nowMs: t + 2_100, wall: wall(3)).map(\.rule), [.emptyViewport],
                       "a blank that outlasts the bound is reported")
        XCTAssertEqual(files(pane).count, 1)
    }

    // MARK: - Capture files are written off the draw path

    func testADeferredCaptureIsWrittenOnTheNextMainQueueTurnNotInsideTheCallback() throws {
        let pane = makeMaterializedPane()
        pane.watch.deferCaptureWrites = true
        pane.repl.evictAllTurnViewsForTesting()

        let hits = pane.repl.simulateDrawPassForTesting(nowMs: PaneRenderWatch.monotonicMs(), wall: wall(0))

        XCTAssertEqual(hits.map(\.rule), [.zeroRowDraw])
        XCTAssertTrue(files(pane).isEmpty, "nothing is written inside the callback that detected the blank")
        waitUntil { self.files(pane).count == 1 }
        XCTAssertEqual(try report(try newestCapture(pane))["rule"] as? String, "zero-row-draw")
        XCTAssertEqual(pane.watch.captureCount, 1)
    }

    func testADeferredCaptureShowsThePaneAsItWasAtTheHitNotAsItIsWhenTheFileLands() throws {
        let pane = makeMaterializedPane()
        pane.watch.deferCaptureWrites = true
        let visibleAtHit = pane.repl.visibleTurnViewCount
        XCTAssertGreaterThan(visibleAtHit, 0)

        _ = pane.watch.noteStall(ms: 400, nowMs: PaneRenderWatch.monotonicMs(), wall: wall(0))
        // Synchronously, before the write lands, the pane changes under it.
        pane.repl.evictAllTurnViewsForTesting()
        XCTAssertEqual(pane.repl.visibleTurnViewCount, 0)
        XCTAssertTrue(files(pane).isEmpty)

        waitUntil { self.files(pane).count == 1 }
        let diagnostics = try XCTUnwrap(try report(try newestCapture(pane))["diagnostics"] as? [String: Any])
        XCTAssertEqual((diagnostics["visibleTurnViews"] as? NSNumber)?.intValue, visibleAtHit,
                       "the report is built at the hit; only the file write is deferred")
    }

    // MARK: - The heartbeat must not change how the document view paints

    /// The heartbeat is proven live by the real-display test above. This guards the other half: the
    /// document view, as tall as the whole transcript, must not override `draw(_:)`, which would tell
    /// AppKit it paints and give it a backing store of its own. Checked on the live class, not the source.
    func testTheDocumentViewDoesNotOverrideDraw() {
        let pane = makePane()
        XCTAssertFalse(pane.repl.documentViewOverridesDrawForTesting)
    }
}
