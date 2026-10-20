import XCTest

// NostromoHome.swift is compiled into this target directly. Only temp directories are touched,
// never the real ~/.nostromo.

final class NostromoHomeTests: XCTestCase {

    private let qaBundleID = "com.hammer.nostromo.qa"
    private let realBundleID = "com.hammer.nostromo"
    private let envKey = "NOSTROMO_QA_HOME"
    private let realHome = URL(fileURLWithPath: "/Users/someone-real", isDirectory: true)

    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NostromoHomeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        try super.tearDownWithError()
    }

    private func resolve(env: [String: String], bundleID: String?) -> String {
        NostromoHome.url(env: env, bundleID: bundleID, realHome: realHome).path
    }

    func testQABundleWithAnExistingAbsoluteDirectoryUsesIt() {
        let got = resolve(env: [envKey: tempRoot.path], bundleID: qaBundleID)
        XCTAssertEqual(got, tempRoot.path)
    }

    func testQABundleWithARelativePathFallsBackToTheRealHome() {
        XCTAssertEqual(resolve(env: [envKey: "relative/home"], bundleID: qaBundleID), realHome.path)
    }

    func testQABundleWithAMissingDirectoryFallsBackToTheRealHome() {
        let missing = tempRoot.appendingPathComponent("does-not-exist").path
        XCTAssertEqual(resolve(env: [envKey: missing], bundleID: qaBundleID), realHome.path)
    }

    func testQABundleWithAFileInsteadOfADirectoryFallsBackToTheRealHome() throws {
        let file = tempRoot.appendingPathComponent("a-file")
        try Data("x".utf8).write(to: file)
        XCTAssertEqual(resolve(env: [envKey: file.path], bundleID: qaBundleID), realHome.path)
    }

    func testQABundleWithTheVariableUnsetUsesTheRealHome() {
        XCTAssertEqual(resolve(env: [:], bundleID: qaBundleID), realHome.path)
    }

    func testTheRealBundleIgnoresTheVariableEvenForAnExistingDirectory() {
        XCTAssertEqual(resolve(env: [envKey: tempRoot.path], bundleID: realBundleID), realHome.path)
    }

    func testAMissingBundleIDIgnoresTheVariable() {
        XCTAssertEqual(resolve(env: [envKey: tempRoot.path], bundleID: nil), realHome.path)
    }
}
