import Foundation

/// The fixed list of destructive patterns (PRD SR6). A match only adds a label, and in a pane treated as
/// production an "Insert asks first" sheet. **No label does not mean safe**: nothing here judges a command.
/// The list is documented verbatim in `docs/terminal.md`; changing it needs a PRD change. Quotes are not
/// parsed: every rule runs on the text as written AND on a normalised copy (`StagingHazards.normalised`:
/// quotes and backslashes dropped, `/* */` comments removed, command substitutions, groups and backticks
/// made separators), and a hit on either counts, so a pattern inside a quoted string matches too and a
/// wrapped (`bash -c 'rm -rf x'`), split (`r''m`) or abbreviated (`q:fl`) form is still seen.
enum StagingDestructivePatterns {

    /// The names, in list order.
    static let names = ["rm -rf", "DROP", "TRUNCATE", "DELETE FROM without WHERE", "migrate:fresh", "db:wipe",
                        "queue:flush", "cache:clear", "--force", "kill -9"]

    /// The names of the patterns `command` matches, in list order.
    static func matches(_ command: String) -> [String] {
        let views = [command] + StagingHazards.normalisedViews(command)
        func any(_ test: (String) -> Bool) -> Bool { views.contains(where: test) }
        var found: [String] = []
        if any(hasRecursiveForcedRemove) { found.append("rm -rf") }
        if any({ StagingHazards.regex(#"\bdrop\s"#, in: $0) }) { found.append("DROP") }
        if any({ StagingHazards.regex(#"\btruncate\b"#, in: $0) }) { found.append("TRUNCATE") }
        if any(hasDeleteWithoutWhere) { found.append("DELETE FROM without WHERE") }
        for name in ["migrate:fresh", "db:wipe", "queue:flush", "cache:clear"]
        where any({ $0.lowercased().contains(name) || usesArtisanAbbreviation(of: name, in: $0) }) {
            found.append(name)
        }
        if any({ StagingHazards.regex(#"(?<![A-Za-z0-9_-])--fo(?:r(?:c(?:e)?)?)?\b"#, in: $0, caseInsensitive: false) }) {
            found.append("--force")
        }
        if any({ StagingHazards.regex(#"\b(?:kill|pkill|killall)\s+(?:-9\b|-KILL\b|-SIGKILL\b|-[sn]\s+(?:9|KILL|SIGKILL)\b)"#, in: $0) }) {
            found.append("kill -9")
        }
        return found
    }

    /// An `rm` word anywhere whose arguments (up to the next `;`, `&`, `&&`, `||` or `|`) include a recursive
    /// flag and a force flag, in any combination or order (`-rf`, `-fr`, `-Rf`, `-r -f`, `--recursive --force`,
    /// the shortened `--recurs`, `--forc`).
    private static func hasRecursiveForcedRemove(_ command: String) -> Bool {
        for segment in StagingHazards.segments(of: command) {
            let words = segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            for (index, word) in words.enumerated() where word == "rm" || word.hasSuffix("/rm") {
                var recursive = false
                var force = false
                for argument in words[(index + 1)...] where argument.hasPrefix("-") {
                    if argument.hasPrefix("--") {
                        if argument.count >= 3 {
                            if "--recursive".hasPrefix(argument) { recursive = true }
                            if "--force".hasPrefix(argument) { force = true }
                        }
                        continue
                    }
                    if argument.contains("r") || argument.contains("R") { recursive = true }
                    if argument.contains("f") { force = true }
                }
                if recursive && force { return true }
            }
        }
        return false
    }

    /// Laravel accepts a shortened command name (`ca:cl`, `q:fl`, `mi:fr`, `db:w`): a word of two letters-only
    /// parts, each a non-empty prefix of the matching part of `name`. Over-matching (`c:c`) is the cheap side.
    private static func usesArtisanAbbreviation(of name: String, in text: String) -> Bool {
        let target = name.split(separator: ":").map(String.init)
        for word in text.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == ";" || $0 == "|" || $0 == "&" }) {
            let parts = word.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, target.count == 2 else { continue }
            let lettersOnly = parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isLetter } }
            if lettersOnly && target[0].hasPrefix(parts[0]) && target[1].hasPrefix(parts[1]) { return true }
        }
        return false
    }

    /// `text` up to a SQL comment start (`-- `, a trailing `--`, `#`): a `WHERE` after one is not part of the statement.
    private static func withoutSqlComment(_ text: String) -> String {
        guard let comment = text.range(of: #"--(?:\s|$)|#"#, options: .regularExpression) else { return text }
        return String(text[..<comment.lowerBound])
    }

    /// A `delete from` with no `where` after it in the same statement (statements split at `;`).
    private static func hasDeleteWithoutWhere(_ command: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: #"\bdelete\s+from\b"#, options: [.caseInsensitive]) else { return false }
        for statement in command.split(separator: ";", omittingEmptySubsequences: false).map(String.init) {
            let ns = statement as NSString
            let found = regex.matches(in: statement, range: NSRange(location: 0, length: ns.length))
            for (index, match) in found.enumerated() {
                let start = match.range.location + match.range.length
                let end = index + 1 < found.count ? found[index + 1].range.location : ns.length
                let rest = withoutSqlComment(ns.substring(with: NSRange(location: start, length: end - start)))
                if !StagingHazards.regex(#"\bwhere\b"#, in: rest) { return true }
            }
        }
        return false
    }
}

/// The other things a row can say about its text. Pure.
enum StagingHazards {

    static let historyReasonText = "Uses shell history (! ^ r fc): Nostromo will not place it here"
    static let localHistoryLabel = "\u{26A0} Uses shell history: what runs may differ from what you see."
    static let noLabelNote = "No label does not mean safe."

    /// Shell history expansion: `!` followed by anything but a space, `=` or `(` (a trailing `!` does not
    /// count); text that starts with `^`; `fc` or `history` as a word anywhere (on the normalised text:
    /// `\fc`, `'fc'`, `$(fc -s)` count); or `r` in command position: first in a segment (split on `;`, `&`,
    /// `&&`, `|`, `||`, a subshell, a substitution, a group or a backtick) or after `then`, `do`, `else`, `elif`, `if`,
    /// `while`, `until`, `!`, `command`, `builtin`, `eval`, `exec`, `time`, `sudo`, `noglob`, `nocorrect`, `nohup`, `nice`,
    /// `env` or `coproc`. The same rule the daemon applies
    /// (`tests/fixtures/terminal_staging/hazards.json`).
    static func usesHistoryExpansion(_ command: String) -> Bool {
        if command.hasPrefix("^") { return true }
        let scalars = Array(command.unicodeScalars)
        for (index, scalar) in scalars.enumerated() where scalar == "!" && index + 1 < scalars.count {
            let next = scalars[index + 1]
            if next != " " && next != "=" && next != "(" { return true }
        }
        return normalisedViews(command).contains { view in
            words(of: view).contains(where: { $0 == "fc" || $0 == "history" })
                || segments(of: view).contains { segment in
                    segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                        .first(where: { !leavesCommandPosition($0) }) == "r"
                }
        }
    }

    private static let prefixWords: Set<String> = ["then", "do", "else", "elif", "if", "while", "until", "!", "-", "command", "builtin",
                                                   "eval", "exec", "time", "sudo", "noglob", "nocorrect", "nohup", "nice", "env", "coproc"]

    /// Does `word` leave the next word in command position? A prefix word, a prefix assignment (`X=1 r` runs the
    /// builtin), an option or a number (`nice -n 5 r`). Only read before a segment's command, so `ls -r` stops at `ls`.
    private static func leavesCommandPosition(_ word: String) -> Bool {
        if prefixWords.contains(word) || word.hasPrefix("-") || word.allSatisfy({ $0.isASCII && $0.isNumber }) { return true }
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let name = word[..<equals]
        return !(name.first?.isNumber ?? true) && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    /// `$'...'` (ANSI-C quoting) with a backslash inside: the shell turns `\x72` into `r`, which no text rule can follow.
    static let escapeQuotedLabel = "\u{26A0} Contains an escape-quoted word ($'...' with a backslash): what runs may differ from what you see."

    static func escapeQuotedWordLabel(_ command: String) -> String? {
        regex(#"\$'[^']*\\"#, in: command, caseInsensitive: false) ? escapeQuotedLabel : nil
    }

    /// Expansions that are empty at run time (`rm${IFS}-rf` is `rm -rf`; `r$@m` is `rm`). Longest first.
    private static let emptyExpansions = ["${IFS}", "$IFS", "$()", "$@", "$*"]

    /// Length of the empty expansion starting at `chars[index]` (a `$`), if any: the fixed forms, a positional
    /// parameter (`$0`-`$9`, `${0}`-`${9}`) and `${IFS` with a modifier (`${IFS%?}`), which runs to the `}`.
    private static func emptyExpansionLength(_ chars: [Character], at index: Int) -> Int? {
        if let fixed = emptyExpansions.first(where: { chars[index...].starts(with: Array($0)) }) { return fixed.count }
        func at(_ offset: Int) -> Character? { index + offset < chars.count ? chars[index + offset] : nil }
        func isDigit(_ c: Character?) -> Bool { c.map { $0.isASCII && $0.isNumber } ?? false }
        if isDigit(at(1)) { return 2 }
        if at(1) == "{", isDigit(at(2)), at(3) == "}" { return 4 }
        if chars[index...].starts(with: Array("${IFS")), let next = at(5), !(next.isLetter || next.isNumber || next == "_") {
            return chars[(index + 5)...].firstIndex(of: "}").map { $0 - index + 1 }
        }
        return nil
    }

    /// Both forms of the normalised text: empty expansions as a space, and removed (inside a word the shell glues
    /// the halves together). Rules match either.
    static func normalisedViews(_ text: String) -> [String] {
        [normalised(text), normalised(text, empty: "")]
    }

    /// The text as a shell would see its words, for the hazard rules (the daemon's `normalise_for_hazards`
    /// does the same): `/* */` comments become a space, quotes and backslashes are dropped (and the `$` of a
    /// `$'...'` quote), empty expansions (`$IFS`, `${IFS}`, `$@`, `$*`, `$()`, `$0`-`$9`, `${IFS%?}`) become `empty`, backticks,
    /// parentheses and braces become `;`, and runs of whitespace collapse.
    static func normalised(_ text: String, empty: String = " ") -> String {
        var out = ""
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            let c = chars[index]
            if c == "$", let length = emptyExpansionLength(chars, at: index) {
                index += length
                if !(empty == " " && out.last == " ") { out.append(empty) }
                continue
            }
            if c == "$", index + 1 < chars.count, chars[index + 1] == "'" {
                index += 1
                continue
            }
            if c == "/", index + 1 < chars.count, chars[index + 1] == "*" {
                index += 2
                var previous: Character = "\0"
                while index < chars.count {
                    let n = chars[index]
                    index += 1
                    if previous == "*" && n == "/" { break }
                    previous = n
                }
                out.append(" ")
                continue
            }
            index += 1
            switch c {
            case "'", "\"", "\\": break
            case "`", "(", ")", "{", "}": out.append(";")
            default:
                if c.isWhitespace {
                    if out.last != " " { out.append(" ") }
                } else {
                    out.append(c)
                }
            }
        }
        return out
    }

    /// Words, split at whitespace and at `;`, `|` and `&`.
    static func words(of text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0 == ";" || $0 == "|" || $0 == "&" }).map(String.init)
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
            // Isolated (FSI ... PDI) so a right-to-left letter cannot reorder the `U+XXXX` text beside it.
            return "\u{2068}\(Character(scalar))\u{2069} \(code)\(name)"
        }
        var parts = shown
        if seen.count > 3 { parts.append("and \(seen.count - 3) more") }
        return "\u{26A0} Contains non-ASCII: " + parts.joined(separator: ", ")
    }

    /// The command split into segments at `;`, `&` (and so `&&`), `|` (and so `||`).
    static func segments(of command: String) -> [String] {
        command.split(whereSeparator: { $0 == ";" || $0 == "|" || $0 == "&" })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    static func regex(_ pattern: String, in text: String, caseInsensitive: Bool = true) -> Bool {
        text.range(of: pattern, options: caseInsensitive ? [.regularExpression, .caseInsensitive] : [.regularExpression]) != nil
    }
}
