// NostromoKit — BackgroundTaskList.swift
//
// What the Background activity chip and popover show for one focus, from the daemon's task
// snapshot (`session_tasks`), the local details (`session_task_detail`), the time now and the
// "seen" mark. Pure and platform-free: the Mac popover, the Mac chip, `nostromo-app tasks` and
// (later) iOS all read the same values from here.
//
// Rules (PRD "What counts as a task", design contract §2.7):
// - Listed: every agent (foreground too), monitor, workflow and other/unknown kind; a shell only
//   once it is in the background.
// - Housekeeping tasks are never counted; they appear only in the Housekeeping section.
// - Running (pending, running, paused, or a status this client does not know): newest first,
//   children under their parent at any depth (indent capped at 3); a child whose parent is not
//   in the running section is top level.
// - Ended: the 20 most recent, newest first.
// - Unknown values are absent, never zero.

import Foundation

// MARK: - Chip

/// What the chip in the input bar shows.
public enum BackgroundChipState: Equatable {
    case hidden
    /// Listed, non-housekeeping tasks that have not ended.
    case running(Int)
    /// Ended since the popover was last opened, none of them failed.
    case done(Int)
    /// Ended since the popover was last opened, this many failed.
    case failed(Int)

    /// Counts above this read `99+` in the chip, so its text never outgrows the slot reserved for it.
    public static let countCap = 99

    /// `◷ 2 running`, `✓ 3 done`, `✕ 1 failed` (`◷ 99+ running` from 100); nil when hidden.
    public var text: String? {
        switch self {
        case .hidden: return nil
        case .running(let n): return "\(icon ?? "") \(Self.countText(n)) running"
        case .done(let n): return "\(icon ?? "") \(Self.countText(n)) done"
        case .failed(let n): return "\(icon ?? "") \(Self.countText(n)) failed"
        }
    }

    /// The glyph alone (`◷`, `✓`, `✕`), what the chip shows when the bar is too narrow for its text;
    /// nil when hidden.
    public var icon: String? {
        switch self {
        case .hidden: return nil
        case .running: return "\u{25F7}"
        case .done: return "\u{2713}"
        case .failed: return "\u{2715}"
        }
    }

    private static func countText(_ n: Int) -> String {
        n > countCap ? "\(countCap)+" : "\(n)"
    }

    /// `hidden`, `running`, `done` or `failed` (what `nostromo-app tasks chip` reports).
    public var name: String {
        switch self {
        case .hidden: return "hidden"
        case .running: return "running"
        case .done: return "done"
        case .failed: return "failed"
        }
    }

    /// `Background activity: 2 running`; nil when hidden.
    public var accessibilityLabel: String? {
        switch self {
        case .hidden: return nil
        case .running(let n): return "Background activity: \(n) running"
        case .done(let n): return "Background activity: \(n) done"
        case .failed(let n): return "Background activity: \(n) failed"
        }
    }
}

// MARK: - Row

/// Which part of the popover a row is in.
public enum BackgroundTaskSection: String, Equatable {
    case running
    case ended
    case housekeeping
}

/// One task as a popover row (and a `tasks list` entry).
public struct BackgroundTaskRow: Equatable {
    public let id: String
    public let section: BackgroundTaskSection
    public let kind: TaskKindWire
    /// `Shell`, `Monitor`, `Agent`, `Workflow` or `Other`.
    public let kindLabel: String
    /// The CLI's own kind name (`local_bash`, …); nil when it sent none.
    public let kindName: String?
    /// The task's own description, verbatim (tooltip, Copy Description).
    public let description: String
    /// What the row reads: `redd · Write failing tests`, the workflow's name, `remote_agent · …`.
    public let title: String
    public let status: TaskStatusWire
    /// `running`, `paused`, `completed`, `failed`, `stopped` (`pending` before it starts).
    public let statusLabel: String
    /// `◷` not ended, `✓` completed, `✕` failed, `■` stopped.
    public let statusIcon: String
    public let isEnded: Bool
    public let isFailed: Bool
    public let endReason: TaskEndReasonWire?
    /// Running: time since it started.
    public let elapsedMs: UInt64?
    /// Ended: how long it ran.
    public let durationMs: UInt64?
    /// Ended: time since it ended.
    public let endedAgoMs: UInt64?
    /// The elapsed time (running) or the duration (ended), as text.
    public let timeText: String?
    /// `4 m ago` (ended only).
    public let endedAgoText: String?
    /// The latest sign of life, one line: an agent's progress or counts, a shell's last line.
    public let signOfLife: String?
    /// The parent task id as the daemon sent it.
    public let parentId: String?
    /// Indentation level under its parent (0 at top level, at most `BackgroundTaskList.maxDepth`).
    public let depth: Int
    public let isHousekeeping: Bool
    /// Not ended, and the daemon has not said the CLI cannot stop tasks (BA5).
    public let stopOffered: Bool

    /// What VoiceOver reads for the row: kind, description, status, time.
    public var accessibilityLabel: String {
        [kindLabel, title, statusLabel, timeText, endedAgoText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

// MARK: - The list

/// Everything the popover and the chip show for one focus.
public struct BackgroundTaskList: Equatable {
    /// How many ended tasks the Ended section keeps.
    public static let endedLimit = 20
    /// Children deeper than this are drawn at this depth.
    public static let maxDepth = 3

    /// Not ended, in display order (each parent followed by its children).
    public let running: [BackgroundTaskRow]
    /// The most recent ended tasks, newest first.
    public let ended: [BackgroundTaskRow]
    /// Housekeeping tasks, running first, then newest first.
    public let housekeeping: [BackgroundTaskRow]
    public let chip: BackgroundChipState

    /// The chip's tooltip: the first three running tasks' titles, one per line.
    public var chipTooltip: String? {
        switch chip {
        case .hidden:
            return nil
        case .running:
            return running.prefix(3).map { $0.title }.joined(separator: "\n")
        case .done(let n):
            return "\(n) background task\(n == 1 ? "" : "s") ended"
        case .failed(let n):
            return "\(n) background task\(n == 1 ? "" : "s") failed"
        }
    }

    /// `2 running` (the popover header).
    public var runningCountText: String { "\(running.count) running" }

    public var isEmpty: Bool { running.isEmpty && ended.isEmpty && housekeeping.isEmpty }

    /// Every row, running, then ended, then housekeeping.
    public var allRows: [BackgroundTaskRow] { running + ended + housekeeping }

    public static let empty = BackgroundTaskList(running: [], ended: [], housekeeping: [], chip: .hidden)

    public init(running: [BackgroundTaskRow], ended: [BackgroundTaskRow], housekeeping: [BackgroundTaskRow],
                chip: BackgroundChipState) {
        self.running = running
        self.ended = ended
        self.housekeeping = housekeeping
        self.chip = chip
    }

    /// Build the list.
    /// - Parameters:
    ///   - tasks: the snapshot's tasks (and any the client keeps itself, e.g. restart-stopped ones).
    ///   - details: `session_task_detail` per task id.
    ///   - nowMs: the time now, in ms since 1970 (the daemon's `*_at_ms` clock).
    ///   - seenEndedAtMs: the highest `ended_at_ms` the user has seen (the popover was opened); nil
    ///     if never.
    ///   - stopSupported: the snapshot's `stop_supported`.
    public static func make(tasks: [TaskMetaWire],
                            details: [String: SessionTaskDetailWire] = [:],
                            nowMs: UInt64,
                            seenEndedAtMs: UInt64? = nil,
                            stopSupported: Bool? = nil) -> BackgroundTaskList {
        let listed = uniqued(tasks).filter(isListed)
        let ordinary = listed.filter { !$0.housekeeping }
        let live = ordinary.filter { !$0.status.isTerminal }
        let over = ordinary.filter { $0.status.isTerminal }

        func row(_ task: TaskMetaWire, _ section: BackgroundTaskSection, depth: Int) -> BackgroundTaskRow {
            makeRow(task, section: section, depth: depth, detail: details[task.id], nowMs: nowMs,
                    stopSupported: stopSupported)
        }

        // Running: a tree, newest first at every level.
        let liveIds = Set(live.map(\.id))
        var children: [String: [TaskMetaWire]] = [:]
        var roots: [TaskMetaWire] = []
        for task in live {
            if let parent = task.parentTaskId, parent != task.id, liveIds.contains(parent) {
                children[parent, default: []].append(task)
            } else {
                roots.append(task)
            }
        }
        var running: [BackgroundTaskRow] = []
        var placed = Set<String>()
        func place(_ task: TaskMetaWire, level: Int) {
            guard placed.insert(task.id).inserted else { return }
            running.append(row(task, .running, depth: min(level, maxDepth)))
            for child in newestFirst(children[task.id] ?? []) { place(child, level: level + 1) }
        }
        for root in newestFirst(roots) { place(root, level: 0) }
        // A parent cycle has no root: its tasks still show, at the top level.
        for task in newestFirst(live) where !placed.contains(task.id) { place(task, level: 0) }

        // Ended: flat, most recently ended first.
        let ended = over
            .enumerated()
            .sorted { a, b in
                let ea = a.element.endedAtMs ?? 0, eb = b.element.endedAtMs ?? 0
                return ea != eb ? ea > eb : a.offset > b.offset
            }
            .prefix(endedLimit)
            .map { row($0.element, .ended, depth: 0) }

        let chores = listed.filter(\.housekeeping)
        let housekeeping = (newestFirst(chores.filter { !$0.status.isTerminal })
                            + newestFirst(chores.filter { $0.status.isTerminal }))
            .map { row($0, .housekeeping, depth: 0) }

        let chip = chipState(runningCount: running.count, ended: over, seenEndedAtMs: seenEndedAtMs)
        return BackgroundTaskList(running: running, ended: ended, housekeeping: housekeeping, chip: chip)
    }

    /// Running wins; else ended tasks newer than the seen mark (never opened: all of them), failed
    /// ones first; else hidden. Housekeeping tasks are not passed in: they never count.
    private static func chipState(runningCount: Int, ended: [TaskMetaWire],
                                  seenEndedAtMs: UInt64?) -> BackgroundChipState {
        if runningCount > 0 { return .running(runningCount) }
        let unseen = ended.filter { task in
            guard let seen = seenEndedAtMs else { return true }
            return (task.endedAtMs ?? 0) > seen
        }
        let failures = unseen.filter { $0.status == .failed }.count
        if failures > 0 { return .failed(failures) }
        return unseen.isEmpty ? .hidden : .done(unseen.count)
    }

    /// The `ended_at_ms` high-water mark of `tasks`: what "the user has seen everything" means.
    public static func seenMark(of tasks: [TaskMetaWire]) -> UInt64? {
        tasks.filter { $0.status.isTerminal }.compactMap(\.endedAtMs).max()
    }

    // MARK: Listing rule

    /// Listed iff an agent (foreground or background), a monitor, a background shell, a workflow
    /// or any other kind.
    public static func isListed(_ task: TaskMetaWire) -> Bool {
        switch task.kind {
        case .shell: return task.isBackgrounded == true
        case .agent, .monitor, .workflow, .other, .unknown: return true
        }
    }

    // MARK: Labels

    public static func kindLabel(_ kind: TaskKindWire) -> String {
        switch kind {
        case .shell: return "Shell"
        case .monitor: return "Monitor"
        case .agent: return "Agent"
        case .workflow: return "Workflow"
        case .other, .unknown: return "Other"
        }
    }

    public static func statusLabel(_ status: TaskStatusWire) -> String {
        switch status {
        case .pending: return "pending"
        case .running: return "running"
        case .paused: return "paused"
        case .completed: return "completed"
        case .failed: return "failed"
        case .stopped: return "stopped"
        case .unknown(let raw): return boundedStatus(raw)
        }
    }

    /// The longest status text a row shows; the daemon's own words for a status this client does
    /// not know are cut to this (control characters removed first).
    public static let statusTextLimit = 24

    /// `raw` on one line without control characters, at most `statusTextLimit` characters (the cut
    /// ends in `…`); `unknown` when nothing printable is left.
    static func boundedStatus(_ raw: String) -> String {
        let printable = String(String.UnicodeScalarView(raw.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
        })).trimmingCharacters(in: .whitespaces)
        if printable.isEmpty { return "unknown" }
        guard printable.count > statusTextLimit else { return printable }
        return String(printable.prefix(statusTextLimit - 1)) + "\u{2026}"
    }

    public static func statusIcon(_ status: TaskStatusWire) -> String {
        switch status {
        case .completed: return "\u{2713}"
        case .failed: return "\u{2715}"
        case .stopped: return "\u{25A0}"
        case .pending, .running, .paused, .unknown: return "\u{25F7}"
        }
    }

    /// The row's title: `<subagent_type> · <description>` for an agent with a type, the
    /// workflow's name for a workflow, `<task_type> · <description>` for any other kind, else the
    /// description.
    public static func title(_ task: TaskMetaWire) -> String {
        let description = oneLine(task.description)
        func joined(_ prefix: String?) -> String {
            guard let prefix = prefix.map(oneLine), !prefix.isEmpty else { return description }
            return description.isEmpty ? prefix : prefix + separator + description
        }
        switch task.kind {
        case .agent:
            return joined(task.subagentType)
        case .workflow:
            if let name = task.workflowName.map(oneLine), !name.isEmpty { return name }
            return description
        case .other, .unknown:
            return joined(kindName(task))
        case .shell, .monitor:
            return description
        }
    }

    /// The CLI's own name for the task's kind: its `task_type`, else the kind string this client
    /// did not recognise; nil when neither was sent.
    public static func kindName(_ task: TaskMetaWire) -> String? {
        if !task.taskType.isEmpty { return task.taskType }
        if case .unknown(let raw) = task.kind, !raw.isEmpty { return raw }
        return nil
    }

    /// `950 tokens`, `18.2k tokens`, `1.3M tokens`.
    public static func tokensText(_ tokens: UInt64) -> String {
        if tokens < 1000 { return "\(tokens) tokens" }
        if tokens < 1_000_000 { return "\(oneDecimal(Double(tokens) / 1000))k tokens" }
        return "\(oneDecimal(Double(tokens) / 1_000_000))M tokens"
    }

    /// `11 tools`, `1 tool`.
    public static func toolsText(_ count: UInt64) -> String {
        "\(count) tool\(count == 1 ? "" : "s")"
    }

    /// `12 s ago`, `4 m ago`, `3 h ago`, `2 d ago`.
    public static func agoText(ms: UInt64) -> String {
        let seconds = ms / 1000
        if seconds < 60 { return "\(seconds) s ago" }
        if seconds < 3600 { return "\(seconds / 60) m ago" }
        if seconds < 86_400 { return "\(seconds / 3600) h ago" }
        return "\(seconds / 86_400) d ago"
    }

    /// The latest sign of life: an agent's progress summary, else `18.2k tokens · 11 tools · Edit`
    /// with unknown parts left out; a shell's or monitor's `last: <line>`; nil when nothing is known.
    public static func signOfLife(_ task: TaskMetaWire, detail: SessionTaskDetailWire?) -> String? {
        switch task.kind {
        case .agent:
            if let summary = nonEmpty(detail?.progressSummary) { return summary }
            let parts = [task.totalTokens.map(tokensText), task.toolUses.map(toolsText),
                         task.lastToolName.map(oneLine).flatMap { $0.isEmpty ? nil : $0 }]
                .compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: separator)
        case .shell, .monitor:
            return nonEmpty(detail?.preview).map { "last: " + $0 }
        case .workflow, .other, .unknown:
            return nonEmpty(detail?.progressSummary)
        }
    }

    // MARK: Private

    static let separator = ToolGroupSummary.separator

    private static func makeRow(_ task: TaskMetaWire, section: BackgroundTaskSection, depth: Int,
                                detail: SessionTaskDetailWire?, nowMs: UInt64,
                                stopSupported: Bool?) -> BackgroundTaskRow {
        let ended = task.status.isTerminal
        let elapsed: UInt64? = ended ? nil : task.startedAtMs.map { msBetween($0, nowMs) }
        let duration: UInt64? = ended ? ranFor(task) : nil
        let ago: UInt64? = ended ? task.endedAtMs.map { msBetween($0, nowMs) } : nil
        let time = (elapsed ?? duration).flatMap { ToolGroupSummary.durationText(seconds: Double($0) / 1000) }
        return BackgroundTaskRow(
            id: task.id,
            section: section,
            kind: task.kind,
            kindLabel: kindLabel(task.kind),
            kindName: kindName(task),
            description: task.description,
            title: title(task),
            status: task.status,
            statusLabel: statusLabel(task.status),
            statusIcon: statusIcon(task.status),
            isEnded: ended,
            isFailed: task.status == .failed,
            endReason: task.endReason,
            elapsedMs: elapsed,
            durationMs: duration,
            endedAgoMs: ago,
            timeText: time,
            endedAgoText: ago.map { agoText(ms: $0) },
            signOfLife: signOfLife(task, detail: detail),
            parentId: task.parentTaskId,
            depth: depth,
            isHousekeeping: task.housekeeping,
            stopOffered: !ended && stopSupported != false)
    }

    /// One entry per id: the last one wins (a client-kept entry never doubles a daemon one).
    private static func uniqued(_ tasks: [TaskMetaWire]) -> [TaskMetaWire] {
        var index: [String: Int] = [:]
        var out: [TaskMetaWire] = []
        for task in tasks {
            if let at = index[task.id] {
                out[at] = task
            } else {
                index[task.id] = out.count
                out.append(task)
            }
        }
        return out
    }

    /// Most recently started first; unknown start times last; ties keep the later entry first.
    private static func newestFirst(_ tasks: [TaskMetaWire]) -> [TaskMetaWire] {
        tasks.enumerated().sorted { a, b in
            let sa = a.element.startedAtMs, sb = b.element.startedAtMs
            switch (sa, sb) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.offset > b.offset
            }
        }.map(\.element)
    }

    /// How long an ended task ran: the daemon's own duration, else end minus start; nil if unknown.
    private static func ranFor(_ task: TaskMetaWire) -> UInt64? {
        if let duration = task.durationMs { return duration }
        guard let start = task.startedAtMs, let end = task.endedAtMs else { return nil }
        return msBetween(start, end)
    }

    /// `to - from`, never negative (timestamps out of order read as zero).
    private static func msBetween(_ from: UInt64, _ to: UInt64) -> UInt64 {
        to >= from ? to - from : 0
    }

    /// One line: newlines and tabs become spaces, ends trimmed.
    static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = oneLine(text)
        return line.isEmpty ? nil : line
    }

    /// One decimal below 100 (`18.2`, `1.0`), none from 100 (`250`); rounded down, so `999.95k` stays `999k`.
    private static func oneDecimal(_ value: Double) -> String {
        if value >= 100 { return "\(Int(value.rounded(.down)))" }
        let tenths = Int((value * 10).rounded(.down))
        return "\(tenths / 10).\(tenths % 10)"
    }
}
