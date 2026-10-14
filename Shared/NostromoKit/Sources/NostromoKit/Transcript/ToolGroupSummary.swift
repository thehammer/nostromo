import Foundation

/// The words on a group's row (PRD "Summary grammar"), and the copy texts.
///
/// Phrases come in a fixed order: Bash, Read, edits, searches, fetches, agents, todos, then
/// one per MCP server in first-appearance order, then everything else. They are
/// plural-aware, comma-separated, and the first is capitalised. Past three phrases the row
/// says `+N more`, where N counts the calls the hidden phrases stand for.
///
/// Distinct files are counted by `target`, falling back to `inputSummary` for calls from a
/// daemon that did not send one. The fallback is a basename, so two files with the same name
/// in different directories count once: it can under-count, never over-count. A call with
/// neither makes the count unknowable, and the phrase then says `read files` without a number
/// rather than a wrong one.
public enum ToolGroupSummary {

    /// What separates the summary, the failure and the time on a row.
    public static let separator = " · "

    /// The count phrases, e.g. `Ran 3 commands, read 1 file, edited 1 file`. Nil for a group
    /// of one: its row shows the call's own header instead.
    public static func summary(for group: ToolGroup) -> String? {
        guard group.callCount > 1 else { return nil }
        let phrases = Self.phrases(for: group.calls)
        var text = phrases.prefix(3).map(\.text).joined(separator: ", ")
        if phrases.count > 3 {
            let hidden = phrases.dropFirst(3).reduce(0) { $0 + $1.calls }
            text += ", +\(hidden) more"
        }
        return FoldTextSanitizer.sanitize(capitalizingFirst(text))
    }

    /// A call's one-line header text: `<tool name> · <input summary>`, sanitized.
    public static func header(for call: FoldCall) -> String {
        let text = call.inputSummary.isEmpty ? call.name : "\(call.name)\(separator)\(call.inputSummary)"
        return FoldTextSanitizer.sanitize(text)
    }

    /// `N failed`, or nil when nothing failed.
    public static func failureText(for group: ToolGroup) -> String? {
        group.failedCount > 0 ? "\(group.failedCount) failed" : nil
    }

    /// The group's elapsed time, or nil when either end is unknown.
    public static func durationText(for group: ToolGroup) -> String? {
        guard let start = group.startedAt, let end = group.endedAt else { return nil }
        return durationText(seconds: end.timeIntervalSince(start))
    }

    /// `850 ms`, `4.1 s`, `2 m 05 s`, `1 h 02 m`. Nil below 1 ms (never `0 ms`).
    public static func durationText(seconds: TimeInterval) -> String? {
        guard seconds.isFinite else { return nil }
        let ms = Int((seconds * 1000).rounded())
        guard ms >= 1 else { return nil }
        if ms < 1000 { return "\(ms) ms" }
        let tenths = Int((seconds * 10).rounded())
        if tenths < 600 { return "\(tenths / 10).\(tenths % 10) s" }
        let wholeSeconds = Int(seconds.rounded())
        if wholeSeconds < 3600 { return "\(wholeSeconds / 60) m \(twoDigits(wholeSeconds % 60)) s" }
        let minutes = Int((seconds / 60).rounded())
        return "\(minutes / 60) h \(twoDigits(minutes % 60)) m"
    }

    /// What the row reads, as plain text: summary (or header), then failure, then time, then
    /// `stopped`, joined by ` · `. This is what Copy Summary copies.
    public static func plainText(for group: ToolGroup) -> String {
        [title(for: group), failureText(for: group), durationText(for: group), stoppedSuffix(for: group)]
            .compactMap { $0 }
            .joined(separator: separator)
    }

    /// The row's VoiceOver label: like `plainText`, with the failure as `1 failed call`. While the
    /// group runs it is the live text instead (with the elapsed time when `now` is given).
    public static func accessibilityLabel(for group: ToolGroup, now: Date? = nil) -> String {
        let failure = group.failedCount > 0
            ? "\(group.failedCount) failed call\(group.failedCount == 1 ? "" : "s")" : nil
        if let running = runningTitle(for: group) {
            return [running, failure, now.flatMap { runningElapsedText(for: group, now: $0) }]
                .compactMap { $0 }
                .joined(separator: ", ")
        }
        return [title(for: group), failure, durationText(for: group), stoppedSuffix(for: group)]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    // MARK: - While running

    /// A running call shows its elapsed time once it has run this long.
    public static let elapsedThreshold: TimeInterval = 10

    /// `Running · N done · <current call header>`, or `Running · <header>` before any call has
    /// finished. Nil unless the group is running.
    public static func runningTitle(for group: ToolGroup) -> String? {
        guard group.state == .running else { return nil }
        var parts = ["Running"]
        if group.finishedCount > 0 { parts.append("\(group.finishedCount) done") }
        if let call = group.currentCall { parts.append(header(for: call)) }
        return FoldTextSanitizer.sanitize(parts.joined(separator: separator))
    }

    /// The running call's elapsed time in whole seconds (`42 s`, `1 m 05 s`), once it has run
    /// `elapsedThreshold`. Nil while younger, when its start is unknown, or when not running.
    public static func runningElapsedText(for group: ToolGroup, now: Date) -> String? {
        guard group.state == .running, let start = group.currentCall?.startedAt else { return nil }
        let age = now.timeIntervalSince(start)
        guard age.isFinite, age >= elapsedThreshold else { return nil }
        let seconds = Int(age.rounded(.down))
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) m \(twoDigits(seconds % 60)) s" }
        let minutes = seconds / 60
        return "\(minutes / 60) h \(twoDigits(minutes % 60)) m"
    }

    /// The whole live line: the running title, the failures so far, the elapsed time.
    /// Nil unless the group is running.
    public static func runningText(for group: ToolGroup, now: Date) -> String? {
        guard let title = runningTitle(for: group) else { return nil }
        return [title, failureText(for: group), runningElapsedText(for: group, now: now)]
            .compactMap { $0 }
            .joined(separator: separator)
    }

    /// `stopped` for a group the operator stopped while a call had no result; nil otherwise.
    /// Calls without a result are unfinished, never failed.
    public static func stoppedSuffix(for group: ToolGroup) -> String? {
        group.state == .stopped ? "stopped" : nil
    }

    /// What VoiceOver announces when a group in the focused pane settles with failures.
    public static func settledAnnouncement(failedCount: Int) -> String {
        "Tool activity finished, \(failedCount) failed call\(failedCount == 1 ? "" : "s")"
    }

    // MARK: - Copy

    /// Copy Commands: every top-level call's complete input, one per line, in order.
    ///
    /// Bash → the command verbatim (multi-line commands keep their newlines). Any other
    /// tool → `<name> <inputFull compacted to one line>`. When `payloadAvailable` is false
    /// and a call's `inputFull` is gone, that call copies as its summary plus ` …`, and a
    /// final line says older calls were truncated.
    ///
    /// Never sanitized: "complete" means exactly what the agent ran.
    public static func commandsText(for group: ToolGroup, payloadAvailable: Bool) -> String {
        var lines: [String] = []
        var truncated = false
        for call in group.calls {
            if call.inputFull.isEmpty && !payloadAvailable {
                truncated = true
                lines.append(call.name == "Bash"
                             ? "\(call.inputSummary) …"
                             : "\(call.name) \(call.inputSummary) …")
            } else if call.name == "Bash" {
                // An input that isn't the expected JSON is copied as it came, never the
                // cut-down summary.
                lines.append(bashCommand(call.inputFull) ?? (call.inputFull.isEmpty ? call.inputSummary : call.inputFull))
            } else {
                let input = oneLine(call.inputFull)
                lines.append(input.isEmpty ? call.name : "\(call.name) \(input)")
            }
        }
        if truncated { lines.append(truncatedCommandsNote) }
        return lines.joined(separator: "\n")
    }

    /// The last line of a Copy Commands text that had to fall back to summaries.
    public static let truncatedCommandsNote =
        "(older calls truncated: full input no longer retained in this pane)"

    // MARK: - Phrases

    private enum Kind: Hashable {
        case bash, read, edit, search, fetch, agent, todo
        case mcp(String)
        case other
    }

    private static func kind(of name: String) -> Kind {
        switch name {
        case "Bash":                                         return .bash
        case "Read":                                         return .read
        case "Write", "Edit", "MultiEdit", "NotebookEdit":   return .edit
        case "Grep", "Glob":                                 return .search
        case "WebFetch", "WebSearch":                        return .fetch
        case "Agent", "Task":                                return .agent
        case "TodoWrite":                                    return .todo
        default:
            guard name.hasPrefix("mcp__") else { return .other }
            let rest = name.dropFirst("mcp__".count)
            let server = rest.range(of: "__").map { rest[..<$0.lowerBound] } ?? rest
            return server.isEmpty ? .other : .mcp(String(server))
        }
    }

    private struct Tally {
        var calls = 0
        var files: Set<String> = []
        var fileCountUnknown = false
    }

    private static func phrases(for calls: [FoldCall]) -> [(text: String, calls: Int)] {
        var tallies: [Kind: Tally] = [:]
        var servers: [String] = []
        for call in calls {
            let kind = kind(of: call.name)
            if case .mcp(let server) = kind, tallies[kind] == nil { servers.append(server) }
            var tally = tallies[kind, default: Tally()]
            tally.calls += 1
            if kind == .read || kind == .edit {
                let file = call.target ?? (call.inputSummary.isEmpty ? nil : call.inputSummary)
                if let file { tally.files.insert(file) } else { tally.fileCountUnknown = true }
            }
            tallies[kind] = tally
        }

        let order: [Kind] = [.bash, .read, .edit, .search, .fetch, .agent, .todo]
            + servers.map { .mcp($0) } + [.other]
        return order.compactMap { kind in
            guard let tally = tallies[kind] else { return nil }
            return (phrase(kind, tally), tally.calls)
        }
    }

    private static func phrase(_ kind: Kind, _ tally: Tally) -> String {
        func counted(_ verb: String, _ n: Int, _ noun: String) -> String {
            "\(verb) \(n) \(noun)\(n == 1 ? "" : "s")"
        }
        func files(_ verb: String) -> String {
            tally.fileCountUnknown ? "\(verb) files" : counted(verb, tally.files.count, "file")
        }
        switch kind {
        case .bash:             return counted("ran", tally.calls, "command")
        case .read:             return files("read")
        case .edit:             return files("edited")
        case .search:           return counted("searched", tally.calls, "time")
        case .fetch:            return counted("fetched", tally.calls, "page")
        case .agent:            return counted("ran", tally.calls, "agent")
        case .todo:             return "updated todos"
        case .mcp(let server):  return counted("used", tally.calls, "\(server) tool")
        case .other:            return counted("used", tally.calls, "other tool")
        }
    }

    // MARK: - Helpers

    private static func title(for group: ToolGroup) -> String {
        summary(for: group) ?? group.calls.first.map(header(for:)) ?? ""
    }

    private static func capitalizingFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    private static func twoDigits(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

    /// The `command` of a Bash call's JSON input, verbatim.
    private static func bashCommand(_ inputFull: String) -> String? {
        guard let data = inputFull.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["command"] as? String
    }

    /// A tool's input on one line: its lines trimmed and joined by spaces. The daemon's
    /// pretty JSON escapes newlines inside strings, so its only line breaks are layout, and
    /// keys, numbers and escapes stay exactly as sent.
    private static func oneLine(_ inputFull: String) -> String {
        inputFull.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
