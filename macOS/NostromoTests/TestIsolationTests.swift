import XCTest
import AppKit

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
/// Mutation: delete the `animationBehavior = .none` line in `GestureFixtures.offscreenWindow` or `APT.window`
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
