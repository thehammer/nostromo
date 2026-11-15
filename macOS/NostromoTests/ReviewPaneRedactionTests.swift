import XCTest
import AppKit
import WebKit

// Perri side pane, slice 2 (SR7): the pane shows signed-in GitHub and Jira pages, so app-control never
// sees it.
//
//   * a screenshot in the real app paints the pane's whole area with the opaque redaction fill, and the
//     block carries the pane's own label, not the terminal's
//   * `tree` / `find` / `ax` read the pane as one fixed entry with no children, and read no text from
//     inside it (tab titles, host, path, notices)
//   * the QA build (synthetic input allowed) is unchanged, and so is how a terminal is redacted
//   * the pane lives outside the daemon's pane tree: opening, closing and resizing it sends nothing
//
// What the tests read is the decoded PNG that `ScreenshotRedaction.pngData` returns and the hits
// `AppControlAX.hits` returns, never the views' internals.

private final class FakeTerminal: NSView, TerminalPixelSource {
    var terminalPixelArea: NSView { self }
}

private final class FocusWithTerminal: NSView {
    let terminal = FakeTerminal()
    override init(frame: NSRect) {
        super.init(frame: frame)
        terminal.frame = NSRect(x: 10, y: 10, width: 200, height: 150)
        addSubview(terminal)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}

@MainActor
final class ReviewPaneRedactionTests: XCTestCase {

    private var world: ReviewFixtureWorld!
    private var model: ReviewPaneModel!
    private var focus: FocusWithTerminal!
    private var container: PerriFocusContainerView!
    private var window: ReviewTestWindow!
    private var daemonCalls: [String] = []

    private let pr = ReviewPR(repo: "acme/web", number: 7)

    override func setUp() async throws {
        try await super.setUp()
        world = ReviewFixtureWorld()
        world.handler.respond = { _ in
            ReviewFixtureHandler.Response(body: ReviewFixtureHandler.html("<p style=\"background:#ff00ff\">canary</p>"))
        }
        model = ReviewPaneModel(tag: "perri-redaction", store: nil)
        model.environment = world.environment
        model.unsentCheck = { _ in false }
        focus = FocusWithTerminal(frame: .zero)
        container = PerriFocusContainerView(focusView: focus, model: model)
        window = ReviewTestWindow.make(size: NSSize(width: 1000, height: 700))
        window.contentView = container
        container.layoutSubtreeIfNeeded()
        daemonCalls = []
        AppStore.shared.perriActionSender = { [unowned self] action, _, _, _ in self.daemonCalls.append(action) }
    }

    override func tearDown() async throws {
        AppStore.shared.perriActionSender = nil
        for tab in model.tabs { model.close(tab) }
        window.contentView = NSView()
        window.close()
        spin(0.3)
        await world.removeDataStore()
        try await super.tearDown()
    }

    /// Opens a ticket tab, whose title is its key: a title app-control must never read.
    @discardableResult
    private func openPane(title: String = "SECRET-TITLE") -> ReviewTab {
        let tab = model.open(pr: pr, target: .ticket(title), url: reviewFixtureURL("github.com/acme/web/pull/7"))
        container.layoutSubtreeIfNeeded()
        return tab
    }

    private var pane: ReviewSidePaneView { container.pane }

    // MARK: Capture helpers

    private struct Capture {
        let rep: NSBitmapImageRep
        let rect: NSRect
        var scale: CGFloat { CGFloat(rep.pixelsWide) / rect.width }
    }

    private func capture() throws -> Capture {
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return Capture(rep: rep, rect: view.convert(view.bounds, to: nil))
    }

    private func pixels(_ capture: Capture, allowsSynthetic: Bool) throws -> ReviewPixels {
        let data = try ScreenshotRedaction.pngData(of: capture.rep, window: window, captureRect: capture.rect,
                                                   allowsSynthetic: allowsSynthetic)
        return try XCTUnwrap(ReviewPixels(png: data), "pngData returned a decodable PNG")
    }

    /// The pane's area as a top-down pixel rectangle of the capture.
    private func paneRect(_ capture: Capture) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
        let r = pane.convert(pane.bounds, to: nil)
        let s = capture.scale
        return (Int(((r.minX - capture.rect.minX) * s).rounded()), Int(((capture.rect.maxY - r.maxY) * s).rounded()),
                Int(((r.maxX - capture.rect.minX) * s).rounded()), Int(((capture.rect.maxY - r.minY) * s).rounded()))
    }

    private var fill: ReviewPixels.RGB {
        let c = ScreenshotRedaction.fillColor.usingColorSpace(.sRGB)!
        return ReviewPixels.RGB(r: Int((c.redComponent * 255).rounded()), g: Int((c.greenComponent * 255).rounded()),
                                b: Int((c.blueComponent * 255).rounded()))
    }

    /// Sample points inside the pane, away from the centred label.
    private func samples(_ r: (x0: Int, y0: Int, x1: Int, y1: Int), scale: CGFloat) -> [(Int, Int)] {
        let inset = Int(10 * scale)
        let xs = [r.x0 + inset, (r.x0 + r.x1) / 2, r.x1 - inset]
        let ys = [r.y0 + inset, r.y0 + (r.y1 - r.y0) / 4, r.y0 + 3 * (r.y1 - r.y0) / 4, r.y1 - inset]
        return xs.flatMap { x in ys.map { y in (x, y) } }
    }

    // MARK: Screenshots

    func testTheRealAppsScreenshotPaintsOverTheWholePane() throws {
        openPane()
        let cap = try capture()
        let r = paneRect(cap)
        XCTAssertGreaterThan(r.x1 - r.x0, Int(PerriFocusContainerView.minimumPaneWidth * cap.scale) - 2, "precondition: the pane is open")

        let out = try pixels(cap, allowsSynthetic: false)

        for (x, y) in samples(r, scale: cap.scale) {
            XCTAssertLessThanOrEqual(out.rgb(x, y).distance(to: fill), 10, "pixel (\(x), \(y)) inside the pane is the redaction fill: \(out.rgb(x, y))")
        }
        // Along the pane's whole top strip, where its tab strip and address bar are.
        for x in stride(from: r.x0 + 4, to: r.x1 - 4, by: 7) {
            XCTAssertLessThanOrEqual(out.rgb(x, r.y0 + 3).distance(to: fill), 10, "tab strip row at x \(x)")
        }
    }

    func testTheQABuildsScreenshotLeavesThePaneAlone() throws {
        openPane()
        let cap = try capture()
        let r = paneRect(cap)

        let out = try pixels(cap, allowsSynthetic: true)

        let painted = samples(r, scale: cap.scale).filter { out.rgb($0.0, $0.1).distance(to: fill) <= 10 }
        XCTAssertLessThan(painted.count, samples(r, scale: cap.scale).count / 2, "the unredacted capture is not the fill")
    }

    func testTheBlockOverThePaneIsLabelledWithThePanesOwnTextAndATerminalKeepsItsOwn() throws {
        openPane()
        let targets = try ScreenshotRedaction.terminalTargets(in: window)

        XCTAssertEqual(targets.count, 2, "the terminal and the pane: \(targets.map(\.label))")
        XCTAssertEqual(targets.filter { $0.label == "review pane hidden from app-control" }.count, 1)
        XCTAssertEqual(targets.filter { $0.label == ScreenshotRedaction.label }.count, 1, "the terminal's label is unchanged")
        XCTAssertEqual(ScreenshotRedaction.label, "terminal hidden from app-control")
        let panes = targets.filter { $0.label != ScreenshotRedaction.label }
        XCTAssertEqual(panes.first?.rect, pane.convert(pane.bounds, to: nil).standardized)
        XCTAssertEqual(panes.first?.isHidden, false)
    }

    func testALabelIsDrawnOnThePaneBlock() throws {
        openPane()
        let cap = try capture()
        let r = paneRect(cap)
        let out = try pixels(cap, allowsSynthetic: false)

        // The label is centred; its glyphs are lighter than the fill.
        let midY = (r.y0 + r.y1) / 2
        var glyphPixels = 0
        for y in (midY - Int(10 * cap.scale))...(midY + Int(10 * cap.scale)) {
            for x in r.x0...r.x1 where out.rgb(x, y).luminance > fill.luminance + 40 { glyphPixels += 1 }
        }
        XCTAssertGreaterThan(glyphPixels, 20, "a label is drawn over the block")
    }

    func testTheTerminalIsStillRedactedWithTheTerminalLabelWhenThePaneIsClosed() throws {
        let targets = try ScreenshotRedaction.terminalTargets(in: window)
        XCTAssertEqual(targets.map(\.label), [ScreenshotRedaction.label], "no pane, only the terminal")
        let cap = try capture()
        let out = try pixels(cap, allowsSynthetic: false)
        let t = focus.terminal.convert(focus.terminal.bounds, to: nil)
        let x = Int(((t.midX - cap.rect.minX) * cap.scale).rounded())
        let y = Int(((cap.rect.maxY - t.minY - 8) * cap.scale).rounded())
        XCTAssertLessThanOrEqual(out.rgb(x, y).distance(to: fill), 10, "the terminal's area is painted, as before")
    }

    func testAPaneThatClosedLeavesNothingToRedact() throws {
        let tab = openPane()
        model.close(tab)
        let targets = try ScreenshotRedaction.terminalTargets(in: window)
        XCTAssertFalse(targets.contains { $0.label == "review pane hidden from app-control" })
    }

    // MARK: Accessibility reads (tree / find / ax)

    private func descendants(of view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants(of: $0) } }

    func testThePaneAndEverythingInsideItIsWithheldInTheRealApp() {
        let tab = openPane()
        XCTAssertTrue(AppControlAX.isWithheld(pane, allowsSynthetic: false))
        XCTAssertTrue(AppControlAX.isWithheld(pane.strip, allowsSynthetic: false))
        XCTAssertTrue(AppControlAX.isWithheld(tab.controller!.webView, allowsSynthetic: false), "the page itself")
        XCTAssertTrue(AppControlAX.isWithheld(tab.controller!.contentView.notice, allowsSynthetic: false), "its notices")
        for sub in descendants(of: pane) {
            XCTAssertTrue(AppControlAX.isWithheld(sub, allowsSynthetic: false), "\(type(of: sub))")
            XCTAssertNil(AppControlAX.text(of: sub, allowsSynthetic: false), "no text is read from \(type(of: sub))")
        }
        XCTAssertFalse(AppControlAX.isWithheld(focus, allowsSynthetic: false), "the focus beside it is not")
        XCTAssertFalse(AppControlAX.isWithheld(focus.terminal, allowsSynthetic: false))
    }

    func testTheQABuildReadsThePaneAsBefore() {
        openPane()
        XCTAssertFalse(AppControlAX.isWithheld(pane, allowsSynthetic: true))
        XCTAssertFalse(AppControlAX.isWithheld(pane.strip, allowsSynthetic: true))
        let texts = descendants(of: pane).compactMap { AppControlAX.text(of: $0, allowsSynthetic: true) }
        XCTAssertTrue(texts.contains { $0.contains("SECRET-TITLE") }, "the tab title is readable there: \(texts)")
    }

    func testAxReadsThePaneAsOneFixedEntryWithNoChildren() {
        openPane()
        let hits = AppControlAX.hits(under: pane, in: window, allowsSynthetic: false)

        XCTAssertEqual(hits.count, 1, "exactly one entry: \(hits.map(\.text))")
        XCTAssertEqual(hits.first?.text, "review pane hidden from app-control")
        XCTAssertEqual(hits.first?.text, AppControlAX.reviewPaneHiddenText)
        let paneFrame = pane.convert(pane.bounds, to: nil)
        if let rect = hits.first?.rectInWindow {
            XCTAssertEqual(rect.minX, paneFrame.minX, accuracy: 1.5)
            XCTAssertEqual(rect.width, paneFrame.width, accuracy: 1.5)
            XCTAssertEqual(rect.height, paneFrame.height, accuracy: 1.5)
        }
    }

    func testAxUnderAPartOfThePaneReadsTheSameSingleEntry() {
        openPane()
        let hits = AppControlAX.hits(under: pane.strip, in: window, allowsSynthetic: false)
        XCTAssertEqual(hits.map(\.text), [AppControlAX.reviewPaneHiddenText])
    }

    func testAxOverTheWholeWindowFindsThePaneOnceAndNothingFromInsideIt() {
        openPane(title: "SECRET-TITLE")
        let content = window.contentView!
        let hits = AppControlAX.hits(under: content, in: window, allowsSynthetic: false)

        XCTAssertEqual(hits.filter { $0.text == AppControlAX.reviewPaneHiddenText }.count, 1, "\(hits.map(\.text))")
        for secret in ["SECRET-TITLE", "Side pane tabs", "Review side pane", "Reload", "Open in Browser", "github.com", "pull/7"] {
            XCTAssertFalse(hits.contains { ($0.text ?? "").contains(secret) }, "app-control must not read \(secret): \(hits.map(\.text))")
        }
    }

    func testTheQABuildsAxReadsStillSeeInsideThePane() {
        openPane(title: "SECRET-TITLE")
        let hits = AppControlAX.hits(under: pane, in: window, allowsSynthetic: true)
        XCTAssertFalse(hits.contains { $0.text == AppControlAX.reviewPaneHiddenText }, "no fixed entry in the QA build")
    }

    func testTheRawAxDumpOfThePaneIsOneFixedNode() throws {
        openPane()
        let node = AppControlAX.dump(pane, 0, allowsSynthetic: false)
        XCTAssertEqual(node["label"] as? String, AppControlAX.reviewPaneHiddenText)
        XCTAssertNil(node["children"], "nothing below it")
        XCTAssertEqual(node["type"] as? String, "ReviewSidePaneView")
    }

    // MARK: The daemon hears nothing

    func testOpeningResizingAndClosingThePaneSendsNothingToTheDaemon() {
        let tab = openPane()
        model.widthFraction = 0.45
        window.setContentSize(NSSize(width: 1100, height: 700))
        let second = model.open(pr: pr, target: .diff, url: reviewFixtureURL("github.com/acme/web/pull/7/files"))
        model.focus(tab)
        model.close(second)
        model.close(tab)
        spin(0.2)
        XCTAssertEqual(daemonCalls, [], "the side pane is Mac-only and outside the daemon's pane tree")
    }

    func testTheFocusViewIsTheContainersOwnChildAndNeverReparentedIntoThePane() {
        let tab = openPane()
        XCTAssertTrue(container.focusView === focus)
        XCTAssertFalse(focus.isDescendant(of: pane))
        XCTAssertFalse(pane.isDescendant(of: focus))
        model.close(tab)
        XCTAssertTrue(focus.isDescendant(of: container))
    }
}
