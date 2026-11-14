import XCTest
import AppKit
import SwiftUI
import WebKit

// Perri side pane, slice 2: the pane and its controls are usable without sight or a pointer (39, 40).
//
//   * the row controls say what they open and for which PR; every row also offers both as accessibility
//     actions whether or not its controls are drawn
//   * tabs read as radio buttons inside a tab group: "tab 2 of 3, #4520 Diff, pull request 4520 in <repo>",
//     each with its own "Close #4520 Diff"
//   * the divider can be moved a step at a time (increment / decrement) and that changes the saved width
//   * keyboard focus goes to the page when a tab opens and back to the queue when the last tab closes
//   * nothing the pane adds is bound to a key equivalent (the main menu's set is pinned by
//     `TrackerPaneViewTests.testTheMainMenusKeyEquivalentsAreExactlyTheOnesItHadBeforeTheTracker`)

private final class FirstResponderView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
final class ReviewPaneAccessibilityTests: XCTestCase {

    private let pr = ReviewPR(repo: "acme/web", number: 4520)
    private var rigs: [PerriRowsRig] = []
    private var worlds: [ReviewFixtureWorld] = []
    private var windows: [NSWindow] = []
    private var models: [ReviewPaneModel] = []

    override func tearDown() async throws {
        rigs.forEach { $0.close() }
        rigs = []
        for model in models { for tab in model.tabs { model.close(tab) } }
        models = []
        for window in windows { window.contentView = NSView(); window.close() }
        windows = []
        spin(0.3)
        for world in worlds { await world.removeDataStore() }
        worlds = []
        try await super.tearDown()
    }

    // MARK: Row controls

    /// SwiftUI builds its accessibility tree only when something is listening. A plain labelled `Text` is the
    /// control: when even that exposes nothing, this process gets no SwiftUI tree and the row tests skip,
    /// leaving `testTheRowControlLabelsAreWrittenAsSpecified` as their guard.
    private func swiftUIAccessibilityIsAvailable() -> Bool {
        let host = NSHostingView(rootView: Text("control").accessibilityLabel("accessibility control label"))
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 40)
        let window = ReviewTestWindow.make(size: NSSize(width: 200, height: 40))
        defer { window.contentView = NSView(); window.close() }
        window.contentView = host
        NSApp.accessibilitySetOverrideValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        spin(0.4)
        return reviewAXNodes(under: host).contains { reviewAXLabel($0) == "accessibility control label" }
    }

    func testTheRowControlsSayWhatTheyOpenAndForWhichPR() throws {
        try XCTSkipUnless(swiftUIAccessibilityIsAvailable(), "no SwiftUI accessibility tree in this process; see testTheRowControlLabelsAreWrittenAsSpecified")
        let rig = PerriRowsRig(width: 480)
        rigs.append(rig)

        let labels = Set(reviewAXNodes(under: rig.hosting).compactMap(reviewAXLabel))

        XCTAssertTrue(labels.contains("Open conversation for pull request 4520 in side pane"), "\(labels.sorted())")
        XCTAssertTrue(labels.contains("Open diff for pull request 4520"), "\(labels.sorted())")
    }

    func testEveryRowOffersBothAsAccessibilityActionsEvenWhenItsControlsAreNotDrawn() throws {
        try XCTSkipUnless(swiftUIAccessibilityIsAvailable(), "no SwiftUI accessibility tree in this process; see testTheRowControlLabelsAreWrittenAsSpecified")
        let rig = PerriRowsRig(width: 480, selected: nil)      // nothing selected: no control is drawn anywhere
        rigs.append(rig)

        var actions: [String: NSAccessibilityCustomAction] = [:]
        for node in reviewAXNodes(under: rig.hosting) {
            for action in (AppControlAX.value(node, "accessibilityCustomActions") as? [NSAccessibilityCustomAction]) ?? [] {
                actions[action.name] = action
            }
        }

        for number in PerriRowsRig.numbers {
            XCTAssertNotNil(actions["Open conversation for pull request \(number) in side pane"], "row \(number): \(actions.keys.sorted())")
            XCTAssertNotNil(actions["Open diff for pull request \(number)"], "row \(number)")
        }
        _ = actions["Open conversation for pull request 4521 in side pane"]?.handler?()
        _ = actions["Open diff for pull request 4522"]?.handler?()
        XCTAssertEqual(rig.recordedConversations, [4521])
        XCTAssertEqual(rig.recordedDiffs, [4522])
        XCTAssertEqual(rig.recordedLoads, [], "an action opens a tab and loads nothing")
    }

    /// The wording of the controls' accessibility labels and row actions, read from the source because the
    /// SwiftUI tree cannot always be read in a test process. Both are written twice: on the buttons (when
    /// drawn) and as row actions (always).
    func testTheRowControlLabelsAreWrittenAsSpecified() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Nostromo/UI/ReviewPane/PerriRowControls.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let conversation = "\"Open conversation for pull request \\(number) in side pane\""
        let diff = "\"Open diff for pull request \\(number)\""
        XCTAssertGreaterThanOrEqual(source.components(separatedBy: conversation).count - 1, 2, "conversation: button label and row action")
        XCTAssertGreaterThanOrEqual(source.components(separatedBy: diff).count - 1, 2, "diff: button label and row action")
    }

    // MARK: Tabs

    private func makeModel(tag: String = "perri-a11y") -> ReviewPaneModel {
        let model = ReviewPaneModel(tag: tag, store: nil)
        model.unsentCheck = { _ in false }
        models.append(model)
        return model
    }

    /// Three tabs, conversation / diff / ticket, in a pane that is not in a window (so no web view is made).
    private func threeTabPane(unsentOnDiff: Bool = false) -> (pane: ReviewSidePaneView, model: ReviewPaneModel, tabs: [ReviewTab]) {
        let model = makeModel()
        let c = model.open(pr: pr, target: .conversation)
        let d = model.open(pr: pr, target: .diff)
        let t = model.open(pr: pr, target: .ticket("CORE-1"), url: URL(string: "https://carefeed.atlassian.net/browse/CORE-1")!, ticketOrder: 1)
        d.unsent = unsentOnDiff
        return (ReviewSidePaneView(model: model), model, [c, d, t])
    }

    func testTheTabsFormATabGroupOfRadioButtons() {
        let (pane, _, _) = threeTabPane()
        XCTAssertEqual(pane.strip.accessibilityRole(), .tabGroup)
        XCTAssertEqual(pane.strip.accessibilityLabel(), "Side pane tabs")
        XCTAssertEqual(pane.strip.items.count, 3)
        XCTAssertEqual(pane.strip.accessibilityTabs()?.count, 3)
        for item in pane.strip.items {
            XCTAssertEqual(item.accessibilityRole(), .radioButton)
            XCTAssertTrue(item.isAccessibilityElement())
        }
    }

    func testATabReadsWithItsPositionTitleAndPullRequest() {
        let (pane, _, _) = threeTabPane()
        XCTAssertEqual(pane.strip.items[0].accessibilityLabel(), "tab 1 of 3, #4520 Conversation, pull request 4520 in acme/web")
        XCTAssertEqual(pane.strip.items[1].accessibilityLabel(), "tab 2 of 3, #4520 Diff, pull request 4520 in acme/web")
        XCTAssertEqual(pane.strip.items[2].accessibilityLabel(), "tab 3 of 3, CORE-1, pull request 4520 in acme/web")
    }

    func testAnUnsentTabSaysSo() {
        let (pane, _, _) = threeTabPane(unsentOnDiff: true)
        XCTAssertEqual(pane.strip.items[1].accessibilityLabel(),
                       "tab 2 of 3, #4520 Diff, pull request 4520 in acme/web, unsent text")
        XCTAssertFalse(pane.strip.items[0].accessibilityLabel()?.contains("unsent") ?? true)
    }

    func testTheSelectedTabReadsAsSelected() {
        let (pane, model, tabs) = threeTabPane()
        XCTAssertEqual(pane.strip.items.map { $0.accessibilityValue() as? Int }, [0, 0, 1], "the last opened is active")
        model.focus(tabs[1])
        XCTAssertEqual(pane.strip.items.map { $0.accessibilityValue() as? Int }, [0, 1, 0])
    }

    func testEachTabHasItsOwnCloseButtonWithItsName() {
        let (pane, _, _) = threeTabPane()
        XCTAssertEqual(pane.strip.items.map { $0.closeButton.accessibilityLabel() },
                       ["Close #4520 Conversation", "Close #4520 Diff", "Close CORE-1"])
    }

    func testPressingATabForAccessibilitySelectsIt() {
        let (pane, model, tabs) = threeTabPane()
        XCTAssertTrue(pane.strip.items[0].accessibilityPerformPress())
        XCTAssertEqual(model.activeID, tabs[0].id)
    }

    func testATabsContextMenuOffersCloseAndCloseOthersWithoutKeyEquivalents() throws {
        let (pane, model, tabs) = threeTabPane()
        let menu = try XCTUnwrap(pane.strip.items[1].menu)
        XCTAssertEqual(menu.items.map(\.title), ["Close Tab", "Close Other Tabs"])
        XCTAssertEqual(menu.items.map(\.keyEquivalent), ["", ""])
        _ = model
        _ = tabs
    }

    func testNothingThePaneAddsHasAKeyEquivalent() throws {
        let (pane, _, _) = threeTabPane()
        func walk(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + walk($0) } }
        for button in ([pane] + walk(pane)).compactMap({ $0 as? NSButton }) {
            XCTAssertEqual(button.keyEquivalent, "", "\(button.accessibilityLabel() ?? button.title)")
        }
        for item in pane.strip.items {
            for entry in item.menu?.items ?? [] { XCTAssertEqual(entry.keyEquivalent, "", entry.title) }
        }
    }

    // MARK: Divider and focus, in a window

    private struct Rig {
        let world: ReviewFixtureWorld
        let model: ReviewPaneModel
        let container: PerriFocusContainerView
        let focus: FirstResponderView
        let queue: FirstResponderView
        let window: ReviewTestWindow
    }

    private func makeRig() -> Rig {
        let world = ReviewFixtureWorld()
        worlds.append(world)
        let model = makeModel()
        model.environment = world.environment
        let focus = FirstResponderView(frame: .zero)
        let queue = FirstResponderView(frame: NSRect(x: 10, y: 10, width: 100, height: 100))
        focus.addSubview(queue)
        let container = PerriFocusContainerView(focusView: focus, model: model)
        let window = ReviewTestWindow.make(size: NSSize(width: 1000, height: 700))
        windows.append(window)
        window.contentView = container
        container.layoutSubtreeIfNeeded()
        return Rig(world: world, model: model, container: container, focus: focus, queue: queue, window: window)
    }

    @discardableResult
    private func openTab(_ rig: Rig, _ target: ReviewTarget = .conversation, path: String = "/acme/web/pull/4520") -> ReviewTab {
        rig.model.open(pr: pr, target: target, url: reviewFixtureURL("github.com\(path)"))
    }

    private func divider(_ rig: Rig) throws -> ReviewSplitView {
        try XCTUnwrap(rig.container.subviews.compactMap { $0 as? ReviewSplitView }.first)
    }

    func testTheDividerIsASplitGroupThatReadsItsPercentage() throws {
        let rig = makeRig()
        openTab(rig)
        let divider = try divider(rig)
        XCTAssertTrue(divider.isAccessibilityElement())
        XCTAssertEqual(divider.accessibilityRole(), .splitGroup)
        XCTAssertEqual(divider.accessibilityLabel(), "Side pane divider")
        XCTAssertEqual(divider.accessibilityValue() as? String, "pane 50 percent")
    }

    func testIncrementWidensThePaneAndDecrementNarrowsItAndTheModelKeepsTheWidth() throws {
        let rig = makeRig()
        openTab(rig)
        let divider = try divider(rig)
        let start = rig.container.pane.frame.width

        XCTAssertTrue(divider.accessibilityPerformIncrement())
        XCTAssertEqual(rig.model.widthFraction, 0.55, accuracy: 0.001)
        rig.container.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(rig.container.pane.frame.width, start + 20, "the pane really got wider")
        XCTAssertEqual(divider.accessibilityValue() as? String, "pane 55 percent")

        XCTAssertTrue(divider.accessibilityPerformDecrement())
        XCTAssertTrue(divider.accessibilityPerformDecrement())
        XCTAssertEqual(rig.model.widthFraction, 0.45, accuracy: 0.001)
        rig.container.layoutSubtreeIfNeeded()
        XCTAssertLessThan(rig.container.pane.frame.width, start - 20)
    }

    func testTheDividerStopsAtTheEndsOfItsRange() throws {
        let rig = makeRig()
        openTab(rig)
        let divider = try divider(rig)
        for _ in 0..<30 { _ = divider.accessibilityPerformIncrement() }
        XCTAssertEqual(rig.model.widthFraction, 0.9, accuracy: 0.001)
        for _ in 0..<30 { _ = divider.accessibilityPerformDecrement() }
        XCTAssertEqual(rig.model.widthFraction, 0.1, accuracy: 0.001)
    }

    func testTheDividerDoesNothingWhileThePaneIsClosed() throws {
        let rig = makeRig()
        let tab = openTab(rig)
        let divider = try divider(rig)
        rig.model.close(tab)
        let before = rig.model.widthFraction
        _ = divider.accessibilityPerformIncrement()
        XCTAssertEqual(rig.model.widthFraction, before)
    }

    func testKeyboardFocusGoesToThePageWhenATabOpens() throws {
        let rig = makeRig()
        XCTAssertTrue(rig.window.makeFirstResponder(rig.queue))

        let tab = openTab(rig)

        XCTAssertTrue(rig.window.firstResponder === tab.controller?.webView, "the page has the keyboard: \(String(describing: rig.window.firstResponder))")
    }

    func testOpeningAnotherTabMovesKeyboardFocusToItsPage() throws {
        let rig = makeRig()
        openTab(rig)
        let second = openTab(rig, .diff, path: "/acme/web/pull/4520/files")
        XCTAssertTrue(rig.window.firstResponder === second.controller?.webView)
    }

    func testKeyboardFocusReturnsToTheQueueWhenTheLastTabCloses() throws {
        let rig = makeRig()
        var returned = 0
        rig.container.focusQueue = { returned += 1; rig.window.makeFirstResponder(rig.queue) }
        XCTAssertTrue(rig.window.makeFirstResponder(rig.queue))
        let first = openTab(rig)
        let second = openTab(rig, .diff, path: "/acme/web/pull/4520/files")

        rig.model.close(first)
        spin(0.2)
        XCTAssertEqual(returned, 0, "a tab remains: the page keeps the keyboard")

        rig.model.close(second)
        XCTAssertTrue(spinUntil(2) { rig.window.firstResponder === rig.queue }, "back in the queue: \(String(describing: rig.window.firstResponder))")
        XCTAssertEqual(returned, 1)
    }

    func testWithoutAQueueTargetKeyboardFocusReturnsToTheFocusView() throws {
        let rig = makeRig()
        let tab = openTab(rig)
        rig.model.close(tab)
        XCTAssertTrue(spinUntil(2) { rig.window.firstResponder === rig.focus }, "\(String(describing: rig.window.firstResponder))")
    }
}
