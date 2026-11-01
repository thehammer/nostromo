import Foundation
import NostromoKit

/// READ-ONLY JSON for `nostromo-app tasks list` and `tasks chip` (BA3). Pure formatting of the same
/// `BackgroundTaskList` the popover and the chip show, so the two can never disagree. Changes nothing.
///
/// Unknown values are `null`, never zero.
enum AppControlTasks {

    /// `--focus TAG` must name a focus this app knows (a pane in some window, or one the task store has
    /// heard of): a typo answers with the tags it could have meant, not with an empty, hidden result.
    static func requireKnownFocus(_ focus: String, known: Set<String>) throws {
        guard known.contains(focus) else {
            throw AppControlError.notFound("no focus tagged \"\(focus)\"; known tags: \(known.sorted())")
        }
    }

    /// `tasks list [--all]`: the running section; with `all`, the Ended and Housekeeping rows too.
    /// `windowOpen` says whether a task has its window open now (the only live signal of one: app-control
    /// cannot reach task windows).
    static func list(tag: String, list: BackgroundTaskList, all: Bool,
                     windowOpen: (String) -> Bool = { _ in false }) -> [String: Any] {
        let rows = all ? list.allRows : list.running
        return [
            "tag": tag,
            "running": list.running.count,
            "chip": chip(tag: tag, list: list),
            "tasks": rows.map { row($0, windowOpen: windowOpen($0.id)) },
        ]
    }

    /// The most text `tasks output` returns (the end of the output), whatever the model holds.
    static let outputTextLimit = 1_048_576

    /// How long a `tasks output` ask keeps the model held after answering, so its reads can finish.
    static let outputHoldSeconds: TimeInterval = 3

    static let outputWithheldReason = "task output is withheld in the real app (it can hold anything a command printed); "
        + "the isolated QA instance returns it"

    /// `tasks output TASK_ID`: what the task window shows, from the same `TaskOutputModel`. `text` is the
    /// end of what the model holds, at most `outputTextLimit` bytes; `truncated` is true when the start of
    /// the output is not in it (the model cut it, or this cap did). With `allowsText` false (the real
    /// app: `SyntheticInputGate.allowsSynthetic`) the text is `null` and `refusal` says why; the rest
    /// still answers. `state` is `loading` while the model is still reading (ask again), then `ready`,
    /// `unavailable` or `error`.
    static func output(tag: String, taskId: String, model: TaskOutputModel, allowsText: Bool) -> [String: Any] {
        let text = capped(model.text)
        let loading = model.state == .loading || model.isFillingHead || model.isRefreshing
        let total: Any = (loading || model.state != .ready) ? NSNull() : model.totalBytes
        let shownText: Any = allowsText ? text.text : NSNull()
        var result: [String: Any] = [
            "tag": tag,
            "task_id": taskId,
            "state": loading ? "loading" : model.stateName,
            "truncated": model.truncatedHead || text.wasCut,
            "total_bytes": total,
            "source": sourceName(model.source),
            "text": shownText,
        ]
        if !allowsText { result["refusal"] = outputWithheldReason }
        return result
    }

    private static func sourceName(_ source: TaskOutputSourceWire?) -> Any {
        switch source {
        case .file?: return "file"
        case .cliTail?: return "cli_tail"
        case .unknown(let raw)?: return FoldTextSanitizer.sanitize(raw)
        case nil: return NSNull()
        }
    }

    /// The last `outputTextLimit` UTF-8 bytes of `text`, cut at a line start when it has to be cut.
    private static func capped(_ text: String) -> (text: String, wasCut: Bool) {
        guard text.utf8.count > outputTextLimit else { return (text, false) }
        return (TaskOutputModel.lastBytes(of: text, outputTextLimit), true)
    }

    /// `tasks chip`: the chip's text (null when hidden) and state.
    static func chip(tag: String, list: BackgroundTaskList) -> [String: Any] {
        [
            "tag": tag,
            "text": value(list.chip.text),
            "state": list.chip.name,
        ]
    }

    /// One task as the popover shows it.
    static func row(_ row: BackgroundTaskRow, windowOpen: Bool = false) -> [String: Any] {
        [
            "id": row.id,
            "section": row.section.rawValue,
            "kind": row.kindLabel,
            "kind_name": value(row.kindName),
            "title": row.title,
            "description": row.description,
            "status": row.statusLabel,
            "elapsed_ms": value(row.elapsedMs),
            "duration_ms": value(row.durationMs),
            "ended_ago_ms": value(row.endedAgoMs),
            "sign_of_life": value(row.signOfLife),
            "parent_id": value(row.parentId),
            "depth": row.depth,
            "housekeeping": row.isHousekeeping,
            "stop_offered": row.stopOffered,
            "window_open": windowOpen,
        ]
    }

    /// The value, or JSON `null` when unknown.
    private static func value<T>(_ v: T?) -> Any { v.map { $0 as Any } ?? NSNull() }
}
