import XCTest
import AppKit
import Combine

// Behavioural spec for Fred's native surface (slice F0): an Inbox pane and a Today pane
// rendered from `MailboxSnapshot` / `CalendarSnapshot`.
//
// The view is driven only through its public API (`model`, `refreshClock()`) and observed
// only through accessibility identifiers, visible text, and accessibility labels. Time is
// injected (a captured clock the tests advance), the pasteboard is a private named one,
// and the time zone is injected, so nothing here reads the wall clock, the general
// pasteboard, or the machine's display setup. No test depends on the view's 30 s timer.
//
// Fixtures: "today" is 2026-10-10 in America/Chicago (CDT, UTC-5). The default clock is
// 09:18, i.e. 12 minutes before the 09:30 "Eng sync".

final class FredSurfaceViewTests: XCTestCase {

    // MARK: - Identifiers

    private let inboxTable = "fred.inbox.table"
    private let todayTable = "fred.today.table"

    // MARK: - Clock, time zone, lifecycle

    private final class Clock { var now: Date; init(_ now: Date) { self.now = now } }

    private static let chicago = TimeZone(identifier: "America/Chicago")!

    /// A moment on 2026-10-10 in Chicago. "HH:mm" or "HH:mm:ss".
    private static func at(_ hms: String, day: Int = 10) -> Date {
        let p = hms.split(separator: ":").compactMap { Int($0) }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = chicago
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = day
        c.hour = p[0]; c.minute = p[1]; c.second = p.count > 2 ? p[2] : 0
        return cal.date(from: c)!
    }
    private func at(_ hms: String) -> Date { Self.at(hms) }

    private let clock = Clock(FredSurfaceViewTests.at("09:18"))
    private var now: Date {
        get { clock.now }
        set { clock.now = newValue }
    }

    private var pasteboard: NSPasteboard!
    private var window: NSWindow?
    private var sut: FredSurfaceView!

    /// Stands in for the surface's repeating and one-shot timers. Nothing here waits on a
    /// wall clock: tests fire jobs by hand.
    private final class FakeScheduler {
        final class Job {
            let interval: TimeInterval
            let repeats: Bool
            let action: () -> Void
            var cancelled = false
            var consumed = false
            init(interval: TimeInterval, repeats: Bool, action: @escaping () -> Void) {
                self.interval = interval; self.repeats = repeats; self.action = action
            }
        }

        private(set) var jobs: [Job] = []

        var scheduler: FredScheduler {
            FredScheduler(
                every: { [unowned self] interval, action in self.register(interval, repeats: true, action) },
                after: { [unowned self] interval, action in self.register(interval, repeats: false, action) })
        }

        private func register(_ interval: TimeInterval, repeats: Bool, _ action: @escaping () -> Void) -> AnyCancellable {
            let job = Job(interval: interval, repeats: repeats, action: action)
            jobs.append(job)
            return AnyCancellable { job.cancelled = true }
        }

        var activeEvery: [Job] { jobs.filter { $0.repeats && !$0.cancelled } }
        var activeAfter: [Job] { jobs.filter { !$0.repeats && !$0.cancelled && !$0.consumed } }
        var allAfter: [Job] { jobs.filter { !$0.repeats } }

        /// One 30 s period elapses for every live repeating job.
        func tickAll() { activeEvery.forEach { $0.action() } }

        /// Run `job` even if it was cancelled: a timer that was already dispatched when it was
        /// cancelled can still deliver its callback.
        func fire(_ job: Job) {
            job.consumed = true
            job.action()
        }

        /// Run every live one-shot job.
        func fireAfter() { activeAfter.forEach(fire) }
    }

    private let fakeScheduler = FakeScheduler()

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("fred-test-\(UUID().uuidString)"))
    }

    override func tearDown() {
        window?.contentView = nil
        window = nil
        sut = nil
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    @discardableResult
    private func makeView(mailbox: MailboxSnapshot? = nil,
                          calendar: CalendarSnapshot? = nil,
                          isConnected: Bool = true,
                          timeZone: TimeZone = FredSurfaceViewTests.chicago,
                          detail: FredDetailActions? = nil) -> FredSurfaceView {
        let clock = self.clock
        let view = FredSurfaceView(
            model: FredSurfaceModel(mailbox: mailbox, calendar: calendar, isConnected: isConnected),
            clock: { clock.now },
            pasteboard: pasteboard,
            timeZone: timeZone,
            scheduler: fakeScheduler.scheduler,
            detail: detail)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 420),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = view
        view.layoutSubtreeIfNeeded()
        window = w
        sut = view
        return view
    }

    private func render(mailbox: MailboxSnapshot? = nil, calendar: CalendarSnapshot? = nil, isConnected: Bool = true) {
        sut.model = FredSurfaceModel(mailbox: mailbox, calendar: calendar, isConnected: isConnected)
        sut.layoutSubtreeIfNeeded()
    }

    private func advance(to date: Date) {
        now = date
        sut.refreshClock()
        sut.layoutSubtreeIfNeeded()
    }

    // MARK: - Snapshot builders (decode JSON, as the app does)

    private let isoOut: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func decode<T: Decodable>(_ type: T.Type, _ object: [String: Any]) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: object)
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(T.self, from: data)
    }

    private func decode<T: Decodable>(_ type: T.Type, json: String) throws -> T {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(T.self, from: Data(json.utf8))
    }

    private struct Prompt {
        var uri = "https://microsoft.com/devicelogin"
        var code = "ABCD-EFGH"
        var expires: Date
    }

    private func promptJSON(_ p: Prompt) -> [String: Any] {
        ["verification_uri": p.uri, "user_code": p.code, "expires_at": isoOut.string(from: p.expires)]
    }

    /// The Outlook link a list item carries.
    private enum Link {
        /// `https://outlook.office.com/m/<index>` (mail) or `/e/<index>` (events).
        case standard
        case absent
        case custom(String)
    }

    private struct Mail {
        var from: String
        var subject: String
        /// Seconds before the clock at build time.
        var ago: TimeInterval = 600
        var vip = false
        var invite = false
        var read = false
        /// Defaults to `m-<index>`.
        var id: String?
        var link: Link = .standard
    }

    private func mailbox(state: String? = "fresh",
                         unread: Int? = nil,
                         items: [Mail] = [],
                         stale: Bool = false,
                         error: String? = nil,
                         updatedAt: Date? = nil,
                         retryAt: Date? = nil,
                         prompt: Prompt? = nil) throws -> MailboxSnapshot {
        var obj: [String: Any] = [
            "generated_at": isoOut.string(from: now),
            "unread_count": unread ?? items.filter { !$0.read }.count,
            "stale": stale,
            "items": items.enumerated().map { i, m -> [String: Any] in
                var o: [String: Any] = [
                    "id": m.id ?? "m-\(i)",
                    "from": m.from,
                    "subject": m.subject,
                    "received_at": isoOut.string(from: now.addingTimeInterval(-m.ago)),
                    "vip": m.vip,
                    "is_invite": m.invite,
                    "is_read": m.read]
                switch m.link {
                case .standard: o["web_link"] = "https://outlook.office.com/m/\(i)"
                case .absent: break
                case .custom(let url): o["web_link"] = url
                }
                return o
            },
        ]
        if let state { obj["state"] = state }
        if let error { obj["error"] = error }
        if let updatedAt { obj["updated_at"] = isoOut.string(from: updatedAt) }
        if let retryAt { obj["retry_at"] = isoOut.string(from: retryAt) }
        if let prompt { obj["auth_prompt"] = promptJSON(prompt) }
        return try decode(MailboxSnapshot.self, obj)
    }

    private struct Ev {
        var title: String
        var start: Date
        var end: Date
        /// Written to both `status` and `response_status` (the wire carries the response there).
        var status = "accepted"
        var isAllDay: Bool?
        var isCancelled: Bool?
        /// Defaults to `e-<index>`.
        var id: String?
        var link: Link = .standard
    }

    private func calendar(state: String? = "fresh",
                          events: [Ev] = [],
                          stale: Bool = false,
                          error: String? = nil,
                          updatedAt: Date? = nil,
                          retryAt: Date? = nil,
                          prompt: Prompt? = nil) throws -> CalendarSnapshot {
        var obj: [String: Any] = [
            "sweater": "",
            "stale": stale,
            "events": events.enumerated().map { i, e -> [String: Any] in
                var o: [String: Any] = [
                    "id": e.id ?? "e-\(i)",
                    "start": isoOut.string(from: e.start),
                    "end": isoOut.string(from: e.end),
                    "title": e.title,
                    "status": e.status,
                    "response_status": e.status,
                    // The daemon's own flag is deliberately wrong: the view must use the clock.
                    "is_now": false,
                ]
                if let a = e.isAllDay { o["is_all_day"] = a }
                if let c = e.isCancelled { o["is_cancelled"] = c }
                switch e.link {
                case .standard: o["web_link"] = "https://outlook.office.com/e/\(i)"
                case .absent: break
                case .custom(let url): o["web_link"] = url
                }
                return o
            },
        ]
        if let state { obj["state"] = state }
        if let error { obj["error"] = error }
        if let updatedAt { obj["updated_at"] = isoOut.string(from: updatedAt) }
        if let retryAt { obj["retry_at"] = isoOut.string(from: retryAt) }
        if let prompt { obj["auth_prompt"] = promptJSON(prompt) }
        return try decode(CalendarSnapshot.self, obj)
    }

    private func ev(_ title: String, _ start: String, _ end: String, status: String = "accepted") -> Ev {
        Ev(title: title, start: at(start), end: at(end), status: status)
    }

    private var engSync: Ev { ev("Eng sync", "09:30", "10:00") }
    private var designReview: Ev { ev("Design review", "11:30", "12:30") }

    /// Three items, but 12 unread overall (the mailbox holds more than the daemon lists).
    private func inboxSample() throws -> MailboxSnapshot {
        try mailbox(unread: 12, items: [
            Mail(from: "Alice Smith <alice@x.com>", subject: "Q3 budget", ago: 5 * 60, vip: true),
            Mail(from: "Bob Jones <bob@x.com>", subject: "Lunch plans", ago: 2 * 3600),
            Mail(from: "carol@x.com", subject: "Weekly digest", ago: 30 * 3600, read: true),
        ])
    }

    // MARK: - View lookup helpers

    private func find(_ id: String, in root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == id { return root }
        for sub in root.subviews {
            if let hit = find(id, in: sub) { return hit }
        }
        return nil
    }

    private func requireView<V: NSView>(_ id: String, in root: NSView? = nil,
                                        file: StaticString = #filePath, line: UInt = #line) throws -> V {
        let base: NSView = root ?? sut
        let v = try XCTUnwrap(find(id, in: base), "no view with accessibility identifier \(id)", file: file, line: line)
        return try XCTUnwrap(v as? V, "\(id) is a \(type(of: v)), expected \(V.self)", file: file, line: line)
    }

    private func field(_ id: String, file: StaticString = #filePath, line: UInt = #line) throws -> NSTextField {
        try requireView(id, file: file, line: line)
    }

    private func banner(_ id: String, file: StaticString = #filePath, line: UInt = #line) throws -> SourceStateBanner {
        try requireView(id, file: file, line: line)
    }

    private func visible(_ v: NSView) -> Bool { !v.isHiddenOrHasHiddenAncestor }

    /// The banner's message when it is showing, `nil` when hidden.
    private func bannerMessage(_ id: String, file: StaticString = #filePath, line: UInt = #line) throws -> String? {
        let b = try banner(id, file: file, line: line)
        return b.isHidden ? nil : b.content?.message
    }

    /// A header/label's text.
    private func text(_ id: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        try field(id, file: file, line: line).stringValue
    }

    /// A label's text, or "" when it is not on screen.
    private func shownText(_ id: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let f = try field(id, file: file, line: line)
        return visible(f) ? f.stringValue : ""
    }

    private func isShown(_ id: String) -> Bool {
        guard let v = find(id, in: sut) else { return false }
        return visible(v)
    }

    private func rowCount(_ tableID: String, file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        let table: NSTableView = try requireView(tableID, file: file, line: line)
        return table.numberOfRows
    }

    private func rowView(_ tableID: String, _ row: Int, file: StaticString = #filePath, line: UInt = #line) throws -> NSView {
        let table: NSTableView = try requireView(tableID, file: file, line: line)
        return try XCTUnwrap(table.view(atColumn: 0, row: row, makeIfNecessary: true),
                             "\(tableID) has no cell at row \(row)", file: file, line: line)
    }

    private func rowField(_ tableID: String, _ row: Int, _ id: String,
                          file: StaticString = #filePath, line: UInt = #line) throws -> NSTextField {
        let cell = try rowView(tableID, row, file: file, line: line)
        return try requireView(id, in: cell, file: file, line: line)
    }

    private func rowLabel(_ tableID: String, _ row: Int, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        try rowView(tableID, row, file: file, line: line).accessibilityLabel() ?? ""
    }

    /// One string per row for the given cell identifier.
    private func column(_ tableID: String, _ id: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        let n = try rowCount(tableID, file: file, line: line)
        return try (0..<n).map { try rowField(tableID, $0, id, file: file, line: line).stringValue }
    }

    private func todayRow(_ title: String, file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        let titles = try column(todayTable, "fred.row.title", file: file, line: line)
        return try XCTUnwrap(titles.firstIndex(of: title), "no Today row titled \(title); rows: \(titles)", file: file, line: line)
    }

    /// Titles of the Today rows currently marked "Now".
    private func nowRows(file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        let n = try rowCount(todayTable, file: file, line: line)
        var out: [String] = []
        for r in 0..<n {
            let marker = try rowField(todayTable, r, "fred.row.now", file: file, line: line)
            if !marker.isHidden {
                XCTAssertEqual(marker.stringValue, "Now", file: file, line: line)
                out.append(try rowField(todayTable, r, "fred.row.title", file: file, line: line).stringValue)
            }
        }
        return out
    }

    /// Every string visible to a user (or, with `visibleOnly: false`, present at all) anywhere in the view.
    private func allText(visibleOnly: Bool = true) -> [String] {
        var out: [String] = []
        func walk(_ v: NSView) {
            if visibleOnly && v.isHidden { return }
            if let tf = v as? NSTextField { out.append(tf.stringValue) }
            if let b = v as? NSButton { out.append(b.title) }
            if let table = v as? NSTableView {
                for r in 0..<table.numberOfRows {
                    if let cell = table.view(atColumn: 0, row: r, makeIfNecessary: true) { walk(cell) }
                }
            }
            v.subviews.forEach(walk)
        }
        walk(sut)
        return out
    }

    private func stringOf(_ v: NSView) -> String? {
        if let t = v as? NSTextField { return t.stringValue }
        if let b = v as? NSButton { return b.title }
        return nil
    }

    private func attributedOf(_ v: NSView) -> NSAttributedString? {
        if let t = v as? NSTextField { return t.attributedStringValue }
        if let b = v as? NSButton { return b.attributedTitle }
        return nil
    }

    private func hasLink(_ s: NSAttributedString) -> Bool {
        var found = false
        s.enumerateAttribute(.link, in: NSRange(location: 0, length: s.length)) { value, _, _ in
            if value != nil { found = true }
        }
        return found
    }

    private func isBold(_ f: NSTextField) -> Bool {
        let attr = f.attributedStringValue
        let font = (attr.length > 0 ? attr.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil) ?? f.font
        guard let font else { return false }
        if font.fontDescriptor.symbolicTraits.contains(.bold) { return true }
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        let weight = (traits?[.weight] as? NSNumber)?.doubleValue ?? 0
        return weight >= Double(NSFont.Weight.semibold.rawValue)
    }

    private func contains(_ haystack: String, _ needle: String, caseInsensitive: Bool = false) -> Bool {
        haystack.range(of: needle, options: caseInsensitive ? [.caseInsensitive] : []) != nil
    }

    // MARK: - Inbox: ordering and header

    func testInboxListsUnreadFirstThenNewestFirstWithReadRowsAfter() throws {
        makeView(mailbox: try mailbox(items: [
            Mail(from: "Read Newest <a@x.com>", subject: "s1", ago: 5 * 60, read: true),
            Mail(from: "Unread Older <b@x.com>", subject: "s2", ago: 3600),
            Mail(from: "Unread Newest <c@x.com>", subject: "s3", ago: 20 * 60),
            Mail(from: "Read Older <d@x.com>", subject: "s4", ago: 7200, read: true),
        ]))
        XCTAssertEqual(try column(inboxTable, "fred.row.sender"),
                       ["Unread Newest", "Unread Older", "Read Newest", "Read Older"],
                       "unread rows come first (newest first), then read rows (newest first)")
        XCTAssertEqual(try column(inboxTable, "fred.row.subject"), ["s3", "s2", "s1", "s4"])
    }

    func testInboxHeaderShowsTheUnreadCountEvenWhenFewerItemsAreListed() throws {
        makeView(mailbox: try inboxSample())
        XCTAssertEqual(try text("fred.inbox.header"), "Inbox · 12 unread")
        XCTAssertEqual(try rowCount(inboxTable), 3)
    }

    func testInboxHeaderNeverShowsACountWhenTheCountCannotBeTrusted() throws {
        makeView()
        for state in ["loading", "unauthenticated", "error", "not_configured"] {
            render(mailbox: try mailbox(state: state, unread: 12, items: [], error: state == "error" ? "boom" : nil))
            XCTAssertEqual(try text("fred.inbox.header"), "Inbox", "state \(state) must not show a count")
        }
        render(mailbox: nil)
        XCTAssertEqual(try text("fred.inbox.header"), "Inbox", "no snapshot yet must not show a count")
    }

    func testInboxHeaderKeepsTheCountWhileStaleOrRateLimited() throws {
        let items = [Mail(from: "Alice <a@x.com>", subject: "Hi")]
        makeView(mailbox: try mailbox(state: "stale", unread: 12, items: items, stale: true,
                                      error: "timeout", updatedAt: now.addingTimeInterval(-600)))
        XCTAssertEqual(try text("fred.inbox.header"), "Inbox · 12 unread")
        render(mailbox: try mailbox(state: "rate_limited", unread: 12, items: items))
        XCTAssertEqual(try text("fred.inbox.header"), "Inbox · 12 unread")
    }

    // MARK: - Inbox: row content

    func testInboxSenderShowsTheDisplayNameOnlyOrTheRawStringWithoutAngleBrackets() throws {
        makeView(mailbox: try inboxSample())
        let senders = try column(inboxTable, "fred.row.sender")
        XCTAssertEqual(Set(senders), ["Alice Smith", "Bob Jones", "carol@x.com"])
    }

    func testInboxRowMarksUnreadVipAndInviteAsVisibleViewsAndInTheSpokenLabel() throws {
        makeView(mailbox: try mailbox(items: [
            Mail(from: "Alice Smith <alice@x.com>", subject: "Quarterly numbers", ago: 5 * 60, vip: true, invite: true),
        ]))
        XCTAssertEqual(try rowCount(inboxTable), 1)
        let dot: NSView = try requireView("fred.row.unread", in: try rowView(inboxTable, 0))
        XCTAssertFalse(dot.isHidden, "unread row shows the unread dot")
        let vip = try rowField(inboxTable, 0, "fred.row.vip")
        XCTAssertFalse(vip.isHidden)
        XCTAssertEqual(vip.stringValue, "VIP")
        let invite = try rowField(inboxTable, 0, "fred.row.invite")
        XCTAssertFalse(invite.isHidden)
        XCTAssertEqual(invite.stringValue, "Invite")

        let label = try rowLabel(inboxTable, 0)
        for word in ["Unread", "VIP", "Invite", "Alice Smith", "Quarterly numbers", "5 min ago"] {
            XCTAssertTrue(contains(label, word), "spoken label \"\(label)\" should contain \"\(word)\"")
        }
    }

    func testInboxReadRowWithNoFlagsShowsNoMarksAndNoMarkWordsInItsLabel() throws {
        makeView(mailbox: try mailbox(items: [
            Mail(from: "Carol Diaz <carol@x.com>", subject: "Weekly digest", ago: 3 * 3600, read: true),
        ]))
        let dot: NSView = try requireView("fred.row.unread", in: try rowView(inboxTable, 0))
        XCTAssertTrue(dot.isHidden, "read row hides the unread dot")
        XCTAssertTrue(try rowField(inboxTable, 0, "fred.row.vip").isHidden)
        XCTAssertTrue(try rowField(inboxTable, 0, "fred.row.invite").isHidden)

        let label = try rowLabel(inboxTable, 0)
        for word in ["Unread", "VIP", "Invite"] {
            XCTAssertFalse(contains(label, word, caseInsensitive: true), "read row label \"\(label)\" must not contain \"\(word)\"")
        }
        for word in ["Carol Diaz", "Weekly digest", "3 h ago"] {
            XCTAssertTrue(contains(label, word), "spoken label \"\(label)\" should contain \"\(word)\"")
        }
    }

    func testInboxMarksAreIndependentVipWithoutInviteAndInviteWithoutVip() throws {
        makeView(mailbox: try mailbox(items: [
            Mail(from: "Vera <v@x.com>", subject: "only vip", ago: 60, vip: true),
            Mail(from: "Ian <i@x.com>", subject: "only invite", ago: 120, invite: true),
        ]))
        let subjects = try column(inboxTable, "fred.row.subject")
        let v = try XCTUnwrap(subjects.firstIndex(of: "only vip"))
        let i = try XCTUnwrap(subjects.firstIndex(of: "only invite"))
        XCTAssertFalse(try rowField(inboxTable, v, "fred.row.vip").isHidden)
        XCTAssertTrue(try rowField(inboxTable, v, "fred.row.invite").isHidden)
        XCTAssertTrue(try rowField(inboxTable, i, "fred.row.vip").isHidden)
        XCTAssertFalse(try rowField(inboxTable, i, "fred.row.invite").isHidden)
        XCTAssertFalse(contains(try rowLabel(inboxTable, v), "Invite"))
        XCTAssertFalse(contains(try rowLabel(inboxTable, i), "VIP"))
    }

    func testInboxSenderIsBoldForUnreadRowsAndRegularForReadRows() throws {
        makeView(mailbox: try mailbox(items: [
            Mail(from: "Una Unread <u@x.com>", subject: "a", ago: 60),
            Mail(from: "Rita Read <r@x.com>", subject: "b", ago: 120, read: true),
        ]))
        let senders = try column(inboxTable, "fred.row.sender")
        let u = try XCTUnwrap(senders.firstIndex(of: "Una Unread"))
        let r = try XCTUnwrap(senders.firstIndex(of: "Rita Read"))
        XCTAssertTrue(isBold(try rowField(inboxTable, u, "fred.row.sender")), "unread sender is bold/semibold")
        XCTAssertFalse(isBold(try rowField(inboxTable, r, "fred.row.sender")), "read sender is regular weight")
    }

    // MARK: - Inbox: relative time

    func testInboxRelativeTimesFollowTheBoundaries() throws {
        // Newest first == ascending age, since every row is unread.
        let cases: [(ago: TimeInterval, text: String)] = [
            (30, "just now"), (59, "just now"), (60, "1 min ago"), (5 * 60, "5 min ago"),
            (59 * 60 + 59, "59 min ago"), (3600, "1 h ago"), (3 * 3600, "3 h ago"),
            (24 * 3600 - 1, "23 h ago"), (24 * 3600, "yesterday"), (48 * 3600 - 1, "yesterday"),
            (48 * 3600, "2 d ago"), (3 * 86400, "3 d ago"),
        ]
        makeView(mailbox: try mailbox(items: cases.reversed().enumerated().map { i, c in
            Mail(from: "Sender <s@x.com>", subject: "s\(i)", ago: c.ago)
        }))
        XCTAssertEqual(try column(inboxTable, "fred.row.time"), cases.map(\.text))
    }

    func testInboxRelativeTimesMoveForwardWhenTheClockAdvancesWithoutANewModel() throws {
        makeView(mailbox: try mailbox(items: [Mail(from: "Alice <a@x.com>", subject: "Hi", ago: 5 * 60)]))
        XCTAssertEqual(try column(inboxTable, "fred.row.time"), ["5 min ago"])
        advance(to: now.addingTimeInterval(10 * 60))
        XCTAssertEqual(try column(inboxTable, "fred.row.time"), ["15 min ago"])
        XCTAssertTrue(contains(try rowLabel(inboxTable, 0), "15 min ago"), "spoken label follows the refreshed time")
    }

    // MARK: - Inbox: empty

    func testInboxShowsAPositiveEmptyMessageForFreshOrEmptyWithNoItems() throws {
        makeView()
        for state in ["empty", "fresh"] {
            render(mailbox: try mailbox(state: state, unread: 0, items: []))
            XCTAssertTrue(isShown("fred.inbox.empty"), "state \(state) with no items shows the empty message")
            XCTAssertEqual(try text("fred.inbox.empty"), "No messages in your Inbox")
            XCTAssertEqual(try rowCount(inboxTable), 0)
            XCTAssertNil(try bannerMessage("fred.inbox.banner"), "an empty inbox is not a problem state")
        }
    }

    func testInboxEmptyMessageIsHiddenWhenThereAreMessages() throws {
        makeView(mailbox: try inboxSample())
        XCTAssertFalse(isShown("fred.inbox.empty"))
    }

    // MARK: - Today: ordering, time ranges, header

    func testTodayRowsAreInStartOrderWithExactTimeRanges() throws {
        let allDay = Ev(title: "Offsite", start: at("00:00"), end: Self.at("00:00", day: 11), isAllDay: true)
        makeView(calendar: try calendar(events: [
            ev("Retro", "15:00", "15:45"),
            engSync,
            designReview,
            allDay,
        ]))
        XCTAssertEqual(try column(todayTable, "fred.row.title"), ["Offsite", "Eng sync", "Design review", "Retro"])
        XCTAssertEqual(try column(todayTable, "fred.row.timerange"),
                       ["All day", "9:30–10:00 am", "11:30 am–12:30 pm", "3:00–3:45 pm"])
        XCTAssertEqual(try text("fred.today.header"), "Today · 4 meetings",
                       "all-day events count; only cancelled ones are excluded")
    }

    func testTodayTimeRangesAreFormattedInTheInjectedTimeZone() throws {
        makeView(calendar: try calendar(events: [engSync]),
                 timeZone: TimeZone(identifier: "America/New_York")!)
        XCTAssertEqual(try column(todayTable, "fred.row.timerange"), ["10:30–11:00 am"])
    }

    func testTodayHeaderCountsMeetingsAndSingularises() throws {
        makeView(calendar: try calendar(events: [engSync, designReview, ev("Retro", "15:00", "15:45")]))
        XCTAssertEqual(try text("fred.today.header"), "Today · 3 meetings")
        render(calendar: try calendar(events: [engSync]))
        XCTAssertEqual(try text("fred.today.header"), "Today · 1 meeting")
    }

    func testTodayHeaderIsJustTodayWhenThereIsNoDataToCount() throws {
        makeView()
        for state in ["loading", "unauthenticated", "error", "not_configured"] {
            render(calendar: try calendar(state: state, events: [engSync, designReview],
                                          error: state == "error" ? "boom" : nil))
            XCTAssertEqual(try text("fred.today.header"), "Today", "state \(state) must not show a meeting count")
        }
        render(calendar: nil)
        XCTAssertEqual(try text("fred.today.header"), "Today")
    }

    // MARK: - Today: status words

    func testTodayShowsAStatusWordForEveryResponseValue() throws {
        let cases: [(status: String, word: String)] = [
            ("accepted", "Accepted"), ("tentativelyAccepted", "Tentative"), ("declined", "Declined"),
            ("cancelled", "Cancelled"), ("organizer", "Organizer"), ("notResponded", "No response"),
            ("none", "No response"), ("", "No response"),
        ]
        // Distinct, future, non-overlapping so nothing is "Now".
        let events = cases.enumerated().map { i, c in
            Ev(title: "Meeting \(i)", start: at("10:00").addingTimeInterval(Double(i) * 1800),
               end: at("10:00").addingTimeInterval(Double(i) * 1800 + 1500), status: c.status)
        }
        makeView(calendar: try calendar(events: events))
        XCTAssertEqual(try column(todayTable, "fred.row.status"), cases.map(\.word))
        XCTAssertEqual(try column(todayTable, "fred.row.title"), cases.indices.map { "Meeting \($0)" })
    }

    func testTodayShowsCancelledForAnEventFlaggedCancelledEvenIfTheResponseWasAccepted() throws {
        var e = ev("Kickoff", "10:00", "10:30")
        e.isCancelled = true
        makeView(calendar: try calendar(events: [e]))
        XCTAssertEqual(try column(todayTable, "fred.row.status"), ["Cancelled"])
    }

    // MARK: - Today: Now and countdown

    func testTodayBeforeTheFirstMeetingCountsDownAndMarksNothingNow() throws {
        makeView(calendar: try calendar(events: [engSync, designReview]))
        XCTAssertEqual(try text("fred.today.countdown"), "Next: Eng sync in 12 min")
        XCTAssertEqual(try nowRows(), [])
    }

    func testTodayDuringAMeetingMarksItNowAndCountsDownToTheNextOne() throws {
        now = at("09:45")
        makeView(calendar: try calendar(events: [engSync, designReview]))
        XCTAssertEqual(try nowRows(), ["Eng sync"])
        XCTAssertEqual(try text("fred.today.countdown"), "Next: Design review in 1 h 45 min")
    }

    func testTodayAMeetingIsNowFromItsStartAndNotFromItsEnd() throws {
        now = at("09:30")
        makeView(calendar: try calendar(events: [engSync, designReview]))
        XCTAssertEqual(try nowRows(), ["Eng sync"], "start <= now")
        XCTAssertEqual(try text("fred.today.countdown"), "Next: Design review in 2 h")

        advance(to: at("10:00"))
        XCTAssertEqual(try nowRows(), [], "now < end is exclusive")
        XCTAssertEqual(try text("fred.today.countdown"), "Next: Design review in 1 h 30 min")
    }

    func testTodayBetweenMeetingsCountsDownToTheNextOne() throws {
        now = at("10:30")
        makeView(calendar: try calendar(events: [engSync, designReview]))
        XCTAssertEqual(try nowRows(), [])
        XCTAssertEqual(try text("fred.today.countdown"), "Next: Design review in 1 h")
    }

    func testTodayAfterTheLastMeetingSaysThereAreNoMoreMeetings() throws {
        now = at("12:45")
        makeView(calendar: try calendar(events: [engSync, designReview]))
        XCTAssertEqual(try text("fred.today.countdown"), "No more meetings today")
        XCTAssertEqual(try nowRows(), [])
        XCTAssertFalse(isShown("fred.today.empty"), "the day had meetings, so it is not the empty day")
        XCTAssertEqual(try rowCount(todayTable), 2, "finished meetings stay listed")
    }

    func testTodayInTheLastMeetingThereIsNothingUpcoming() throws {
        now = at("12:00")
        makeView(calendar: try calendar(events: [engSync, designReview]))
        XCTAssertEqual(try nowRows(), ["Design review"])
        XCTAssertEqual(try text("fred.today.countdown"), "No more meetings today")
    }

    func testTodayCountdownRoundsPartialMinutesUpAndHasAMinimumOfOne() throws {
        makeView(calendar: try calendar(events: [engSync]))
        let cases: [(clock: String, expected: String)] = [
            ("09:17:40", "Next: Eng sync in 13 min"),  // 12 min 20 s away
            ("09:18:00", "Next: Eng sync in 12 min"),  // exactly 12 min
            ("09:29:30", "Next: Eng sync in 1 min"),   // 30 s away still reads 1 min
            ("08:25:00", "Next: Eng sync in 1 h 5 min"),
            ("07:30:00", "Next: Eng sync in 2 h"),
        ]
        for c in cases {
            advance(to: at(c.clock))
            XCTAssertEqual(try text("fred.today.countdown"), c.expected, "at \(c.clock)")
        }
    }

    func testTodayAdvancingTheClockFlipsNowAndTheCountdownWithoutANewModel() throws {
        makeView(calendar: try calendar(events: [engSync, designReview]))
        XCTAssertEqual(try nowRows(), [])
        XCTAssertEqual(try text("fred.today.countdown"), "Next: Eng sync in 12 min")

        advance(to: at("09:31"))
        XCTAssertEqual(try nowRows(), ["Eng sync"])
        XCTAssertEqual(try text("fred.today.countdown"), "Next: Design review in 1 h 59 min")

        advance(to: at("12:45"))
        XCTAssertEqual(try nowRows(), [])
        XCTAssertEqual(try text("fred.today.countdown"), "No more meetings today")
    }

    func testTodayOverlappingMeetingsAreBothNow() throws {
        now = at("10:15")
        makeView(calendar: try calendar(events: [ev("Planning", "09:30", "10:30"), ev("Interview", "10:00", "11:00")]))
        XCTAssertEqual(Set(try nowRows()), ["Planning", "Interview"])
    }

    func testTodayNonCurrentRowsHideTheNowMarker() throws {
        now = at("09:45")
        makeView(calendar: try calendar(events: [engSync, designReview]))
        XCTAssertFalse(try rowField(todayTable, try todayRow("Eng sync"), "fred.row.now").isHidden)
        XCTAssertTrue(try rowField(todayTable, try todayRow("Design review"), "fred.row.now").isHidden)
    }

    // MARK: - Today: cancelled, declined, all-day

    func testTodayCancelledMeetingIsExcludedFromTheCountAndNextButShownStruckThrough() throws {
        let budget = ev("Budget", "09:25", "09:55", status: "cancelled")  // would be "Next" in 7 min if it counted
        makeView(calendar: try calendar(events: [budget, engSync, designReview]))
        XCTAssertEqual(try text("fred.today.header"), "Today · 2 meetings")
        XCTAssertEqual(try text("fred.today.countdown"), "Next: Eng sync in 12 min")
        XCTAssertEqual(try rowCount(todayTable), 3, "cancelled meetings stay listed")

        let row = try todayRow("Budget")
        XCTAssertEqual(try rowField(todayTable, row, "fred.row.status").stringValue, "Cancelled")
        let struck = try rowField(todayTable, row, "fred.row.title").attributedStringValue
        let style = struck.length > 0 ? struck.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) as? Int : nil
        XCTAssertNotNil(style, "cancelled title carries a strikethrough")
        XCTAssertNotEqual(style ?? 0, 0)

        let plain = try rowField(todayTable, try todayRow("Eng sync"), "fred.row.title").attributedStringValue
        XCTAssertNil(plain.length > 0 ? plain.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) : nil,
                     "live titles are not struck through")
    }

    func testTodayCancelledMeetingInProgressIsNotNow() throws {
        now = at("09:40")
        makeView(calendar: try calendar(events: [ev("Budget", "09:30", "10:00", status: "cancelled"), designReview]))
        XCTAssertEqual(try nowRows(), [])
        XCTAssertEqual(try text("fred.today.countdown"), "Next: Design review in 1 h 50 min")
    }

    func testTodayDeclinedMeetingIsNeitherNowNorNext() throws {
        makeView(calendar: try calendar(events: [ev("Skipped", "09:25", "09:55", status: "declined"), engSync]))
        XCTAssertEqual(try text("fred.today.countdown"), "Next: Eng sync in 12 min", "declined is skipped for Next")
        advance(to: at("09:40"))
        XCTAssertEqual(try nowRows(), ["Eng sync"], "declined 09:25-09:55 is not Now at 09:40")
        XCTAssertEqual(try rowField(todayTable, try todayRow("Skipped"), "fred.row.status").stringValue, "Declined")
    }

    func testTodayAllDayEventsAreNeverNowOrNext() throws {
        // The all-day event here starts after the clock so only the flag can exclude it from Next.
        let allDay = Ev(title: "Company holiday", start: at("09:25"), end: Self.at("00:00", day: 11), isAllDay: true)
        makeView(calendar: try calendar(events: [allDay, engSync]))
        XCTAssertEqual(try text("fred.today.countdown"), "Next: Eng sync in 12 min")
        advance(to: at("09:26"))
        XCTAssertEqual(try nowRows(), [], "all-day is not Now even while its span covers the clock")
        XCTAssertEqual(try rowField(todayTable, try todayRow("Company holiday"), "fred.row.timerange").stringValue, "All day")
    }

    // MARK: - Today: accessibility labels

    func testTodayRowLabelsSpeakTitleTimeRangeAndStatusAndOnlyTheCurrentRowStartsWithNow() throws {
        now = at("09:45")
        makeView(calendar: try calendar(events: [engSync, designReview]))

        let current = try rowLabel(todayTable, try todayRow("Eng sync"))
        XCTAssertTrue(current.hasPrefix("Now"), "current row label \"\(current)\" should start with Now")
        for part in ["Eng sync", "9:30–10:00 am", "Accepted"] {
            XCTAssertTrue(contains(current, part), "label \"\(current)\" should contain \"\(part)\"")
        }

        let later = try rowLabel(todayTable, try todayRow("Design review"))
        for part in ["Design review", "11:30 am–12:30 pm", "Accepted"] {
            XCTAssertTrue(contains(later, part), "label \"\(later)\" should contain \"\(part)\"")
        }
        XCTAssertFalse(contains(later, "Now"), "non-current label \"\(later)\" must not say Now")
    }

    func testTodayCancelledRowLabelSaysCancelled() throws {
        makeView(calendar: try calendar(events: [ev("Budget", "10:00", "10:30", status: "cancelled")]))
        let label = try rowLabel(todayTable, 0)
        XCTAssertTrue(contains(label, "Budget"))
        XCTAssertTrue(contains(label, "Cancelled"))
        XCTAssertTrue(contains(label, "10:00–10:30 am"))
    }

    // MARK: - Today: empty

    func testTodayShowsANoMeetingsMessageAndCountdownForAnEmptyDay() throws {
        makeView()
        for state in ["fresh", "empty"] {
            render(calendar: try calendar(state: state, events: []))
            XCTAssertTrue(isShown("fred.today.empty"), "state \(state) with no events shows the empty message")
            XCTAssertEqual(try text("fred.today.empty"), "No meetings today")
            XCTAssertEqual(try text("fred.today.countdown"), "No meetings today")
            XCTAssertEqual(try rowCount(todayTable), 0)
            XCTAssertNil(try bannerMessage("fred.today.banner"))
        }
    }

    func testTodayEmptyMessageIsHiddenWhenThereAreMeetings() throws {
        makeView(calendar: try calendar(events: [engSync]))
        XCTAssertFalse(isShown("fred.today.empty"))
    }

    // MARK: - Source-state banners

    func testBannersShowLoadingForMissingOrLoadingSnapshotsAndNeverFakeCountsOrEmptyStates() throws {
        makeView()  // FredSurfaceModel() — nothing has arrived yet
        XCTAssertEqual(try bannerMessage("fred.inbox.banner"), "Loading Mail…")
        XCTAssertEqual(try bannerMessage("fred.today.banner"), "Loading Calendar…")
        XCTAssertEqual(try text("fred.inbox.header"), "Inbox")
        XCTAssertEqual(try text("fred.today.header"), "Today")
        XCTAssertEqual(try rowCount(inboxTable), 0)
        XCTAssertEqual(try rowCount(todayTable), 0)

        let visibleText = allText(visibleOnly: true)
        for forbidden in ["0 unread", "No meetings", "No messages", "No more meetings"] {
            XCTAssertFalse(visibleText.contains { $0.contains(forbidden) },
                           "\"\(forbidden)\" must not appear while loading; saw \(visibleText)")
        }

        render(mailbox: try mailbox(state: "loading"), calendar: try calendar(state: "loading"))
        XCTAssertEqual(try bannerMessage("fred.inbox.banner"), "Loading Mail…")
        XCTAssertEqual(try bannerMessage("fred.today.banner"), "Loading Calendar…")
    }

    func testBannersAreHiddenForFreshAndEmptyData() throws {
        makeView(mailbox: try inboxSample(), calendar: try calendar(events: [engSync]))
        XCTAssertNil(try bannerMessage("fred.inbox.banner"))
        XCTAssertNil(try bannerMessage("fred.today.banner"))
        render(mailbox: try mailbox(state: "empty", unread: 0), calendar: try calendar(state: "empty"))
        XCTAssertNil(try bannerMessage("fred.inbox.banner"))
        XCTAssertNil(try bannerMessage("fred.today.banner"))
    }

    func testStaleBannersSaySinceWhenAndWhyAndKeepTheRowsVisible() throws {
        let updated = now.addingTimeInterval(-14 * 60)
        makeView(
            mailbox: try mailbox(state: "stale", unread: 12,
                                 items: [Mail(from: "Alice <a@x.com>", subject: "Hi")],
                                 stale: true, error: "Graph timeout", updatedAt: updated),
            calendar: try calendar(state: "stale", events: [engSync], stale: true,
                                   error: "Calendar timeout", updatedAt: updated))

        let mail = try XCTUnwrap(try bannerMessage("fred.inbox.banner"), "stale mail shows a banner")
        XCTAssertTrue(mail.hasPrefix("Stale: last updated 14 min ago"), mail)
        XCTAssertTrue(mail.hasSuffix("Graph timeout"), mail)
        XCTAssertEqual(try rowCount(inboxTable), 1, "stale data stays on screen")

        let cal = try XCTUnwrap(try bannerMessage("fred.today.banner"), "stale calendar shows a banner")
        XCTAssertTrue(cal.hasPrefix("Stale: last updated 14 min ago"), cal)
        XCTAssertTrue(cal.hasSuffix("Calendar timeout"), cal)
        XCTAssertEqual(try rowCount(todayTable), 1)
    }

    func testErrorStateShowsAFailureBannerNoRowsAndNeverAnUnreadCount() throws {
        makeView(mailbox: try mailbox(state: "error", unread: 0, items: [], error: "connection refused"),
                 calendar: try calendar(state: "error", events: [], error: "calendar down"))
        XCTAssertEqual(try bannerMessage("fred.inbox.banner"), "Mail failed: connection refused")
        XCTAssertEqual(try bannerMessage("fred.today.banner"), "Calendar failed: calendar down")
        XCTAssertEqual(try text("fred.inbox.header"), "Inbox")
        XCTAssertEqual(try text("fred.today.header"), "Today")
        XCTAssertFalse(allText(visibleOnly: false).contains { $0.contains("0 unread") },
                       "an errored mailbox must not claim \"0 unread\" anywhere")
        XCTAssertFalse(isShown("fred.inbox.empty"), "an error is not an empty inbox")
        XCTAssertFalse(isShown("fred.today.empty"), "an error is not an empty day")
        XCTAssertEqual(try shownText("fred.today.countdown"), "", "no countdown from failed data")
    }

    func testErrorStateDropsAnyItemsTheSnapshotStillCarries() throws {
        makeView(mailbox: try mailbox(state: "error", unread: 4,
                                      items: [Mail(from: "Alice <a@x.com>", subject: "a"), Mail(from: "Bob <b@x.com>", subject: "b")],
                                      error: "boom"),
                 calendar: try calendar(state: "error", events: [engSync, designReview], error: "boom"))
        XCTAssertEqual(try rowCount(inboxTable), 0)
        XCTAssertEqual(try rowCount(todayTable), 0)
        XCTAssertEqual(try text("fred.inbox.header"), "Inbox")
        XCTAssertEqual(try text("fred.today.header"), "Today")
        XCTAssertEqual(try shownText("fred.today.countdown"), "")
    }

    func testNotConfiguredAndUnauthenticatedWithoutAPromptSayWhyInTheBanner() throws {
        makeView(mailbox: try mailbox(state: "unauthenticated", unread: 0, error: "sign-in required"),
                 calendar: try calendar(state: "not_configured", error: "no Microsoft account configured"))
        XCTAssertEqual(try bannerMessage("fred.inbox.banner"), "Mail: sign-in required")
        XCTAssertEqual(try bannerMessage("fred.today.banner"), "Calendar: no Microsoft account configured")
        XCTAssertFalse(isShown("fred.inbox.signin"), "no prompt, so no sign-in group")
        XCTAssertFalse(isShown("fred.today.signin"))
        XCTAssertEqual(try rowCount(inboxTable), 0)
        XCTAssertEqual(try text("fred.inbox.header"), "Inbox")
    }

    func testRateLimitedShowsABannerButKeepsTheRows() throws {
        makeView(mailbox: try mailbox(state: "rate_limited", unread: 12,
                                      items: [Mail(from: "Alice <a@x.com>", subject: "Hi")]),
                 calendar: try calendar(state: "rate_limited", events: [engSync, designReview]))
        let mail = try XCTUnwrap(try bannerMessage("fred.inbox.banner"), "rate-limited mail shows a banner")
        XCTAssertTrue(mail.contains("Mail"), mail)
        XCTAssertNotNil(try bannerMessage("fred.today.banner"))
        XCTAssertEqual(try rowCount(inboxTable), 1)
        XCTAssertEqual(try rowCount(todayTable), 2)
    }

    // MARK: - Sign-in (device flow)

    private func signInPrompt(code: String = "ABCD-EFGH", expires: String = "09:42") -> Prompt {
        Prompt(code: code, expires: at(expires))
    }

    func testUnauthenticatedWithAPromptShowsTheSignInGroupInBothPanes() throws {
        makeView(mailbox: try mailbox(state: "unauthenticated", unread: 0, prompt: signInPrompt()),
                 calendar: try calendar(state: "unauthenticated"))  // calendar has no prompt of its own
        for pane in ["inbox", "today"] {
            XCTAssertTrue(isShown("fred.\(pane).signin"), "\(pane) shows the sign-in group")
            let url: NSView = try requireView("fred.\(pane).signin.url")
            XCTAssertEqual(stringOf(url), "https://microsoft.com/devicelogin")
            XCTAssertTrue(attributedOf(url).map(hasLink) ?? false, "\(pane) URL is a clickable link")
            XCTAssertTrue(try text("fred.\(pane).signin.code").contains("ABCD-EFGH"))
            XCTAssertEqual(try text("fred.\(pane).signin.expiry"), "Expires at 9:42 am")
            let copy: NSButton = try requireView("fred.\(pane).signin.copy")
            XCTAssertEqual(copy.title, "Copy code")
            XCTAssertNil(try bannerMessage("fred.\(pane).banner"), "the sign-in group replaces the generic banner")
        }
        XCTAssertEqual(try rowCount(inboxTable), 0)
        XCTAssertEqual(try rowCount(todayTable), 0)
        XCTAssertEqual(try text("fred.inbox.header"), "Inbox")
        XCTAssertEqual(try text("fred.today.header"), "Today")
        XCTAssertFalse(isShown("fred.inbox.empty"))
        XCTAssertFalse(isShown("fred.today.empty"))
    }

    func testTodayPrefersItsOwnPromptOverTheMailboxPrompt() throws {
        makeView(mailbox: try mailbox(state: "unauthenticated", unread: 0, prompt: signInPrompt(code: "MAIL-1111")),
                 calendar: try calendar(state: "unauthenticated", prompt: signInPrompt(code: "CAL-2222")))
        XCTAssertTrue(try text("fred.inbox.signin.code").contains("MAIL-1111"))
        XCTAssertTrue(try text("fred.today.signin.code").contains("CAL-2222"))
    }

    func testSignInGroupIsHiddenOnceTheSourceIsAuthenticated() throws {
        makeView(mailbox: try mailbox(state: "unauthenticated", unread: 0, prompt: signInPrompt()),
                 calendar: try calendar(state: "unauthenticated"))
        XCTAssertTrue(isShown("fred.inbox.signin"))
        render(mailbox: try inboxSample(), calendar: try calendar(events: [engSync]))
        XCTAssertFalse(isShown("fred.inbox.signin"))
        XCTAssertFalse(isShown("fred.today.signin"))
        XCTAssertEqual(try rowCount(inboxTable), 3)
        XCTAssertEqual(try rowCount(todayTable), 1)
    }

    func testSignInExpiryReadsExpiredOnceTheCodeIsPast() throws {
        makeView(mailbox: try mailbox(state: "unauthenticated", unread: 0, prompt: signInPrompt(expires: "09:42")),
                 calendar: try calendar(state: "unauthenticated"))
        XCTAssertEqual(try text("fred.inbox.signin.expiry"), "Expires at 9:42 am")
        advance(to: at("09:50"))
        XCTAssertEqual(try text("fred.inbox.signin.expiry"), "Code expired at 9:42 am")
        XCTAssertEqual(try text("fred.today.signin.expiry"), "Code expired at 9:42 am")
    }

    func testSignInExpiryIsShownInTheInjectedTimeZone() throws {
        makeView(mailbox: try mailbox(state: "unauthenticated", unread: 0, prompt: signInPrompt(expires: "09:42")),
                 calendar: nil,
                 timeZone: TimeZone(identifier: "America/New_York")!)
        XCTAssertEqual(try text("fred.inbox.signin.expiry"), "Expires at 10:42 am")
    }

    func testCopyCodePutsTheCodeOnTheInjectedPasteboard() throws {
        makeView(mailbox: try mailbox(state: "unauthenticated", unread: 0, prompt: signInPrompt(code: "WXYZ-1234")),
                 calendar: try calendar(state: "unauthenticated"))
        let copy: NSButton = try requireView("fred.inbox.signin.copy")
        copy.performClick(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), "WXYZ-1234")

        pasteboard.clearContents()
        let todayCopy: NSButton = try requireView("fred.today.signin.copy")
        todayCopy.performClick(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), "WXYZ-1234", "Today's Copy code copies the code it displays")
    }

    // MARK: - Disconnected

    func testDisconnectedShowsTheBannerDimsBothPanesAndKeepsTheRows() throws {
        makeView(mailbox: try inboxSample(), calendar: try calendar(events: [engSync, designReview]), isConnected: false)
        XCTAssertEqual(try bannerMessage("fred.disconnected.banner"), "Disconnected from nostromd")
        let inboxPane: NSView = try requireView("fred.inbox.pane")
        let todayPane: NSView = try requireView("fred.today.pane")
        XCTAssertLessThan(inboxPane.alphaValue, 1)
        XCTAssertLessThan(todayPane.alphaValue, 1)
        XCTAssertEqual(try rowCount(inboxTable), 3, "last-known rows stay visible while disconnected")
        XCTAssertEqual(try rowCount(todayTable), 2)
    }

    func testReconnectingClearsTheBannerAndUndimsThePanes() throws {
        makeView(mailbox: try inboxSample(), calendar: try calendar(events: [engSync]), isConnected: false)
        render(mailbox: try inboxSample(), calendar: try calendar(events: [engSync]), isConnected: true)
        XCTAssertNil(try bannerMessage("fred.disconnected.banner"))
        let inboxPane: NSView = try requireView("fred.inbox.pane")
        let todayPane: NSView = try requireView("fred.today.pane")
        XCTAssertEqual(inboxPane.alphaValue, 1, accuracy: 0.001)
        XCTAssertEqual(todayPane.alphaValue, 1, accuracy: 0.001)
    }

    func testConnectedViewShowsNoDisconnectedBanner() throws {
        makeView(mailbox: try inboxSample(), calendar: try calendar(events: [engSync]))
        XCTAssertNil(try bannerMessage("fred.disconnected.banner"))
    }

    // MARK: - Re-rendering on model change

    func testAssigningANewModelRerendersFromErrorToFreshData() throws {
        makeView(mailbox: try mailbox(state: "error", unread: 0, error: "boom"),
                 calendar: try calendar(state: "error", error: "boom"))
        XCTAssertEqual(try rowCount(inboxTable), 0)
        XCTAssertNotNil(try bannerMessage("fred.inbox.banner"))

        render(mailbox: try inboxSample(), calendar: try calendar(events: [engSync, designReview]))
        XCTAssertNil(try bannerMessage("fred.inbox.banner"))
        XCTAssertNil(try bannerMessage("fred.today.banner"))
        XCTAssertEqual(try rowCount(inboxTable), 3)
        XCTAssertEqual(try rowCount(todayTable), 2)
        XCTAssertEqual(try text("fred.inbox.header"), "Inbox · 12 unread")
        XCTAssertEqual(try text("fred.today.header"), "Today · 2 meetings")
        XCTAssertEqual(try text("fred.today.countdown"), "Next: Eng sync in 12 min")
    }

    func testAssigningANewModelReplacesRowsRatherThanAppendingToThem() throws {
        makeView(mailbox: try inboxSample(), calendar: try calendar(events: [engSync, designReview]))
        render(mailbox: try mailbox(items: [Mail(from: "Zed <z@x.com>", subject: "only one")]),
               calendar: try calendar(events: [designReview]))
        XCTAssertEqual(try column(inboxTable, "fred.row.sender"), ["Zed"])
        XCTAssertEqual(try column(todayTable, "fred.row.title"), ["Design review"])
    }

    func testTheFirstSnapshotReplacesTheLoadingBanner() throws {
        makeView()
        XCTAssertNotNil(try bannerMessage("fred.inbox.banner"))
        render(mailbox: try inboxSample(), calendar: nil)
        XCTAssertNil(try bannerMessage("fred.inbox.banner"))
        XCTAssertEqual(try bannerMessage("fred.today.banner"), "Loading Calendar…", "Today is still waiting on its own snapshot")
    }

    // MARK: - Wire decoding: state

    func testMailboxStateIsDerivedFromLegacyFieldsWhenTheWireOmitsIt() throws {
        let prompt = #""auth_prompt": {"verification_uri": "https://x/d", "user_code": "C", "expires_at": "2026-10-10T15:00:00Z"}"#
        let cases: [(json: String, expected: SourceState)] = [
            ("{\(prompt)}", .unauthenticated),
            (#"{"error": "boom", "stale": true, "unread_count": 3}"#, .stale),
            (#"{"error": "boom", "unread_count": 3}"#, .error),
            (#"{"stale": true, "unread_count": 3, "items": []}"#, .stale),
            (#"{"unread_count": 0, "items": []}"#, .empty),
            (#"{}"#, .empty),
            (#"{"unread_count": 5, "items": []}"#, .fresh),
            (#"{"unread_count": 1, "items": [{"from": "A <a@x.com>", "subject": "s", "vip": false, "is_invite": false, "is_read": false}]}"#, .fresh),
        ]
        for c in cases {
            let snapshot = try decode(MailboxSnapshot.self, json: c.json)
            XCTAssertEqual(snapshot.state, c.expected, "legacy JSON \(c.json)")
        }
    }

    func testMailboxStateOnTheWireWinsOverLegacyFields() throws {
        let snapshot = try decode(MailboxSnapshot.self, json: #"{"state": "rate_limited", "unread_count": 0, "items": [], "stale": true}"#)
        XCTAssertEqual(snapshot.state, .rateLimited)
    }

    func testCalendarStateIsDerivedFromLegacyFieldsWhenTheWireOmitsIt() throws {
        let prompt = #""auth_prompt": {"verification_uri": "https://x/d", "user_code": "C", "expires_at": "2026-10-10T15:00:00Z"}"#
        let event = #"{"start": "2026-10-10T14:30:00Z", "end": "2026-10-10T15:00:00Z", "title": "t", "status": "accepted", "is_now": false}"#
        let cases: [(json: String, expected: SourceState)] = [
            ("{\(prompt)}", .unauthenticated),
            (#"{"error": "boom", "stale": true}"#, .stale),
            (#"{"error": "boom"}"#, .error),
            (#"{"stale": true, "events": []}"#, .stale),
            (#"{"events": []}"#, .empty),
            ("{\"events\": [\(event)]}", .fresh),
        ]
        for c in cases {
            let snapshot = try decode(CalendarSnapshot.self, json: c.json)
            XCTAssertEqual(snapshot.state, c.expected, "legacy JSON \(c.json)")
        }
        let withPrompt = try decode(CalendarSnapshot.self, json: "{\(prompt)}")
        XCTAssertEqual(withPrompt.authPrompt?.userCode, "C", "calendar snapshots now carry their own auth prompt")
    }

    // MARK: - Rate limiting: `retry_at` on the wire and in the banner

    /// The app's decoder (`NostromodClient`): ISO8601 with or without fractional seconds.
    private func appDecode<T: Decodable>(_ type: T.Type, json: String) throws -> T {
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let str = try c.decode(String.self)
            if let date = frac.date(from: str) ?? basic.date(from: str) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Cannot parse date: \(str)")
        }
        return try d.decode(T.self, from: Data(json.utf8))
    }

    /// `retryAt` read by name so this file compiles before the model gains the field:
    /// a missing property reads as `nil` and the assertion (not the build) fails.
    private func retryAt(_ snapshot: Any) -> Date? {
        Mirror(reflecting: snapshot).children.first { $0.label == "retryAt" }?.value as? Date
    }

    private let retryInstant = Date(timeIntervalSince1970: 1_791_642_840) // 2026-10-10T14:34:00Z

    func testMailboxSnapshotDecodesRetryAtWithAndWithoutFractionalSeconds() throws {
        let basic = try appDecode(MailboxSnapshot.self, json: #"{"state": "rate_limited", "stale": true, "unread_count": 4, "retry_at": "2026-10-10T14:34:00Z"}"#)
        XCTAssertEqual(retryAt(basic), retryInstant)
        let frac = try appDecode(MailboxSnapshot.self, json: #"{"state": "rate_limited", "stale": true, "unread_count": 4, "retry_at": "2026-10-10T14:34:00.250Z"}"#)
        XCTAssertEqual(try XCTUnwrap(retryAt(frac)).timeIntervalSince(retryInstant), 0.25, accuracy: 0.001)
        let absent = try appDecode(MailboxSnapshot.self, json: #"{"state": "fresh", "unread_count": 4}"#)
        XCTAssertNil(retryAt(absent))
        XCTAssertEqual(basic.state, .rateLimited)
    }

    func testCalendarSnapshotDecodesRetryAtWithAndWithoutFractionalSeconds() throws {
        let basic = try appDecode(CalendarSnapshot.self, json: #"{"state": "rate_limited", "stale": true, "events": [], "retry_at": "2026-10-10T14:34:00Z"}"#)
        XCTAssertEqual(retryAt(basic), retryInstant)
        let frac = try appDecode(CalendarSnapshot.self, json: #"{"state": "rate_limited", "stale": true, "events": [], "retry_at": "2026-10-10T14:34:00.250Z"}"#)
        XCTAssertEqual(try XCTUnwrap(retryAt(frac)).timeIntervalSince(retryInstant), 0.25, accuracy: 0.001)
        let absent = try appDecode(CalendarSnapshot.self, json: #"{"state": "fresh", "events": []}"#)
        XCTAssertNil(retryAt(absent))
        XCTAssertEqual(basic.state, .rateLimited)
    }

    func testRateLimitedBannerContentSaysWhenItWillRetryOnlyWhenItKnows() throws {
        let known = SourceStateBanner.content(state: .rateLimited, updatedAt: nil, reason: nil,
                                              retryAt: retryInstant, sourceName: "Mail", now: now)
        XCTAssertTrue(try XCTUnwrap(known).message.contains("retrying at"), known?.message ?? "nil")
        let unknown = SourceStateBanner.content(state: .rateLimited, updatedAt: nil, reason: nil,
                                                retryAt: nil, sourceName: "Mail", now: now)
        XCTAssertFalse(try XCTUnwrap(unknown).message.contains("retrying at"))
    }

    func testRateLimitedFredPanesTellTheUserWhenTheDaemonWillAskMicrosoftAgain() throws {
        let mail = try appDecode(MailboxSnapshot.self, json: """
            {"state": "rate_limited", "stale": true, "unread_count": 12, "items": [],
             "error": "Mail fetch failed: Microsoft is rate limiting requests (429)",
             "retry_at": "2026-10-10T14:34:00Z"}
            """)
        let cal = try appDecode(CalendarSnapshot.self, json: """
            {"state": "rate_limited", "stale": true, "events": [], "sweater": "sage",
             "error": "Calendar fetch failed: Microsoft is rate limiting requests (429)",
             "retry_at": "2026-10-10T14:34:00Z"}
            """)
        makeView(mailbox: mail, calendar: cal)
        for id in ["fred.inbox.banner", "fred.today.banner"] {
            let message = try XCTUnwrap(try bannerMessage(id), "\(id) is showing")
            XCTAssertTrue(message.contains("Rate-limited"), message)
            XCTAssertTrue(message.contains("retrying at"), "\(id): \(message)")
        }
    }

    /// Throttled before anything was ever fetched: the snapshot carries no data and
    /// no `updated_at`, so the panes must not turn its zeros into "0 unread" / "No
    /// meetings today" (the invariant: a throttled fetch is never a confident zero).
    func testRateLimitedMailWithNothingEverFetchedNeverReadsAsZeroUnreadOrAnEmptyInbox() throws {
        makeView(mailbox: try mailbox(state: "rate_limited", unread: 0, items: [], stale: true,
                                      error: "Mail fetch failed: Microsoft is rate limiting requests (429)"))
        XCTAssertEqual(try text("fred.inbox.header"), "Inbox", "no count was ever read")
        XCTAssertFalse(isShown("fred.inbox.empty"), "a throttled inbox is not an empty inbox")
        XCTAssertNotNil(try bannerMessage("fred.inbox.banner"), "the user is told why")
        XCTAssertEqual(try rowCount(inboxTable), 0)
    }

    func testRateLimitedCalendarWithNothingEverFetchedNeverReadsAsNoMeetingsToday() throws {
        makeView(calendar: try calendar(state: "rate_limited", events: [], stale: true,
                                        error: "Calendar fetch failed: Microsoft is rate limiting requests (429)"))
        XCTAssertFalse(isShown("fred.today.empty"), "a throttled calendar is not an empty day")
        XCTAssertFalse(try text("fred.today.countdown").contains("No meetings"))
        XCTAssertFalse(try text("fred.today.header").contains("No meetings"))
        XCTAssertNotNil(try bannerMessage("fred.today.banner"))
        XCTAssertEqual(try rowCount(todayTable), 0)
    }

    // MARK: - F1: detail and Ask Fred

    /// Records what the view asked of its injected collaborators. Closures answer synchronously.
    private final class DetailFake {
        var requested: [String] = []
        var seeds: [String] = []
        var opened: [URL] = []
        var detailResult: (String) -> Result<WorkItemDetail, WorkError> = { id in
            .failure(WorkError(code: "not_found", message: "no detail for \(id)"))
        }
        var seedError: WorkError?
        /// When set, `seedFred` completions are parked in `pendingSeeds` for the test to run later.
        var deferSeed = false
        var pendingSeeds: [(WorkError?) -> Void] = []
        /// When set, `requestDetail` completions are parked in `pendingDetails`.
        var deferDetail = false
        var pendingDetails: [(Result<WorkItemDetail, WorkError>) -> Void] = []

        var actions: FredDetailActions {
            FredDetailActions(
                requestDetail: { id, done in
                    self.requested.append(id)
                    if self.deferDetail { self.pendingDetails.append(done) } else { done(self.detailResult(id)) }
                },
                seedFred: { text, done in
                    self.seeds.append(text)
                    if self.deferSeed { self.pendingSeeds.append(done) } else { done(self.seedError) }
                },
                open: { self.opened.append($0) })
        }
    }

    private func mailDetail(id: String = "mail:m-0") throws -> WorkItemDetail {
        try decode(WorkItemDetail.self, [
            "item_id": id,
            "title": "Quarterly numbers",
            "fields": [["From", "Alice Smith <alice@example.com>"],
                       ["To", "Bob Jones <bob@example.com>"],
                       ["Received", "Sat 10 Oct 2026, 09:10"]],
            "markdown": "Hello Bob,\nNumbers attached.",
            "files": [String](),
            "links": [["label": "Open in Outlook", "url": "https://outlook.office.com/detail/mail"]],
        ])
    }

    private func eventDetail(id: String = "event:e-0") throws -> WorkItemDetail {
        try decode(WorkItemDetail.self, [
            "item_id": id,
            "title": "Eng sync",
            "fields": [["Organiser", "Olive <olive@example.com>"],
                       ["When", "Sat 10 Oct 2026, 09:30\u{2013}10:00"],
                       ["Attendees", "Ann (accepted), Ben (no response)"]],
            "markdown": "Agenda: roadmap",
            "files": [String](),
            "links": [["label": "Open in Outlook", "url": "https://outlook.office.com/detail/event"]],
        ])
    }

    private func oneMailView(_ fake: DetailFake) throws {
        makeView(mailbox: try mailbox(items: [Mail(from: "Alice", subject: "Quarterly numbers")]),
                 detail: fake.actions)
    }

    private func oneEventView(_ fake: DetailFake) throws {
        makeView(calendar: try calendar(events: [Ev(title: "Eng sync", start: at("09:30"), end: at("10:00"))]),
                 detail: fake.actions)
    }

    func testNothingIsSelectedSoNoDetailIsShownUntilARowIsSelected() throws {
        let fake = DetailFake()
        try oneMailView(fake)
        XCTAssertNil(sut.detailView)
        XCTAssertTrue(fake.requested.isEmpty)
    }

    func testSelectingAnInboxRowRequestsThatMessageAndShowsItsFieldsAndBody() throws {
        let fake = DetailFake()
        fake.detailResult = { [self] _ in .success(try! mailDetail()) }
        try oneMailView(fake)
        sut.selectInboxRow(0)
        XCTAssertEqual(fake.requested, ["mail:m-0"])
        let d = try XCTUnwrap(sut.detailView)
        XCTAssertEqual(d.displayedFields.map(\.label), ["From", "To", "Received"])
        XCTAssertEqual(d.displayedFields.first?.value, "Alice Smith <alice@example.com>")
        XCTAssertEqual(d.displayedBody, "Hello Bob,\nNumbers attached.")
        XCTAssertNil(d.errorText)
    }

    func testSelectingATodayEventRequestsThatEventAndShowsItsFieldsAndAgenda() throws {
        let fake = DetailFake()
        fake.detailResult = { [self] _ in .success(try! eventDetail()) }
        try oneEventView(fake)
        sut.selectTodayRow(0)
        XCTAssertEqual(fake.requested, ["event:e-0"])
        let d = try XCTUnwrap(sut.detailView)
        XCTAssertEqual(d.displayedFields.map(\.label), ["Organiser", "When", "Attendees"])
        XCTAssertEqual(d.displayedBody, "Agenda: roadmap")
    }

    func testADetailErrorIsShownInTheDetailAndNeverAsAnEmptyMessage() throws {
        let fake = DetailFake()
        fake.detailResult = { _ in .failure(WorkError(code: "not_found", message: "That item no longer exists in Outlook")) }
        try oneMailView(fake)
        sut.selectInboxRow(0)
        let d = try XCTUnwrap(sut.detailView)
        XCTAssertEqual(d.errorText, "That item no longer exists in Outlook")
        XCTAssertTrue(d.displayedFields.isEmpty)
        XCTAssertEqual(d.displayedBody, "")
    }

    // MARK: Ask Fred / Prep with Fred

    private func loadedMailDetailView(_ fake: DetailFake) throws -> FredDetailView {
        fake.detailResult = { [self] _ in .success(try! mailDetail()) }
        try oneMailView(fake)
        sut.selectInboxRow(0)
        return try XCTUnwrap(sut.detailView)
    }

    func testAskFredOpensAConfirmationWithTheDefaultPromptAndSendsNothingYet() throws {
        let fake = DetailFake()
        let d = try loadedMailDetailView(fake)
        XCTAssertFalse(d.isConfirming)
        d.beginSeed()
        XCTAssertTrue(d.isConfirming)
        XCTAssertEqual(d.promptText, FredDetailPrompts.ask(try mailDetail(), nonce: try promptNonce(d.promptText)))
        XCTAssertTrue(fake.seeds.isEmpty, "nothing is sent until the user confirms")
    }

    func testConfirmingSendsExactlyOneSeedWithTheEditedPromptAndCloses() throws {
        let fake = DetailFake()
        let d = try loadedMailDetailView(fake)
        d.beginSeed()
        d.promptText = "Just tell me if this needs a reply."
        d.confirmSeed()
        XCTAssertEqual(fake.seeds, ["Just tell me if this needs a reply."])
        XCTAssertFalse(d.isConfirming)
        XCTAssertNil(d.errorText)
        d.confirmSeed()
        XCTAssertEqual(fake.seeds.count, 1, "a second confirm with nothing open sends nothing")
    }

    func testCancellingSendsNothingAndCloses() throws {
        let fake = DetailFake()
        let d = try loadedMailDetailView(fake)
        d.beginSeed()
        d.cancelSeed()
        XCTAssertTrue(fake.seeds.isEmpty)
        XCTAssertFalse(d.isConfirming)
    }

    func testWhenFredIsNotRunningTheUserIsToldHowToRecoverAndSuccessIsNotClaimed() throws {
        let fake = DetailFake()
        fake.seedError = WorkError(code: "fred_not_running", message: "raw daemon text")
        let d = try loadedMailDetailView(fake)
        d.beginSeed()
        d.confirmSeed()
        XCTAssertEqual(d.errorText, "Fred's session isn't running; open Fred's chat once and retry.")
        XCTAssertEqual(fake.seeds.count, 1)
        XCTAssertFalse(d.isConfirming && d.errorText == nil, "no success state is shown")
    }

    func testPrepWithFredOnAnEventSeedsTheMeetingPrompt() throws {
        let fake = DetailFake()
        fake.detailResult = { [self] _ in .success(try! eventDetail()) }
        try oneEventView(fake)
        sut.selectTodayRow(0)
        let d = try XCTUnwrap(sut.detailView)
        d.beginSeed()
        let nonce = try promptNonce(d.promptText)
        XCTAssertEqual(d.promptText, FredDetailPrompts.prep(try eventDetail(), nonce: nonce))
        d.confirmSeed()
        XCTAssertEqual(fake.seeds, [FredDetailPrompts.prep(try eventDetail(), nonce: nonce)])
    }

    // MARK: Open in Outlook

    func testOpenInOutlookHandsTheDetailsLinkToTheOpener() throws {
        let fake = DetailFake()
        let d = try loadedMailDetailView(fake)
        d.openInOutlook()
        XCTAssertEqual(fake.opened, [URL(string: "https://outlook.office.com/detail/mail")!])
    }

    func testOpenInOutlookFallsBackToTheListItemsLinkWhenTheDetailFailed() throws {
        let fake = DetailFake()
        try oneMailView(fake)
        sut.selectInboxRow(0)
        let d = try XCTUnwrap(sut.detailView)
        XCTAssertNotNil(d.errorText)
        d.openInOutlook()
        XCTAssertEqual(fake.opened, [URL(string: "https://outlook.office.com/m/0")!])
    }

    // MARK: Default prompts

    /// The per-prompt fence nonce, read back from the prompt the view seeded.
    private func promptNonce(_ prompt: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let re = try NSRegularExpression(pattern: "untrusted_(email|agenda)_([0-9a-f]{16,})")
        let m = try XCTUnwrap(re.firstMatch(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)),
                              "no fence tag in the prompt: \(prompt)", file: file, line: line)
        return String(prompt[try XCTUnwrap(Range(m.range(at: 2), in: prompt), file: file, line: line)])
    }

    func testTheAskPromptOpensWithTheInstructionsAndCarriesTheMessage() throws {
        let p = FredDetailPrompts.ask(try mailDetail())
        XCTAssertTrue(p.hasPrefix("Here is an email from my inbox. Summarise it and tell me if it needs a reply; if so, draft one for me to review. Do not send anything."), p)
        for piece in ["Alice Smith <alice@example.com>", "Bob Jones <bob@example.com>",
                      "Sat 10 Oct 2026, 09:10", "Quarterly numbers", "Hello Bob,\nNumbers attached."] {
            XCTAssertTrue(p.contains(piece), "missing \(piece) in \(p)")
        }
    }

    func testThePrepPromptOpensWithTheInstructionsAndCarriesTheMeeting() throws {
        let p = FredDetailPrompts.prep(try eventDetail())
        XCTAssertTrue(p.hasPrefix("Brief me for this meeting: related email threads, related Jira issues, and open questions. Do not RSVP or change the calendar."), p)
        for piece in ["Eng sync", "Olive <olive@example.com>", "Ann (accepted), Ben (no response)", "Agenda: roadmap"] {
            XCTAssertTrue(p.contains(piece), "missing \(piece) in \(p)")
        }
    }

    // MARK: - F1 hardening: fixtures

    private func customDetail(id: String, title: String = "Eng sync", fields: [[String]] = [],
                              markdown: String = "Agenda: roadmap",
                              link: String? = "https://outlook.office.com/detail/event") throws -> WorkItemDetail {
        try decode(WorkItemDetail.self, [
            "item_id": id,
            "title": title,
            "fields": fields,
            "markdown": markdown,
            "files": [String](),
            "links": link.map { [["label": "Open in Outlook", "url": $0]] } ?? [],
        ])
    }

    /// A successful detail for whatever item is asked about.
    private func answerEverything(_ fake: DetailFake) {
        fake.detailResult = { [self] id in
            id.hasPrefix("mail:") ? .success(try! mailDetail(id: id)) : .success(try! eventDetail(id: id))
        }
    }

    private func mailList(ids: [String] = ["m-0", "m-1", "m-2"], read: Set<String> = []) -> [Mail] {
        ids.enumerated().map { i, id in
            Mail(from: "Sender \(id) <s@x.com>", subject: "Subject \(id)", ago: 300 + 300 * TimeInterval(i),
                 read: read.contains(id), id: id)
        }
    }

    private func eventFixture(_ id: String) -> Ev {
        switch id {
        case "e-new": return Ev(title: "Standup", start: at("08:00"), end: at("08:30"), id: id)
        case "e-0": return Ev(title: "Eng sync", start: at("09:30"), end: at("10:00"), id: id)
        case "e-1": return Ev(title: "Design review", start: at("11:30"), end: at("12:30"), id: id)
        default: return Ev(title: "Retro", start: at("14:00"), end: at("15:00"), id: id)
        }
    }

    private func eventList(ids: [String] = ["e-0", "e-1", "e-2"]) -> [Ev] { ids.map(eventFixture) }

    private func listsView(_ fake: DetailFake, mailIds: [String] = ["m-0", "m-1", "m-2"],
                           eventIds: [String] = ["e-0", "e-1", "e-2"]) throws {
        answerEverything(fake)
        makeView(mailbox: try mailbox(items: mailList(ids: mailIds)),
                 calendar: try calendar(events: eventList(ids: eventIds)),
                 detail: fake.actions)
    }

    private func setModel(mailIds: [String]? = ["m-0", "m-1", "m-2"], read: Set<String> = [],
                          eventIds: [String]? = ["e-0", "e-1", "e-2"]) throws {
        sut.model = FredSurfaceModel(
            mailbox: try mailIds.map { try mailbox(items: mailList(ids: $0, read: read)) },
            calendar: try eventIds.map { try calendar(events: eventList(ids: $0)) },
            isConnected: true)
        sut.layoutSubtreeIfNeeded()
    }

    // MARK: - F1 hardening: the clock is a scheduler, not a wall-clock timer

    func testStartClockInstallsOneThirtySecondRepeatingRefreshAndNoOtherRepeatingJob() throws {
        makeView(calendar: try calendar(events: [engSync]))
        sut.startClock()
        XCTAssertEqual(fakeScheduler.activeEvery.map(\.interval), [30],
                       "one live 30 s repeating job, however many times the clock is (re)started")
    }

    func testTheRepeatingRefreshRecomputesTheCountdownFromTheInjectedClock() throws {
        makeView(calendar: try calendar(events: [engSync]))
        sut.startClock()
        XCTAssertEqual(try text("fred.today.countdown"), "Next: Eng sync in 12 min")
        now = at("09:28")   // ten minutes pass; nothing re-renders until the job fires
        fakeScheduler.tickAll()
        XCTAssertEqual(try text("fred.today.countdown"), "Next: Eng sync in 2 min")
    }

    func testLeavingTheWindowStopsTheRepeatingRefresh() throws {
        makeView(calendar: try calendar(events: [engSync]))
        sut.startClock()
        XCTAssertFalse(fakeScheduler.activeEvery.isEmpty)
        window?.contentView = nil
        XCTAssertTrue(fakeScheduler.activeEvery.isEmpty, "no repeating job outlives the view's window")
    }

    // MARK: - F1 hardening: selecting the same item twice

    func testSelectingTheSameInboxRowTwiceKeepsTheSameDetailViewAndAsksTheDaemonOnce() throws {
        let fake = DetailFake()
        try listsView(fake)
        sut.selectInboxRow(0)
        let first = try XCTUnwrap(sut.detailView)
        sut.selectInboxRow(0)
        XCTAssertTrue(sut.detailView === first, "re-selecting the open item must not rebuild its detail")
        XCTAssertEqual(fake.requested, ["mail:m-0"])
    }

    func testSelectingTheSameTodayRowTwiceKeepsTheSameDetailViewAndAsksTheDaemonOnce() throws {
        let fake = DetailFake()
        try listsView(fake)
        sut.selectTodayRow(1)
        let first = try XCTUnwrap(sut.detailView)
        sut.selectTodayRow(1)
        XCTAssertTrue(sut.detailView === first)
        XCTAssertEqual(fake.requested, ["event:e-1"])
    }

    func testSelectingADifferentRowReplacesTheDetailViewAndRequestsThatItem() throws {
        let fake = DetailFake()
        try listsView(fake)
        sut.selectInboxRow(0)
        let first = try XCTUnwrap(sut.detailView)
        sut.selectInboxRow(1)
        let second = try XCTUnwrap(sut.detailView)
        XCTAssertFalse(second === first)
        XCTAssertEqual(fake.requested, ["mail:m-0", "mail:m-1"])
        sut.selectTodayRow(0)
        XCTAssertFalse(try XCTUnwrap(sut.detailView) === second)
        XCTAssertEqual(fake.requested.last, "event:e-0")
    }

    func testAnEditedPromptSurvivesSelectingTheSameRowAgain() throws {
        let fake = DetailFake()
        try listsView(fake)
        sut.selectInboxRow(0)
        let d = try XCTUnwrap(sut.detailView)
        d.beginSeed()
        d.promptText = "My edited prompt"
        sut.selectInboxRow(0)
        XCTAssertTrue(sut.detailView === d)
        XCTAssertTrue(d.isConfirming)
        XCTAssertEqual(d.promptText, "My edited prompt")
        XCTAssertEqual(fake.requested.count, 1)
    }

    func testAnEditedPromptSurvivesAClockTickAndAModelUpdateThatKeepsTheItem() throws {
        let fake = DetailFake()
        try listsView(fake)
        sut.selectInboxRow(1)
        let d = try XCTUnwrap(sut.detailView)
        d.beginSeed()
        d.promptText = "My edited prompt"

        sut.startClock()
        now = at("09:20")
        fakeScheduler.tickAll()
        sut.refreshClock()
        XCTAssertEqual(d.promptText, "My edited prompt", "a tick must not reset the prompt")

        try setModel(read: ["m-0"])   // the item stays, its row moves
        XCTAssertTrue(sut.detailView === d)
        XCTAssertTrue(d.isConfirming)
        XCTAssertEqual(d.promptText, "My edited prompt")
        XCTAssertEqual(fake.requested.count, 1)
    }

    // MARK: - F1 hardening: the selection survives a re-render

    func testNothingIsSelectedUntilTheUserSelectsARow() throws {
        let fake = DetailFake()
        try listsView(fake)
        XCTAssertNil(sut.selectedInboxRow)
        XCTAssertNil(sut.selectedTodayRow)
    }

    func testTheSelectedInboxMessageStaysSelectedWhenItsRowMovesBecauseAnotherMessageWasRead() throws {
        let fake = DetailFake()
        try listsView(fake)
        sut.selectInboxRow(1)   // m-1
        XCTAssertEqual(sut.selectedInboxRow, 1)
        let d = try XCTUnwrap(sut.detailView)

        try setModel(read: ["m-0"])   // unread first: m-1, m-2, then the read m-0
        XCTAssertEqual(sut.selectedInboxRow, 0, "the same message, at its new row")
        XCTAssertNil(sut.selectedTodayRow)
        XCTAssertTrue(sut.detailView === d)
        XCTAssertEqual(fake.requested, ["mail:m-1"], "no new detail request for the same item")

        try setModel(read: ["m-1"])   // now it is read and sinks below the unread ones
        XCTAssertEqual(sut.selectedInboxRow, 2)
        XCTAssertTrue(sut.detailView === d)
        XCTAssertEqual(fake.requested.count, 1)
    }

    func testTheSelectedInboxMessageStaysSelectedWhenANewerMessageArrivesAboveIt() throws {
        let fake = DetailFake()
        try listsView(fake)
        sut.selectInboxRow(1)
        let d = try XCTUnwrap(sut.detailView)
        try setModel(mailIds: ["m-new", "m-0", "m-1", "m-2"])
        XCTAssertEqual(sut.selectedInboxRow, 2)
        XCTAssertTrue(sut.detailView === d)
        XCTAssertEqual(fake.requested.count, 1)
    }

    func testTheSelectedTodayEventStaysSelectedWhenAnEarlierMeetingAppears() throws {
        let fake = DetailFake()
        try listsView(fake)
        sut.selectTodayRow(1)   // e-1
        XCTAssertEqual(sut.selectedTodayRow, 1)
        let d = try XCTUnwrap(sut.detailView)
        try setModel(eventIds: ["e-new", "e-0", "e-1", "e-2"])
        XCTAssertEqual(sut.selectedTodayRow, 2)
        XCTAssertNil(sut.selectedInboxRow)
        XCTAssertTrue(sut.detailView === d)
        XCTAssertEqual(fake.requested, ["event:e-1"])
    }

    func testAClockTickKeepsTheSelectionTheDetailViewAndTheRequestCount() throws {
        let fake = DetailFake()
        try listsView(fake)
        sut.startClock()
        sut.selectInboxRow(2)
        let inboxDetail = try XCTUnwrap(sut.detailView)
        for minute in ["09:19", "09:20", "09:21"] {
            now = at(minute)
            fakeScheduler.tickAll()
            XCTAssertEqual(sut.selectedInboxRow, 2)
            XCTAssertNil(sut.selectedTodayRow)
        }
        sut.refreshClock()
        XCTAssertEqual(sut.selectedInboxRow, 2)
        XCTAssertTrue(sut.detailView === inboxDetail)
        XCTAssertEqual(fake.requested, ["mail:m-2"])

        sut.selectTodayRow(0)
        let todayDetail = try XCTUnwrap(sut.detailView)
        now = at("09:40")
        fakeScheduler.tickAll()
        sut.refreshClock()
        XCTAssertEqual(sut.selectedTodayRow, 0)
        XCTAssertNil(sut.selectedInboxRow, "only one table holds the selection")
        XCTAssertTrue(sut.detailView === todayDetail)
        XCTAssertEqual(fake.requested, ["mail:m-2", "event:e-0"])
    }

    func testSelectingInTheOtherTableClearsTheFirstTablesSelection() throws {
        let fake = DetailFake()
        try listsView(fake)
        sut.selectInboxRow(0)
        sut.selectTodayRow(2)
        XCTAssertNil(sut.selectedInboxRow)
        XCTAssertEqual(sut.selectedTodayRow, 2)
        sut.selectInboxRow(1)
        XCTAssertEqual(sut.selectedInboxRow, 1)
        XCTAssertNil(sut.selectedTodayRow)
        try setModel(read: ["m-2"])
        XCTAssertEqual(sut.selectedInboxRow, 1)
        XCTAssertNil(sut.selectedTodayRow)
    }

    func testWhenTheSelectedItemLeavesTheModelTheDetailStaysAndNoRowIsSelected() throws {
        let fake = DetailFake()
        try listsView(fake)
        sut.selectInboxRow(0)
        let d = try XCTUnwrap(sut.detailView)
        try setModel(mailIds: ["m-1", "m-2"])   // m-0 is gone (e.g. deleted or moved out of the Inbox)
        XCTAssertNil(sut.selectedInboxRow)
        XCTAssertNil(sut.selectedTodayRow)
        XCTAssertTrue(sut.detailView === d, "the open detail is kept: it still describes what the user was reading")
        XCTAssertEqual(fake.requested, ["mail:m-0"])
        try setModel(mailIds: nil, eventIds: nil)
        XCTAssertNil(sut.selectedInboxRow)
        XCTAssertTrue(sut.detailView === d)
        XCTAssertEqual(fake.requested.count, 1)
    }

    func testManyModelUpdatesNeverRequestADetailForTheSameItemAgain() throws {
        let fake = DetailFake()
        try listsView(fake)
        sut.selectInboxRow(1)
        XCTAssertEqual(fake.requested, ["mail:m-1"])
        for i in 0..<6 {
            try setModel(read: i.isMultiple(of: 2) ? ["m-0"] : [])
            sut.refreshClock()
        }
        try setModel(mailIds: ["m-2", "m-1", "m-0"])
        render(mailbox: try mailbox(items: mailList(ids: ["m-1"])), calendar: nil)
        XCTAssertEqual(fake.requested, ["mail:m-1"])
        // Replace the list with different items that no longer contain the selection.
        try setModel(mailIds: ["x-1", "x-2"], eventIds: ["e-new"])
        try setModel(mailIds: ["x-3"], eventIds: [])
        XCTAssertEqual(fake.requested, ["mail:m-1"], "re-rendering is never a selection by the user")
    }

    func testReloadingAListWhileATodayEventIsSelectedNeverRequestsADetailForTheInbox() throws {
        let fake = DetailFake()
        try listsView(fake)
        sut.selectTodayRow(0)
        for read in [Set<String>(), ["m-0"], ["m-0", "m-1"]] {
            try setModel(read: read)
        }
        XCTAssertEqual(fake.requested, ["event:e-0"])
        XCTAssertEqual(sut.selectedTodayRow, 0)
        XCTAssertNil(sut.selectedInboxRow)
    }

    // MARK: - F1 hardening: a seed that finishes after the view was replaced

    private func deferredSeedSetup(_ fake: DetailFake) throws {
        fake.deferSeed = true
        try listsView(fake)
    }

    /// Select `row`, open its confirmation and send, leaving the seed pending.
    private func startPendingSeed(inboxRow row: Int) throws {
        sut.selectInboxRow(row)
        let d = try XCTUnwrap(sut.detailView)
        d.beginSeed()
        d.confirmSeed()
    }

    func testAFredNotRunningResultAfterTheViewWasReplacedStillTellsTheUserHowToRecover() throws {
        let fake = DetailFake()
        try deferredSeedSetup(fake)
        try startPendingSeed(inboxRow: 0)   // no local reference to the view: it may be freed
        XCTAssertEqual(fake.pendingSeeds.count, 1)
        sut.selectInboxRow(1)
        XCTAssertNil(sut.seedBannerText, "nothing has been reported yet")
        fake.pendingSeeds[0](WorkError(code: "fred_not_running", message: "raw"))
        XCTAssertEqual(sut.seedBannerText, FredDetailView.couldNotSeedNotRunning)
        XCTAssertTrue(allText().contains(FredDetailView.couldNotSeedNotRunning),
                      "the message is on screen even though its detail view is gone; saw \(allText())")
    }

    func testASuccessfulSeedAfterTheViewWasReplacedStillConfirmsToTheUser() throws {
        let fake = DetailFake()
        try deferredSeedSetup(fake)
        try startPendingSeed(inboxRow: 0)
        sut.selectInboxRow(1)
        fake.pendingSeeds[0](nil)
        XCTAssertEqual(sut.seedBannerText, "Sent to Fred. Switch to Fred's chat to follow along.")
        XCTAssertTrue(allText().contains("Sent to Fred. Switch to Fred's chat to follow along."))
    }

    func testAnotherSeedErrorAfterTheViewWasReplacedReportsTheDaemonsMessage() throws {
        let fake = DetailFake()
        try deferredSeedSetup(fake)
        try startPendingSeed(inboxRow: 0)
        sut.selectTodayRow(0)
        fake.pendingSeeds[0](WorkError(code: "boom", message: "the pipe broke"))
        XCTAssertEqual(sut.seedBannerText, "Couldn't send to Fred: the pipe broke")
    }

    func testTheSeedBannerIsAlsoSetWhenTheViewIsStillOpen() throws {
        let fake = DetailFake()
        try deferredSeedSetup(fake)
        sut.selectInboxRow(0)
        let d = try XCTUnwrap(sut.detailView)
        d.beginSeed()
        d.confirmSeed()
        fake.pendingSeeds[0](nil)
        XCTAssertEqual(sut.seedBannerText, "Sent to Fred. Switch to Fred's chat to follow along.")
        XCTAssertFalse(d.isConfirming)
    }

    func testTheSeedBannerClearsWhenTheEightSecondTimerFires() throws {
        let fake = DetailFake()
        try deferredSeedSetup(fake)
        try startPendingSeed(inboxRow: 0)
        fake.pendingSeeds[0](nil)
        XCTAssertNotNil(sut.seedBannerText)
        XCTAssertEqual(fakeScheduler.activeAfter.map(\.interval), [8])
        fakeScheduler.fireAfter()
        XCTAssertNil(sut.seedBannerText)
        XCTAssertFalse(allText().contains("Sent to Fred. Switch to Fred's chat to follow along."))
    }

    func testAnOldBannerTimerFiringLateNeverWipesANewerBanner() throws {
        let fake = DetailFake()
        try deferredSeedSetup(fake)
        try startPendingSeed(inboxRow: 0)
        sut.selectInboxRow(1)
        try startPendingSeed(inboxRow: 2)
        XCTAssertEqual(fake.pendingSeeds.count, 2)

        fake.pendingSeeds[0](nil)
        let firstClear = try XCTUnwrap(fakeScheduler.allAfter.last)
        fake.pendingSeeds[1](WorkError(code: "boom", message: "second failed"))
        XCTAssertEqual(sut.seedBannerText, "Couldn't send to Fred: second failed", "the newer result replaces the older")
        let secondClear = try XCTUnwrap(fakeScheduler.allAfter.last)
        XCTAssertFalse(firstClear === secondClear)
        XCTAssertEqual(secondClear.interval, 8)

        fakeScheduler.fire(firstClear)   // even if it was cancelled, a dispatched timer can still run
        XCTAssertEqual(sut.seedBannerText, "Couldn't send to Fred: second failed")
        fakeScheduler.fire(secondClear)
        XCTAssertNil(sut.seedBannerText)
    }

    // MARK: - F1 hardening: Mac-side stale and rate-limited display

    func testRateLimitedPanesWithDataSayWhenTheyRetryAndTheRowsStayUsable() throws {
        let fake = DetailFake()
        answerEverything(fake)
        let updated = now.addingTimeInterval(-20 * 60)
        makeView(mailbox: try mailbox(state: "rate_limited", unread: 12, items: mailList(), stale: true,
                                      error: "Mail fetch failed: Microsoft is rate limiting requests (429)",
                                      updatedAt: updated, retryAt: retryInstant),
                 calendar: try calendar(state: "rate_limited", events: [engSync, designReview], stale: true,
                                        error: "Calendar fetch failed: Microsoft is rate limiting requests (429)",
                                        updatedAt: updated, retryAt: retryInstant),
                 detail: fake.actions)
        for id in ["fred.inbox.banner", "fred.today.banner"] {
            let message = try XCTUnwrap(try bannerMessage(id), "\(id) is showing")
            XCTAssertTrue(message.contains("Rate-limited"), message)
            XCTAssertTrue(message.contains("retrying at"), message)
        }
        XCTAssertEqual(try text("fred.inbox.header"), "Inbox · 12 unread", "the last good count stays")
        XCTAssertEqual(try rowCount(inboxTable), 3)
        XCTAssertEqual(try rowCount(todayTable), 2)

        sut.selectInboxRow(1)
        XCTAssertEqual(fake.requested, ["mail:m-1"], "a rate-limited list still opens details")
        XCTAssertEqual(sut.selectedInboxRow, 1)
        XCTAssertNil(try XCTUnwrap(sut.detailView).errorText)
        sut.startClock()
        fakeScheduler.tickAll()
        XCTAssertTrue(try XCTUnwrap(try bannerMessage("fred.inbox.banner")).contains("retrying at"))
        XCTAssertEqual(sut.selectedInboxRow, 1)

        sut.selectTodayRow(0)
        XCTAssertEqual(fake.requested, ["mail:m-1", "event:e-0"])
    }

    func testStaleBannerKeepsCountingWhileARowStaysSelected() throws {
        let fake = DetailFake()
        answerEverything(fake)
        makeView(mailbox: try mailbox(state: "stale", unread: 12, items: mailList(), stale: true,
                                      error: "Graph timeout", updatedAt: now.addingTimeInterval(-14 * 60)),
                 detail: fake.actions)
        sut.selectInboxRow(0)
        XCTAssertEqual(fake.requested, ["mail:m-0"], "stale data is still selectable")
        let d = try XCTUnwrap(sut.detailView)
        XCTAssertTrue(try XCTUnwrap(try bannerMessage("fred.inbox.banner")).hasPrefix("Stale: last updated 14 min ago"))
        advance(to: at("09:19"))
        let message = try XCTUnwrap(try bannerMessage("fred.inbox.banner"))
        XCTAssertTrue(message.hasPrefix("Stale: last updated 15 min ago"), message)
        XCTAssertTrue(message.hasSuffix("Graph timeout"), message)
        XCTAssertEqual(sut.selectedInboxRow, 0)
        XCTAssertTrue(sut.detailView === d)
        XCTAssertEqual(fake.requested.count, 1)
    }

    func testRecoveringFromRateLimitingKeepsTheOpenDetail() throws {
        let fake = DetailFake()
        answerEverything(fake)
        makeView(mailbox: try mailbox(state: "rate_limited", unread: 3, items: mailList(), stale: true,
                                      updatedAt: now.addingTimeInterval(-60), retryAt: retryInstant),
                 detail: fake.actions)
        sut.selectInboxRow(2)
        let d = try XCTUnwrap(sut.detailView)
        render(mailbox: try mailbox(state: "fresh", items: mailList()))
        XCTAssertNil(try bannerMessage("fred.inbox.banner"))
        XCTAssertTrue(sut.detailView === d)
        XCTAssertEqual(sut.selectedInboxRow, 2)
        XCTAssertEqual(fake.requested, ["mail:m-2"])
    }

    func testARateLimitedPaneThatNeverFetchedAnythingHasNoRowToOpen() throws {
        let fake = DetailFake()
        answerEverything(fake)
        makeView(mailbox: try mailbox(state: "rate_limited", unread: 0, items: [], stale: true, retryAt: retryInstant),
                 detail: fake.actions)
        sut.selectInboxRow(0)
        XCTAssertNil(sut.detailView)
        XCTAssertTrue(fake.requested.isEmpty)
        XCTAssertNil(sut.selectedInboxRow)
    }

    // MARK: - F1 hardening: Open in Outlook only ever opens a validated link

    private func openButton(_ d: FredDetailView) throws -> NSButton { try requireView("fred.detail.open", in: d) }
    private func seedButton(_ d: FredDetailView) throws -> NSButton { try requireView("fred.detail.seed", in: d) }

    private func mailView(_ fake: DetailFake, link: Link = .standard) throws {
        makeView(mailbox: try mailbox(items: [Mail(from: "Alice", subject: "Quarterly numbers", link: link)]),
                 detail: fake.actions)
    }

    func testAnUnsafeDetailLinkIsNeverOpenedAndTheValidListLinkIsUsedInstead() throws {
        for bad in ["file:///etc/passwd", "javascript:alert(1)", "http://outlook.office.com/x",
                    "https://outlook.office.com.evil.example/x", "https://outlook.office.com@evil.example/"] {
            let fake = DetailFake()
            fake.detailResult = { [self] id in .success(try! customDetail(id: id, fields: [["From", "A"]], link: bad)) }
            try mailView(fake)
            sut.selectInboxRow(0)
            let d = try XCTUnwrap(sut.detailView)
            XCTAssertTrue(d.openButtonIsEnabled, bad)
            d.openInOutlook()
            XCTAssertEqual(fake.opened, [URL(string: "https://outlook.office.com/m/0")!], "detail link \(bad)")
        }
    }

    func testAValidDetailLinkWinsAndAnUnsafeListLinkIsIgnored() throws {
        let fake = DetailFake()
        fake.detailResult = { [self] _ in .success(try! mailDetail()) }
        try mailView(fake, link: .custom("file:///etc/passwd"))
        sut.selectInboxRow(0)
        let d = try XCTUnwrap(sut.detailView)
        d.openInOutlook()
        XCTAssertEqual(fake.opened, [URL(string: "https://outlook.office.com/detail/mail")!])
    }

    func testWithNoSafeLinkAnywhereTheButtonIsDisabledExplainsWhyAndOpensNothing() throws {
        let fake = DetailFake()
        fake.detailResult = { [self] id in
            .success(try! customDetail(id: id, fields: [["From", "A"]], link: "javascript:alert(1)"))
        }
        try mailView(fake, link: .custom("http://outlook.office.com/m/0"))
        sut.selectInboxRow(0)
        let d = try XCTUnwrap(sut.detailView)
        XCTAssertFalse(d.openButtonIsEnabled)
        let tip = try XCTUnwrap(d.openButtonToolTip)
        XCTAssertFalse(tip.trimmingCharacters(in: .whitespaces).isEmpty)
        XCTAssertFalse(try openButton(d).isEnabled, "the control agrees with the property")
        XCTAssertEqual(try openButton(d).toolTip, tip)
        d.openInOutlook()
        XCTAssertTrue(fake.opened.isEmpty)
    }

    func testAMessageWithNoLinkAtAllCannotBeOpened() throws {
        let fake = DetailFake()
        fake.detailResult = { [self] id in .success(try! customDetail(id: id, fields: [["From", "A"]], link: nil)) }
        try mailView(fake, link: .absent)
        sut.selectInboxRow(0)
        let d = try XCTUnwrap(sut.detailView)
        XCTAssertFalse(d.openButtonIsEnabled)
        XCTAssertNotNil(d.openButtonToolTip)
        d.openInOutlook()
        XCTAssertTrue(fake.opened.isEmpty)
    }

    func testAValidLinkEnablesTheButtonWithoutATooltipBeforeAndAfterTheDetailLoads() throws {
        let fake = DetailFake()
        fake.deferDetail = true
        try mailView(fake)
        sut.selectInboxRow(0)
        let d = try XCTUnwrap(sut.detailView)
        XCTAssertTrue(d.openButtonIsEnabled, "before the detail loads the list item's link is used")
        XCTAssertNil(d.openButtonToolTip)
        XCTAssertTrue(try openButton(d).isEnabled)
        d.openInOutlook()
        XCTAssertEqual(fake.opened, [URL(string: "https://outlook.office.com/m/0")!])

        fake.pendingDetails[0](.success(try mailDetail()))
        XCTAssertTrue(d.openButtonIsEnabled)
        XCTAssertNil(d.openButtonToolTip)
        XCTAssertTrue(try openButton(d).isEnabled)
    }

    func testBeforeTheDetailLoadsAnUnsafeListLinkLeavesTheButtonDisabled() throws {
        for link in [Link.custom("https://evil.example/m/0"), .custom("file:///etc/passwd"), .absent] {
            let fake = DetailFake()
            fake.deferDetail = true
            try mailView(fake, link: link)
            sut.selectInboxRow(0)
            let d = try XCTUnwrap(sut.detailView)
            XCTAssertFalse(d.openButtonIsEnabled)
            XCTAssertNotNil(d.openButtonToolTip)
            d.openInOutlook()
            XCTAssertTrue(fake.opened.isEmpty)
        }
    }

    func testTheDetailLinkEnablesTheButtonWhenTheListLinkIsUnsafe() throws {
        let fake = DetailFake()
        fake.deferDetail = true
        try mailView(fake, link: .custom("file:///etc/passwd"))
        sut.selectInboxRow(0)
        let d = try XCTUnwrap(sut.detailView)
        XCTAssertFalse(d.openButtonIsEnabled)
        fake.pendingDetails[0](.success(try mailDetail()))
        XCTAssertTrue(d.openButtonIsEnabled)
        XCTAssertNil(d.openButtonToolTip)
    }

    // MARK: - F1 hardening: cancelled and all-day events

    private func eventView(_ fake: DetailFake, _ ev: Ev = Ev(title: "Eng sync", start: FredSurfaceViewTests.at("09:30"), end: FredSurfaceViewTests.at("10:00"))) throws {
        makeView(calendar: try calendar(events: [ev]), detail: fake.actions)
    }

    func testAMailsAskFredButtonIsEnabledOnceLoadedAndNeverCancelled() throws {
        let fake = DetailFake()
        fake.deferDetail = true
        try oneMailView(fake)
        sut.selectInboxRow(0)
        let d = try XCTUnwrap(sut.detailView)
        XCTAssertFalse(d.seedButtonIsEnabled, "nothing to seed until the detail has loaded")
        XCTAssertEqual(d.seedButtonTitle, "Ask Fred…")
        fake.pendingDetails[0](.success(try customDetail(id: "mail:m-0", title: "Cancelled: lunch",
                                                         fields: [["Status", "Cancelled"]])))
        XCTAssertFalse(d.isCancelled, "a message is never cancelled")
        XCTAssertTrue(d.seedButtonIsEnabled)
        XCTAssertEqual(d.seedButtonTitle, "Ask Fred…")
        XCTAssertTrue(try seedButton(d).isEnabled)
        XCTAssertEqual(try seedButton(d).title, "Ask Fred…")
        d.beginSeed()
        XCTAssertTrue(d.isConfirming)
    }

    func testPrepWithFredIsEnabledForALiveEventOnceItsDetailLoads() throws {
        let fake = DetailFake()
        fake.deferDetail = true
        try eventView(fake)
        sut.selectTodayRow(0)
        let d = try XCTUnwrap(sut.detailView)
        XCTAssertFalse(d.seedButtonIsEnabled)
        XCTAssertFalse(d.isCancelled)
        fake.pendingDetails[0](.success(try eventDetail()))
        XCTAssertTrue(d.seedButtonIsEnabled)
        XCTAssertFalse(d.isCancelled)
        XCTAssertEqual(d.seedButtonTitle, "Prep with Fred")
        XCTAssertTrue(try seedButton(d).isEnabled)
    }

    func testAnEventTheDetailSaysIsCancelledCannotBeSeededEvenThoughTheListDoesNotKnow() throws {
        let fake = DetailFake()
        fake.detailResult = { [self] id in
            .success(try! customDetail(id: id, fields: [["Status", "Cancelled"], ["When", "Sat 10 Oct 2026, 09:30\u{2013}10:00"]]))
        }
        try eventView(fake)   // the list event is not cancelled
        sut.selectTodayRow(0)
        let d = try XCTUnwrap(sut.detailView)
        XCTAssertEqual(d.displayedFields.first?.label, "Status")
        XCTAssertEqual(d.displayedFields.first?.value, "Cancelled")
        XCTAssertTrue(d.isCancelled)
        XCTAssertFalse(d.seedButtonIsEnabled)
        XCTAssertFalse(try seedButton(d).isEnabled)
        XCTAssertEqual(d.seedButtonTitle, "Prep with Fred", "the label does not change; the button is just off")

        d.beginSeed()
        XCTAssertFalse(d.isConfirming)
        XCTAssertEqual(d.promptText, "", "no prompt is prepared for a cancelled meeting")
        d.confirmSeed()
        XCTAssertTrue(fake.seeds.isEmpty)
    }

    func testACancelledEventInTheListIsNotSeedableBeforeAndAfterItsDetailLoads() throws {
        let fake = DetailFake()
        fake.deferDetail = true
        try eventView(fake, Ev(title: "Eng sync", start: at("09:30"), end: at("10:00"), isCancelled: true))
        sut.selectTodayRow(0)
        let d = try XCTUnwrap(sut.detailView)
        XCTAssertTrue(d.isCancelled, "known from the list row before the detail arrives")
        XCTAssertFalse(d.seedButtonIsEnabled)
        d.beginSeed()
        XCTAssertFalse(d.isConfirming)

        fake.pendingDetails[0](.success(try eventDetail()))   // the detail carries no Status field
        XCTAssertTrue(d.isCancelled)
        XCTAssertFalse(d.seedButtonIsEnabled)
        d.beginSeed()
        XCTAssertFalse(d.isConfirming)
        XCTAssertEqual(d.seedButtonTitle, "Prep with Fred")
        XCTAssertTrue(fake.seeds.isEmpty)
    }

    func testACancelledStatusInTheListIsEnoughEvenWhenTheDetailFails() throws {
        let fake = DetailFake()   // default: every detail request fails
        try eventView(fake, Ev(title: "Eng sync", start: at("09:30"), end: at("10:00"), status: "cancelled"))
        sut.selectTodayRow(0)
        let d = try XCTUnwrap(sut.detailView)
        XCTAssertNotNil(d.errorText)
        XCTAssertTrue(d.isCancelled)
        XCTAssertFalse(d.seedButtonIsEnabled)
        d.beginSeed()
        XCTAssertFalse(d.isConfirming)
    }

    func testAnEventWithAnotherStatusIsNotCancelled() throws {
        let fake = DetailFake()
        fake.detailResult = { [self] id in .success(try! customDetail(id: id, fields: [["Status", "Tentative"]])) }
        try eventView(fake)
        sut.selectTodayRow(0)
        let d = try XCTUnwrap(sut.detailView)
        XCTAssertFalse(d.isCancelled)
        XCTAssertTrue(d.seedButtonIsEnabled)
        d.beginSeed()
        XCTAssertTrue(d.isConfirming)
    }

    func testAnAllDayEventShowsItsWhenVerbatimAndCanBePrepped() throws {
        let fake = DetailFake()
        fake.detailResult = { [self] id in
            .success(try! customDetail(id: id, title: "Offsite", fields: [["When", "Fri 9 Oct 2026 (all day)"]]))
        }
        try eventView(fake, Ev(title: "Offsite", start: at("00:00"), end: at("23:59"), isAllDay: true))
        sut.selectTodayRow(0)
        let d = try XCTUnwrap(sut.detailView)
        XCTAssertEqual(d.displayedFields.map(\.label), ["When"])
        XCTAssertEqual(d.displayedFields.first?.value, "Fri 9 Oct 2026 (all day)", "shown as sent, never time-converted")
        XCTAssertFalse(d.isCancelled)
        XCTAssertTrue(d.seedButtonIsEnabled)
        d.beginSeed()
        XCTAssertTrue(d.isConfirming)
        XCTAssertTrue(d.promptText.contains("When: Fri 9 Oct 2026 (all day)"), d.promptText)
    }

    func testAMultiDayAllDayEventShowsItsWholeRangeVerbatim() throws {
        let fake = DetailFake()
        let when = "Fri 9 Oct 2026 \u{2013} Sun 11 Oct 2026 (all day)"
        fake.detailResult = { [self] id in .success(try! customDetail(id: id, title: "Offsite", fields: [["When", when]])) }
        try eventView(fake, Ev(title: "Offsite", start: at("00:00"), end: at("23:59"), isAllDay: true))
        sut.selectTodayRow(0)
        let d = try XCTUnwrap(sut.detailView)
        XCTAssertEqual(d.displayedFields.first?.value, when)
        XCTAssertTrue(d.seedButtonIsEnabled)
        XCTAssertEqual(try rowField(todayTable, 0, "fred.row.timerange").stringValue, "All day")
    }

    func testARecurringInstanceDetailBehavesLikeAnyOtherEvent() throws {
        let fake = DetailFake()
        let id = "AAMkAGI2TG93AAA=_20261010T143000Z"
        fake.detailResult = { [self] item in
            .success(try! customDetail(id: item, fields: [["Organiser", "Olive <olive@example.com>"],
                                                          ["Recurrence", "Weekly on Saturday"],
                                                          ["When", "Sat 10 Oct 2026, 09:30\u{2013}10:00"]]))
        }
        try eventView(fake, Ev(title: "Eng sync", start: at("09:30"), end: at("10:00"), id: id))
        sut.selectTodayRow(0)
        XCTAssertEqual(fake.requested, ["event:\(id)"])
        let d = try XCTUnwrap(sut.detailView)
        XCTAssertEqual(d.displayedFields.map(\.label), ["Organiser", "Recurrence", "When"])
        XCTAssertFalse(d.isCancelled)
        XCTAssertTrue(d.seedButtonIsEnabled)
        XCTAssertTrue(d.openButtonIsEnabled)
        d.beginSeed()
        XCTAssertTrue(d.isConfirming)
    }

    // MARK: Daylight-saving boundaries in the Mac list (already correct; these pin it)

    private func isoDate(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    private func listEvent(_ start: String, _ end: String) throws -> CalendarEvent {
        let ev = Ev(title: "Boundary", start: isoDate(start), end: isoDate(end))
        return try XCTUnwrap(try calendar(events: [ev]).events.first)
    }

    func testTheListFormatsAnEventThatSpansTheFallBackHourInChicago() throws {
        // 2026-11-01: 02:00 CDT becomes 01:00 CST. 06:30Z is 1:30 am CDT, 08:00Z is 2:00 am CST.
        let e = try listEvent("2026-11-01T06:30:00Z", "2026-11-01T08:00:00Z")
        XCTAssertEqual(FredPresentation.timeRange(e, in: Self.chicago), "1:30–2:00 am")
    }

    func testTheListFormatsAnEventThatSpansTheSpringForwardGapInChicago() throws {
        // 2026-03-08: 02:00 CST becomes 03:00 CDT. 07:30Z is 1:30 am CST, 09:30Z is 4:30 am CDT.
        let e = try listEvent("2026-03-08T07:30:00Z", "2026-03-08T09:30:00Z")
        XCTAssertEqual(FredPresentation.timeRange(e, in: Self.chicago), "1:30–4:30 am")
    }
}
