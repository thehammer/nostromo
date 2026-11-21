import AppKit
import Foundation
import XCTest

/// Spins the main run loop until `condition` holds and returns the moment it does (true), or false after
/// `timeout` seconds. The event is the exit, so a fast machine pays nothing and a loaded one (CI, a starved
/// global pool) gets the whole cap instead of a fixed guess. Fails with `description` on a timeout.
@discardableResult
func waitUntil(_ description: @autoclosure () -> String, timeout: TimeInterval = 15,
               file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
    let held = condition()
    if !held { XCTFail("timed out after \(timeout) s: \(description())", file: file, line: line) }
    return held
}

/// Lets already-queued (and soon-queued) main work run for a short, bounded time. Use it AFTER an event has
/// been observed, so an exact-count or "must not happen" assertion still sees a stray late arrival; never
/// as the wait for the event itself.
func drainMain(for seconds: TimeInterval = 0.15) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
}

/// Returns once every block already queued on the main queue has run: a marker is enqueued behind them and
/// waited for. The deterministic partner of `queue.sync {}` for code that hops `queue.async { ...
/// DispatchQueue.main.async { ... } }`: after the `sync`, the hop is already queued, so the marker runs
/// after it. No fixed delay, so nothing to outlast and nothing to pass vacuously.
func flushMain(file: StaticString = #filePath, line: UInt = #line) {
    var reached = false
    DispatchQueue.main.async { reached = true }
    waitUntil("the main queue never reached the flush marker", file: file, line: line) { reached }
}

// MARK: - Font precondition

/// The pinned code font the rendered-height goldens were recorded with (CI installs Fira Code Nerd Font).
/// Without it `Theme.codeFont` quietly falls back to the system mono face, the fallback sticks in
/// `codeFontCache` for the whole process, and the height goldens fail with a pile of unrelated-looking
/// mismatches. Call from `setUpWithError` of every class whose goldens depend on it.
///
/// A missing font FAILS the test with a clear message and stops it (`continueAfterFailure = false`).
/// There is one escape hatch, for a laptop without the font and only by the owner's choice: set
/// `NOSTROMO_ALLOW_MISSING_FIRA=1` in the environment to turn the failure into a skip. CI never sets it.
func requireFiraCodeNerdFont(_ testCase: XCTestCase) throws {
    let installed = NSFont(name: "FiraCodeNF-Reg", size: 13) != nil
    if !installed, ProcessInfo.processInfo.environment["NOSTROMO_ALLOW_MISSING_FIRA"] == "1" {
        throw XCTSkip("Fira Code Nerd Font is not installed and NOSTROMO_ALLOW_MISSING_FIRA=1 is set")
    }
    testCase.continueAfterFailure = false
    XCTAssertNotNil(NSFont(name: "FiraCodeNF-Reg", size: 13),
                    "Fira Code Nerd Font is not installed: the rendered-height goldens were recorded with it")
}
