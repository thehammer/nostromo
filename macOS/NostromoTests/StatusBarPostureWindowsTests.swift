import XCTest

// PostureSnapshot / WindowPace / Theme are compiled into this target directly (logic test).

final class StatusBarPostureWindowsTests: XCTestCase {

    private let now: TimeInterval = 1_800_000_000

    private func window(_ used: Float, resetsIn: TimeInterval) -> WindowPace {
        WindowPace(usedPct: used, elapsedPct: 50, pace: 1, paceSmoothed: nil,
                   resetsAt: now + resetsIn, level: "normal")
    }

    private func snap(five: WindowPace?, seven: WindowPace?, stale: Bool = false,
                      writtenAt: TimeInterval? = 1_800_000_000 - 60) -> PostureSnapshot {
        PostureSnapshot(posture: .normal, fiveHour: five, sevenDay: seven,
                        sonnetSevenDay: nil, scoped: [], agents: [:], staleInput: stale,
                        writtenAt: writtenAt)
    }

    func testNormalPostureShowsBothWindows() {
        let s = snap(five: window(42, resetsIn: 7200), seven: window(28, resetsIn: 80 * 3600))
        XCTAssertEqual(s.statusWindows(now: now), [
            .init(label: "5h", pct: 42, remaining: "2h"),
            .init(label: "7d", pct: 28, remaining: "80h"),
        ])
    }

    func testFullyUsedShowsRealHundredPercent() {
        let s = snap(five: window(100, resetsIn: 1800), seven: window(100, resetsIn: 3600))
        XCTAssertEqual(s.statusWindows(now: now).map(\.pct), [100, 100])
    }

    func testStaleInputShowsNothing() {
        let s = snap(five: window(10, resetsIn: 3600), seven: window(10, resetsIn: 3600), stale: true)
        XCTAssertTrue(s.statusWindows(now: now).isEmpty)
    }

    func testResetInThePastHidesThatWindow() {
        let s = snap(five: window(90, resetsIn: -60), seven: window(30, resetsIn: 3600))
        XCTAssertEqual(s.statusWindows(now: now).map(\.label), ["7d"])
    }

    func testAbsentFiveHourIsHidden() {
        let s = snap(five: nil, seven: window(30, resetsIn: 3600))
        XCTAssertEqual(s.statusWindows(now: now).map(\.label), ["7d"])
    }

    func testSnapshotOlderThanCutoffShowsNothing() {
        let five = window(10, resetsIn: 3600), seven = window(10, resetsIn: 3600)
        XCTAssertEqual(snap(five: five, seven: seven, writtenAt: now - 299).statusWindows(now: now).count, 2)
        let old = snap(five: five, seven: seven, writtenAt: now - 301)
        XCTAssertTrue(old.statusWindows(now: now).isEmpty)
        XCTAssertTrue(old.isStale(now: now))
    }

    func testUnknownWriteTimeIsTreatedAsStale() {
        let s = snap(five: window(10, resetsIn: 3600), seven: nil, writtenAt: nil)
        XCTAssertTrue(s.statusWindows(now: now).isEmpty)
    }

    func testNextTickHidesWindowWhoseResetPassed() {
        let s = snap(five: window(50, resetsIn: 30), seven: window(30, resetsIn: 3600))
        XCTAssertEqual(s.statusWindows(now: now).map(\.label), ["5h", "7d"])
        // 60 s later (still fresh snapshot): 5h reset has passed.
        let later = now + 60
        let s2 = PostureSnapshot(posture: .normal, fiveHour: s.fiveHour, sevenDay: s.sevenDay,
                                 sonnetSevenDay: nil, scoped: [], agents: [:], writtenAt: later - 30)
        XCTAssertEqual(s2.statusWindows(now: later).map(\.label), ["7d"])
    }

    func testNinetyNinePointSixShowsNinetyNine() {
        let s = snap(five: window(99.6, resetsIn: 3600), seven: nil)
        XCTAssertEqual(s.statusWindows(now: now).map(\.pct), [99])
    }

    func testParsesStaleInputAndFallsBackToMtime() {
        let json: [String: Any] = ["posture": "Pump the brakes", "stale_input": true]
        let mtime = Date(timeIntervalSince1970: now)
        let s = PostureSnapshot.parse(json: json, fileModified: mtime)
        XCTAssertEqual(s?.staleInput, true)
        XCTAssertEqual(s?.writtenAt, now)   // no ts: mtime used
        XCTAssertTrue(s?.statusWindows(now: now).isEmpty ?? false)
        var withTs = json; withTs["ts"] = "2026-10-27T03:03:22Z"; withTs["stale_input"] = false
        XCTAssertEqual(PostureSnapshot.parse(json: withTs, fileModified: mtime)?.writtenAt, 1_793_070_202)
    }

    func testTimestampParsing() {
        XCTAssertEqual(PostureSnapshot.parseTimestamp("2026-10-27T03:03:22Z"), 1_793_070_202)
        XCTAssertNotNil(PostureSnapshot.parseTimestamp("2026-10-27T03:03:22.500Z"))
        XCTAssertNil(PostureSnapshot.parseTimestamp(nil))
        XCTAssertNil(PostureSnapshot.parseTimestamp("garbage"))
    }

    func testMissingPostureShowsNothing() {
        let missing: PostureSnapshot? = nil
        XCTAssertTrue((missing?.statusWindows(now: now) ?? []).isEmpty)
    }

    /// Nostromo must never read the tmux-era rate-limits cache file.
    func testNoSourceReferencesTheTmuxRateLimitsFile() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let needle = ".claude-rate" + "-limits"
        for dir in ["macOS/Nostromo", "src"] {
            guard let e = FileManager.default.enumerator(at: root.appendingPathComponent(dir),
                                                         includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in e where ["swift", "rs"].contains(url.pathExtension) {
                let text = try String(contentsOf: url, encoding: .utf8)
                XCTAssertFalse(text.contains(needle), "\(url.path) references \(needle)")
            }
        }
    }
}
