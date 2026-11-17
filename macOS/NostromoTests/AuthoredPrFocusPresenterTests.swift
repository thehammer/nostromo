import XCTest
import AppKit
import NostromoKit

// Showing the focus after a send: the window that already shows it, or the window the person clicked in,
// with the keyboard in the focus's input.
//
// Contract.
//  * A window already showing the focus is raised and its input takes the keyboard; the window the click came
//    from is left alone.
//  * Otherwise the window the click came from switches to the focus (then comes forward), and its input takes
//    the keyboard.
//  * The app is brought forward.
//  * A focus that is still arriving (a session the daemon just created) is waited for: the switch and the
//    input focus are retried, and given up after a bounded number of tries.
//  * A real transcript pane puts the keyboard in its input when asked.
//
// Mutations (to be run by hand), and the test that fails for each:
//   M1 the presenter always switches the origin window    -> testAWindowAlreadyShowingTheFocusIsRaisedAndTheOriginIsLeftAlone
//   M2 the presenter forgets to activate the app          -> testTheAppIsBroughtForward
//   M3 no retry while the focus is arriving               -> testItRetriesWhileTheFocusIsStillArriving
//   M4 retries never stop                                 -> testItGivesUpAfterItsAttempts
//   M6 the window is ordered front on every retry          -> testTheWindowIsOrderedFrontOnceHoweverLongTheFocusTakesToArrive
//   M7 the default attempts go back to 20                   -> testTheDefaultRetryBoundIsAtMostTenTries
//   M5 `focusInput` does not make the input first responder -> testAReplViewTakesTheKeyboardInItsInput
final class AuthoredPrFocusPresenterTests: MouseQueueTestCase {

    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.contentView = nil; window.close() }
        windows = []
        super.tearDown()
    }

    private func makeWindow() -> NSWindow {
        let window = APT.window(size: NSSize(width: 300, height: 200))
        windows.append(window)
        return window
    }

    func testAWindowAlreadyShowingTheFocusIsRaisedAndTheOriginIsLeftAlone() {
        let origin = FakeFocusHost(window: makeWindow(), shows: "other", openTags: ["cody-1"])
        let showing = FakeFocusHost(window: makeWindow(), shows: "cody-1", openTags: ["cody-1"])
        let counters = PresenterCounters()
        let presenter = makeFakePresenter(hosts: { [origin, showing] in [origin, showing] }, counters: counters)

        presenter.show(tag: "cody-1", from: origin.nsWindow)

        XCTAssertEqual(showing.log, ["bringToFront", "focusInput"], "the window that shows it comes forward and takes the keyboard")
        XCTAssertTrue(origin.log.isEmpty, "the window the click came from does not switch")
    }

    func testOtherwiseTheOriginWindowSwitchesThenTakesTheKeyboard() {
        let origin = FakeFocusHost(window: makeWindow(), shows: "other", openTags: ["cody-1", "other"])
        let bystander = FakeFocusHost(window: makeWindow(), shows: "third", openTags: ["cody-1"])
        let presenter = makeFakePresenter(hosts: { [bystander, origin] in [bystander, origin] })

        presenter.show(tag: "cody-1", from: origin.nsWindow)

        XCTAssertEqual(origin.log, ["switchTo:cody-1", "bringToFront", "focusInput"],
                       "the window the person clicked in switches to the focus, then its input takes the keyboard")
        XCTAssertEqual(origin.shownFocusTag, "cody-1")
        XCTAssertTrue(bystander.log.isEmpty, "another window is not touched")
    }

    func testTheAppIsBroughtForward() {
        let origin = FakeFocusHost(window: makeWindow(), openTags: ["cody-1"])
        let counters = PresenterCounters()
        let presenter = makeFakePresenter(hosts: { [origin] in [origin] }, counters: counters)
        presenter.show(tag: "cody-1", from: origin.nsWindow)
        XCTAssertGreaterThanOrEqual(counters.activations, 1)
    }

    func testItRetriesWhileTheFocusIsStillArriving() throws {
        // The focus appears on the third try; its input is on screen one try after that.
        let origin = FakeFocusHost(window: makeWindow(), openTags: ["cody-new"], inputReadyAfter: 1, switchReadyAfter: 2)
        let counters = PresenterCounters()
        let presenter = makeFakePresenter(hosts: { [origin] in [origin] }, counters: counters)

        presenter.show(tag: "cody-new", from: origin.nsWindow)

        XCTAssertEqual(origin.shownFocusTag, "cody-new", "it got there in the end")
        XCTAssertEqual(origin.switchCalls, 3, "asked until the focus was there")
        XCTAssertGreaterThanOrEqual(origin.inputCalls, 2, "and until its input could take the keyboard")
        XCTAssertEqual(origin.log.last, "focusInput")
        XCTAssertFalse(counters.delays.isEmpty, "it waited between tries")
        XCTAssertLessThan(try XCTUnwrap(counters.delays.max()), 2, "a short wait: the person is watching")
    }

    func testTheWindowIsOrderedFrontOnceHoweverLongTheFocusTakesToArrive() {
        // The window shows the focus at once, but its input is on screen only on the fifth try.
        let showing = FakeFocusHost(window: makeWindow(), shows: "cody-1", openTags: ["cody-1"], inputReadyAfter: 4)
        let presenter = makeFakePresenter(hosts: { [showing] in [showing] })

        presenter.show(tag: "cody-1", from: nil)

        XCTAssertGreaterThanOrEqual(showing.inputCalls, 5, "precondition: it retried")
        XCTAssertEqual(showing.log.filter { $0 == "bringToFront" }.count, 1, "ordered front once, not on every retry")
    }

    func testTheDefaultRetryBoundIsAtMostTenTries() {
        let origin = FakeFocusHost(window: makeWindow(), openTags: [])
        let presenter = makeFakePresenter(hosts: { [origin] in [origin] })
        presenter.show(tag: "never", from: origin.nsWindow)
        XCTAssertLessThanOrEqual(origin.switchCalls, 10, "a second of waiting at most")
        XCTAssertGreaterThan(origin.switchCalls, 1)
    }

    func testItGivesUpAfterItsAttempts() {
        let origin = FakeFocusHost(window: makeWindow(), openTags: [])   // the focus never appears
        let counters = PresenterCounters()
        let presenter = makeFakePresenter(hosts: { [origin] in [origin] }, counters: counters)
        presenter.attempts = 4

        presenter.show(tag: "never", from: origin.nsWindow)

        XCTAssertEqual(origin.switchCalls, 4, "it tried exactly as often as it was allowed")
        XCTAssertEqual(counters.delays.count, 3, "and waited between the tries")
        XCTAssertNil(origin.shownFocusTag)
    }

    func testWithNoWindowAtAllItDoesNotCrashAndGivesUp() {
        let counters = PresenterCounters()
        let presenter = makeFakePresenter(hosts: { [] }, counters: counters)
        presenter.attempts = 3
        presenter.show(tag: "cody-1", from: nil)
        XCTAssertEqual(counters.delays.count, 2)
        XCTAssertEqual(counters.activations, 0, "nothing to show: the app is not pulled forward for nothing")
    }

    // MARK: - A real pane

    func testAReplViewTakesTheKeyboardInItsInput() throws {
        let tag = "focus-presenter-\(UUID().uuidString)"
        let repl = ReplView(tag: tag)
        repl.renderWatch.captureDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("focus-presenter-\(UUID().uuidString)", isDirectory: true)
        repl.renderWatch.visibilityOverride = true
        let size = NSSize(width: 800, height: 600)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: size),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none   // a closing window with an animation parks a pool thread (see TestIsolationTests)
        repl.frame = NSRect(origin: .zero, size: size)
        window.contentView = repl
        window.orderFrontRegardless()
        addTeardownBlock {
            repl.renderWatch.visibilityOverride = false
            window.orderOut(nil)
            window.contentView = nil
            window.close()
            AppStore.shared.session(for: tag).detach()
        }
        repl.layoutSubtreeIfNeeded()
        _ = window.makeFirstResponder(nil)
        XCTAssertFalse(window.firstResponder is NSTextView, "precondition: the keyboard is not in an input")

        XCTAssertTrue(repl.focusInput(), "the input took the keyboard")

        let responder = try XCTUnwrap(window.firstResponder as? NSTextView, "the first responder is a text view")
        XCTAssertTrue(responder.isDescendant(of: repl), "and it is this pane's input")
        XCTAssertTrue(responder.isEditable, "an input a person can type into")
    }

    func testAReplViewOutOfAWindowCannotTakeTheKeyboard() {
        let tag = "focus-presenter-\(UUID().uuidString)"
        let repl = ReplView(tag: tag)
        addTeardownBlock { AppStore.shared.session(for: tag).detach() }
        repl.renderWatch.captureDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("focus-presenter-\(UUID().uuidString)", isDirectory: true)
        XCTAssertFalse(repl.focusInput(), "not on screen yet: the presenter tries again")
    }
}
