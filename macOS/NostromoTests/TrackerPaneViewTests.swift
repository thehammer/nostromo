import XCTest
import AppKit
import Combine
import NostromoKit

// The tracker pane (T1): what it shows for the 60-item golden board, that an update touches only
// the rows that changed, that a selection survives other updates, that Copy as Markdown puts the
// file's own text on the pasteboard, what each filter shows, the daemon-disconnect and two-window
// halves of PRD 23 and 25, focus, the "no new key equivalents" rule (contract 1.5) and the split
// divider's persistence (PRD 14).
//
// Everything is injected: `now` (no wall clock), the pasteboard (a private named one), the
// highlight scheduler (a manual one), the time zone (UTC), and the store (a ticking clock, so each
// ingest is delivered at once, or a manual clock and scheduler to exercise coalescing). Boards are
// the golden frame `tests/fixtures/tracker/frame-tracker-board.json`, decoded through
// `NostromodClient.decode` (the app's own decoder) after in-memory edits; the fixture files are
// shared with the Rust and Kit tests and are never changed.

// MARK: - Shared support (also used by AppControlTrackerTests and TrackerAppearanceTests)

/// A clock the test moves by hand.
final class TrackerManualClock {
    var date: Date
    init(_ date: Date) { self.date = date }
    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}

/// A clock that moves one second every time it is read, so a store using it always sees
/// "more than 100 ms since the last delivery" and delivers every ingest at once.
final class TrackerTickingClock {
    private var date = Date(timeIntervalSince1970: 1_000_000)
    func next() -> Date {
        date = date.addingTimeInterval(1)
        return date
    }
}

/// Collects `schedule(delay, work)` calls and runs them on `flush()`.
final class TrackerManualScheduler {
    private(set) var scheduled: [(delay: TimeInterval, work: () -> Void)] = []
    func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) { scheduled.append((delay, work)) }
    var delays: [TimeInterval] { scheduled.map(\.delay) }
    func flush() {
        while !scheduled.isEmpty {
            let batch = scheduled
            scheduled = []
            batch.forEach { $0.work() }
        }
    }
}

struct TrackerFixtureError: Error, CustomStringConvertible {
    let description: String
}

/// The golden `tracker_board` frame as editable JSON, decoded the way the app decodes it.
struct TrackerBoardScript {
    typealias Obj = [String: Any]

    private(set) var frame: Obj

    init(tag: String, file: StaticString = #filePath) throws {
        var f = try TrackerPaneFx.goldenFrame(file: file)
        f["tag"] = tag
        frame = f
    }

    private var board: Obj {
        get { frame["board"] as? Obj ?? [:] }
        set { frame["board"] = newValue }
    }

    private var nodes: [Obj] {
        get { board["nodes"] as? [Obj] ?? [] }
        set { board["nodes"] = newValue }
    }

    var tag: String { frame["tag"] as? String ?? "" }

    // MARK: Decoding

    /// The frame as the Mac client decodes it: what `AppStore` hands to `TrackerStore.ingest`.
    func message() throws -> ServerMsg {
        try TrackerPaneFx.message(frame)
    }

    func decodedBoard() throws -> TrackerBoardViewWire {
        guard case .trackerBoard(let decoded) = try message(), let view = decoded.board else {
            throw TrackerFixtureError(description: "frame did not decode to a board")
        }
        return view
    }

    // MARK: Reading the JSON (an independent source of expected values)

    var itemNodes: [Obj] { nodes.filter { ($0["type"] as? String) == "item" } }
    var sectionNodes: [Obj] { nodes.filter { ($0["type"] as? String) == "section" } }

    func itemIDs(status: String? = nil, notStatus: String? = nil, section: String? = nil) -> [String] {
        itemNodes.filter { node in
            if let status, (node["status"] as? String) != status { return false }
            if let notStatus, (node["status"] as? String) == notStatus { return false }
            if let section, (node["section"] as? String) != section { return false }
            return true
        }.compactMap { $0["id"] as? String }
    }

    func item(_ id: String) -> Obj? { itemNodes.first { ($0["id"] as? String) == id } }
    func status(_ id: String) -> String? { item(id)?["status"] as? String }
    func owner(_ id: String) -> String? { item(id)?["owner"] as? String }

    func text(_ id: String) -> String? {
        ((item(id)?["text_spans"] as? [Obj])?.first?["text"]) as? String
    }

    /// Items per section id, counting every status (what the section row's count shows under All).
    func itemCount(inSection id: String) -> Int { itemIDs(section: id).count }

    // MARK: Editing

    private func index(ofItem id: String) throws -> Int {
        guard let i = nodes.firstIndex(where: { ($0["type"] as? String) == "item" && ($0["id"] as? String) == id }) else {
            throw TrackerFixtureError(description: "no item \(id) in the golden board")
        }
        return i
    }

    mutating func updateItem(_ id: String, _ change: (inout Obj) -> Void) throws {
        var all = nodes
        let i = try index(ofItem: id)
        change(&all[i])
        nodes = all
    }

    mutating func setStatus(_ id: String, _ status: String) throws {
        try updateItem(id) { $0["status"] = status }
    }

    mutating func setText(_ id: String, _ text: String) throws {
        let spans: [Obj] = [["kind": "text", "text": text]]
        try updateItem(id) { $0["text_spans"] = spans }
    }

    mutating func setOwner(_ id: String, _ owner: String) throws {
        try updateItem(id) { $0["owner"] = owner }
    }

    mutating func removeItem(_ id: String) throws {
        var all = nodes
        all.remove(at: try index(ofItem: id))
        nodes = all
    }

    mutating func moveItem(_ id: String, toSection section: String) throws {
        var all = nodes
        var node = all.remove(at: try index(ofItem: id))
        node["section"] = section
        guard let heading = all.firstIndex(where: { ($0["type"] as? String) == "section" && ($0["id"] as? String) == section }) else {
            throw TrackerFixtureError(description: "no section \(section) in the golden board")
        }
        all.insert(node, at: heading + 1)
        nodes = all
    }

    mutating func insertItem(id: String, section: String, status: String = "todo", text: String = "A new item") throws {
        let spans: [Obj] = [["kind": "text", "text": text]]
        let none: [Obj] = []
        let item: Obj = ["type": "item", "id": id, "section": section, "text_spans": spans, "status": status,
                         "updated_at": TrackerPaneFx.iso(1_760_547_800), "note_blocks": none, "links": none,
                         "kind": "item", "ran": false, "source": "- [ ] \(text)\n"]
        var all = nodes
        guard let heading = all.firstIndex(where: { ($0["type"] as? String) == "section" && ($0["id"] as? String) == section }) else {
            throw TrackerFixtureError(description: "no section \(section) in the golden board")
        }
        all.insert(item, at: heading + 1)
        nodes = all
    }

    /// One paragraph per entry.
    mutating func setNote(_ id: String, paragraphs: [String]) throws {
        let blocks: [Obj] = paragraphs.map { ["kind": "paragraph", "spans": [["kind": "text", "text": $0]]] }
        try updateItem(id) { $0["note_blocks"] = blocks }
    }

    /// A prose node just before the Log heading.
    mutating func appendProse(key: String, blocks: [Obj], source: String = "") throws {
        var all = nodes
        let node: Obj = ["type": "prose", "key": key, "blocks": blocks, "source": source]
        guard let log = all.firstIndex(where: { ($0["type"] as? String) == "log_heading" }) else {
            throw TrackerFixtureError(description: "the golden board has no Log heading")
        }
        all.insert(node, at: log)
        nodes = all
    }

    mutating func setBanner(_ banner: Obj?) {
        if let banner { board["banner"] = banner } else { board.removeValue(forKey: "banner") }
    }

    mutating func setCommittable(remote: String?) {
        var committable: Obj = [:]
        if let remote { committable["remote"] = remote }
        board["committable"] = committable
    }

    mutating func setVersion(_ version: Int) {
        board["version"] = version
    }

    mutating func setBoardUpdatedAt(epoch: TimeInterval) {
        board["updated_at"] = TrackerPaneFx.iso(epoch)
    }
}

/// One pane in its own window, with the injected collaborators the tests drive.
struct TrackerPaneRig {
    let window: NSWindow
    let host: RigFlippedDoc
    let pane: TrackerPaneView
    let store: TrackerStore
    let tag: String
    /// The pane's `now`.
    let clock: TrackerManualClock
    /// What the pane's highlight scheduler was asked to run.
    let scheduler: TrackerManualScheduler
    let pasteboard: NSPasteboard
    /// An editable field below the pane, to hold keyboard focus.
    let composer: NSTextField

    func push(_ script: TrackerBoardScript, file: StaticString = #filePath, line: UInt = #line) {
        do {
            store.ingest(try script.message())
        } catch {
            XCTFail("could not decode the board: \(error)", file: file, line: line)
        }
        settle()
    }

    func settle() {
        host.layoutSubtreeIfNeeded()
        pane.layoutSubtreeIfNeeded()
    }

    /// A user scroll: what a trackpad does to the clip view.
    func scroll(to y: CGFloat) {
        pane.clipView.scroll(to: NSPoint(x: 0, y: y))
        pane.scrollView.reflectScrolledClipView(pane.clipView)
        settle()
    }

    func rowView(_ key: String, file: StaticString = #filePath, line: UInt = #line) -> TrackerRowView? {
        let view = pane.rowViews[key]
        if view == nil { XCTFail("no row view \(key); rows: \(pane.displayedRows.map(\.key))", file: file, line: line) }
        return view
    }

    var rowFrames: [String: CGRect] {
        Dictionary(uniqueKeysWithValues: pane.rowViews.map { ($0.key, $0.value.frame) })
    }
}

enum TrackerPaneFx {
    typealias Obj = [String: Any]

    /// 2025-10-15 17:06:40 UTC: four minutes after the golden board's newest item, so the board
    /// reads "updated 4 m ago" and its items read from "4 m" to "2 h".
    static let now = Date(timeIntervalSince1970: 1_760_548_000)
    static let utc = TimeZone(identifier: "UTC")!

    static let client = NostromodClient(socketPath: "/dev/null")

    static let hostPadding: CGFloat = 34

    // MARK: Fixtures

    /// `<repo>/tests/fixtures/tracker/<name>`: the test files are three directories below the root.
    static func fixtureData(_ name: String, file: StaticString = #filePath) throws -> Data {
        try Data(contentsOf: repoRoot(file: file).appendingPathComponent("tests/fixtures/tracker/\(name)"))
    }

    static func fixtureText(_ name: String, file: StaticString = #filePath) throws -> String {
        String(decoding: try fixtureData(name, file: file), as: UTF8.self)
    }

    static func repoRoot(file: StaticString = #filePath) -> URL {
        var url = URL(fileURLWithPath: "\(file)")
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }

    static func goldenFrame(file: StaticString = #filePath) throws -> Obj {
        let data = try fixtureData("frame-tracker-board.json", file: file)
        guard let object = try JSONSerialization.jsonObject(with: data) as? Obj else {
            throw TrackerFixtureError(description: "golden frame is not a JSON object")
        }
        return object
    }

    static func message(_ frame: Obj) throws -> ServerMsg {
        let data = try JSONSerialization.data(withJSONObject: frame)
        let msg = client.decode(type_: (frame["type"] as? String) ?? "", json: frame, raw: data)
        switch msg {
        case .trackerBoard, .trackerSummary: return msg
        default: throw TrackerFixtureError(description: "frame did not decode to a tracker frame")
        }
    }

    static func nullBoardMessage(tag: String) throws -> ServerMsg {
        try message(["type": "tracker_board", "tag": tag, "board": NSNull()])
    }

    static func summaryMessage(tag: String, file: StaticString = #filePath) throws -> ServerMsg {
        guard var frame = try JSONSerialization.jsonObject(with: try fixtureData("frame-tracker-summary.json", file: file)) as? Obj else {
            throw TrackerFixtureError(description: "summary frame is not a JSON object")
        }
        frame["tag"] = tag
        return try message(frame)
    }

    static func iso(_ epoch: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date(timeIntervalSince1970: epoch))
    }

    static func uniqueTag() -> String { "kate-\(UUID().uuidString.prefix(8).lowercased())" }

    // MARK: The file's own text (sliced out of board-60.md, independent of the wire `source` fields)

    /// The heading line, the lines under it and the blank line that follows, up to the next `## `.
    static func fileSection(titled title: String, in markdown: String) -> String? {
        let lines = markdown.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: "## \(title)") else { return nil }
        let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("## ") } ?? lines.count
        return lines[start..<end].joined(separator: "\n") + "\n"
    }

    /// The item's task line, its indented block and the blank lines after it.
    static func fileItem(id: String, in markdown: String) -> String? {
        let lines = markdown.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains("<!-- #\(id) ") }) else { return nil }
        var end = start + 1
        while end < lines.count, lines[end].hasPrefix("  ") || (lines[end].isEmpty && end < lines.count - 1) { end += 1 }
        return lines[start..<end].joined(separator: "\n") + "\n"
    }

    // MARK: Stores

    /// Every ingest is delivered at once (the clock moves a second per read).
    static func makeImmediateStore() -> TrackerStore {
        let clock = TrackerTickingClock()
        return TrackerStore(now: { clock.next() }, schedule: { _, work in work() })
    }

    /// A store whose clock and scheduler the test drives, to exercise the 10 Hz coalescing.
    static func makeManualStore(start: Date = Date(timeIntervalSince1970: 2_000_000))
        -> (store: TrackerStore, clock: TrackerManualClock, scheduler: TrackerManualScheduler) {
        let clock = TrackerManualClock(start)
        let scheduler = TrackerManualScheduler()
        let store = TrackerStore(now: { clock.date }, schedule: { scheduler.schedule($0, $1) })
        return (store, clock, scheduler)
    }

    // MARK: Panes

    static func makeRig(_ testCase: XCTestCase,
                        tag: String = TrackerPaneFx.uniqueTag(),
                        store: TrackerStore? = nil,
                        window: NSWindow? = nil,
                        size: NSSize = NSSize(width: 360, height: 600),
                        reduceMotion: Bool = false) -> TrackerPaneRig {
        let store = store ?? makeImmediateStore()
        let clock = TrackerManualClock(now)
        let scheduler = TrackerManualScheduler()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TrackerTests-\(UUID().uuidString)"))
        testCase.addTeardownBlock { pasteboard.releaseGlobally() }

        let pane = TrackerPaneView(tag: tag, store: store, now: { clock.date }, reduceMotion: { reduceMotion },
                                   pasteboard: pasteboard, schedule: { scheduler.schedule($0, $1) },
                                   timeZone: utc, tickInterval: nil)
        let hostSize = NSSize(width: size.width, height: size.height + hostPadding)
        let window = window ?? makeRigWindow(testCase, size: hostSize)
        let host = RigFlippedDoc(frame: NSRect(origin: .zero, size: hostSize))
        pane.frame = NSRect(origin: .zero, size: size)
        let composer = NSTextField(string: "")
        composer.frame = NSRect(x: 0, y: size.height + 3, width: size.width, height: 28)
        host.addSubview(pane)
        host.addSubview(composer)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        pane.layoutSubtreeIfNeeded()
        return TrackerPaneRig(window: window, host: host, pane: pane, store: store, tag: tag, clock: clock,
                              scheduler: scheduler, pasteboard: pasteboard, composer: composer)
    }

    // MARK: Reading what a pane shows

    /// Every string any view under `root` shows.
    static func allTexts(in root: NSView) -> [String] {
        ([root] + rigAllSubviews(of: root)).flatMap { view -> [String] in
            var out: [String] = []
            if let field = view as? NSTextField { out.append(field.stringValue) }
            if let text = view as? NSTextView { out.append(text.string) }
            if let button = view as? NSButton { out.append(button.title) }
            if let tip = view.toolTip { out.append(tip) }
            return out
        }
    }

    static func itemKeys(_ pane: TrackerPaneView) -> [String] {
        pane.displayedRows.map(\.key).filter { $0.hasPrefix("item:") }
    }

    static func sectionKeys(_ pane: TrackerPaneView) -> [String] {
        pane.displayedRows.map(\.key).filter { $0.hasPrefix("section:") }
    }

    static let marks: [String: String] = ["todo": "○", "in-progress": "◐", "blocked": "⊘", "needs-you": "●", "done": "✓"]

    /// Invoke a menu item the way a click does, without a visible menu.
    @discardableResult
    static func invoke(_ item: NSMenuItem, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        guard let action = item.action else {
            XCTFail("menu item \(item.title) has no action", file: file, line: line)
            return false
        }
        let handled = NSApp.sendAction(action, to: item.target, from: item)
        XCTAssertTrue(handled, "nothing handled \(item.title)", file: file, line: line)
        return handled
    }
}

// MARK: - Tests

final class TrackerPaneViewTests: XCTestCase {

    private typealias Fx = TrackerPaneFx

    private func goldenRig(reduceMotion: Bool = false, file: StaticString = #filePath, line: UInt = #line)
        throws -> (rig: TrackerPaneRig, script: TrackerBoardScript) {
        let tag = Fx.uniqueTag()
        let rig = Fx.makeRig(self, tag: tag, reduceMotion: reduceMotion)
        let script = try TrackerBoardScript(tag: tag, file: file)
        rig.push(script, file: file, line: line)
        return (rig, script)
    }

    private func firstResponderChain(of window: NSWindow) -> [NSResponder] {
        var out: [NSResponder] = []
        var current = window.firstResponder
        while let responder = current {
            out.append(responder)
            current = responder.nextResponder
        }
        return out
    }

    // MARK: - PRD 12: the 60-item board

    func testTheGoldenBoardShowsSixSectionsEachWithItsTitleAndCount() throws {
        let (rig, script) = try goldenRig()
        let sections = script.sectionNodes
        XCTAssertEqual(sections.count, 6)
        XCTAssertEqual(Fx.sectionKeys(rig.pane), sections.compactMap { ($0["id"] as? String).map { "section:\($0)" } },
                       "six section rows, in file order")
        for node in sections {
            guard let id = node["id"] as? String, let title = node["title"] as? String else { continue }
            let text = rig.rowView("section:\(id)")?.visibleText ?? ""
            XCTAssertTrue(text.contains(title), "section row \(id) shows its title: \(text)")
            XCTAssertTrue(text.contains("\(script.itemCount(inSection: id))"),
                          "section row \(id) shows its item count \(script.itemCount(inSection: id)): \(text)")
        }
    }

    func testEveryOpenItemRowShowsItsStatusMarkTextOwnerAndRelativeTime() throws {
        let (rig, script) = try goldenRig()
        let open = script.itemIDs(notStatus: "done")
        XCTAssertEqual(open.count, 43)
        for id in open {
            let text = rig.rowView("item:\(id)")?.visibleText ?? ""
            let status = script.status(id) ?? ""
            XCTAssertTrue(text.contains(Fx.marks[status] ?? "?"), "\(id) (\(status)) shows its mark: \(text)")
            XCTAssertTrue(text.contains(script.text(id) ?? "?"), "\(id) shows its text: \(text)")
            if let owner = script.owner(id) {
                XCTAssertTrue(text.contains(owner), "\(id) shows its owner chip \(owner): \(text)")
            }
        }
        // Relative time: the newest item is 4 m old, the oldest in `now` is hours old.
        XCTAssertEqual(rig.rowView("item:audit-3183")?.timeLabel?.stringValue, "4 m")
        XCTAssertEqual(rig.rowView("item:check-1000")?.timeLabel?.stringValue, "2 h")
        XCTAssertEqual(rig.rowView("item:docum-1740")?.timeLabel?.stringValue, "1 h")
        for id in open {
            XCTAssertFalse(rig.rowView("item:\(id)")?.timeLabel?.stringValue.isEmpty ?? true, "\(id) shows a time")
        }
        // Owner chip and environment badge appear in the row.
        let hazardous = rig.rowView("item:retry-1074")?.visibleText ?? ""
        XCTAssertTrue(hazardous.contains("PROD"), hazardous)
        XCTAssertTrue(hazardous.contains("me"), hazardous)
    }

    func testNeedsYouItemsAreInTheStripAndInTheirSection() throws {
        let (rig, script) = try goldenRig()
        let needs = script.itemIDs(status: "needs-you")
        XCTAssertEqual(needs.count, 10)
        XCTAssertTrue(rig.pane.strip.text.contains("Waiting on you (10)"), rig.pane.strip.text)
        XCTAssertFalse(rig.pane.strip.isHidden)
        for id in needs {
            XCTAssertTrue(rig.pane.strip.text.contains(script.text(id) ?? "?"), "\(id) is in the strip")
            let view = rig.rowView("item:\(id)")
            XCTAssertTrue(view?.visibleText.contains("●") ?? false, "\(id) is also in its section, marked ●")
            XCTAssertEqual(view?.row.item?.sectionId, "waiting-on-you")
        }
    }

    func testDoneItemsAreFoldedIntoADoneGroupPerSection() throws {
        let (rig, script) = try goldenRig()
        let done = script.itemIDs(status: "done")
        XCTAssertEqual(done.count, 17)
        for id in done {
            XCTAssertNil(rig.pane.rowViews["item:\(id)"], "done item \(id) has no row of its own")
        }
        XCTAssertTrue(rig.rowView("done:done")?.visibleText.contains("Done (12)") ?? false, rig.pane.rowViews["done:done"]?.visibleText ?? "")
        XCTAssertTrue(rig.rowView("done:findings")?.visibleText.contains("Done (5)") ?? false, rig.pane.rowViews["done:findings"]?.visibleText ?? "")
        XCTAssertNil(rig.pane.rowViews["done:now"], "a section with nothing done has no Done group")
    }

    func testTheLogShowsTheNewestFiveLinesAndOpensToAllTwelve() throws {
        let (rig, _) = try goldenRig()
        let collapsed = rig.rowView("log")?.visibleText ?? ""
        for n in 8...12 { XCTAssertTrue(collapsed.contains(String(format: "event %02d", n)), collapsed) }
        XCTAssertFalse(collapsed.contains("event 07"), collapsed)
        let positions = (8...12).compactMap { collapsed.range(of: String(format: "event %02d", $0))?.lowerBound }
        XCTAssertEqual(positions, positions.sorted(by: >), "newest first")

        rig.pane.toggleLog()
        rig.settle()
        let expanded = rig.rowView("log")?.visibleText ?? ""
        for n in 1...12 { XCTAssertTrue(expanded.contains(String(format: "event %02d", n)), expanded) }
    }

    func testTheHeaderShowsTheTitleAndUpdatedTimeAndTheCommittableBadgeWhenThereIsOne() throws {
        let (rig, script) = try goldenRig()
        XCTAssertEqual(rig.pane.header.titleLabel.stringValue, "Synthetic release triage")
        XCTAssertEqual(rig.pane.header.updatedLabel.stringValue, "updated 4 m ago")
        func shownBadges() -> [String] {
            rigAllSubviews(of: rig.pane.header).compactMap { $0 as? NSTextField }
                .filter { !$0.isHiddenOrHasHiddenAncestor && $0.stringValue.contains("committed") }
                .map(\.stringValue)
        }
        XCTAssertEqual(shownBadges(), [], "a board that cannot be committed shows no badge")

        var committable = script
        committable.setCommittable(remote: "github.com/example/repo")
        rig.push(committable)
        XCTAssertEqual(shownBadges(), ["This file can be committed to github.com/example/repo"])
    }

    func testProseWithACodeBlockATableAndATaskListRendersAsSuch() throws {
        let (rig, script) = try goldenRig()
        func span(_ text: String) -> TrackerPaneFx.Obj { ["kind": "text", "text": text] }
        func paragraph(_ text: String) -> TrackerPaneFx.Obj { ["kind": "paragraph", "spans": [span(text)]] }
        let code: TrackerPaneFx.Obj = ["kind": "code_block", "lang": "swift", "text": "let answer = 42\nprint(answer)\n"]
        let table: TrackerPaneFx.Obj = [
            "kind": "table",
            "header": [[span("Fruit")], [span("Count")]],
            "rows": [[[span("apple")], [span("3")]], [[span("pear")], [span("12")]]],
        ]
        let tasks: TrackerPaneFx.Obj = ["kind": "list", "ordered": false,
                                        "items": [[paragraph("[ ] buy milk")], [paragraph("[x] done thing")]]]
        let blocks: [TrackerPaneFx.Obj] = [paragraph("Intro to the notes."), code, table, tasks]
        var edited = script
        try edited.appendProse(key: "redd-rich-prose-0", blocks: blocks)
        rig.push(edited)

        let prose = try XCTUnwrap(rig.rowView("prose:redd-rich-prose-0")?.proseView)
        let scrollers = prose.wideBlockScrollViews
        XCTAssertEqual(scrollers.count, 2, "the code block and the table each scroll on their own")

        // Fenced code: monospaced, inside its own horizontal scroller, exactly as written.
        let codeText = try XCTUnwrap(scrollers.compactMap { $0.documentView as? NSTextView }.first { $0.string.contains("let answer") })
        XCTAssertEqual(codeText.string, "let answer = 42\nprint(answer)")
        let font = try XCTUnwrap(codeText.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        // Monospaced by measurement (Fira Code Nerd Font does not report `isFixedPitch`): every
        // character advances the same width.
        let narrow = ("iiii" as NSString).size(withAttributes: [.font: font]).width
        let wide = ("MMMM" as NSString).size(withAttributes: [.font: font]).width
        XCTAssertEqual(narrow, wide, accuracy: 0.5, "code is monospaced, not \(font.fontName)")
        let codeScroller = try XCTUnwrap(scrollers.first { $0.documentView === codeText })
        XCTAssertTrue(codeScroller.hasHorizontalScroller)
        XCTAssertFalse(codeScroller.hasVerticalScroller)

        // Table: a grid with the cell texts, in the other scroller.
        let tableScroller = try XCTUnwrap(scrollers.first { $0 !== codeScroller })
        let grid = try XCTUnwrap(rigAllSubviews(of: try XCTUnwrap(tableScroller.documentView)).compactMap { $0 as? NSGridView }.first)
        var cells: [[String]] = []
        for r in 0..<grid.numberOfRows {
            cells.append((0..<grid.numberOfColumns).map { c in
                (grid.cell(atColumnIndex: c, rowIndex: r).contentView as? NSTextField)?.stringValue ?? "?"
            })
        }
        XCTAssertEqual(cells, [["Fruit", "Count"], ["apple", "3"], ["pear", "12"]])

        // Task list: ☐ / ☑ boxes, never the literal markers.
        let all = prose.plainText
        XCTAssertTrue(all.contains("☐ buy milk"), all)
        XCTAssertTrue(all.contains("☑ done thing"), all)
        XCTAssertFalse(all.contains("[ ]"), all)
        XCTAssertFalse(all.contains("[x]"), all)

        // The pane itself never scrolls sideways because of a wide block.
        XCTAssertFalse(rig.pane.scrollView.hasHorizontalScroller)
    }

    func testAFiveHundredCharacterItemWrapsAtTheWidthOfThePaneWithoutAHorizontalScroller() throws {
        let (rig, script) = try goldenRig()
        let long = String(String(repeating: "wrapword ", count: 60).prefix(500))
        XCTAssertEqual(long.count, 500)
        var edited = script
        try edited.setText("check-1000", long)
        rig.push(edited)

        let clipWidth = rig.pane.clipView.bounds.width
        XCTAssertGreaterThan(clipWidth, 100)
        let longView = try XCTUnwrap(rig.rowView("item:check-1000"))
        let shortView = try XCTUnwrap(rig.rowView("item:verif-1037"))
        let textView = try XCTUnwrap(longView.textViews.first)
        let oneLine = try XCTUnwrap(shortView.textViews.first).frame.height
        XCTAssertGreaterThan(oneLine, 0)
        XCTAssertGreaterThanOrEqual(textView.frame.height, oneLine * 4, "500 characters wrap to several lines")
        XCTAssertLessThanOrEqual(textView.frame.maxX, clipWidth + 0.5, "the text stays inside the pane's width")
        XCTAssertLessThanOrEqual(longView.frame.width, clipWidth + 0.5)
        XCTAssertFalse(rig.pane.scrollView.hasHorizontalScroller)
        XCTAssertEqual(rig.pane.documentView.frame.width, clipWidth, accuracy: 0.5, "the document is exactly as wide as the viewport")
    }

    func testCollapsedNoteShowsFirstLineAndOpensToTheRest() throws {
        let (rig, script) = try goldenRig()
        var edited = script
        try edited.setNote("verif-1037", paragraphs: ["First line of the note", "Second line", "Third line"])
        rig.push(edited)
        let collapsed = rig.rowView("item:verif-1037")?.visibleText ?? ""
        XCTAssertTrue(collapsed.contains("First line of the note"), collapsed)
        XCTAssertFalse(collapsed.contains("Third line"), collapsed)

        rig.pane.toggleNote(item: "verif-1037")
        rig.settle()
        let expanded = rig.rowView("item:verif-1037")?.visibleText ?? ""
        XCTAssertTrue(expanded.contains("Third line"), expanded)
    }

    // MARK: - Before any board

    func testBeforeAnyBoardThePaneShowsAQuietWaitingLineAndNoRows() {
        let rig = Fx.makeRig(self)
        XCTAssertEqual(rig.pane.placeholder.stringValue, "Waiting for the tracker…")
        XCTAssertTrue(rig.pane.placeholder.superview === rig.pane)
        XCTAssertFalse(rig.pane.placeholder.isHidden)
        XCTAssertTrue(rig.pane.rowViews.isEmpty)
        XCTAssertTrue(rig.pane.documentView.subviews.isEmpty)
        XCTAssertTrue(rig.pane.displayedRows.isEmpty)
        XCTAssertNil(rig.pane.board)
        XCTAssertFalse(Fx.allTexts(in: rig.pane).contains { $0.localizedCaseInsensitiveContains("loading") }, "no Loading before the first board")
    }

    func testTheFirstBoardRemovesThePlaceholderAndItNeverComesBack() throws {
        let tag = Fx.uniqueTag()
        let rig = Fx.makeRig(self, tag: tag)
        var script = try TrackerBoardScript(tag: tag)
        rig.push(script)
        XCTAssertNil(rig.pane.placeholder.superview, "the first board replaces the placeholder")
        XCTAssertFalse(rig.pane.rowViews.isEmpty)

        try script.setStatus("verif-1037", "blocked")
        rig.push(script)
        XCTAssertNil(rig.pane.placeholder.superview, "a later board does not bring it back")

        rig.store.daemonDisconnected()
        rig.pane.render()
        XCTAssertNil(rig.pane.placeholder.superview, "a lost connection does not bring it back")

        rig.pane.setFilter(.waiting)
        rig.pane.setFilter(.all)
        XCTAssertNil(rig.pane.placeholder.superview)
    }

    func testNoViewInThePaneEverShowsLoading() throws {
        let tag = Fx.uniqueTag()
        let rig = Fx.makeRig(self, tag: tag)
        var script = try TrackerBoardScript(tag: tag)
        func assertNoLoading(_ when: String, line: UInt = #line) {
            let loading = Fx.allTexts(in: rig.pane).filter { $0.localizedCaseInsensitiveContains("loading") }
            XCTAssertEqual(loading, [], "\(when): nothing says Loading", line: line)
        }
        assertNoLoading("before the first board")
        rig.push(script)
        assertNoLoading("with a board")
        try script.setStatus("verif-1037", "done")
        rig.push(script)
        assertNoLoading("after an update")
        rig.store.daemonDisconnected()
        assertNoLoading("after the daemon disconnected")
        script.setBanner(["type": "missing", "last_seen": Fx.iso(1_760_547_000)])
        rig.push(script)
        assertNoLoading("with a missing-file banner")
    }

    // MARK: - PRD 20: an update touches only what changed

    func testPushingAnIdenticalBoardTwiceChangesNothing() throws {
        let (rig, script) = try goldenRig()
        let generation = rig.pane.renderGeneration
        let views = rig.pane.rowViews

        rig.push(script)
        rig.push(script)
        XCTAssertLessThanOrEqual(rig.pane.renderGeneration - generation, 1, "an identical board renders at most once")
        XCTAssertEqual(rig.pane.rowsUpdatedLast, 0, "and updates no row")
        XCTAssertEqual(Set(rig.pane.rowViews.keys), Set(views.keys))
        for (key, view) in views { XCTAssertTrue(rig.pane.rowViews[key] === view, "\(key) is the same view") }
    }

    func testANewVersionWithTheSameContentUpdatesNoRow() throws {
        let (rig, script) = try goldenRig()
        let before = rig.pane.renderGeneration
        var bumped = script
        bumped.setVersion(8)
        rig.push(bumped)
        XCTAssertEqual(rig.pane.rowsUpdatedLast, 0, "only the version changed: no row has anything new to show")
        XCTAssertLessThanOrEqual(rig.pane.renderGeneration - before, 1)
    }

    func testRenderingAgainWithoutAChangeUpdatesNoRow() throws {
        let (rig, _) = try goldenRig()
        let before = rig.pane.renderGeneration
        rig.pane.render()
        rig.pane.render()
        XCTAssertEqual(rig.pane.rowsUpdatedLast, 0)
        XCTAssertLessThanOrEqual(rig.pane.renderGeneration - before, 1)
    }

    func testAOneItemStatusChangeUpdatesOnlyThatRow() throws {
        let (rig, script) = try goldenRig()
        let before = rig.pane.rowViews
        let generation = rig.pane.renderGeneration

        var edited = script
        try edited.setStatus("verif-1037", "blocked")
        rig.push(edited)

        XCTAssertEqual(rig.pane.renderGeneration, generation + 1)
        XCTAssertGreaterThanOrEqual(rig.pane.rowsUpdatedLast, 1)
        XCTAssertLessThanOrEqual(rig.pane.rowsUpdatedLast, 2, "a status change is one row, not a repaint of the board")
        XCTAssertTrue(rig.rowView("item:verif-1037")?.visibleText.contains("⊘") ?? false, "the row shows its new mark")
        XCTAssertEqual(Set(rig.pane.rowViews.keys), Set(before.keys), "no row came or went")
        for (key, view) in before { XCTAssertTrue(rig.pane.rowViews[key] === view, "\(key) is the same view instance") }
    }

    func testAddingAnItemBuildsOneRowAndLeavesTheOthersAlone() throws {
        let (rig, script) = try goldenRig()
        let before = rig.pane.rowViews
        var edited = script
        try edited.insertItem(id: "fresh-0001", section: "next", text: "A brand new item")
        rig.push(edited)

        XCTAssertNotNil(rig.pane.rowViews["item:fresh-0001"])
        XCTAssertEqual(rig.pane.rowViews.count, before.count + 1)
        XCTAssertLessThanOrEqual(rig.pane.rowsUpdatedLast, 3, "the new row plus at most a count that moved")
        for (key, view) in before { XCTAssertTrue(rig.pane.rowViews[key] === view, "\(key) is the same view instance") }
    }

    func testChangingAnItemFoldedAwayInADoneGroupTouchesNoRow() throws {
        let (rig, script) = try goldenRig()
        let before = rig.pane.rowViews
        var edited = script
        try edited.setText("repro-2110", "Reproduce user avatar sync (reworded)")
        rig.push(edited)
        XCTAssertEqual(rig.pane.rowsUpdatedLast, 0, "nothing on screen shows that item")
        for (key, view) in before { XCTAssertTrue(rig.pane.rowViews[key] === view) }
    }

    // MARK: - Highlight (at most one second, none with Reduce Motion)

    func testAChangedRowIsHighlightedAtOnceAndNotAfterTheScheduledWorkRuns() throws {
        let (rig, script) = try goldenRig()
        XCTAssertTrue(rig.pane.rowViews.values.allSatisfy { !$0.isHighlighted }, "the first board highlights nothing")

        var edited = script
        try edited.setStatus("verif-1037", "blocked")
        rig.push(edited)

        let changed = try XCTUnwrap(rig.rowView("item:verif-1037"))
        XCTAssertTrue(changed.isHighlighted)
        XCTAssertEqual(rig.pane.rowViews.values.filter(\.isHighlighted).count, 1, "only the changed row")
        XCTAssertFalse(rig.scheduler.delays.isEmpty, "the end of the highlight is scheduled")
        XCTAssertTrue(rig.scheduler.delays.allSatisfy { $0 <= 1.0 }, "the highlight lasts at most a second: \(rig.scheduler.delays)")

        rig.scheduler.flush()
        XCTAssertFalse(changed.isHighlighted)
        XCTAssertTrue(rig.pane.rowViews.values.allSatisfy { !$0.isHighlighted })
    }

    func testWithReduceMotionNothingIsEverHighlighted() throws {
        let (rig, script) = try goldenRig(reduceMotion: true)
        var edited = script
        try edited.setStatus("verif-1037", "blocked")
        rig.push(edited)
        XCTAssertGreaterThanOrEqual(rig.pane.rowsUpdatedLast, 1, "the change itself was applied")
        XCTAssertTrue(rig.pane.rowViews.values.allSatisfy { !$0.isHighlighted })
        rig.scheduler.flush()
        XCTAssertTrue(rig.pane.rowViews.values.allSatisfy { !$0.isHighlighted })
    }

    func testAClockTickChangesTimeLabelsInPlaceWithoutHighlightOrMovingAnyRow() throws {
        let (rig, _) = try goldenRig()
        let views = rig.pane.rowViews
        let frames = rig.rowFrames
        let before = Dictionary(uniqueKeysWithValues: views.compactMap { key, view in view.timeLabel.map { (key, $0.stringValue) } })
        XCTAssertEqual(before["item:audit-3183"], "4 m")

        rig.clock.advance(600)
        rig.pane.tick()
        rig.settle()

        XCTAssertEqual(rig.rowView("item:audit-3183")?.timeLabel?.stringValue, "14 m")
        XCTAssertEqual(rig.pane.header.updatedLabel.stringValue, "updated 14 m ago")
        let after = Dictionary(uniqueKeysWithValues: rig.pane.rowViews.compactMap { key, view in view.timeLabel.map { (key, $0.stringValue) } })
        XCTAssertNotEqual(after, before, "the labels moved on")
        XCTAssertTrue(rig.pane.rowViews.values.allSatisfy { !$0.isHighlighted }, "a tick is not a change")
        XCTAssertTrue(rig.scheduler.scheduled.isEmpty, "a tick schedules no highlight")
        XCTAssertEqual(rig.rowFrames, frames, "no row moved or resized")
        for (key, view) in views { XCTAssertTrue(rig.pane.rowViews[key] === view, "\(key) was updated in place") }
    }

    // MARK: - PRD 21: a selection survives other updates

    func testASelectionSurvivesTenUpdatesToOtherItems() throws {
        let (rig, script) = try goldenRig()
        let key = "item:revie-1111"
        let row = try XCTUnwrap(rig.rowView(key))
        let textView = try XCTUnwrap(row.textViews.first)
        let original = textView.string
        XCTAssertTrue(rig.window.makeFirstResponder(textView))
        let range = NSRange(location: 0, length: 6)
        textView.setSelectedRange(range)
        rigSettle(0.02)
        XCTAssertEqual(textView.selectedRange(), range)

        var edited = script
        let others = Array(script.itemIDs(section: "next").prefix(10))
        XCTAssertEqual(others.count, 10)
        for (i, id) in others.enumerated() {
            try edited.setText(id, "\(script.text(id) ?? "") (edit \(i))")
            rig.push(edited)
        }

        XCTAssertTrue(rig.rowView(key) === row, "the selected row is the same view")
        XCTAssertTrue(row.textViews.first === textView, "and the same text view")
        XCTAssertEqual(textView.string, original)
        XCTAssertEqual(textView.selectedRange(), range, "the selection did not move")
        for (i, id) in others.enumerated() {
            XCTAssertTrue(rig.rowView("item:\(id)")?.visibleText.contains("(edit \(i))") ?? false, "update \(i) to \(id) was applied")
        }
    }

    func testAnUpdateToTheSelectedItemWaitsForTheSelectionToClear() throws {
        let (rig, script) = try goldenRig()
        let key = "item:revie-1111"
        let textView = try XCTUnwrap(rig.rowView(key)?.textViews.first)
        let original = textView.string
        XCTAssertTrue(rig.window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: 0, length: 6))
        rigSettle(0.02)

        var edited = script
        try edited.setText("revie-1111", "Review queue job 8812 (revised)")
        rig.push(edited)

        XCTAssertEqual(rig.rowView(key)?.textViews.first?.string, original, "not applied while the text is selected")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 6))
        XCTAssertTrue(rig.pane.deferral.held.contains { $0.key == key && $0.kind == .selection })

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        rigSettle(0.02)
        rig.settle()
        XCTAssertTrue(rig.rowView(key)?.visibleText.contains("(revised)") ?? false, "applied right after the selection cleared: \(rig.rowView(key)?.visibleText ?? "")")
        XCTAssertTrue(rig.pane.deferral.held.isEmpty)
    }

    // MARK: - PRD 15: Copy as Markdown and the filters

    private func pasted(_ rig: TrackerPaneRig) -> String? {
        rig.pasteboard.string(forType: .string)
    }

    func testCopyAsMarkdownFromTheHeaderPutsTheFilesExactBytesOnThePasteboard() throws {
        let (rig, _) = try goldenRig()
        let expected = try Fx.fixtureText("board-60.md")
        rig.pasteboard.clearContents()
        Fx.invoke(rig.pane.header.copyMenuItem())
        XCTAssertEqual(pasted(rig), expected)
        XCTAssertEqual(Data((pasted(rig) ?? "").utf8), try Fx.fixtureData("board-60.md"), "byte for byte")
    }

    func testCopyAsMarkdownFromASectionPutsThatSectionsFileTextOnThePasteboard() throws {
        let (rig, _) = try goldenRig()
        let markdown = try Fx.fixtureText("board-60.md")
        for (id, title) in [("now", "Now"), ("done", "Done"), ("loose-ends", "Loose ends")] {
            let expected = try XCTUnwrap(Fx.fileSection(titled: title, in: markdown))
            let items = try XCTUnwrap(rig.rowView("section:\(id)")).copyMenuItems()
            XCTAssertEqual(items.count, 1, "\(title) offers Copy as Markdown")
            rig.pasteboard.clearContents()
            if let item = items.first { Fx.invoke(item) }
            XCTAssertEqual(pasted(rig), expected, "section \(title)")
        }
    }

    func testCopyAsMarkdownFromAnItemPutsThatItemsFileTextOnThePasteboard() throws {
        let (rig, _) = try goldenRig()
        let markdown = try Fx.fixtureText("board-60.md")
        // With a note and a link; with a fenced block; the last in its section (the blank line after it is its own).
        for id in ["check-1000", "retry-1074", "backf-1333"] {
            let expected = try XCTUnwrap(Fx.fileItem(id: id, in: markdown))
            let items = try XCTUnwrap(rig.rowView("item:\(id)")).copyMenuItems()
            XCTAssertEqual(items.count, 1)
            rig.pasteboard.clearContents()
            if let item = items.first { Fx.invoke(item) }
            XCTAssertEqual(pasted(rig), expected, "item \(id)")
        }
    }

    func testRowsThatAreNeitherAnItemNorASectionOfferNoCopy() throws {
        let (rig, _) = try goldenRig()
        XCTAssertTrue(try XCTUnwrap(rig.rowView("done:done")).copyMenuItems().isEmpty)
        XCTAssertTrue(try XCTUnwrap(rig.rowView("log")).copyMenuItems().isEmpty)
    }

    private func assertFilter(_ filter: TrackerFilter, shows expected: Set<String>, script: TrackerBoardScript,
                              rig: TrackerPaneRig, line: UInt = #line) {
        let itemRows = Set(Fx.itemKeys(rig.pane).map { String($0.dropFirst("item:".count)) })
        XCTAssertEqual(itemRows, expected, "filter \(filter)", line: line)
        XCTAssertEqual(rig.pane.filter, filter, line: line)
        XCTAssertEqual(rig.pane.header.filterControl.selectedSegment, TrackerFilter.allCases.firstIndex(of: filter), line: line)
    }

    func testEachFilterShowsTheRightRowsAndTheBoardDoesNotChange() throws {
        let (rig, script) = try goldenRig()
        let board = rig.store.board(for: rig.tag)
        let allRows = rig.pane.displayedRows
        var deliveries = 0
        let sink = rig.store.changes.sink { _ in deliveries += 1 }
        defer { sink.cancel() }

        rig.pane.setFilter(.open)
        rig.settle()
        assertFilter(.open, shows: Set(script.itemIDs(notStatus: "done")), script: script, rig: rig)
        XCTAssertFalse(rig.pane.displayedRows.contains { $0.key.hasPrefix("done:") }, "Open has no Done groups")

        rig.pane.setFilter(.waiting)
        rig.settle()
        assertFilter(.waiting, shows: Set(script.itemIDs(status: "needs-you")), script: script, rig: rig)

        rig.pane.setFilter(.done)
        rig.settle()
        assertFilter(.done, shows: Set(script.itemIDs(status: "done")), script: script, rig: rig)

        rig.pane.setFilter(.all)
        rig.settle()
        XCTAssertEqual(rig.pane.displayedRows, allRows, "All brings back exactly the rows it had")

        XCTAssertEqual(rig.store.board(for: rig.tag), board, "a filter never edits the board")
        XCTAssertEqual(deliveries, 0, "and sends nothing anywhere")
    }

    func testTheFilterControlSelectsTheFilter() throws {
        let (rig, script) = try goldenRig()
        let control = rig.pane.header.filterControl
        XCTAssertEqual(control.segmentCount, TrackerFilter.allCases.count)
        for (index, expected) in [(1, TrackerFilter.open), (2, .waiting), (3, .done), (0, .all)] {
            control.selectedSegment = index
            XCTAssertTrue(control.sendAction(control.action, to: control.target))
            rig.settle()
            XCTAssertEqual(rig.pane.filter, expected)
        }
        control.selectedSegment = 2
        _ = control.sendAction(control.action, to: control.target)
        rig.settle()
        assertFilter(.waiting, shows: Set(script.itemIDs(status: "needs-you")), script: script, rig: rig)
    }

    // MARK: - PRD 23 (Mac half): a lost daemon connection changes nothing on screen

    func testAfterTheDaemonDisconnectsThePaneKeepsItsRowsAndShowsNoPlaceholder() throws {
        let (rig, script) = try goldenRig()
        let keys = rig.pane.displayedRows.map(\.key)
        rig.store.daemonDisconnected()
        rig.pane.render()
        rig.settle()
        XCTAssertFalse(rig.store.isConnected)
        XCTAssertEqual(rig.pane.displayedRows.map(\.key), keys)
        XCTAssertNil(rig.pane.placeholder.superview)
        XCTAssertFalse(rig.pane.rowViews.isEmpty)
        XCTAssertTrue(rig.pane.rowViews["item:\(script.itemIDs().first ?? "")"] != nil)
        XCTAssertFalse(Fx.allTexts(in: rig.pane).contains { $0.localizedCaseInsensitiveContains("loading") })
    }

    func testAReplayedBoardAfterReconnectChangesNothingAndMovesNoAnchor() throws {
        let (rig, script) = try goldenRig()
        rig.scroll(to: 400)
        let anchor = rig.pane.anchorSnapshot(windowIndex: 0)
        XCTAssertGreaterThan(anchor.scrollY, 100, "the pane is scrolled mid-board")
        let views = rig.pane.rowViews
        let frames = rig.rowFrames

        rig.store.daemonDisconnected()
        rig.push(script)   // the reconnect's replay of the same board
        XCTAssertTrue(rig.store.isConnected, "a board arriving means we are connected again")

        XCTAssertEqual(rig.pane.anchorSnapshot(windowIndex: 0), anchor, "the reading position is identical")
        XCTAssertEqual(rig.rowFrames, frames)
        for (key, view) in views { XCTAssertTrue(rig.pane.rowViews[key] === view) }

        // A replay that differs only in its version replaces the board in place, same result.
        var bumped = script
        bumped.setVersion(9)
        rig.store.daemonDisconnected()
        rig.push(bumped)
        XCTAssertEqual(rig.pane.anchorSnapshot(windowIndex: 0), anchor)
        XCTAssertEqual(rig.pane.rowsUpdatedLast, 0)
    }

    // MARK: - PRD 25 (Mac half): two windows, one delivery

    func testTwoPanesOnTheSameTagReceiveTheSameBoardInTheSameCoalescedDelivery() throws {
        let manual = Fx.makeManualStore()
        let tag = Fx.uniqueTag()
        let first = Fx.makeRig(self, tag: tag, store: manual.store)
        let second = Fx.makeRig(self, tag: tag, store: manual.store)
        XCTAssertFalse(first.window === second.window)
        var script = try TrackerBoardScript(tag: tag)

        manual.store.ingest(try script.message())   // delivered at once
        first.settle(); second.settle()
        XCTAssertNotNil(first.pane.presentation)
        XCTAssertEqual(first.pane.presentation, second.pane.presentation)

        // Two quick changes: held for the end of the 100 ms window, then delivered once to both.
        try script.setStatus("verif-1037", "blocked")
        script.setVersion(8)
        manual.store.ingest(try script.message())
        try script.setText("revie-1111", "Review queue job 8812 (second change)")
        script.setVersion(9)
        manual.store.ingest(try script.message())
        first.settle(); second.settle()
        XCTAssertFalse(first.rowView("item:revie-1111")?.visibleText.contains("(second change)") ?? true, "still within the window: not delivered yet")
        XCTAssertEqual(first.pane.presentation, second.pane.presentation, "neither is ahead of the other")

        manual.clock.advance(0.1)
        manual.scheduler.flush()
        first.settle(); second.settle()
        XCTAssertTrue(first.rowView("item:revie-1111")?.visibleText.contains("(second change)") ?? false)
        XCTAssertTrue(second.rowView("item:revie-1111")?.visibleText.contains("(second change)") ?? false)
        XCTAssertTrue(first.rowView("item:verif-1037")?.visibleText.contains("⊘") ?? false, "the folded changes arrived together")
        XCTAssertTrue(second.rowView("item:verif-1037")?.visibleText.contains("⊘") ?? false)
        XCTAssertEqual(first.pane.presentation, second.pane.presentation)
        XCTAssertEqual(first.pane.displayedRows, second.pane.displayedRows)
    }

    func testScrollingOnePaneDoesNotMoveTheOther() throws {
        let tag = Fx.uniqueTag()
        let store = Fx.makeImmediateStore()
        let first = Fx.makeRig(self, tag: tag, store: store)
        let second = Fx.makeRig(self, tag: tag, store: store)
        let script = try TrackerBoardScript(tag: tag)
        store.ingest(try script.message())
        first.settle(); second.settle()

        let secondBefore = second.pane.clipView.bounds
        let firstBefore = first.pane.clipView.bounds
        first.scroll(to: 350)
        XCTAssertGreaterThan(first.pane.clipView.bounds.minY, firstBefore.minY + 100, "the first pane scrolled")
        XCTAssertEqual(second.pane.clipView.bounds, secondBefore, "the second did not")
        XCTAssertEqual(second.pane.anchorSnapshot(windowIndex: 1).scrollY, Double(secondBefore.minY))
    }

    // MARK: - Focus

    func testThePaneAndItsPartsNeverAcceptKeyboardFocus() throws {
        let (rig, _) = try goldenRig()
        XCTAssertFalse(rig.pane.acceptsFirstResponder)
        XCTAssertFalse(rig.pane.header.acceptsFirstResponder)
        XCTAssertFalse(rig.pane.banner.acceptsFirstResponder)
        XCTAssertFalse(rig.pane.strip.acceptsFirstResponder)
        for view in rig.pane.rowViews.values { XCTAssertFalse(view.acceptsFirstResponder) }
    }

    func testUpdatesNeverMoveKeyboardFocusIntoThePane() throws {
        let (rig, script) = try goldenRig()
        XCTAssertTrue(rig.window.makeFirstResponder(rig.composer))
        let responder = rig.window.firstResponder
        XCTAssertNotNil(responder)

        var edited = script
        let ids = Array(script.itemIDs(notStatus: "done").prefix(5))
        for (i, id) in ids.enumerated() {
            try edited.setText(id, "\(script.text(id) ?? "") (update \(i))")
            rig.push(edited)
        }
        try edited.setStatus("verif-1037", "needs-you")
        edited.setBanner(["type": "missing", "last_seen": Fx.iso(1_760_547_000)])
        rig.push(edited)
        rig.pane.setFilter(.waiting)
        rig.pane.setFilter(.all)
        rig.pane.tick()

        XCTAssertTrue(rig.window.firstResponder === responder, "the composer still holds focus")
        let chain = firstResponderChain(of: rig.window)
        XCTAssertFalse(chain.contains { ($0 as? NSView).map { $0.isDescendant(of: rig.pane) } ?? false }, "nothing inside the pane is first responder")
    }

    // MARK: - No new key equivalents (contract 1.5)

    /// The set `setupMenu()` and `ModelShortcut` give the main menu today: ⌘Q, ⌘X/C/V/A/Z, ⇧⌘Z (written "Z"),
    /// ⇧⌘D/I/K/P/B (Debug) , ⇧⌘M (Session > model) and ⌥⌘A (Go to Approval Card).
    private static let pinnedKeyEquivalents: Set<String> = [
        "⌘q", "⌘x", "⌘c", "⌘v", "⌘a", "⌘z", "⌘Z",
        "⇧⌘d", "⇧⌘i", "⇧⌘k", "⇧⌘p", "⇧⌘b", "⇧⌘m", "⌥⌘a",
    ]

    private func symbols(forFlags flags: [String]) -> String {
        var out = ""
        if flags.contains(".control") { out += "⌃" }
        if flags.contains(".option") { out += "⌥" }
        if flags.contains(".shift") { out += "⇧" }
        if flags.contains(".command") { out += "⌘" }
        return out
    }

    private func flags(in text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func groups(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) throws -> [[String]] {
        let regex = try NSRegularExpression(pattern: pattern, options: options)
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (0..<match.numberOfRanges).map { i in
                match.range(at: i).location == NSNotFound ? "" : ns.substring(with: match.range(at: i))
            }
        }
    }

    private func mainMenuKeyEquivalents() throws -> Set<String> {
        let root = Fx.repoRoot()
        let source = try String(contentsOf: root.appendingPathComponent("macOS/Nostromo/AppDelegate.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func setupMenu()"), "setupMenu() moved")
        let end = try XCTUnwrap(source.range(of: "NSApplication.shared.mainMenu = mainMenu", range: start.upperBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.upperBound])
        let ns = body as NSString

        var found = Set<String>()
        let regex = try NSRegularExpression(pattern: #"keyEquivalent:\s*"([^"]*)""#)
        for match in regex.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: match.range(at: 1))
            guard !key.isEmpty else { continue }
            let before = ns.substring(to: match.range.location)
            var mask = [".command"]
            if let open = before.range(of: "NSMenuItem(", options: .backwards) {
                let lineStart = before[..<open.lowerBound].lastIndex(of: "\n").map { before.index(after: $0) } ?? before.startIndex
                let prefix = String(before[lineStart..<open.lowerBound])
                if let name = try groups(#"(?:let|var)\s+(\w+)\s*=\s*$"#, in: prefix).first?[1] {
                    if let flagText = try groups(#"\b"# + name + #"\.keyEquivalentModifierMask\s*=\s*\[([^\]]*)\]"#, in: body).first?[1] {
                        mask = flags(in: flagText)
                    }
                }
            }
            found.insert(symbols(forFlags: mask) + key)
        }

        // ModelShortcut.makeMenuItem() carries its own key and mask.
        let chip = try String(contentsOf: root.appendingPathComponent("macOS/Nostromo/UI/Model/ModelChip.swift"), encoding: .utf8)
        let key = try XCTUnwrap(try groups(#"static let keyEquivalent\s*=\s*"([^"]+)""#, in: chip).first?[1], "ModelShortcut.keyEquivalent moved")
        let maskText = try XCTUnwrap(try groups(#"static let modifierMask[^=]*=\s*\[([^\]]*)\]"#, in: chip).first?[1], "ModelShortcut.modifierMask moved")
        found.insert(symbols(forFlags: flags(in: maskText)) + key)
        return found
    }

    func testTheMainMenusKeyEquivalentsAreExactlyTheOnesItHadBeforeTheTracker() throws {
        let found = try mainMenuKeyEquivalents()
        XCTAssertEqual(found.sorted(), Self.pinnedKeyEquivalents.sorted(),
                       "the tracker adds no main-menu item and no global key equivalent (contract 1.5). Added: \(found.subtracting(Self.pinnedKeyEquivalents).sorted()); gone: \(Self.pinnedKeyEquivalents.subtracting(found).sorted())")
    }

    func testNothingInTheTrackerSourcesDeclaresAKeyEquivalentOrTouchesTheMainMenu() throws {
        let directory = Fx.repoRoot().appendingPathComponent("macOS/Nostromo/UI/Tracker")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThanOrEqual(files.count, 8, "the scan found the tracker's files: \(files)")
        for name in files.sorted() {
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            XCTAssertEqual(try groups(#"keyEquivalent:\s*"[^"]+""#, in: code).count, 0, "\(name) declares a key equivalent")
            XCTAssertEqual(try groups(#"\.keyEquivalent\s*=\s*"[^"]+""#, in: code).count, 0, "\(name) sets a key equivalent")
            XCTAssertFalse(code.contains("mainMenu"), "\(name) touches the main menu")
        }
    }

    // MARK: - PRD 14: the divider is persisted only by a user drag

    private func makeDynamicFocusWindow(_ focus: Focus, size: NSSize) -> (window: RigWindow, view: DynamicFocusView) {
        let window = makeRigWindow(self, size: size)
        let view = DynamicFocusView(focus: focus, windowId: "tracker-split-test-\(UUID().uuidString.prefix(6))")
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return (window, view)
    }

    /// Lets the split's first layout pass apply its ratios (it retries on every pass until it lands).
    private func layOut(_ view: NSView, until done: () -> Bool) {
        for _ in 0..<20 where !done() {
            view.layoutSubtreeIfNeeded()
            rigSettle(0.02)
        }
        view.layoutSubtreeIfNeeded()
    }

    private func leftShare(of split: NSSplitView) -> Double {
        let widths = split.arrangedSubviews.map { Double($0.frame.width) }
        return widths[0] / max(widths.reduce(0, +), 1)
    }

    func testTheTrackerSplitsDividerIsPersistedOnlyByAUserDragAndRestoredByANewView() throws {
        _ = NSApplication.shared
        let focus = Focus(id: UUID().uuidString, agentTag: "trk", projectPath: "/tmp/tracker-split-test", isBuiltIn: false)
        let tag = focus.sessionTag
        let prefix = "nostromo.dynlayout.\(tag)."
        func savedKeys() -> [String] { UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) } }
        addTeardownBlock { for key in savedKeys() { UserDefaults.standard.removeObject(forKey: key) } }
        XCTAssertEqual(savedKeys(), [], "a fresh tag starts with nothing saved")

        // A focus whose tree is `split horizontal [repl, tracker]` at 0.66 / 0.34, from the daemon.
        AppStore.shared.applyForTesting(.focusLayout(
            tag: tag,
            tree: .split(direction: .horizontal, children: [.leaf(paneId: "repl"), .leaf(paneId: "tracker")], ratios: [0.66, 0.34]),
            focusedPane: nil))

        let size = NSSize(width: 1000, height: 600)
        let (window, focusView) = makeDynamicFocusWindow(focus, size: size)
        let split = try XCTUnwrap(rigAllSubviews(of: focusView).compactMap { $0 as? RatioSplitView }.first, "the tree built a split")
        layOut(focusView) { split.ratiosApplied }
        XCTAssertTrue(split.ratiosApplied, "the programmatic ratios were applied")
        XCTAssertEqual(split.arrangedSubviews.count, 2)
        XCTAssertEqual(leftShare(of: split), 0.66, accuracy: 0.03)
        XCTAssertTrue(rigAllSubviews(of: focusView).contains { $0 is TrackerPaneView }, "the tracker leaf is the native pane")

        // Creating it, applying its ratios and resizing the window are not user choices.
        XCTAssertEqual(savedKeys(), [], "a programmatic creation is not persisted")
        window.setContentSize(NSSize(width: 1200, height: 640))
        layOut(focusView) { false }
        XCTAssertEqual(savedKeys(), [], "a window resize is not persisted")

        // The user grabs the divider and drags it to the middle.
        let dividerX = split.arrangedSubviews[0].frame.maxX + split.dividerThickness / 2
        let midY = split.bounds.midY
        let from = split.convert(NSPoint(x: dividerX, y: midY), to: nil)
        let to = split.convert(NSPoint(x: split.bounds.width * 0.5, y: midY), to: nil)
        try drag(split, in: window, from: from, to: to)
        layOut(focusView) { false }

        let keys = savedKeys()
        XCTAssertEqual(keys.count, 1, "the drag was saved once, under the split's path: \(keys)")
        let saved = try XCTUnwrap(keys.first.flatMap { UserDefaults.standard.array(forKey: $0) as? [Double] }, "a ratio array was written")
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(saved.reduce(0, +), 1, accuracy: 0.02)
        XCTAssertEqual(saved[0], 0.5, accuracy: 0.06, "the saved ratio is where the divider was dropped (was 0.66): \(saved)")

        // A new view for the same tag comes up with the dragged ratio, not the agent's.
        let size2 = NSSize(width: 1000, height: 600)
        let (window2, focusView2) = makeDynamicFocusWindow(focus, size: size2)
        let split2 = try XCTUnwrap(rigAllSubviews(of: focusView2).compactMap { $0 as? RatioSplitView }.first)
        layOut(focusView2) { split2.ratiosApplied }
        XCTAssertTrue(split2.ratiosApplied)
        XCTAssertEqual(leftShare(of: split2), saved[0], accuracy: 0.03, "the new DynamicFocusView restores the dragged divider")
        XCTAssertEqual(savedKeys().count, 1, "restoring it wrote nothing new")
        _ = window2
    }

    /// Press on the divider, drag in `steps` moves, release. The drags and the release are queued first:
    /// the split's own mouse tracking loop finds them (the same reason `AppControlMouse` queues its up).
    private func drag(_ split: NSSplitView, in window: NSWindow, from: NSPoint, to: NSPoint, steps: Int = 8) throws {
        let number = 0x5A00
        let t = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, _ point: NSPoint, _ offset: TimeInterval) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: t + offset,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: number,
                                             clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1),
                          "could not make a mouse event")
        }
        let down = try event(.leftMouseDown, from, 0)
        for i in 1...steps {
            let f = CGFloat(i) / CGFloat(steps)
            let point = NSPoint(x: from.x + (to.x - from.x) * f, y: from.y + (to.y - from.y) * f)
            NSApp.postEvent(try event(.leftMouseDragged, point, 0.001 * Double(i)), atStart: false)
        }
        NSApp.postEvent(try event(.leftMouseUp, to, 0.001 * Double(steps + 1)), atStart: false)
        split.mouseDown(with: down)
        // Anything the tracking loop left behind must not leak into later tests.
        while NSApp.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: .distantPast, inMode: .default, dequeue: true) != nil {}
    }
}
