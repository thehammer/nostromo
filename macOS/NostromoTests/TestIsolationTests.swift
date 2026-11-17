import XCTest
import AppKit
import SwiftUI

/// Guards the suite against test-order pollution: one class leaving process-wide state that breaks a class
/// that runs later in the same xctest process (it passes alone, fails after the polluter).
///
/// The one found so far: a test window that was ordered in and then closed with AppKit's default animation
/// parks a libdispatch worker in `NSAnimation _runBlocking` for good. The `AuthoredPr*` hand-off classes
/// (Picker, Preview, StartSession, TellButton) did that once per test; after ~60 the global pool was out of
/// workers and every later `DispatchQueue.global` job never ran, so `RepoOrgResolver` never answered
/// (NoCodebaseCreateTests, CreateFocusSheetLabelTests, RepoOrgTests, MainLayoutWindowTitleTests failed).
/// The fix is `animationBehavior = .none` on the shared window factories; this class fails at its source if a
/// factory regresses, and if anything else starves the pool.
///
/// The root fix is `TestBundleSetup` (the bundle's principal class): every NSWindow made in the process
/// defaults to `.none`, so no test file has to remember. The per-factory settings stay (harmless).
///
/// Mutation: make `TestBundleSetup.install()` a no-op (or drop `INFOPLIST_KEY_NSPrincipalClass`) ->
/// testEveryWindowRouteDefaultsToNoAnimation and ZPoolStarvationGuardTests fail on the real shards. Or delete the `animationBehavior = .none` line in `GestureFixtures.offscreenWindow` or `APT.window`
/// or `APT.inkHost` -> testSharedTestWindowFactoriesDoNotAnimate fails.
final class TestIsolationTests: XCTestCase {

    func testSharedTestWindowFactoriesDoNotAnimate() {
        let windows = [
            GestureFixtures.offscreenWindow(),
            APT.window(size: NSSize(width: 100, height: 100)),
            APT.inkHost(size: NSSize(width: 100, height: 100), appearance: .darkAqua).window,
        ]
        defer { windows.forEach { $0.contentView = nil; $0.close() } }
        for window in windows {
            XCTAssertEqual(window.animationBehavior, .none,
                           "a test window must not animate: its close parks a dispatch worker forever")
        }
    }

    /// Windows made the way test files make them, without any per-file `animationBehavior` line.
    func testEveryWindowRouteDefaultsToNoAnimation() {
        let rect = NSRect(x: 0, y: 0, width: 100, height: 100)
        let controller = NSWindowController(window: NSWindow(contentViewController: NSViewController()))
        let hosting = NSHostingController(rootView: Color.clear)
        let windows: [(String, NSWindow)] = [
            ("NSWindow(contentRect:)", NSWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: true)),
            ("NSWindow(contentRect:screen:)", NSWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: true, screen: nil)),
            ("NSPanel", NSPanel(contentRect: rect, styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: true)),
            ("NSWindow(contentViewController:)", NSWindow(contentViewController: NSViewController())),
            ("NSWindowController.window", controller.window!),
            ("NSWindow(contentViewController: hosting)", NSWindow(contentViewController: hosting)),
            ("NSWindow subclass", ProbeWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: true)),
        ]
        defer { windows.forEach { $0.1.contentView = nil; $0.1.close() } }
        for (route, window) in windows {
            XCTAssertEqual(window.animationBehavior, .none, "\(route) must default to no animation")
        }
    }

    /// Only `FullScreenTeardownLegalityTests` may ask for the default animation back, on purpose.
    func testNoTestFileReintroducesDefaultWindowAnimation() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let allowed: Set<String> = ["FullScreenTeardownLegalityTests.swift", "TestIsolationTests.swift"]
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && !allowed.contains($0.lastPathComponent) }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("animationBehavior = .default"),
                           "\(file.lastPathComponent) re-enables window animation, which can park a pool worker")
        }
    }

    func testTheGlobalQueuePoolStillRunsWorkAtEveryQoS() {
        // After the window-heavy classes ran before this one, a starved pool never runs these.
        for qos in [DispatchQoS.QoSClass.userInteractive, .userInitiated, .utility] {
            let ran = expectation(description: "global \(qos)")
            DispatchQueue.global(qos: qos).async { ran.fulfill() }
            wait(for: [ran], timeout: 2)
        }
    }

    func testAWindowTheHelpersMadeCanBeClosedWithoutLeavingTheMainRunLoopOrThePoolStuck() {
        let window = GestureFixtures.offscreenWindow()
        window.close()
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            DispatchQueue.global(qos: .userInteractive).async { settled.fulfill() }
        }
        wait(for: [settled], timeout: 5)
    }
}

private final class ProbeWindow: NSWindow {}

/// Named `Z...` so it sorts LAST: the shards run classes alphabetically, so this sits where the victims
/// (`NoCodebaseCreateTests`, `NostromodClientHandshakeTests`, ...) do and fails if anything earlier in the
/// run left the global pool short of workers. 64 concurrent user-interactive jobs need far more threads
/// than a pool that lost ~60 to parked animations has.
final class ZPoolStarvationGuardTests: XCTestCase {
    func testGlobalPoolStillServesManyConcurrentUserInteractiveJobs() {
        let n = 64
        let done = expectation(description: "all jobs ran")
        done.expectedFulfillmentCount = n
        for _ in 0..<n {
            DispatchQueue.global(qos: .userInteractive).async {
                Thread.sleep(forTimeInterval: 0.05)
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 10)
    }
}
