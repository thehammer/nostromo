import Foundation

/// The content-free staging numbers (PRD "Metrics"), computed from the daemon's terminal audit trail:
/// `terminal.jsonl` and its rotated siblings `terminal-<stamp>[-N].jsonl`, read-only (never written).
/// Counts only: no command, note, terminal id or owner ever appears in the summary.
///
/// Debug > Copy Terminal Staging Stats copies `summary(auditDirectory:)`.
enum TerminalStagingStats {

    struct Counts: Equatable {
        /// Distinct (terminal, owner) with at least one stage.
        var listsUsed = 0
        /// `stage` operations: entries staged.
        var entriesStaged = 0
        var inserts = 0
        /// First inserts of an entry: entries inserted at least once.
        var firstInserts = 0
        /// Entries removed or cleared that were never inserted (the audit's `unused`).
        var unused = 0
        var archivedManual = 0
        var archivedAuto = 0
        var listFull = 0
        var rateLimited = 0
        var confirmsInserted = 0
        var confirmsCancelled = 0
        var justChanged = 0
        var malformedLines = 0
        var filesRead = 0
    }

    /// `terminal.jsonl` and every `terminal-*.jsonl` in `directory`, oldest name first. Nothing else.
    static func auditFiles(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0 == "terminal.jsonl" || ($0.hasPrefix("terminal-") && $0.hasSuffix(".jsonl")) }
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }

    /// The summary text for the audit trail in `directory`.
    static func summary(auditDirectory directory: URL) -> String {
        text(counts(files: auditFiles(in: directory)))
    }

    static func counts(files: [URL]) -> Counts {
        var counts = Counts()
        var lists = Set<String>()
        for file in files {
            guard let data = try? String(contentsOf: file, encoding: .utf8) else { continue }
            counts.filesRead += 1
            for line in data.split(whereSeparator: \.isNewline) {
                add(String(line), to: &counts, lists: &lists)
            }
        }
        counts.listsUsed = lists.count
        return counts
    }

    /// Counts the lines of one in-memory audit file (tests).
    static func counts(lines: [String]) -> Counts {
        var counts = Counts()
        var lists = Set<String>()
        for line in lines { add(line, to: &counts, lists: &lists) }
        counts.listsUsed = lists.count
        return counts
    }

    private static func add(_ line: String, to counts: inout Counts, lists: inout Set<String>) {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let event = object["event"] as? String else {
            counts.malformedLines += 1
            return
        }
        switch event {
        case "staging_changed":
            let op = object["op"] as? String
            let by = object["by"] as? String
            if op == "stage" {
                counts.entriesStaged += 1
                lists.insert("\(object["terminal_id"] as? String ?? "")|\(object["tag"] as? String ?? "")")
            }
            if op == "archive" {
                if by == "auto" { counts.archivedAuto += 1 } else { counts.archivedManual += 1 }
            }
            counts.unused += (object["unused"] as? Int) ?? 0
        case "staging_inserted":
            counts.inserts += 1
            if object["first"] as? Bool == true { counts.firstInserts += 1 }
            if object["confirmed"] as? Bool == true { counts.confirmsInserted += 1 }
        case "staging_refused":
            switch object["code"] as? String {
            case "list_full": counts.listFull += 1
            case "rate_limited": counts.rateLimited += 1
            default: break
            }
        case "staging_ui_event":
            // The line's own `event` is its tag (`staging_ui_event`), so the UI event's name is another key.
            let name = ["ui_event", "name", "kind", "what"].lazy.compactMap { object[$0] as? String }.first
            switch name {
            case "confirm_cancelled": counts.confirmsCancelled += 1
            case "just_changed": counts.justChanged += 1
            default: break
            }
        default:
            break
        }
    }

    static func text(_ c: Counts) -> String {
        func percent(_ part: Int, of whole: Int) -> String {
            whole == 0 ? "n/a" : "\(Int((Double(part) / Double(whole) * 100).rounded()))%"
        }
        let perList = c.listsUsed == 0 ? "n/a" : String(format: "%.1f", Double(c.inserts) / Double(c.listsUsed))
        return [
            "Terminal staging stats (counts only; no command text)",
            "Lists used: \(c.listsUsed)",
            "Inserts: \(c.inserts) (\(perList) per list)",
            "Staged entries inserted at least once: \(c.firstInserts) of \(c.entriesStaged) (\(percent(c.firstInserts, of: c.entriesStaged)))",
            "Removed or cleared unused: \(c.unused)",
            "Archived: \(c.archivedManual) manual, \(c.archivedAuto) auto",
            "Refused: list_full \(c.listFull), rate_limited \(c.rateLimited)",
            "Destructive confirms: \(c.confirmsInserted) inserted, \(c.confirmsCancelled) cancelled",
            "Just changed (refused within the reading delay): \(c.justChanged)",
            "Audit files read: \(c.filesRead); malformed lines skipped: \(c.malformedLines)",
        ].joined(separator: "\n")
    }
}
