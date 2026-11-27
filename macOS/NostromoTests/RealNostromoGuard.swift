import AppKit
import XCTest

/// Run-level guard: the test run must not change the operator's real `~/.nostromo`.
///
/// The test bundle's principal class (`TestBundleSetup`) takes a `snapshot` of the files tests are known to
/// have touched before the first test runs; the `ZRealNostromoGuard*Tests` classes (last in their shard)
/// take another and `differences` must be empty. `NostromoHome` already sends every path into a temporary
/// home under XCTest, so this is the net under that seam: a path that bypasses it shows up here.
///
/// Watched: exactly the paths past incidents touched (`logs/window-placement.log` by `TaskWindowTests`,
/// `composer-history.v1/sensitive-marks.v1.json` by the #511 job tests) plus the other files the Mac app owns
/// in `~/.nostromo`. NOT the whole directory: on a Mac where the real app and daemon run they write all
/// over it. When the real app is running the guard only compares which watched files exist (a test that
/// creates or deletes one is still caught); with no app running (CI, a quiet Mac) it compares size and
/// modification time as well.
enum RealNostromoGuard {

    /// Relative to `~/.nostromo`. Files are compared by existence (and size and mtime when `full`).
    static let watchedFiles = [
        "composer-history.v1/sensitive-marks.v1.json",
        "logs/window-placement.log",
        "transcript-folds.v1.json",
        "audit/terminal.jsonl",
        "focuses.json",
    ]
    /// Directories whose entry names are compared (only when `full`: a live app adds entries as you work).
    static let watchedDirectories = ["composer-history.v1", "attachments", "huey"]

    static let realRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nostromo", isDirectory: true)

    /// Path -> a description of its state; a path that does not exist maps to `"absent"`.
    static func snapshot(root: URL = realRoot, files: [String] = watchedFiles,
                         directories: [String] = watchedDirectories) -> [String: String] {
        var result: [String: String] = [:]
        let fm = FileManager.default
        for relative in files {
            let url = root.appendingPathComponent(relative)
            guard let attributes = try? fm.attributesOfItem(atPath: url.path) else { result[relative] = "absent"; continue }
            let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            result[relative] = "present|\(size)|\(modified)"
        }
        for relative in directories {
            let names = try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(relative).path)
            result[relative + "/"] = names.map { "entries|" + $0.sorted().joined(separator: ",") } ?? "absent"
        }
        return result
    }

    /// What changed between two snapshots. `full` compares everything; otherwise only whether each watched
    /// *file* exists (directory listings and file contents are skipped: a live app changes them).
    static func differences(before: [String: String], after: [String: String], full: Bool) -> [String] {
        var found: [String] = []
        for key in Set(before.keys).union(after.keys).sorted() {
            let (old, new) = (before[key] ?? "absent", after[key] ?? "absent")
            guard old != new else { continue }
            if !full {
                if key.hasSuffix("/") { continue }
                if old.hasPrefix("present") && new.hasPrefix("present") { continue }
            }
            found.append("\(key): \(old) -> \(new)")
        }
        return found
    }

    /// True when the operator's real Nostromo app is running (its bundle id, not a QA clone or a test host).
    static var realAppIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.hammer.nostromo").isEmpty
    }

    private static var baseline: [String: String]?

    /// Called once by the principal class, before any test runs.
    static func recordBaseline() {
        if baseline == nil { baseline = snapshot() }
    }

    static var hasBaseline: Bool { baseline != nil }

    static func currentDifferences(full: Bool) -> [String] {
        guard let baseline else { return ["no baseline: the test bundle's principal class did not run"] }
        return differences(before: baseline, after: snapshot(), full: full)
    }

    /// The assertion every `ZRealNostromoGuard*Tests` class makes.
    static func assertRealNostromoUntouched(file: StaticString = #filePath, line: UInt = #line) {
        let drift = currentDifferences(full: !realAppIsRunning)
        XCTAssertTrue(drift.isEmpty,
                      "the test run changed the real ~/.nostromo (a path that bypasses NostromoHome?):\n" + drift.joined(separator: "\n"),
                      file: file, line: line)
    }
}

/// Removes the per-process test home when the test bundle finishes.
final class TestHomeCleanup: NSObject, XCTestObservation {
    func testBundleDidFinish(_ testBundle: Bundle) {
        NostromoHome.removeTestHome()
    }
}

/// Named `Z...` so each sorts LAST in its shard (the shards run classes alphabetically). Three classes, one
/// per shard (`macOS/ci/mac-shards.json` lists a class once, and a shard runs only its own classes), so
/// every shard's process checks itself. Shard 3 is the catch-all and picks `Shard3` up with no config.
final class ZRealNostromoGuardShard1Tests: XCTestCase {
    func testTheRealNostromoDirectoryWasNotTouched() { RealNostromoGuard.assertRealNostromoUntouched() }
}

final class ZRealNostromoGuardShard2Tests: XCTestCase {
    func testTheRealNostromoDirectoryWasNotTouched() { RealNostromoGuard.assertRealNostromoUntouched() }
}

final class ZRealNostromoGuardShard3Tests: XCTestCase {
    func testTheRealNostromoDirectoryWasNotTouched() { RealNostromoGuard.assertRealNostromoUntouched() }
}
