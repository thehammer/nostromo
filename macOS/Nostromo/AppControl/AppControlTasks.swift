import Foundation
import NostromoKit

/// READ-ONLY JSON for `nostromo-app tasks list` and `tasks chip` (BA3). Pure formatting of the same
/// `BackgroundTaskList` the popover and the chip show, so the two can never disagree. Changes nothing.
///
/// Unknown values are `null`, never zero.
enum AppControlTasks {

    /// `tasks list [--all]`: the running section; with `all`, the Ended and Housekeeping rows too.
    static func list(tag: String, list: BackgroundTaskList, all: Bool) -> [String: Any] {
        let rows = all ? list.allRows : list.running
        return [
            "tag": tag,
            "running": list.running.count,
            "chip": chip(tag: tag, list: list),
            "tasks": rows.map(row),
        ]
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
    static func row(_ row: BackgroundTaskRow) -> [String: Any] {
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
        ]
    }

    /// The value, or JSON `null` when unknown.
    private static func value<T>(_ v: T?) -> Any { v.map { $0 as Any } ?? NSNull() }
}
