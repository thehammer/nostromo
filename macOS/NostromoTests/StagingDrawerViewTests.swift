import XCTest
import AppKit

// `StagingDrawerView` and its rows, driven in real windows with real `NSEvent`s (the terminal view is the
// fake from StagingInsertControllerTests; there is no SwiftTerm here).
//
// What a person sees and can do:
//   SB-2   the command shown is exactly the command staged (every golden command), never edited
//   SB-6   no list: nothing at all (hidden, zero high, no timer). A list: a header, up to 5 rows before it
//          scrolls, never more than 45% of the pane body, only a strip in a body under 120 pt. It grows as
//          entries arrive but does not shrink while any remain; collapses to `3 staged by Claudia ▸`, which
//          pulses once for a new entry (not with reduce-motion). A frame never moves the keyboard focus and
//          never scrolls anything.
//   SB-7   every window shows the same rows from one store update; only the driver's rows insert; a mirror's
//          rows say why and a click sends nothing; the moment a mirror becomes the driver its rows are live.
//   SB-8   the list goes with the daemon connection, the terminal or a `none` frame; a frozen list says so,
//          stays insertable, and still accepts Remove and Clear all.
//   SB-9   keyboard: Up/Down/Tab/Shift-Tab select, Space inserts (a person's key event only), Return and
//          Enter do nothing and go nowhere, Escape gives the keyboard back, and nothing has a key equivalent.
//   SB-10  VoiceOver: a row is a button with a spoken label; a disabled one says why.
//   SB-11  agent text appears only in the command and note slots; the app writes every label itself.
//   SB-14  layout at 200/280/400/700 pt with 12 entries, a 1,000-character command, a long note and a long
//          agent name: nothing overlaps or overflows; Show all reveals everything.
//   SB-15  no leaks, a timer only while visible with entries, an unchanged frame redraws nothing.

// MARK: - Fixtures

/// Counts the key events that reach it: stands in for everything above the drawer in the responder chain.
final class StagingKeyProbeView: NSView {
    private(set) var keyDownCount = 0
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { keyDownCount += 1 }
}

/// Something else that holds the keyboard.
final class StagingFocusProbe: NSView {
    override var acceptsFirstResponder: Bool { true }
}

final class StagingDrawerHostState {
    var date = StagingFixtures.baseDate.addingTimeInterval(10)
    var reduceMotion = false
    var layoutRequests = 0
}

func stagingDescendants(_ view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + stagingDescendants($0) }
}

/// A drawer in a window, laid out the way `TerminalPaneHostView` does: it asks `preferredHeight` for the
/// pane body's height and width, takes that much of the bottom, and does it again when the drawer asks.
final class StagingDrawerHost {
    let rig: StagingRig
    let window: NSWindow
    let container: StagingKeyProbeView
    let drawer: StagingDrawerView
    let state: StagingDrawerHostState
    var bodyHeight: CGFloat
    var width: CGFloat

    init(rig: StagingRig, side: StagingSide? = nil, width: CGFloat = 400, bodyHeight: CGFloat = 400,
         paneKey: String = UUID().uuidString) {
        self.rig = rig
        self.width = width
        self.bodyHeight = bodyHeight
        let s = StagingDrawerHostState()
        state = s
        let w = rig.makeWindow(size: NSSize(width: max(900, width + 20), height: max(700, bodyHeight + 20)))
        window = w
        let c = StagingKeyProbeView()
        c.frame = NSRect(x: 0, y: 0, width: width, height: bodyHeight)
        w.contentView!.addSubview(c)
        container = c
        let d = StagingDrawerView(controller: (side ?? rig.primary).controller, staging: rig.staging, paneKey: paneKey,
                                  date: { s.date }, reduceMotion: { s.reduceMotion })
        drawer = d
        c.addSubview(d)
        d.onLayoutChange = { [weak self] in
            s.layoutRequests += 1
            self?.relayout()
        }
        relayout()
    }

    func relayout() {
        let height = drawer.preferredHeight(forBodyHeight: bodyHeight, width: width)
        drawer.frame = NSRect(x: 0, y: 0, width: width, height: height)
        drawer.layoutSubtreeIfNeeded()
    }

    func tearDown() {
        drawer.onLayoutChange = nil
        drawer.removeFromSuperview()
    }

    // MARK: What is on screen

    var allViews: [NSView] { stagingDescendants(drawer) }
    var textFields: [NSTextField] { allViews.compactMap { $0 as? NSTextField } }
    var texts: [String] { textFields.map { $0.stringValue } }
    var visibleTexts: [String] { textFields.filter { !$0.isHiddenOrHasHiddenAncestor }.map { $0.stringValue } }
    var rows: [StagingRowView] { drawer.orderedRows }
    var scroll: NSScrollView? { drawer.subviews.compactMap { $0 as? NSScrollView }.first }
    var divider: StagingDividerView? { drawer.subviews.compactMap { $0 as? StagingDividerView }.first }
    var height: CGFloat { drawer.frame.height }

    var clickables: [StagingClickableLabel] { drawer.subviews.compactMap { $0 as? StagingClickableLabel } }
    var stripButton: StagingClickableLabel? { clickables.first { $0.title.contains("staged by") } }
    var chevron: StagingClickableLabel? { clickables.first { $0.accessibilityLabel() == "Collapse staged commands" } }

    func commandLabel(of row: StagingRowView) -> NSTextField? {
        row.subviews.compactMap { $0 as? NSTextField }.first { $0.attributedStringValue.string == row.model.command }
    }

    func label(of row: StagingRowView, text: String) -> NSTextField? {
        row.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == text }
    }

    func showAll(of row: StagingRowView) -> StagingClickableLabel? {
        row.subviews.compactMap { $0 as? StagingClickableLabel }.first
    }
}

// MARK: - Tests

final class StagingDrawerViewTests: XCTestCase {

    private var rigs: [StagingRig] = []
    private var hosts: [StagingDrawerHost] = []

    override func tearDown() {
        for host in hosts { host.tearDown() }
        hosts = []
        for rig in rigs { rig.tearDown() }
        rigs = []
        super.tearDown()
    }

    // MARK: Helpers

    private func makeRig(gate: @escaping StagingInsertController.Gate = StagingGates.allowAll, kind: TerminalKind? = .local,
                         status: TerminalStatus? = .running, isMirror: Bool = false) -> StagingRig {
        let rig = StagingRig(gate: gate, kind: kind, status: status, isMirror: isMirror)
        rigs.append(rig)
        return rig
    }

    private func makeHost(_ rig: StagingRig, side: StagingSide? = nil, width: CGFloat = 400, bodyHeight: CGFloat = 400,
                          paneKey: String = UUID().uuidString) -> StagingDrawerHost {
        let host = StagingDrawerHost(rig: rig, side: side, width: width, bodyHeight: bodyHeight, paneKey: paneKey)
        hosts.append(host)
        return host
    }

    private func commands(_ n: Int) -> [String] {
        (1...max(1, n)).map { "echo item-\($0)" }
    }

    /// A drawer with `entries` staged, readable (past the 1.5 s delay) and drawn again.
    private func readyHost(gate: @escaping StagingInsertController.Gate = StagingGates.real(), commands list: [String] = ["ls -la", "pwd", "date"],
                           width: CGFloat = 400, bodyHeight: CGFloat = 400, isMirror: Bool = false)
        -> (rig: StagingRig, host: StagingDrawerHost) {
        let rig = makeRig(gate: gate, isMirror: isMirror)
        let host = makeHost(rig, width: width, bodyHeight: bodyHeight)
        rig.ingest(StagingFixtures.entries(list))
        rig.settle()
        host.drawer.refresh()
        return (rig, host)
    }

    private func overlaps(_ a: NSRect, _ b: NSRect) -> Bool {
        let i = a.intersection(b)
        return !i.isNull && i.width > 0.5 && i.height > 0.5
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    // MARK: - SB-6: nothing without a list

    func testWithNoListTheDrawerIsHiddenZeroHighAndRunsNoTimer() {
        let host = makeHost(makeRig())

        XCTAssertTrue(host.drawer.isHidden)
        XCTAssertFalse(host.drawer.hasList)
        XCTAssertEqual(host.drawer.preferredHeight(forBodyHeight: 400, width: 400), 0)
        XCTAssertEqual(host.height, 0)
        XCTAssertNil(host.drawer.tickTimer)
        XCTAssertFalse(host.drawer.acceptsFirstResponder, "a drawer with nothing in it cannot take the keyboard")
        XCTAssertFalse(host.drawer.focusRows())
    }

    func testAnEmptyListShowsTheHeaderThatTellsThePersonWhatToDo() {
        let rig = makeRig()
        let host = makeHost(rig)
        let list = rig.ingest([])

        XCTAssertFalse(host.drawer.isHidden)
        XCTAssertTrue(host.drawer.hasList)
        XCTAssertGreaterThan(host.height, StagingDrawerView.dividerHeight)
        XCTAssertTrue(host.visibleTexts.contains(StagingDrawerModel.headerParts(list).lead), "visible: \(host.visibleTexts)")
        XCTAssertTrue(host.rows.isEmpty)
        XCTAssertNil(host.drawer.tickTimer, "nothing to age")
    }

    func testTheHeaderNamesTheAgentAndTheCount() {
        let (_, host) = readyHost()

        XCTAssertTrue(host.visibleTexts.contains("Staged by Claudia"), "\(host.visibleTexts)")
        XCTAssertTrue(host.visibleTexts.contains("(3)"), "\(host.visibleTexts)")
    }

    // MARK: - SB-6: height

    private func drawerHeight(entries n: Int, bodyHeight: CGFloat = 1_000, commands list: [String]? = nil) -> (height: CGFloat, host: StagingDrawerHost) {
        let rig = makeRig()
        let host = makeHost(rig, bodyHeight: bodyHeight)
        rig.ingest(StagingFixtures.entries(list ?? commands(n)))
        return (host.height, host)
    }

    func testTheDrawerShowsUpToFiveRowsAndThenScrolls() {
        let one = drawerHeight(entries: 1), three = drawerHeight(entries: 3), five = drawerHeight(entries: 5)
        let eight = drawerHeight(entries: 8), twelve = drawerHeight(entries: 12)

        XCTAssertLessThan(one.height, three.height)
        XCTAssertLessThan(three.height, five.height)
        XCTAssertEqual(eight.height, five.height, accuracy: 0.5, "a sixth row does not make the drawer taller")
        XCTAssertEqual(twelve.height, five.height, accuracy: 0.5)

        for (name, result, scrolls) in [("5", five, false), ("8", eight, true), ("12", twelve, true)] {
            let scroll = result.host.scroll
            let documentHeight = scroll?.documentView?.frame.height ?? 0
            let visibleHeight = scroll?.frame.height ?? 0
            if scrolls {
                XCTAssertGreaterThan(documentHeight, visibleHeight + 1, "\(name) entries scroll")
            } else {
                XCTAssertLessThanOrEqual(documentHeight, visibleHeight + 1, "\(name) entries fit")
            }
        }
    }

    func testTheDrawerIsNeverMoreThan45PercentOfThePaneBody() {
        let long = String(repeating: "word ", count: 190)   // 950 scalars: three lines and Show all
        let list = [long, long, long, long, long, long, long, long]
        for body in [200.0, 300.0, 600.0, 1_000.0] {
            let result = drawerHeight(entries: list.count, bodyHeight: CGFloat(body), commands: list)
            XCTAssertLessThanOrEqual(result.height, CGFloat(body) * 0.45 + 0.5, "body \(body)")
            XCTAssertGreaterThanOrEqual(result.height, StagingDrawerView.dividerHeight + StagingDrawerView.stripHeight - 0.5)
        }
    }

    func testAPaneBodyUnder120PointsShowsOnlyTheStrip() {
        let rig = makeRig()
        let host = makeHost(rig, bodyHeight: 100)
        rig.ingest(StagingFixtures.entries(commands(3)))

        let strip = StagingDrawerView.dividerHeight + StagingDrawerView.stripHeight
        XCTAssertEqual(host.height, strip)
        XCTAssertEqual(host.scroll?.isHidden, true, "no rows")
        XCTAssertEqual(host.stripButton?.isHidden, false)
        XCTAssertTrue(host.visibleTexts.contains("3 staged by Claudia \u{25B8}"), "\(host.visibleTexts)")

        host.bodyHeight = 20
        host.relayout()
        XCTAssertEqual(host.height, 20, "never taller than the body")

        host.bodyHeight = 120
        host.relayout()
        XCTAssertGreaterThan(host.height, strip, "at 120 pt rows are back")
        XCTAssertEqual(host.scroll?.isHidden, false)
    }

    func testTheDrawerGrowsAsEntriesArriveButDoesNotShrinkWhileAnyRemain() {
        let rig = makeRig()
        let host = makeHost(rig, bodyHeight: 1_000)

        rig.ingest(StagingFixtures.entries(commands(2)))
        let two = host.height
        rig.ingest(StagingFixtures.entries(commands(5)))
        let five = host.height
        XCTAssertGreaterThan(five, two, "grows")

        rig.ingest(StagingFixtures.entries(commands(2)))
        XCTAssertEqual(host.height, five, accuracy: 0.5, "two entries left, still tall: the shell is not resized for every change")
        rig.ingest(StagingFixtures.entries(commands(1)))
        XCTAssertEqual(host.height, five, accuracy: 0.5)
    }

    func testTheDrawerShrinksWhenTheListEmptiesAndDisappearsWhenItIsGone() {
        let rig = makeRig()
        let host = makeHost(rig, bodyHeight: 1_000)
        rig.ingest(StagingFixtures.entries(commands(5)))
        let five = host.height

        rig.ingest([])
        XCTAssertLessThan(host.height, five, "an empty list is just the header")
        XCTAssertGreaterThan(host.height, 0)

        rig.ingest([], state: .none)
        XCTAssertEqual(host.height, 0)
        XCTAssertTrue(host.drawer.isHidden)
    }

    // MARK: - SB-6: collapse

    func testCollapsingLeavesAOneLineStripThatSaysHowManyAreStaged() {
        let (_, host) = readyHost()
        let expanded = host.height

        host.chevron?.onClick?()

        XCTAssertTrue(host.drawer.isCollapsed)
        XCTAssertEqual(host.height, StagingDrawerView.dividerHeight + StagingDrawerView.stripHeight)
        XCTAssertLessThan(host.height, expanded)
        XCTAssertEqual(host.stripButton?.isHidden, false)
        XCTAssertTrue(host.visibleTexts.contains("3 staged by Claudia \u{25B8}"), "\(host.visibleTexts)")
        XCTAssertEqual(host.scroll?.isHidden, true)

        host.stripButton?.onClick?()

        XCTAssertFalse(host.drawer.isCollapsed)
        XCTAssertGreaterThan(host.height, StagingDrawerView.dividerHeight + StagingDrawerView.stripHeight)
        XCTAssertEqual(host.stripButton?.isHidden, true)
    }

    func testANewEntryWhileCollapsedUpdatesTheCountAndPulsesOnce() {
        let (rig, host) = readyHost()
        host.drawer.setCollapsed(true)
        XCTAssertEqual(host.drawer.pulseCount, 0)

        rig.ingest(StagingFixtures.entries(commands(4)))

        XCTAssertEqual(host.drawer.pulseCount, 1)
        XCTAssertTrue(host.visibleTexts.contains("4 staged by Claudia \u{25B8}"), "\(host.visibleTexts)")
        XCTAssertNotNil(host.stripButton?.layer?.animation(forKey: "staging-pulse"), "the strip pulses")

        rig.ingest([StagingFixtures.entry("s-1", 1, "echo something else")] + Array(StagingFixtures.entries(commands(4)).dropFirst()))
        XCTAssertEqual(host.drawer.pulseCount, 1, "an edit that adds nothing does not pulse")
    }

    func testTheStripDoesNotPulseWithReduceMotion() {
        let (rig, host) = readyHost()
        host.state.reduceMotion = true
        host.drawer.setCollapsed(true)

        rig.ingest(StagingFixtures.entries(commands(4)))

        XCTAssertTrue(host.visibleTexts.contains("4 staged by Claudia \u{25B8}"), "the count still updates")
        XCTAssertNil(host.stripButton?.layer?.animation(forKey: "staging-pulse"), "no animation under reduce motion")
    }

    func testAnExpandedDrawerDoesNotPulseForANewEntry() {
        let (rig, host) = readyHost()

        rig.ingest(StagingFixtures.entries(commands(4)))

        XCTAssertEqual(host.drawer.pulseCount, 0)
    }

    // MARK: - SB-6: focus and scrolling

    func testAFrameNeverChangesTheFirstResponder() {
        let rig = makeRig()
        let host = makeHost(rig)
        let probe = StagingFocusProbe()
        probe.frame = NSRect(x: 0, y: 300, width: 20, height: 20)
        host.container.addSubview(probe)
        XCTAssertTrue(host.window.makeFirstResponder(probe))

        rig.ingest(StagingFixtures.entries(commands(3)))
        XCTAssertTrue(host.window.firstResponder === probe, "the first frame")
        rig.ingest(StagingFixtures.entries(commands(5)), state: .frozen)
        XCTAssertTrue(host.window.firstResponder === probe, "a frozen frame")
        host.drawer.setCollapsed(true)
        rig.ingest(StagingFixtures.entries(commands(6)))
        XCTAssertTrue(host.window.firstResponder === probe, "a frame while collapsed")
        rig.ingest([], state: .none)
        XCTAssertTrue(host.window.firstResponder === probe, "the list going away")
    }

    func testAFrameNeverScrollsTheRows() throws {
        let rig = makeRig()
        let host = makeHost(rig, bodyHeight: 1_000)
        rig.ingest(StagingFixtures.entries(commands(12)))
        let scroll = try XCTUnwrap(host.scroll)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 30))
        scroll.reflectScrolledClipView(scroll.contentView)
        let before = scroll.contentView.bounds.origin.y
        XCTAssertGreaterThan(before, 0, "harness: the rows scrolled")

        rig.ingest(StagingFixtures.entries(commands(13)))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, before, "a new entry")
        rig.ingest(StagingFixtures.entries(commands(13)), state: .frozen)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, before, "freezing")
    }

    func testTheClockTicksNeverScrollOrChangeFocus() {
        let (rig, host) = readyHost(commands: commands(12))
        host.drawer.focusRows()
        let before = host.scroll?.contentView.bounds.origin
        for _ in 0..<5 {
            rig.settle(1)
            host.drawer.refresh()
        }
        XCTAssertEqual(host.scroll?.contentView.bounds.origin, before)
        XCTAssertTrue(host.window.firstResponder === host.drawer)
    }

    // MARK: - Just changed

    func testAnEntryJustChangedSaysSoOnItsRowAndAClickShowsTheNoticeAndInsertsNothing() throws {
        let rig = makeRig(gate: StagingGates.real())
        let host = makeHost(rig)
        rig.ingest(StagingFixtures.entries(["echo one"]))
        rig.settle()
        host.drawer.refresh()
        XCTAssertFalse(host.visibleTexts.contains(StagingDisabledReason.justChanged.text))

        rig.ingest(StagingFixtures.entries(["echo two"]))    // replaced: its reading delay starts again
        let row = try XCTUnwrap(host.rows.first)
        XCTAssertTrue(host.visibleTexts.contains("Just changed: read it again"), "\(host.visibleTexts)")

        rig.mouseDown(row, in: host.window)
        rig.mouseUp(row, in: host.window)

        XCTAssertTrue(rig.target.sent.isEmpty)
        XCTAssertTrue(rig.insertedFrames.isEmpty)
        XCTAssertEqual(host.drawer.notice, "Just changed: read it again")
        XCTAssertTrue(host.visibleTexts.contains("Just changed: read it again"))

        rig.settle()
        host.drawer.refresh()
        XCTAssertEqual(host.rows.first?.model.state, .ready, "readable again after the delay")
        rig.click(try XCTUnwrap(host.rows.first), in: host.window)
        XCTAssertEqual(rig.target.sent, [Array("echo two".utf8)])
    }

    func testAnInsertedRowSaysSoAndKeepsWorking() throws {
        let rig = makeRig(gate: StagingGates.real())
        let host = makeHost(rig)
        rig.ingest(StagingFixtures.entries(["ls -la"]))
        rig.settle()
        host.drawer.refresh()
        let row = try XCTUnwrap(host.rows.first)

        rig.click(row, in: host.window)
        XCTAssertEqual(rig.target.sent.count, 1)

        let insertedAt = StagingFixtures.baseDate.addingTimeInterval(8)
        rig.ingest([StagingFixtures.entry("s-1", 1, "ls -la", insertedCount: 1, lastInsertedAt: insertedAt)])
        rig.settle()
        host.drawer.refresh()
        XCTAssertTrue(host.visibleTexts.contains("inserted 2s ago"), "\(host.visibleTexts)")
        XCTAssertEqual(host.rows.first?.model.glyph, "\u{2713}")
    }

    // MARK: - SB-7: mirrors

    func testTwoWindowsShowTheSameRowsFromOneStoreUpdate() {
        let rig = makeRig(gate: StagingGates.real())
        let mirrorSide = rig.makeSide(isMirror: true, gate: StagingGates.real())
        let driver = makeHost(rig)
        let mirror = makeHost(rig, side: mirrorSide)

        rig.ingest(StagingFixtures.entries(["ls -la", "pwd", "date"]))
        rig.settle()
        driver.drawer.refresh()
        mirror.drawer.refresh()

        XCTAssertEqual(driver.rows.map { $0.model.command }, ["ls -la", "pwd", "date"])
        XCTAssertEqual(mirror.rows.map { $0.model.command }, driver.rows.map { $0.model.command })
        XCTAssertEqual(mirror.rows.map { $0.model.number }, driver.rows.map { $0.model.number })
        XCTAssertEqual(driver.rows.map { $0.model.state }, [.ready, .ready, .ready])
        XCTAssertEqual(mirror.rows.map { $0.model.state }, Array(repeating: StagingRowModel.State.disabled(.mirror), count: 3))
    }

    func testOnlyTheDriversRowsInsertAndAMirrorsClickSendsNothing() throws {
        let rig = makeRig(gate: StagingGates.real())
        let mirrorSide = rig.makeSide(isMirror: true, gate: StagingGates.real())
        let driver = makeHost(rig)
        let mirror = makeHost(rig, side: mirrorSide)
        rig.ingest(StagingFixtures.entries(["ls -la"]))
        rig.settle()
        driver.drawer.refresh()
        mirror.drawer.refresh()

        rig.click(try XCTUnwrap(mirror.rows.first), in: mirror.window)
        XCTAssertTrue(mirrorSide.target.sent.isEmpty)
        XCTAssertTrue(rig.target.sent.isEmpty)
        XCTAssertTrue(rig.insertedFrames.isEmpty, "a click in a mirror reports nothing as inserted")

        rig.click(try XCTUnwrap(driver.rows.first), in: driver.window)
        XCTAssertEqual(rig.target.sent, [Array("ls -la".utf8)])
        XCTAssertTrue(mirrorSide.target.sent.isEmpty, "the mirror's terminal never hears it")
        XCTAssertEqual(rig.insertedFrames.count, 1)
    }

    func testAMirrorShowsTheReasonOnceAndItsRowsDoNotRepeatIt() {
        let rig = makeRig(gate: StagingGates.real())
        let mirrorSide = rig.makeSide(isMirror: true, gate: StagingGates.real())
        let mirror = makeHost(rig, side: mirrorSide)
        rig.ingest(StagingFixtures.entries(["ls -la", "pwd"]))
        rig.settle()
        mirror.drawer.refresh()

        XCTAssertEqual(mirror.visibleTexts.filter { $0 == StagingDisabledReason.mirror.text }.count, 1, "\(mirror.visibleTexts)")
        XCTAssertEqual(StagingDisabledReason.mirror.text, "Click the terminal to drive it from this window")
    }

    func testAMirrorThatBecomesTheDriverGetsLiveRowsOnRefresh() throws {
        let rig = makeRig(gate: StagingGates.real())
        let mirrorSide = rig.makeSide(isMirror: true, gate: StagingGates.real())
        let mirror = makeHost(rig, side: mirrorSide)
        rig.ingest(StagingFixtures.entries(["ls -la"]))
        rig.settle()
        mirror.drawer.refresh()
        XCTAssertEqual(mirror.rows.first?.model.state, .disabled(.mirror))

        mirrorSide.context?.isMirror = false
        mirror.drawer.refresh()

        XCTAssertEqual(mirror.rows.first?.model.state, .ready)
        XCTAssertFalse(mirror.visibleTexts.contains(StagingDisabledReason.mirror.text))
        rig.click(try XCTUnwrap(mirror.rows.first), in: mirror.window)
        XCTAssertEqual(mirrorSide.target.sent, [Array("ls -la".utf8)])
    }

    func testAMirrorsContextMenuCannotRemove() throws {
        let rig = makeRig()
        let mirrorSide = rig.makeSide(isMirror: true)
        let mirror = makeHost(rig, side: mirrorSide)
        let driver = makeHost(rig)
        rig.ingest(StagingFixtures.entries(["ls"]))

        let event = StagingEvents.mouse(.leftMouseDown, in: mirror.window, at: NSPoint(x: 5, y: 5))
        let mirrorMenu = try XCTUnwrap(try XCTUnwrap(mirror.rows.first).menu(for: event))
        let driverMenu = try XCTUnwrap(try XCTUnwrap(driver.rows.first).menu(for: event))

        XCTAssertEqual(mirrorMenu.items.map { $0.title }, ["Copy", "Remove"])
        XCTAssertEqual(mirrorMenu.items.map { $0.isEnabled }, [true, false], "Copy works anywhere, Remove only where the terminal is driven")
        XCTAssertEqual(driverMenu.items.map { $0.isEnabled }, [true, true])
    }

    // MARK: - SB-8: the list goes away with its source

    private func assertGone(_ host: StagingDrawerHost, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(host.drawer.isHidden, message, file: file, line: line)
        XCTAssertFalse(host.drawer.hasList, message, file: file, line: line)
        XCTAssertEqual(host.height, 0, message, file: file, line: line)
        XCTAssertTrue(host.rows.isEmpty, message, file: file, line: line)
        XCTAssertNil(host.drawer.tickTimer, message, file: file, line: line)
        XCTAssertNil(host.drawer.selectedEntryId, message, file: file, line: line)
    }

    func testTheDrawerGoesWhenTheDaemonConnectionDrops() {
        let (rig, host) = readyHost()
        XCTAssertTrue(host.drawer.hasList)
        rig.staging.connectionChanged(false)
        assertGone(host, "connection lost")
    }

    func testTheDrawerGoesWhenTheTerminalCloses() {
        let (rig, host) = readyHost()
        rig.staging.terminalClosed(StagingFixtures.terminalId)
        assertGone(host, "terminal closed")
    }

    func testTheDrawerGoesOnANoneFrame() {
        let (rig, host) = readyHost()
        rig.ingest([], state: .none)
        assertGone(host, "none frame")
    }

    func testAFrozenListSaysSoStaysInsertableAndStillAcceptsRemoveAndClear() throws {
        let (rig, host) = readyHost(gate: StagingGates.allowAll)
        rig.ingest(StagingFixtures.entries(["ls -la", "pwd"]), state: .frozen)
        rig.settle()
        host.drawer.refresh()

        XCTAssertTrue(host.visibleTexts.contains("Claudia stopped following; this list won't change"), "\(host.visibleTexts)")
        XCTAssertEqual(host.rows.map { $0.model.state }, [.ready, .ready], "a frozen list can still be inserted")

        _ = try XCTUnwrap(host.rows.first).activate(with: nil)
        XCTAssertEqual(rig.target.sent, [Array("ls -la".utf8)])

        let menu = try XCTUnwrap(try XCTUnwrap(host.rows.last).menu(for: StagingEvents.mouse(.leftMouseDown, in: host.window, at: NSPoint(x: 5, y: 5))))
        let remove = try XCTUnwrap(menu.items.first { $0.title == "Remove" })
        XCTAssertTrue(remove.isEnabled)
        let action = try XCTUnwrap(remove.action)
        _ = (remove.target as? NSObject)?.perform(action, with: remove)
        XCTAssertEqual(rig.stagingFrames.last, .stagingRemove(terminalId: StagingFixtures.terminalId, entryId: "s-2"))

        XCTAssertEqual(rig.controller.clearAll(event: nil, control: host.drawer), .done)
        XCTAssertEqual(rig.stagingFrames.last, .stagingClear(terminalId: StagingFixtures.terminalId))
    }

    func testTheStripOfAFrozenListSaysItIsStopped() {
        let (rig, host) = readyHost()
        rig.ingest(StagingFixtures.entries(["ls"]), state: .frozen)
        host.drawer.setCollapsed(true)
        XCTAssertTrue(host.visibleTexts.contains("1 staged by Claudia (stopped) \u{25B8}"), "\(host.visibleTexts)")
    }

    // MARK: - SB-9: keyboard

    func testFocusRowsTakesTheKeyboardAndSelectsTheFirstRowWithoutInsertingAnything() {
        let (rig, host) = readyHost()

        XCTAssertTrue(host.drawer.focusRows())

        XCTAssertTrue(host.window.firstResponder === host.drawer)
        XCTAssertEqual(host.drawer.selectedEntryId, "s-1")
        XCTAssertTrue(rig.target.sent.isEmpty, "focusing inserts nothing")
        XCTAssertTrue(rig.stagingFrames.isEmpty)
    }

    func testFocusRowsOpensACollapsedDrawer() {
        let (_, host) = readyHost()
        host.drawer.setCollapsed(true)

        XCTAssertTrue(host.drawer.focusRows())

        XCTAssertFalse(host.drawer.isCollapsed)
    }

    func testArrowsAndTabMoveTheSelectionAndStopAtTheEnds() {
        let (_, host) = readyHost()
        let w = host.window
        host.drawer.focusRows()

        host.drawer.keyDown(with: StagingEvents.down(in: w))
        XCTAssertEqual(host.drawer.selectedEntryId, "s-2")
        host.drawer.keyDown(with: StagingEvents.down(in: w))
        XCTAssertEqual(host.drawer.selectedEntryId, "s-3")
        host.drawer.keyDown(with: StagingEvents.down(in: w))
        XCTAssertEqual(host.drawer.selectedEntryId, "s-3", "no wrap past the last row")
        host.drawer.keyDown(with: StagingEvents.up(in: w))
        XCTAssertEqual(host.drawer.selectedEntryId, "s-2")
        host.drawer.keyDown(with: StagingEvents.tab(in: w))
        XCTAssertEqual(host.drawer.selectedEntryId, "s-3")
        host.drawer.keyDown(with: StagingEvents.tab(in: w, shift: true))
        XCTAssertEqual(host.drawer.selectedEntryId, "s-2")
        host.drawer.keyDown(with: StagingEvents.up(in: w))
        host.drawer.keyDown(with: StagingEvents.up(in: w))
        XCTAssertEqual(host.drawer.selectedEntryId, "s-1", "no wrap past the first row")
        XCTAssertEqual(host.rows.map { $0.isSelected }, [true, false, false])
    }

    func testSpaceInsertsTheSelectedRowOnlyForAHumanKeyEvent() throws {
        let (rig, host) = readyHost()
        let w = host.window
        host.drawer.focusRows()
        host.drawer.keyDown(with: StagingEvents.down(in: w))   // s-2: pwd

        host.drawer.keyDown(with: try StagingEvents.marked(StagingEvents.space(in: w)))
        XCTAssertTrue(rig.target.sent.isEmpty, "a synthetic Space inserts nothing")
        XCTAssertEqual(rig.refusals, [.stageInsert])

        host.drawer.keyDown(with: StagingEvents.space(in: w))
        XCTAssertEqual(rig.target.sent, [Array("pwd".utf8)])
        XCTAssertEqual(rig.insertedFrames, [.stagingInserted(terminalId: StagingFixtures.terminalId, entryId: "s-2", bytes: 3, confirmed: false)])
        XCTAssertEqual(rig.target.focusCount, 1, "the terminal takes the keyboard so the next Enter goes to the shell")
    }

    func testSpaceWithNoSelectionInsertsNothing() {
        let (rig, host) = readyHost()
        host.drawer.keyDown(with: StagingEvents.space(in: host.window))
        XCTAssertTrue(rig.target.sent.isEmpty)
    }

    func testSpaceOnADisabledRowInsertsNothing() {
        let (rig, host) = readyHost(isMirror: true)
        host.drawer.focusRows()
        host.drawer.keyDown(with: StagingEvents.space(in: host.window))
        XCTAssertTrue(rig.target.sent.isEmpty)
        XCTAssertTrue(rig.insertedFrames.isEmpty)
    }

    func testReturnAndKeypadEnterSendNothingAndAreNotForwarded() {
        let (rig, host) = readyHost()
        host.drawer.focusRows()

        for event in [StagingEvents.returnKey(in: host.window), StagingEvents.keypadEnter(in: host.window)] {
            host.drawer.keyDown(with: event)
            XCTAssertFalse(host.drawer.performKeyEquivalent(with: event), "the drawer claims no key equivalent")
        }

        XCTAssertTrue(rig.target.sent.isEmpty)
        XCTAssertTrue(rig.stagingFrames.isEmpty)
        XCTAssertEqual(rig.target.focusCount, 0)
        XCTAssertEqual(host.container.keyDownCount, 0, "swallowed, not passed up the responder chain")
        XCTAssertEqual(host.drawer.selectedEntryId, "s-1")
    }

    func testEscapeGivesTheKeyboardBack() {
        let (_, host) = readyHost()
        var returned = 0
        host.drawer.onReturnToTerminal = { returned += 1 }
        host.drawer.focusRows()

        host.drawer.keyDown(with: StagingEvents.escape(in: host.window))

        XCTAssertEqual(returned, 1)
    }

    func testNothingInTheDrawerHasAKeyEquivalent() throws {
        let (_, host) = readyHost()
        let w = host.window
        let events = [StagingEvents.returnKey(in: w), StagingEvents.keypadEnter(in: w), StagingEvents.space(in: w),
                      StagingEvents.escape(in: w), StagingEvents.key(36, "\r", in: w, modifiers: [.command])]

        for view in [host.drawer as NSView] + host.allViews {
            if let button = view as? NSButton {
                XCTAssertEqual(button.keyEquivalent, "", "\(button)")
            }
            for event in events {
                XCTAssertFalse(view.performKeyEquivalent(with: event), "\(type(of: view)) claimed a key equivalent")
            }
        }
        XCTAssertNil(w.defaultButtonCell, "no default button")

        let menu = try XCTUnwrap(try XCTUnwrap(host.rows.first).menu(for: StagingEvents.mouse(.leftMouseDown, in: w, at: NSPoint(x: 5, y: 5))))
        for item in menu.items {
            XCTAssertEqual(item.keyEquivalent, "", item.title)
            XCTAssertTrue(item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask).isEmpty
                          || item.keyEquivalent.isEmpty, item.title)
        }
    }

    func testTheTerminalMenuHasFocusStagedCommandsOnShiftCommandJ() throws {
        _ = NSApplication.shared
        let main = MainMenu.make(target: nil)
        let terminal = try XCTUnwrap(main.items.compactMap { $0.submenu }.first { $0.title == "Terminal" })
        let item = try XCTUnwrap(terminal.items.first { $0.title == "Focus Staged Commands" })

        XCTAssertEqual(item.keyEquivalent.lowercased(), "j")
        XCTAssertEqual(item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask), [.command, .shift])
        XCTAssertEqual(item.action, #selector(MainMenuActions.focusStagedCommands(_:)))

        var owners: [String] = []
        for top in main.items {
            for entry in top.submenu?.items ?? [] where entry.keyEquivalent.lowercased() == "j" {
                if entry.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == [.command, .shift] { owners.append(entry.title) }
            }
        }
        XCTAssertEqual(owners, ["Focus Staged Commands"], "⇧⌘J belongs to exactly one item")
    }

    func testThereIsNoMenuItemForInsertingAStagedCommand() throws {
        _ = NSApplication.shared
        let main = MainMenu.make(target: nil)
        let titles = main.items.compactMap { $0.submenu }.flatMap { $0.items }.map { $0.title.lowercased() }
        XCTAssertFalse(titles.contains { $0.contains("insert staged") || $0.contains("place staged") || $0.contains("staged command ") },
                       "only focus moves by shortcut; inserting is a person's click or Space: \(titles.filter { $0.contains("staged") })")
    }

    // MARK: - SB-10: VoiceOver

    func testARowIsAButtonWithItsSpokenLabel() throws {
        let (_, host) = readyHost()
        let row = try XCTUnwrap(host.rows.first)

        XCTAssertEqual(row.accessibilityRole(), .button)
        XCTAssertEqual(row.accessibilityIdentifier(), "staging-row")
        XCTAssertEqual(row.accessibilityLabel(), "Staged command 1 of 3, ls -la, ready to place at the prompt")
        XCTAssertEqual(host.rows.map { $0.accessibilityLabel() ?? "" }.filter { $0.contains("of 3") }.count, 3)
    }

    func testADisabledRowAnnouncesWhyItIsUnavailable() throws {
        let (_, host) = readyHost(isMirror: true)
        let row = try XCTUnwrap(host.rows.first)

        XCTAssertEqual(row.accessibilityLabel(),
                       "Staged command 1 of 3, ls -la, unavailable: Click the terminal to drive it from this window")
    }

    func testTheDrawerIsAGroupNamedStagedCommands() {
        let (_, host) = readyHost()
        XCTAssertEqual(host.drawer.accessibilityRole(), .group)
        XCTAssertEqual(host.drawer.accessibilityLabel(), "Staged commands")
    }

    func testShowAllAndTheChevronAreButtonsThatVoiceOverCanPress() throws {
        let rig = makeRig()
        let host = makeHost(rig)
        rig.ingest(StagingFixtures.entries([String(repeating: "word ", count: 190)]))
        let row = try XCTUnwrap(host.rows.first)
        let showAll = try XCTUnwrap(host.showAll(of: row))

        XCTAssertEqual(showAll.accessibilityRole(), .button)
        XCTAssertEqual(showAll.accessibilityLabel(), "Show all")
        XCTAssertTrue(showAll.accessibilityPerformPress())
        XCTAssertTrue(row.isExpanded)

        let chevron = try XCTUnwrap(host.chevron)
        XCTAssertEqual(chevron.accessibilityRole(), .button)
        XCTAssertTrue(chevron.accessibilityPerformPress())
        XCTAssertTrue(host.drawer.isCollapsed)
    }

    // MARK: - SB-11: agent text only in its slots

    func testAgentTextAppearsOnlyInTheCommandAndNoteSlots() {
        let canary = "CANARY-b7e1d2"
        let rig = makeRig()
        let host = makeHost(rig)
        rig.ingest([StagingFixtures.entry("s-1", 1, "echo \(canary) <name>", note: "\(canary) is the note")])
        rig.settle()
        host.drawer.refresh()

        let holders = host.textFields.filter { $0.stringValue.contains(canary) }
        XCTAssertEqual(holders.count, 2, "the command and the note, nowhere else: \(holders.map { $0.stringValue })")
        XCTAssertEqual(holders.filter { $0.attributedStringValue.string == "echo \(canary) <name>" }.count, 1)
        XCTAssertEqual(holders.filter { $0.stringValue == "Claudia's note (unverified): \(canary) is the note" }.count, 1)

        let outsideRows = host.allViews.filter { view in
            var current: NSView? = view
            while let candidate = current {
                if candidate is StagingRowView { return false }
                current = candidate.superview
            }
            return true
        }
        for view in [host.drawer as NSView] + outsideRows {
            XCTAssertFalse((view.accessibilityLabel() ?? "").contains(canary), "\(type(of: view)) speaks the agent's text")
            XCTAssertFalse((view.toolTip ?? "").contains(canary), "\(type(of: view)) has the agent's text as a tooltip")
        }
        XCTAssertNil(host.rows.first?.toolTip)
    }

    func testTheNoteIsLabelledUnverifiedAndAtMostTwoLines() throws {
        let rig = makeRig()
        let host = makeHost(rig)
        rig.ingest([StagingFixtures.entry("s-1", 1, "ls", note: String(repeating: "note ", count: 40))])
        let row = try XCTUnwrap(host.rows.first)
        let note = try XCTUnwrap(host.label(of: row, text: try XCTUnwrap(row.model.noteText)))

        XCTAssertTrue(note.stringValue.hasPrefix("Claudia's note (unverified): "))
        XCTAssertEqual(note.maximumNumberOfLines, 2)
        XCTAssertEqual(note.lineBreakMode, .byTruncatingTail)
    }

    func testThePlaceholderWarningIsTheAppsOwnTextAndOnlyForACommandWithAPlaceholder() throws {
        let rig = makeRig()
        let host = makeHost(rig)
        rig.ingest([StagingFixtures.entry("s-1", 1, "scp <file> host:/tmp"),
                    StagingFixtures.entry("s-2", 2, "ls", note: "Contains <x>: edit it before pressing Enter")])
        let first = try XCTUnwrap(host.rows.first)
        let second = try XCTUnwrap(host.rows.last)

        let warning = host.label(of: first, text: StagingDrawerModel.placeholderLabel)
        XCTAssertNotNil(warning)
        XCTAssertEqual(warning?.isHidden, false)
        XCTAssertNil(host.label(of: second, text: StagingDrawerModel.placeholderLabel), "an agent's note cannot make the app's warning")
        XCTAssertEqual(second.model.labels, [])
    }

    func testTheAgentNameInTheHeaderIsSanitisedAndCapped() {
        let rig = makeRig()
        let host = makeHost(rig)
        rig.ingest(StagingFixtures.entries(["ls"]), agent: "Cla\u{202E}u\u{200B}dia " + String(repeating: "Z", count: 80))

        let lead = host.visibleTexts.first { $0.hasPrefix("Staged by ") }
        XCTAssertNotNil(lead)
        let name = String((lead ?? "").dropFirst("Staged by ".count))
        XCTAssertLessThanOrEqual(name.count, 40)
        XCTAssertTrue(name.hasPrefix("Claudia ZZZ"))
        XCTAssertFalse(name.unicodeScalars.contains { $0.value == 0x202E || $0.value == 0x200B })
    }

    // MARK: - SB-2: the command is shown exactly as staged

    func testTheDisplayedCommandIsTheStagedCommandForEveryGoldenCommand() throws {
        let rig = makeRig()
        let window = rig.makeWindow()
        rig.ingest(StagingFixtures.entries(try StagingFixtures.commands()))
        rig.settle()
        for (index, command) in try StagingFixtures.commands().enumerated() {
            let row = rig.makeRow(entryId: "s-\(index + 1)", in: window)
            let shown = row.subviews.compactMap { $0 as? NSTextField }.first { $0.attributedStringValue.string == command }
            XCTAssertNotNil(shown, "not displayed exactly: \(command)")
            XCTAssertEqual(shown?.stringValue, command)
            XCTAssertEqual(row.model.command, command)
            row.removeFromSuperview()
        }
    }

    // MARK: - SB-14: layout

    private func hostileEntries() -> [StagingEntry] {
        var entries: [StagingEntry] = []
        let long = String((0..<1_000).map { Character(UnicodeScalar(UInt8(97 + $0 % 26))) })
        for i in 1...12 {
            switch i {
            case 1: entries.append(StagingFixtures.entry("s-1", 1, long))
            case 2: entries.append(StagingFixtures.entry("s-2", 2, "git log --oneline -n 20", note: String(repeating: "note ", count: 24)))
            default: entries.append(StagingFixtures.entry("s-\(i)", i, "echo item-\(i) && ls -la src/terminal"))
            }
        }
        return entries
    }

    func testTwelveHostileEntriesLayOutWithoutOverlapOrOverflowAtEveryWidth() throws {
        for width in [200.0, 280.0, 400.0, 700.0] {
            let w = CGFloat(width)
            let rig = makeRig()
            let host = makeHost(rig, width: w, bodyHeight: 900)
            rig.ingest(hostileEntries(), agent: String(repeating: "A", count: 40))
            host.relayout()
            let tag = "width \(Int(width))"

            XCTAssertEqual(host.drawer.frame.width, w, tag)
            XCTAssertLessThanOrEqual(host.height, 900 * 0.45 + 0.5, tag)
            XCTAssertEqual(host.rows.count, 12, tag)

            // Rows stack without overlapping, inside the drawer's width.
            let frames = host.rows.map { $0.frame }
            for pair in zip(frames, frames.dropFirst()) {
                XCTAssertLessThanOrEqual(pair.0.maxY, pair.1.minY + 0.5, "rows overlap at \(tag)")
            }
            for row in host.rows {
                XCTAssertLessThanOrEqual(row.frame.maxX, host.drawer.bounds.width + 0.5, "a row overflows at \(tag)")
                XCTAssertGreaterThanOrEqual(row.frame.minX, -0.5, tag)
            }

            // Inside a row: number, glyph, first command lines and age.
            for row in host.rows {
                let fields = row.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }
                let number = fields.first { $0.stringValue == "\(row.model.number)" }
                let glyph = fields.first { $0.stringValue == row.model.glyph }
                let command = host.commandLabel(of: row)
                let age = fields.first { $0.stringValue == row.model.age }
                let parts = [("number", number), ("glyph", glyph), ("command", command), ("age", age)]
                for (name, field) in parts {
                    let label = try XCTUnwrap(field, "\(name) of row \(row.model.number) at \(tag)")
                    XCTAssertTrue(row.bounds.insetBy(dx: -0.5, dy: -0.5).contains(label.frame),
                                  "\(name) of row \(row.model.number) leaves its row at \(tag): \(label.frame) in \(row.bounds)")
                    XCTAssertGreaterThan(label.frame.width, 0, "\(name) at \(tag)")
                }
                if width >= 280 {
                    for i in 0..<parts.count {
                        for j in (i + 1)..<parts.count {
                            let a = try XCTUnwrap(parts[i].1).frame, b = try XCTUnwrap(parts[j].1).frame
                            XCTAssertFalse(overlaps(a, b), "\(parts[i].0) overlaps \(parts[j].0) in row \(row.model.number) at \(tag)")
                        }
                    }
                }
            }

            // The header keeps its count; nothing in the drawer sticks out of it.
            let count = try XCTUnwrap(host.drawer.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "(12)" }, tag)
            XCTAssertFalse(count.isHidden, tag)
            XCTAssertGreaterThan(count.frame.width, 0, tag)
            XCTAssertGreaterThan(count.frame.height, 0, tag)
            if let lead = host.drawer.subviews.compactMap({ $0 as? NSTextField }).first(where: { $0.stringValue.hasPrefix("Staged by") }) {
                XCTAssertFalse(overlaps(lead.frame, count.frame), "the header text runs into the count at \(tag)")
            }
            for view in host.drawer.subviews where !view.isHidden {
                XCTAssertTrue(host.drawer.bounds.insetBy(dx: -0.5, dy: -0.5).contains(view.frame),
                              "\(type(of: view)) overflows the drawer at \(tag): \(view.frame) in \(host.drawer.bounds)")
            }
        }
    }

    func testAThousandCharacterCommandShowsThreeLinesAndShowAllRevealsTheRest() throws {
        let rig = makeRig()
        let host = makeHost(rig, width: 400, bodyHeight: 900)
        let long = hostileEntries()[0].command
        rig.ingest([StagingFixtures.entry("s-1", 1, long)])
        let row = try XCTUnwrap(host.rows.first)
        let label = try XCTUnwrap(host.commandLabel(of: row))
        let showAll = try XCTUnwrap(host.showAll(of: row))
        let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)))

        XCTAssertEqual(label.maximumNumberOfLines, 3)
        XCTAssertLessThanOrEqual(label.frame.height, 3 * lineHeight + 1, "three lines")
        XCTAssertGreaterThanOrEqual(label.frame.height, 3 * lineHeight - 1)
        XCTAssertEqual(label.stringValue, long, "the label holds the whole command even while it shows three lines")
        XCTAssertFalse(showAll.isHidden)
        XCTAssertEqual(showAll.title, "Show all")
        let collapsedHeight = row.frame.height

        showAll.onClick?()
        host.relayout()

        XCTAssertTrue(row.isExpanded)
        XCTAssertEqual(label.maximumNumberOfLines, 0)
        XCTAssertEqual(label.stringValue, long)
        XCTAssertGreaterThan(row.frame.height, collapsedHeight)
        XCTAssertTrue(row.bounds.insetBy(dx: -0.5, dy: -0.5).contains(label.frame), "\(label.frame) in \(row.bounds)")
        XCTAssertEqual(showAll.title, "Show less")

        showAll.onClick?()
        host.relayout()
        XCTAssertFalse(row.isExpanded)
        XCTAssertEqual(label.maximumNumberOfLines, 3)
    }

    func testAShortCommandHasNoShowAll() throws {
        let rig = makeRig()
        let host = makeHost(rig)
        rig.ingest(StagingFixtures.entries(["ls -la"]))
        let row = try XCTUnwrap(host.rows.first)
        XCTAssertEqual(host.showAll(of: row)?.isHidden, true)
    }

    // MARK: - Carried review item: right-to-left text and stacked combining marks

    private var awkwardCommands: [(name: String, command: String)] {
        [("Hebrew", "echo \u{05E9}\u{05DC}\u{05D5}\u{05DD} \u{05E2}\u{05D5}\u{05DC}\u{05DD} && ls"),
         ("Arabic", "echo \u{0645}\u{0631}\u{062D}\u{0628}\u{0627} \u{0628}\u{0627}\u{0644}\u{0639}\u{0627}\u{0644}\u{0645} && ls"),
         ("thirty combining marks", "e" + String(repeating: "\u{0301}", count: 30) + "cho hi")]
    }

    func testTheCommandIsDrawnLeftToRightWithAnOverrideWhateverLettersItHolds() throws {
        let expected = NSNumber(value: NSWritingDirection.leftToRight.rawValue | NSTextWritingDirection.override.rawValue)
        for (name, command) in awkwardCommands {
            let attributed = StagingRowView.commandText(command, dimmed: false)
            let style = try XCTUnwrap(attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle, name)
            XCTAssertEqual(style.baseWritingDirection, .leftToRight, name)
            XCTAssertEqual(attributed.attribute(.writingDirection, at: 0, effectiveRange: nil) as? [NSNumber], [expected], name)
            XCTAssertEqual(attributed.string, command, "\(name): the text itself is not changed")

            let rig = makeRig()
            let window = rig.makeWindow()
            rig.ingest([StagingFixtures.entry("s-1", 1, command)])
            let row = rig.makeRow(in: window)
            let label = try XCTUnwrap(row.subviews.compactMap { $0 as? NSTextField }.first { $0.attributedStringValue.string == command }, name)
            let shownStyle = label.attributedStringValue.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            XCTAssertEqual(shownStyle?.baseWritingDirection, .leftToRight, "\(name): as the label holds it")
            XCTAssertEqual(label.attributedStringValue.attribute(.writingDirection, at: 0, effectiveRange: nil) as? [NSNumber], [expected], name)
        }
    }

    func testARowClipsToItsOwnBoundsSoStackedMarksCannotDrawOverANeighbour() throws {
        for (name, command) in awkwardCommands {
            for width in [200.0, 400.0] {
                let rig = makeRig()
                let window = rig.makeWindow()
                rig.ingest([StagingFixtures.entry("s-1", 1, command)])
                let row = rig.makeRow(in: window, width: CGFloat(width))
                row.layoutSubtreeIfNeeded()

                XCTAssertEqual(row.layer?.masksToBounds, true, name)
                let label = try XCTUnwrap(row.subviews.compactMap { $0 as? NSTextField }.first { $0.attributedStringValue.string == command }, name)
                XCTAssertTrue(row.bounds.insetBy(dx: -0.5, dy: -0.5).contains(label.frame), "\(name) at \(width): \(label.frame) in \(row.bounds)")
            }
        }
    }

    // MARK: - Nothing is selectable and the row owns every click

    func testNoTextInTheDrawerIsSelectable() {
        let rig = makeRig()
        let host = makeHost(rig, bodyHeight: 900)
        rig.ingest(hostileEntries())
        host.drawer.setCollapsed(false)

        XCTAssertGreaterThan(host.textFields.count, 20)
        for field in host.textFields {
            XCTAssertFalse(field.isSelectable, "\"\(field.stringValue.prefix(30))\" is selectable")
            XCTAssertFalse(field.isEditable)
        }
    }

    func testAClickOnTheCommandHitsTheRowNotATextField() throws {
        let (_, host) = readyHost(gate: StagingGates.allowAll)
        let row = try XCTUnwrap(host.rows.first)
        let label = try XCTUnwrap(host.commandLabel(of: row))
        let onCommand = NSPoint(x: label.frame.midX, y: label.frame.midY)

        let hit = host.container.hitTest(row.convert(onCommand, to: host.container.superview))

        XCTAssertTrue(hit === row, "hit \(String(describing: hit))")
        XCTAssertNil(row.hitTest(row.convert(NSPoint(x: -50, y: -50), to: row.superview)), "outside the row is not the row")
    }

    // MARK: - SB-15: timers

    func testTheTimerRunsOnlyWhileTheDrawerIsVisibleWithEntriesInAWindow() throws {
        let rig = makeRig()
        let host = makeHost(rig)
        XCTAssertNil(host.drawer.tickTimer, "no list")

        rig.ingest(StagingFixtures.entries(["ls"]))
        let timer = try XCTUnwrap(host.drawer.tickTimer, "a visible list with entries ticks")
        XCTAssertTrue(timer.isValid)
        XCTAssertTrue(CFRunLoopContainsTimer(CFRunLoopGetMain(), unsafeBitCast(timer, to: CFRunLoopTimer.self), CFRunLoopMode.commonModes),
                      "in the common modes, so ages keep counting while a menu is open or the divider is dragged")

        rig.ingest([])
        XCTAssertNil(host.drawer.tickTimer, "an empty list has nothing to age")
        XCTAssertFalse(timer.isValid)

        rig.ingest(StagingFixtures.entries(["ls"]))
        let again = try XCTUnwrap(host.drawer.tickTimer)
        rig.ingest([], state: .none)
        XCTAssertNil(host.drawer.tickTimer)
        XCTAssertFalse(again.isValid)
    }

    func testTheTimerStopsWhenTheDrawerLeavesItsWindow() throws {
        let rig = makeRig()
        let host = makeHost(rig)
        rig.ingest(StagingFixtures.entries(["ls"]))
        let timer = try XCTUnwrap(host.drawer.tickTimer)

        host.drawer.removeFromSuperview()

        XCTAssertNil(host.drawer.tickTimer)
        XCTAssertFalse(timer.isValid)

        host.container.addSubview(host.drawer)
        XCTAssertNotNil(host.drawer.tickTimer, "back in a window with entries: it ticks again")
    }

    // MARK: - SB-15: redraw only what changed

    func testAnIdenticalFrameChangesNothingAndNotifiesNobody() {
        let (rig, host) = readyHost()
        let rowUpdates = host.drawer.rowUpdateCount
        let notifications = rig.staging.notificationCount
        let requests = host.state.layoutRequests

        rig.staging.ingest(StagingFixtures.list(revision: 1, entries: StagingFixtures.entries(["ls -la", "pwd", "date"])))
        host.drawer.refresh()

        XCTAssertEqual(rig.staging.notificationCount, notifications, "a repeated revision is ignored by the store")
        XCTAssertEqual(host.drawer.rowUpdateCount, rowUpdates)
        XCTAssertEqual(host.state.layoutRequests, requests, "and the host is not asked to lay out again")
    }

    func testANewRevisionWithNothingChangedRedrawsNoRow() {
        let (rig, host) = readyHost()
        let rowUpdates = host.drawer.rowUpdateCount

        rig.ingest(StagingFixtures.entries(["ls -la", "pwd", "date"]))   // same entries, next revision

        XCTAssertEqual(host.drawer.rowUpdateCount, rowUpdates, "the rows' text did not change")
    }

    func testANewRevisionWithOneEntryChangedRebuildsOnlyThatRow() {
        let (rig, host) = readyHost()
        rig.settle()
        host.drawer.refresh()
        let rowUpdates = host.drawer.rowUpdateCount
        let before = host.rows

        rig.ingest(StagingFixtures.entries(["ls -la", "pwd --changed", "date"]))

        XCTAssertEqual(host.drawer.rowUpdateCount, rowUpdates + 1, "one row redrawn")
        XCTAssertEqual(host.rows.map { $0.model.command }, ["ls -la", "pwd --changed", "date"])
        XCTAssertTrue(zip(before, host.rows).allSatisfy { $0 === $1 }, "rows are reused by entry id, not rebuilt")
    }

    func testTheClockAdvancingRedrawsRowsOnlyWhenTheirStateChanges() {
        let (rig, host) = readyHost()
        let rowUpdates = host.drawer.rowUpdateCount

        rig.settle(1)
        host.drawer.refresh()
        host.drawer.refresh()

        XCTAssertEqual(host.drawer.rowUpdateCount, rowUpdates, "nothing a row shows changed")
    }

    // MARK: - SB-15: memory

    private final class WeakRow {
        weak var row: StagingRowView?
        init(_ row: StagingRowView) { self.row = row }
    }

    func testRemovingTheDrawerFromItsWindowReleasesTheDrawerItsRowsAndTheController() {
        let rig = makeRig()
        let window = rig.makeWindow()
        weak var weakDrawer: StagingDrawerView?
        weak var weakController: StagingInsertController?
        var weakRows: [WeakRow] = []
        var hadTimer = false

        autoreleasepool {
            let target = FakeStagingTarget()
            let controller = StagingInsertController(
                staging: rig.staging, sessions: rig.sessions, target: target, pasteboard: rig.pasteboard,
                context: { StagingContext(terminalId: StagingFixtures.terminalId, kind: .local, status: .running, isMirror: false) },
                gate: StagingGates.allowAll)
            let drawer = StagingDrawerView(controller: controller, staging: rig.staging, paneKey: UUID().uuidString,
                                           date: { StagingFixtures.baseDate }, reduceMotion: { true })
            drawer.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
            window.contentView!.addSubview(drawer)
            rig.ingest(StagingFixtures.entries(["ls", "pwd", "date"]))
            drawer.layoutSubtreeIfNeeded()
            weakDrawer = drawer
            weakController = controller
            weakRows = drawer.orderedRows.map { WeakRow($0) }
            hadTimer = drawer.tickTimer != nil
            drawer.removeFromSuperview()
        }

        XCTAssertTrue(hadTimer, "harness: the drawer was live")
        XCTAssertEqual(weakRows.count, 3)
        XCTAssertTrue(waitUntil { weakDrawer == nil }, "the drawer is still alive")
        XCTAssertTrue(waitUntil { weakController == nil }, "the controller is still alive")
        XCTAssertTrue(waitUntil { weakRows.allSatisfy { $0.row == nil } }, "a row is still alive")

        // The store no longer calls anyone.
        let notifications = rig.staging.notificationCount
        rig.ingest(StagingFixtures.entries(["ls"]))
        XCTAssertEqual(rig.staging.notificationCount, notifications + 1)
    }

    // MARK: - The divider

    func testDraggingTheDividerClampsBetweenTheStripAndSixtyPercentOfTheBody() throws {
        let rig = makeRig()
        let host = makeHost(rig, bodyHeight: 500)
        rig.ingest(StagingFixtures.entries(commands(8)))
        let divider = try XCTUnwrap(host.divider)
        let strip = StagingDrawerView.dividerHeight + StagingDrawerView.stripHeight

        divider.onDrag?(200)
        XCTAssertEqual(host.height, 200, accuracy: 0.5)
        divider.onDrag?(5)
        XCTAssertEqual(host.height, strip, accuracy: 0.5, "never smaller than the strip")
        divider.onDrag?(10_000)
        XCTAssertEqual(host.height, 300, accuracy: 0.5, "never more than 60% of the body")
    }

    func testDraggingWithTheMouseMakesTheDrawerTallerWhenDraggedUp() throws {
        let rig = makeRig()
        let host = makeHost(rig, bodyHeight: 800)
        rig.ingest(StagingFixtures.entries(commands(2)))
        let divider = try XCTUnwrap(host.divider)
        let start = host.height

        divider.mouseDown(with: StagingEvents.mouse(.leftMouseDown, in: host.window, at: NSPoint(x: 10, y: 100)))
        divider.mouseDragged(with: StagingEvents.mouse(.leftMouseDragged, in: host.window, at: NSPoint(x: 10, y: 160)))
        divider.mouseUp(with: StagingEvents.mouse(.leftMouseUp, in: host.window, at: NSPoint(x: 10, y: 160)))

        XCTAssertEqual(host.height, start + 60, accuracy: 0.5)
    }

    func testADraggedHeightIsRememberedPerPaneAndNotForAnotherPane() throws {
        let paneKey = "pane-" + UUID().uuidString
        do {
            let rig = makeRig()
            let host = makeHost(rig, bodyHeight: 600, paneKey: paneKey)
            rig.ingest(StagingFixtures.entries(commands(2)))
            try XCTUnwrap(host.divider).onDrag?(250)
            XCTAssertEqual(host.height, 250, accuracy: 0.5)
        }

        let rig = makeRig()
        let same = makeHost(rig, bodyHeight: 600, paneKey: paneKey)
        let other = makeHost(rig, bodyHeight: 600, paneKey: "pane-" + UUID().uuidString)
        rig.ingest(StagingFixtures.entries(commands(2)))

        XCTAssertEqual(same.height, 250, accuracy: 0.5, "the same pane remembers")
        XCTAssertLessThan(other.height, 250, "another pane does not")
    }

    func testTheDividerDoesNothingWhileCollapsed() throws {
        let (_, host) = readyHost()
        host.drawer.setCollapsed(true)
        try XCTUnwrap(host.divider).onDrag?(300)
        XCTAssertEqual(host.height, StagingDrawerView.dividerHeight + StagingDrawerView.stripHeight)
        XCTAssertEqual(host.divider?.isHidden, true)
    }
}
