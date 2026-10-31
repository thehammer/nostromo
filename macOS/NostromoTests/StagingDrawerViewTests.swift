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
//   SB-8   the list goes with the daemon connection, the terminal, a `none` frame or a frame the app cannot
//          read (which keeps the revision, so a replay does not bring it back); a drawer that held the
//          keyboard gives it back. A frozen list says so, stays insertable, and still accepts Remove and Clear all.
//   SB-9   keyboard: Up/Down/Tab/Shift-Tab select, Space inserts (a person's key event only), Return and
//          Enter do nothing and go nowhere, Escape gives the keyboard back, and nothing has a key equivalent.
//   SB-10  VoiceOver: a row is a button with a spoken label; a disabled one says why.
//   SB-11  agent text appears only in the command and note slots; the app writes every label itself.
//   SB-14  layout at 200/280/400/700 pt with 12 entries, a 1,000-character command, a long note and a long
//          agent name: nothing overlaps or overflows; Show all reveals everything.
//   SB-15  no leaks, a timer only while visible with entries, an unchanged frame redraws nothing.
//   SB-16  rows hold still: none moves (nor does the drawer) when the 1.5 s reading delay ends after an edit,
//          an added or a removed entry, nor when a refusal notice or the shared reason appears or clears,
//          at 200 and 400 pt. The reason and the note are labels whose OWN cell wraps (two lines, the last
//          one cut), and each draws the two lines it has room for.

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

// MARK: - What an accessibility client is shown

/// One element in the accessibility tree as a client (VoiceOver, app-control) would be shown it.
fileprivate struct StagingAXNode {
    let object: NSObject
    let role: NSAccessibility.Role?
    let label: String?
    let value: String?
    let identifier: String
    let children: [StagingAXNode]

    var descendants: [StagingAXNode] { children.flatMap { [$0] + $0.descendants } }
}

/// Walks the real accessibility children (never a view's own role): a view that is not an accessibility
/// element is replaced by whatever it contains, exactly as `NSAccessibility.unignoredChildren` does, and
/// an element contributes itself and what it says its children are.
fileprivate enum StagingAX {
    /// What a client sees beneath `root` (not `root` itself).
    static func tree(under root: NSView) -> [StagingAXNode] {
        dedupe(childObjects(of: root).flatMap { nodes(for: $0, depth: 1) })
    }

    private static func nodes(for object: NSObject, depth: Int) -> [StagingAXNode] {
        guard depth < 40 else { return [] }
        if let view = object as? NSView, !view.isAccessibilityElement() {
            var inside = childObjects(of: view)
            if inside.isEmpty { inside = view.subviews.filter { !$0.isHidden } }
            return dedupe(inside.flatMap { nodes(for: $0, depth: depth + 1) })
        }
        let role = string(object, "accessibilityRole").map { NSAccessibility.Role(rawValue: $0) }
        return [StagingAXNode(object: object, role: role, label: string(object, "accessibilityLabel"),
                              value: text(object, "accessibilityValue"),
                              identifier: string(object, "accessibilityIdentifier") ?? "",
                              children: dedupe(childObjects(of: object).flatMap { nodes(for: $0, depth: depth + 1) }))]
    }

    private static func childObjects(of object: NSObject) -> [NSObject] {
        var found: [NSObject] = []
        for name in ["accessibilityChildren", "accessibilityContents"] {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector),
                  let array = object.perform(selector)?.takeUnretainedValue() as? [AnyObject] else { continue }
            found += array.compactMap { $0 as? NSObject }
        }
        // A scroll area's own children are AppKit's business; be sure its content is looked at.
        if let scroll = object as? NSScrollView, let document = scroll.documentView { found.append(document) }
        return found
    }

    private static func string(_ object: NSObject, _ name: String) -> String? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    private static func text(_ object: NSObject, _ name: String) -> String? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() else { return nil }
        return (value as? String) ?? (value as? NSAttributedString)?.string
    }

    private static func dedupe(_ nodes: [StagingAXNode]) -> [StagingAXNode] {
        var seen = Set<ObjectIdentifier>()
        return nodes.filter { seen.insert(ObjectIdentifier($0.object)).inserted }
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
        // The row says it is unavailable by its dimming, its glyph and its spoken label, not by a line of
        // text that would make it taller until the delay ends (which moves every row below it).
        XCTAssertEqual(row.model.state, .disabled(.justChanged))
        XCTAssertEqual(row.model.glyph, "\u{2298}")
        XCTAssertTrue(row.accessibilityLabel()?.contains("unavailable: Just changed: read it again") ?? false, "\(String(describing: row.accessibilityLabel()))")
        XCTAssertFalse(host.visibleTexts.contains("Just changed: read it again"), "\(host.visibleTexts)")

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
        rig.settle()   // Copy is enabled once the text has been readable for 1.5 s

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

    /// A Space key-down as the keyboard makes it: `repeating` is the auto-repeat of a held key.
    private func spaceEvent(in window: NSWindow, repeating: Bool, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                         context: nil, characters: " ", charactersIgnoringModifiers: " ",
                         isARepeat: repeating, keyCode: 49)!
    }

    // The gate lets everything through here, so the only thing that can refuse these Spaces is the rule
    // that a held key (auto-repeat) and a Space with a modifier are not a person pressing Space.

    func testAnAutoRepeatedSpaceInsertsNothingSendsNothingAndChangesNothing() {
        let (rig, host) = readyHost(gate: StagingGates.allowAll)
        host.drawer.focusRows()
        let modelsBefore = host.rows.map { $0.model }
        let selectedBefore = host.drawer.selectedEntryId
        let noticeBefore = host.drawer.notice
        let sessionFramesBefore = rig.sessionFrames.count
        let held = spaceEvent(in: host.window, repeating: true)
        XCTAssertTrue(held.isARepeat, "the event under test is a repeat")

        for _ in 0..<3 { host.drawer.keyDown(with: held) }

        XCTAssertTrue(rig.target.sent.isEmpty, "no bytes reach the shell from a held Space")
        XCTAssertEqual(rig.target.focusCount, 0)
        XCTAssertTrue(rig.stagingFrames.isEmpty, "nothing is reported to the daemon")
        XCTAssertEqual(rig.sessionFrames.count, sessionFramesBefore)
        XCTAssertEqual(host.drawer.notice, noticeBefore)
        XCTAssertEqual(host.drawer.selectedEntryId, selectedBefore)
        XCTAssertEqual(host.rows.map { $0.model }, modelsBefore)

        host.drawer.keyDown(with: spaceEvent(in: host.window, repeating: false))
        XCTAssertEqual(rig.target.sent, [Array("ls -la".utf8)], "a plain Space that is not a repeat still inserts")
    }

    func testSpaceWithACommandControlOptionOrShiftModifierInsertsNothing() {
        let (rig, host) = readyHost(gate: StagingGates.allowAll)
        host.drawer.focusRows()

        for (name, modifier) in [("command", NSEvent.ModifierFlags.command), ("control", .control),
                                 ("option", .option), ("shift", .shift)] {
            host.drawer.keyDown(with: spaceEvent(in: host.window, repeating: false, modifiers: [modifier]))
            XCTAssertTrue(rig.target.sent.isEmpty, "\(name)-Space inserts nothing")
            XCTAssertTrue(rig.stagingFrames.isEmpty, "\(name)-Space reports nothing")
            XCTAssertEqual(rig.target.focusCount, 0, "\(name)-Space")
        }

        host.drawer.keyDown(with: spaceEvent(in: host.window, repeating: false))
        XCTAssertEqual(rig.target.sent, [Array("ls -la".utf8)], "plain Space is the positive control")
    }

    func testHoldingSpaceOnARowThatJustChangedDoesNotInsertItWhenTheReadingDelayRunsOut() {
        let (rig, host) = readyHost(gate: StagingGates.allowAll)
        host.drawer.focusRows()
        rig.ingest(StagingFixtures.entries(["ls -la --color", "pwd", "date"]))   // the selected row just changed
        let w = host.window

        host.drawer.keyDown(with: spaceEvent(in: w, repeating: false))
        XCTAssertTrue(rig.target.sent.isEmpty, "the first press is inside the 1.5 s reading delay")

        rig.settle()   // the key is still down: its auto-repeats arrive after the delay
        for _ in 0..<3 { host.drawer.keyDown(with: spaceEvent(in: w, repeating: true)) }
        XCTAssertTrue(rig.target.sent.isEmpty, "a held key never turns into an insert")
        XCTAssertTrue(rig.insertedFrames.isEmpty)

        host.drawer.keyDown(with: spaceEvent(in: w, repeating: false))
        XCTAssertEqual(rig.target.sent, [Array("ls -la --color".utf8)], "a fresh press after the delay inserts")
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

    // MARK: - SB-10: VoiceOver sees one element per row (the real accessibility tree)

    /// Four rows: one with a note, one inserted and a placeholder, one long (Show all), one plain.
    private func voiceOverHost() -> (rig: StagingRig, host: StagingDrawerHost) {
        let rig = makeRig()
        let host = makeHost(rig, width: 400, bodyHeight: 1_000)
        rig.ingest([
            StagingFixtures.entry("s-1", 1, "git status --short", note: "see what changed"),
            StagingFixtures.entry("s-2", 2, "echo <name>", insertedCount: 1,
                                  lastInsertedAt: StagingFixtures.baseDate.addingTimeInterval(8)),
            StagingFixtures.entry("s-3", 3, String(repeating: "word ", count: 190)),
            StagingFixtures.entry("s-4", 4, "pwd"),
        ])
        rig.settle()
        host.drawer.refresh()
        host.relayout()
        host.window.contentView?.layoutSubtreeIfNeeded()
        return (rig, host)
    }

    /// The drawer's element in the tree a client sees, with everything inside it.
    private func drawerNode(_ host: StagingDrawerHost, file: StaticString = #filePath, line: UInt = #line) throws -> StagingAXNode {
        let everything = StagingAX.tree(under: host.container).flatMap { [$0] + $0.descendants }
        let groups = everything.filter { $0.role == .group && $0.label == "Staged commands" }
        XCTAssertEqual(groups.count, 1, "one group named Staged commands in the tree", file: file, line: line)
        return try XCTUnwrap(groups.first, "no element is the drawer", file: file, line: line)
    }

    func testTheDrawerIsOneAccessibilityGroupNamedStagedCommandsThatContainsTheRows() throws {
        let (_, host) = voiceOverHost()

        let drawer = try drawerNode(host)

        XCTAssertEqual(drawer.identifier, "staging-drawer")
        let labels = drawer.descendants.compactMap { $0.label }
        for row in host.rows {
            XCTAssertTrue(labels.contains(row.model.accessibilityLabel), "\(row.model.accessibilityLabel) is inside the group")
        }
    }

    func testEachStagedRowIsExactlyOneButtonWithItsSpokenLabelInTheAccessibilityTree() throws {
        let (_, host) = voiceOverHost()
        let drawer = try drawerNode(host)
        XCTAssertEqual(host.rows.count, 4)

        for row in host.rows {
            let spoken = row.model.accessibilityLabel
            let matches = drawer.descendants.filter { $0.label == spoken }
            XCTAssertEqual(matches.count, 1, "\(spoken): one element, not one per piece of text")
            XCTAssertEqual(matches.first?.role, .button, spoken)
            XCTAssertEqual(matches.first?.identifier, "staging-row", spoken)
        }
        let rowElements = drawer.descendants.filter { $0.identifier == "staging-row" }
        XCTAssertEqual(rowElements.count, 4, "exactly the four staged rows, nothing more")
        XCTAssertTrue(rowElements.allSatisfy { $0.role == .button })
    }

    func testNoneOfARowsChildTextIsASeparateAccessibilityElement() throws {
        let (_, host) = voiceOverHost()
        let drawer = try drawerNode(host)
        let rowElements = drawer.descendants.filter { $0.identifier == "staging-row" }
        XCTAssertEqual(rowElements.count, 4, "the rows must be elements before their text can be hidden")
        let seen = drawer.descendants.filter { $0.identifier != "staging-row" }

        for row in host.rows {
            let fields = row.subviews.compactMap { $0 as? NSTextField }
            XCTAssertGreaterThanOrEqual(fields.count, 5, "the row has its number, glyph, command, age and more")
            for field in fields {
                let shown = field.attributedStringValue.string
                XCTAssertFalse(seen.contains { $0.object === field },
                               "row \(row.model.number): the text field \"\(shown)\" is an element of its own")
                guard !shown.isEmpty else { continue }
                XCTAssertFalse(seen.contains { $0.value == shown || $0.label == shown },
                               "row \(row.model.number): \"\(shown)\" is read a second time, apart from the row's own label")
            }
        }
    }

    func testShowAllAndTheDrawersChevronAndMenuAreButtonsInTheAccessibilityTree() throws {
        let (_, host) = voiceOverHost()
        let drawer = try drawerNode(host)
        let longRow = try XCTUnwrap(host.rows.first { $0.model.command.hasPrefix("word ") })
        let showAll = try XCTUnwrap(host.showAll(of: longRow))
        XCTAssertFalse(showAll.isHidden, "the long row offers Show all")
        let inside = drawer.descendants

        let showAllNode = try XCTUnwrap(inside.first { $0.object === showAll }, "the long row's Show all is in the tree")
        XCTAssertEqual(showAllNode.role, .button)
        XCTAssertEqual(showAllNode.label, "Show all")
        for label in ["Collapse staged commands", "Staged commands menu"] {
            let matches = inside.filter { $0.label == label }
            XCTAssertEqual(matches.count, 1, "\(label): one element")
            XCTAssertEqual(matches.first?.role, .button, label)
        }
        for buttonText in ["Show all", "\u{25BE}"] {
            XCTAssertFalse(inside.contains { $0.role == .staticText && ($0.value == buttonText || $0.label == buttonText) },
                           "a button's own text (\(buttonText)) is not a second element beside it")
        }
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
        // Word wrapping with the last visible line cut: `.byTruncatingTail` would draw one line.
        XCTAssertEqual(note.lineBreakMode, .byWordWrapping)
        XCTAssertEqual(note.cell?.wraps, true)
        XCTAssertEqual(note.cell?.truncatesLastVisibleLine, true)
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
        let expected = NSNumber(value: NSWritingDirection.leftToRight.rawValue | (1 << 1))
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
                XCTAssertTrue(label.clipsToBounds, "\(name): the command's own label clips (macOS 14+ does not clip a text field by default)")
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
        // Every entry is still inside its reading delay (nothing was settled), so the only thing that
        // differs between the two revisions is the one command: only that row has anything to redraw.
        let rig = makeRig(gate: StagingGates.real())
        let host = makeHost(rig)
        rig.ingest(StagingFixtures.entries(["ls -la", "pwd", "date"]))
        host.drawer.refresh()
        let rowUpdates = host.drawer.rowUpdateCount
        let before = host.rows

        rig.ingest(StagingFixtures.entries(["ls -la", "pwd --changed", "date"]))

        XCTAssertEqual(host.drawer.rowUpdateCount, rowUpdates + 1, "one row redrawn")
        XCTAssertEqual(host.rows.map { $0.model.command }, ["ls -la", "pwd --changed", "date"])
        XCTAssertTrue(zip(before, host.rows).allSatisfy { $0 === $1 }, "rows are reused by entry id, not rebuilt")
    }

    /// One entry changing restarts the reading delay of every entry (the rows below it may have moved), so
    /// every row that was ready now says "Just changed": each is redrawn, and still in the same view.
    func testWhenOneEntryChangesEveryReadyRowGoesBackToJustChangedInTheSameRowViews() {
        let (rig, host) = readyHost()
        XCTAssertEqual(host.rows.map { $0.model.state }, [.ready, .ready, .ready], "harness")
        let before = host.rows

        rig.ingest(StagingFixtures.entries(["ls -la", "pwd --changed", "date"]))

        XCTAssertEqual(host.rows.map { $0.model.state }, Array(repeating: StagingRowModel.State.disabled(.justChanged), count: 3))
        XCTAssertTrue(zip(before, host.rows).allSatisfy { $0 === $1 }, "rows are reused by entry id, not rebuilt")

        rig.settle()
        host.drawer.refresh()
        XCTAssertEqual(host.rows.map { $0.model.state }, [.ready, .ready, .ready], "all readable again together")
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

    // MARK: - A terminal that does not take the bytes

    func testAClickWhoseBytesTheTerminalDoesNotTakeShowsTheNotSentNoticeAndPlacesNothing() throws {
        let (rig, host) = readyHost()
        rig.target.sendResult = false
        let row = try XCTUnwrap(host.rows.first)

        rig.click(row, in: host.window)

        XCTAssertEqual(host.drawer.notice, StagingDisabledReason.notSent.text)
        XCTAssertTrue(host.visibleTexts.contains(StagingDisabledReason.notSent.text), "\(host.visibleTexts)")
        XCTAssertTrue(rig.target.sent.isEmpty, "nothing reached the shell")
        XCTAssertEqual(rig.target.focusCount, 0, "the terminal does not take the keyboard")
        XCTAssertTrue(rig.insertedFrames.isEmpty, "nothing is reported as inserted")
        XCTAssertEqual(host.rows.first?.model.state, .ready, "the row does not claim it was inserted")

        // Not a state of the terminal: once it takes bytes again, the same row places its command.
        rig.target.sendResult = true
        rig.click(try XCTUnwrap(host.rows.first), in: host.window)
        XCTAssertEqual(rig.target.sent, [Array("ls -la".utf8)])
        XCTAssertNil(host.drawer.notice, "a placement that worked clears the refusal")
        XCTAssertEqual(rig.insertedFrames.count, 1)
    }

    func testASpaceWhoseBytesTheTerminalDoesNotTakeShowsTheSameNotice() {
        let (rig, host) = readyHost()
        rig.target.sendResult = false
        host.drawer.focusRows()

        host.drawer.keyDown(with: StagingEvents.space(in: host.window))

        XCTAssertEqual(host.drawer.notice, StagingDisabledReason.notSent.text)
        XCTAssertTrue(rig.target.sent.isEmpty)
        XCTAssertEqual(rig.target.focusCount, 0)
        XCTAssertTrue(rig.insertedFrames.isEmpty)
    }

    func testTheNotSentNoticeGoesAwayWhenWhatItWasAboutChanges() throws {
        let (rig, host) = readyHost()
        rig.target.sendResult = false
        rig.click(try XCTUnwrap(host.rows.first), in: host.window)
        XCTAssertEqual(host.drawer.notice, StagingDisabledReason.notSent.text)

        rig.ingest(StagingFixtures.entries(["ls -la --changed", "pwd", "date"]))

        XCTAssertNil(host.drawer.notice)
        XCTAssertFalse(host.visibleTexts.contains(StagingDisabledReason.notSent.text))
    }

    // MARK: - Ages tick in place

    func testAClockTickInTheFirstMinuteUpdatesTheAgeInPlaceAndKeepsTheRefusalNoticeAndTheLayout() throws {
        let rig = makeRig(gate: StagingGates.real())
        let host = makeHost(rig)
        rig.ingest(StagingFixtures.entries(["echo one"]))   // just changed: a click is refused
        host.drawer.refresh()
        let row = try XCTUnwrap(host.rows.first)
        let age = try XCTUnwrap(host.label(of: row, text: "10s"), "harness: the row's age label")
        rig.click(row, in: host.window)
        XCTAssertEqual(host.drawer.notice, StagingDisabledReason.justChanged.text, "harness: a refusal notice is showing")
        let rowUpdates = host.drawer.rowUpdateCount
        let layoutRequests = host.state.layoutRequests
        let heightBefore = host.height

        for seconds in 1...3 {
            host.state.date = host.state.date.addingTimeInterval(1)
            host.drawer.refresh()
            XCTAssertEqual(age.stringValue, "\(10 + seconds)s", "the age moves on every tick")
        }

        XCTAssertEqual(host.drawer.notice, StagingDisabledReason.justChanged.text, "an age tick is not a change: the reason stays")
        XCTAssertTrue(host.visibleTexts.contains(StagingDisabledReason.justChanged.text))
        XCTAssertEqual(host.drawer.rowUpdateCount, rowUpdates, "no row is redrawn for an age")
        XCTAssertEqual(host.state.layoutRequests, layoutRequests, "the host is not asked to lay out again for an age")
        XCTAssertEqual(host.height, heightBefore)
        XCTAssertTrue(host.rows.first === row, "the same row view")
        XCTAssertEqual(host.rows.first?.model.age, "13s", "the model the row holds is current too")
    }

    func testAnInsertedRowsAgoTextUpdatesInPlaceWithoutALayoutRequest() throws {
        let rig = makeRig(gate: StagingGates.real())
        let host = makeHost(rig)
        rig.ingest([StagingFixtures.entry("s-1", 1, "ls -la", insertedCount: 1,
                                          lastInsertedAt: StagingFixtures.baseDate.addingTimeInterval(8))])
        rig.settle()
        host.drawer.refresh()
        let row = try XCTUnwrap(host.rows.first)
        let ago = try XCTUnwrap(host.label(of: row, text: "inserted 2s ago"), "harness: \(host.visibleTexts)")
        let rowUpdates = host.drawer.rowUpdateCount
        let layoutRequests = host.state.layoutRequests

        host.state.date = host.state.date.addingTimeInterval(3)
        host.drawer.refresh()

        XCTAssertEqual(ago.stringValue, "inserted 5s ago")
        XCTAssertEqual(host.drawer.rowUpdateCount, rowUpdates)
        XCTAssertEqual(host.state.layoutRequests, layoutRequests)
        XCTAssertEqual(host.rows.first?.accessibilityLabel(), host.rows.first?.model.accessibilityLabel,
                       "what VoiceOver says is current as well")
        XCTAssertTrue(host.rows.first?.accessibilityLabel()?.contains("inserted 5s ago") == true)
    }

    func testANewRevisionStillClearsTheRefusalNoticeThatAnAgeTickKept() throws {
        let rig = makeRig(gate: StagingGates.real())
        let host = makeHost(rig)
        rig.ingest(StagingFixtures.entries(["echo one"]))
        host.drawer.refresh()
        rig.click(try XCTUnwrap(host.rows.first), in: host.window)
        XCTAssertEqual(host.drawer.notice, StagingDisabledReason.justChanged.text)
        host.state.date = host.state.date.addingTimeInterval(3)
        host.drawer.refresh()
        XCTAssertNotNil(host.drawer.notice, "harness: the age tick kept it")

        rig.ingest(StagingFixtures.entries(["echo one", "echo two"]))

        XCTAssertNil(host.drawer.notice)
    }

    func testARowChangingStateStillClearsTheRefusalNoticeThatAnAgeTickKept() throws {
        let rig = makeRig(gate: StagingGates.real())
        let host = makeHost(rig)
        rig.ingest(StagingFixtures.entries(["echo one"]))
        host.drawer.refresh()
        rig.click(try XCTUnwrap(host.rows.first), in: host.window)
        XCTAssertEqual(host.drawer.notice, StagingDisabledReason.justChanged.text)

        rig.settle()          // the reading delay is over: the row is ready, which is a real change to it
        host.drawer.refresh()

        XCTAssertEqual(host.rows.first?.model.state, .ready)
        XCTAssertNil(host.drawer.notice)
    }

    // MARK: - Rows hold still: nothing moves under the pointer when a row becomes clickable

    /// Where a person can aim, as the host has laid it out: each row in the drawer's document and in the
    /// window, and the drawer itself.
    private struct DrawerGeometry {
        let rowIds: [String]
        let documentFrames: [NSRect]
        let windowFrames: [NSRect]
        let drawerFrame: NSRect
        let preferredHeight: CGFloat
    }

    private func geometry(of host: StagingDrawerHost) -> DrawerGeometry {
        DrawerGeometry(rowIds: host.rows.map { $0.model.entryId },
                       documentFrames: host.rows.map { $0.frame },
                       windowFrames: host.rows.map { $0.convert($0.bounds, to: nil) },
                       drawerFrame: host.drawer.frame,
                       preferredHeight: host.drawer.preferredHeight(forBodyHeight: host.bodyHeight, width: host.width))
    }

    private func assertSameRect(_ a: NSRect, _ b: NSRect, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let moved = max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.width - b.width), abs(a.height - b.height))
        XCTAssertLessThanOrEqual(moved, 0.01, "\(message): \(a) became \(b)", file: file, line: line)
    }

    /// Every row is in the same place in the window (a row a person is about to click has not moved).
    private func assertRowsStill(_ a: DrawerGeometry, _ b: DrawerGeometry, _ tag: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.rowIds, b.rowIds, "\(tag): the same rows", file: file, line: line)
        guard a.rowIds == b.rowIds else { return }
        for (index, id) in a.rowIds.enumerated() {
            assertSameRect(a.windowFrames[index], b.windowFrames[index], "\(tag): row \(id) moved in the window", file: file, line: line)
        }
    }

    /// Nothing moved or resized: each row in the window and in the drawer's document, the drawer's frame and
    /// the height it asks the host for.
    private func assertSameGeometry(_ a: DrawerGeometry, _ b: DrawerGeometry, _ tag: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        assertRowsStill(a, b, tag, file: file, line: line)
        guard a.rowIds == b.rowIds else { return }
        for (index, id) in a.rowIds.enumerated() {
            assertSameRect(a.documentFrames[index], b.documentFrames[index], "\(tag): row \(id) moved in the drawer", file: file, line: line)
        }
        assertSameRect(a.drawerFrame, b.drawerFrame, "\(tag): the drawer's frame", file: file, line: line)
        XCTAssertEqual(a.preferredHeight, b.preferredHeight, accuracy: 0.01, "\(tag): the height the drawer asks for", file: file, line: line)
    }

    private var wrappedBoundaryCommand: String {
        "docker run --rm -it -v $(pwd):/work -w /work -e FOO=bar ghcr.io/example/builder:latest make test-all"
    }

    /// A list that looks like a real one: a plain command, a command that wraps (and needs Show all at 200 pt),
    /// a `<name>` placeholder (the app's own label), one with a note, one that was inserted before (a line
    /// `inserted 2s ago` once it is readable) and one the app will not insert (a tab).
    private func readingBoundaryEntries() -> [StagingEntry] {
        [StagingFixtures.entry("s-1", 1, "ls -la"),
         StagingFixtures.entry("s-2", 2, wrappedBoundaryCommand),
         StagingFixtures.entry("s-3", 3, "scp <file> host:/tmp"),
         StagingFixtures.entry("s-4", 4, "git status --short", note: "Run this first to see what changed, then decide what to commit"),
         StagingFixtures.entry("s-5", 5, "make build", insertedCount: 1, lastInsertedAt: StagingFixtures.baseDate.addingTimeInterval(8)),
         StagingFixtures.entry("s-6", 6, "ls\u{09}-la")]
    }

    /// Stages the list and lets it be read, changes it with `change`, looks at the drawer 1.49 s later (every
    /// row still "Just changed") and 1.51 s later (the rows are clickable) and says where everything was each time.
    private func drawerAroundTheEndOfTheReadingDelay(width: CGFloat, tag: String, change: ([StagingEntry]) -> [StagingEntry])
        -> (before: DrawerGeometry, after: DrawerGeometry) {
        let rig = makeRig(gate: StagingGates.real())
        let host = makeHost(rig, width: width, bodyHeight: 2_000)
        let initial = readingBoundaryEntries()
        rig.ingest(initial)
        rig.settle()
        host.drawer.refresh()
        host.relayout()

        rig.ingest(change(initial))
        rig.box.storeClock += StagingDrawerModel.readingDelay - 0.01
        host.drawer.refresh()
        host.relayout()
        XCTAssertGreaterThanOrEqual(host.rows.count, 5, "\(tag): harness: the rows are there")
        XCTAssertTrue(host.rows.allSatisfy { $0.model.state == .disabled(.justChanged) },
                      "\(tag): harness: at 1.49 s every row still says it just changed: \(host.rows.map { $0.model.state })")
        let before = geometry(of: host)

        rig.box.storeClock += 0.02
        host.drawer.refresh()
        host.relayout()
        for row in host.rows {
            let expected: StagingRowModel.State
            switch row.model.entryId {
            case "s-5": expected = .inserted(ago: "inserted 2s ago")
            case "s-6": expected = .disabled(.notInsertable)
            default:    expected = .ready
            }
            XCTAssertEqual(row.model.state, expected, "\(tag): harness: \(row.model.entryId) at 1.51 s")
        }
        return (before, geometry(of: host))
    }

    func testNoRowMovesWhenTheReadingDelayEndsAfterAnEdit() {
        for width in [200.0, 400.0] {
            let tag = "edit, width \(Int(width))"
            let result = drawerAroundTheEndOfTheReadingDelay(width: CGFloat(width), tag: tag) { entries in
                var edited = entries
                edited[0] = StagingFixtures.entry("s-1", 1, "ls -la --color=always")
                return edited
            }
            assertSameGeometry(result.before, result.after, "\(tag): between 1.49 s and 1.51 s")
        }
    }

    func testNoRowMovesWhenTheReadingDelayEndsAfterAnEntryIsAdded() {
        for width in [200.0, 400.0] {
            let tag = "add, width \(Int(width))"
            let result = drawerAroundTheEndOfTheReadingDelay(width: CGFloat(width), tag: tag) { entries in
                var added = entries
                added.insert(StagingFixtures.entry("s-7", 7, "git log --oneline -5", note: "the last five commits"), at: 2)
                return added
            }
            assertSameGeometry(result.before, result.after, "\(tag): between 1.49 s and 1.51 s")
        }
    }

    func testNoRowMovesWhenTheReadingDelayEndsAfterAnEntryIsRemoved() {
        for width in [200.0, 400.0] {
            let tag = "remove, width \(Int(width))"
            let result = drawerAroundTheEndOfTheReadingDelay(width: CGFloat(width), tag: tag) { entries in
                entries.filter { $0.id != "s-2" }
            }
            assertSameGeometry(result.before, result.after, "\(tag): between 1.49 s and 1.51 s")
        }
    }

    // MARK: Notices and reasons come and go without moving a row

    func testAJustChangedRefusalNoticeAppearingAndClearingNeverMovesARowOrChangesTheDrawersHeight() throws {
        for width in [200.0, 400.0] {
            let tag = "width \(Int(width))"
            let rig = makeRig(gate: StagingGates.real())
            let host = makeHost(rig, width: CGFloat(width), bodyHeight: 2_000)
            rig.ingest(readingBoundaryEntries())    // just changed: a click is refused
            host.drawer.refresh()
            host.relayout()
            let before = geometry(of: host)

            rig.click(try XCTUnwrap(host.rows.first, tag), in: host.window)
            host.relayout()
            XCTAssertEqual(host.drawer.notice, StagingDisabledReason.justChanged.text, "\(tag): harness: the refusal is showing")
            XCTAssertTrue(host.visibleTexts.contains(StagingDisabledReason.justChanged.text), "\(tag): harness: \(host.visibleTexts)")
            let during = geometry(of: host)

            rig.settle()     // the reading delay is over: the row is ready and the notice goes
            host.drawer.refresh()
            host.relayout()
            XCTAssertNil(host.drawer.notice, "\(tag): harness: the notice is gone")
            let after = geometry(of: host)

            assertSameGeometry(before, during, "\(tag): the notice appearing")
            assertSameGeometry(during, after, "\(tag): the notice clearing at the ready transition")
        }
    }

    func testTheNotSentNoticeAppearingAndClearingNeverMovesARowOrChangesTheDrawersHeight() throws {
        for width in [200.0, 400.0] {
            let tag = "width \(Int(width))"
            let rig = makeRig(gate: StagingGates.real())
            let host = makeHost(rig, width: CGFloat(width), bodyHeight: 2_000)
            let entries = readingBoundaryEntries()
            rig.ingest(entries)
            rig.settle()
            host.drawer.refresh()
            host.relayout()
            let before = geometry(of: host)

            rig.target.sendResult = false
            rig.click(try XCTUnwrap(host.rows.first, tag), in: host.window)
            host.relayout()
            XCTAssertEqual(host.drawer.notice, StagingDisabledReason.notSent.text, "\(tag): harness: the notice is showing")
            XCTAssertTrue(host.visibleTexts.contains(StagingDisabledReason.notSent.text), "\(tag): harness: \(host.visibleTexts)")
            let during = geometry(of: host)

            // The same rows again in a newer frame: what the notice was about is no longer there, the rows are the same.
            rig.ingest(entries)
            host.relayout()
            XCTAssertNil(host.drawer.notice, "\(tag): harness: the notice is gone")
            let after = geometry(of: host)

            assertSameGeometry(before, during, "\(tag): the notice appearing")
            assertSameGeometry(during, after, "\(tag): the notice clearing")
        }
    }

    func testAMirrorWindowBecomingTheDriverAndMirrorAgainNeverMovesARow() {
        for width in [200.0, 400.0] {
            let tag = "width \(Int(width))"
            let rig = makeRig(gate: StagingGates.real())
            let side = rig.makeSide(isMirror: true, gate: StagingGates.real())
            let host = makeHost(rig, side: side, width: CGFloat(width), bodyHeight: 2_000)
            // Rows with no line of their own once readable: it is the shared reason that comes and goes.
            rig.ingest(Array(readingBoundaryEntries().prefix(4)))
            rig.settle()
            host.drawer.refresh()
            host.relayout()
            XCTAssertTrue(host.visibleTexts.contains(StagingDisabledReason.mirror.text), "\(tag): harness: the shared reason is showing")
            let asMirror = geometry(of: host)

            side.context?.isMirror = false      // a click in the terminal: this window drives now
            host.drawer.refresh()
            host.relayout()
            XCTAssertFalse(host.visibleTexts.contains(StagingDisabledReason.mirror.text), "\(tag): harness: the shared reason is gone")
            XCTAssertEqual(host.rows.first?.model.state, .ready, "\(tag): harness: the rows are live")
            let asDriver = geometry(of: host)

            side.context?.isMirror = true       // another window took the terminal back
            host.drawer.refresh()
            host.relayout()
            XCTAssertTrue(host.visibleTexts.contains(StagingDisabledReason.mirror.text), "\(tag): harness: the shared reason is back")
            let mirrorAgain = geometry(of: host)

            assertRowsStill(asMirror, asDriver, "\(tag): the shared reason clearing")
            assertRowsStill(asDriver, mirrorAgain, "\(tag): the shared reason appearing")
        }
    }

    // MARK: - The drawer gives the keyboard back when it goes away

    func testADrawerThatHoldsTheKeyboardGivesItBackExactlyOnceWhenItsListGoesAway() {
        let ways: [(String, (StagingRig) -> Void)] = [
            ("a none frame", { rig in rig.ingest([], state: .none) }),
            ("the terminal closing", { rig in rig.staging.terminalClosed(StagingFixtures.terminalId) }),
        ]
        for (name, goAway) in ways {
            let (rig, host) = readyHost()
            var returned = 0
            host.drawer.onReturnToTerminal = { returned += 1 }
            XCTAssertTrue(host.drawer.focusRows(), name)
            XCTAssertTrue(host.window.firstResponder === host.drawer, "harness: \(name)")

            goAway(rig)

            XCTAssertEqual(returned, 1, name)
            XCTAssertFalse(host.drawer.hasList, name)
            host.drawer.refresh()
            XCTAssertEqual(returned, 1, "\(name): not again on the next refresh")
        }
    }

    func testADrawerThatNeverHeldTheKeyboardDoesNotAskForItToBeGivenBack() {
        let (rig, host) = readyHost()
        var returned = 0
        host.drawer.onReturnToTerminal = { returned += 1 }

        rig.ingest([], state: .none)

        XCTAssertEqual(returned, 0, "the keyboard was never the drawer's")
        XCTAssertFalse(host.drawer.hasList)
    }

    func testADrawerWhileSomethingElseHoldsTheKeyboardLeavesItThere() {
        let (rig, host) = readyHost()
        var returned = 0
        host.drawer.onReturnToTerminal = { returned += 1 }
        let probe = StagingFocusProbe()
        probe.frame = NSRect(x: 0, y: 300, width: 20, height: 20)
        host.container.addSubview(probe)
        XCTAssertTrue(host.window.makeFirstResponder(probe))

        rig.staging.terminalClosed(StagingFixtures.terminalId)

        XCTAssertEqual(returned, 0, "something else held the keyboard")
        XCTAssertTrue(host.window.firstResponder === probe)
        XCTAssertFalse(host.drawer.hasList)
    }

    func testADrawerThatHoldsTheKeyboardGivesItBackExactlyOnceWhenItsListBecomesUnreadableAndAReplayedFrameDoesNotBringItBack() {
        let (rig, host) = readyHost()
        var returned = 0
        host.drawer.onReturnToTerminal = { returned += 1 }
        XCTAssertTrue(host.drawer.focusRows())
        XCTAssertTrue(host.window.firstResponder === host.drawer, "harness")

        rig.staging.listUnreadable(StagingFixtures.terminalId)

        XCTAssertEqual(returned, 1)
        XCTAssertFalse(host.drawer.hasList)
        XCTAssertTrue(host.drawer.isHidden)
        XCTAssertEqual(host.height, 0)
        host.drawer.refresh()
        XCTAssertEqual(returned, 1, "not again on the next refresh")

        // The daemon's revision 1 was seen already: a replay of it shows nothing. A newer frame does.
        rig.staging.ingest(StagingFixtures.list(revision: 1, entries: StagingFixtures.entries(["ls -la"])))
        XCTAssertFalse(host.drawer.hasList, "a replayed frame does not bring the drawer back")
        rig.ingest(StagingFixtures.entries(["ls -la"]))
        XCTAssertTrue(host.drawer.hasList, "a newer frame does")
    }

    func testADrawerThatNeverHeldTheKeyboardDoesNotAskForItToBeGivenBackWhenItsListBecomesUnreadable() {
        let (rig, host) = readyHost()
        var returned = 0
        host.drawer.onReturnToTerminal = { returned += 1 }

        rig.staging.listUnreadable(StagingFixtures.terminalId)

        XCTAssertEqual(returned, 0, "the keyboard was never the drawer's")
        XCTAssertFalse(host.drawer.hasList)
    }

    // MARK: - Copy and the reading delay (the row's context menu)

    private func copyItem(of row: StagingRowView, in window: NSWindow) throws -> NSMenuItem {
        let menu = try XCTUnwrap(row.menu(for: StagingEvents.mouse(.leftMouseDown, in: window, at: NSPoint(x: 5, y: 5))))
        return try XCTUnwrap(menu.items.first { $0.title == "Copy" })
    }

    func testTheContextMenusCopyIsDisabledWithinTheReadingDelayAndEnabledAfterIt() throws {
        let rig = makeRig()
        let host = makeHost(rig)
        rig.ingest(StagingFixtures.entries(["ls -la"]))
        let row = try XCTUnwrap(host.rows.first)

        XCTAssertFalse(try copyItem(of: row, in: host.window).isEnabled, "the text has just appeared")
        rig.settle(1.0)
        XCTAssertFalse(try copyItem(of: row, in: host.window).isEnabled, "one second is not enough")
        rig.settle(0.5)
        XCTAssertTrue(try copyItem(of: row, in: host.window).isEnabled, "one and a half seconds")

        rig.ingest(StagingFixtures.entries(["ls -la --changed"]))
        XCTAssertFalse(try copyItem(of: row, in: host.window).isEnabled, "a change starts the delay again")
        rig.settle()
        XCTAssertTrue(try copyItem(of: row, in: host.window).isEnabled)
    }

    func testTheContextMenusCopyIsStillEnabledAfterTheDelayOnARowThatCannotBePlaced() throws {
        let rig = makeRig()
        let mirrorSide = rig.makeSide(isMirror: true)
        let mirror = makeHost(rig, side: mirrorSide)
        rig.ingest(StagingFixtures.entries(["ls -la"]))

        XCTAssertFalse(try copyItem(of: try XCTUnwrap(mirror.rows.first), in: mirror.window).isEnabled, "inside the delay, even in a mirror")
        rig.settle()
        XCTAssertTrue(try copyItem(of: try XCTUnwrap(mirror.rows.first), in: mirror.window).isEnabled)
        XCTAssertEqual(mirror.rows.first?.model.disabledReason, .mirror, "harness: the row is one that cannot be placed")
    }

    // MARK: - The reason under the header wraps and is never cut

    /// The height the text needs in a text field's own cell `width` wide, with no line limit.
    private func neededCellHeight(of text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.lineBreakMode = .byWordWrapping
        field.cell?.wraps = true
        field.maximumNumberOfLines = 0
        return ceil(field.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000)).height)
    }

    private func reasonLabel(in host: StagingDrawerHost, text: String) -> NSTextField? {
        host.drawer.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == text }
    }

    private func mirrorHost(width: CGFloat) -> (rig: StagingRig, host: StagingDrawerHost) {
        let rig = makeRig(gate: StagingGates.real())
        let side = rig.makeSide(isMirror: true, gate: StagingGates.real())
        let host = makeHost(rig, side: side, width: width, bodyHeight: 1_000)
        rig.ingest(StagingFixtures.entries(["ls -la"]))
        rig.settle()
        host.drawer.refresh()
        host.relayout()
        return (rig, host)
    }

    func testTheMirrorReasonIsFullyShownAtEveryNarrowWidthAndTheRowsStartBelowIt() throws {
        let text = StagingDisabledReason.mirror.text
        let lineHeight = NSLayoutManager().defaultLineHeight(for: Theme.statusFont)
        for width in [200.0, 280.0, 600.0] {
            let w = CGFloat(width)
            let tag = "width \(Int(width))"
            let (_, host) = mirrorHost(width: w)
            let label = try XCTUnwrap(reasonLabel(in: host, text: text), "the reason is in the drawer at \(tag)")

            XCTAssertFalse(label.isHiddenOrHasHiddenAncestor, tag)
            XCTAssertGreaterThan(label.frame.width, 0, tag)
            XCTAssertTrue(host.drawer.bounds.insetBy(dx: -0.5, dy: -0.5).contains(label.frame), "\(tag): \(label.frame) in \(host.drawer.bounds)")

            // Not cut: the text, wrapped as its own cell wraps it at the label's width, needs no more than the label has.
            let needed = neededCellHeight(of: text, font: Theme.statusFont, width: label.frame.width)
            XCTAssertLessThanOrEqual(needed, label.frame.height + 0.5, "\(tag): the reason needs \(needed) pt but the label is \(label.frame.height) pt high")
            XCTAssertLessThanOrEqual(needed, lineHeight * CGFloat(StagingDrawerView.reasonLines) + 2, "\(tag): at most \(StagingDrawerView.reasonLines) lines")

            // The rows begin below it.
            let scroll = try XCTUnwrap(host.scroll, tag)
            XCTAssertGreaterThanOrEqual(scroll.frame.minY, label.frame.maxY - 0.5, "\(tag): the rows overlap the reason")
            XCTAssertFalse(overlaps(scroll.frame, label.frame), tag)
            // And the header above it.
            for field in host.drawer.subviews.compactMap({ $0 as? NSTextField }) where field !== label && !field.isHidden {
                XCTAssertFalse(overlaps(field.frame, label.frame), "\(tag): \"\(field.stringValue)\" overlaps the reason")
            }
        }
    }

    func testTheMirrorReasonTakesTwoLinesAtTwoHundredPointsAndOneLineWhenThereIsRoom() throws {
        let text = StagingDisabledReason.mirror.text
        let lineHeight = NSLayoutManager().defaultLineHeight(for: Theme.statusFont)

        let narrow = mirrorHost(width: 200)
        let wide = mirrorHost(width: 600)
        let narrowLabel = try XCTUnwrap(reasonLabel(in: narrow.host, text: text))
        let wideLabel = try XCTUnwrap(reasonLabel(in: wide.host, text: text))

        XCTAssertGreaterThanOrEqual(narrowLabel.frame.height, 2 * lineHeight - 0.5, "the text needs two lines at 200 pt")
        XCTAssertLessThan(wideLabel.frame.height, 2 * lineHeight - 0.5, "one line is enough at 600 pt")
        XCTAssertGreaterThanOrEqual(wideLabel.frame.height, lineHeight - 0.5)

        // The drawer asks the host for the extra line, and about one line more.
        let extra = narrow.host.height - wide.host.height
        XCTAssertGreaterThan(extra, lineHeight * 0.5, "a narrow drawer is taller by the second line of the reason")
        XCTAssertLessThan(extra, lineHeight * 1.5 + 1, "and by about one line, not more")
        XCTAssertGreaterThan(narrow.host.drawer.preferredHeight(forBodyHeight: 1_000, width: 200),
                             wide.host.drawer.preferredHeight(forBodyHeight: 1_000, width: 600))
    }

    // MARK: - The reason label itself wraps and draws its lines (not a separate cell measured for it)

    /// The pixel rows of what `view` draws by itself (nothing behind it) that hold ink, as bands: a run of
    /// rows with ink ended by a row with none. One band is one line of text, two bands are two lines.
    private func inkBands(of view: NSView) throws -> (bands: [Range<Int>], pointsPerPixelRow: CGFloat) {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds), "harness: a bitmap to draw the label into")
        view.cacheDisplay(in: view.bounds, to: rep)
        var bands: [Range<Int>] = []
        var start: Int?
        for y in 0..<rep.pixelsHigh {
            var hasInk = false
            for x in 0..<rep.pixelsWide {
                if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 {
                    hasInk = true
                    break
                }
            }
            if hasInk {
                if start == nil { start = y }
            } else if let began = start {
                bands.append(began..<y)
                start = nil
            }
        }
        if let began = start { bands.append(began..<rep.pixelsHigh) }
        return (bands, view.bounds.height / CGFloat(max(1, rep.pixelsHigh)))
    }

    /// The height `label`'s own cell needs for the label's own text at the label's own width, no line limit.
    private func ownCellNeed(of label: NSTextField) -> CGFloat {
        let saved = label.maximumNumberOfLines
        label.maximumNumberOfLines = 0
        defer { label.maximumNumberOfLines = saved }
        return ceil(label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.frame.width, height: 10_000)).height)
    }

    /// A label that shows at most two wrapped lines: its cell wraps at words and cuts the last visible line.
    /// (A label whose cell does not wrap draws one truncated line however tall its frame is.)
    private func assertWrapsInTwoLinesAndCutsTheLast(_ label: NSTextField, _ tag: String,
                                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(label.cell?.wraps, true, "\(tag): the label's own cell wraps", file: file, line: line)
        XCTAssertEqual(label.lineBreakMode, .byWordWrapping, "\(tag): it breaks lines at words", file: file, line: line)
        XCTAssertEqual(label.maximumNumberOfLines, 2, "\(tag): at most two lines", file: file, line: line)
        XCTAssertEqual(label.cell?.truncatesLastVisibleLine, true, "\(tag): what does not fit is cut at the end of the last line", file: file, line: line)
    }

    func testTheReasonLabelItselfIsSetToWrapAtWordsInTwoLinesAndCutTheLast() throws {
        let text = StagingDisabledReason.mirror.text
        for width in [200.0, 600.0] {
            let (_, host) = mirrorHost(width: CGFloat(width))
            let label = try XCTUnwrap(reasonLabel(in: host, text: text), "width \(Int(width))")

            assertWrapsInTwoLinesAndCutsTheLast(label, "width \(Int(width))")
            XCTAssertEqual(StagingDrawerView.reasonLines, 2, "harness")
        }
    }

    func testTheReasonLabelsOwnCellNeedsTwoLinesAtTwoHundredPointsAndTheLabelHasRoomForThemAndOneLineWhenThereIsRoom() throws {
        let text = StagingDisabledReason.mirror.text
        let lineHeight = NSLayoutManager().defaultLineHeight(for: Theme.statusFont)
        let narrow = mirrorHost(width: 200)
        let wide = mirrorHost(width: 600)
        let narrowLabel = try XCTUnwrap(reasonLabel(in: narrow.host, text: text))
        let wideLabel = try XCTUnwrap(reasonLabel(in: wide.host, text: text))

        // Measured by the label's OWN cell, which is what draws it.
        let narrowNeed = ownCellNeed(of: narrowLabel)
        let wideNeed = ownCellNeed(of: wideLabel)
        XCTAssertGreaterThanOrEqual(narrowNeed, 2 * lineHeight - 0.5, "the label's own cell needs two lines at 200 pt, not one: \(narrowNeed) pt")
        XCTAssertLessThan(narrowNeed, 3 * lineHeight - 0.5, "and not three")
        XCTAssertLessThan(wideNeed, 2 * lineHeight - 0.5, "one line is enough at 600 pt: \(wideNeed) pt")
        XCTAssertGreaterThanOrEqual(narrowLabel.frame.height, narrowNeed - 0.5, "the label is as tall as its own cell needs")
        XCTAssertGreaterThanOrEqual(wideLabel.frame.height, wideNeed - 0.5)
    }

    func testTheReasonLabelDrawsBothWrappedLinesInsideItsOwnFrameAtTwoHundredPointsAndOneLineWhenThereIsRoom() throws {
        let text = StagingDisabledReason.mirror.text
        let narrow = mirrorHost(width: 200)
        let wide = mirrorHost(width: 600)
        let narrowLabel = try XCTUnwrap(reasonLabel(in: narrow.host, text: text))
        let wideLabel = try XCTUnwrap(reasonLabel(in: wide.host, text: text))

        // Rendered by the label itself into a bitmap: lines of ink, counted. (No descender in this text,
        // so two lines are two clearly separate bands.)
        let narrowInk = try inkBands(of: narrowLabel)
        let wideInk = try inkBands(of: wideLabel)

        XCTAssertEqual(narrowInk.bands.count, 2, "the reason's label draws two lines of text at 200 pt: \(narrowInk.bands) in \(narrowLabel.frame)")
        XCTAssertEqual(wideInk.bands.count, 1, "and one line at 600 pt: \(wideInk.bands) in \(wideLabel.frame)")
    }

    // MARK: - Stacked combining marks cannot cover the lines below the command

    func testTheLinesBelowACommandOfStackedCombiningMarksSitBelowItsClippedLabel() throws {
        let command = "e" + String(repeating: "\u{0301}", count: 30) + "cho <name>"
        for width in [200.0, 280.0, 400.0] {
            let rig = makeRig()
            let host = makeHost(rig, width: CGFloat(width), bodyHeight: 1_000)
            rig.ingest([StagingFixtures.entry("s-1", 1, command, note: "check the path first", insertedCount: 1,
                                              lastInsertedAt: StagingFixtures.baseDate.addingTimeInterval(8))])
            rig.settle()
            host.drawer.refresh()
            host.relayout()
            let row = try XCTUnwrap(host.rows.first)
            row.needsLayout = true
            row.layoutSubtreeIfNeeded()
            let tag = "width \(Int(width))"

            let label = try XCTUnwrap(host.commandLabel(of: row), tag)
            XCTAssertTrue(label.clipsToBounds, "\(tag): the command's label clips its own drawing")
            let below: [(String, NSTextField?)] = [
                ("placeholder warning", host.label(of: row, text: StagingDrawerModel.placeholderLabel)),
                ("state line", host.label(of: row, text: "inserted 2s ago")),
                ("note", row.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue.contains("(unverified)") }),
            ]
            for (name, field) in below {
                let f = try XCTUnwrap(field, "\(name) at \(tag)")
                XCTAssertFalse(f.isHidden, "\(name) at \(tag)")
                XCTAssertGreaterThan(f.frame.height, 0, "\(name) at \(tag)")
                XCTAssertGreaterThanOrEqual(f.frame.minY, label.frame.maxY - 0.5, "\(name) is not below the command at \(tag)")
                XCTAssertFalse(overlaps(f.frame, label.frame), "\(name) intersects the command at \(tag)")
                XCTAssertTrue(row.bounds.insetBy(dx: -0.5, dy: -0.5).contains(f.frame), "\(name) leaves its row at \(tag): \(f.frame) in \(row.bounds)")
            }
        }
    }

    func testThePlaceholderWarningIsTallEnoughForEveryLineItsOwnCellDrawsAtNarrowWidths() throws {
        for width in [200.0, 280.0, 400.0] {
            let rig = makeRig()
            let host = makeHost(rig, width: CGFloat(width), bodyHeight: 1_000)
            rig.ingest(StagingFixtures.entries(["scp <file> host:/tmp"]))
            rig.settle()
            host.drawer.refresh()
            host.relayout()
            let row = try XCTUnwrap(host.rows.first)
            row.needsLayout = true
            row.layoutSubtreeIfNeeded()
            let tag = "width \(Int(width))"

            let warning = try XCTUnwrap(host.label(of: row, text: StagingDrawerModel.placeholderLabel), tag)
            XCTAssertFalse(warning.isHidden, tag)

            // What the label's own cell needs at the label's width, with no line limit.
            let savedLines = warning.maximumNumberOfLines
            warning.maximumNumberOfLines = 0
            let needed = ceil(warning.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: warning.frame.width, height: 10_000)).height)
            warning.maximumNumberOfLines = savedLines

            XCTAssertGreaterThanOrEqual(warning.frame.height, needed - 0.5,
                                        "\(tag): the warning needs \(needed) pt but its label is \(warning.frame.height) pt high, so a line is cut")
            XCTAssertTrue(row.bounds.insetBy(dx: -0.5, dy: -0.5).contains(warning.frame), "\(tag): \(warning.frame) in \(row.bounds)")
            if let command = host.commandLabel(of: row) {
                XCTAssertGreaterThanOrEqual(warning.frame.minY, command.frame.maxY - 0.5, tag)
            }
        }
    }

    // MARK: - The note under a command wraps in its own label, two lines at most

    private var veryLongNote: String {
        "Run the whole migration suite before you push this branch, because the last two reviews both found a missing index and a rename that broke the staging seed script, and nobody wants a third round of that"
    }

    /// A drawer with one plain row carrying `note`, laid out at `width`, and the label that draws the note.
    private func noteRow(width: CGFloat, note: String) throws -> (host: StagingDrawerHost, row: StagingRowView, label: NSTextField) {
        let rig = makeRig()
        let host = makeHost(rig, width: width, bodyHeight: 1_000)
        rig.ingest([StagingFixtures.entry("s-1", 1, "echo hello", note: note)])
        rig.settle()
        host.drawer.refresh()
        host.relayout()
        let row = try XCTUnwrap(host.rows.first)
        row.needsLayout = true
        row.layoutSubtreeIfNeeded()
        let fields = row.subviews.compactMap { $0 as? NSTextField }
        let label = try XCTUnwrap(fields.first { $0.stringValue.contains("(unverified)") }, "the note is in the row at width \(Int(width))")
        return (host, row, label)
    }

    func testTheNotesOwnLabelWrapsAtWordsAndCutsOnlyItsLastOfTwoLinesAndStillSaysUnverifiedAtTheStart() throws {
        for width in [200.0, 400.0] {
            let tag = "width \(Int(width))"
            let (_, row, label) = try noteRow(width: CGFloat(width), note: veryLongNote)

            assertWrapsInTwoLinesAndCutsTheLast(label, tag)
            XCTAssertTrue(label.stringValue.hasPrefix("Claudia's note (unverified): "), "\(tag): \(label.stringValue)")
            XCTAssertTrue(label.stringValue.contains("Run the whole migration suite"), tag)
            XCTAssertFalse(label.isHiddenOrHasHiddenAncestor, tag)
            XCTAssertTrue(row.bounds.insetBy(dx: -0.5, dy: -0.5).contains(label.frame), "\(tag): \(label.frame) in \(row.bounds)")
        }
    }

    func testALongNoteDrawsTwoLinesInItsOwnFrameAtTwoHundredPointsAndIsCutThereNotAtThree() throws {
        let lineHeight = NSLayoutManager().defaultLineHeight(for: Theme.statusFont)
        let (_, row, label) = try noteRow(width: 200, note: veryLongNote)

        // What the label's own cell draws: two lines of ink ("Claudia's note", then "(unverified): ..." cut off).
        let ink = try inkBands(of: label)
        XCTAssertEqual(ink.bands.count, 2, "the note's label draws two lines at 200 pt: \(ink.bands)")

        // The label has room for exactly those two lines, and the row for the label.
        XCTAssertGreaterThanOrEqual(label.frame.height, 2 * lineHeight - 0.5, "room for two lines: \(label.frame)")
        XCTAssertLessThan(label.frame.height, 3 * lineHeight - 0.5, "never room for a third: \(label.frame)")
        XCTAssertTrue(row.bounds.insetBy(dx: -0.5, dy: -0.5).contains(label.frame), "\(label.frame) in \(row.bounds)")
        // Its own cell needs more than that for the whole note: it is cut, not squeezed.
        XCTAssertGreaterThan(ownCellNeed(of: label), 3 * lineHeight, "the label's own cell wraps the whole note onto more than three lines at 200 pt")
    }

    func testALongNoteAtFourHundredPointsAlsoDrawsTwoLinesAndAShortNoteDrawsOne() throws {
        let lineHeight = NSLayoutManager().defaultLineHeight(for: Theme.statusFont)

        let long = try noteRow(width: 400, note: veryLongNote).label
        let longInk = try inkBands(of: long)
        let first = try XCTUnwrap(longInk.bands.first, "the long note draws something")
        let last = try XCTUnwrap(longInk.bands.last)
        let extent = CGFloat(last.upperBound - first.lowerBound) * longInk.pointsPerPixelRow
        XCTAssertGreaterThan(extent, lineHeight * 1.4, "the ink of a long note spans two lines, not one: \(extent) pt, bands \(longInk.bands)")
        XCTAssertLessThanOrEqual(longInk.bands.count, 2, "never a third line: \(longInk.bands)")
        XCTAssertLessThan(long.frame.height, 3 * lineHeight - 0.5)

        let short = try noteRow(width: 400, note: "check the path first").label
        let shortInk = try inkBands(of: short)
        XCTAssertEqual(shortInk.bands.count, 1, "a note that fits is one line: \(shortInk.bands)")
        XCTAssertLessThan(short.frame.height, 2 * lineHeight - 0.5, "and takes no room for a second")
    }

    // MARK: - "Show all" and the command's drawn lines

    /// What the real command label draws (its own cell, no line limit) in points, for `text` at `width`.
    private func drawnHeight(of label: NSTextField, showing text: NSAttributedString, width: CGFloat) -> CGFloat {
        let savedText = label.attributedStringValue
        let savedLines = label.maximumNumberOfLines
        defer {
            label.attributedStringValue = savedText
            label.maximumNumberOfLines = savedLines
        }
        label.attributedStringValue = text
        label.maximumNumberOfLines = 0
        return ceil(label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000)).height)
    }

    private struct DrawnCommand {
        let length: Int
        let lines: Int
        let frameHeight: CGFloat
        let fitsAllLines: Bool
        let fitsExactlyThree: Bool
        let showAllVisible: Bool
        let showAllTitle: String?
    }

    /// Lays `command` out in a 280 pt drawer and reports what the row did against what its cell draws.
    private func drawn(_ command: String, host: StagingDrawerHost, rig: StagingRig) throws -> DrawnCommand {
        rig.ingest([StagingFixtures.entry("s-1", 1, command)])
        host.relayout()
        let row = try XCTUnwrap(host.rows.first)
        row.needsLayout = true
        row.layoutSubtreeIfNeeded()
        let label = try XCTUnwrap(host.commandLabel(of: row))
        let width = label.frame.width

        let one = drawnHeight(of: label, showing: StagingRowView.commandText("X", dimmed: false), width: width)
        let two = drawnHeight(of: label, showing: StagingRowView.commandText("X\nX", dimmed: false), width: width)
        let perLine = two - one
        XCTAssertGreaterThan(perLine, 5, "harness: a line is more than 5 pt high in the label's own cell")
        let all = drawnHeight(of: label, showing: label.attributedStringValue, width: width)
        let lines = 1 + Int(((all - one) / perLine).rounded())
        let threeLines = one + 2 * perLine
        let fourLines = one + 3 * perLine

        let showAll = host.showAll(of: row)
        return DrawnCommand(length: command.count, lines: lines, frameHeight: label.frame.height,
                            fitsAllLines: label.frame.height >= all - 0.5,
                            fitsExactlyThree: label.frame.height >= threeLines - 0.5 && label.frame.height < fourLines - 0.5,
                            showAllVisible: showAll?.isHidden == false, showAllTitle: showAll?.title)
    }

    private var commandShapes: [(name: String, make: (Int) -> String)] {
        let alphabet = Array("a1b2c3d4e5f6g7h8i9j0")
        let words = Array("echo word  ls -la /tmp/x ")
        return [("no spaces", { n in String((0..<n).map { alphabet[$0 % alphabet.count] }) }),
                ("with spaces", { n in String((0..<n).map { words[$0 % words.count] }) })]
    }

    private var commandLengths: [Int] { Array(1...200) + Array(stride(from: 207, through: 400, by: 7)) }

    func testTheLastLineOfACommandIsNeverCutAndShowAllAppearsExactlyWhenMoreThanThreeLinesAreDrawn() throws {
        for shape in commandShapes {
            let rig = makeRig()
            let host = makeHost(rig, width: 280, bodyHeight: 1_000)
            rig.ingest(StagingFixtures.entries(["x"]))
            var results: [DrawnCommand] = []
            for length in commandLengths {
                let result = try drawn(shape.make(length), host: host, rig: rig)
                results.append(result)
                let tag = "\(shape.name), \(length) characters, \(result.lines) lines"

                if result.lines > StagingRowView.collapsedLines {
                    XCTAssertTrue(result.showAllVisible, "\(tag): more than three lines are drawn, so Show all must be offered")
                    XCTAssertEqual(result.showAllTitle, "Show all", tag)
                    XCTAssertTrue(result.fitsExactlyThree, "\(tag): collapsed, the label is exactly three lines high (frame \(result.frameHeight))")
                } else {
                    XCTAssertFalse(result.showAllVisible, "\(tag): it all fits in three lines, so there is nothing to show")
                    XCTAssertTrue(result.fitsAllLines, "\(tag): the label is too short for what its cell draws, so the last line is cut (frame \(result.frameHeight))")
                }
            }
            XCTAssertTrue(results.contains { $0.lines == 1 }, "\(shape.name): harness covers one line")
            XCTAssertTrue(results.contains { $0.lines > 6 }, "\(shape.name): harness covers many lines")
            XCTAssertEqual(results.map { $0.lines }, results.map { $0.lines }.sorted(), "\(shape.name): a longer command never draws fewer lines")
        }
    }

    func testTheLongestCommandThatDrawsThreeLinesHasNoShowAllAndTheNextOneDoes() throws {
        for shape in commandShapes {
            let rig = makeRig()
            let host = makeHost(rig, width: 280, bodyHeight: 1_000)
            rig.ingest(StagingFixtures.entries(["x"]))

            // Find the boundary by measuring: the first length that draws a fourth line.
            var firstWithFourLines: Int?
            for length in 1...400 {
                let result = try drawn(shape.make(length), host: host, rig: rig)
                if result.lines > 3 { firstWithFourLines = length; break }
            }
            let boundary = try XCTUnwrap(firstWithFourLines, "\(shape.name): some length draws four lines")
            XCTAssertGreaterThan(boundary, 3, shape.name)

            let three = try drawn(shape.make(boundary - 1), host: host, rig: rig)
            XCTAssertEqual(three.lines, 3, "\(shape.name): \(boundary - 1) characters draw exactly three lines")
            XCTAssertFalse(three.showAllVisible, "\(shape.name): three lines, no Show all")
            XCTAssertTrue(three.fitsAllLines, "\(shape.name): the label holds all three lines (frame \(three.frameHeight))")

            let four = try drawn(shape.make(boundary), host: host, rig: rig)
            XCTAssertEqual(four.lines, 4, "\(shape.name): \(boundary) characters draw four lines")
            XCTAssertTrue(four.showAllVisible, "\(shape.name): the fourth line exists, so Show all is offered")
            XCTAssertTrue(four.fitsExactlyThree, "\(shape.name): collapsed to exactly three lines")
        }
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
