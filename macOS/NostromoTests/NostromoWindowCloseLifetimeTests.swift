import XCTest
import AppKit

// NostromoWindow.swift and DisplayTopology.swift are compiled into this target
// directly. Windows are never shown and no real display is touched.
//
// Required behavior: the app holds every NostromoWindow strongly (`windows`,
// `windowsByDisplayUUID`) and closes it when its display is removed. `close()` must
// not release the window on the app's behalf (`isReleasedWhenClosed == false`): under
// ARC that is one release too many, and the crash only surfaces later, when an
// autorelease pool pops (EXC_BAD_ACCESS in objc_release). So after a close the window
// stays alive for as long as the app holds it and is freed exactly once when the app
// lets go.
//
// SAFETY: with `isReleasedWhenClosed == true`, closing a strongly held window
// over-releases it and takes down the whole test bundle. Every test that closes a
// window therefore asserts the flag first and returns before `close()` when it is
// wrong, so the failure is a red assertion, not a crash.

private final class SubclassedWindow: NostromoWindow {}

private let contentRect = NSRect(x: 100, y: 100, width: 800, height: 600)
private let styleMask: NSWindow.StyleMask = [.titled, .resizable, .fullSizeContentView]

private func makeWindow() -> NostromoWindow {
    NostromoWindow(contentRect: contentRect, styleMask: styleMask, backing: .buffered, defer: true)
}

/// A window configured the way `AppDelegate` configures one it creates.
private func makeAppStyleWindow() -> NostromoWindow {
    let win = makeWindow()
    win.delegate = win
    win.isOrphanedByScreenRemoval = true
    win.animationBehavior = .none
    win.lifecycleHandler = nil
    return win
}

final class NostromoWindowCloseLifetimeTests: XCTestCase {

    private let displayUUID = "display-uuid-1"

    /// Drains autorelease pools and spins the run loop until `condition` holds (or 2s pass).
    @discardableResult
    private func spin(until condition: () -> Bool = { false }) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            autoreleasepool { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            if condition() { return true }
        } while Date() < deadline
        return condition()
    }

    // MARK: - WC-1 / WC-4

    func test_a_new_NostromoWindow_is_not_released_when_closed() {
        let window = makeWindow()
        XCTAssertFalse(window.isReleasedWhenClosed)
    }

    func test_a_subclass_of_NostromoWindow_is_not_released_when_closed() {
        let window = SubclassedWindow(contentRect: contentRect, styleMask: styleMask, backing: .buffered, defer: true)
        XCTAssertFalse(window.isReleasedWhenClosed)
    }

    // MARK: - WC-2a

    func test_closing_a_strongly_held_window_leaves_it_alive_and_frees_it_once_when_dropped() {
        weak var weakWindow: NostromoWindow?
        var windows: [NostromoWindow] = []
        var windowsByDisplayUUID: [String: NostromoWindow] = [:]
        autoreleasepool {
            let win = makeAppStyleWindow()
            weakWindow = win
            windows.append(win)
            windowsByDisplayUUID[displayUUID] = win
        }

        XCTAssertFalse(windows[0].isReleasedWhenClosed)
        guard !windows[0].isReleasedWhenClosed else { return }

        autoreleasepool { windows[0].close() }
        spin()

        XCTAssertNotNil(weakWindow, "close() must not release a window the app still holds")
        XCTAssertEqual(windows[0].isVisible, false)

        autoreleasepool {
            windows.removeAll()
            windowsByDisplayUUID.removeAll()
        }
        XCTAssertTrue(spin(until: { weakWindow == nil }),
                      "the window must be freed once the app drops its last reference")
    }

    // MARK: - WC-2b

    func test_display_removal_teardown_closes_the_window_once_and_it_is_freed_cleanly() {
        weak var weakWindow: NostromoWindow?
        var windows: [NostromoWindow] = []
        var windowsByDisplayUUID: [String: NostromoWindow] = [:]
        var willCloseCount = 0
        var observed: ObjectIdentifier?

        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: nil
        ) { note in
            if let object = note.object as AnyObject?, ObjectIdentifier(object) == observed {
                willCloseCount += 1
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        autoreleasepool {
            let win = makeWindow()
            win.delegate = win
            weakWindow = win
            observed = ObjectIdentifier(win)
            windows.append(win)
            windowsByDisplayUUID[displayUUID] = win
        }

        XCTAssertFalse(windows[0].isReleasedWhenClosed)
        guard !windows[0].isReleasedWhenClosed else { return }

        // The same steps `AppDelegate.closeWindowForVanishedDisplay` runs. The teardown
        // unbinds the window from `windows` / `windowsByDisplayUUID` itself; the local
        // `win` is the only strong reference left and ends with this scope.
        autoreleasepool {
            let win = windows[0]
            VanishedWindowTeardown.run(.init(
                unbindKey: { windowsByDisplayUUID.removeValue(forKey: self.displayUUID) },
                dropController: {},
                removeFromWindows: { windows.removeAll { $0 === win } },
                afterUnbind: {},
                prepareWindow: {
                    win.isOrphanedByScreenRemoval = true
                    win.animationBehavior = .none
                    win.lifecycleHandler = nil
                },
                dropFullScreenMask: {
                    guard win.styleMask.contains(.fullScreen) else { return }
                    var mask = win.styleMask
                    mask.remove(.fullScreen)
                    win.styleMask = mask
                },
                close: { win.close() }
            ))
            XCTAssertFalse(win.isVisible)
            // The app still holds the window across the teardown (AppDelegate's local `win`).
            XCTAssertNotNil(weakWindow)
        }
        spin()

        XCTAssertEqual(willCloseCount, 1, "willCloseNotification is posted exactly once per close")
        XCTAssertTrue(spin(until: { weakWindow == nil }),
                      "once the teardown has unbound the window and its scope ends, it must be freed")
    }
}
