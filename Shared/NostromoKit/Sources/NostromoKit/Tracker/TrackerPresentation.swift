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
    /// Foldable items whose details (text after the title, and the note) are shown.
    public var expandedItems: Set<String>
    /// Sections whose "Done (N)" group is open.
    public var expandedDoneGroups: Set<String>
    /// The Log shows every line, not just the newest 5.
    public var logExpanded: Bool

    public init(expandedItems: Set<String> = [], expandedDoneGroups: Set<String> = [], logExpanded: Bool = false) {
        self.expandedItems = expandedItems
        self.expandedDoneGroups = expandedDoneGroups
        self.logExpanded = logExpanded
    }
}

// MARK: - Waiting on you

/// One entry of the "Waiting on you" strip.
public struct TrackerWaitingEntry: Equatable {
    /// What a click on the entry goes to. Content-free: an id or a tag, never text from a request.
    public enum Target: Equatable {
        /// Nothing to go to (a source that only informs).
        case none
        /// A board item (a `needs-you` item or a staged command): the pane scrolls to it.
        case boardItem(String)
        /// A pending `nostromo_ask_decision` request: its sheet.
        case decision(String)
        /// The focus's pending approvals: select the focus and show its card.
        case approvals(String)
        /// A failed background task: the background popover.
        case backgroundTask(String)
    }

    /// Unique across sources (`item:<id>` for a tracker item). Two sources that name the same
    /// item share its key, so it is listed once.
    public let key: String
    public let text: String
    /// Where it comes from, shown muted (the section title for a tracker item).
    public let detail: String?
    public let target: Target
    /// How much of the strip's count it stands for: 1, except the approvals entry, which is one
    /// row for however many requests wait (so the count matches the sidebar pill).
    public let weight: Int

    public init(key: String, text: String, detail: String?, target: Target = .none, weight: Int = 1) {
        self.key = key
        self.text = text
        self.detail = detail
        self.target = target
        self.weight = weight
    }
}

/// Something that can put entries in the strip: the board's `needs-you` items, its un-run staged
/// commands, the focus's pending decisions and approvals, and its failed background tasks.
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
                                                   text: TrackerTitle.split(TrackerTitle.stripInvisible(TrackerText.plain(item.textSpans))).title,
                                                   detail: titles[item.section],
                                                   target: .boardItem(item.id)))
            default:
                break
            }
        }
        return entries
    }
}

/// Staged commands the user has not ticked "Ran it" on (`kind == command && !ran`), in file order.
/// Reads the board data only; it does not depend on how the pane draws a command.
public struct TrackerUnrunCommandSource: TrackerWaitingSource {
    public init() {}

    public func waitingEntries(board: TrackerBoardViewWire) -> [TrackerWaitingEntry] {
        var titles: [String: String] = [:]
        var entries: [TrackerWaitingEntry] = []
        for node in board.nodes {
            switch node {
            case .section(let id, let title, _):
                titles[id] = title
            case .item(let item) where item.kind == .command && !item.ran && item.status != .done:
                entries.append(TrackerWaitingEntry(key: "item:\(item.id)",
                                                   text: TrackerTitle.split(TrackerTitle.stripInvisible(TrackerText.plain(item.textSpans))).title,
                                                   detail: titles[item.section],
                                                   target: .boardItem(item.id)))
            default:
                break
            }
        }
        return entries
    }
}

/// A pending decision as the strip shows it: the request and a one-line summary.
public struct TrackerDecisionSummary: Equatable {
    public let requestId: String
    public let text: String

    public init(requestId: String, text: String) {
        self.requestId = requestId
        self.text = text
    }
}

/// The focus's pending `nostromo_ask_decision` requests, in the order given (oldest first).
public struct TrackerDecisionSource: TrackerWaitingSource {
    private let decisions: [TrackerDecisionSummary]

    public init(decisions: [TrackerDecisionSummary]) { self.decisions = decisions }

    public func waitingEntries(board: TrackerBoardViewWire) -> [TrackerWaitingEntry] {
        decisions.map {
            TrackerWaitingEntry(key: "decision:\($0.requestId)", text: $0.text, detail: "Decision",
                                target: .decision($0.requestId))
        }
    }
}

/// The focus's pending approvals: one entry with the count and a link to the card, and never a
/// word of any request's tool or input.
public struct TrackerApprovalsSource: TrackerWaitingSource {
    private let tag: String
    private let pendingCount: Int

    public init(tag: String, pendingCount: Int) {
        self.tag = tag
        self.pendingCount = pendingCount
    }

    public func waitingEntries(board: TrackerBoardViewWire) -> [TrackerWaitingEntry] {
        guard pendingCount > 0 else { return [] }
        let text = pendingCount == 1 ? "1 approval waiting" : "\(pendingCount) approvals waiting"
        return [TrackerWaitingEntry(key: "approvals", text: text, detail: "Approvals",
                                    target: .approvals(tag), weight: pendingCount)]
    }
}

/// Background tasks whose last state is `failed` and which the user has not seen yet (the popover
/// was not opened since they ended: BA's own "seen" rule, so a task leaves here when it leaves the
/// chip). Newest failure first. It lists the tasks, never counts them: the numbers shown for
/// background work come from BA's chip (`TrackerBackgroundSummary`).
public struct TrackerFailedTaskSource: TrackerWaitingSource {
    private let tasks: [TaskMetaWire]
    private let seenEndedAtMs: UInt64?

    public init(tasks: [TaskMetaWire], seenEndedAtMs: UInt64?) {
        self.tasks = tasks
        self.seenEndedAtMs = seenEndedAtMs
    }

    public func waitingEntries(board: TrackerBoardViewWire) -> [TrackerWaitingEntry] {
        var latest: [String: TaskMetaWire] = [:]   // a later entry with the same id wins, as in BA's list
        for task in tasks { latest[task.id] = task }
        let failed = latest.values.filter { task in
            BackgroundTaskList.isListed(task) && !task.housekeeping && task.status == .failed
                && (seenEndedAtMs.map { (task.endedAtMs ?? 0) > $0 } ?? true)
        }
        return failed
            .sorted { ($0.endedAtMs ?? 0, $1.id) > ($1.endedAtMs ?? 0, $0.id) }
            .map { task in
                TrackerWaitingEntry(key: "task:\(task.id)", text: BackgroundTaskList.title(task),
                                    detail: "Background task failed", target: .backgroundTask(task.id))
            }
    }
}

/// The strip's sources in the order the strip lists them: approvals, decisions, un-run commands,
/// `needs-you` items, failed background tasks.
public enum TrackerWaitingSources {
    public static func make(tag: String,
                            approvalsPending: Int,
                            decisions: [TrackerDecisionSummary],
                            tasks: [TaskMetaWire],
                            seenEndedAtMs: UInt64?) -> [TrackerWaitingSource] {
        [TrackerApprovalsSource(tag: tag, pendingCount: approvalsPending),
         TrackerDecisionSource(decisions: decisions),
         TrackerUnrunCommandSource(),
         TrackerNeedsYouSource(),
         TrackerFailedTaskSource(tasks: tasks, seenEndedAtMs: seenEndedAtMs)]
    }
}

/// The one line under the strip for background work: BA's chip text, and nothing counted here.
/// Hidden when the chip is hidden. It tracks the chip because it is built from it.
public struct TrackerBackgroundSummary: Equatable {
    public let chip: BackgroundChipState

    public init(chip: BackgroundChipState) { self.chip = chip }

    public init(list: BackgroundTaskList) { self.init(chip: list.chip) }

    public var isHidden: Bool { chip == .hidden }

    /// `◷ 2 running in the background`, `✕ 1 failed in the background`; nil when hidden.
    public var text: String? { chip.text.map { "\($0) in the background" } }

    public var accessibilityLabel: String? { chip.accessibilityLabel }
}

/// A tracker producer for the app-wide "needs you" source (`NeedsYou.swift`): the board's waiting
/// items as one content-free item each, with no tracker text (a surface shows the reason only).
public enum TrackerNeedsYouProducer {
    public static let name = "tracker"

    /// The `needs-you` board items and un-run commands only. Decisions, approvals and background
    /// tasks already have their own producers (`decisions`, `approvals`); listing them here would
    /// count them twice.
    public static func items(tag: String, board: TrackerBoardViewWire) -> [NeedsYouItem] {
        var seen = Set<String>()
        var out: [NeedsYouItem] = []
        let entries = TrackerUnrunCommandSource().waitingEntries(board: board)
            + TrackerNeedsYouSource().waitingEntries(board: board)
        for entry in entries where seen.insert(entry.key).inserted {
            out.append(NeedsYouItem(id: "\(name):\(tag):\(entry.key)", source: .focus(tag), reason: .trackerWaiting))
        }
        return out
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
    /// Unsettled conflicts on the board: overwritten values and removed items.
    public let conflictCount: Int
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
    /// The sum of the entries' weights (one each, except approvals).
    public var count: Int { entries.reduce(0) { $0 + $1.weight } }
    /// "Waiting on you (N)".
    public var title: String { "Waiting on you (\(count))" }
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
    public internal(set) var updatedAt: Date?
    /// "now", "4 m", "2 h", "Oct 14" (empty without a time).
    public internal(set) var relativeTime: String
    public let noteBlocks: [MdBlock]
    /// The note's first line as plain text (nil without a note). A collapsed item no longer shows
    /// it (the fold holds it); `tracker show` still reports it.
    public let noteFirstLine: String?
    /// The one-line title (`TrackerTitle.split` of `text`).
    public let title: String
    /// The text after the title, shown first under the fold (nil when the text is whole).
    public let bodyLead: String?
    /// There is something under the fold: text after the title, or a note.
    public let isFoldable: Bool
    /// Foldable and the user opened it.
    public internal(set) var isExpanded: Bool
    /// Link texts (what `tracker show` reports).
    public let linkTexts: [String]
    /// The links, rendered as chips.
    public let links: [TrackerLinkWire]
    /// The live source the item follows, if any.
    public let bound: TrackerBoundWire?
    /// "as of 10:42" when the source is badly stale (the item keeps its last value); nil otherwise.
    public let staleFootnote: String?
    public let env: TrackerEnvWire?
    /// `PROD`, `CANADA`, `DEMO`, `STAGING`, `LOCAL`, `ENV?`.
    public let envBadge: String?
    /// The environment is one a mistake there hurts (`PROD`, `CANADA`, `DEMO`, `ENV?`).
    public let isHazard: Bool
    public let kind: TrackerItemKindWire
    /// The staged command as the daemon sent it (nil on a plain item). Untrusted text: draw
    /// `TrackerCommandText.displayed(_:)`, never this.
    public let command: String?
    /// The user ticked "Ran it" (or edited `[x]` into the file).
    public let ran: Bool
    /// The item's exact markdown in the file.
    public let source: String
    /// The task text as stored, raw markdown (what an editor opens with).
    public let editText: String
    /// The note as stored, raw markdown.
    public let editNote: String?
    /// Overwritten values the user hasn't settled.
    public let conflicts: [TrackerConflictWire]
    /// Older overwritten values a cap dropped.
    public let droppedConflicts: Int
    /// Sensitive-looking text the user hasn't cleared.
    public let sensitive: TrackerSensitiveWire?

    public var isDone: Bool { status == .done }
    public var isNeedsYou: Bool { status == .needsYou }
    /// The tick and the status menu apply: not a command (T4's "Ran it") and not a bound item
    /// (its status follows its source).
    public var isTickable: Bool { kind == .item && bound == nil }
    public var isStatusEditable: Bool { isTickable }
    /// A staged command: the pane shows its command block instead of a tick.
    public var isCommand: Bool { kind == .command && command != nil }
    /// "Ran it" applies: a human action on a command (the pane's Tick; an agent can never do it).
    public var canMarkRan: Bool { isCommand }
    /// "Status follows Mother job" for a bound item, nil otherwise.
    public var boundTooltip: String? {
        bound.map { "Status follows \(TrackerConflictText.sourceLabel($0.source))" }
    }
    /// What VoiceOver reads on the conflict mark: the first conflict (who set what, who then changed it, and
    /// what it reads now: the board does not say what the winner set, so the current value is not called theirs),
    /// and how many more. Two writers that are both this pane are told apart as "another window".
    public var conflictSummary: String? {
        guard let first = conflicts.first else { return nil }
        let (loser, winner) = TrackerConflictText.actors(first)
        let current = first.field == "status" ? status.wireName : (first.field == "note" ? (editNote ?? "") : editText)
        var text = "Conflict on \(first.field): \(loser) set \(TrackerConflictText.plain(first.losing, field: first.field)), "
            + "then \(winner) changed it; it now reads \(TrackerConflictText.plain(current, field: first.field))"
        if conflicts.count > 1 { text += ", and \(conflicts.count - 1) more" }
        return text
    }
    /// "Possible sensitive data (phone number). Not shown to the agent."
    public var sensitiveLabel: String? {
        sensitive.map { "Possible sensitive data (\(TrackerConflictText.classList($0.classes))). Not shown to the agent." }
    }
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

/// The "+ Add item" row that ends a section's open items. It carries nothing that changes when an item
/// is added (the pane works out where the new item goes when the user creates it), so adding items never
/// rebuilds the row whose field is open.
public struct TrackerAddRow: Equatable {
    public let sectionId: String
    public let sectionTitle: String
    /// "+ Add item".
    public static let label = "+ Add item"
    /// "Add item to <section title>".
    public var accessibilityLabel: String { "Add item to \(sectionTitle)" }
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
        case addItem(TrackerAddRow)
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
    public static func addKey(_ section: String) -> String { "add:\(section)" }
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

extension TrackerRow {
    /// `other` and this row differ only in whether the item is expanded (the user's own fold
    /// toggle, which is not a content change and must not flash the change highlight).
    public func differsOnlyInFold(from other: TrackerRow) -> Bool {
        guard key == other.key, case .item(let a) = content, case .item(let b) = other.content,
              a.isExpanded != b.isExpanded else { return false }
        return a.withExpanded(b.isExpanded) == b
    }
}

extension TrackerItemRow {
    func withExpanded(_ expanded: Bool) -> TrackerItemRow {
        var copy = self
        copy.isExpanded = expanded
        return copy
    }

    func withTime(_ relative: String, _ updated: Date?) -> TrackerItemRow {
        var copy = self
        copy.relativeTime = relative
        copy.updatedAt = updated
        return copy
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
                               timeZone: TimeZone = .current,
                               editSupported: Bool = true) -> TrackerPresentation {
        // Under All and Open, on a board that can be read, and only when the daemon takes pane edits (an older
        // daemon gets no half-working control): a section ends with its add row.
        let showsAdd = editSupported && board.banner == nil && (filter == .all || filter == .open)
        var builder = RowBuilder(filter: filter, folds: folds, now: now, timeZone: timeZone, showsAdd: showsAdd)
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
            },
            conflictCount: board.removedConflicts.count + board.nodes.reduce(0) { total, node in
                if case .item(let item) = node { return total + item.conflicts.count }
                return total
            })

        return TrackerPresentation(
            header: header,
            banner: board.banner.flatMap { banner(for: $0, path: board.path, now: now, timeZone: timeZone) },
            strip: TrackerStrip(entries: uniqued(sources.flatMap { $0.waitingEntries(board: board) })),
            rows: builder.rows,
            filter: filter,
            foldedItems: builder.folded,
            hiddenItems: builder.hidden,
            hiddenByUser: board.hiddenByUser)
    }

    /// The first entry for each key: an item two sources name (a staged command marked needs-you)
    /// is listed once.
    private static func uniqued(_ entries: [TrackerWaitingEntry]) -> [TrackerWaitingEntry] {
        var seen = Set<String>()
        return entries.filter { seen.insert($0.key).inserted }
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
        let showsAdd: Bool

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

        init(filter: TrackerFilter, folds: TrackerFoldState, now: Date, timeZone: TimeZone, showsAdd: Bool) {
            self.showsAdd = showsAdd
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
            if showsAdd {
                rows.append(TrackerRow(key: TrackerRow.addKey(section.id), content: .addItem(
                    TrackerAddRow(sectionId: section.id, sectionTitle: section.title))))
            }
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

    public static func itemRow(_ wire: TrackerItemWire, sectionTitle: String, folds: TrackerFoldState,
                        now: Date, timeZone: TimeZone) -> TrackerItemRow {
        let lines = TrackerText.lines(wire.noteBlocks)
        let plain = TrackerText.plain(wire.textSpans)
        let split = TrackerTitle.split(TrackerTitle.stripInvisible(plain))
        let foldable = split.rest != nil || !wire.noteBlocks.isEmpty
        return TrackerItemRow(
            id: wire.id,
            sectionId: wire.section,
            sectionTitle: sectionTitle,
            status: wire.status,
            mark: TrackerStatusMark.mark(for: wire.status),
            textSpans: wire.textSpans,
            text: plain,
            owner: wire.owner,
            updatedAt: wire.updatedAt,
            relativeTime: TrackerRelativeTime.short(wire.updatedAt, now: now, timeZone: timeZone),
            noteBlocks: wire.noteBlocks,
            noteFirstLine: lines.first,
            title: split.title,
            bodyLead: split.rest,
            isFoldable: foldable,
            isExpanded: foldable && folds.expandedItems.contains(wire.id),
            linkTexts: wire.links.map(\.text),
            links: wire.links,
            bound: wire.bound,
            staleFootnote: TrackerBoundFootnote.text(wire.bound, timeZone: timeZone),
            env: wire.env,
            envBadge: wire.env.flatMap(TrackerEnvBadge.text),
            isHazard: wire.env.map(TrackerEnvBadge.isHazard) ?? false,
            kind: wire.kind,
            command: wire.command,
            ran: wire.ran,
            source: wire.source,
            editText: wire.text,
            editNote: wire.note,
            conflicts: wire.conflicts,
            droppedConflicts: wire.droppedConflicts,
            sensitive: wire.sensitive)
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

/// What the command block draws and Copy copies. The daemon refuses hostile command text; the Mac
/// still treats whatever arrives as untrusted: it keeps line feeds and tabs, drops every other control,
/// format (bidi, zero-width, BOM) and line/paragraph-separator character, and caps the length.
public enum TrackerCommandText {
    public static let maxScalars = 8_000
    private static let invisiblePadding: Set<UInt32> = [0x115F, 0x1160, 0x3164, 0xFFA0, 0x2800, 0x034F]

    public static func displayed(_ raw: String) -> String {
        var out = String.UnicodeScalarView()
        var count = 0
        for scalar in raw.unicodeScalars {
            if count >= maxScalars { break }
            switch scalar {
            case "\n", "\t":
                break
            default:
                switch scalar.properties.generalCategory {
                case .control, .format, .lineSeparator, .paragraphSeparator: continue
                default: break
                }
                // Blank-looking padding that could hide text off the block's edge (the daemon refuses
                // these too: `is_invisible`).
                if invisiblePadding.contains(scalar.value) { continue }
            }
            out.append(scalar)
            count += 1
        }
        return String(out)
    }

    /// "3 lines" for a command of more than one line, nil for one line.
    public static func lineBadge(_ displayed: String) -> String? {
        let lines = displayed.split(separator: "\n", omittingEmptySubsequences: false).count
        return lines > 1 ? "\(lines) lines" : nil
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

    /// What a copy shows in place of a node this client does not recognise (it carries no source):
    /// a visible comment, so a whole-board copy is never silently missing a piece of the file.
    static let unknownNodePlaceholder = "<!-- nostromo: unrecognised board node -->\n"

    static func source(_ node: TrackerNodeWire) -> String {
        switch node {
        case .title(_, let source), .section(_, _, let source), .logHeading(_, let source),
             .prose(_, _, let source), .logLine(_, _, let source):
            return source
        case .item(let item):
            return item.source
        case .unknown:
            return unknownNodePlaceholder
        }
    }
}

// MARK: - Conflict and badge wording

/// The plain words the pane uses for conflicts and sensitive badges. Values are shown as text, never
/// markdown; labels the daemon sends (`pane (you)`, `file (unknown editor)`, `source …`) become sentences.
public enum TrackerConflictText {
    /// Longest value shown in a conflict (the popover scrolls past it).
    public static let maxValueChars = 500

    /// The two writers of a conflict as the mark names them. Two writers that are both a pane (two windows)
    /// are told apart when the daemon gives them distinct names: the earlier one is "another window".
    public static func actors(_ conflict: TrackerConflictWire) -> (loser: String, winner: String) {
        if conflict.losingBy.hasPrefix("pane"), conflict.winningBy.hasPrefix("pane"), conflict.losingBy != conflict.winningBy {
            return ("another window", "you")
        }
        return (actor(conflict.losingBy), actor(conflict.winningBy))
    }

    /// A value as plain text (no quotes), cut at `maxValueChars`: what a spoken sentence uses.
    public static func plain(_ value: String, field: String) -> String {
        let shown = field == "status" ? value.replacingOccurrences(of: "-", with: " ") : value
        return shown.count > maxValueChars ? String(shown.prefix(maxValueChars)) + "…" : shown
    }

    public static func actor(_ by: String) -> String {
        if by.hasPrefix("pane") { return "you" }
        if by.hasPrefix("file") { return "a file edit" }
        if by.hasPrefix("source") {
            return sourceLabel(String(by.dropFirst("source".count)).trimmingCharacters(in: CharacterSet(charactersIn: " :")))
        }
        return by
    }

    /// "Mother job" or "PR CI" for a bound source; the source's own name otherwise.
    public static func sourceLabel(_ source: String) -> String {
        switch source.lowercased() {
        case "pr.ci": return "PR CI"
        case "mother.job": return "Mother job"
        default: return source.isEmpty ? "its source" : source
        }
    }

    /// A value as one quoted piece of plain text, cut at `maxValueChars`.
    public static func display(_ value: String, field: String) -> String {
        display(field == "status" ? value.replacingOccurrences(of: "-", with: " ") : value)
    }

    public static func display(_ value: String) -> String {
        let shown = value.count > maxValueChars ? String(value.prefix(maxValueChars)) + "…" : value
        return "“\(shown)”"
    }

    public static func classList(_ classes: [String]) -> String {
        let names = classes.map { name -> String in
            switch name {
            case "phone": return "phone number"
            case "ssn": return "social security number"
            case "email": return "email address"
            default: return name.replacingOccurrences(of: "_", with: " ")
            }
        }
        return names.isEmpty ? "sensitive data" : names.joined(separator: ", ")
    }

    /// "4 s", "3 m", "2 h", from the pane's own clock.
    public static func ago(_ date: Date?, now: Date) -> String {
        guard let date else { return "a moment" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) m" }
        return "\(seconds / 3600) h"
    }

    /// "agent claudia set status to “in progress”, then you set it to “done”, 4 s ago."
    public static func sentence(_ conflict: TrackerConflictWire, current: String, now: Date) -> String {
        "\(actor(conflict.losingBy)) set \(conflict.field) to \(display(conflict.losing, field: conflict.field)), then "
            + "\(actor(conflict.winningBy)) set it to \(display(current, field: conflict.field)), \(ago(conflict.at, now: now)) ago."
    }

    /// "agent claudia removed “<title>” 3 s after you changed it."
    public static func sentence(_ removed: TrackerRemovedConflictWire, now: Date) -> String {
        "\(actor(removed.winningBy)) removed \(display(removed.title)) \(ago(removed.at, now: now)) after "
            + "\(actor(removed.losingBy)) changed it."
    }
}
