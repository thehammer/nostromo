import Foundation

/// The directory that contains `.nostromo` for this process, and the single seam through which the Mac app
/// reaches the user's state on disk (`~/.nostromo`, `~/.mother`, `~/.claude`, `~/Library/Application Support`).
///
/// `FileManager.homeDirectoryForCurrentUser` comes from the system user database and ignores the
/// `HOME` a launcher sets, so the isolated QA clone (`com.hammer.nostromo.qa`) used to write into the
/// user's real `~/.nostromo`. Every path under `~/.nostromo` is built from `NostromoHome.current`.
///
/// Only the QA bundle id can be redirected (by `NOSTROMO_QA_HOME`, an absolute path of an existing
/// directory). The real app (`com.hammer.nostromo`) gets the real home whatever the environment says,
/// so a stray variable can never move the user's state.
///
/// Under XCTest every path here resolves into a per-process temporary directory (`testHome`), removed when the
/// test bundle finishes, so no test can read, write or delete the operator's real data. The decision is made in
/// `url(env:bundleID:realHome:underTests:testHome:)`, which takes "running under tests" as a parameter; the one
/// place that detects XCTest is `isRunningUnderTests`. A policy test (`tests/state_path_policy`) fails when source
/// outside this file builds a `.nostromo` path or asks the system for the home directory.
enum NostromoHome {
    static let qaBundleID = "com.hammer.nostromo.qa"
    static let qaHomeEnvKey = "NOSTROMO_QA_HOME"

    /// Pure rule behind `current`; env, bundle id, real home and whether this is a test run are injected so
    /// it is testable. Under tests the answer is `testHome`, whatever the environment or bundle id says.
    static func url(env: [String: String], bundleID: String?, realHome: URL,
                    underTests: Bool = false, testHome: @autoclosure () -> URL = NostromoHome.testHome) -> URL {
        if underTests { return testHome() }
        guard bundleID == qaBundleID,
              let path = env[qaHomeEnvKey],
              path.hasPrefix("/")
        else { return realHome }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return realHome }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// True only for the QA clone's bundle id (exactly). The QA instance must never start Mother.
    static func isQAInstance(bundleID: String?) -> Bool {
        bundleID == qaBundleID
    }

    static var isQAInstance: Bool {
        isQAInstance(bundleID: Bundle.main.bundleIdentifier)
    }

    /// Whether an offline broker should trigger `mother daemon start`: never for the QA clone.
    static func shouldAttemptMotherDaemonStart(brokerConnected: Bool, isQA: Bool) -> Bool {
        !brokerConnected && !isQA
    }

    /// This process's home: the QA clone's own home under QA, the temporary test home under XCTest, else the
    /// user's real home.
    static var current: URL {
        url(env: ProcessInfo.processInfo.environment,
            bundleID: Bundle.main.bundleIdentifier,
            realHome: FileManager.default.homeDirectoryForCurrentUser,
            underTests: isRunningUnderTests)
    }

    /// The user's home for state that belongs to other tools (`~/.claude`, `~/.mother`, `~/Library`): never the
    /// QA clone's redirect (QA still reads the real Claude and Mother state), but the temporary home under XCTest.
    static var userHome: URL {
        isRunningUnderTests ? testHome : FileManager.default.homeDirectoryForCurrentUser
    }

    /// `~/Library/Application Support` for this process (inside the temporary home under XCTest).
    static var applicationSupportDirectory: URL {
        if isRunningUnderTests {
            return testHome.appendingPathComponent("Library/Application Support", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    // MARK: - Running under tests

    /// The one place XCTest is detected: the test bundle loads `XCTestCase`, the app never does.
    static let isRunningUnderTests: Bool = NSClassFromString("XCTestCase") != nil

    /// `<tmp>/nostromo-tests-<pid>/home`, created on first use. One per test process, so concurrent test
    /// processes never share it, and `removeTestHome()` takes it away when the run ends.
    static let testHome: URL = {
        removeTestHome()   // a crashed earlier run may have left this pid's directory behind
        let home = testRoot.appendingPathComponent("home", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }()

    static let testRootPrefix = "nostromo-tests-"

    static var testRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(testRootPrefix)\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }

    /// Delete this process's temporary home. Refuses anything that is not a `nostromo-tests-` directory directly
    /// under the temporary directory, so it can never remove real state.
    @discardableResult
    static func removeTestHome(root: URL = testRoot,
                               temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> Bool {
        let parent = root.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
        guard root.lastPathComponent.hasPrefix(testRootPrefix),
              parent == temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        else { return false }
        try? FileManager.default.removeItem(at: root)
        return true
    }
}
