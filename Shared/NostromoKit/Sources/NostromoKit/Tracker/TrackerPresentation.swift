// NostromoKit — TrackerPresentation.swift
//
// The tracker pane's view model (T1), built from a `tracker_board` snapshot. Pure: no views, no
// clock (`now` is passed in), no UserDefaults, so the Mac pane and a later iOS pane render the same
// rows and `nostromo-app tracker show` reports exactly what the pane shows.
//
// What it produces (design contract §9):
// - a header (title, "updated 2 m ago", the committable badge), a banner and the pinned
//   "Waiting on you (N)" strip, which sit outside the scrolling content;
// - the scrolling rows, each with a stable key the pane diffs by: `section:<id>` (heading with an
//   item count), `item:<id>`, `done:<section>` (the collapsed "Done (N)" group at the end of a
//   section), `prose:<key>`, `log` (newest first, collapsed to 5 lines).
//
// The filter (All / Open / Waiting on you / Done) is the user's view only: it changes which rows
// are built, never the board.

import Foundation

// MARK: - Inputs

/// What the user chose to see. View-only: it never reaches the daemon.
public enum TrackerFilter: String, CaseIterable, Equatable {
    case all
    case open
    case waiting
    case done

    /// The filter control's label.
    public var label: String {
        switch self {
        case .all: return "All"
        case .open: return "Open"
        case .waiting: return "Waiting on you"
        case .done: return "Done"
        }
    }
}

/// The user's disclosure choices, kept by the pane (never by the board).
public struct TrackerFoldState: Equatable {
    /// Items whose long note (more than 2 lines) is shown in full.
    public var expandedNotes: Set<String>
    /// Sections whose "Done (N)" group is open.
    public var expandedDoneGroups: Set<String>
    /// The Log shows every line, not just the newest 5.
    public var logExpanded: Bool

    public init(expandedNotes: Set<String> = [], expandedDoneGroups: Set<String> = [], logExpanded: Bool = false) {
        self.expandedNotes = expandedNotes
        self.expandedDoneGroups = expandedDoneGroups
        self.logExpanded = logExpanded
    }
}

// MARK: - Waiting on you

/// One entry of the "Waiting on you" strip.
public struct TrackerWaitingEntry: Equatable {
    /// Unique across sources (`item:<id>` for a tracker item).
    public let key: String
    public let text: String
    /// Where it comes from, shown muted (the section title for a tracker item).
    public let detail: String?

    public init(key: String, text: String, detail: String?) {
        self.key = key
        self.text = text
        self.detail = detail
    }
}

/// Something that can put entries in the strip. T1 has one source (the board's `needs-you`
/// items); later slices add pending decisions and background work as further conformers.
public protocol TrackerWaitingSource {
    func waitingEntries(board: TrackerBoardViewWire) -> [TrackerWaitingEntry]
}

/// The board's `needs-you` items, in file order. They also stay in their own section.
public struct TrackerNeedsYouSource: TrackerWaitingSource {
    public init() {}

    public func waitingEntries(board: TrackerBoardViewWire) -> [TrackerWaitingEntry] {
        var titles: [String: String] = [:]
        var entries: [TrackerWaitingEntry] = []
        for node in board.nodes {
            switch node {
            case .section(let id, let title, _):
                titles[id] = title
            case .item(let item) where item.status == .needsYou:
                entries.append(TrackerWaitingEntry(key: "item:\(item.id)",
                                                   text: TrackerText.plain(item.textSpans),
                                                   detail: titles[item.section]))
            default:
                break
            }
        }
        return entries
    }
}

// MARK: - Output

/// Above the scroll view: never moves the content.
public struct TrackerHeader: Equatable {
    public let title: String
    public let path: String
    /// "updated 2 m ago" (empty when the board has no time).
    public let updatedText: String
    /// "This file can be committed to <remote>", or nil when the board is not committable.
    public let committableText: String?
}

public struct TrackerBannerRow: Equatable {
    public enum Kind: String, Equatable {
        case unreadable
        case missing
    }
    public static let key = "banner"
    public let kind: Kind
    public let text: String
}

public struct TrackerStrip: Equatable {
    public static let key = "strip"
    public let entries: [TrackerWaitingEntry]
    public init(entries: [TrackerWaitingEntry]) { self.entries = entries }
    public var count: Int { entries.count }
    /// "Waiting on you (N)".
    public var title: String { "Waiting on you (\(entries.count))" }
}

public struct TrackerSectionRow: Equatable {
    public let id: String
    public let title: String
    /// Items in the section that the filter shows (folded done items included under All).
    public let count: Int
}

public struct TrackerItemRow: Equatable {
    public let id: String
    public let sectionId: String
    public let sectionTitle: String
    public let status: TrackerStatusWire
    /// `○ ◐ ⊘ ● ✓`.
    public let mark: String
    public let textSpans: [MdSpan]
    /// The text as plain characters (what Copy-as-text and `tracker show` report).
    public let text: String
    public let owner: String?
    public let updatedAt: Date?
    /// "now", "4 m", "2 h", "Oct 14" (empty without a time).
    public let relativeTime: String
    public let noteBlocks: [MdBlock]
    /// The note's first line as plain text (nil without a note): what a collapsed note shows,
    /// and what a `blocked` item always shows.
    public let noteFirstLine: String?
    /// The note is longer than 2 lines, so it collapses to one with a disclosure.
    public let noteIsCollapsible: Bool
    /// The whole note is shown (a short note, or a long one the user expanded).
    public let noteExpanded: Bool
    /// Link texts, rendered as plain muted text in T1 (T6 makes them chips).
    public let linkTexts: [String]
    public let env: TrackerEnvWire?
    /// `PROD`, `CANADA`, `DEMO`, `STAGING`, `LOCAL`, `ENV?`.
    public let envBadge: String?
    /// The environment is one a mistake there hurts (`PROD`, `CANADA`, `DEMO`, `ENV?`).
    public let isHazard: Bool
    public let kind: TrackerItemKindWire
    /// The item's exact markdown in the file.
    public let source: String

    public var isDone: Bool { status == .done }
    public var isNeedsYou: Bool { status == .needsYou }
}

public struct TrackerDoneGroupRow: Equatable {
    public let sectionId: String
    public let count: Int
    public let expanded: Bool
    /// The done items it holds, in file order.
    public let itemIds: [String]
    /// "Done (N)".
    public var title: String { "Done (\(count))" }
}

public struct TrackerProseRow: Equatable {
    public let key: String
    public let blocks: [MdBlock]
}

public struct TrackerLogRow: Equatable {
    public static let collapsedLines = 5
    public let title: String
    /// Newest first; only the newest 5 unless expanded.
    public let lines: [TrackerLogLineWire]
    public let total: Int
    public let expanded: Bool
    /// More lines exist than the collapsed view shows.
    public var isCollapsible: Bool { total > Self.collapsedLines }
}

/// A row standing in for an item whose change is held back while the user can see it
/// (`TrackerDeferral`): it keeps the item's key and place.
public struct TrackerStubRow: Equatable {
    public enum Kind: Equatable {
        case movedTo(sectionTitle: String)
        case removed
    }
    public let kind: Kind
    /// The item as it was last shown.
    public let item: TrackerItemRow

    /// "moved to Next" / "removed".
    public var text: String {
        switch kind {
        case .movedTo(let title): return "moved to \(title)"
        case .removed: return "removed"
        }
    }
}

public struct TrackerRow: Equatable {
    public enum Content: Equatable {
        case section(TrackerSectionRow)
        case item(TrackerItemRow)
        case doneGroup(TrackerDoneGroupRow)
        case prose(TrackerProseRow)
        case log(TrackerLogRow)
        case stub(TrackerStubRow)
    }

    public let key: String
    public let content: Content

    public init(key: String, content: Content) {
        self.key = key
        self.content = content
    }

    public static func sectionKey(_ id: String) -> String { "section:\(id)" }
    public static func itemKey(_ id: String) -> String { "item:\(id)" }
    public static func doneKey(_ section: String) -> String { "done:\(section)" }
    public static func proseKey(_ key: String) -> String { "prose:\(key)" }
    public static let logKey = "log"

    /// The item this row shows (an item row or a stub), if any.
    public var item: TrackerItemRow? {
        switch content {
        case .item(let item): return item
        case .stub(let stub): return stub.item
        default: return nil
        }
    }

    /// `other` and this row differ only in their relative times: a clock tick, which updates in
    /// place without a highlight.
    public func differsOnlyInTime(from other: TrackerRow) -> Bool {
        guard key == other.key, case .item(let a) = content, case .item(let b) = other.content,
              a != b else { return false }
        return a.updatedAt == b.updatedAt && a.withTime("", nil) == b.withTime("", nil)
    }
}

extension TrackerItemRow {
    func withTime(_ relative: String, _ updated: Date?) -> TrackerItemRow {
        TrackerItemRow(id: id, sectionId: sectionId, sectionTitle: sectionTitle, status: status, mark: mark,
                       textSpans: textSpans, text: text, owner: owner, updatedAt: updated, relativeTime: relative,
                       noteBlocks: noteBlocks, noteFirstLine: noteFirstLine, noteIsCollapsible: noteIsCollapsible,
                       noteExpanded: noteExpanded, linkTexts: linkTexts, env: env, envBadge: envBadge,
                       isHazard: isHazard, kind: kind, source: source)
    }
}

public struct TrackerPresentation: Equatable {
    public let header: TrackerHeader
    public let banner: TrackerBannerRow?
    public let strip: TrackerStrip
    /// The scrolling content, top to bottom.
    public let rows: [TrackerRow]
    public let filter: TrackerFilter
    /// Done items folded into a collapsed "Done (N)" group (not in `rows`), by item id.
    public let foldedItems: [String: TrackerItemRow]
    /// Items the filter leaves out (not in `rows`), by item id. Lets `TrackerDeferral` keep an item
    /// that changes out of the filter's view in place while the reader can see it.
    public let hiddenItems: [String: TrackerItemRow]
    public let hiddenByUser: Bool
}

// MARK: - Building

public enum TrackerPresenter {

    public static func present(board: TrackerBoardViewWire,
                               now: Date,
                               filter: TrackerFilter = .all,
                               folds: TrackerFoldState = TrackerFoldState(),
                               sources: [TrackerWaitingSource] = [TrackerNeedsYouSource()],
                               timeZone: TimeZone = .current) -> TrackerPresentation {
        var builder = RowBuilder(filter: filter, folds: folds, now: now, timeZone: timeZone)
        for node in board.nodes { builder.add(node) }
        builder.finishSection()
        if builder.sawLog || !board.log.isEmpty, filter == .all {
            let newestFirst = Array(board.log.reversed())
            let shown = folds.logExpanded ? newestFirst : Array(newestFirst.prefix(TrackerLogRow.collapsedLines))
            builder.rows.append(TrackerRow(key: TrackerRow.logKey, content: .log(TrackerLogRow(
                title: builder.logTitle ?? "Log", lines: shown, total: board.log.count, expanded: folds.logExpanded))))
        }

        let header = TrackerHeader(
            title: board.title,
            path: board.path,
            updatedText: TrackerRelativeTime.header(board.updatedAt, now: now, timeZone: timeZone),
            committableText: board.committable.map { c in
                c.remote.map { "This file can be committed to \($0)" } ?? "This file can be committed"
            })

        return TrackerPresentation(
            header: header,
            banner: board.banner.flatMap { banner(for: $0, path: board.path, now: now, timeZone: timeZone) },
            strip: TrackerStrip(entries: sources.flatMap { $0.waitingEntries(board: board) }),
            rows: builder.rows,
            filter: filter,
            foldedItems: builder.folded,
            hiddenItems: builder.hidden,
            hiddenByUser: board.hiddenByUser)
    }

    /// "Can't read index.md (line 42: duplicate item id). Showing the version from 10:42" and
    /// "index.md is gone (last seen 10:42)" (PRD, "Malformed, missing or oversized files").
    static func banner(for wire: TrackerBannerWire, path: String, now: Date, timeZone: TimeZone) -> TrackerBannerRow? {
        let file = path.split(separator: "/").last.map(String.init) ?? "The board"
        switch wire {
        case .unreadable(let line, let reason, let lastGoodAt):
            var text = "Can't read \(file) (line \(line): \(readableReason(reason)))."
            if let lastGoodAt {
                text += " Showing the version from \(TrackerRelativeTime.clock(lastGoodAt, now: now, timeZone: timeZone))"
            } else {
                text += " Showing the last good version"
            }
            return TrackerBannerRow(kind: .unreadable, text: text)
        case .missing(let lastSeen):
            let text = lastSeen.map {
                "\(file) is gone (last seen \(TrackerRelativeTime.clock($0, now: now, timeZone: timeZone)))"
            } ?? "\(file) is gone"
            return TrackerBannerRow(kind: .missing, text: text)
        case .unknown:
            return nil
        }
    }

    /// The daemon's reason code in words (`duplicate_id` → "duplicate item id").
    static func readableReason(_ code: String) -> String {
        switch code {
        case "duplicate_id": return "duplicate item id"
        case "invalid_utf8": return "not valid UTF-8"
        case "garbled_marker": return "garbled item marker"
        default: return code.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// Builds the rows one node at a time, closing each section with its Done group.
    private struct RowBuilder {
        let filter: TrackerFilter
        let folds: TrackerFoldState
        let now: Date
        let timeZone: TimeZone

        var rows: [TrackerRow] = []
        var folded: [String: TrackerItemRow] = [:]
        var hidden: [String: TrackerItemRow] = [:]
        var sawLog = false
        var logTitle: String?

        private var section: (id: String, title: String)?
        private var sectionRowIndex: Int?
        private var sectionCount = 0
        private var sectionDone: [TrackerItemRow] = []
        private var inLog = false

        init(filter: TrackerFilter, folds: TrackerFoldState, now: Date, timeZone: TimeZone) {
            self.filter = filter
            self.folds = folds
            self.now = now
            self.timeZone = timeZone
        }

        mutating func add(_ node: TrackerNodeWire) {
            switch node {
            case .title, .logLine, .unknown:
                break
            case .section(let id, let title, _):
                finishSection()
                inLog = false
                section = (id, title)
                sectionRowIndex = rows.count
                rows.append(TrackerRow(key: TrackerRow.sectionKey(id),
                                       content: .section(TrackerSectionRow(id: id, title: title, count: 0))))
            case .logHeading(let title, _):
                finishSection()
                inLog = true
                sawLog = true
                logTitle = title
            case .prose(let key, let blocks, _):
                guard filter == .all, !inLog else { return }
                rows.append(TrackerRow(key: TrackerRow.proseKey(key), content: .prose(TrackerProseRow(key: key, blocks: blocks))))
            case .item(let wire):
                guard !inLog else { return }
                addItem(wire)
            }
        }

        private mutating func addItem(_ wire: TrackerItemWire) {
            let row = TrackerPresenter.itemRow(wire, sectionTitle: section?.title ?? "", folds: folds,
                                              now: now, timeZone: timeZone)
            switch filter {
            case .all:
                sectionCount += 1
                if row.isDone {
                    sectionDone.append(row)
                } else {
                    rows.append(TrackerRow(key: TrackerRow.itemKey(row.id), content: .item(row)))
                }
            case .open, .waiting, .done:
                guard Self.matches(row, filter) else {
                    hidden[row.id] = row
                    return
                }
                sectionCount += 1
                rows.append(TrackerRow(key: TrackerRow.itemKey(row.id), content: .item(row)))
            }
        }

        static func matches(_ row: TrackerItemRow, _ filter: TrackerFilter) -> Bool {
            switch filter {
            case .all: return true
            case .open: return !row.isDone
            case .waiting: return row.isNeedsYou
            case .done: return row.isDone
            }
        }

        /// Close the open section: set its count, add its Done group (All only), and under a
        /// narrowing filter drop a section that shows nothing.
        mutating func finishSection() {
            defer {
                section = nil
                sectionRowIndex = nil
                sectionCount = 0
                sectionDone = []
            }
            guard let section, let index = sectionRowIndex else { return }
            if filter != .all && sectionCount == 0 {
                rows.removeSubrange(index...)
                return
            }
            rows[index] = TrackerRow(key: TrackerRow.sectionKey(section.id),
                                     content: .section(TrackerSectionRow(id: section.id, title: section.title,
                                                                        count: sectionCount)))
            guard filter == .all, !sectionDone.isEmpty else { return }
            let expanded = folds.expandedDoneGroups.contains(section.id)
            rows.append(TrackerRow(key: TrackerRow.doneKey(section.id), content: .doneGroup(TrackerDoneGroupRow(
                sectionId: section.id, count: sectionDone.count, expanded: expanded,
                itemIds: sectionDone.map(\.id)))))
            for item in sectionDone {
                if expanded {
                    rows.append(TrackerRow(key: TrackerRow.itemKey(item.id), content: .item(item)))
                } else {
                    folded[item.id] = item
                }
            }
        }
    }

    static func itemRow(_ wire: TrackerItemWire, sectionTitle: String, folds: TrackerFoldState,
                        now: Date, timeZone: TimeZone) -> TrackerItemRow {
        let lines = TrackerText.lines(wire.noteBlocks)
        let collapsible = lines.count > 2
        return TrackerItemRow(
            id: wire.id,
            sectionId: wire.section,
            sectionTitle: sectionTitle,
            status: wire.status,
            mark: TrackerStatusMark.mark(for: wire.status),
            textSpans: wire.textSpans,
            text: TrackerText.plain(wire.textSpans),
            owner: wire.owner,
            updatedAt: wire.updatedAt,
            relativeTime: TrackerRelativeTime.short(wire.updatedAt, now: now, timeZone: timeZone),
            noteBlocks: wire.noteBlocks,
            noteFirstLine: lines.first,
            noteIsCollapsible: collapsible,
            noteExpanded: !collapsible || folds.expandedNotes.contains(wire.id),
            linkTexts: wire.links.map(\.text),
            env: wire.env,
            envBadge: wire.env.flatMap(TrackerEnvBadge.text),
            isHazard: wire.env.map(TrackerEnvBadge.isHazard) ?? false,
            kind: wire.kind,
            source: wire.source)
    }
}

// MARK: - Small vocabularies

public enum TrackerStatusMark {
    /// `○` todo, `◐` in progress, `⊘` blocked, `●` needs you, `✓` done.
    public static func mark(for status: TrackerStatusWire) -> String {
        switch status {
        case .todo: return "○"
        case .inProgress: return "◐"
        case .blocked: return "⊘"
        case .needsYou: return "●"
        case .done: return "✓"
        case .unknown: return "○"
        }
    }
}

extension TrackerStatusWire {
    /// The wire spelling (`in-progress`), as `tracker show` reports it.
    public var wireName: String {
        switch self {
        case .todo: return "todo"
        case .inProgress: return "in-progress"
        case .blocked: return "blocked"
        case .needsYou: return "needs-you"
        case .done: return "done"
        case .unknown(let raw): return raw
        }
    }
}

public enum TrackerEnvBadge {
    public static func text(_ env: TrackerEnvWire) -> String? {
        switch env {
        case .prod: return "PROD"
        case .canada: return "CANADA"
        case .demo: return "DEMO"
        case .staging: return "STAGING"
        case .local: return "LOCAL"
        case .unset: return "ENV?"
        case .unknown: return nil
        }
    }

    public static func isHazard(_ env: TrackerEnvWire) -> Bool {
        switch env {
        case .prod, .canada, .demo, .unset: return true
        case .staging, .local, .unknown: return false
        }
    }
}

/// Relative times: fixed short forms so the label never changes width much and a tick never
/// reflows a row.
public enum TrackerRelativeTime {

    /// "now" (under a minute, or in the future), "4 m", "2 h", then the date ("Oct 14").
    public static func short(_ date: Date?, now: Date, timeZone: TimeZone = .current) -> String {
        guard let date else { return "" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) m" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600)) h" }
        return formatter("MMM d", timeZone).string(from: date)
    }

    /// The header's "updated 2 m ago" ("updated just now", "updated Oct 14").
    public static func header(_ date: Date?, now: Date, timeZone: TimeZone = .current) -> String {
        guard let date else { return "" }
        return "updated \(since(date, now: now, timeZone: timeZone))"
    }

    /// "just now", "2 m ago", "3 h ago", "Oct 14".
    static func since(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        let text = short(date, now: now, timeZone: timeZone)
        if text == "now" { return "just now" }
        return now.timeIntervalSince(date) < 86_400 ? "\(text) ago" : text
    }

    /// A wall-clock time: "10:42" on `now`'s day, else "Oct 14 10:42".
    public static func clock(_ date: Date, now: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let format = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "MMM d HH:mm"
        return formatter(format, timeZone).string(from: date)
    }

    private static let lock = NSLock()
    private static var formatters: [String: DateFormatter] = [:]

    /// Cached per format and time zone; a `DateFormatter` is costly to make and a board has
    /// hundreds of times.
    private static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(format)|\(timeZone.identifier)"
        if let cached = formatters[key] { return cached }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        formatters[key] = formatter
        return formatter
    }
}

/// Plain text out of the markdown model.
public enum TrackerText {
    public static func plain(_ spans: [MdSpan]) -> String {
        spans.map { plain($0) }.joined()
    }

    public static func plain(_ span: MdSpan) -> String {
        switch span {
        case .text(let text), .code(let text): return text
        case .emph(let spans), .strong(let spans), .strike(let spans): return plain(spans)
        case .link(let spans, _): return plain(spans)
        case .image(let alt, _): return alt
        }
    }

    /// The blocks as plain lines, for counting a note's lines and showing its first one.
    public static func lines(_ blocks: [MdBlock]) -> [String] {
        blocks.flatMap(lines)
    }

    static func lines(_ block: MdBlock) -> [String] {
        switch block {
        case .paragraph(let spans), .heading(_, let spans):
            return plain(spans).components(separatedBy: "\n")
        case .codeBlock(_, let text):
            var parts = text.components(separatedBy: "\n")
            if parts.last == "" { parts.removeLast() }
            return parts
        case .list(_, _, let items):
            return items.flatMap { lines($0) }
        case .quote(let blocks):
            return lines(blocks)
        case .table(let header, let rows):
            return ([header] + rows).filter { !$0.isEmpty }.map { row in row.map { plain($0) }.joined(separator: " | ") }
        case .rule:
            return ["—"]
        }
    }
}

// MARK: - Copy as Markdown

/// The file's own markdown for a part of the board, from the nodes' `source` (contract §5), so
/// a copy is the file's text and the whole board is the file's bytes.
public enum TrackerMarkdown {

    /// Every node's `source` in order, title line first.
    public static func board(_ board: TrackerBoardViewWire) -> String {
        board.nodes.map { Self.source($0) }.joined()
    }

    /// The section's heading and everything under it, up to the next section or the Log.
    public static func section(_ id: String, in board: TrackerBoardViewWire) -> String? {
        var out: String?
        for node in board.nodes {
            switch node {
            case .section(let sid, _, let source):
                if out != nil { return out }
                if sid == id { out = source }
            case .logHeading:
                if out != nil { return out }
            default:
                if out != nil { out! += Self.source(node) }
            }
        }
        return out
    }

    public static func item(_ id: String, in board: TrackerBoardViewWire) -> String? {
        for node in board.nodes {
            if case .item(let item) = node, item.id == id { return item.source }
        }
        return nil
    }

    static func source(_ node: TrackerNodeWire) -> String {
        switch node {
        case .title(_, let source), .section(_, _, let source), .logHeading(_, let source),
             .prose(_, _, let source), .logLine(_, _, let source):
            return source
        case .item(let item):
            return item.source
        case .unknown:
            return ""
        }
    }
}
