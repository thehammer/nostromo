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
/// abbreviated (`q:fl`) form is still seen. Two rules do read quotes, to stop asking about ordinary read-only
/// commands: `> file` ignores a `>` inside a quoted string (SQL, `awk` and `jq` programs are full of them) unless
/// the string is the argument of a command wrapper (`bash -c '...'`, `eval`, `ssh host '...'`, `parallel`, ...),
/// which is analysed as live code; and `stop/shutdown` only counts in command position.
/// Besides the names, a production pane also asks first for four warnings that are not names: an escape-quoted word,
/// a brace group glued to a word, a wildcard in the command word and any non-ASCII text
/// (`StagingHazards.asksFirstInProduction`). Every scanner walks `unicodeScalars`, never Characters.
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
        where any({ StagingHazards.scalarContains($0.lowercased(), name) || usesArtisanAbbreviation(of: name, in: $0) }) {
            found.append(name)
        }
        if any(hasForceFlag) { found.append("--force") }
        if any(hasForceKill) { found.append("kill -9") }
        for name in ["migrate:refresh", "migrate:reset", "migrate:rollback"]
        where any({ StagingHazards.scalarContains($0.lowercased(), name) || usesArtisanAbbreviation(of: name, in: $0) }) {
            found.append(name)
        }
        if any({ programThen($0, ["kubectl"], ["delete"]) }) { found.append("kubectl delete") }
        if any({ programThen($0, ["kubectl"], ["drain"]) }) { found.append("kubectl drain") }
        if any({ programThen($0, ["helm"], ["uninstall", "delete", "del", "un"]) }) { found.append("helm uninstall") }
        if any(hasTerraformDestroy) { found.append("terraform destroy") }
        if any(hasAwsDelete) { found.append("aws delete/terminate") }
        if any(hasAwsS3Remove) { found.append("aws s3 rm/rb") }
        if any(hasDdOutput) { found.append("dd of=") }
        if any({ StagingHazards.redirectionSplitWords(of: $0).contains { program($0).unicodeScalars.starts(with: "mkfs".unicodeScalars) } }) { found.append("mkfs") }
        if any({ StagingHazards.redirectionSplitWords(of: $0).contains { program($0) == "shred" } }) { found.append("shred") }
        if hasUnquotedTruncation(command, views: views) { found.append("> file") }
        if any(hasFindDelete) { found.append("find -delete") }
        if any(hasXargsOrPipedRemove) { found.append("xargs/piped rm") }
        for name in ["queue:clear", "horizon:clear", "optimize:clear"]
        where any({ StagingHazards.scalarContains($0.lowercased(), name) || usesArtisanAbbreviation(of: name, in: $0) }) {
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
                for argument in words[(index + 1)...] where argument.unicodeScalars.first == "-" {
                    if argument.unicodeScalars.starts(with: "--".unicodeScalars) {
                        if argument.unicodeScalars.count >= 3 {
                            if "--recursive".hasPrefix(argument) { recursive = true }
                            if "--force".hasPrefix(argument) { force = true }
                        }
                        continue
                    }
                    if argument.unicodeScalars.contains("r") || argument.unicodeScalars.contains("R") { recursive = true }
                    if argument.unicodeScalars.contains("f") { force = true }
                }
                if recursive && force { return true }
            }
        }
        return false
    }

    /// `--force` at a word boundary and not preceded by a word character or `-`, and its shortened `--fo`, `--for`,
    /// `--forc` (so `--force-with-lease` matches, `--forceful` and `---force` do not). Scalar by scalar, as the daemon's
    /// `has_force_flag` does: before it only ASCII counts, after it any alphanumeric scalar (or `_`) ends the match.
    private static func hasForceFlag(_ view: String) -> Bool {
        let chars = Array(view.unicodeScalars)
        for start in chars.indices where chars[start...].starts(with: "--fo".unicodeScalars) {
            if start > 0, StagingHazards.isASCIIAlphanumeric(chars[start - 1]) || chars[start - 1] == "_" || chars[start - 1] == "-" { continue }
            var end = start + 4
            for expected in ["r", "c", "e"] as [Unicode.Scalar] {
                if end < chars.count, chars[end] == expected { end += 1 } else { break }
            }
            if !(end < chars.count && (chars[end] == "_" || StagingHazards.isAlphanumeric(chars[end]))) { return true }
        }
        return false
    }

    /// Laravel accepts a shortened command name (`ca:cl`, `q:fl`, `mi:fr`, `db:w`): a word of two letters-only
    /// parts, each a non-empty prefix of the matching part of `name`. Over-matching (`c:c`) is the cheap side.
    private static func usesArtisanAbbreviation(of name: String, in text: String) -> Bool {
        let target = name.split(separator: ":").map(String.init)
        for word in StagingHazards.splitScalars(text.lowercased(), where: { $0 == " " || $0 == "\t" || $0 == ";" || $0 == "|" || $0 == "&" }) {
            let parts = StagingHazards.splitScalars(word, omittingEmpty: false, where: { $0 == ":" })
            guard parts.count == 2, target.count == 2 else { continue }
            let lettersOnly = parts.allSatisfy { !$0.isEmpty && $0.unicodeScalars.allSatisfy { $0.isASCII && $0.properties.isAlphabetic } }
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
        StagingHazards.splitScalars(view, where: { $0 == ";" || $0 == "|" || $0 == "&" })
            .map { StagingHazards.splitScalars($0, where: { $0 == " " || $0 == "\t" || $0 == "<" || $0 == ">" }) }
            .filter { !$0.isEmpty }
    }

    private static func program(_ word: String) -> String {
        (StagingHazards.splitScalars(word, omittingEmpty: false, where: { $0 == "/" }).last ?? word).lowercased()
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
                if word.unicodeScalars.starts(with: "--signal=".unicodeScalars),
                   isKillSignal(StagingHazards.string(word.unicodeScalars.dropFirst("--signal=".count))) { return true }
                if word.unicodeScalars.first == "-", !word.unicodeScalars.starts(with: "--".unicodeScalars) {
                    let flag = StagingHazards.string(word.unicodeScalars.dropFirst())
                    if isKillSignal(flag) { return true }
                    if flag.unicodeScalars.first == "s" || flag.unicodeScalars.first == "n",
                       isKillSignal(StagingHazards.string(flag.unicodeScalars.dropFirst())) { return true }
                }
                if ["-s", "-n", "--signal"].contains(word), index + 1 < rest.count, isKillSignal(rest[index + 1]) { return true }
            }
        }
        return false
    }

    /// `terraform`, `tofu`, `terragrunt` or `pulumi` followed later in the segment by `destroy`, `destroy-all`,
    /// `-destroy`, `--destroy`, `-replace` or `--replace` (optionally `=value`), or, for `pulumi`, `down` (its alias
    /// of `destroy`). `plan -destroy` is read-only but its plan file can be applied unseen, so it asks too. Also
    /// (same label) `taint`, `force-unlock`, `workspace ... delete`, `state ... rm`/`remove`/`push`/`delete` and
    /// `stack ... rm`/`remove` (pulumi: deletes the stack and its history): each makes the next apply destroy
    /// something, or forgets, overwrites or deletes state, or breaks a lock.
    private static func hasTerraformDestroy(_ view: String) -> Bool {
        let programs = ["terraform", "tofu", "terragrunt", "pulumi"]
        for words in segmentWords(view) {
            guard let at = words.firstIndex(where: { programs.contains(program($0)) }) else { continue }
            let pulumi = program(words[at]) == "pulumi"
            let lowered = words[(at + 1)...].map { $0.lowercased() }
            func then(_ first: String, _ verbs: [String]) -> Bool {
                guard let found = lowered.firstIndex(of: first) else { return false }
                return lowered[(found + 1)...].contains { verbs.contains($0) }
            }
            if then("workspace", ["delete"]) || then("state", ["rm", "remove", "push", "delete"])
                || then("stack", ["rm", "remove"]) { return true }
            for word in lowered {
                if ["destroy", "destroy-all", "taint", "force-unlock"].contains(word) || (pulumi && word == "down") { return true }
                if word.unicodeScalars.first == "-" {
                    let flag = StagingHazards.string(word.unicodeScalars.drop(while: { $0 == "-" }))
                    let name = StagingHazards.splitScalars(flag, omittingEmpty: false, where: { $0 == "=" }).first ?? ""
                    if name == "destroy" || name == "replace" { return true }
                }
            }
        }
        return false
    }

    /// `aws` followed later in the segment by a word that is exactly `delete-...`, `batch-delete-...`, `terminate-...`,
    /// `remove-...`, `deregister-...` or `purge-...`, or exactly `schedule-key-deletion` (kms: the key is gone in 7 to
    /// 30 days) or `stop-instances`, or `update-service` with `--desired-count` 0, `+0` or `-0` (an ECS service scaled to
    /// nothing).
    private static func hasAwsDelete(_ view: String) -> Bool {
        let verbs = ["delete-", "batch-delete-", "terminate-", "remove-", "deregister-", "purge-"]
        // A shell tool parses `+0` and `-0` as 0 too.
        func isZero(_ text: String) -> Bool {
            var digits = Substring(text)
            if let first = digits.first, first == "+" || first == "-" { digits = digits.dropFirst() }
            return !digits.isEmpty && digits.allSatisfy { $0 == "0" }
        }
        for words in segmentWords(view) {
            guard let after = afterProgram(words, ["aws"]) else { continue }
            let rest = after.map { $0.lowercased() }
            if rest.contains("update-service") {
                for (index, word) in rest.enumerated() {
                    if word.unicodeScalars.starts(with: "--desired-count=".unicodeScalars),
                       isZero(StagingHazards.string(word.unicodeScalars.dropFirst("--desired-count=".count))) { return true }
                    if word == "--desired-count", index + 1 < rest.count, isZero(rest[index + 1]) { return true }
                }
            }
            for word in rest {
                if word == "schedule-key-deletion" || word == "stop-instances" { return true }
                for verb in verbs where word.unicodeScalars.starts(with: verb.unicodeScalars) {
                    let tail = word.unicodeScalars.dropFirst(verb.unicodeScalars.count)
                    if !tail.isEmpty && tail.allSatisfy({ ($0.value >= 0x61 && $0.value <= 0x7A) || StagingHazards.isASCIIDigit($0) || $0 == "-" }) { return true }
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
            afterProgram(words, ["dd"])?.contains { $0.lowercased().unicodeScalars.starts(with: "of=".unicodeScalars) } ?? false
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
        guard let regex = StagingHazards.expression(deletePattern, caseInsensitive: true) else { return false }
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

    // MARK: Shutdown, in command position

    /// Programs that run what follows them as a command, so a later word in the same segment may be the command
    /// (`bash -c 'reboot'`, `ssh host reboot`, `xargs systemctl stop`, `find -exec shutdown`): the quote wrappers
    /// (`StagingHazards.quoteWrappers`) and these.
    private static let moreCommandWrappers: Set<String> = ["xargs", "nsenter", "chroot", "find"]

    /// The indexes of the words of one segment that are in command position: the first word, then each word after
    /// only prefix words (an assignment, a prefix program, an option, an option's value, a duration), and, once a
    /// command wrapper or a substitution placeholder (`_`: its output may be the command) has been seen, every
    /// later word.
    private static func commandPositions(_ words: [String]) -> [Int] {
        var positions: [Int] = []
        var leading = true
        var wrapped = false
        var afterOption = false
        for (index, word) in words.enumerated() {
            if leading || wrapped { positions.append(index) }
            let name = program(word)
            let runsOthers = ["kubectl", "docker", "podman"].contains(name)
                && words[(index + 1)...].contains { ["exec", "run"].contains($0.lowercased()) }
            if StagingHazards.quoteWrappers.contains(name) || moreCommandWrappers.contains(name) || word == "_" || runsOthers
                || (leading && StagingHazards.isDotWrapper(word)) {
                wrapped = true
            }
            if leading { (leading, afterOption) = StagingHazards.leadingStep(word, afterOption: afterOption) }
        }
        return positions
    }

    /// The verbs of `systemctl`, `loginctl` and `machinectl` that take the machine (or a guest) down or out of service.
    private static let powerVerbs = ["reboot", "poweroff", "halt", "kexec", "rescue", "emergency", "suspend", "hibernate"]

    /// A `shutdown`, `reboot`, `halt` or `poweroff` program, `systemctl` followed later in the segment by `stop`,
    /// `disable`, `mask` or a power verb, `loginctl` or `machinectl` followed by a power verb, or `service` followed
    /// later by `stop`, each only in command position
    /// (`commandPositions`): `last reboot | head` and `grep -i shutdown /var/log/syslog` merely mention one.
    private static func hasStopOrShutdown(_ view: String) -> Bool {
        for words in segmentWords(view) {
            for at in commandPositions(words) {
                func later(_ verbs: [String]) -> Bool { words[(at + 1)...].contains { verbs.contains($0.lowercased()) } }
                switch program(words[at]) {
                case "shutdown", "reboot", "halt", "poweroff": return true
                case "systemctl": if later(["stop", "disable", "mask"]) || later(powerVerbs) { return true }
                case "loginctl", "machinectl": if later(powerVerbs) { return true }
                case "service": if later(["stop"]) { return true }
                default: break
                }
            }
        }
        return false
    }

    /// `> file` on the views of the text with the operators of its quoted strings masked: a `>` inside a quoted
    /// string is a character, not a redirection (`StagingHazards.maskingQuotedOperators`).
    private static func hasUnquotedTruncation(_ command: String, views: [String]) -> Bool {
        let masked = StagingHazards.maskingQuotedOperators(command)
        if masked == command { return views.contains(where: truncatesAFile) }
        let maskedViews = [masked] + StagingHazards.normalisedViews(masked) + StagingHazards.normalisedWordViews(masked)
        return maskedViews.contains(where: truncatesAFile)
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
        if command.unicodeScalars.first == "^" { return true }
        let scalars = Array(command.unicodeScalars)
        for (index, scalar) in scalars.enumerated() where scalar == "!" && index + 1 < scalars.count {
            let next = scalars[index + 1]
            if next != " " && next != "=" && next != "(" { return true }
        }
        return normalisedViews(command).contains { view in
            words(of: view).contains(where: { $0 == "fc" || $0 == "history" })
                || segments(of: view).contains { segment in
                    splitScalars(segment, where: { $0 == " " || $0 == "\t" })
                        .first(where: { !leavesCommandPosition($0) }) == "r"
                }
        }
    }

    private static let prefixWords: Set<String> = ["then", "do", "else", "elif", "if", "while", "until", "!", "-", "command", "builtin",
                                                   "eval", "exec", "time", "sudo", "noglob", "nocorrect", "nohup", "nice", "env", "coproc"]

    /// Does `word` leave the next word in command position? A prefix word, a prefix assignment (`X=1 r` runs the
    /// builtin), an option or a number (`nice -n 5 r`). Only read before a segment's command, so `ls -r` stops at `ls`.
    private static func leavesCommandPosition(_ word: String) -> Bool {
        let scalars = Array(word.unicodeScalars)
        if prefixWords.contains(word) || scalars.first == "-" || scalars.allSatisfy(isASCIIDigit) { return true }
        guard let equals = scalars.firstIndex(of: "="), equals > 0, !isASCIIDigit(scalars[0]) else { return false }
        return scalars[..<equals].allSatisfy { isASCIIAlphanumeric($0) || $0 == "_" }
    }

    /// `$'...'` (ANSI-C quoting) with a backslash inside: the shell turns `\x72` into `r`, which no text rule can follow.
    static let escapeQuotedLabel = "\u{26A0} Contains an escape-quoted word ($'...' with a backslash): what runs may differ from what you see."

    /// What a production pane's row adds to a warning that makes Insert ask first.
    static let asksFirstSuffix = " Insert asks first."

    /// A brace group glued to a word (`r{m,} -rf x`, `kill -{9..9} 1`): the shell expands it into words no text rule can follow.
    static let braceGluedLabel = "\u{26A0} Contains a brace expansion glued to a word ({a,b} or {1..3}): what runs may differ from what you see."

    static func escapeQuotedWordLabel(_ command: String, production: Bool = false) -> String? {
        regex(#"\$'[^']*\\"#, in: command, caseInsensitive: false) ? escapeQuotedLabel + (production ? asksFirstSuffix : "") : nil
    }

    static func braceGluedWordLabel(_ command: String, production: Bool = false) -> String? {
        hasBraceGluedWord(command) ? braceGluedLabel + (production ? asksFirstSuffix : "") : nil
    }

    /// A wildcard in the command word (`/bin/r? -rf x`, `/sbin/reb??t`): the shell expands it into a program no text rule can follow.
    static let wildcardCommandLabel = "\u{26A0} The command word is a wildcard (? * [): what runs may differ from what you see."

    static func wildcardCommandWordLabel(_ command: String, production: Bool = false) -> String? {
        hasWildcardCommandWord(command) ? wildcardCommandLabel + (production ? asksFirstSuffix : "") : nil
    }

    /// Shown in a production pane next to the non-ASCII label: any non-ASCII text makes Insert ask first.
    static let nonASCIIAsksLabel = "\u{26A0} Contains characters outside ASCII (a combining mark can change what a shell reads). Insert asks first."

    /// Does a production pane ask before inserting `command`? On a destructive match, on an escape-quoted word
    /// (`$'\x72\x6d' -rf x`), on a brace group glued to a word (`r{m,} -rf x`), on a wildcard in the command word
    /// (`/bin/r? -rf x`) and on any non-ASCII text: no text rule can follow what the shell makes of the first four, and
    /// the last is the belt to the scalar scanners' braces, so they fail toward the sheet. The daemon's
    /// `asks_in_production` is the same rule.
    static func asksFirstInProduction(_ command: String) -> Bool {
        !StagingDestructivePatterns.matches(command).isEmpty || escapeQuotedWordLabel(command) != nil
            || braceGluedWordLabel(command) != nil || hasWildcardCommandWord(command) || containsNonASCII(command)
    }

    // MARK: Scalars, not Characters
    //
    // Every scanner below walks `unicodeScalars`. A `Character` is a grapheme cluster: a combining accent (U+0301)
    // glues to the scalar before it, so `,` followed by U+0301 is no longer a comma, and a shell (and the daemon,
    // which reads code points) still sees one. The same goes for `String.hasPrefix`, `split(whereSeparator:)`,
    // `contains(_: Character)` and friends, which is why the destructive rules use the scalar helpers here.

    static func isASCIIDigit(_ c: Unicode.Scalar) -> Bool { c.value >= 0x30 && c.value <= 0x39 }

    static func isASCIIAlphanumeric(_ c: Unicode.Scalar) -> Bool {
        isASCIIDigit(c) || (c.value >= 0x41 && c.value <= 0x5A) || (c.value >= 0x61 && c.value <= 0x7A)
    }

    /// The Rust `char::is_alphanumeric`: Alphabetic or numeric (Nd, Nl, No).
    static func isAlphanumeric(_ c: Unicode.Scalar) -> Bool {
        if c.properties.isAlphabetic { return true }
        switch c.properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }

    /// Does `text` hold `needle` as a run of scalars? (`String.contains` compares Characters: a combining mark glued
    /// to the last letter of `needle` would hide it.)
    static func scalarContains(_ text: String, _ needle: String) -> Bool {
        let hay = Array(text.unicodeScalars)
        let pin = Array(needle.unicodeScalars)
        if pin.isEmpty { return true }
        guard hay.count >= pin.count else { return false }
        for start in 0...(hay.count - pin.count) where Array(hay[start..<(start + pin.count)]) == pin { return true }
        return false
    }

    /// A string from scalars.
    static func string<S: Sequence>(_ scalars: S) -> String where S.Element == Unicode.Scalar {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    /// `text` split at the scalars for which `isSeparator` holds, as a scalar-wise `split(whereSeparator:)`.
    static func splitScalars(_ text: String, omittingEmpty: Bool = true, where isSeparator: (Unicode.Scalar) -> Bool) -> [String] {
        text.unicodeScalars.split(omittingEmptySubsequences: omittingEmpty, whereSeparator: isSeparator).map { string($0) }
    }

    /// Any code point above U+007F. A production pane asks first for text that holds one, whatever it is (an
    /// accented letter, a combining mark, a look-alike letter): the scanners read scalars, but a combining accent
    /// glued to a `,`, a quote or a `;` is the one thing that reads differently to a person, to a rule and to a
    /// shell, so the sheet is the belt to the scalars' braces. **Cost, taken on purpose:** `echo café` asks too
    /// (the drawer already labels non-ASCII text). The daemon's `contains_non_ascii` is the same rule.
    static func containsNonASCII(_ command: String) -> Bool {
        command.unicodeScalars.contains { !$0.isASCII }
    }

    /// Expansions that are empty at run time (`rm${IFS}-rf` is `rm -rf`; `r$@m` is `rm`). Longest first.
    private static let emptyExpansions = ["${IFS}", "$IFS", "$()", "$@", "$*"]

    /// Length of the empty expansion starting at `chars[index]` (a `$`), if any: the fixed forms, a positional
    /// parameter (`$0`-`$9`, `${0}`-`${9}`) and `${IFS` with a plain `%` / `#` / `:N:M` modifier, which runs to the `}`.
    private static func emptyExpansionLength(_ chars: [Unicode.Scalar], at index: Int) -> Int? {
        if let fixed = emptyExpansions.first(where: { chars[index...].starts(with: Array($0.unicodeScalars)) }) {
            return fixed.unicodeScalars.count
        }
        func at(_ offset: Int) -> Unicode.Scalar? { index + offset < chars.count ? chars[index + offset] : nil }
        func isDigit(_ c: Unicode.Scalar?) -> Bool { c.map(isASCIIDigit) ?? false }
        if isDigit(at(1)) { return 2 }
        if at(1) == "{", isDigit(at(2)), at(3) == "}" { return 4 }
        if chars[index...].starts(with: Array("${IFS".unicodeScalars)), let close = chars[(index + 5)...].firstIndex(of: "}") {
            // Only modifiers that keep whitespace or nothing: `%` / `#` with a literal pattern, and `:N` / `:N:M`.
            // `:+`, `:-`, `=`, `/` and anything with `$`, a backtick or `(` are not swallowed: the operand can run
            // a command, so it stays visible to the rules.
            let body = Array(chars[(index + 5)..<close])
            let offset = body.count > 1 && body[0] == ":" && body.dropFirst().allSatisfy { $0 == ":" || isASCIIDigit($0) }
            let literal = !body.dropFirst().contains(where: { "$`(){\\'\"".unicodeScalars.contains($0) })
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
        let chars = Array(text.unicodeScalars)
        var index = 0
        while index < chars.count {
            let c = chars[index]
            if c == "$", let length = emptyExpansionLength(chars, at: index) {
                index += length
                if !(empty == " " && out.unicodeScalars.last == " ") { out.append(empty) }
                continue
            }
            if c == "$", index + 1 < chars.count, chars[index + 1] == "'" || chars[index + 1] == "\"" {
                index += 1
                continue
            }
            if c == "/", index + 1 < chars.count, chars[index + 1] == "*" {
                index += 2
                var previous: Unicode.Scalar = "\0"
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
                if c.properties.isWhitespace {
                    if out.unicodeScalars.last != " " { out.append(" ") }
                } else {
                    out.unicodeScalars.append(c)
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
        let chars = Array(text.unicodeScalars)
        var braces = 0
        var escaped = false
        var index = 0
        while index < chars.count {
            let c = chars[index]
            // A backslash-escaped character never opens a substitution. A quoted opener is NOT told apart here: it
            // opens like any other, and its body is emitted below, so what it hides is still seen (`rm '$(' -rf x ')'`).
            let literal = escaped
            escaped = false
            if c == "$", !literal {
                if let length = emptyExpansionLength(chars, at: index) {
                    index += length
                    if !(empty == " " && out.unicodeScalars.last == " ") { out.append(empty) }
                    continue
                }
                let next: Unicode.Scalar? = index + 1 < chars.count ? chars[index + 1] : nil
                if next == "'" || next == "\"" {
                    index += 1
                    continue
                }
                if next == "(", let close = closingIndex(chars, from: index + 1, open: "(", close: ")") {
                    out.append(" _ ")
                    out.append(substitutionWords(Array(chars[(index + 2)..<close]), empty: empty))
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
            if c == "<", !literal, index + 1 < chars.count, chars[index + 1] == "(",
               let close = closingIndex(chars, from: index + 1, open: "(", close: ")") {
                out.append(" _ ")
                out.append(substitutionWords(Array(chars[(index + 2)..<close]), empty: empty))
                index = close + 1
                continue
            }
            if c == "`", !literal, let close = closingBacktick(chars, from: index) {
                out.append(" _ ")
                out.append(substitutionWords(Array(chars[(index + 1)..<close]), empty: empty))
                index = close + 1
                continue
            }
            index += 1
            switch c {
            case "\\": escaped = !literal
            case "'", "\"": break
            case "{":
                braces += 1
                out.append(" ")
            case "}":
                braces = max(0, braces - 1)
                out.append(" ")
            case "," where braces > 0: out.append(" ")
            case "`", "(", ")": out.append(" ")
            default:
                if c.properties.isWhitespace { out.append(" ") } else { out.unicodeScalars.append(c) }
            }
        }
        return out
    }

    /// The words inside a `$(...)`, backtick pair or `<(...)` for `normalisedWords`: the body as that view reads any
    /// text, with `;`, `|` and `&` turned into spaces so it cannot split the outer segment.
    private static func substitutionWords(_ body: [Unicode.Scalar], empty: String) -> String {
        let words = normalisedWords(string(body), empty: empty).unicodeScalars.map { (c: Unicode.Scalar) -> Unicode.Scalar in
            c == ";" || c == "|" || c == "&" ? " " : c
        }
        return " " + string(words) + " "
    }

    /// The index of the scalar that closes the `open` at `chars[start]`, counting nested pairs; nil when unbalanced.
    /// Quote- and escape-aware: a closer (or an opener) inside `'...'` or `"..."`, or after a backslash, neither closes
    /// nor opens, so `$(echo ")"; x)` closes at its last parenthesis. A quote that never closes makes the whole group
    /// unbalanced (the caller then drops the opener and what follows stays visible). A `case` pattern's `)`
    /// (`$(case a in a) cmd;; esac)`) does not close: while a `case` word in command position is open (until its
    /// `esac`), a `)` at the group's own depth ends a pattern, not the group.
    private static func closingIndex(_ chars: [Unicode.Scalar], from start: Int, open: Unicode.Scalar, close: Unicode.Scalar) -> Int? {
        var depth = 0
        var quote: Unicode.Scalar?
        var escaped = false
        var cases = 0
        var atCommand = true
        var word = ""
        var wordAtCommand = false
        // A word that ended: `case` in command position opens a case, `esac` in command position closes one.
        func endWord() {
            if wordAtCommand && word == "case" {
                cases += 1
            } else if wordAtCommand && word == "esac" {
                cases = max(0, cases - 1)
            }
            word = ""
        }
        for index in start..<chars.count {
            let c = chars[index]
            if escaped {
                escaped = false
            } else if quote == "'" {
                if c == "'" { quote = nil }
            } else if c == "\\" {
                endWord()
                atCommand = false
                escaped = true
            } else if quote != nil {
                if quote == c { quote = nil }
            } else if c == "'" || c == "\"" {
                endWord()
                atCommand = false
                quote = c
            } else if isASCIIAlphanumeric(c) || c == "_" {
                if word.isEmpty {
                    wordAtCommand = atCommand
                    atCommand = false
                }
                word.unicodeScalars.append(c)
            } else {
                endWord()
                if c == open {
                    depth += 1
                    atCommand = true
                } else if c == close {
                    atCommand = true
                    if !(depth == 1 && cases > 0 && close == ")") {
                        depth = max(0, depth - 1)
                        if depth == 0 { return index }
                    }
                } else if c == ";" || c == "&" || c == "|" || c == "\n" || c == "{" {
                    atCommand = true
                } else if !c.properties.isWhitespace {
                    atCommand = false
                }
            }
        }
        return nil
    }

    /// The index of the backtick that closes the one at `chars[start]`: the next one not escaped by a backslash.
    private static func closingBacktick(_ chars: [Unicode.Scalar], from start: Int) -> Int? {
        var escaped = false
        var index = start + 1
        while index < chars.count {
            let c = chars[index]
            if escaped {
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "`" {
                return index
            }
            index += 1
        }
        return nil
    }

    // MARK: Quoted operators, glued brace groups

    /// Programs whose quoted argument is itself a command (`bash -c '...'`, `eval '...'`, `ssh host '...'`,
    /// `parallel '...'`, `source <(echo '...')`, `echo '...' | at now`): that argument is analysed as live code, not
    /// as a string. A lone `.` (the other name of `source`) counts too, but only in command position (`find . -name`
    /// is not a wrapper): `isDotWrapper`.
    static let quoteWrappers: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "ash", "csh", "tcsh", "fish", "mksh", "rbash", "yash", "pwsh", "eval",
        "ssh", "mosh", "parallel", "watch", "su", "script", "flock", "runuser", "gosu", "su-exec", "pdsh", "ansible",
        "source", "at", "batch"]

    /// A lone `.` is `source`: it runs its file, which may be `<(echo '...')` or `/dev/stdin`.
    static func isDotWrapper(_ word: String) -> Bool { word == "." }

    private static func programName(_ word: String) -> String {
        (splitScalars(word, omittingEmpty: false, where: { $0 == "/" }).last ?? word).lowercased()
    }

    private static func maskedOperator(_ c: Unicode.Scalar) -> Unicode.Scalar { c == ">" || c == "{" || c == "}" ? "_" : c }

    /// Programs that run another program after their own words, so what follows them is still in command position.
    private static let prefixPrograms: Set<String> = [
        "then", "do", "else", "elif", "if", "while", "until", "!", "-", "command", "builtin", "eval", "exec",
        "time", "sudo", "doas", "noglob", "nocorrect", "nohup", "nice", "ionice", "setsid", "env", "timeout",
        "pkexec", "busybox", "stdbuf", "systemd-run", "strace", "ltrace", "taskset", "chrt", "numactl", "unbuffer",
        "caffeinate", "unshare", "setpriv", "coproc"]

    /// Options of the prefix programs that take a value (`sudo -u deploy`, `timeout -s KILL 5`, `ionice -c 2`,
    /// `exec -a name`, `strace -o file`, `sudo -D dir`, `env -S 'cmd'`; compared lowercased). A long option
    /// without `=` is taken to have one too (`sudo --user deploy reboot`): that only ever asks more.
    private static let optionsWithValue: Set<String> = ["-u", "-g", "-h", "-p", "-r", "-t", "-c", "-s", "-k", "-n", "-a", "-o", "-w", "-d"]

    /// A `name=value` prefix assignment.
    private static func isAssignment(_ word: String) -> Bool {
        let scalars = Array(word.unicodeScalars)
        guard let equals = scalars.firstIndex(of: "="), equals > 0, !isASCIIDigit(scalars[0]) else { return false }
        return scalars[..<equals].allSatisfy { isASCIIAlphanumeric($0) || $0 == "_" }
    }

    /// A number, duration or hex mask (`5`, `0.5`, `5s`, `10m`, `0x3`): the operand of `nice`, `timeout`, `taskset`.
    private static func isDuration(_ word: String) -> Bool {
        var scalars = Array(word.unicodeScalars)
        if word.unicodeScalars.starts(with: "0x".unicodeScalars) {
            let hex = scalars.dropFirst(2)
            return !hex.isEmpty && hex.allSatisfy { isASCIIDigit($0) || ($0.value >= 0x41 && $0.value <= 0x46) || ($0.value >= 0x61 && $0.value <= 0x66) }
        }
        if let last = scalars.last, "smhd".unicodeScalars.contains(last) { scalars.removeLast() }
        return !scalars.isEmpty && scalars.contains(where: isASCIIDigit) && scalars.allSatisfy { isASCIIDigit($0) || $0 == "." }
    }

    /// While reading the words before a segment's command: does `word` leave the next word in command position (a prefix
    /// word), and does it take a value of its own (so the word after it is one too)?
    static func leadingStep(_ word: String, afterOption: Bool) -> (prefix: Bool, takesValue: Bool) {
        let dash = word.unicodeScalars.first == "-"
        let prefix = afterOption || isAssignment(word) || prefixPrograms.contains(programName(word)) || dash || isDuration(word)
        let takesValue = dash
            && (optionsWithValue.contains(word.lowercased())
                || (word.unicodeScalars.starts(with: "--".unicodeScalars) && !word.unicodeScalars.contains("=")))
        return (prefix, takesValue)
    }

    /// `text` with the operators that a quoted string cannot use replaced by `_`: a `>` (not a redirection), `{` and `}`
    /// (not a brace group) inside `'...'`, `"..."` or `$'...'`, and a `>` inside an arithmetic expansion
    /// (`$(( 3 > 2 ))`, `arithmeticEnd`). Things stay live: the quoted argument of a command wrapper
    /// (a quoted string after a `quoteWrappers` word in the same segment, the word read as a shell reads it:
    /// `b'a'sh -c 'echo x > f'`, `\bash`, and any command word holding a `$` expansion or a backtick, which may be a
    /// shell: `$SHELL -c '...'`), analysed recursively with its own quotes; a double-quoted string that holds a `$(...)`
    /// or a backtick (its text is scanned as live command text, because a substitution can hold a `case` pattern or a
    /// quote that no cheap scan follows: **cost, taken on purpose:** `echo "x > y $(date)"` asks); everything in a
    /// string whose closing quote is missing; and, when a command wrapper or a `$` command word is fed by a pipe
    /// (`echo 'echo x > f' | sh`, `| ssh h`), everything. The daemon's `mask_quoted_operators` is the same scan.
    ///
    /// **Accepted trade-off of ignoring a quoted `>`:** `awk 'BEGIN{print 1 > "/etc/x"}'`, a `perl -e` or an
    /// `osascript` program that writes a file is not seen (python, ruby and node never were).
    static func maskingQuotedOperators(_ text: String) -> String {
        let (masked, scan) = scanQuotes(text)
        return scan.fedShell ? text : masked
    }

    /// Does a command word (the first word of a segment after the prefix words: `sudo`, `env`, options and
    /// assignments) hold a wildcard (`?`, `*`, `[`), except the `[` and `[[` of a test? A shell expands
    /// `/bin/r? -rf /x` into `/bin/rm -rf /x`, which no text rule can follow, so a production pane asks. A wildcard
    /// in an argument or inside a quoted program does not count; the word is read as a shell reads it, so a quoted
    /// wildcard counts (asking is the cheap side). The daemon's `wildcard_command_word` is the same rule.
    static func hasWildcardCommandWord(_ command: String) -> Bool {
        scanQuotes(command).scan.wildcardCommand
    }

    /// What the quote scan found besides the masked text.
    struct QuoteScan {
        /// A command wrapper or a `$` command word is fed by a pipe: everything is live.
        var fedShell = false
        /// A command word holds a wildcard (`hasWildcardCommandWord`).
        var wildcardCommand = false
    }

    private static func scanQuotes(_ text: String) -> (masked: String, scan: QuoteScan) {
        var out = ""
        var scan = QuoteScan()
        maskInto(Array(text.unicodeScalars), &out, &scan)
        return (out, scan)
    }

    /// What the mask scan knows about the segment it is in.
    private struct MaskSegment {
        /// The current word as a shell reads it: quotes and backslashes dropped, quoted text kept.
        var word = ""
        var wrapperSeen = false
        var leading = true
        var afterOption = false
        /// A `xargs`-like word has been seen: a `$` word after it may be the command it runs.
        var runsOthers = false
        var piped: Bool

        mutating func endWord(_ scan: inout QuoteScan) {
            if word.isEmpty { return }
            let name = StagingHazards.programName(word)
            let wrapper = StagingHazards.quoteWrappers.contains(name) || (leading && StagingHazards.isDotWrapper(word))
            if wrapper { wrapperSeen = true }
            // `env -S 'cmd'` runs its string as a command line.
            if leading && (word.unicodeScalars.starts(with: "-S".unicodeScalars) || word.unicodeScalars.starts(with: "--split-string".unicodeScalars)) {
                wrapperSeen = true
            }
            // A variable or substitution where the command goes (`$SHELL -c '...'`, `` `which bash` -c '...' ``) may
            // be a shell.
            let dynamicCommand = (leading || runsOthers) && word.unicodeScalars.contains(where: { $0 == "$" || $0 == "`" })
            if dynamicCommand { wrapperSeen = true }
            if piped && (wrapper || dynamicCommand) { scan.fedShell = true }
            if ["xargs", "nsenter", "chroot", "find", "kubectl", "docker", "podman"].contains(name) { runsOthers = true }
            if leading {
                (leading, afterOption) = StagingHazards.leadingStep(word, afterOption: afterOption)
                // The first word that is not a prefix is the command word.
                if !leading && word != "[" && word != "[["
                    && word.unicodeScalars.contains(where: { $0 == "?" || $0 == "*" || $0 == "[" }) {
                    scan.wildcardCommand = true
                }
            }
            word = ""
        }
    }

    private static func maskInto(_ chars: [Unicode.Scalar], _ out: inout String, _ scan: inout QuoteScan) {
        var segment = MaskSegment(piped: false)
        var index = 0
        while index < chars.count {
            let c = chars[index]
            if c == "$", let end = arithmeticEnd(chars, at: index) {
                for n in chars[index..<end] {
                    out.unicodeScalars.append(n == ">" ? "_" : n)
                    segment.word.unicodeScalars.append(n)
                }
                index = end
                continue
            }
            switch c {
            case "\\":
                out.unicodeScalars.append(c)
                if index + 1 < chars.count {
                    out.unicodeScalars.append(chars[index + 1])
                    segment.word.unicodeScalars.append(chars[index + 1])
                }
                index += 2
            case "'", "\"":
                let ansi = c == "'" && index > 0 && chars[index - 1] == "$"
                guard let end = quoteEnd(chars, from: index, ansi: ansi) else {
                    out.unicodeScalars.append(contentsOf: chars[index...])
                    return
                }
                let content = Array(chars[(index + 1)..<end])
                out.unicodeScalars.append(c)
                if segment.wrapperSeen || (c == "\"" && holdsSubstitution(content)) {
                    maskInto(content, &out, &scan)
                } else if c == "\"" {
                    maskDoubleQuoted(content, &out)
                } else {
                    out.unicodeScalars.append(contentsOf: content.map(maskedOperator))
                }
                out.unicodeScalars.append(c)
                segment.word.unicodeScalars.append(contentsOf: content)
                index = end + 1
            case "&" where index > 0 && chars[index - 1] == "|":
                // The `&` of `|&` belongs to the pipe: the segment it ends is still fed by it.
                segment.endWord(&scan)
                out.unicodeScalars.append(c)
                index += 1
            case ";", "|", "&", "\n":
                segment.endWord(&scan)
                let singlePipe = c == "|" && !(index + 1 < chars.count && chars[index + 1] == "|")
                    && !(index > 0 && chars[index - 1] == "|")
                segment = MaskSegment(piped: singlePipe)
                out.unicodeScalars.append(c)
                index += 1
            default:
                if c.properties.isWhitespace || c == "(" || c == ")" {
                    segment.endWord(&scan)
                } else {
                    segment.word.unicodeScalars.append(c)
                }
                out.unicodeScalars.append(c)
                index += 1
            }
        }
        segment.endWord(&scan)
    }

    /// Does the text inside a double-quoted string hold a `$(` or a backtick?
    private static func holdsSubstitution(_ content: [Unicode.Scalar]) -> Bool {
        for (index, c) in content.enumerated() {
            if c == "`" || (c == "$" && index + 1 < content.count && content[index + 1] == "(") { return true }
        }
        return false
    }

    /// The inside of a double-quoted string that holds no substitution: every `>`, `{` and `}` masked.
    private static func maskDoubleQuoted(_ content: [Unicode.Scalar], _ out: inout String) {
        var index = 0
        while index < content.count {
            let c = content[index]
            if c == "\\" {
                out.unicodeScalars.append(c)
                if index + 1 < content.count { out.unicodeScalars.append(maskedOperator(content[index + 1])) }
                index += 2
                continue
            }
            out.unicodeScalars.append(maskedOperator(c))
            index += 1
        }
    }

    /// The index just past the `))` of the arithmetic expansion starting at `chars[start]` (`$((`), when its body is
    /// plain arithmetic: letters, digits, spaces and the operator characters, no parenthesis, quote, backtick,
    /// backslash or `;`. A `>` in it is a comparison, not a redirection (`echo $(( 3 > 2 ))`); a body with anything
    /// else (`$(( $(echo x > f) ))`, `$((echo x > f) )`) is read as the command it may be.
    private static func arithmeticEnd(_ chars: [Unicode.Scalar], at start: Int) -> Int? {
        guard start + 2 < chars.count, chars[start + 1] == "(", chars[start + 2] == "(",
              let close = closingIndex(chars, from: start + 1, open: "(", close: ")"),
              close >= start + 5, chars[close - 1] == ")" else { return nil }
        let operators = " \t_$+-*/%<>=!^~?:,.#&|".unicodeScalars
        let plain = chars[(start + 3)..<(close - 1)].allSatisfy { isASCIIAlphanumeric($0) || operators.contains($0) }
        return plain ? close + 1 : nil
    }

    /// The index of the quote that closes the one at `chars[start]`: a single quote has no escapes (but `$'...'` does), a
    /// double quote honours backslashes and skips over `$(...)` and backtick substitutions. Nil if unterminated.
    private static func quoteEnd(_ chars: [Unicode.Scalar], from start: Int, ansi: Bool) -> Int? {
        let quote = chars[start]
        var index = start + 1
        while index < chars.count {
            let c = chars[index]
            if c == quote { return index }
            if c == "\\" && (quote == "\"" || ansi) {
                index += 2
                continue
            }
            if quote == "\"" {
                var skip: Int?
                if c == "$", index + 1 < chars.count, chars[index + 1] == "(" {
                    skip = closingIndex(chars, from: index + 1, open: "(", close: ")")
                } else if c == "`" {
                    skip = closingBacktick(chars, from: index)
                }
                if let close = skip {
                    index = close + 1
                    continue
                }
            }
            index += 1
        }
        return nil
    }

    /// An unquoted, unescaped brace expansion (`{a,b}` or `{1..3}`, `{x..z}`: a body with no whitespace and a comma or a
    /// sequence) glued to other text: the scalar before the `{` or after the `}` is not whitespace and not `;`, `|`,
    /// `&`, `<`, `>`, `(` or `)`. A shell expands it into words no rule can follow (`r{m,} -rf /x` is `rm -rf /x`), so a
    /// production pane asks. A group alone (`{rm,-rf,/x}`, `ls {a,b}`) is read by the normalised views instead, and
    /// `${...}` is a parameter expansion. **Cost, taken on purpose:** an ordinary glued group such as `cp file{,.bak}` or
    /// `ls file{1,2}.txt` asks too. Quoted braces (`jq '{a,b}'`, `--query 'Items[].{Id:Id}'`) do not count, except in the
    /// quoted argument of a command wrapper (`maskingQuotedOperators`). The daemon's `brace_glued_word` is the same rule.
    static func hasBraceGluedWord(_ command: String) -> Bool {
        guard command.unicodeScalars.contains("{") else { return false }
        let chars = Array(maskingQuotedOperators(command).unicodeScalars)
        func glue(_ index: Int) -> Bool {
            guard index >= 0, index < chars.count else { return false }
            return !chars[index].properties.isWhitespace && !";|&<>()".unicodeScalars.contains(chars[index])
        }
        var index = 0
        while index < chars.count {
            if chars[index] == "\\" {
                index += 1
            } else if chars[index] == "{", index == 0 || chars[index - 1] != "$", let close = matchingBrace(chars, from: index) {
                if isBraceExpansion(Array(chars[(index + 1)..<close])) && (glue(index - 1) || glue(close + 1)) { return true }
            }
            index += 1
        }
        return false
    }

    /// The index of the `}` that closes the `{` at `chars[start]` (nested pairs counted, backslashes skipped).
    private static func matchingBrace(_ chars: [Unicode.Scalar], from start: Int) -> Int? {
        var depth = 0
        var index = start
        while index < chars.count {
            if chars[index] == "\\" {
                index += 1
            } else if chars[index] == "{" {
                depth += 1
            } else if chars[index] == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    /// Would a shell expand a group with this body: no whitespace, and a comma or a sequence (`1..3`, `-2..2`, `a..z`,
    /// with an optional `..step`)?
    private static func isBraceExpansion(_ body: [Unicode.Scalar]) -> Bool {
        if body.contains(where: { $0.properties.isWhitespace }) { return false }
        if body.contains(",") { return true }
        // Split at `..`, left to right, without overlap (`1...3` is `1` and `.3`).
        var parts: [[Unicode.Scalar]] = []
        var current: [Unicode.Scalar] = []
        var index = 0
        while index < body.count {
            if body[index] == ".", index + 1 < body.count, body[index + 1] == "." {
                parts.append(current)
                current = []
                index += 2
            } else {
                current.append(body[index])
                index += 1
            }
        }
        parts.append(current)
        func integer(_ part: [Unicode.Scalar]) -> Bool {
            var digits = part[...]
            if let first = digits.first, first == "+" || first == "-" { digits = digits.dropFirst() }
            return !digits.isEmpty && digits.allSatisfy(isASCIIDigit)
        }
        func letter(_ part: [Unicode.Scalar]) -> Bool {
            part.count == 1 && part[0].isASCII && ((part[0].value >= 0x41 && part[0].value <= 0x5A) || (part[0].value >= 0x61 && part[0].value <= 0x7A))
        }
        switch parts.count {
        case 2: return (integer(parts[0]) && integer(parts[1])) || (letter(parts[0]) && letter(parts[1]))
        case 3: return ((integer(parts[0]) && integer(parts[1])) || (letter(parts[0]) && letter(parts[1]))) && integer(parts[2])
        default: return false
        }
    }

    /// The words of a `${...}` body: its name, then its operand with the operator (`:-`, `:=`, `:+`, `:?`, `%`, `#`, `/`,
    /// `^`, `,`) skipped and anything but letters, digits, `_`, `-`, `.`, `/` and `=` turned into a space, so
    /// `${X:-delete}` gives `X delete` and `${X:-$(rm -rf /)}` shows `rm -rf /`.
    private static func parameterWords(_ body: [Unicode.Scalar]) -> String {
        var at = body.prefix(while: { isASCIIAlphanumeric($0) || $0 == "_" }).count
        let name = string(body[..<at])
        if at < body.count, body[at] == ":" { at += 1 }
        if at < body.count {
            let op = body[at]
            if "-=+?".unicodeScalars.contains(op) {
                at += 1
            } else if "%#/^,".unicodeScalars.contains(op) {
                at += 1
                if at < body.count, body[at] == op { at += 1 }
            }
        }
        let operand = string(body[at...].map { isAlphanumeric($0) || "_-./=".unicodeScalars.contains($0) ? $0 : " " })
        return " \(name) \(operand) "
    }

    /// Words, split at whitespace and at `;`, `|` and `&`.
    static func words(of text: String) -> [String] {
        splitScalars(text) { $0.properties.isWhitespace || $0 == ";" || $0 == "|" || $0 == "&" }
    }

    /// Words for the destructive rules: split at whitespace and at `;`, `|`, `&`, `<` and `>`, so a redirection glued
    /// to a word (`kubectl delete>/dev/null ns x`) still leaves the verb a word of its own. The history check keeps
    /// [`words(of:)`].
    static func redirectionSplitWords(of text: String) -> [String] {
        splitScalars(text) { $0.properties.isWhitespace || ";|&<>".unicodeScalars.contains($0) }
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
        splitScalars(command, where: { $0 == ";" || $0 == "|" || $0 == "&" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// ICU's `\b` skips combining marks and the daemon's regex engine does not: `\b` is spelled out here as the
    /// daemon's (a boundary between a word scalar and a non-word one, a word being Alphabetic, Mark, Nd, Pc or a
    /// joiner), so both read `kill` after a combining mark the same way.
    static func unicodeBoundaries(_ pattern: String) -> String {
        let word = #"[\p{Alphabetic}\p{M}\p{Nd}\p{Pc}\p{Join_Control}]"#
        return pattern.replacingOccurrences(of: #"\b"#, with: "(?:(?<=\(word))(?!\(word))|(?<!\(word))(?=\(word)))")
    }

    /// Compiled expressions, by pattern: building one costs more than running it, and the rules run it on every view.
    private static let expressions = NSCache<NSString, NSRegularExpression>()

    static func expression(_ pattern: String, caseInsensitive: Bool) -> NSRegularExpression? {
        let key = ((caseInsensitive ? "i:" : "s:") + pattern) as NSString
        if let cached = expressions.object(forKey: key) { return cached }
        guard let compiled = try? NSRegularExpression(pattern: unicodeBoundaries(pattern),
                                                      options: caseInsensitive ? [.caseInsensitive] : []) else { return nil }
        expressions.setObject(compiled, forKey: key)
        return compiled
    }

    static func regex(_ pattern: String, in text: String, caseInsensitive: Bool = true) -> Bool {
        guard let expression = expression(pattern, caseInsensitive: caseInsensitive) else { return false }
        return expression.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }
}
