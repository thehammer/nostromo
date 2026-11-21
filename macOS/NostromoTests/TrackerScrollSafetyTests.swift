import XCTest
import AppKit
import NostromoKit

// T1: the tracker's scroll-safety gate (PRD "Scroll, layout and focus safety", criteria 17 and 18).
//
// A `TrackerPaneView` in a window is fed boards through a real `TrackerStore` (decoded the way the
// socket reader decodes them), starting from the golden `frame-tracker-board.json` (board-60). From
// two starting positions, scrolled into the middle of the board and at the top, thirty scripted updates
// run one after another. After every one the pane's first visible row key is unchanged, the offset of
// the viewport top into that row moved by at most 1 pt, and the pane never became the first responder.
// Where each change lands (above, inside or below the viewport, or on the first visible row itself) is
// worked out from the pane's current row frames, never from fixed y values.
//
// Criterion 18 (deferred done / move / remove) follows: an on-screen change stays where the reader sees
// it until it leaves the viewport, an off-screen one applies at once.
//
// `TrackerGate*` types below are internal on purpose: `TrackerTranscriptSafetyTests` runs the same script
// next to the transcript rig. No wall clock (the pane's `now` and the store's are injected), no real
// pasteboard, no UserDefaults, no daemon.

// MARK: - Gate harness

struct TrackerGateError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// A clock the test moves by hand. `step` makes every read advance it (the store's coalescing clock).
final class TrackerGateClock {
    private(set) var time: TimeInterval
    let step: TimeInterval

    init(start: TimeInterval, step: TimeInterval = 0) {
        time = start
        self.step = step
    }

    var date: Date { Date(timeIntervalSince1970: time) }

    func advance(_ seconds: TimeInterval) { time += seconds }

    func tickingDate() -> Date {
        time += step
        return date
    }
}

/// Where an update lands relative to what the reader sees.
enum TrackerGatePlacement: String {
    /// Entirely above the viewport (the nearest such row).
    case above
    /// The first visible row itself (or, when that is not an item, the first visible item).
    case first
    /// Visible, below the first visible row.
    case inside
    /// Entirely below the viewport (the nearest such row).
    case below

    /// The placements to try, in order. At the top of the board nothing is above the viewport, so
    /// "above" falls back to what is nearest.
    var order: [TrackerGatePlacement] {
        switch self {
        case .above: return [.above, .first, .inside]
        case .first: return [.first, .inside]
        case .inside: return [.inside, .first]
        case .below: return [.below, .inside]
        }
    }
}

/// The wire board as editable JSON, so each scripted update is a new `tracker_board` frame.
struct TrackerGateBoard {
    private(set) var root: [String: Any]

    /// board-60 as the daemon sends it, with every `needs-you` item made `todo`, so the Waiting strip
    /// starts empty and the strip events can take it 0 -> 1 -> 0.
    static func base(file: StaticString = #filePath) throws -> TrackerGateBoard {
        var url = URL(fileURLWithPath: file.description)
        for _ in 0 ..< 3 { url.deleteLastPathComponent() }
        url.appendPathComponent("tests/fixtures/tracker/frame-tracker-board.json")
        let data = try Data(contentsOf: url)
        guard let frame = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let board = frame["board"] as? [String: Any] else {
            throw TrackerGateError("frame-tracker-board.json has no board")
        }
        var out = TrackerGateBoard(root: board)
        out.mapItems { item in
            if item["status"] as? String == "needs-you" { item["status"] = "todo" }
            // An un-run staged command waits on the person too (T5): none do at the start.
            if item["kind"] as? String == "command" { item["ran"] = true }
        }
        return out
    }

    private var nodes: [[String: Any]] {
        get { root["nodes"] as? [[String: Any]] ?? [] }
        set { root["nodes"] = newValue }
    }

    static func spans(_ text: String) -> [[String: Any]] {
        [["kind": "text", "text": text] as [String: Any]]
    }

    static func paragraphs(_ lines: [String]) -> [[String: Any]] {
        lines.map { ["kind": "paragraph", "spans": spans($0)] as [String: Any] }
    }

    private func index(ofItem id: String) throws -> Int {
        guard let i = nodes.firstIndex(where: { $0["type"] as? String == "item" && $0["id"] as? String == id }) else {
            throw TrackerGateError("the board has no item \(id)")
        }
        return i
    }

    mutating func bumpVersion() {
        root["version"] = ((root["version"] as? Int) ?? 0) + 1
    }

    mutating func mapItems(_ change: (inout [String: Any]) -> Void) {
        nodes = nodes.map { node in
            guard node["type"] as? String == "item" else { return node }
            var copy = node
            change(&copy)
            return copy
        }
    }

    mutating func editItem(_ id: String, _ change: (inout [String: Any]) -> Void) throws {
        var all = nodes
        let i = try index(ofItem: id)
        change(&all[i])
        nodes = all
    }

    mutating func setStatus(_ id: String, _ status: String) throws {
        try editItem(id) { $0["status"] = status }
    }

    mutating func setText(_ id: String, _ text: String) throws {
        try editItem(id) { $0["text_spans"] = Self.spans(text) }
    }

    /// One paragraph per line; no lines clears the note.
    mutating func setNote(_ id: String, lines: [String]) throws {
        try editItem(id) { $0["note_blocks"] = Self.paragraphs(lines) }
    }

    mutating func addItem(id: String, after existing: String, text: String, status: String = "todo") throws {
        var all = nodes
        let i = try index(ofItem: existing)
        let section = all[i]["section"] as? String ?? ""
        let node: [String: Any] = [
            "type": "item", "id": id, "section": section,
            "text_spans": Self.spans(text), "status": status,
            "updated_at": "2025-10-15T17:03:00Z",
            "note_blocks": [Any](), "links": [Any](),
            "kind": "item", "ran": false,
            "source": "- [ ] \(text) - \(status) <!-- #\(id) 1760547780 -->\n",
        ]
        all.insert(node, at: i + 1)
        nodes = all
    }

    mutating func removeItem(_ id: String) throws {
        var all = nodes
        all.remove(at: try index(ofItem: id))
        nodes = all
    }

    /// The agent moves `id` to the top of `section`.
    mutating func moveItem(_ id: String, toSection section: String) throws {
        var all = nodes
        var node = all.remove(at: try index(ofItem: id))
        node["section"] = section
        guard let s = all.firstIndex(where: { $0["type"] as? String == "section" && $0["id"] as? String == section }) else {
            throw TrackerGateError("the board has no section \(section)")
        }
        all.insert(node, at: s + 1)
        nodes = all
    }

    /// The daemon's own move (T3b2): `id` goes right after `other`, into `other`'s section.
    mutating func placeItem(_ id: String, after other: String) throws {
        var all = nodes
        var node = all.remove(at: try index(ofItem: id))
        guard let to = all.firstIndex(where: { $0["type"] as? String == "item" && $0["id"] as? String == other }) else {
            throw TrackerGateError("the board has no item \(other)")
        }
        node["section"] = all[to]["section"]
        all.insert(node, at: to + 1)
        nodes = all
    }

    mutating func appendLog(_ text: String) {
        var log = root["log"] as? [[String: Any]] ?? []
        let time = String(format: "10:%02d", log.count)
        log.append(["time": time, "text": text] as [String: Any])
        root["log"] = log
        var all = nodes
        all.append(["type": "log_line", "time": time, "text": text, "source": "- \(time) \(text)\n"] as [String: Any])
        nodes = all
    }

    mutating func setProse(key: String, text: String) throws {
        var all = nodes
        guard let i = all.firstIndex(where: { $0["type"] as? String == "prose" && $0["key"] as? String == key }) else {
            throw TrackerGateError("the board has no prose block \(key)")
        }
        all[i]["blocks"] = Self.paragraphs([text])
        all[i]["source"] = text + "\n\n"
        nodes = all
    }

    mutating func setBanner() {
        root["banner"] = ["type": "unreadable", "line": 3, "reason": "duplicate_id"] as [String: Any]
    }

    mutating func clearBanner() {
        _ = root.removeValue(forKey: "banner")
    }
}

/// One scripted update.
struct TrackerGateEvent {
    enum Kind: String, CaseIterable {
        case status, text, wrap, note, add, remove, move, log, tick, banner, strip, prose
    }

    enum Action {
        /// Edit the board, then deliver it through the store.
        case edit((inout TrackerGateBoard, TrackerGateHarness) throws -> Void)
        /// Move the pane's clock on and let it refresh its relative times.
        case tick(by: TimeInterval)
    }

    let kind: Kind
    let name: String
    let action: Action
    /// Something visible that the update must change (proves the update did something).
    let observe: ((TrackerPaneView) -> String)?
}

/// The thirty updates, spread above, inside and below the viewport.
enum TrackerGateScript {
    static let longText = String(repeating: "This item now has text long enough to wrap over several lines at the width of the pane. ", count: 3)

    private static func edit(_ kind: TrackerGateEvent.Kind, _ name: String,
                             observe: ((TrackerPaneView) -> String)? = nil,
                             _ body: @escaping (inout TrackerGateBoard, TrackerGateHarness) throws -> Void) -> TrackerGateEvent {
        TrackerGateEvent(kind: kind, name: name, action: .edit(body), observe: observe)
    }

    private static func nextStatus(_ status: TrackerStatusWire) -> String {
        switch status {
        case .todo: return "in-progress"
        case .inProgress: return "blocked"
        default: return "todo"
        }
    }

    private static func isOpen(_ item: TrackerItemRow) -> Bool {
        item.status == .todo || item.status == .inProgress || item.status == .blocked
    }

    static func events() -> [TrackerGateEvent] {
        var e: [TrackerGateEvent] = []

        // Status changes.
        e.append(edit(.status, "status change above the viewport") { board, h in
            let item = try h.requireItem(.above) { $0.status == .todo }
            try board.setStatus(item.id, "in-progress")
        })
        e.append(edit(.status, "status change inside the viewport") { board, h in
            let item = try h.requireItem(.inside) { isOpen($0) }
            try board.setStatus(item.id, nextStatus(item.status))
        })
        e.append(edit(.status, "status change on the first visible row") { board, h in
            let item = try h.requireItem(.first) { isOpen($0) }
            try board.setStatus(item.id, nextStatus(item.status))
        })

        // Text changes, including growth to more lines.
        e.append(edit(.text, "text change above the viewport") { board, h in
            let item = try h.requireItem(.above)
            try board.setText(item.id, "Reworded above the viewport")
        })
        e.append(edit(.text, "text change inside the viewport") { board, h in
            let item = try h.requireItem(.inside)
            try board.setText(item.id, "Reworded inside the viewport")
        })
        e.append(edit(.text, "text change on the first visible row") { board, h in
            let item = try h.requireItem(.first)
            try board.setText(item.id, "Reworded on the first visible row")
        })
        e.append(edit(.wrap, "text wraps to more lines above the viewport") { board, h in
            let item = try h.requireItem(.above)
            try board.setText(item.id, TrackerGateScript.longText)
        })
        e.append(edit(.wrap, "text wraps to more lines inside the viewport") { board, h in
            let item = try h.requireItem(.inside)
            try board.setText(item.id, TrackerGateScript.longText)
        })
        e.append(edit(.wrap, "text wraps to more lines on the first visible row") { board, h in
            let item = try h.requireItem(.first)
            try board.setText(item.id, TrackerGateScript.longText)
        })

        // Notes.
        e.append(edit(.note, "note added above the viewport") { board, h in
            let item = try h.requireItem(.above) { $0.noteBlocks.isEmpty }
            try board.setNote(item.id, lines: ["A note arrived above the viewport."])
        })
        e.append(edit(.note, "note added inside the viewport") { board, h in
            let item = try h.requireItem(.inside) { $0.noteBlocks.isEmpty }
            try board.setNote(item.id, lines: ["A note arrived inside the viewport."])
        })
        e.append(edit(.note, "note changed on the first visible row") { board, h in
            let item = try h.requireItem(.first) { !$0.noteBlocks.isEmpty }
            try board.setNote(item.id, lines: ["Changed note, line one", "line two", "line three"])
        })
        e.append(edit(.note, "note changed above the viewport") { board, h in
            let item = try h.requireItem(.above) { !$0.noteBlocks.isEmpty }
            try board.setNote(item.id, lines: ["Changed above.", "A second line."])
        })
        e.append(edit(.note, "note changed below the viewport") { board, h in
            let item = try h.requireItem(.below) { !$0.noteBlocks.isEmpty }
            try board.setNote(item.id, lines: ["Changed below the viewport."])
        })

        // Items added, removed, moved.
        e.append(edit(.add, "item added above the viewport") { board, h in
            let item = try h.requireItem(.above)
            try board.addItem(id: h.nextAddedID(), after: item.id, text: "Added above the viewport")
        })
        e.append(edit(.add, "item added inside the viewport") { board, h in
            let item = try h.requireItem(.inside)
            try board.addItem(id: h.nextAddedID(), after: item.id, text: "Added inside the viewport")
        })
        e.append(edit(.add, "item added below the viewport") { board, h in
            let item = try h.requireItem(.below)
            try board.addItem(id: h.nextAddedID(), after: item.id, text: "Added below the viewport")
        })
        e.append(edit(.remove, "item removed above the viewport") { board, h in
            let item = try h.requireItem(.above)
            try board.removeItem(item.id)
        })
        e.append(edit(.remove, "item removed inside the viewport") { board, h in
            let item = try h.requireItem(.inside)
            try board.removeItem(item.id)
        })
        e.append(edit(.remove, "item removed below the viewport") { board, h in
            let item = try h.requireItem(.below)
            try board.removeItem(item.id)
        })
        e.append(edit(.move, "item moved to another section above the viewport") { board, h in
            let item = try h.requireItem(.above)
            try board.moveItem(item.id, toSection: item.sectionId == "next" ? "findings" : "next")
        })
        e.append(edit(.move, "item moved to another section inside the viewport") { board, h in
            let item = try h.requireItem(.inside)
            try board.moveItem(item.id, toSection: item.sectionId == "next" ? "findings" : "next")
        })
        e.append(edit(.move, "item moved to another section below the viewport") { board, h in
            let item = try h.requireItem(.below)
            try board.moveItem(item.id, toSection: item.sectionId == "next" ? "findings" : "next")
        })

        // Log, clock, banner, strip, prose.
        e.append(edit(.log, "Log line appended below the viewport") { board, _ in
            board.appendLog("Gate: a log line the agent appended")
        })
        e.append(TrackerGateEvent(kind: .tick, name: "relative-time tick", action: .tick(by: 600),
                                  observe: { $0.header.updatedLabel.stringValue }))
        e.append(edit(.banner, "banner appears above the content",
                      observe: { String(describing: $0.banner.preferredHeight) }) { board, _ in
            board.setBanner()
        })
        e.append(edit(.banner, "banner clears",
                      observe: { String(describing: $0.banner.preferredHeight) }) { board, _ in
            board.clearBanner()
        })
        e.append(edit(.strip, "strip count goes 0 to 1",
                      observe: { String(describing: $0.strip.preferredHeight) }) { board, h in
            let item = try h.requireItem(.below) { isOpen($0) }
            try board.setStatus(item.id, "needs-you")
        })
        e.append(edit(.strip, "strip count goes 1 to 0",
                      observe: { String(describing: $0.strip.preferredHeight) }) { board, h in
            let item = try h.requireItem(.below) { $0.status == .needsYou }
            try board.setStatus(item.id, "todo")
        })
        e.append(edit(.prose, "prose block changes above the viewport") { board, h in
            let key = try h.requireProseKey(.above)
            try board.setProse(key: key, text: "Prose the agent rewrote while the reader was further down.")
        })
        return e
    }
}

/// What the pane's edit sender was handed, in order.
final class TrackerGateEditLog {
    struct Sent {
        let requestId: String
        let base: UInt64
        let ops: [TrackerPaneOpWire]
    }

    var sent: [Sent] = []
}

/// A tracker pane fed by a real store, plus everything the gate reads from it.
final class TrackerGateHarness {
    enum Start: String {
        /// The viewport top is inside a note-bearing item row in the middle of the board (not on a row
        /// boundary).
        case mid
        case top
    }

    struct Placed {
        let key: String
        let frame: CGRect
        let row: TrackerRow
    }

    static let tag = "gate-tracker"

    /// What the pane asked its injected openers to do (T6): nothing reaches a daemon or the browser.
    let links = TrackerGateLinkRecorder()
    /// Every `tracker_edit` frame the pane sent (T3b2): the pane has no other way to send anything.
    let edits = TrackerGateEditLog()
    /// What the pane asked its injected schedule to run later (the remove banner's 10 s); nothing runs unless a test says so.
    let scheduled = TrackerManualScheduler()

    let pane: TrackerPaneView
    let store: TrackerStore
    let paneClock: TrackerGateClock
    private(set) var board: TrackerGateBoard
    private let client = NostromodClient(socketPath: "/dev/null")
    private var added = 0

    /// `editing`: the pane acts as if the daemon takes pane edits (T3b); the frames go nowhere.
    init(_ testCase: XCTestCase, editing: Bool = false) throws {
        board = try TrackerGateBoard.base()
        // Relative times: board-60's last item is 4 m old at this `now`.
        let paneClock = TrackerGateClock(start: 1_760_548_000)
        // The store coalesces at 10 Hz by its own clock; every read moves it a second, so each ingest
        // is delivered synchronously.
        let storeClock = TrackerGateClock(start: 1_760_000_000, step: 1)
        let store = TrackerStore(now: { storeClock.tickingDate() }, schedule: { _, work in work() })
        self.paneClock = paneClock
        self.store = store
        let links = self.links
        let edits = self.edits
        let scheduled = self.scheduled
        pane = TrackerPaneView(tag: TrackerGateHarness.tag, store: store, now: { paneClock.date },
                               reduceMotion: { true }, pasteboard: rigPrivatePasteboard(testCase),
                               openLinkInDaemon: { tag, item, index in links.daemonOpens.append(.init(tag: tag, item: item, index: index)) },
                               openURL: { links.urlOpens.append($0) },
                               schedule: { scheduled.schedule($0, $1) }, timeZone: TimeZone(identifier: "UTC")!, tickInterval: nil,
                               editSupported: { editing },
                               editSender: { _, requestId, base, _, ops in
                                   edits.sent.append(.init(requestId: requestId, base: base, ops: ops))
                                   return true
                               },
                               editSchedule: { _, _ in })
    }

    // MARK: Layout and delivery

    func layout() {
        pane.window?.contentView?.layoutSubtreeIfNeeded()
        pane.window?.contentView?.layoutSubtreeIfNeeded()
    }

    /// Deliver the current board as a `tracker_board` frame, decoded by the Mac client.
    func push() throws {
        board.bumpVersion()
        let frame: [String: Any] = ["type": "tracker_board", "tag": Self.tag, "board": board.root]
        let data = try JSONSerialization.data(withJSONObject: frame)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TrackerGateError("frame is not an object")
        }
        let msg = client.decode(type_: "tracker_board", json: json, raw: data)
        guard case .trackerBoard = msg else { throw TrackerGateError("the frame did not decode as tracker_board") }
        store.ingest(msg)
    }

    /// The daemon applies the user's last edit (T3b2): the board with `change` arrives, then the result.
    func echo(created: [String] = [], _ change: (inout TrackerGateBoard) throws -> Void) throws {
        guard let last = edits.sent.last else { throw TrackerGateError("nothing was sent to echo") }
        try mutate(change)
        var object: [String: Any] = ["tag": Self.tag, "request_id": last.requestId, "ok": true,
                                     "version": (board.root["version"] as? Int) ?? 0]
        if !created.isEmpty { object["created"] = created }
        let data = try JSONSerialization.data(withJSONObject: object)
        store.ingestEditResult(try JSONDecoder().decode(TrackerEditResultWire.self, from: data))
        layout()
    }

    /// Edit the board and deliver it.
    func mutate(_ body: (inout TrackerGateBoard) throws -> Void) throws {
        var copy = board
        try body(&copy)
        board = copy
        try push()
        layout()
    }

    func nextAddedID() -> String {
        added += 1
        return "gate-added-\(added)"
    }

    /// Run one scripted update and lay out. Throws when the update could not be built (no row where
    /// it should land) or did nothing it was meant to do.
    func perform(_ event: TrackerGateEvent) throws {
        let observed = event.observe?(pane)
        switch event.action {
        case .edit(let body):
            var copy = board
            try body(&copy, self)
            board = copy
            try push()
        case .tick(let seconds):
            paneClock.advance(seconds)
            pane.tick()
        }
        layout()
        if let observed, let observe = event.observe, observe(pane) == observed {
            throw TrackerGateError("the update changed nothing visible (\(observed))")
        }
    }

    // MARK: Scrolling

    /// The operator scrolling: the clip view moves and the pane hears the bounds change.
    func scrollUser(to y: CGFloat) {
        pane.clipView.scroll(to: NSPoint(x: 0, y: y))
        pane.scrollView.reflectScrolledClipView(pane.clipView)
        layout()
    }

    func scrollToBottom() {
        scrollUser(to: max(0, pane.documentView.frame.height - pane.clipView.bounds.height))
    }

    func scroll(toRow key: String, offset: CGFloat) throws {
        guard let frame = frame(of: key) else { throw TrackerGateError("no row \(key) to scroll to") }
        scrollUser(to: frame.minY + offset)
    }

    func start(_ start: Start) throws {
        switch start {
        case .top:
            scrollUser(to: 0)
        case .mid:
            let withNotes = placedRows().filter { placed in
                guard case .item(let item) = placed.row.content, placed.key == TrackerRow.itemKey(item.id) else { return false }
                return !item.noteBlocks.isEmpty
            }
            guard !withNotes.isEmpty else { throw TrackerGateError("the board shows no item with a note") }
            let target = withNotes[withNotes.count / 3]
            scrollUser(to: target.frame.minY + floor(target.frame.height / 2))
            let first = pane.anchorSnapshot(windowIndex: 0).firstVisible
            guard first?.rowKey == target.key, (first?.offsetPt ?? 0) > 3 else {
                throw TrackerGateError("mid start did not land inside \(target.key): \(String(describing: first))")
            }
        }
    }

    // MARK: Reading the pane

    func placedRows() -> [Placed] {
        pane.displayedRows.compactMap { row in
            pane.rowViews[row.key].map { Placed(key: row.key, frame: $0.frame, row: row) }
        }
    }

    func frame(of key: String) -> CGRect? { pane.rowViews[key]?.frame }

    var displayedKeys: [String] { pane.displayedRows.map(\.key) }

    func doneGroup(section: String) -> TrackerDoneGroupRow? {
        for row in pane.displayedRows {
            if case .doneGroup(let group) = row.content, group.sectionId == section { return group }
        }
        return nil
    }

    /// The first row on screen and the offset into it, were the viewport top at `y` in today's layout.
    func expectedFirstVisible(atScrollY y: CGFloat) -> (key: String, offset: CGFloat)? {
        let height = pane.clipView.bounds.height
        for placed in placedRows() where placed.frame.height > 0 && placed.frame.maxY > y && placed.frame.minY < y + height {
            return (placed.key, y - placed.frame.minY)
        }
        return nil
    }

    func paneOwnsFirstResponder() -> Bool {
        guard let view = pane.window?.firstResponder as? NSView else { return false }
        return view === pane || view.isDescendant(of: pane)
    }

    // MARK: Picking where an update lands

    private func candidates(_ placement: TrackerGatePlacement, among rows: [Placed]) -> [Placed] {
        let viewport = pane.clipView.bounds
        let firstKey = pane.anchorSnapshot(windowIndex: 0).firstVisible?.rowKey
        switch placement {
        case .above:
            return Array(rows.filter { $0.frame.maxY <= viewport.minY }.reversed())
        case .first:
            return rows.filter { $0.key == firstKey }
        case .inside:
            return rows.filter { $0.frame.maxY > viewport.minY && $0.frame.minY < viewport.maxY && $0.key != firstKey }
        case .below:
            return rows.filter { $0.frame.minY >= viewport.maxY }
        }
    }

    func pickItem(_ placement: TrackerGatePlacement, where predicate: (TrackerItemRow) -> Bool = { _ in true }) -> TrackerItemRow? {
        let rows = placedRows().filter { placed in
            guard case .item(let item) = placed.row.content, placed.key == TrackerRow.itemKey(item.id) else { return false }
            return predicate(item)
        }
        for option in placement.order {
            if let hit = candidates(option, among: rows).first, case .item(let item) = hit.row.content { return item }
        }
        return nil
    }

    func requireItem(_ placement: TrackerGatePlacement, where predicate: (TrackerItemRow) -> Bool = { _ in true }) throws -> TrackerItemRow {
        guard let item = pickItem(placement, where: predicate) else {
            throw TrackerGateError("no item row \(placement.rawValue) the viewport meets the update's condition")
        }
        return item
    }

    func requireProseKey(_ placement: TrackerGatePlacement) throws -> String {
        let rows = placedRows().filter { placed in
            if case .prose = placed.row.content { return true }
            return false
        }
        for option in placement.order {
            if let hit = candidates(option, among: rows).first, case .prose(let prose) = hit.row.content { return prose.key }
        }
        throw TrackerGateError("no prose row \(placement.rawValue) the viewport")
    }

    // MARK: The gate

    /// The top edge of `key`'s row in window coordinates: where the reader sees it.
    func screenTop(of key: String) -> CGFloat? {
        pane.rowViews[key].map { $0.convert($0.bounds, to: nil).maxY }
    }

    /// Run `event` and assert what the reader sees did not move: the row that was first visible is
    /// at the same place on screen (≤ 1 pt), and, when nothing above the scroll view changed height,
    /// it is still the first visible row with the viewport top's offset into it moved by at most
    /// 1 pt; the pane never took focus. (When the banner or the strip appears, the scroll view's top
    /// moves down and the content scrolls by as much, so the read line stays put on screen. The one
    /// exception is a pane at offset 0: there is no line being read below the fold, so it stays at
    /// the very top, scrolled by nothing, and the first row stays the first row at offset 0.)
    func assertNoMove(_ name: String, _ event: TrackerGateEvent,
                      file: StaticString = #filePath, line: UInt = #line) {
        assertNoMove(name, file: file, line: line) { try self.perform(event) }
    }

    /// [`assertNoMove(_:_:)`] for any interaction, not only a scripted board update (T4: expanding a
    /// command row, Ran it, Copy).
    func assertNoMove(_ name: String, userGesture: Bool = false, file: StaticString = #filePath, line: UInt = #line,
                      _ interaction: () throws -> Void) {
        let ownedFocusBefore = paneOwnsFirstResponder()
        let before = pane.anchorSnapshot(windowIndex: 0)
        XCTAssertNotNil(before.firstVisible, "\(name): the pane has a first visible row", file: file, line: line)
        let readKey = before.firstVisible?.rowKey
        let screenBefore = readKey.flatMap(screenTop(of:))
        let chromeBefore = pane.scrollView.frame.minY
        let atTop = before.scrollY <= 0.5
        do {
            try interaction()
            layout()
        } catch {
            XCTFail("\(name): \(error)", file: file, line: line)
            return
        }
        let after = pane.anchorSnapshot(windowIndex: 0)
        if atTop && pane.scrollView.frame.minY != chromeBefore {
            XCTAssertLessThanOrEqual(after.scrollY, 0.5, "\(name): the pane left the top of the board (scrollY \(after.scrollY))",
                                     file: file, line: line)
            XCTAssertEqual(after.firstVisible?.rowKey, readKey, "\(name): first visible row changed", file: file, line: line)
            XCTAssertLessThanOrEqual(after.firstVisible?.offsetPt ?? .infinity, 1,
                                     "\(name): the first row was scrolled into", file: file, line: line)
        } else if let readKey, let screenBefore, let screenAfter = screenTop(of: readKey) {
            let moved = abs(screenAfter - screenBefore)
            XCTAssertLessThanOrEqual(moved, 1, "\(name): the line being read (\(readKey)) moved \(moved) pt on screen",
                                     file: file, line: line)
        } else {
            XCTFail("\(name): the first visible row \(readKey ?? "nil") is no longer shown", file: file, line: line)
        }
        if pane.scrollView.frame.minY == chromeBefore {
            XCTAssertEqual(after.firstVisible?.rowKey, before.firstVisible?.rowKey,
                           "\(name): first visible row changed", file: file, line: line)
            let drift = abs((after.firstVisible?.offsetPt ?? .infinity) - (before.firstVisible?.offsetPt ?? 0))
            XCTAssertLessThanOrEqual(drift, 1, "\(name): first visible row moved by \(drift) pt", file: file, line: line)
        }
        XCTAssertFalse(paneOwnsFirstResponder() && !ownedFocusBefore && !userGesture,
                       "\(name): the tracker took keyboard focus (\(String(describing: pane.window?.firstResponder)))",
                       file: file, line: line)
    }
}

// MARK: - The tests

final class TrackerScrollSafetyTests: XCTestCase {

    private func makeHarness(_ start: TrackerGateHarness.Start,
                             size: NSSize = NSSize(width: 380, height: 420),
                             editing: Bool = false) throws -> TrackerGateHarness {
        let window = makeRigWindow(self, size: size)
        let harness = try TrackerGateHarness(self, editing: editing)
        let content = window.contentView!
        harness.pane.frame = content.bounds
        harness.pane.autoresizingMask = [.width, .height]
        content.addSubview(harness.pane)
        harness.layout()
        try harness.push()
        harness.layout()
        try harness.start(start)
        return harness
    }

    private func assertPending(_ harness: TrackerGateHarness, _ key: String, _ kind: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        let snapshot = harness.pane.anchorSnapshot(windowIndex: 0)
        XCTAssertTrue(snapshot.pending.contains(TrackerAnchorSnapshot.Pending(key: key, kind: kind)),
                      "\(key) is held as \(kind): \(snapshot.pending)", file: file, line: line)
        XCTAssertTrue(snapshot.deferredPending, "a deferred change is pending", file: file, line: line)
    }

    private func assertNothingPending(_ harness: TrackerGateHarness, _ message: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let snapshot = harness.pane.anchorSnapshot(windowIndex: 0)
        XCTAssertTrue(snapshot.pending.isEmpty, "\(message): pending \(snapshot.pending)", file: file, line: line)
        XCTAssertFalse(snapshot.deferredPending, message, file: file, line: line)
    }

    private func assertSameFrame(_ actual: CGRect?, _ expected: CGRect, _ message: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        guard let actual else { return XCTFail("\(message): no frame", file: file, line: line) }
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.5, "\(message): x", file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5, "\(message): y", file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.5, "\(message): width", file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.5, "\(message): height", file: file, line: line)
    }

    private func assertFirstVisible(_ harness: TrackerGateHarness, is expected: (key: String, offset: CGFloat),
                                    _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let first = harness.pane.anchorSnapshot(windowIndex: 0).firstVisible
        XCTAssertEqual(first?.rowKey, expected.key, "\(message): first visible row", file: file, line: line)
        XCTAssertEqual(first?.offsetPt ?? .infinity, Double(expected.offset), accuracy: 1,
                       "\(message): offset into the first visible row", file: file, line: line)
    }

    // MARK: - T4: a staged command's row never moves the reading line

    /// Expanding a command row, Ran it, Copy and a long command arriving each leave the first visible
    /// row where it was (the measure `assertNoMove` takes), wherever the command row is.
    func testCommandRowInteractionsNeverMoveTheFirstVisibleRow() throws {
        var exercised = 0
        for placement in [TrackerGatePlacement.above, .inside, .below] {
            let h = try makeHarness(.mid, editing: true)
            guard let item = h.pickItem(placement, where: { $0.isCommand && $0.status != .done }) else { continue }
            let id = item.id
            let key = TrackerRow.itemKey(id)
            exercised += 1
            h.assertNoMove("\(placement): expand the command row") { h.pane.toggleNote(item: id) }
            h.assertNoMove("\(placement): Copy") {
                let block = try XCTUnwrap(h.pane.rowViews[key]?.commandBlock)
                block.copyButton.performClick(nil)
            }
            // A person's click on the box is a user edit: it may take the pane's focus sink (as every pane edit does).
            h.assertNoMove("\(placement): Ran it", userGesture: true) {
                let block = try XCTUnwrap(h.pane.rowViews[key]?.commandBlock)
                block.permit = { _ in .human(sourcePid: nil, sourceState: nil) }
                block.ranItCheckbox.performClick(nil)
                XCTAssertEqual(h.edits.sent.count, 1, "\(placement): Ran it sent the tick")
            }
            h.assertNoMove("\(placement): the board ticks it") { try h.echo { try $0.setStatus(id, "done") } }
            h.assertNoMove("\(placement): a long command arrives") {
                let lines = (1...40).map { "echo line \($0)" }.joined(separator: "\n")
                try h.mutate { try $0.editItem(id) { $0["command"] = lines } }
            }
            h.assertNoMove("\(placement): the long command is cut to a short one") {
                try h.mutate { try $0.editItem(id) { $0["command"] = "ls" } }
            }
        }
        XCTAssertGreaterThanOrEqual(exercised, 2, "the board has command rows above, inside and below the viewport")
    }

    // MARK: - PRD 17: thirty scripted updates

    func testTheScriptIsThirtyUpdatesOfEveryRequiredKind() {
        let events = TrackerGateScript.events()
        XCTAssertEqual(events.count, 30)
        XCTAssertEqual(Set(events.map(\.kind)), Set(TrackerGateEvent.Kind.allCases),
                       "status, text, wrap, note, add, remove, move, log, tick, banner, strip and prose are all in the script")
        for placement in ["above", "inside", "below", "first visible row"] {
            XCTAssertTrue(events.contains { $0.name.contains(placement) }, "the script has updates \(placement)")
        }
    }

    func testThirtyScriptedUpdatesNeverMoveTheReadingPositionWhenScrolledMidBoard() throws {
        let harness = try makeHarness(.mid)
        XCTAssertGreaterThan(harness.pane.anchorSnapshot(windowIndex: 0).scrollY, 0, "setup: scrolled into the board")
        XCTAssertFalse(harness.paneOwnsFirstResponder())
        for (i, event) in TrackerGateScript.events().enumerated() {
            harness.assertNoMove("mid-board #\(i + 1) \(event.name)", event)
        }
    }

    func testThirtyScriptedUpdatesNeverMoveTheReadingPositionAtTheTop() throws {
        let harness = try makeHarness(.top)
        XCTAssertEqual(harness.pane.anchorSnapshot(windowIndex: 0).scrollY, 0, accuracy: 0.5, "setup: at the top")
        XCTAssertFalse(harness.paneOwnsFirstResponder())
        for (i, event) in TrackerGateScript.events().enumerated() {
            harness.assertNoMove("top #\(i + 1) \(event.name)", event)
        }
    }

    // MARK: - The banner or the strip appearing at offset 0

    /// The first displayed row, the viewport top and the scroll position at the very top of the board.
    private func assertAtTheVeryTop(_ harness: TrackerGateHarness, firstRow: String, _ message: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let snapshot = harness.pane.anchorSnapshot(windowIndex: 0)
        XCTAssertEqual(snapshot.scrollY, 0, accuracy: 0.5, "\(message): scrollY", file: file, line: line)
        XCTAssertEqual(harness.pane.clipView.bounds.minY, 0, accuracy: 0.5, "\(message): clip top", file: file, line: line)
        XCTAssertEqual(snapshot.firstVisible?.rowKey, firstRow, "\(message): first visible row", file: file, line: line)
        XCTAssertEqual(snapshot.firstVisible?.offsetPt ?? .infinity, 0, accuracy: 0.5,
                       "\(message): offset into the first row", file: file, line: line)
        XCTAssertEqual(harness.frame(of: firstRow)?.minY ?? .infinity, 0, accuracy: 0.5,
                       "\(message): the first row is at the top of the document", file: file, line: line)
    }

    func testTheWaitingStripAppearingAtOffsetZeroLeavesThePaneAtTheTopWithTheFirstRowStillFirst() throws {
        let harness = try makeHarness(.top)
        let pane = harness.pane
        let firstRow = try XCTUnwrap(pane.anchorSnapshot(windowIndex: 0).firstVisible?.rowKey)
        assertAtTheVeryTop(harness, firstRow: firstRow, "setup")
        XCTAssertEqual(pane.strip.preferredHeight, 0, "setup: nothing waits yet")
        let chromeBefore = pane.scrollView.frame.minY

        let item = try harness.requireItem(.below) { $0.status == .todo }
        try harness.mutate { try $0.setStatus(item.id, "needs-you") }

        XCTAssertGreaterThan(pane.strip.preferredHeight, 0, "the strip appeared")
        XCTAssertEqual(pane.scrollView.frame.minY - chromeBefore, pane.strip.preferredHeight, accuracy: 0.5,
                       "it pushed the scroll view down by its own height")
        assertAtTheVeryTop(harness, firstRow: firstRow, "after the strip appeared")

        try harness.mutate { try $0.setStatus(item.id, "todo") }
        XCTAssertEqual(pane.strip.preferredHeight, 0, "the strip went again")
        assertAtTheVeryTop(harness, firstRow: firstRow, "after the strip went")
    }

    func testTheBannerAppearingAtOffsetZeroLeavesThePaneAtTheTopWithTheFirstRowStillFirst() throws {
        let harness = try makeHarness(.top)
        let pane = harness.pane
        let firstRow = try XCTUnwrap(pane.anchorSnapshot(windowIndex: 0).firstVisible?.rowKey)
        assertAtTheVeryTop(harness, firstRow: firstRow, "setup")
        XCTAssertEqual(pane.banner.preferredHeight, 0, "setup: no banner yet")

        try harness.mutate { $0.setBanner() }
        XCTAssertGreaterThan(pane.banner.preferredHeight, 0, "the banner appeared")
        assertAtTheVeryTop(harness, firstRow: firstRow, "after the banner appeared")

        try harness.mutate { $0.clearBanner() }
        XCTAssertEqual(pane.banner.preferredHeight, 0, "the banner went")
        assertAtTheVeryTop(harness, firstRow: firstRow, "after the banner went")
    }

    func testTheStripAndTheBannerTogetherAtOffsetZeroStillLeaveThePaneAtTheTop() throws {
        let harness = try makeHarness(.top)
        let firstRow = try XCTUnwrap(harness.pane.anchorSnapshot(windowIndex: 0).firstVisible?.rowKey)
        let item = try harness.requireItem(.below) { $0.status == .todo }
        try harness.mutate { board in
            board.setBanner()
            try board.setStatus(item.id, "needs-you")
        }
        XCTAssertGreaterThan(harness.pane.banner.preferredHeight, 0)
        XCTAssertGreaterThan(harness.pane.strip.preferredHeight, 0)
        assertAtTheVeryTop(harness, firstRow: firstRow, "after both appeared")
    }

    func testTheWaitingStripAppearingWhileScrolledAwayFromTheTopStillKeepsTheReadingLineStationary() throws {
        let harness = try makeHarness(.top)
        try harness.scroll(toRow: "section:next", offset: 10)
        let pane = harness.pane
        let before = pane.anchorSnapshot(windowIndex: 0)
        XCTAssertGreaterThan(before.scrollY, 100, "setup: scrolled into the board")
        let readKey = try XCTUnwrap(before.firstVisible?.rowKey)
        let screenBefore = try XCTUnwrap(harness.screenTop(of: readKey))
        let chromeBefore = pane.scrollView.frame.minY

        let item = try harness.requireItem(.below) { $0.status == .todo }
        try harness.mutate { try $0.setStatus(item.id, "needs-you") }

        XCTAssertGreaterThan(pane.strip.preferredHeight, 0, "the strip appeared")
        let shift = pane.scrollView.frame.minY - chromeBefore
        XCTAssertEqual(shift, pane.strip.preferredHeight, accuracy: 0.5)
        let after = pane.anchorSnapshot(windowIndex: 0)
        // The line being read stays put on screen. It is not asserted to stay the first row *in the
        // viewport*: the strip now covers the top of the old viewport, and the heading being read is
        // shorter than the strip, so the next row is the first one left in view.
        XCTAssertEqual(try XCTUnwrap(harness.screenTop(of: readKey)), screenBefore, accuracy: 1,
                       "the line being read did not move on screen")
        XCTAssertEqual(after.scrollY, before.scrollY + Double(shift), accuracy: 1, "the content scrolled by the strip's height")
    }

    // MARK: - PRD 18a: done

    private let doneItem = "rotat-2702"        // a todo item in Findings, which already has a Done group
    private let doneSection = "findings"

    /// The viewport top sits inside the Findings heading, so the item is on screen and is not the first row.
    private func onScreenDoneSetup() throws -> (harness: TrackerGateHarness, key: String, frame: CGRect, doneCount: Int) {
        let harness = try makeHarness(.top)
        try harness.scroll(toRow: "section:findings", offset: 10)
        let key = TrackerRow.itemKey(doneItem)
        XCTAssertTrue(harness.pane.visibleKeys().contains(key), "setup: \(key) is on screen")
        let frame = try XCTUnwrap(harness.frame(of: key))
        XCTAssertFalse(harness.pane.rowViews[key]?.isStrikethrough ?? true, "setup: not struck through yet")
        let count = try XCTUnwrap(harness.doneGroup(section: doneSection)).count
        return (harness, key, frame, count)
    }

    func testAnOnScreenItemSetToDoneStaysInPlaceStruckThrough() throws {
        let (harness, key, frame, doneCount) = try onScreenDoneSetup()
        let before = harness.pane.anchorSnapshot(windowIndex: 0)

        try harness.mutate { try $0.setStatus(doneItem, "done") }

        assertSameFrame(harness.frame(of: key), frame, "the done item keeps its frame")
        XCTAssertEqual(harness.pane.rowViews[key]?.isStrikethrough, true, "the done item is struck through")
        assertPending(harness, key, "done_in_place")
        XCTAssertEqual(harness.doneGroup(section: doneSection)?.count, doneCount, "Done (N) has not taken it yet")
        let after = harness.pane.anchorSnapshot(windowIndex: 0)
        XCTAssertEqual(after.firstVisible?.rowKey, before.firstVisible?.rowKey)
        XCTAssertEqual(after.firstVisible?.offsetPt ?? .infinity, before.firstVisible?.offsetPt ?? 0, accuracy: 1)
    }

    func testADoneItemFoldsIntoItsSectionsDoneGroupOnlyAfterItScrollsFullyOutOfView() throws {
        let (harness, key, frame, doneCount) = try onScreenDoneSetup()
        try harness.mutate { try $0.setStatus(doneItem, "done") }
        assertPending(harness, key, "done_in_place")

        // Still partly in view: still held.
        harness.scrollUser(to: frame.maxY - 5)
        XCTAssertNotNil(harness.pane.rowViews[key], "a done item still partly on screen stays in place")
        assertPending(harness, key, "done_in_place")

        // Fully out of view above the viewport: it folds.
        let top = frame.maxY + 3
        let expected = try XCTUnwrap(harness.expectedFirstVisible(atScrollY: top))
        harness.scrollUser(to: top)

        XCTAssertNil(harness.pane.rowViews[key], "no item row once it has folded")
        XCTAssertFalse(harness.displayedKeys.contains(key))
        let group = try XCTUnwrap(harness.doneGroup(section: doneSection))
        XCTAssertEqual(group.count, doneCount + 1, "the section's Done (N) took it")
        XCTAssertTrue(group.itemIds.contains(doneItem))
        assertNothingPending(harness, "nothing is held after the fold")
        assertFirstVisible(harness, is: expected, "the fold")
    }

    func testClickingTheDoneGroupReleasesAHeldDoneItem() throws {
        let (harness, key, _, doneCount) = try onScreenDoneSetup()
        try harness.mutate { try $0.setStatus(doneItem, "done") }
        assertPending(harness, key, "done_in_place")
        let before = harness.pane.anchorSnapshot(windowIndex: 0)

        harness.pane.toggleDoneGroup(section: doneSection)
        harness.layout()

        assertNothingPending(harness, "the Done group released the hold")
        let group = try XCTUnwrap(harness.doneGroup(section: doneSection))
        XCTAssertTrue(group.expanded, "the clicked group opened")
        XCTAssertEqual(group.count, doneCount + 1)
        XCTAssertTrue(group.itemIds.contains(doneItem), "the item is in the group")
        let groupFrame = try XCTUnwrap(harness.frame(of: TrackerRow.doneKey(doneSection)))
        let itemFrame = try XCTUnwrap(harness.frame(of: key), "the opened group lists the item")
        XCTAssertGreaterThan(itemFrame.minY, groupFrame.minY, "the item now sits under the Done heading")
        let after = harness.pane.anchorSnapshot(windowIndex: 0)
        XCTAssertEqual(after.firstVisible?.rowKey, before.firstVisible?.rowKey)
        XCTAssertEqual(after.firstVisible?.offsetPt ?? .infinity, before.firstVisible?.offsetPt ?? 0, accuracy: 1)
    }

    func testAnItemSetToDoneAboveTheViewportFoldsAtOnce() throws {
        let harness = try makeHarness(.top)
        harness.scrollToBottom()
        let key = TrackerRow.itemKey(doneItem)
        let frame = try XCTUnwrap(harness.frame(of: key))
        XCTAssertLessThanOrEqual(frame.maxY, harness.pane.clipView.bounds.minY, "setup: above the viewport")
        let count = try XCTUnwrap(harness.doneGroup(section: doneSection)).count
        let before = harness.pane.anchorSnapshot(windowIndex: 0)

        try harness.mutate { try $0.setStatus(doneItem, "done") }

        XCTAssertNil(harness.pane.rowViews[key], "folded at once")
        XCTAssertEqual(harness.doneGroup(section: doneSection)?.count, count + 1)
        assertNothingPending(harness, "an off-screen fold is not deferred")
        let after = harness.pane.anchorSnapshot(windowIndex: 0)
        XCTAssertEqual(after.firstVisible?.rowKey, before.firstVisible?.rowKey)
        XCTAssertEqual(after.firstVisible?.offsetPt ?? .infinity, before.firstVisible?.offsetPt ?? 0, accuracy: 1)
    }

    func testAnItemSetToDoneBelowTheViewportFoldsAtOnce() throws {
        let harness = try makeHarness(.top)
        let key = TrackerRow.itemKey("check-2776")
        let frame = try XCTUnwrap(harness.frame(of: key))
        XCTAssertGreaterThanOrEqual(frame.minY, harness.pane.clipView.bounds.maxY, "setup: below the viewport")
        let count = try XCTUnwrap(harness.doneGroup(section: doneSection)).count
        let before = harness.pane.anchorSnapshot(windowIndex: 0)

        try harness.mutate { try $0.setStatus("check-2776", "done") }

        XCTAssertNil(harness.pane.rowViews[key], "folded at once")
        XCTAssertEqual(harness.doneGroup(section: doneSection)?.count, count + 1)
        assertNothingPending(harness, "an off-screen fold is not deferred")
        let after = harness.pane.anchorSnapshot(windowIndex: 0)
        XCTAssertEqual(after.firstVisible?.rowKey, before.firstVisible?.rowKey)
        XCTAssertEqual(after.firstVisible?.offsetPt ?? .infinity, before.firstVisible?.offsetPt ?? 0, accuracy: 1)
    }

    // MARK: - PRD 18b: moved

    private let movedItem = "audit-1407"        // second item of Next, moved to Findings

    /// The viewport top sits inside the Next heading, so the whole section is on screen.
    private func onScreenMoveSetup() throws -> (harness: TrackerGateHarness, key: String, frame: CGRect, nextKey: String, nextTop: CGFloat) {
        let harness = try makeHarness(.top)
        try harness.scroll(toRow: "section:next", offset: 10)
        let key = TrackerRow.itemKey(movedItem)
        XCTAssertTrue(harness.pane.visibleKeys().contains(key), "setup: \(key) is on screen")
        let frame = try XCTUnwrap(harness.frame(of: key))
        let keys = harness.displayedKeys
        let index = try XCTUnwrap(keys.firstIndex(of: key))
        let nextKey = keys[index + 1]
        let nextTop = try XCTUnwrap(harness.frame(of: nextKey)).minY
        return (harness, key, frame, nextKey, nextTop)
    }

    func testAnOnScreenItemMovedToAnotherSectionLeavesAMovedToStubAndAppearsInTheNewSectionAtOnce() throws {
        let (harness, key, frame, nextKey, nextTop) = try onScreenMoveSetup()
        let before = harness.pane.anchorSnapshot(windowIndex: 0)

        try harness.mutate { try $0.moveItem(movedItem, toSection: "findings") }

        // The stub holds the old place.
        let stub = try XCTUnwrap(harness.pane.rowViews[key], "a stub keeps the item's place")
        XCTAssertTrue(stub.visibleText.contains("moved to Findings"), "stub reads: \(stub.visibleText)")
        XCTAssertEqual(stub.frame.minY, frame.minY, accuracy: 0.5, "the stub is where the item was")
        XCTAssertGreaterThanOrEqual(stub.frame.height, frame.height - 0.5, "the stub is at least as tall as the item")
        let nextNow = try XCTUnwrap(harness.frame(of: nextKey)).minY
        XCTAssertEqual(nextNow, nextTop, accuracy: 1, "rows below the stub did not move")
        // The item is in its new section now.
        XCTAssertNotNil(harness.pane.rowViews["moving:\(movedItem)"], "the item appears in the new section at once")
        let keys = harness.displayedKeys
        let findings = try XCTUnwrap(keys.firstIndex(of: "section:findings"))
        let moving = try XCTUnwrap(keys.firstIndex(of: "moving:\(movedItem)"))
        let looseEnds = try XCTUnwrap(keys.firstIndex(of: "section:loose-ends"))
        XCTAssertTrue(findings < moving && moving < looseEnds, "the live copy is inside Findings")
        let live = try XCTUnwrap(harness.pane.displayedRows.first { $0.key == "moving:\(movedItem)" })
        if case .item(let item) = live.content {
            XCTAssertEqual(item.sectionId, "findings")
        } else {
            XCTFail("the live copy is an item row")
        }
        assertPending(harness, key, "moved")
        let after = harness.pane.anchorSnapshot(windowIndex: 0)
        XCTAssertEqual(after.firstVisible?.rowKey, before.firstVisible?.rowKey)
        XCTAssertEqual(after.firstVisible?.offsetPt ?? .infinity, before.firstVisible?.offsetPt ?? 0, accuracy: 1)
    }

    func testAMovedItemsStubConvergesWithinAPointOnceItScrollsOffScreen() throws {
        let (harness, key, _, _, _) = try onScreenMoveSetup()
        try harness.mutate { try $0.moveItem(movedItem, toSection: "findings") }
        let stubFrame = try XCTUnwrap(harness.frame(of: key))
        assertPending(harness, key, "moved")

        let top = stubFrame.maxY + 3
        let expected = try XCTUnwrap(harness.expectedFirstVisible(atScrollY: top))
        harness.scrollUser(to: top)

        assertNothingPending(harness, "the stub has gone")
        XCTAssertFalse(harness.displayedKeys.contains { $0.hasPrefix("moving:") }, "no temporary row is left")
        let row = try XCTUnwrap(harness.pane.rowViews[key], "the item is shown in its new section")
        XCTAssertFalse(row.visibleText.contains("moved to"), "it is the item, not the stub: \(row.visibleText)")
        let keys = harness.displayedKeys
        let findings = try XCTUnwrap(keys.firstIndex(of: "section:findings"))
        let item = try XCTUnwrap(keys.firstIndex(of: key))
        let looseEnds = try XCTUnwrap(keys.firstIndex(of: "section:loose-ends"))
        XCTAssertTrue(findings < item && item < looseEnds, "the item sits in Findings")
        assertFirstVisible(harness, is: expected, "the stub's release")
    }

    private func assertOffScreenMoveAppliesAtOnce(viewportAtBottom: Bool, line: UInt = #line) throws {
        let harness = try makeHarness(.top)
        if viewportAtBottom { harness.scrollToBottom() }
        let item = try harness.requireItem(viewportAtBottom ? .above : .below) { $0.sectionId == "next" }
        let key = TrackerRow.itemKey(item.id)
        XCTAssertFalse(harness.pane.visibleKeys().contains(key), "setup: off screen", line: line)
        let before = harness.pane.anchorSnapshot(windowIndex: 0)

        try harness.mutate { try $0.moveItem(item.id, toSection: "findings") }

        assertNothingPending(harness, "an off-screen move is not deferred")
        XCTAssertFalse(harness.displayedKeys.contains { $0.hasPrefix("moving:") }, "no temporary row", line: line)
        let keys = harness.displayedKeys
        let findings = try XCTUnwrap(keys.firstIndex(of: "section:findings"))
        let moved = try XCTUnwrap(keys.firstIndex(of: key), "the item is in its new section")
        let looseEnds = try XCTUnwrap(keys.firstIndex(of: "section:loose-ends"))
        XCTAssertTrue(findings < moved && moved < looseEnds, "the item sits in Findings", line: line)
        XCTAssertFalse(harness.pane.rowViews[key]?.visibleText.contains("moved to") ?? true, "no stub", line: line)
        let after = harness.pane.anchorSnapshot(windowIndex: 0)
        XCTAssertEqual(after.firstVisible?.rowKey, before.firstVisible?.rowKey, line: line)
        XCTAssertEqual(after.firstVisible?.offsetPt ?? .infinity, before.firstVisible?.offsetPt ?? 0, accuracy: 1, line: line)
    }

    func testAnItemMovedWhileAboveTheViewportMovesAtOnce() throws {
        try assertOffScreenMoveAppliesAtOnce(viewportAtBottom: true)
    }

    func testAnItemMovedWhileBelowTheViewportMovesAtOnce() throws {
        try assertOffScreenMoveAppliesAtOnce(viewportAtBottom: false)
    }

    // MARK: - PRD 18c: removed

    private let removedItem = "check-1444"      // third item of Next, with a note (a tall row)

    private func onScreenRemoveSetup() throws -> (harness: TrackerGateHarness, key: String, frame: CGRect, nextKey: String, nextTop: CGFloat) {
        let harness = try makeHarness(.top)
        try harness.scroll(toRow: "section:next", offset: 10)
        let key = TrackerRow.itemKey(removedItem)
        XCTAssertTrue(harness.pane.visibleKeys().contains(key), "setup: \(key) is on screen")
        let frame = try XCTUnwrap(harness.frame(of: key))
        let keys = harness.displayedKeys
        let index = try XCTUnwrap(keys.firstIndex(of: key))
        let nextKey = keys[index + 1]
        let nextTop = try XCTUnwrap(harness.frame(of: nextKey)).minY
        return (harness, key, frame, nextKey, nextTop)
    }

    func testAnOnScreenRemovedItemLeavesAMutedRemovedStubOfTheSameHeight() throws {
        let (harness, key, frame, nextKey, nextTop) = try onScreenRemoveSetup()
        let before = harness.pane.anchorSnapshot(windowIndex: 0)

        try harness.mutate { try $0.removeItem(removedItem) }

        let stub = try XCTUnwrap(harness.pane.rowViews[key], "a stub keeps the item's place")
        XCTAssertEqual(stub.visibleText, "removed")
        let color = stub.textViews.first?.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, TrackerTheme.muted, "the stub is muted")
        assertSameFrame(stub.frame, frame, "the stub keeps the item's frame and height")
        let nextNow = try XCTUnwrap(harness.frame(of: nextKey)).minY
        XCTAssertEqual(nextNow, nextTop, accuracy: 1, "rows below the stub did not move")
        assertPending(harness, key, "removed")
        let after = harness.pane.anchorSnapshot(windowIndex: 0)
        XCTAssertEqual(after.firstVisible?.rowKey, before.firstVisible?.rowKey)
        XCTAssertEqual(after.firstVisible?.offsetPt ?? .infinity, before.firstVisible?.offsetPt ?? 0, accuracy: 1)
    }

    func testARemovedItemsStubGoesOnceItScrollsOffScreenWithinAPointOfDrift() throws {
        let (harness, key, frame, _, _) = try onScreenRemoveSetup()
        try harness.mutate { try $0.removeItem(removedItem) }
        assertPending(harness, key, "removed")

        let top = frame.maxY + 3
        let expected = try XCTUnwrap(harness.expectedFirstVisible(atScrollY: top))
        harness.scrollUser(to: top)

        XCTAssertNil(harness.pane.rowViews[key], "the stub is gone")
        XCTAssertFalse(harness.displayedKeys.contains(key))
        assertNothingPending(harness, "nothing is held")
        assertFirstVisible(harness, is: expected, "the stub's release")
    }

    private func assertOffScreenRemoveAppliesAtOnce(viewportAtBottom: Bool, line: UInt = #line) throws {
        let harness = try makeHarness(.top)
        if viewportAtBottom { harness.scrollToBottom() }
        let item = try harness.requireItem(viewportAtBottom ? .above : .below) { $0.sectionId == "findings" }
        let key = TrackerRow.itemKey(item.id)
        XCTAssertFalse(harness.pane.visibleKeys().contains(key), "setup: off screen", line: line)
        let before = harness.pane.anchorSnapshot(windowIndex: 0)

        try harness.mutate { try $0.removeItem(item.id) }

        XCTAssertNil(harness.pane.rowViews[key], "removed at once, no stub", line: line)
        assertNothingPending(harness, "an off-screen removal is not deferred")
        let after = harness.pane.anchorSnapshot(windowIndex: 0)
        XCTAssertEqual(after.firstVisible?.rowKey, before.firstVisible?.rowKey, line: line)
        XCTAssertEqual(after.firstVisible?.offsetPt ?? .infinity, before.firstVisible?.offsetPt ?? 0, accuracy: 1, line: line)
    }

    func testAnItemRemovedWhileAboveTheViewportGoesAtOnce() throws {
        try assertOffScreenRemoveAppliesAtOnce(viewportAtBottom: true)
    }

    func testAnItemRemovedWhileBelowTheViewportGoesAtOnce() throws {
        try assertOffScreenRemoveAppliesAtOnce(viewportAtBottom: false)
    }

    // MARK: - T3b2: add, keyboard move, drop and remove (and the remove banner) never move the reading line

    private enum StructureStart { case mid, top }

    /// A 360 x 600 pane beside a fake daemon over the golden board, Now cut to five items (so its add row is on
    /// screen at the top of the board) and Next's third item open on a three-paragraph note (a tall row to read).
    /// `mid`: the viewport top is 2 pt into that tall row, with Now, Next's first two items and the headings above it.
    private func structureHarness(_ start: StructureStart, file: StaticString = #filePath, line: UInt = #line) throws -> TrackerEditHarness {
        let h = try TrackerEditHarness(self, size: NSSize(width: 360, height: 600), configure: { script in
            for id in ["close-1185", "repro-1222", "triag-1259", "docum-1296", "backf-1333"] { try script.removeItem(id) }
            try script.setNote("check-1444", paragraphs: (1...3).map {
                "Paragraph \($0) of a note that is long enough to wrap over two lines at the width of the pane, so the row is tall."
            })
        }, file: file, line: line)
        h.pane.toggleNote(item: "check-1444")
        h.rig.settle()
        switch start {
        case .top:
            h.rig.scroll(to: 0)
        case .mid:
            h.rig.scroll(to: try XCTUnwrap(h.pane.rowViews["item:check-1444"], file: file, line: line).frame.minY + 2)
        }
        let anchor = h.pane.anchorSnapshot(windowIndex: 0)
        switch start {
        case .top:
            XCTAssertEqual(anchor.scrollY, 0, accuracy: 0.5, "setup: at the very top", file: file, line: line)
        case .mid:
            XCTAssertEqual(anchor.firstVisible?.rowKey, "item:check-1444", "setup: reading the tall row", file: file, line: line)
            XCTAssertEqual(anchor.firstVisible?.offsetPt ?? -1, 2, accuracy: 0.5, "setup: 2 pt into it", file: file, line: line)
            XCTAssertGreaterThan(anchor.scrollY, 100, "setup: scrolled into the board", file: file, line: line)
            XCTAssertGreaterThan(try XCTUnwrap(h.pane.rowViews["item:check-1444"]).frame.height, TrackerNoticeView.height + 20,
                                 "setup: tall enough to stay the first row when the notice shifts it", file: file, line: line)
        }
        XCTAssertEqual(h.pane.notice.preferredHeight, 0, "setup: no notice", file: file, line: line)
        return h
    }

    /// One thing the user (or the daemon answering them) does, and how far the notice slot grows (or shrinks) because of it.
    private struct StructureEvent {
        let name: String
        let chromeShift: CGFloat
        let run: () throws -> Void
    }

    /// Run `event`; afterwards the row that was first on screen is still the first row on screen, and the viewport
    /// top is as far into it as it was, EXCEPT where the notice slot changed height: then the viewport top went
    /// down the document by exactly the notice's height, so the line being read did not move on screen. At the very
    /// top of the board nothing shifts at all.
    private func assertTheReadingLineStays(_ h: TrackerEditHarness, _ start: StructureStart, _ event: StructureEvent,
                                          file: StaticString = #filePath, line: UInt = #line) {
        let before = h.pane.anchorSnapshot(windowIndex: 0)
        guard let first = before.firstVisible else { return XCTFail("\(event.name): no first visible row", file: file, line: line) }
        let rowView = h.pane.rowViews[first.rowKey]
        let screenBefore = rowView.map { h.pane.convert($0.bounds, from: $0).minY }
        let docTopBefore = rowView?.frame.minY
        let chromeBefore = h.pane.scrollView.frame.minY
        do {
            try event.run()
        } catch {
            return XCTFail("\(event.name): \(error)", file: file, line: line)
        }
        h.rig.settle()
        let after = h.pane.anchorSnapshot(windowIndex: 0)
        let shift = h.pane.scrollView.frame.minY - chromeBefore
        XCTAssertEqual(shift, event.chromeShift, accuracy: 0.5, "\(event.name): how far the notice slot grew", file: file, line: line)
        XCTAssertEqual(after.firstVisible?.rowKey, first.rowKey, "\(event.name): the first visible row is the same row", file: file, line: line)
        switch start {
        case .top:
            XCTAssertEqual(after.scrollY, 0, accuracy: 0.5, "\(event.name): still at the very top", file: file, line: line)
            XCTAssertEqual(after.firstVisible?.offsetPt ?? .infinity, first.offsetPt, accuracy: 1,
                           "\(event.name): at the top nothing shifts, even where the notice appeared", file: file, line: line)
        case .mid:
            XCTAssertEqual(after.firstVisible?.offsetPt ?? .infinity, first.offsetPt + Double(event.chromeShift), accuracy: 1,
                           "\(event.name): the offset into the first row moved by the notice height (\(event.chromeShift)) and nothing more",
                           file: file, line: line)
            // The scroll position follows the notice (28 pt) and, when rows above the reading line came or went, the
            // height they added or took away: the row being read is where it was on screen.
            let aboveDelta = Double((h.pane.rowViews[first.rowKey]?.frame.minY ?? 0) - (docTopBefore ?? 0))
            XCTAssertEqual(after.scrollY, before.scrollY + Double(event.chromeShift) + aboveDelta, accuracy: 1,
                           "\(event.name): the scroll position compensates for the notice height and for rows added or removed above",
                           file: file, line: line)
            if let rowView, let screenBefore {
                XCTAssertEqual(h.pane.convert(rowView.bounds, from: rowView).minY, screenBefore, accuracy: 1,
                               "\(event.name): the line being read did not move on screen", file: file, line: line)
            }
        }
    }

    private func runStructureEvents(_ start: StructureStart, file: StaticString = #filePath, line: UInt = #line,
                                    _ events: (TrackerEditHarness) throws -> [StructureEvent]) throws {
        let h = try structureHarness(start, file: file, line: line)
        for event in try events(h) { assertTheReadingLineStays(h, start, event, file: file, line: line) }
    }

    private func newItem(_ id: String, _ section: String, _ text: String) -> TrackerBoardScript.Obj {
        TrackerBoardScript.newItemNode(id: id, section: section, text: text)
    }

    private func addEvents(_ h: TrackerEditHarness, section: String, after last: String) -> [StructureEvent] {
        let key = TrackerRow.addKey(section)
        func row() throws -> TrackerRowView { try XCTUnwrap(h.pane.rowViews[key], "no \(key)") }
        func field() throws -> TrackerTitleEditor { try XCTUnwrap(try row().addField, "the add field is not open") }
        return [
            StructureEvent(name: "add: the add row opens its field", chromeShift: 0) {
                try XCTUnwrap(try row().addItemButton).performClick(nil)
            },
            StructureEvent(name: "add: a title is typed", chromeShift: 0) { h.type("A brand new item", into: try field()) },
            StructureEvent(name: "add: Return sends it and the field waits, dimmed", chromeShift: 0) { h.pressReturn(in: try field()) },
            StructureEvent(name: "add: the daemon's board has the new row (inserted at once, no deferral)", chromeShift: 0) {
                try h.echo({ try $0.insert(self.newItem("gate-new-1", section, "A brand new item"), section: section, after: last) },
                           created: ["gate-new-1"])
            },
            StructureEvent(name: "add: Esc closes the field", chromeShift: 0) { h.pressEscape(in: try field()) },
        ]
    }

    func testAddingAnItemFromTheAddRowNeverMovesTheReadingLineMidBoard() throws {
        try runStructureEvents(.mid) { h in addEvents(h, section: "next", after: "triag-1703") }
    }

    func testAddingAnItemFromTheAddRowNeverMovesTheReadingLineAtTheTop() throws {
        try runStructureEvents(.top) { h in addEvents(h, section: "now", after: "draft-1148") }
    }

    func testAnAddThatLandsAboveTheReadingLineLeavesTheLineWhereItWasMidBoard() throws {
        // The user opened the field, scrolled down, and the daemon's board puts the new row above the viewport.
        let h = try structureHarness(.mid)
        let field = try { () throws -> TrackerTitleEditor in
            let row = try XCTUnwrap(h.pane.rowViews[TrackerRow.addKey("now")])
            row.addItemButton?.performClick(nil)
            return try XCTUnwrap(row.addField)
        }()
        h.type("Added above the viewport", into: field)
        h.pressReturn(in: field)
        h.rig.scroll(to: try XCTUnwrap(h.pane.rowViews["item:check-1444"]).frame.minY + 2)
        let events = [
            StructureEvent(name: "add: the new row lands above the viewport", chromeShift: 0) {
                try h.echo({ try $0.insert(self.newItem("gate-new-2", "now", "Added above the viewport"), section: "now", after: "draft-1148") },
                           created: ["gate-new-2"])
            },
        ]
        for event in events { assertTheReadingLineStays(h, .mid, event) }
        XCTAssertNotNil(h.pane.rowViews["item:gate-new-2"], "the row is there")
    }

    // Keyboard move (the Move pull-down, the menu and VoiceOver all call `moveItem`).

    private func moveEvents(_ h: TrackerEditHarness, down id: String, after neighbour: String, section: String) -> [StructureEvent] {
        [
            StructureEvent(name: "keyboard move: Move Down sends the move", chromeShift: 0) { h.pane.moveItem(id, .down) },
            StructureEvent(name: "keyboard move: the daemon's board, applied at once", chromeShift: 0) {
                try h.echo { try $0.place(id, section: section, after: neighbour) }
            },
        ]
    }

    func testAKeyboardMoveNeverMovesTheReadingLineMidBoard() throws {
        try runStructureEvents(.mid) { h in
            let toSectionAbove = StructureEvent(name: "keyboard move: to the section above the viewport, the row lands above the reading line", chromeShift: 0) {
                h.pane.moveItem("close-1629", .toSection("now"))
                try h.echo { try $0.place("close-1629", section: "now") }
            }
            return moveEvents(h, down: "draft-1592", after: "close-1629", section: "next") + [toSectionAbove]
        }
    }

    func testAKeyboardMoveNeverMovesTheReadingLineAtTheTop() throws {
        try runStructureEvents(.top) { h in moveEvents(h, down: "retry-1074", after: "revie-1111", section: "now") }
    }

    // Drop.

    private func dropEvents(_ h: TrackerEditHarness, drag id: String, over key: String, after neighbour: String, section: String) -> [StructureEvent] {
        func point() throws -> NSPoint {
            let frame = try XCTUnwrap(h.pane.rowViews[key]?.frame, "no row \(key)")
            return NSPoint(x: frame.midX, y: frame.minY + 3)
        }
        let payload = (id: id, pane: h.pane.paneIdentity)
        return [
            StructureEvent(name: "drop: the drag begins", chromeShift: 0) { h.pane.dragBegan() },
            StructureEvent(name: "drop: the pointer is over a row (the line shows)", chromeShift: 0) {
                XCTAssertEqual(h.pane.dragMoved(payload: payload, at: try point()), .move)
                XCTAssertFalse(h.pane.dropIndicator.isHidden)
            },
            StructureEvent(name: "drop: dropped (the move is sent)", chromeShift: 0) {
                XCTAssertTrue(h.pane.dragDropped(payload: payload, at: try point()))
            },
            StructureEvent(name: "drop: the drag ends", chromeShift: 0) { h.pane.dragEnded() },
            StructureEvent(name: "drop: the daemon's board, applied at once", chromeShift: 0) {
                XCTAssertEqual(h.sent.last?.ops, [.move(id: id, section: section, before: nil, after: neighbour)])
                try h.echo { try $0.place(id, section: section, after: neighbour) }
            },
        ]
    }

    func testADropNeverMovesTheReadingLineMidBoard() throws {
        try runStructureEvents(.mid) { h in
            dropEvents(h, drag: "verif-1481", over: "item:revie-1555", after: "retry-1518", section: "next")
        }
    }

    func testADropNeverMovesTheReadingLineAtTheTop() throws {
        try runStructureEvents(.top) { h in
            dropEvents(h, drag: "verif-1037", over: "item:draft-1148", after: "revie-1111", section: "now")
        }
    }

    func testADragInProgressMovesNothingNeitherRowsNorTheScrollPosition() throws {
        for start in [StructureStart.mid, .top] {
            let h = try structureHarness(start)
            let frames = h.rig.rowFrames
            let before = h.pane.anchorSnapshot(windowIndex: 0)
            let payload = (id: "verif-1037", pane: h.pane.paneIdentity)
            h.pane.dragBegan()
            for key in ["item:retry-1074", "section:next", "add:now", "item:draft-1148", "done:findings"] {
                guard let frame = h.pane.rowViews[key]?.frame else { continue }
                _ = h.pane.dragMoved(payload: payload, at: NSPoint(x: frame.midX, y: frame.minY + 3))
                _ = h.pane.dragMoved(payload: payload, at: NSPoint(x: frame.midX, y: frame.maxY - 3))
                h.rig.settle()
                let after = h.pane.anchorSnapshot(windowIndex: 0)
                XCTAssertEqual(h.rig.rowFrames, frames, "\(start): no row moved or changed size over \(key)")
                XCTAssertEqual(after.scrollY, before.scrollY, accuracy: 0.01, "\(start): the scroll position over \(key)")
                XCTAssertEqual(after.firstVisible, before.firstVisible, "\(start): the reading line over \(key)")
                XCTAssertEqual(after.documentHeight, before.documentHeight, accuracy: 0.01, "\(start): the document's height over \(key)")
            }
            h.pane.dragExited()
            XCTAssertEqual(h.rig.rowFrames, frames, "\(start): leaving the pane moved nothing")
            h.pane.dragEnded()
            XCTAssertEqual(h.rig.rowFrames, frames, "\(start): ending the drag moved nothing")
            XCTAssertEqual(h.pane.anchorSnapshot(windowIndex: 0).scrollY, before.scrollY, accuracy: 0.01, "\(start)")
            XCTAssertTrue(h.sent.isEmpty, "\(start): a drag that is not dropped sends nothing")
        }
    }

    // Remove, and the banner coming and going. The notice slot is 28 pt: the line being read stays still on
    // screen by the viewport moving down the document by that much (mid-board), and at the very top nothing shifts.

    private func removeEvents(_ h: TrackerEditHarness, remove first: String, then second: String,
                              firstTitle: String) -> [StructureEvent] {
        func expire() { h.rig.scheduler.scheduled.filter { $0.delay == TrackerPaneView.removalBannerLifetime }.forEach { $0.work() } }
        let sourceTitle = firstTitle
        return [
            StructureEvent(name: "remove: Remove sends it and the banner appears", chromeShift: TrackerNoticeView.height) {
                h.pane.removeItem(first)
                XCTAssertEqual(h.pane.notice.text, "Removed “\(sourceTitle)”.")
            },
            StructureEvent(name: "remove: the daemon's board, the row goes at once (no stub)", chromeShift: 0) {
                try h.echo { try $0.removeItem(first) }
                XCTAssertNil(h.pane.rowViews["item:\(first)"])
            },
            StructureEvent(name: "remove: a second removal replaces the banner (same height)", chromeShift: 0) {
                h.pane.removeItem(second)
                try h.echo { try $0.removeItem(second) }
            },
            StructureEvent(name: "remove: the banner goes after 10 s", chromeShift: -TrackerNoticeView.height) {
                expire()
                XCTAssertNil(h.pane.notice.text)
            },
        ]
    }

    func testRemovingItemsAndTheBannerComingAndGoingMoveTheReadingLineByExactlyTheNoticeHeightMidBoard() throws {
        XCTAssertEqual(TrackerNoticeView.height, 28, "the notice slot is 28 pt as designed")
        try runStructureEvents(.mid) { h in
            removeEvents(h, remove: "revie-1555", then: "repro-1666", firstTitle: "Review invoice batch")
        }
    }

    func testRemovingItemsAndTheBannerComingAndGoingMoveNothingAtTheTop() throws {
        try runStructureEvents(.top) { h in
            removeEvents(h, remove: "revie-1111", then: "draft-1148", firstTitle: "Review queue job 8812")
        }
    }

    func testTheBannersUndoTakesTheBannerAwayAndTheRestoreLandsWithoutMovingTheReadingLine() throws {
        for start in [StructureStart.mid, .top] {
            let h = try structureHarness(start)
            let id = start == .mid ? "revie-1555" : "revie-1111"
            let section = start == .mid ? "next" : "now"
            let node = try XCTUnwrap(h.script.item(id))
            let events = [
                StructureEvent(name: "undo: Remove", chromeShift: TrackerNoticeView.height) { h.pane.removeItem(id) },
                StructureEvent(name: "undo: the board without the row", chromeShift: 0) { try h.echo { try $0.removeItem(id) } },
                StructureEvent(name: "undo: the banner's Undo sends the restore and the banner goes", chromeShift: -TrackerNoticeView.height) {
                    try XCTUnwrap(h.pane.notice.actionButton).performClick(nil)
                },
                StructureEvent(name: "undo: the board with the item back", chromeShift: 0) {
                    guard case .restore(_, let into, let before, let after)? = h.sent.last?.ops.first else {
                        return XCTFail("no restore was sent: \(h.sent)")
                    }
                    XCTAssertEqual(into, section)
                    try h.echo({ try $0.insert(node, section: into, before: before, after: after) }, created: [id])
                },
            ]
            for event in events { assertTheReadingLineStays(h, start, event) }
        }
    }

    func testARemovalAboveTheReadingLineAndItsBannerLeaveTheLineWhereItWasMidBoard() throws {
        // VoiceOver can act on a row that is scrolled out of view: the row above goes, the rows under it move up,
        // and the line being read stays where it is on screen (the viewport moves up the document by the row's height).
        try runStructureEvents(.mid) { h in
            [
                StructureEvent(name: "remove above: Remove on a row above the viewport; the banner appears", chromeShift: TrackerNoticeView.height) {
                    h.pane.removeItem("audit-1407")
                },
                StructureEvent(name: "remove above: the board without it, applied at once", chromeShift: 0) {
                    try h.echo { try $0.removeItem("audit-1407") }
                    XCTAssertNil(h.pane.rowViews["item:audit-1407"])
                },
            ]
        }
    }
}
