import Foundation
import NostromoKit

/// Everything a task window's title and header say about one task, as plain strings, built from the
/// store's task entry, its row and its detail. Pure, so the title, the header, the tooltip and the
/// accessibility label are tested without a window.
///
/// **Every string here came from the CLI or the model** (a description, a prompt, a summary, a
/// subagent type), so each one goes through `FoldTextSanitizer` on its way in: nothing the window
/// draws, copies or reads aloud holds a bidi override, an escape sequence or an invisible filler.
struct TaskWindowContent: Equatable {
    /// The longest description the window title carries (the header has all of it).
    static let titleDescriptionLimit = 80
    /// The longest description or summary the header, tooltip and accessibility label carry.
    static let textLimit = 200

    let focusTag: String
    let taskId: String
    let kind: TaskKindWire
    /// `Shell`, `Monitor`, `Agent`, `Workflow` or `Other`.
    let kindLabel: String
    /// `kate · Agent: Write failing tests`, the description cut to 80 characters.
    let windowTitle: String
    /// The task's description, in full, on one line (the header wraps it).
    let description: String
    /// `running`, `completed`, `failed`, `stopped`, `stopped · restart`.
    let statusText: String
    let isFailed: Bool
    let isEnded: Bool
    /// `Started 2:03:07 PM`; nil when the daemon did not say when.
    let startedText: String?
    /// `Running for 1 m 03 s` or `Ran for 5.0 s` (the duration text of a tool group); nil when unknown.
    let timeText: String?
    /// An ended task's closing words: the completion summary; a running one's progress summary.
    let summary: String?
    /// The prompt an agent was given (daemon detail), preformatted text.
    let prompt: String?
    /// `18.2k tokens · 11 tools · Edit` for an agent; nil when none of it is known.
    let activityText: String?
    /// The CLI's `tool_use.id` of the Agent call (the subagent view's key); never drawn.
    let toolUseId: String?
    /// The daemon can show this task's output.
    let hasOutput: Bool

    /// The title for a task the store no longer lists.
    static func windowTitle(focusName: String, kindLabel: String, description: String) -> String {
        let focus = FoldTextSanitizer.sanitize(focusName)
        let text = FoldTextSanitizer.sanitize(description)
        let cut = text.count > titleDescriptionLimit ? String(text.prefix(titleDescriptionLimit - 1)) + "\u{2026}" : text
        let tail = cut.isEmpty ? kindLabel : "\(kindLabel): \(cut)"
        return focus.isEmpty ? tail : "\(focus) \u{00B7} \(tail)"
    }

    /// The content for `meta`, as of `nowMs` (ms since 1970), shown for the focus named `focusName`.
    /// `row` is the popover's row for the same task (labels, elapsed time); nil when the list no longer
    /// has it (the entry is then labelled from `meta` alone).
    static func make(tag: String, focusName: String, meta: TaskMetaWire, row: BackgroundTaskRow?,
                     detail: SessionTaskDetailWire?, nowMs: UInt64,
                     timeZone: TimeZone = .current, locale: Locale = .current) -> TaskWindowContent {
        let kindLabel = row?.kindLabel ?? BackgroundTaskList.kindLabel(meta.kind)
        let ended = meta.status.isTerminal
        var status = row?.statusLabel ?? BackgroundTaskList.statusLabel(meta.status)
        if meta.status == .stopped {
            switch meta.endReason {
            case .restart?: status += " \u{00B7} restart"
            case .sessionEnded?: status += " \u{00B7} session ended"
            default: break
            }
        }
        let time: String?
        if let ms = (ended ? (meta.durationMs ?? span(meta)) : meta.startedAtMs.map { nowMs >= $0 ? nowMs - $0 : 0 }),
           let text = ToolGroupSummary.durationText(seconds: Double(ms) / 1000) {
            time = (ended ? "Ran for " : "Running for ") + text
        } else {
            time = nil
        }
        let started = meta.startedAtMs.map { ms -> String in
            let formatter = DateFormatter()
            formatter.timeZone = timeZone
            formatter.locale = locale
            formatter.dateStyle = .none
            formatter.timeStyle = .medium
            return "Started " + formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
        }
        let description = cut(oneLine(meta.description))
        let summary = ended ? detail?.completionSummary : detail?.progressSummary
        let activity = meta.kind == .agent ? agentActivity(meta) : nil
        return TaskWindowContent(
            focusTag: tag,
            taskId: meta.id,
            kind: meta.kind,
            kindLabel: kindLabel,
            windowTitle: windowTitle(focusName: focusName, kindLabel: kindLabel, description: meta.description),
            description: description,
            statusText: FoldTextSanitizer.sanitize(status),
            isFailed: meta.status == .failed,
            isEnded: ended,
            startedText: started,
            timeText: time,
            summary: summary.flatMap(multiline).map(cut),
            prompt: detail?.prompt.flatMap(multiline),
            activityText: activity,
            toolUseId: meta.toolUseId,
            hasOutput: meta.hasOutput || meta.kind == .shell || meta.kind == .monitor)
    }

    /// What VoiceOver reads for the header.
    var accessibilityLabel: String {
        [kindLabel, description, statusText, timeText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    // MARK: Private

    private static func cut(_ text: String) -> String {
        text.count > textLimit ? String(text.prefix(textLimit - 1)) + "\u{2026}" : text
    }

    private static func oneLine(_ text: String) -> String {
        FoldTextSanitizer.sanitizeInline(text)
    }

    /// Document text with its line breaks; nil when nothing is left of it.
    private static func multiline(_ text: String) -> String? {
        let clean = FoldTextSanitizer.sanitizeMultiline(text).trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    private static func span(_ meta: TaskMetaWire) -> UInt64? {
        guard let start = meta.startedAtMs, let end = meta.endedAtMs else { return nil }
        return end >= start ? end - start : 0
    }

    private static func agentActivity(_ meta: TaskMetaWire) -> String? {
        let parts = [meta.totalTokens.map(BackgroundTaskList.tokensText), meta.toolUses.map(BackgroundTaskList.toolsText),
                     meta.lastToolName.map { FoldTextSanitizer.sanitize($0) }.flatMap { $0.isEmpty ? nil : $0 }]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ToolGroupSummary.separator)
    }
}
