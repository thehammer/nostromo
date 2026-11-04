import Foundation

/// The fixed list of destructive patterns (PRD SR6). A match only adds a label, and in a pane treated as
/// production an "Insert asks first" sheet. **No label does not mean safe**: nothing here judges a command.
/// The list is documented verbatim in `docs/terminal.md`; changing it needs a PRD change. Quotes are not
/// parsed: every rule runs on the text as written AND on four normalised copies (`StagingHazards.normalised`:
/// quotes and backslashes dropped, `/* */` comments removed, command substitutions, groups and backticks
/// made separators; and `StagingHazards.normalisedWords`: each `$(...)`, backtick pair or `${...}` one
/// placeholder word, brace groups split at commas; each with empty expansions as a space and removed), and a
/// hit on any counts, so a pattern inside a quoted string matches too and a wrapped (`bash -c 'rm -rf x'`),
/// split (`r''m`), substituted (`kubectl --context $(...) delete ns x`), brace-expanded (`{rm,-rf,/x}`) or
/// abbreviated (`q:fl`) form is still seen.
enum StagingDestructivePatterns {

    /// The names, in list order.
    static let names = ["rm -rf", "DROP", "TRUNCATE", "DELETE FROM without WHERE", "migrate:fresh", "db:wipe",
                        "queue:flush", "cache:clear", "--force", "kill -9",
                        // Added with the staging-leftovers families, in this order.
                        "migrate:refresh", "migrate:reset", "migrate:rollback", "kubectl delete", "kubectl drain",
                        "helm uninstall", "terraform destroy", "aws delete/terminate", "aws s3 rm/rb", "dd of=", "mkfs",
                        "shred", "> file", "find -delete", "xargs/piped rm",
                        // Added with the review fix-ups, in this order.
                        "queue:clear", "horizon:clear", "optimize:clear", "FLUSHALL/FLUSHDB", "stop/shutdown"]

    /// The names of the patterns `command` matches, in list order.
    static func matches(_ command: String) -> [String] {
        let views = [command] + StagingHazards.normalisedViews(command) + StagingHazards.normalisedWordViews(command)
        func any(_ test: (String) -> Bool) -> Bool { views.contains(where: test) }
        var found: [String] = []
        if any(hasRecursiveForcedRemove) { found.append("rm -rf") }
        if any({ StagingHazards.regex(#"\bdrop\s"#, in: $0) || hasProgram($0, ["dropdb"]) }) { found.append("DROP") }
        if any({ StagingHazards.regex(#"\btruncate\b"#, in: $0) }) { found.append("TRUNCATE") }
        if any(hasDeleteWithoutWhere) { found.append("DELETE FROM without WHERE") }
        for name in ["migrate:fresh", "db:wipe", "queue:flush", "cache:clear"]
        where any({ $0.lowercased().contains(name) || usesArtisanAbbreviation(of: name, in: $0) }) {
            found.append(name)
        }
        if any({ StagingHazards.regex(#"(?<![A-Za-z0-9_-])--fo(?:r(?:c(?:e)?)?)?\b"#, in: $0, caseInsensitive: false) }) {
            found.append("--force")
        }
        if any(hasForceKill) { found.append("kill -9") }
        for name in ["migrate:refresh", "migrate:reset", "migrate:rollback"]
        where any({ $0.lowercased().contains(name) || usesArtisanAbbreviation(of: name, in: $0) }) {
            found.append(name)
        }
        if any({ programThen($0, ["kubectl"], ["delete"]) }) { found.append("kubectl delete") }
        if any({ programThen($0, ["kubectl"], ["drain"]) }) { found.append("kubectl drain") }
        if any({ programThen($0, ["helm"], ["uninstall", "delete", "del", "un"]) }) { found.append("helm uninstall") }
        if any(hasTerraformDestroy) { found.append("terraform destroy") }
        if any(hasAwsDelete) { found.append("aws delete/terminate") }
        if any(hasAwsS3Remove) { found.append("aws s3 rm/rb") }
        if any(hasDdOutput) { found.append("dd of=") }
        if any({ StagingHazards.redirectionSplitWords(of: $0).contains { program($0).hasPrefix("mkfs") } }) { found.append("mkfs") }
        if any({ StagingHazards.redirectionSplitWords(of: $0).contains { program($0) == "shred" } }) { found.append("shred") }
        if any(truncatesAFile) { found.append("> file") }
        if any(hasFindDelete) { found.append("find -delete") }
        if any(hasXargsOrPipedRemove) { found.append("xargs/piped rm") }
        for name in ["queue:clear", "horizon:clear", "optimize:clear"]
        where any({ $0.lowercased().contains(name) || usesArtisanAbbreviation(of: name, in: $0) }) {
            found.append(name)
        }
        if any({ StagingHazards.regex(#"\bflush(?:all|db)\b"#, in: $0) }) { found.append("FLUSHALL/FLUSHDB") }
        if any(hasStopOrShutdown) { found.append("stop/shutdown") }
        return found
    }

    /// An `rm` program (any case: macOS volumes are case-insensitive) anywhere whose arguments (up to the next
    /// `;`, `&`, `&&`, `||` or `|`) include a recursive flag and a force flag, in any combination or order
    /// (`-rf`, `-fr`, `-Rf`, `-r -f`, `--recursive --force`, the shortened `--recurs`, `--forc`). Words are split
    /// as everywhere else (`segmentWords`: also at `<` and `>`, so `rm>/dev/null -rf x` is seen).
    private static func hasRecursiveForcedRemove(_ command: String) -> Bool {
        for words in segmentWords(command) {
            for (index, word) in words.enumerated() where program(word) == "rm" {
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

    // MARK: Families added with the staging-leftovers PR
    //
    // A *segment* is a view split at `;`, `|` and `&`; its *words* are split at spaces and tabs; a word's
    // *program* is its last path component, lowercased. A program counts anywhere in a segment, so a leading
    // `sudo`, `env`, `command`, `time`, `nohup`, `exec`, a prefix assignment or an option never hides it, and
    // global options between it and its verb do not either. The daemon's `destructive.rs` is the same rules.

    private static func segmentWords(_ view: String) -> [[String]] {
        view.split(whereSeparator: { $0 == ";" || $0 == "|" || $0 == "&" })
            .map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "<" || $0 == ">" }).map(String.init) }
            .filter { !$0.isEmpty }
    }

    private static func program(_ word: String) -> String {
        (word.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? word).lowercased()
    }

    /// Is any word of the view (split at whitespace, `;`, `|`, `&`, `<`, `>`) one of `programs`?
    private static func hasProgram(_ view: String, _ programs: [String]) -> Bool {
        StagingHazards.redirectionSplitWords(of: view).contains { programs.contains(program($0)) }
    }

    /// The words after the first word whose program is one of `programs`.
    private static func afterProgram(_ words: [String], _ programs: [String]) -> [String]? {
        guard let at = words.firstIndex(where: { programs.contains(program($0)) }) else { return nil }
        return Array(words[(at + 1)...])
    }

    /// Is there a segment with one of `programs` followed later by one of `verbs` (lowercased compare)?
    private static func programThen(_ view: String, _ programs: [String], _ verbs: [String]) -> Bool {
        segmentWords(view).contains { words in
            afterProgram(words, programs)?.contains { verbs.contains($0.lowercased()) } ?? false
        }
    }

    /// Is `word` (lowercase) signal 9? Numerically, so `09` and `0009` count as they do in a shell.
    private static func isKillSignal(_ word: String) -> Bool {
        if word == "kill" || word == "sigkill" { return true }
        return !word.isEmpty && word.allSatisfy { $0.isASCII && $0.isNumber } && word.drop(while: { $0 == "0" }) == "9"
    }

    /// The original `kill`/`pkill`/`killall` + force signal, and a kill program followed anywhere later in the same
    /// segment by one (`pkill -f x -9`, `kill -s9 1`, `kill -n9 1`, `kill -09 1`, `kill --signal=KILL 1`). Signal 9
    /// is compared as a number: `-09`, `-s 0009`.
    private static func hasForceKill(_ view: String) -> Bool {
        if StagingHazards.regex(#"\b(?:kill|pkill|killall)\s+(?:-9\b|-KILL\b|-SIGKILL\b|-[sn]\s+(?:9|KILL|SIGKILL)\b)"#, in: view) { return true }
        for words in segmentWords(view) {
            guard let after = afterProgram(words, ["kill", "pkill", "killall"]) else { continue }
            let rest = after.map { $0.lowercased() }
            for (index, word) in rest.enumerated() {
                if word.hasPrefix("--signal="), isKillSignal(String(word.dropFirst("--signal=".count))) { return true }
                if word.hasPrefix("-"), !word.hasPrefix("--") {
                    let flag = String(word.dropFirst())
                    if isKillSignal(flag) { return true }
                    if flag.hasPrefix("s") || flag.hasPrefix("n"), isKillSignal(String(flag.dropFirst())) { return true }
                }
                if ["-s", "-n", "--signal"].contains(word), index + 1 < rest.count, isKillSignal(rest[index + 1]) { return true }
            }
        }
        return false
    }

    /// `terraform`, `tofu`, `terragrunt` or `pulumi` followed later in the segment by `destroy`, `destroy-all`,
    /// `-destroy`, `--destroy`, `-replace` or `--replace` (optionally `=value`). `plan -destroy` is read-only but its
    /// plan file can be applied unseen, so it asks too. Also (same label) `taint`, `force-unlock`,
    /// `workspace ... delete` and `state ... rm`/`remove`/`push`: each makes the next apply destroy something, or
    /// forgets, overwrites or deletes state, or breaks a lock.
    private static func hasTerraformDestroy(_ view: String) -> Bool {
        for words in segmentWords(view) {
            guard let rest = afterProgram(words, ["terraform", "tofu", "terragrunt", "pulumi"]) else { continue }
            let lowered = rest.map { $0.lowercased() }
            func then(_ first: String, _ verbs: [String]) -> Bool {
                guard let at = lowered.firstIndex(of: first) else { return false }
                return lowered[(at + 1)...].contains { verbs.contains($0) }
            }
            if then("workspace", ["delete"]) || then("state", ["rm", "remove", "push"]) { return true }
            for word in lowered {
                if ["destroy", "destroy-all", "taint", "force-unlock"].contains(word) { return true }
                if word.hasPrefix("-") {
                    let flag = word.drop(while: { $0 == "-" })
                    let name = flag.split(separator: "=", omittingEmptySubsequences: false).first.map(String.init) ?? ""
                    if name == "destroy" || name == "replace" { return true }
                }
            }
        }
        return false
    }

    /// `aws` followed later in the segment by a word that is exactly `delete-...`, `batch-delete-...`, `terminate-...`,
    /// `remove-...`, `deregister-...` or `purge-...`, or exactly `schedule-key-deletion` (kms: the key is gone in 7 to
    /// 30 days) or `stop-instances`, or `update-service` with `--desired-count` 0 (an ECS service scaled to nothing).
    private static func hasAwsDelete(_ view: String) -> Bool {
        let verbs = ["delete-", "batch-delete-", "terminate-", "remove-", "deregister-", "purge-"]
        func isZero(_ text: String) -> Bool { !text.isEmpty && text.allSatisfy { $0 == "0" } }
        for words in segmentWords(view) {
            guard let after = afterProgram(words, ["aws"]) else { continue }
            let rest = after.map { $0.lowercased() }
            if rest.contains("update-service") {
                for (index, word) in rest.enumerated() {
                    if word.hasPrefix("--desired-count="), isZero(String(word.dropFirst("--desired-count=".count))) { return true }
                    if word == "--desired-count", index + 1 < rest.count, isZero(rest[index + 1]) { return true }
                }
            }
            for word in rest {
                if word == "schedule-key-deletion" || word == "stop-instances" { return true }
                for verb in verbs where word.hasPrefix(verb) {
                    let tail = word.dropFirst(verb.count)
                    if !tail.isEmpty && tail.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }) { return true }
                }
            }
        }
        return false
    }

    /// `aws` then `s3` then `rm` or `rb`; also `aws s3 sync ... --delete` and `aws s3 cp /dev/null s3://...` (which
    /// replaces the object with an empty one).
    private static func hasAwsS3Remove(_ view: String) -> Bool {
        for words in segmentWords(view) {
            guard let after = afterProgram(words, ["aws"]) else { continue }
            let rest = after.map { $0.lowercased() }
            guard let s3 = rest.firstIndex(of: "s3") else { continue }
            let tail = Array(rest[(s3 + 1)...])
            if tail.contains("rm") || tail.contains("rb") { return true }
            if let cp = tail.firstIndex(of: "cp"), tail[(cp + 1)...].contains("/dev/null") { return true }
            if let sync = tail.firstIndex(of: "sync"), tail[(sync + 1)...].contains("--delete") { return true }
        }
        return false
    }

    /// `dd` followed later in the segment by a word starting `of=`.
    private static func hasDdOutput(_ view: String) -> Bool {
        segmentWords(view).contains { words in
            afterProgram(words, ["dd"])?.contains { $0.lowercased().hasPrefix("of=") } ?? false
        }
    }

    /// A `>` that truncates a file. `>>` (append) and `<>` are not truncation; `>&` followed by a descriptor or `-`
    /// is a duplication (`2>&1`, `>&2`); a target of exactly `/dev/null`, `/dev/stderr` or `/dev/stdout` (case matters:
    /// `/DEV/NULL` is a file on a case-sensitive volume) is exempt.
    /// Anything else, an empty target and `>(...)` included, matches. Quotes and backslashes inside a target are
    /// ignored (`> '/dev/null'` is `/dev/null`).
    private static func truncatesAFile(_ view: String) -> Bool {
        let c = Array(view.unicodeScalars)
        let terminators = Set(";|&<>(){}`".unicodeScalars)
        var i = 0
        while i < c.count {
            if c[i] != ">" { i += 1; continue }
            if i + 1 < c.count, c[i + 1] == ">" {
                while i < c.count, c[i] == ">" { i += 1 }
                continue
            }
            let afterLess = i > 0 && c[i - 1] == "<"
            i += 1
            if afterLess { continue }
            if i < c.count, c[i] == "|" || c[i] == "!" { i += 1 }
            let duplication = i < c.count && c[i] == "&"
            if duplication { i += 1 }
            while i < c.count, c[i] == " " || c[i] == "\t" { i += 1 }
            var target = ""
            while i < c.count {
                let scalar = c[i]
                if scalar.properties.isWhitespace || terminators.contains(scalar) { break }
                if scalar != "'" && scalar != "\"" && scalar != "\\" { target.unicodeScalars.append(scalar) }
                i += 1
            }
            var digits = Substring(target)
            while digits.last == "-" { digits = digits.dropLast() }
            let descriptor = target == "-" || (!digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber })
            if duplication && descriptor { continue }
            if ["/dev/null", "/dev/stderr", "/dev/stdout"].contains(target) { continue }
            return true
        }
        return false
    }

    /// A `find` program followed later anywhere in the text (the `{}` of `-exec rm {} \;` splits segments once
    /// normalised) by `-delete`, or by `-exec`/`-execdir`/`-ok`/`-okdir` and later an `rm` program.
    private static func hasFindDelete(_ view: String) -> Bool {
        let words = StagingHazards.redirectionSplitWords(of: view).map { $0.lowercased() }
        guard let rest = afterProgram(words, ["find"]) else { return false }
        if rest.contains("-delete") { return true }
        guard let exec = rest.firstIndex(where: { ["-exec", "-execdir", "-ok", "-okdir"].contains($0) }) else { return false }
        return rest[(exec + 1)...].contains { program($0) == "rm" }
    }

    /// An `xargs` or `parallel` program followed later anywhere in the text by an `rm` program (`parallel rm ::: a b`),
    /// or an `rm` program after a single `|` (a pipe, not `||`) anywhere in the text.
    private static func hasXargsOrPipedRemove(_ view: String) -> Bool {
        let words = StagingHazards.redirectionSplitWords(of: view)
        if afterProgram(words, ["xargs", "parallel"])?.contains(where: { program($0) == "rm" }) ?? false { return true }
        let chars = Array(view.unicodeScalars)
        guard let pipe = chars.indices.first(where: { index in
            chars[index] == "|" && (index == 0 || chars[index - 1] != "|") && (index + 1 >= chars.count || chars[index + 1] != "|")
        }) else { return false }
        var rest = String.UnicodeScalarView()
        rest.append(contentsOf: chars[(pipe + 1)...])
        return StagingHazards.redirectionSplitWords(of: String(rest)).contains { program($0) == "rm" }
    }

    /// `text` up to a SQL comment start (`-- `, a trailing `--`, `#`): a `WHERE` after one is not part of the statement.
    private static func withoutSqlComment(_ text: String) -> String {
        guard let comment = text.range(of: #"--(?:\s|$)|#"#, options: .regularExpression) else { return text }
        return String(text[..<comment.lowerBound])
    }

    /// `delete from`, `delete t from`, `delete t1, t2 from`, `delete ignore|low_priority|quick from`.
    private static let deletePattern = #"\bdelete\s+(?:(?:ignore|low_priority|quick)\s+)*(?:[\w$.`\x22]+(?:\s*,\s*[\w$.`\x22]+)*\s+)?from\b"#

    /// The quote (`'` or `"`, as a UTF-16 unit) still open before offset `limit`: a single quote has no escapes, a
    /// backslash escapes the next character anywhere else.
    private static func openQuote(in units: [UInt16], before limit: Int) -> UInt16? {
        let backslash: UInt16 = 0x5C, single: UInt16 = 0x27, double: UInt16 = 0x22
        var quote: UInt16?
        var escaped = false
        for index in 0..<limit {
            let unit = units[index]
            if escaped {
                escaped = false
            } else if unit == backslash && quote != single {
                escaped = true
            } else if quote == unit {
                quote = nil
            } else if quote == nil && (unit == single || unit == double) {
                quote = unit
            }
        }
        return quote
    }

    /// A `delete from` with no `where` after it in the same statement. A statement ends at `;`, `&`, `|`, the next
    /// `delete from`, and, when the `delete` sits inside a quoted string (`psql -c 'DELETE FROM users' -c '... WHERE ...'`),
    /// at that string's closing quote.
    private static func hasDeleteWithoutWhere(_ command: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: deletePattern, options: [.caseInsensitive]) else { return false }
        let ns = command as NSString
        let units = Array(command.utf16)
        let semicolon: UInt16 = 0x3B, ampersand: UInt16 = 0x26, pipe: UInt16 = 0x7C, backslash: UInt16 = 0x5C, single: UInt16 = 0x27
        let found = regex.matches(in: command, range: NSRange(location: 0, length: ns.length))
        for (index, match) in found.enumerated() {
            let quote = openQuote(in: units, before: match.range.location)
            let start = match.range.location + match.range.length
            let limit = index + 1 < found.count ? found[index + 1].range.location : ns.length
            var stop = limit
            var escaped = false
            var position = start
            while position < limit {
                let unit = units[position]
                if !escaped && (unit == semicolon || unit == ampersand || unit == pipe || unit == quote) {
                    stop = position
                    break
                }
                escaped = !escaped && unit == backslash && quote != single
                position += 1
            }
            let rest = withoutSqlComment(ns.substring(with: NSRange(location: start, length: stop - start)))
            if !StagingHazards.regex(#"\bwhere\b"#, in: rest) { return true }
        }
        return false
    }

    /// A `shutdown`, `reboot`, `halt` or `poweroff` program anywhere, `systemctl` followed later in the segment by
    /// `stop`, `disable` or `mask`, or `service` followed later by `stop`.
    private static func hasStopOrShutdown(_ view: String) -> Bool {
        hasProgram(view, ["shutdown", "reboot", "halt", "poweroff"])
            || programThen(view, ["systemctl"], ["stop", "disable", "mask"])
            || programThen(view, ["service"], ["stop"])
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

    /// Does a production pane ask before inserting `command`? On a destructive match, and on an escape-quoted word
    /// (`$'\x72\x6d' -rf x`): no text rule can follow what the shell makes of it, so it fails toward the sheet.
    static func asksFirstInProduction(_ command: String) -> Bool {
        !StagingDestructivePatterns.matches(command).isEmpty || escapeQuotedWordLabel(command) != nil
    }

    /// Expansions that are empty at run time (`rm${IFS}-rf` is `rm -rf`; `r$@m` is `rm`). Longest first.
    private static let emptyExpansions = ["${IFS}", "$IFS", "$()", "$@", "$*"]

    /// Length of the empty expansion starting at `chars[index]` (a `$`), if any: the fixed forms, a positional
    /// parameter (`$0`-`$9`, `${0}`-`${9}`) and `${IFS` with a plain `%` / `#` / `:N:M` modifier, which runs to the `}`.
    private static func emptyExpansionLength(_ chars: [Character], at index: Int) -> Int? {
        if let fixed = emptyExpansions.first(where: { chars[index...].starts(with: Array($0)) }) { return fixed.count }
        func at(_ offset: Int) -> Character? { index + offset < chars.count ? chars[index + offset] : nil }
        func isDigit(_ c: Character?) -> Bool { c.map { $0.isASCII && $0.isNumber } ?? false }
        if isDigit(at(1)) { return 2 }
        if at(1) == "{", isDigit(at(2)), at(3) == "}" { return 4 }
        if chars[index...].starts(with: Array("${IFS")), let close = chars[(index + 5)...].firstIndex(of: "}") {
            // Only modifiers that keep whitespace or nothing: `%` / `#` with a literal pattern, and `:N` / `:N:M`.
            // `:+`, `:-`, `=`, `/` and anything with `$`, a backtick or `(` are not swallowed: the operand can run
            // a command, so it stays visible to the rules.
            let body = Array(chars[(index + 5)..<close])
            let offset = body.count > 1 && body[0] == ":" && body.dropFirst().allSatisfy { $0 == ":" || ($0.isASCII && $0.isNumber) }
            let literal = !body.dropFirst().contains(where: { "$`(){\\'\"".contains($0) })
            if offset || ((body.first == "%" || body.first == "#") && literal) { return close - index + 1 }
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
            if c == "$", index + 1 < chars.count, chars[index + 1] == "'" || chars[index + 1] == "\"" {
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

    /// Both forms of [`normalisedWords`]: empty expansions as a space, and removed.
    static func normalisedWordViews(_ text: String) -> [String] {
        [normalisedWords(text), normalisedWords(text, empty: "")]
    }

    /// The view of the text for the destructive rules in which what a shell expands cannot sit between a program and
    /// its verb (the daemon's `normalise_for_hazard_words` does the same): each balanced `$(...)`, backtick pair,
    /// `<(...)` or `${...}` becomes ONE placeholder word (`_`; for `${...}` the words of its operand follow it, so
    /// `${X:-delete}` still shows `delete`), `(`, `)`, `{`, `}` become spaces, and a comma inside a brace group does
    /// too (`{rm,-rf,/x}` is the words `rm -rf /x`). Quotes and backslashes are dropped, and so is the `$` of `$'...'`
    /// and `$"..."`; empty expansions as in [`normalised`]. `;`, `|` and `&` stay, and `/* */` is NOT a comment here:
    /// a shell has none, so `echo /*; 'kubectl' delete ns x; echo */` runs the middle command. An unbalanced opener
    /// is dropped and what follows stays visible.
    static func normalisedWords(_ text: String, empty: String = " ") -> String {
        var out = ""
        let chars = Array(text)
        var braces = 0
        var index = 0
        while index < chars.count {
            let c = chars[index]
            if c == "$" {
                if let length = emptyExpansionLength(chars, at: index) {
                    index += length
                    if !(empty == " " && out.last == " ") { out.append(empty) }
                    continue
                }
                let next: Character? = index + 1 < chars.count ? chars[index + 1] : nil
                if next == "'" || next == "\"" {
                    index += 1
                    continue
                }
                if next == "(", let close = closingIndex(chars, from: index + 1, open: "(", close: ")") {
                    out.append(" _ ")
                    index = close + 1
                    continue
                }
                if next == "{", let close = closingIndex(chars, from: index + 1, open: "{", close: "}") {
                    out.append(" _ ")
                    out.append(parameterWords(Array(chars[(index + 2)..<close])))
                    index = close + 1
                    continue
                }
            }
            if c == "<", index + 1 < chars.count, chars[index + 1] == "(",
               let close = closingIndex(chars, from: index + 1, open: "(", close: ")") {
                out.append(" _ ")
                index = close + 1
                continue
            }
            if c == "`", let close = chars[(index + 1)...].firstIndex(of: "`") {
                out.append(" _ ")
                index = close + 1
                continue
            }
            index += 1
            switch c {
            case "'", "\"", "\\": break
            case "{":
                braces += 1
                out.append(" ")
            case "}":
                braces = max(0, braces - 1)
                out.append(" ")
            case "," where braces > 0: out.append(" ")
            case "`", "(", ")": out.append(" ")
            default: out.append(c.isWhitespace ? " " : c)
            }
        }
        return out
    }

    /// The index of the character that closes the `open` at `chars[start]`, counting nested pairs; nil when unbalanced.
    private static func closingIndex(_ chars: [Character], from start: Int, open: Character, close: Character) -> Int? {
        var depth = 0
        for index in start..<chars.count {
            if chars[index] == open {
                depth += 1
            } else if chars[index] == close {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }

    /// The words of a `${...}` body: its name, then its operand with the operator (`:-`, `:=`, `:+`, `:?`, `%`, `#`, `/`,
    /// `^`, `,`) skipped and anything but letters, digits, `_`, `-`, `.`, `/` and `=` turned into a space, so
    /// `${X:-delete}` gives `X delete` and `${X:-$(rm -rf /)}` shows `rm -rf /`.
    private static func parameterWords(_ body: [Character]) -> String {
        var at = body.prefix(while: { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }).count
        let name = String(body[..<at])
        if at < body.count, body[at] == ":" { at += 1 }
        if at < body.count {
            let op = body[at]
            if "-=+?".contains(op) {
                at += 1
            } else if "%#/^,".contains(op) {
                at += 1
                if at < body.count, body[at] == op { at += 1 }
            }
        }
        let operand = String(body[at...].map { (c: Character) -> Character in
            (c.isLetter || c.isNumber || "_-./=".contains(c)) ? c : " "
        })
        return " \(name) \(operand) "
    }

    /// Words, split at whitespace and at `;`, `|` and `&`.
    static func words(of text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0 == ";" || $0 == "|" || $0 == "&" }).map(String.init)
    }

    /// Words for the destructive rules: split at whitespace and at `;`, `|`, `&`, `<` and `>`, so a redirection glued
    /// to a word (`kubectl delete>/dev/null ns x`) still leaves the verb a word of its own. The history check keeps
    /// [`words(of:)`].
    static func redirectionSplitWords(of text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || ";|&<>".contains($0) }).map(String.init)
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
