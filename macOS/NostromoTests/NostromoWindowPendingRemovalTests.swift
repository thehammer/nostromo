import XCTest
import AppKit

// NostromoWindow.swift is compiled into this target directly. The window is never
// shown, no real display is touched and time is a manual clock injected through
// `NostromoWindow.scheduler`, so nothing here uses the wall clock.
//
// Required behavior: a window whose display vanished (its close is waiting out the
// grace, `isPendingScreenRemoval`) must not re-enter full-screen after a
// full-screen exit: entering full-screen creates a Space on a display that is
// about to lose its window. When the display returns (flag cleared) the re-entry
// resumes, exactly once.

/// A manual clock: `advance(by:)` fires every closure that falls due, in time
/// order (ties in scheduling order), including closures scheduled while firing.
private final class ManualClock: PlacementScheduler {
    private(set) var now: TimeInterval = 0
    private var queue: [(due: TimeInterval, seq: Int, work: () -> Void)] = []
    private var seq = 0

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
        seq += 1
        queue.append((now + max(delay, 0), seq, work))
    }

    func advance(by interval: TimeInterval) {
        let target = now + interval
        while let index = nextDueIndex(upTo: target) {
            let item = queue.remove(at: index)
            now = max(now, item.due)
            item.work()
        }
        now = target
    }

    private func nextDueIndex(upTo target: TimeInterval) -> Int? {
        var best: Int?
        for (i, item) in queue.enumerated() where item.due <= target {
            if let b = best {
                if (item.due, item.seq) < (queue[b].due, queue[b].seq) { best = i }
            } else {
                best = i
            }
        }
        return best
    }
}

/// Records `toggleFullScreen` instead of asking AppKit to do it.
private final class RecordingWindow: NostromoWindow {
    private(set) var toggleCalls = 0
    override func toggleFullScreen(_ sender: Any?) { toggleCalls += 1 }
}

final class NostromoWindowPendingRemovalTests: XCTestCase {

    private var clock: ManualClock!
    private var window: RecordingWindow!

    /// Slack past `reentryDelay` so the tests do not pin the exact resume timing.
    private let margin: TimeInterval = 1.0
    private var reentryDelay: TimeInterval { NostromoWindow.reentryDelay }

    override func setUp() {
        super.setUp()
        clock = ManualClock()
        window = RecordingWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true)
        window.scheduler = clock
    }

    override func tearDown() {
        window = nil
        clock = nil
        super.tearDown()
    }

    /// AppKit reports that the window left full-screen (the window is not full-screen).
    private func exitFullScreen() {
        XCTAssertFalse(window.styleMask.contains(.fullScreen), "precondition: the window is not full-screen")
        window.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification))
    }

    // MARK: Unchanged behavior

    func test_with_nothing_pending_the_window_re_enters_full_screen_once_after_the_re_entry_delay() {
        XCTAssertFalse(window.isPendingScreenRemoval)

        exitFullScreen()
        clock.advance(by: reentryDelay - 0.5)
        XCTAssertEqual(window.toggleCalls, 0, "not before the re-entry delay")

        clock.advance(by: 0.5 + margin)
        XCTAssertEqual(window.toggleCalls, 1)

        clock.advance(by: 60)
        XCTAssertEqual(window.toggleCalls, 1, "re-enters exactly once")
    }

    // MARK: Pending removal blocks the re-entry

    func test_a_window_pending_removal_does_not_re_enter_full_screen() {
        window.isPendingScreenRemoval = true

        exitFullScreen()
        clock.advance(by: reentryDelay + margin)
        XCTAssertEqual(window.toggleCalls, 0, "a doomed window must not enter full-screen")

        clock.advance(by: 60)
        XCTAssertEqual(window.toggleCalls, 0, "and does not keep trying while it stays doomed")
    }

    func test_a_flag_set_after_the_exit_but_before_the_re_entry_timer_fires_blocks_the_re_entry() {
        exitFullScreen()
        clock.advance(by: 1.0)
        window.isPendingScreenRemoval = true            // the display vanished mid-wait

        clock.advance(by: reentryDelay + margin)
        XCTAssertEqual(window.toggleCalls, 0, "the timer fires into a doomed window: no toggle")

        clock.advance(by: 60)
        XCTAssertEqual(window.toggleCalls, 0)
    }

    // MARK: Clearing the flag resumes the re-entry

    func test_clearing_the_flag_after_the_timer_was_blocked_resumes_the_re_entry_exactly_once() {
        window.isPendingScreenRemoval = true
        exitFullScreen()
        clock.advance(by: reentryDelay + margin)
        XCTAssertEqual(window.toggleCalls, 0)

        window.isPendingScreenRemoval = false           // the display returned
        clock.advance(by: reentryDelay + margin)
        XCTAssertEqual(window.toggleCalls, 1, "the re-entry resumes")

        clock.advance(by: 60)
        XCTAssertEqual(window.toggleCalls, 1, "exactly once")
    }

    func test_a_flag_set_after_the_exit_resumes_the_re_entry_once_it_clears() {
        exitFullScreen()
        clock.advance(by: 1.0)
        window.isPendingScreenRemoval = true
        clock.advance(by: reentryDelay + margin)
        XCTAssertEqual(window.toggleCalls, 0)

        window.isPendingScreenRemoval = false
        clock.advance(by: reentryDelay + margin)
        XCTAssertEqual(window.toggleCalls, 1)

        clock.advance(by: 60)
        XCTAssertEqual(window.toggleCalls, 1)
    }

    func test_a_flag_that_comes_and_goes_inside_the_wait_does_not_double_the_re_entry() {
        exitFullScreen()
        window.isPendingScreenRemoval = true
        clock.advance(by: 1.0)
        window.isPendingScreenRemoval = false           // cleared before the original timer fires

        clock.advance(by: reentryDelay + margin)
        clock.advance(by: 60)

        XCTAssertEqual(window.toggleCalls, 1, "the original timer and a resume must not both toggle")
    }

    func test_setting_and_clearing_the_flag_without_a_pending_re_entry_never_toggles() {
        window.isPendingScreenRemoval = true
        window.isPendingScreenRemoval = false
        clock.advance(by: 60)

        XCTAssertEqual(window.toggleCalls, 0, "clearing the flag resumes a blocked re-entry only; it never starts one")
    }
}
