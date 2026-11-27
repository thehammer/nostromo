import XCTest

/// The guard's own logic, over a temporary directory standing in for the real `~/.nostromo`. Mutation: make
/// `differences` return `[]` and each test below fails; drop the `recordBaseline()` call in `TestBundleSetup`
/// and `testThePrincipalClassTookTheBaseline` fails.
final class RealNostromoGuardTests: XCTestCase {

    private var root: URL!
    private let files = ["logs/window-placement.log", "composer-history.v1/sensitive-marks.v1.json"]
    private let directories = ["composer-history.v1", "attachments"]

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RealNostromoGuardTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("logs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("composer-history.v1"), withIntermediateDirectories: true)
        try Data("one\n".utf8).write(to: root.appendingPathComponent("logs/window-placement.log"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func snap() -> [String: String] { RealNostromoGuard.snapshot(root: root, files: files, directories: directories) }

    func testAnUntouchedDirectoryHasNoDifferences() {
        let before = snap()
        XCTAssertEqual(RealNostromoGuard.differences(before: before, after: snap(), full: true), [])
        XCTAssertEqual(RealNostromoGuard.differences(before: before, after: snap(), full: false), [])
    }

    func testACreatedWatchedFileIsCaughtInBothModes() throws {
        let before = snap()
        try Data("{}".utf8).write(to: root.appendingPathComponent("composer-history.v1/sensitive-marks.v1.json"))
        for full in [true, false] {
            let drift = RealNostromoGuard.differences(before: before, after: snap(), full: full)
            XCTAssertTrue(drift.contains { $0.hasPrefix("composer-history.v1/sensitive-marks.v1.json:") }, "full=\(full): \(drift)")
        }
    }

    func testADeletedWatchedFileIsCaughtInBothModes() throws {
        let before = snap()
        try FileManager.default.removeItem(at: root.appendingPathComponent("logs/window-placement.log"))
        for full in [true, false] {
            XCTAssertFalse(RealNostromoGuard.differences(before: before, after: snap(), full: full).isEmpty, "full=\(full)")
        }
    }

    func testAGrownFileIsCaughtOnlyInFullMode() throws {
        let before = snap()
        let handle = try FileHandle(forWritingTo: root.appendingPathComponent("logs/window-placement.log"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("163 more lines\n".utf8))
        try handle.close()
        XCTAssertTrue(RealNostromoGuard.differences(before: before, after: snap(), full: true)
            .contains { $0.hasPrefix("logs/window-placement.log:") })
        XCTAssertEqual(RealNostromoGuard.differences(before: before, after: snap(), full: false), [],
                       "with the real app running a log that grew is not a test's doing")
    }

    func testANewEntryInAWatchedDirectoryIsCaughtOnlyInFullMode() throws {
        let before = snap()
        try Data("x".utf8).write(to: root.appendingPathComponent("composer-history.v1/abc"))
        XCTAssertTrue(RealNostromoGuard.differences(before: before, after: snap(), full: true)
            .contains { $0.hasPrefix("composer-history.v1/:") })
        XCTAssertEqual(RealNostromoGuard.differences(before: before, after: snap(), full: false), [])
    }

    func testAMissingRootIsAbsentEverywhere() {
        let missing = root.appendingPathComponent("nope")
        let shot = RealNostromoGuard.snapshot(root: missing, files: files, directories: directories)
        XCTAssertEqual(Set(shot.values), ["absent"])
        XCTAssertEqual(RealNostromoGuard.differences(before: shot, after: shot, full: true), [])
    }

    func testThePrincipalClassTookTheBaseline() {
        XCTAssertTrue(RealNostromoGuard.hasBaseline, "TestBundleSetup records the baseline before any test runs")
    }
}
