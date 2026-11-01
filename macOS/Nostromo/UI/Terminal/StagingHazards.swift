import Foundation

/// The fixed list of destructive patterns (PRD SR6). A match only adds a label, and in a pane treated as
/// production an "Insert asks first" sheet. **No label does not mean safe**: nothing here judges a command.
/// The list is documented verbatim in `docs/terminal.md`; changing it needs a PRD change. Quotes are not
/// parsed: a pattern inside a quoted string matches too (asking is the cheap side).
enum StagingDestructivePatterns {

    /// The names, in list order.
    static let names = ["rm -rf", "DROP", "TRUNCATE", "DELETE FROM without WHERE", "migrate:fresh", "db:wipe",
                        "queue:flush", "cache:clear", "--force", "kill -9"]

    /// The names of the patterns `command` matches, in list order.
    static func matches(_ command: String) -> [String] {
        var found: [String] = []
        if hasRecursiveForcedRemove(command) { found.append("rm -rf") }
        if StagingHazards.regex(#"\bdrop\s"#, in: command) { found.append("DROP") }
        if StagingHazards.regex(#"\btruncate\b"#, in: command) { found.append("TRUNCATE") }
        if hasDeleteWithoutWhere(command) { found.append("DELETE FROM without WHERE") }
        let lower = command.lowercased()
        for name in ["migrate:fresh", "db:wipe", "queue:flush", "cache:clear"] where lower.contains(name) {
            found.append(name)
        }
        if StagingHazards.regex(#"(?<![A-Za-z0-9_-])--force\b"#, in: command, caseInsensitive: false) { found.append("--force") }
        if StagingHazards.regex(#"\b(?:kill|pkill|killall)\s+(?:-9\b|-KILL\b|-SIGKILL\b|-s\s+(?:9|KILL|SIGKILL)\b)"#, in: command) {
            found.append("kill -9")
        }
        return found
    }

    /// An `rm` word whose arguments (up to the next `;`, `&&`, `||` or `|`) include a recursive flag and a
    /// force flag, in any combination or order (`-rf`, `-fr`, `-Rf`, `-r -f`, `--recursive --force`).
    private static func hasRecursiveForcedRemove(_ command: String) -> Bool {
        for segment in StagingHazards.segments(of: command) {
            let words = segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            for (index, word) in words.enumerated() where word == "rm" || word.hasSuffix("/rm") {
                var recursive = false
                var force = false
                for argument in words[(index + 1)...] where argument.hasPrefix("-") {
                    if argument == "--recursive" { recursive = true }
                    if argument == "--force" { force = true }
                    guard !argument.hasPrefix("--") else { continue }
                    if argument.contains("r") || argument.contains("R") { recursive = true }
                    if argument.contains("f") { force = true }
                }
                if recursive && force { return true }
            }
        }
        return false
    }

    /// `delete from` with no `where` anywhere after it.
    private static func hasDeleteWithoutWhere(_ command: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: #"\bdelete\s+from\b"#, options: [.caseInsensitive]) else { return false }
        let ns = command as NSString
        guard let match = regex.firstMatch(in: command, range: NSRange(location: 0, length: ns.length)) else { return false }
        let rest = ns.substring(from: match.range.location + match.range.length)
        return !StagingHazards.regex(#"\bwhere\b"#, in: rest)
    }
}

/// The other things a row can say about its text. Pure.
enum StagingHazards {

    static let historyReasonText = "Uses shell history (! ^ r fc): Nostromo will not place it here"
    static let localHistoryLabel = "\u{26A0} Uses shell history: what runs may differ from what you see."
    static let noLabelNote = "No label does not mean safe."

    /// Shell history expansion: `!` followed by anything but a space, `=` or `(` (a trailing `!` does not
    /// count); text that starts with `^`; or a command segment (split on `;`, `&&`, `||`, `|`) whose first
    /// word is exactly `r`, `fc` or `history`. The same rule the daemon applies (`tests/fixtures/terminal_staging/hazards.json`).
    static func usesHistoryExpansion(_ command: String) -> Bool {
        if command.hasPrefix("^") { return true }
        let scalars = Array(command.unicodeScalars)
        for (index, scalar) in scalars.enumerated() where scalar == "!" && index + 1 < scalars.count {
            let next = scalars[index + 1]
            if next != " " && next != "=" && next != "(" { return true }
        }
        for segment in segments(of: command) {
            let first = segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
            if let first, first == "r" || first == "fc" || first == "history" { return true }
        }
        return false
    }

    /// `⚠ Matches a destructive pattern (queue:flush). Insert asks first. No label does not mean safe.`
    static func destructiveLabel(_ names: [String], production: Bool) -> String? {
        guard !names.isEmpty else { return nil }
        let list = names.joined(separator: ", ")
        return "\u{26A0} Matches a destructive pattern (\(list)). " + (production ? "Insert asks first. " : "") + noLabelNote
    }

    /// `⚠ Contains non-ASCII: а U+0430 CYRILLIC SMALL LETTER A`: up to three distinct scalars above U+007E
    /// with their code points and names, then `and N more`. Nil when the text is ASCII.
    static func nonASCIILabel(_ command: String) -> String? {
        var seen: [Unicode.Scalar] = []
        for scalar in command.unicodeScalars where scalar.value > 0x7E && !seen.contains(scalar) { seen.append(scalar) }
        guard !seen.isEmpty else { return nil }
        let shown = seen.prefix(3).map { scalar -> String in
            let code = "U+" + String(format: "%04X", scalar.value)
            let name = scalar.properties.name.map { " " + $0 } ?? ""
            return "\(Character(scalar)) \(code)\(name)"
        }
        var parts = shown
        if seen.count > 3 { parts.append("and \(seen.count - 3) more") }
        return "\u{26A0} Contains non-ASCII: " + parts.joined(separator: ", ")
    }

    /// The command split into segments at `;`, `&&`, `||` and `|`.
    static func segments(of command: String) -> [String] {
        command.replacingOccurrences(of: "&&", with: ";")
            .split(whereSeparator: { $0 == ";" || $0 == "|" })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    static func regex(_ pattern: String, in text: String, caseInsensitive: Bool = true) -> Bool {
        text.range(of: pattern, options: caseInsensitive ? [.regularExpression, .caseInsensitive] : [.regularExpression]) != nil
    }
}
