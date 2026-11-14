import XCTest
import AppKit
import WebKit

// Perri side pane, slice 2: the container that puts the review pane beside a Perri focus.
//
//   * opening then closing a tab leaves every leaf of the focus exactly where it was (16, within 0.5 pt)
//   * the pane is there synchronously when a tab is opened, well inside 150 ms (11)
//   * opening a tab that already exists loads nothing again and keeps the page's scroll position (12)
//   * the saved width fraction is reapplied after hide/show and after rebuilding from the store (17)
//   * 420 pt for the focus and 380 pt for the pane hold whenever the container is wide enough for both
//
// The focus is a stand-in view with nested split views whose children keep fixed fractions (the way the
// real focus re-applies its saved ratios), so any drift seen here comes from the container, not the stand-in.
// Pages come from the fixture scheme: nothing touches the network.

/// A split view that lays its children out by fixed fractions, whatever size it is resized to.
private final class FractionSplit: NSSplitView {
    var fractions: [CGFloat] = []

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        guard fractions.count == subviews.count else { return super.resizeSubviews(withOldSize: oldSize) }
        let gaps = dividerThickness * CGFloat(subviews.count - 1)
        let total = (isVertical ? bounds.width : bounds.height) - gaps
        var offset: CGFloat = 0
        for (view, fraction) in zip(subviews, fractions) {
            let size = total * fraction
            view.frame = isVertical
                ? NSRect(x: offset, y: 0, width: size, height: bounds.height)
                : NSRect(x: 0, y: offset, width: bounds.width, height: size)
            offset += size + dividerThickness
        }
    }
}

private final class Leaf: NSView {
    let name: String
    init(_ name: String) { self.name = name; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var acceptsFirstResponder: Bool { true }
}

/// What a Perri focus looks like to the container: one view with split views nested inside.
private final class StandInFocus: NSView {
    let columns = FractionSplit()
    let rightRows = FractionSplit()
    let leaves = [Leaf("repl"), Leaf("queue"), Leaf("notes")]

    init() {
        super.init(frame: .zero)
        columns.isVertical = true
        columns.dividerStyle = .thin
        rightRows.isVertical = false
        rightRows.dividerStyle = .thin
        rightRows.fractions = [0.43, 0.57]
        rightRows.addSubview(leaves[1])
        rightRows.addSubview(leaves[2])
        columns.fractions = [0.37, 0.63]
        columns.addSubview(leaves[0])
        columns.addSubview(rightRows)
        columns.autoresizingMask = [.width, .height]
        addSubview(columns)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        columns.frame = bounds
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        columns.frame = NSRect(origin: .zero, size: newSize)
    }
}

@MainActor
final class PerriFocusContainerLayoutTests: XCTestCase {

    private let pr = ReviewPR(repo: "acme/web", number: 7)

    private struct Rig {
        let world: ReviewFixtureWorld
        let model: ReviewPaneModel
        let focus: StandInFocus
        let container: PerriFocusContainerView
        let window: ReviewTestWindow
    }

    private var rigs: [Rig] = []
    private var worlds: [ReviewFixtureWorld] = []

    private func makeRig(width: CGFloat = 1000, store: ReviewPaneStore? = nil, tag: String = "perri-layout",
                         world: ReviewFixtureWorld? = nil) -> Rig {
        let world = world ?? ReviewFixtureWorld()
        if !worlds.contains(where: { $0 === world }) { worlds.append(world) }
        let model = ReviewPaneModel(tag: tag, store: store)
        model.environment = world.environment      // before anything can be shown
        model.unsentCheck = { _ in false }
        let focus = StandInFocus()
        let container = PerriFocusContainerView(focusView: focus, model: model)
        let window = ReviewTestWindow.make(size: NSSize(width: width, height: 700))
        window.contentView = container
        container.layoutSubtreeIfNeeded()
        let rig = Rig(world: world, model: model, focus: focus, container: container, window: window)
        rigs.append(rig)
        return rig
    }

    override func tearDown() async throws {
        for rig in rigs {
            for tab in rig.model.tabs { rig.model.close(tab) }
            rig.window.contentView = NSView()
            rig.window.close()
        }
        rigs = []
        spin(0.3)
        for world in worlds { await world.removeDataStore() }
        worlds = []
        try await super.tearDown()
    }

    private func store() throws -> ReviewPaneStore {
        let suite = "PerriFocusContainerLayoutTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return ReviewPaneStore(defaults: defaults, jiraSite: { nil })
    }

    @discardableResult
    private func openTab(_ rig: Rig, _ target: ReviewTarget = .conversation, path: String = "/acme/web/pull/7") -> ReviewTab {
        rig.model.open(pr: pr, target: target, url: reviewFixtureURL("github.com\(path)"))
    }

    /// Every leaf of the focus, in the container's coordinates.
    private func leafFrames(_ rig: Rig) -> [(String, NSRect)] {
        rig.container.layoutSubtreeIfNeeded()
        return rig.focus.leaves.map { ($0.name, $0.convert($0.bounds, to: rig.container)) }
    }

    private func assertFrames(_ a: [(String, NSRect)], equal b: [(String, NSRect)], accuracy: CGFloat = 0.5,
                              _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, file: file, line: line)
        for ((name, x), (_, y)) in zip(a, b) {
            XCTAssertEqual(x.minX, y.minX, accuracy: accuracy, "\(name) x: \(message)", file: file, line: line)
            XCTAssertEqual(x.minY, y.minY, accuracy: accuracy, "\(name) y: \(message)", file: file, line: line)
            XCTAssertEqual(x.width, y.width, accuracy: accuracy, "\(name) width: \(message)", file: file, line: line)
            XCTAssertEqual(x.height, y.height, accuracy: accuracy, "\(name) height: \(message)", file: file, line: line)
        }
    }

    // MARK: 16: the focus does not drift

    func testOpeningAndClosingATabLeavesEveryLeafWhereItWas() {
        let rig = makeRig()
        let before = leafFrames(rig)
        XCTAssertGreaterThan(before[0].1.width, 0, "precondition: the focus is laid out")

        for cycle in 1...3 {
            let tab = openTab(rig)
            let during = leafFrames(rig)
            XCTAssertLessThan(during[0].1.width, before[0].1.width, "the pane took room from the focus (cycle \(cycle))")
            rig.model.close(tab)
            spin(0.1)
            assertFrames(leafFrames(rig), equal: before, "after cycle \(cycle)")
        }
    }

    func testTheFocusFillsTheContainerAgainWhenTheLastTabCloses() {
        let rig = makeRig()
        let tab = openTab(rig)
        XCTAssertTrue(rig.container.isPaneShown)
        rig.model.close(tab)
        XCTAssertFalse(rig.container.isPaneShown)
        XCTAssertNil(rig.container.pane.superview, "the pane is removed, not hidden behind")
        XCTAssertEqual(rig.focus.frame.width, rig.container.bounds.width, accuracy: 0.5)
        XCTAssertEqual(rig.focus.frame.height, rig.container.bounds.height, accuracy: 0.5)
    }

    func testResizingWhileThePaneIsOpenThenClosingMatchesAContainerThatNeverHadOne() {
        let rig = makeRig(width: 1000)
        let tab = openTab(rig)
        rig.window.setContentSize(NSSize(width: 900, height: 640))
        rig.container.layoutSubtreeIfNeeded()
        rig.model.close(tab)
        spin(0.1)

        let fresh = makeRig(width: 900)
        fresh.window.setContentSize(NSSize(width: 900, height: 640))
        assertFrames(leafFrames(rig), equal: leafFrames(fresh), "same size, one had a pane for a while")
    }

    // MARK: 11: the pane is there at once

    func testThePaneIsPresentSynchronouslyInsideOpenAndWellInsideOneFiftyMilliseconds() {
        // The first web view in a process pays for WebKit's start-up; the person's first tab is not a cold start.
        let warm = makeRig()
        warm.model.close(openTab(warm))
        spin(0.3)

        let rig = makeRig()
        XCTAssertFalse(rig.container.isPaneShown)

        let start = CFAbsoluteTimeGetCurrent()
        let tab = openTab(rig)
        rig.container.layoutSubtreeIfNeeded()
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let split = rig.container.subviews.compactMap { $0 as? ReviewSplitView }.first
        let frames = "container \(rig.container.frame), split \(String(describing: split?.frame)), focus \(rig.focus.frame), pane \(rig.container.pane.frame)"
        XCTAssertTrue(rig.container.isPaneShown, "no run loop turn was needed")
        XCTAssertNotNil(rig.container.pane.superview)
        XCTAssertTrue(rig.container.pane.window === rig.window)
        XCTAssertGreaterThanOrEqual(rig.container.pane.frame.width, PerriFocusContainerView.minimumPaneWidth - 0.5,
                                    "the pane has its width the moment it appears: \(frames)")
        XCTAssertEqual(rig.container.pane.strip.items.count, 1, "its tab strip shows the tab")
        XCTAssertNotNil(tab.controller, "and the tab's web view exists")
        XCTAssertNotNil(tab.controller?.webView.superview, "in the pane")
        XCTAssertLessThan(elapsed, 0.150, "\(Int(elapsed * 1000)) ms")
    }

    func testThePaneAppearsOnTheFirstTabOnlyAndSecondTabsJoinIt() {
        let rig = makeRig()
        openTab(rig, .conversation)
        let width = rig.container.pane.frame.width
        openTab(rig, .diff, path: "/acme/web/pull/7/files")
        XCTAssertEqual(rig.container.pane.frame.width, width, accuracy: 0.5, "the pane did not move for the second tab")
        XCTAssertEqual(rig.container.pane.strip.items.count, 2)
    }

    // MARK: 12: re-opening makes no second load and keeps the scroll

    private func tallPage() -> String {
        ReviewFixtureHandler.html("<div style=\"height:4000px\">tall</div>")
    }

    func testReopeningAnExistingTabLoadsNothingAgainAndKeepsTheScrollOffset() async throws {
        let rig = makeRig()
        rig.world.handler.respond = { [self] url in
            ReviewFixtureHandler.Response(body: url.path == "/acme/web/pull/7" ? self.tallPage() : ReviewFixtureHandler.html("<p>\(url.path)</p>"))
        }
        let tab = openTab(rig)
        let controller = try XCTUnwrap(tab.controller)
        XCTAssertTrue(spinUntil(15) { !controller.webView.isLoading && controller.webView.url == tab.startURL })
        _ = try await controller.webView.evaluateJavaScript("window.scrollTo(0, 400); true")
        var scrolled = false
        for _ in 0..<100 where !scrolled {
            scrolled = (try? await controller.webView.evaluateJavaScript("window.scrollY") as? Double) == 400
            if !scrolled { spin(0.05) }
        }
        XCTAssertTrue(scrolled, "precondition: the page is scrolled")
        let loads = rig.world.handler.requestCount(host: "github.com", pathPrefix: "/acme/web/pull/7")
        XCTAssertEqual(loads, 1)

        // The person presses Conversation again, with another tab opened in between.
        rig.model.open(pr: pr, target: .conversation, url: reviewFixtureURL("github.com/acme/web/pull/7"))
        openTab(rig, .diff, path: "/acme/web/pull/7/files")
        rig.model.open(pr: pr, target: .conversation, url: reviewFixtureURL("github.com/acme/web/pull/7"))
        spin(0.6)

        XCTAssertEqual(rig.model.tabs.count, 2)
        XCTAssertEqual(rig.model.activeID, tab.id)
        XCTAssertTrue(tab.controller === controller, "the same web view, not a rebuilt one")
        XCTAssertEqual(rig.world.handler.requestCount(host: "github.com", pathPrefix: "/acme/web/pull/7/files"), 1, "the diff loaded once")
        XCTAssertEqual(rig.world.handler.requests(toHost: "github.com").filter { $0.path == "/acme/web/pull/7" }.count, 1,
                       "no second load of the conversation")
        let y = try await controller.webView.evaluateJavaScript("window.scrollY") as? Double
        XCTAssertEqual(y, 400, "the scroll offset survived")
    }

    // MARK: 17: the saved fraction

    private func paneFraction(_ rig: Rig) -> CGFloat {
        let available = rig.container.bounds.width - 1
        return rig.container.pane.frame.width / available
    }

    func testTheSavedFractionIsReappliedAfterHideAndShow() throws {
        let rig = makeRig(width: 1000, store: try store())
        rig.model.widthFraction = 0.4
        let tab = openTab(rig)
        rig.container.layoutSubtreeIfNeeded()
        XCTAssertEqual(paneFraction(rig), 0.4, accuracy: 0.005, "applied on first show")

        rig.model.close(tab)
        openTab(rig)
        rig.container.layoutSubtreeIfNeeded()
        XCTAssertEqual(paneFraction(rig), 0.4, accuracy: 0.005, "reapplied after hide and show")
    }

    func testTheSavedFractionIsReappliedAfterRebuildingTheContainerFromTheStore() async throws {
        let shared = try store()
        let first = makeRig(width: 1000, store: shared, tag: "perri-rebuild")
        first.model.widthFraction = 0.4
        openTab(first)
        first.container.layoutSubtreeIfNeeded()
        XCTAssertEqual(paneFraction(first), 0.4, accuracy: 0.005, "precondition")

        // A relaunch: a new model from the same store, a new container, a new window.
        let second = makeRig(width: 1000, store: shared, tag: "perri-rebuild", world: first.world)

        XCTAssertEqual(second.model.widthFraction, 0.4, accuracy: 0.0001)
        XCTAssertTrue(second.container.isPaneShown, "the restored tabs bring the pane back")
        XCTAssertEqual(paneFraction(second), 0.4, accuracy: 0.005)
    }

    func testAChangedFractionIsKeptWhenTheContainerIsResized() throws {
        let rig = makeRig(width: 1000, store: try store())
        rig.model.widthFraction = 0.45
        openTab(rig)
        rig.window.setContentSize(NSSize(width: 1300, height: 700))
        rig.container.layoutSubtreeIfNeeded()
        XCTAssertEqual(paneFraction(rig), 0.45, accuracy: 0.005)
    }

    // MARK: Minimum widths

    func testTheMinimumWidthsHoldWheneverTheContainerIsWideEnoughForBoth() {
        let rig = makeRig(width: 1000)
        openTab(rig)
        for width in [801, 900, 1000, 1400, 2000] as [CGFloat] {
            for fraction in [0.1, 0.5, 0.9] {
                rig.model.widthFraction = fraction
                rig.window.setContentSize(NSSize(width: width + 1, height: 700))     // a resize is what applies it
                rig.window.setContentSize(NSSize(width: width, height: 700))
                rig.container.layoutSubtreeIfNeeded()
                let focus = rig.focus.frame.width, pane = rig.container.pane.frame.width
                let at = "container \(Int(width)) pt, fraction \(fraction)"
                XCTAssertGreaterThanOrEqual(focus, PerriFocusContainerView.minimumFocusWidth - 0.5, "focus: \(at)")
                XCTAssertGreaterThanOrEqual(pane, PerriFocusContainerView.minimumPaneWidth - 0.5, "pane: \(at)")
                XCTAssertEqual(focus + pane + 1, width, accuracy: 1.5, "they fill the container: \(at)")
            }
        }
    }

    func testBelowTheCombinedMinimumTheFocusKeepsItsWidthAndThePaneTakesTheRest() {
        let rig = makeRig(width: 1000)
        openTab(rig)
        for width in [700, 600] as [CGFloat] {
            rig.window.setContentSize(NSSize(width: width, height: 700))
            rig.container.layoutSubtreeIfNeeded()
            XCTAssertGreaterThanOrEqual(rig.focus.frame.width, PerriFocusContainerView.minimumFocusWidth - 0.5, "container \(Int(width)) pt")
            XCTAssertEqual(rig.focus.frame.width + rig.container.pane.frame.width + 1, width, accuracy: 1.5, "container \(Int(width)) pt")
        }
    }

    func testPaneWidthTable() {
        // (container width, fraction) -> pane width, with a one point divider.
        let table: [(CGFloat, Double, CGFloat)] = [
            (1000, 0.5, 499.5), (1000, 0.4, 399.6), (1000, 0.1, 380), (1000, 0.9, 579),
            (801, 0.5, 380), (1400, 0.3, 419.7), (700, 0.5, 279), (420, 0.5, 0),
        ]
        for (total, fraction, expected) in table {
            XCTAssertEqual(PerriFocusContainerView.paneWidth(total: total, fraction: fraction), expected, accuracy: 0.01,
                           "\(total) pt at \(fraction)")
        }
    }
}
