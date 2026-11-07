//! The fixed list of destructive patterns (PRD SR6): what makes the Mac app ask before it places a staged
//! command in a pane treated as production, and what it labels in every pane. **No label does not mean safe**:
//! nothing here judges a command.
//!
//! The Mac app computes the list for its sheet (`StagingDestructivePatterns` in `StagingHazards.swift`); this
//! is the daemon's port of the same rules, and the shared fixture `tests/fixtures/terminal_staging/hazards.json`
//! pins both to the same answers (its `destructive` field). The daemon itself does not refuse on a match.
//!
//! Every rule runs on the text as written AND on four normalised copies ([`super::text::normalise_for_hazards`]
//! and [`super::text::normalise_for_hazard_words`], each with empty expansions as a space and with them
//! removed); a hit on any view counts, so a wrapped (`bash -c 'rm -rf x'`), quoted (`r''m`), split (`r$()m`),
//! substituted (`kubectl --context $(...) delete ns x`) or brace-expanded (`{rm,-rf,/x}`) form is still seen.
//! Quotes are not parsed, so a pattern inside a quoted string matches too: asking is the cheap side, and an
//! ambiguous case asks. Two rules do read quotes, both to stop asking about ordinary read-only commands:
//! `> file` ignores a `>` inside a quoted string (SQL, `awk` and `jq` programs are full of them) unless the
//! string is the argument of a command wrapper (`bash -c '...'`, `eval`, `ssh host '...'`, `parallel`, ...),
//! which is analysed as live code; and `stop/shutdown` only counts in command position.
//!
//! Vocabulary used below: a *segment* is a view split at `;`, `|` and `&`; its *words* are split at spaces and
//! tabs; a word's *program* is its last path component, lowercased (`/usr/bin/kubectl` is `kubectl`). A
//! program counts anywhere in a segment, so a leading `sudo`, `env`, `command`, `time`, `nohup`, `exec`, a
//! prefix assignment or option never hides it, and global options between it and its verb do not either.
//!
//! Besides the 30 names, a production pane also asks first for four *warnings* that are not names (nothing
//! in them says what the command does): an escape-quoted word (`$'\x72m'`), a brace group glued to a word
//! (`r{m,} -rf x`, `kill -{9..9} 1`), a wildcard in the command word (`/bin/r? -rf x`) and any non-ASCII text
//! (the belt to the scalar scanners' braces: a combining mark can glue to a `,` or a quote), see
//! [`asks_in_production`].

use std::sync::OnceLock;

use regex::Regex;

use super::text::{
    closing_backtick, closing_index, normalise_for_hazard_words, normalise_for_hazard_words_joined,
    normalise_for_hazards, normalise_for_hazards_joined,
};

/// The names, in list order. The first ten are the original list; the rest were added with the
/// staging-leftovers families (the last five with the review fix-ups).
pub const DESTRUCTIVE_NAMES: [&str; 30] = [
    "rm -rf",
    "DROP",
    "TRUNCATE",
    "DELETE FROM without WHERE",
    "migrate:fresh",
    "db:wipe",
    "queue:flush",
    "cache:clear",
    "--force",
    "kill -9",
    "migrate:refresh",
    "migrate:reset",
    "migrate:rollback",
    "kubectl delete",
    "kubectl drain",
    "helm uninstall",
    "terraform destroy",
    "aws delete/terminate",
    "aws s3 rm/rb",
    "dd of=",
    "mkfs",
    "shred",
    "> file",
    "find -delete",
    "xargs/piped rm",
    "queue:clear",
    "horizon:clear",
    "optimize:clear",
    "FLUSHALL/FLUSHDB",
    "stop/shutdown",
];

/// The names of the patterns `text` matches, in list order.
pub fn destructive_patterns(text: &str) -> Vec<&'static str> {
    let views = views_of(text);
    let any = |test: &dyn Fn(&str) -> bool| views.iter().any(|v| test(v));
    let matches = |name: &str| -> bool {
        match name {
            "rm -rf" => any(&has_recursive_forced_remove),
            "DROP" => any(&|v| {
                regex(&DROP, r"(?i)\bdrop\s").is_match(v)
                    || all_words(v).iter().any(|w| program(w) == "dropdb")
            }),
            "TRUNCATE" => any(&|v| regex(&TRUNCATE, r"(?i)\btruncate\b").is_match(v)),
            "DELETE FROM without WHERE" => any(&has_delete_without_where),
            "migrate:fresh" | "db:wipe" | "queue:flush" | "cache:clear" | "migrate:refresh"
            | "migrate:reset" | "migrate:rollback" | "queue:clear" | "horizon:clear"
            | "optimize:clear" => {
                any(&|v| v.to_lowercase().contains(name) || uses_artisan_abbreviation(name, v))
            }
            "--force" => any(&has_force_flag),
            "kill -9" => any(&has_force_kill),
            "kubectl delete" => any(&|v| program_then(v, &["kubectl"], &["delete"])),
            "kubectl drain" => any(&|v| program_then(v, &["kubectl"], &["drain"])),
            "helm uninstall" => {
                any(&|v| program_then(v, &["helm"], &["uninstall", "delete", "del", "un"]))
            }
            "terraform destroy" => any(&has_terraform_destroy),
            "aws delete/terminate" => any(&has_aws_delete),
            "aws s3 rm/rb" => any(&has_aws_s3_remove),
            "dd of=" => any(&|v| {
                segment_words(v).iter().any(|words| {
                    after_program(words, &["dd"]).is_some_and(|rest| {
                        rest.iter().any(|w| w.to_lowercase().starts_with("of="))
                    })
                })
            }),
            "mkfs" => any(&|v| all_words(v).iter().any(|w| program(w).starts_with("mkfs"))),
            "shred" => any(&|v| all_words(v).iter().any(|w| program(w) == "shred")),
            "> file" => {
                // A `>` inside a quoted string is not a redirection: read the views of the text with those masked.
                let masked = mask_quoted_operators(text);
                if masked == text {
                    any(&truncates_a_file)
                } else {
                    views_of(&masked).iter().any(|v| truncates_a_file(v))
                }
            }
            "find -delete" => any(&has_find_delete),
            "xargs/piped rm" => any(&has_xargs_or_piped_rm),
            "FLUSHALL/FLUSHDB" => any(&|v| regex(&FLUSH, r"(?i)\bflush(?:all|db)\b").is_match(v)),
            "stop/shutdown" => any(&has_stop_or_shutdown),
            _ => false,
        }
    };
    DESTRUCTIVE_NAMES
        .iter()
        .copied()
        .filter(|n| matches(n))
        .collect()
}

/// The text as written and its four normalised copies.
fn views_of(text: &str) -> [String; 5] {
    [
        text.to_string(),
        normalise_for_hazards(text),
        normalise_for_hazards_joined(text),
        normalise_for_hazard_words(text),
        normalise_for_hazard_words_joined(text),
    ]
}

/// Does a production pane ask before inserting `text`? On a destructive match, on an escape-quoted word
/// ([`escape_quoted_word`]), on a brace group glued to a word ([`brace_glued_word`]), on a wildcard in a
/// command word ([`wildcard_command_word`]) and on any non-ASCII text ([`contains_non_ascii`]). The Mac app's
/// `StagingHazards.asksFirstInProduction` is the same rule.
pub fn asks_in_production(text: &str) -> bool {
    !destructive_patterns(text).is_empty()
        || escape_quoted_word(text)
        || brace_glued_word(text)
        || wildcard_command_word(text)
        || contains_non_ascii(text)
}

/// Any code point above U+007F. A production pane asks first for text that holds one, whatever it is (an accented
/// letter, a combining mark, a look-alike letter): the Mac app scans scalars, but a rule that reads a combining
/// accent glued to a `,`, a quote or a `;` differently from a shell is the one gap a rule cannot close, so the
/// sheet does. **Cost, taken on purpose:** `echo café` asks too (the drawer already labels non-ASCII text).
pub fn contains_non_ascii(text: &str) -> bool {
    !text.is_ascii()
}

static DROP: OnceLock<Regex> = OnceLock::new();
static ESCAPE_QUOTED: OnceLock<Regex> = OnceLock::new();
static TRUNCATE: OnceLock<Regex> = OnceLock::new();
static KILL: OnceLock<Regex> = OnceLock::new();
static DELETE_FROM: OnceLock<Regex> = OnceLock::new();
static FLUSH: OnceLock<Regex> = OnceLock::new();
static WHERE: OnceLock<Regex> = OnceLock::new();
static SQL_COMMENT: OnceLock<Regex> = OnceLock::new();

fn regex<'a>(cell: &'a OnceLock<Regex>, pattern: &str) -> &'a Regex {
    cell.get_or_init(|| Regex::new(pattern).expect("destructive pattern"))
}

// ── shared text helpers ─────────────────────────────────────────────────────────────────────────────

/// The view split at `;`, `|` and `&`, each segment as its words (split at spaces, tabs, `<` and `>`, so a
/// redirection glued to a word, `kubectl delete>/dev/null ns x`, still leaves the verb a word of its own).
fn segment_words(view: &str) -> Vec<Vec<String>> {
    view.split([';', '|', '&'])
        .map(|segment| split_words(segment, &[' ', '\t', '<', '>']))
        .filter(|words: &Vec<String>| !words.is_empty())
        .collect()
}

/// `text` split at `separators`, with a glued `env -S<command>` or `--split-string=<command>` word as two
/// words (`env -Sreboot` is `env -S reboot`): the option, then the command it runs.
fn split_words(text: &str, separators: &[char]) -> Vec<String> {
    let mut words = Vec::new();
    for word in text.split(separators).filter(|w| !w.is_empty()) {
        let glued = word
            .strip_prefix("--split-string=")
            .map(|rest| ("--split-string", rest))
            .or_else(|| word.strip_prefix("-S").map(|rest| ("-S", rest)));
        match glued {
            Some((option, rest)) if !rest.is_empty() => {
                words.push(option.to_string());
                words.push(rest.to_string());
            }
            _ => words.push(word.to_string()),
        }
    }
    words
}

/// Every word of the view, split at whitespace and at `;`, `|`, `&`, `<` and `>`.
fn all_words(view: &str) -> Vec<String> {
    let mut words = Vec::new();
    for part in view.split(|c: char| c.is_whitespace() || matches!(c, ';' | '|' | '&' | '<' | '>'))
    {
        words.extend(split_words(part, &[]));
    }
    words
}

/// A word's program: its last path component, lowercased.
fn program(word: &str) -> String {
    word.rsplit('/').next().unwrap_or(word).to_lowercase()
}

/// The words after the first word whose program is one of `programs`.
fn after_program<'a>(words: &'a [String], programs: &[&str]) -> Option<&'a [String]> {
    let at = words
        .iter()
        .position(|w| programs.contains(&program(w).as_str()))?;
    Some(&words[at + 1..])
}

/// Is there a segment with one of `programs` followed later by one of `verbs` (lowercased compare)?
fn program_then(view: &str, programs: &[&str], verbs: &[&str]) -> bool {
    segment_words(view).iter().any(|words| {
        after_program(words, programs).is_some_and(|rest| {
            rest.iter()
                .any(|w| verbs.contains(&w.to_lowercase().as_str()))
        })
    })
}

// ── the original ten ────────────────────────────────────────────────────────────────────────────────

/// An `rm` program (any case: macOS volumes are case-insensitive) anywhere whose arguments (up to the next `;`,
/// `&` or `|`) include a recursive flag and a force flag, in any combination or order (`-rf`, `-fr`, `-Rf`,
/// `-r -f`, `--recursive --force`, `--recurs`, `--forc`).
fn has_recursive_forced_remove(view: &str) -> bool {
    segment_words(view).iter().any(|words| {
        words
            .iter()
            .enumerate()
            .filter(|(_, w)| program(w) == "rm")
            .any(|(index, _)| {
                let (mut recursive, mut force) = (false, false);
                for argument in words[index + 1..].iter().filter(|a| a.starts_with('-')) {
                    if argument.starts_with("--") {
                        if argument.chars().count() >= 3 {
                            recursive |= "--recursive".starts_with(argument.as_str());
                            force |= "--force".starts_with(argument.as_str());
                        }
                        continue;
                    }
                    recursive |= argument.contains('r') || argument.contains('R');
                    force |= argument.contains('f');
                }
                recursive && force
            })
    })
}

/// Laravel accepts a shortened command name (`ca:cl`, `q:fl`, `mi:fr`, `db:w`): a word of two letters-only
/// parts, each a non-empty prefix of the matching part of `name`. Over-matching (`c:c`) is the cheap side.
fn uses_artisan_abbreviation(name: &str, text: &str) -> bool {
    let Some((first, second)) = name.split_once(':') else {
        return false;
    };
    text.to_lowercase()
        .split([' ', '\t', ';', '|', '&'])
        .any(|word| {
            let parts: Vec<&str> = word.split(':').collect();
            parts.len() == 2
                && parts
                    .iter()
                    .all(|p| !p.is_empty() && p.chars().all(|c| c.is_ascii_alphabetic()))
                && first.starts_with(parts[0])
                && second.starts_with(parts[1])
        })
}

/// `--force` at a word boundary and not preceded by a word character or `-`, and its shortened `--fo`, `--for`,
/// `--forc` (so `--force-with-lease` matches, `--forceful` and `---force` do not).
fn has_force_flag(view: &str) -> bool {
    let chars: Vec<char> = view.chars().collect();
    let is_word = |c: char| c.is_alphanumeric() || c == '_';
    (0..chars.len()).any(|start| {
        if chars[start..].iter().take(4).collect::<String>() != "--fo" {
            return false;
        }
        // Before it only ASCII counts (the Mac app's lookbehind is `(?<![A-Za-z0-9_-])`): `é--force` matches.
        if start > 0
            && (chars[start - 1].is_ascii_alphanumeric() || matches!(chars[start - 1], '_' | '-'))
        {
            return false;
        }
        let mut end = start + 4;
        for expected in ['r', 'c', 'e'] {
            if chars.get(end) == Some(&expected) {
                end += 1;
            } else {
                break;
            }
        }
        !chars.get(end).is_some_and(|c| is_word(*c))
    })
}

/// A `delete from` (also `delete t from`, `delete ignore|low_priority|quick from`) with no `where` after it in
/// the same statement. A statement ends at `;`, `&`, `|`, the next `delete from`, and, when the `delete` sits
/// inside a quoted string (`psql -c 'DELETE FROM users' -c '... WHERE ...'`), at that string's closing quote.
fn has_delete_without_where(view: &str) -> bool {
    let delete = regex(
        &DELETE_FROM,
        r"(?i)\bdelete\s+(?:(?:ignore|low_priority|quick)\s+)*(?:[\w$.`\x22]+(?:\s*,\s*[\w$.`\x22]+)*\s+)?from\b",
    );
    let where_ = regex(&WHERE, r"(?i)\bwhere\b");
    let comment = regex(&SQL_COMMENT, r"--(?:\s|$)|#");
    let found: Vec<_> = delete.find_iter(view).collect();
    found.iter().enumerate().any(|(index, m)| {
        let quote = open_quote_at(view, m.start());
        let next = found.get(index + 1).map_or(view.len(), |n| n.start());
        let mut escaped = false;
        let stop = view[m.end()..next]
            .char_indices()
            .find(|&(_, c)| {
                let ends = !escaped && (matches!(c, ';' | '&' | '|') || Some(c) == quote);
                escaped = !escaped && c == '\\' && quote != Some('\'');
                ends
            })
            .map_or(next, |(at, _)| m.end() + at);
        let rest = &view[m.end()..stop];
        let rest = comment.find(rest).map_or(rest, |c| &rest[..c.start()]);
        !where_.is_match(rest)
    })
}

/// The quote (`'` or `"`) still open at byte `at` of `view` (a single quote has no escapes, a backslash escapes
/// the next character anywhere else).
fn open_quote_at(view: &str, at: usize) -> Option<char> {
    let (mut quote, mut escaped) = (None, false);
    for (index, c) in view.char_indices() {
        if index >= at {
            break;
        }
        if escaped {
            escaped = false;
        } else if c == '\\' && quote != Some('\'') {
            escaped = true;
        } else if quote == Some(c) {
            quote = None;
        } else if quote.is_none() && matches!(c, '\'' | '"') {
            quote = Some(c);
        }
    }
    quote
}

// ── kill -9 ─────────────────────────────────────────────────────────────────────────────────────────

/// Is `word` (lowercase) signal 9? Numerically, so `09` and `0009` count as they do in a shell.
fn is_kill_signal(word: &str) -> bool {
    matches!(word, "kill" | "sigkill")
        || (!word.is_empty()
            && word.chars().all(|c| c.is_ascii_digit())
            && word.trim_start_matches('0') == "9")
}

/// The original `kill`/`pkill`/`killall` followed by a force signal, and a `kill` program followed anywhere
/// later in the same segment by one (`pkill -f x -9`, `kill -s9 1`, `kill -n9 1`, `kill -09 1`,
/// `kill --signal=KILL 1`). Signal 9 is compared as a number: `-09`, `-s 0009`.
fn has_force_kill(view: &str) -> bool {
    let original = regex(
        &KILL,
        r"(?i)\b(?:kill|pkill|killall)\s+(?:-9\b|-KILL\b|-SIGKILL\b|-[sn]\s+(?:9|KILL|SIGKILL)\b)",
    );
    if original.is_match(view) {
        return true;
    }
    segment_words(view).iter().any(|words| {
        let Some(rest) = after_program(words, &["kill", "pkill", "killall"]) else {
            return false;
        };
        let rest: Vec<String> = rest.iter().map(|w| w.to_lowercase()).collect();
        rest.iter().enumerate().any(|(index, w)| {
            w.strip_prefix("--signal=").is_some_and(is_kill_signal)
                || (!w.starts_with("--")
                    && w.strip_prefix('-').is_some_and(|flag| {
                        is_kill_signal(flag)
                            || flag.strip_prefix(['s', 'n']).is_some_and(is_kill_signal)
                    }))
                || (matches!(w.as_str(), "-s" | "-n" | "--signal")
                    && rest.get(index + 1).is_some_and(|n| is_kill_signal(n)))
        })
    })
}

// ── infrastructure ──────────────────────────────────────────────────────────────────────────────────

/// `terraform`, `tofu`, `terragrunt` or `pulumi` followed later in the segment by `destroy`, `destroy-all`,
/// `-destroy`, `--destroy`, `-replace` or `--replace` (optionally `=value`), or, for `pulumi`, `down` (its alias
/// of `destroy`). `plan -destroy` is read-only but its plan file can be applied unseen, so it asks too. Also
/// (same label) `taint`, `force-unlock`, `workspace … delete`, `state … rm`/`remove`/`push`/`delete` and
/// `stack … rm`/`remove` (pulumi: deletes the stack and its history): each makes the next apply destroy
/// something, or forgets, overwrites or deletes state, or breaks a lock.
fn has_terraform_destroy(view: &str) -> bool {
    const PROGRAMS: [&str; 4] = ["terraform", "tofu", "terragrunt", "pulumi"];
    segment_words(view).iter().any(|words| {
        let Some(at) = words
            .iter()
            .position(|w| PROGRAMS.contains(&program(w).as_str()))
        else {
            return false;
        };
        let pulumi = program(&words[at]) == "pulumi";
        let rest: Vec<String> = words[at + 1..].iter().map(|w| w.to_lowercase()).collect();
        let then = |first: &str, verbs: &[&str]| {
            rest.iter()
                .position(|w| w == first)
                .is_some_and(|at| rest[at + 1..].iter().any(|w| verbs.contains(&w.as_str())))
        };
        then("workspace", &["delete"])
            || then("state", &["rm", "remove", "push", "delete"])
            || then("stack", &["rm", "remove"])
            || rest.iter().any(|w| {
                let flag = w.trim_start_matches('-');
                let name = flag.split('=').next().unwrap_or(flag);
                matches!(
                    w.as_str(),
                    "destroy" | "destroy-all" | "taint" | "force-unlock"
                ) || (pulumi && w == "down")
                    || (w.starts_with('-') && (name == "destroy" || name == "replace"))
            })
    })
}

/// `aws` followed later in the segment by a word that is exactly `delete-…`, `batch-delete-…`, `terminate-…`,
/// `remove-…`, `deregister-…` or `purge-…`, or exactly `schedule-key-deletion` (kms: the key is gone in 7 to 30
/// days) or `stop-instances`, or `update-service` with `--desired-count` 0, `+0` or `-0` (an ECS service scaled to nothing).
fn has_aws_delete(view: &str) -> bool {
    const VERBS: [&str; 6] = [
        "delete-",
        "batch-delete-",
        "terminate-",
        "remove-",
        "deregister-",
        "purge-",
    ];
    segment_words(view).iter().any(|words| {
        after_program(words, &["aws"]).is_some_and(|rest| {
            let rest: Vec<String> = rest.iter().map(|w| w.to_lowercase()).collect();
            let scales_to_zero = rest.contains(&"update-service".to_string())
                && rest.iter().enumerate().any(|(index, w)| {
                    // A shell tool parses `+0` and `-0` as 0 too.
                    let zero = |n: &str| {
                        let n = n.strip_prefix(['+', '-']).unwrap_or(n);
                        !n.is_empty() && n.chars().all(|c| c == '0')
                    };
                    w.strip_prefix("--desired-count=").is_some_and(zero)
                        || (w == "--desired-count" && rest.get(index + 1).is_some_and(|n| zero(n)))
                });
            scales_to_zero
                || rest.iter().any(|w| {
                    w == "schedule-key-deletion"
                        || w == "stop-instances"
                        || VERBS.iter().any(|verb| {
                            w.strip_prefix(verb).is_some_and(|x| {
                                !x.is_empty()
                                    && x.chars().all(|c| {
                                        c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-'
                                    })
                            })
                        })
                })
        })
    })
}

/// `aws` then `s3` then `rm` or `rb`; also `aws s3 sync … --delete` and `aws s3 cp /dev/null s3://…` (which
/// replaces the object with an empty one).
fn has_aws_s3_remove(view: &str) -> bool {
    segment_words(view).iter().any(|words| {
        let Some(rest) = after_program(words, &["aws"]) else {
            return false;
        };
        let rest: Vec<String> = rest.iter().map(|w| w.to_lowercase()).collect();
        let Some(s3) = rest.iter().position(|w| w == "s3") else {
            return false;
        };
        let after = &rest[s3 + 1..];
        after.iter().any(|w| w == "rm" || w == "rb")
            || after
                .iter()
                .position(|w| w == "cp")
                .is_some_and(|cp| after[cp + 1..].iter().any(|w| w == "/dev/null"))
            || after
                .iter()
                .position(|w| w == "sync")
                .is_some_and(|sync| after[sync + 1..].iter().any(|w| w == "--delete"))
    })
}

// ── redirection, find, xargs ────────────────────────────────────────────────────────────────────────

/// A `>` that truncates a file. `>>` (append) and `<>` are not truncation; `>&` followed by a descriptor or `-`
/// is a duplication (`2>&1`, `>&2`); a target of exactly `/dev/null`, `/dev/stderr` or `/dev/stdout` (case
/// matters: `/DEV/NULL` is a file on a case-sensitive volume) is exempt.
/// Anything else, an empty target and `>(…)` included, matches. Quotes and backslashes inside a target are
/// ignored (`> '/dev/null'` is `/dev/null`).
fn truncates_a_file(view: &str) -> bool {
    let c: Vec<char> = view.chars().collect();
    let mut i = 0;
    while i < c.len() {
        if c[i] != '>' {
            i += 1;
            continue;
        }
        if c.get(i + 1) == Some(&'>') {
            while c.get(i) == Some(&'>') {
                i += 1;
            }
            continue;
        }
        let after_less = i > 0 && c[i - 1] == '<';
        i += 1;
        if after_less {
            continue;
        }
        if matches!(c.get(i), Some('|') | Some('!')) {
            i += 1;
        }
        let duplication = c.get(i) == Some(&'&');
        if duplication {
            i += 1;
        }
        while matches!(c.get(i), Some(' ') | Some('\t')) {
            i += 1;
        }
        let mut target = String::new();
        while let Some(&ch) = c.get(i) {
            if ch.is_whitespace()
                || matches!(
                    ch,
                    ';' | '|' | '&' | '<' | '>' | '(' | ')' | '{' | '}' | '`'
                )
            {
                break;
            }
            if !matches!(ch, '\'' | '"' | '\\') {
                target.push(ch);
            }
            i += 1;
        }
        let descriptor = {
            let digits = target.trim_end_matches('-');
            target == "-" || (!digits.is_empty() && digits.chars().all(|d| d.is_ascii_digit()))
        };
        if duplication && descriptor {
            continue;
        }
        if matches!(target.as_str(), "/dev/null" | "/dev/stderr" | "/dev/stdout") {
            continue;
        }
        return true;
    }
    false
}

/// A `find` program followed later anywhere in the text (the `{}` of `-exec rm {} \;` splits segments once
/// normalised) by `-delete`, or by `-exec`/`-execdir`/`-ok`/`-okdir` and later an `rm` program.
fn has_find_delete(view: &str) -> bool {
    let words: Vec<String> = all_words(view).iter().map(|w| w.to_lowercase()).collect();
    let Some(rest) = after_program(&words, &["find"]) else {
        return false;
    };
    rest.iter().any(|w| w == "-delete")
        || rest
            .iter()
            .position(|w| matches!(w.as_str(), "-exec" | "-execdir" | "-ok" | "-okdir"))
            .is_some_and(|exec| rest[exec + 1..].iter().any(|w| program(w) == "rm"))
}

/// An `xargs` or `parallel` program followed later anywhere in the text by an `rm` program (`parallel rm ::: a b`,
/// `parallel 'rm -rf {}' ::: x`), or an `rm` program after a single `|` (a pipe, not `||`) anywhere in the text.
fn has_xargs_or_piped_rm(view: &str) -> bool {
    let words = all_words(view);
    if after_program(&words, &["xargs", "parallel"])
        .is_some_and(|rest| rest.iter().any(|w| program(w) == "rm"))
    {
        return true;
    }
    let chars: Vec<char> = view.chars().collect();
    let pipe = (0..chars.len()).find(|&i| {
        chars[i] == '|' && (i == 0 || chars[i - 1] != '|') && chars.get(i + 1) != Some(&'|')
    });
    pipe.is_some_and(|at| {
        let rest: String = chars[at + 1..].iter().collect();
        all_words(&rest).iter().any(|w| program(w) == "rm")
    })
}

// ── shutdown ────────────────────────────────────────────────────────────────────────────────────────

/// Programs whose quoted argument is itself a command (`bash -c '...'`, `eval '...'`, `ssh host '...'`,
/// `parallel '...'`, `source <(echo '...')`, `echo '...' | at now`): that argument is analysed as live code, not
/// as a string. A lone `.` (the other name of `source`) counts too, but only in command position (`find . -name`
/// is not a wrapper): [`is_dot_wrapper`].
const QUOTE_WRAPPERS: &[&str] = &[
    "sh", "bash", "zsh", "dash", "ksh", "ash", "csh", "tcsh", "fish", "mksh", "rbash", "yash",
    "pwsh", "eval", "ssh", "mosh", "parallel", "watch", "su", "script", "flock", "runuser", "gosu",
    "su-exec", "pdsh", "ansible", "source", "at", "batch",
];

/// Wrappers that count only in command position: `at`, `batch` and `source` are also ordinary words
/// (`grep at 'a > b' file` is a search, not a job).
const COMMAND_POSITION_WRAPPERS: &[&str] = &["source", "at", "batch"];

/// Is `name` (a program) a [`QUOTE_WRAPPERS`] entry here? `leading`: the word is in command position.
fn is_quote_wrapper(name: &str, leading: bool) -> bool {
    QUOTE_WRAPPERS.contains(&name) && (leading || !COMMAND_POSITION_WRAPPERS.contains(&name))
}

/// Programs that run what follows them as a command, so a later word in the same segment may be the command
/// (`bash -c 'reboot'`, `ssh host reboot`, `xargs systemctl stop`, `find -exec shutdown`): the wrappers above
/// and these.
const MORE_COMMAND_WRAPPERS: &[&str] = &["xargs", "nsenter", "chroot", "find"];

/// Programs that run another program after their own words, so what follows them is still in command position.
const PREFIX_PROGRAMS: &[&str] = &[
    "then",
    "do",
    "else",
    "elif",
    "if",
    "while",
    "until",
    "!",
    "-",
    "command",
    "builtin",
    "eval",
    "exec",
    "time",
    "sudo",
    "doas",
    "noglob",
    "nocorrect",
    "nohup",
    "nice",
    "ionice",
    "setsid",
    "env",
    "timeout",
    "pkexec",
    "busybox",
    "stdbuf",
    "systemd-run",
    "strace",
    "ltrace",
    "taskset",
    "chrt",
    "numactl",
    "unbuffer",
    "caffeinate",
    "unshare",
    "setpriv",
    "coproc",
];

/// Options of the prefix programs that take a value (`sudo -u deploy`, `timeout -s KILL 5`, `ionice -c 2`). A long
/// option without `=` is taken to have one too (`sudo --user deploy reboot`): that only ever asks more.
/// (`exec -a name`, `strace -o file`, `sudo -D dir`, `env -S 'cmd'` take one too; compared lowercased.)
const OPTIONS_WITH_VALUE: &[&str] = &[
    "-u", "-g", "-h", "-p", "-r", "-t", "-c", "-s", "-k", "-n", "-a", "-o", "-w", "-d",
];

/// A `name=value` prefix assignment.
fn is_assignment(word: &str) -> bool {
    word.split_once('=').is_some_and(|(name, _)| {
        !name.is_empty()
            && !name.starts_with(|c: char| c.is_ascii_digit())
            && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
    })
}

/// A number, duration or hex mask (`5`, `0.5`, `5s`, `10m`, `0x3`): the operand of `nice`, `timeout`, `taskset`.
fn is_duration(word: &str) -> bool {
    if let Some(hex) = word.strip_prefix("0x") {
        return !hex.is_empty() && hex.chars().all(|c| c.is_ascii_hexdigit());
    }
    let number = word.strip_suffix(['s', 'm', 'h', 'd']).unwrap_or(word);
    !number.is_empty()
        && number.chars().any(|c| c.is_ascii_digit())
        && number.chars().all(|c| c.is_ascii_digit() || c == '.')
}

/// While reading the words before a segment's command: does `word` leave the next word in command position
/// (a prefix word), and does it take a value of its own (so the word after it is one too)? `previous` is the
/// program of the word before it: `-p` is a flag of `time` and `command`, not an option with a value.
fn leading_step(word: &str, after_option: bool, previous: &str) -> (bool, bool) {
    let prefix = after_option
        || is_assignment(word)
        || PREFIX_PROGRAMS.contains(&program(word).as_str())
        || word.starts_with('-')
        || is_duration(word);
    let takes_value = word.starts_with('-')
        && ((OPTIONS_WITH_VALUE.contains(&word.to_lowercase().as_str())
            && !(word == "-p" && matches!(previous, "time" | "command" | "builtin")))
            || (word.starts_with("--") && !word.contains('=')));
    (prefix, takes_value)
}

/// The indexes of the words of one segment that are in command position: the first word, then each word
/// after only prefix words (an assignment, a prefix program, an option, an option's value, a duration), and,
/// once a command wrapper or a substitution placeholder (`_`: its output may be the command) has been seen,
/// every later word.
fn command_positions(words: &[String]) -> Vec<usize> {
    let (mut positions, mut leading, mut wrapped, mut after_option) = (vec![], true, false, false);
    for (index, word) in words.iter().enumerate() {
        if leading || wrapped {
            positions.push(index);
        }
        let name = program(word);
        if is_quote_wrapper(&name, leading)
            || MORE_COMMAND_WRAPPERS.contains(&name.as_str())
            || word == "_"
            || (leading && is_dot_wrapper(word))
            || (matches!(name.as_str(), "kubectl" | "docker" | "podman")
                && words[index + 1..]
                    .iter()
                    .any(|w| matches!(w.to_lowercase().as_str(), "exec" | "run")))
        {
            wrapped = true;
        }
        if leading {
            let previous = index
                .checked_sub(1)
                .map_or(String::new(), |p| program(&words[p]));
            (leading, after_option) = leading_step(word, after_option, &previous);
        }
    }
    positions
}

/// The segments of the view (as [`segment_words`]), each with whether it feeds a shell: it is piped (a single `|`,
/// or `|&`; also a `(...)` or `{ ...; }` group, which the views turn into `;`) into a segment whose command is a
/// shell or a command wrapper ([`feeds_a_shell`]: `echo reboot | sh`, `printf reboot | ssh h`). What such a
/// segment holds is run as code, so every word of it is in command position.
fn piped_segments(view: &str) -> Vec<(Vec<String>, bool)> {
    let chars: Vec<char> = view.chars().collect();
    // Each raw segment, and whether a single pipe ended it.
    let mut raw: Vec<(String, bool)> = Vec::new();
    let mut current = String::new();
    for (i, &c) in chars.iter().enumerate() {
        if !matches!(c, ';' | '|' | '&') {
            current.push(c);
            continue;
        }
        // The `&` of `|&` belongs to the pipe.
        if c == '&' && i > 0 && chars[i - 1] == '|' {
            continue;
        }
        let single_pipe =
            c == '|' && chars.get(i + 1) != Some(&'|') && (i == 0 || chars[i - 1] != '|');
        raw.push((std::mem::take(&mut current), single_pipe));
    }
    raw.push((current, false));
    let mut segments: Vec<Vec<String>> = Vec::new();
    let mut piped_into: Vec<bool> = Vec::new();
    // A pipe that follows an empty segment (`(echo reboot) | sh` is `;echo reboot; | sh`) pipes every earlier segment.
    for (text, pipes) in raw {
        let words = split_words(&text, &[' ', '\t', '<', '>']);
        if words.is_empty() {
            if pipes {
                piped_into.iter_mut().for_each(|piped| *piped = true);
            }
            continue;
        }
        segments.push(words);
        piped_into.push(pipes);
    }
    (0..segments.len())
        .map(|index| {
            let fed = piped_into[index]
                && segments
                    .get(index + 1)
                    .is_some_and(|next| feeds_a_shell(next));
            (segments[index].clone(), fed)
        })
        .collect()
}

/// Is the command of this segment (after its prefix words: `sudo`, `env`, options, assignments) a shell or a
/// command wrapper ([`QUOTE_WRAPPERS`], a lone `.`), or a `$` or backtick word or substitution placeholder that
/// may be one?
fn feeds_a_shell(words: &[String]) -> bool {
    let (mut leading, mut after_option) = (true, false);
    for (index, word) in words.iter().enumerate() {
        if !leading {
            return false;
        }
        if is_quote_wrapper(&program(word), true)
            || is_dot_wrapper(word)
            || word == "_"
            || word.contains(['$', '`'])
        {
            return true;
        }
        let previous = index
            .checked_sub(1)
            .map_or(String::new(), |p| program(&words[p]));
        (leading, after_option) = leading_step(word, after_option, &previous);
    }
    false
}

/// The verbs of `systemctl`, `loginctl` and `machinectl` that take the machine (or a guest) down or out of service.
const POWER_VERBS: &[&str] = &[
    "reboot",
    "poweroff",
    "halt",
    "kexec",
    "rescue",
    "emergency",
    "suspend",
    "hibernate",
];

/// A `shutdown`, `reboot`, `halt` or `poweroff` program, `systemctl` followed later in the segment by `stop`,
/// `disable`, `mask` or a power verb ([`POWER_VERBS`]), `loginctl` or `machinectl` followed by a power verb, or
/// `service` followed later by `stop`, each only in command position
/// ([`command_positions`]): `last reboot | head` and `grep -i shutdown /var/log/syslog` merely mention one.
fn has_stop_or_shutdown(view: &str) -> bool {
    piped_segments(view).iter().any(|(words, fed_shell)| {
        let positions: Vec<usize> = if *fed_shell {
            (0..words.len()).collect()
        } else {
            command_positions(words)
        };
        positions.iter().any(|&at| {
            let later = |verbs: &[&str]| {
                words[at + 1..]
                    .iter()
                    .any(|w| verbs.contains(&w.to_lowercase().as_str()))
            };
            match program(&words[at]).as_str() {
                "shutdown" | "reboot" | "halt" | "poweroff" => true,
                "systemctl" => later(&["stop", "disable", "mask"]) || later(POWER_VERBS),
                "loginctl" | "machinectl" => later(POWER_VERBS),
                "service" => later(&["stop"]),
                _ => false,
            }
        })
    })
}

// ── quoted `>`, escape-quoted words, glued brace groups ─────────────────────────────────────────────

/// `text` with the operators that a quoted string cannot use replaced by `_`: a `>` (not a redirection),
/// `{` and `}` (not a brace group) inside `'...'`, `"..."` or `$'...'`, and a `>` inside an arithmetic expansion
/// (`$(( 3 > 2 ))`, [`arithmetic_end`]). Things stay live: the quoted
/// argument of a command wrapper (a quoted string after a [`QUOTE_WRAPPERS`] word in the same segment, the word
/// read as a shell reads it: `b'a'sh -c 'echo x > f'`, `\bash`, and any command word holding a `$` expansion or
/// a backtick, which may be a shell: `$SHELL -c '...'`), analysed recursively with its own quotes; a
/// double-quoted string that holds a `$(...)` or a backtick (its text is scanned as live command text, in which a `'` is a letter, because a
/// substitution can hold a `case` pattern or a quote that no cheap scan follows: **cost, taken on purpose:**
/// `echo "x > y $(date)"` asks); everything in a string whose closing quote is missing; and, when
/// a command wrapper or a `$` command word is fed by a pipe (`echo 'echo x > f' | sh`, `| ssh h`), everything.
/// The Mac app's `StagingHazards.maskingQuotedOperators` is the same scan.
///
/// **Accepted trade-off of ignoring a quoted `>`:** `awk 'BEGIN{print 1 > "/etc/x"}'`, a `perl -e` or an
/// `osascript` program that writes a file is not seen (python, ruby and node never were).
fn mask_quoted_operators(text: &str) -> String {
    let (masked, scan) = scan_quotes(text);
    if scan.fed_shell {
        text.to_string()
    } else {
        masked
    }
}

/// Does a command word (the first word of a segment, subshell, `$(...)` or `{ ...; }` after the prefix words: `sudo`,
/// `env`, options and assignments) hold a wildcard (`?`, `*`, `[`), except the `[` and `[[` of a test? A shell expands
/// `/bin/r? -rf /x` into `/bin/rm -rf /x`, which no text rule can follow, so a production pane asks. A wildcard
/// in an argument or inside a quoted program does not count; the word is read as a shell reads it, so a quoted
/// wildcard counts (asking is the cheap side).
pub fn wildcard_command_word(text: &str) -> bool {
    scan_quotes(text).1.wildcard_command
}

/// What the quote scan found besides the masked text.
#[derive(Default)]
struct Scan {
    /// A command wrapper or a `$` command word is fed by a pipe: everything is live.
    fed_shell: bool,
    /// A command word holds a wildcard ([`wildcard_command_word`]).
    wildcard_command: bool,
    /// How many `case` statements are open: a `)` inside one ends a pattern, and a command follows it.
    cases: usize,
}

fn scan_quotes(text: &str) -> (String, Scan) {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut scan = Scan::default();
    mask_into(&chars, &mut out, &mut scan, false);
    (out, scan)
}

/// A lone `.` is `source`: it runs its file, which may be `<(echo '...')` or `/dev/stdin`.
fn is_dot_wrapper(word: &str) -> bool {
    word == "."
}

/// Programs that run a command given after their own words (and, for [`runner_skip`], a first argument of their
/// own): what follows is in command position, so a wildcard there is a program name
/// (`xargs /bin/r? -rf`, `ssh h /bin/r? -rf /x`, `find . -exec /bin/r? -rf {} \;`).
const COMMAND_RUNNERS: &[&str] = &[
    "xargs", "nsenter", "chroot", "ssh", "mosh", "parallel", "watch", "flock", "runuser", "gosu",
    "su-exec", "pdsh",
];

/// The words a runner takes before its command: a host (`ssh HOST cmd`), a root (`chroot DIR cmd`), a lock file,
/// a user.
fn runner_skip(name: &str) -> u8 {
    u8::from(matches!(
        name,
        "ssh" | "mosh" | "pdsh" | "chroot" | "flock" | "gosu" | "su-exec"
    ))
}

/// [`leading_step`] for the words after a runner: `xargs -I {} cmd`, `-L 1` and `-E eof` take a value too.
fn runner_step(word: &str, after_option: bool, previous: &str) -> (bool, bool) {
    let (prefix, takes_value) = leading_step(word, after_option, previous);
    (prefix, takes_value || matches!(word, "-I" | "-L" | "-E"))
}

/// What the mask scan knows about the segment it is in.
#[derive(Default, Clone)]
struct MaskSegment {
    /// The current word as a shell reads it: quotes and backslashes dropped, quoted text kept.
    word: String,
    wrapper_seen: bool,
    leading: bool,
    after_option: bool,
    /// A `xargs`-like word has been seen: a `$` word after it may be the command it runs.
    runs_others: bool,
    piped: bool,
    /// After a command runner ([`COMMAND_RUNNERS`], `find -exec`): the words so far are options, so the next may be
    /// the command; read like `leading`, and a wildcard in one counts.
    runner_leading: bool,
    runner_after_option: bool,
    runner_skip: u8,
    /// A `find` is in command position in this segment: `-exec` and friends start a command.
    in_find: bool,
    /// The program of the previous word of the segment.
    previous: String,
}

impl MaskSegment {
    fn new(piped: bool) -> Self {
        MaskSegment {
            leading: true,
            piped,
            ..Default::default()
        }
    }

    fn end_word(&mut self, scan: &mut Scan) {
        if self.word.is_empty() {
            return;
        }
        let name = program(&self.word);
        let was_leading = self.leading;
        let was_runner_leading = self.runner_leading;
        // A wildcard in any leading word (the command, a prefix program's option or value: `time -p /bin/r?`) or in a
        // runner's command words is a program name no text rule can follow. `[`, `[[` and assignments are not.
        if (was_leading || was_runner_leading)
            && self.word.contains(['?', '*', '['])
            && !matches!(self.word.as_str(), "[" | "[[")
            && !is_assignment(&self.word)
        {
            scan.wildcard_command = true;
        }
        if was_leading && self.word == "case" {
            scan.cases += 1;
        } else if was_leading && self.word == "esac" {
            scan.cases = scan.cases.saturating_sub(1);
        }
        if was_runner_leading {
            let (prefix, takes_value) =
                runner_step(&self.word, self.runner_after_option, &self.previous);
            self.runner_after_option = takes_value;
            if !prefix {
                if self.runner_skip > 0 {
                    self.runner_skip -= 1;
                } else {
                    self.runner_leading = false;
                }
            }
        }
        if self.in_find && matches!(self.word.as_str(), "-exec" | "-execdir" | "-ok" | "-okdir") {
            (
                self.runner_leading,
                self.runner_after_option,
                self.runner_skip,
            ) = (true, false, 0);
        }
        if was_leading || was_runner_leading {
            if COMMAND_RUNNERS.contains(&name.as_str()) {
                (
                    self.runner_leading,
                    self.runner_after_option,
                    self.runner_skip,
                ) = (true, false, runner_skip(&name));
            }
            self.in_find |= name == "find";
        }
        let wrapper =
            is_quote_wrapper(&name, self.leading) || (self.leading && is_dot_wrapper(&self.word));
        if wrapper {
            self.wrapper_seen = true;
        }
        // `env -S 'cmd'` runs its string as a command line.
        if self.leading && (self.word.starts_with("-S") || self.word.starts_with("--split-string"))
        {
            self.wrapper_seen = true;
        }
        // A variable or substitution where the command goes (`$SHELL -c '...'`, `` `which bash` -c '...' ``) may
        // be a shell.
        let dynamic_command = (self.leading || self.runs_others) && self.word.contains(['$', '`']);
        if dynamic_command {
            self.wrapper_seen = true;
        }
        if self.piped && (wrapper || dynamic_command) {
            scan.fed_shell = true;
        }
        if MORE_COMMAND_WRAPPERS.contains(&name.as_str())
            || matches!(name.as_str(), "kubectl" | "docker" | "podman")
        {
            self.runs_others = true;
        }
        if self.leading {
            (self.leading, self.after_option) =
                leading_step(&self.word, self.after_option, &self.previous);
        }
        // A group (`{ cmd; }`, `function f { cmd; }`) starts with a command.
        if self.word == "{" {
            self.leading = true;
        }
        self.previous = name;
        self.word.clear();
    }
}

/// Scans `chars` as live command text. With `quoted_text` they are the inside of a double-quoted string that holds a
/// substitution: a `'` in it is a letter (not a quote), and its first word is an argument, not the command (so the
/// `$` of `"$(...)"` is not a command word that may be a shell); a `$(` starts a command as it does anywhere.
fn mask_into(chars: &[char], out: &mut String, scan: &mut Scan, quoted_text: bool) {
    let masked = |c: char| if matches!(c, '>' | '{' | '}') { '_' } else { c };
    let (mut segment, mut i) = (MaskSegment::new(false), 0);
    segment.leading = !quoted_text;
    // Inside a backtick pair: the segment outside it, and whether the next word after the pair is in command
    // position (an assignment's value or an option's value: `` x=`date` /bin/r? ``).
    let mut backtick: Option<(MaskSegment, bool)> = None;
    while i < chars.len() {
        let c = chars[i];
        if c == '$' {
            if let Some(end) = arithmetic_end(chars, i) {
                for &n in &chars[i..end] {
                    out.push(if n == '>' { '_' } else { n });
                    segment.word.push(n);
                }
                i = end;
                continue;
            }
        }
        match c {
            '\\' => {
                out.push(c);
                if let Some(&next) = chars.get(i + 1) {
                    out.push(next);
                    segment.word.push(next);
                }
                i += 2;
            }
            '\'' if quoted_text => {
                segment.word.push(c);
                out.push(c);
                i += 1;
            }
            '\'' | '"' => {
                let ansi = c == '\'' && i > 0 && chars[i - 1] == '$';
                let Some(end) = quote_end(chars, i, ansi) else {
                    out.extend(&chars[i..]);
                    return;
                };
                let content = &chars[i + 1..end];
                // `env -S'cmd'`: the string glued to the option runs as a command line.
                if segment.leading
                    && (segment.word.starts_with("-S")
                        || segment.word.starts_with("--split-string"))
                {
                    segment.wrapper_seen = true;
                }
                out.push(c);
                if segment.wrapper_seen {
                    mask_into(content, out, scan, false);
                } else if c == '"' && holds_substitution(content) {
                    // Live text, in which a `'` is a letter: `"it's $(echo x > f) it's"` runs the substitution.
                    mask_into(content, out, scan, true);
                } else if c == '"' {
                    mask_double_quoted(content, out);
                } else {
                    out.extend(content.iter().map(|&n| masked(n)));
                }
                out.push(c);
                // A string analysed as live code is not a word of this segment (`ssh h 'ls /var/log/*'`).
                if !segment.wrapper_seen {
                    segment.word.extend(content);
                }
                i = end + 1;
            }
            '`' if backtick.is_some() => {
                segment.end_word(scan);
                if let Some((outer, leading_after)) = backtick.take() {
                    segment = outer;
                    (segment.leading, segment.after_option) = (leading_after, false);
                }
                out.push(c);
                i += 1;
            }
            // A backtick pair holds a command of its own.
            '`' if closing_backtick(chars, i).is_some() => {
                let (was_leading, was_value) = (segment.leading, segment.after_option);
                let command_position = was_leading || segment.runs_others;
                let glued_assignment = is_assignment(&segment.word);
                segment.end_word(scan);
                // A substitution where the command goes may be a shell: `` `which bash` -c '...' ``.
                if command_position {
                    segment.wrapper_seen = true;
                    if segment.piped {
                        scan.fed_shell = true;
                    }
                }
                backtick = Some((
                    segment.clone(),
                    was_leading && (was_value || glued_assignment),
                ));
                (segment.leading, segment.after_option) = (true, false);
                out.push(c);
                i += 1;
            }
            // The `&` of `|&` belongs to the pipe: the segment it ends is still fed by it.
            '&' if i > 0 && chars[i - 1] == '|' => {
                segment.end_word(scan);
                out.push(c);
                i += 1;
            }
            ';' | '|' | '&' | '\n' => {
                segment.end_word(scan);
                let single_pipe =
                    c == '|' && chars.get(i + 1) != Some(&'|') && (i == 0 || chars[i - 1] != '|');
                segment = MaskSegment::new(single_pipe);
                out.push(c);
                i += 1;
            }
            c if c.is_whitespace() || matches!(c, '(' | ')') => {
                segment.end_word(scan);
                // A subshell, `$(`, `<(` or `((` starts a command of its own, and so does what follows the `)` of a
                // `case` pattern.
                if c == '(' || (c == ')' && scan.cases > 0) {
                    (segment.leading, segment.after_option) = (true, false);
                }
                out.push(c);
                i += 1;
            }
            c => {
                segment.word.push(c);
                out.push(c);
                i += 1;
            }
        }
    }
    segment.end_word(scan);
}

/// Does the text inside a double-quoted string hold a `$(` or a backtick?
fn holds_substitution(content: &[char]) -> bool {
    content.contains(&'`') || content.windows(2).any(|w| w == ['$', '('])
}

/// The inside of a double-quoted string that holds no substitution: every `>`, `{` and `}` masked.
fn mask_double_quoted(content: &[char], out: &mut String) {
    let mut i = 0;
    while i < content.len() {
        let c = content[i];
        if c == '\\' {
            out.push(c);
            if let Some(&next) = content.get(i + 1) {
                out.push(if matches!(next, '>' | '{' | '}') {
                    '_'
                } else {
                    next
                });
            }
            i += 2;
            continue;
        }
        out.push(if matches!(c, '>' | '{' | '}') { '_' } else { c });
        i += 1;
    }
}

/// The index just past the `))` of the arithmetic expansion starting at `chars[start]` (`$((`), when its body is
/// plain arithmetic: letters, digits, spaces and the operator characters, no parenthesis, quote, backtick,
/// backslash or `;`. A `>` in it is a comparison, not a redirection (`echo $(( 3 > 2 ))`); a body with anything
/// else (`$(( $(echo x > f) ))`, `$((echo x > f) )`) is read as the command it may be.
fn arithmetic_end(chars: &[char], start: usize) -> Option<usize> {
    if chars.get(start + 1) != Some(&'(') || chars.get(start + 2) != Some(&'(') {
        return None;
    }
    let close = closing_index(chars, start + 1, '(', ')')?;
    if close < start + 5 || chars[close - 1] != ')' {
        return None;
    }
    let body = &chars[start + 3..close - 1];
    let plain = body
        .iter()
        .all(|&c| c.is_ascii_alphanumeric() || " \t_$+-*/%<>=!^~?:,.#&|".contains(c));
    plain.then_some(close + 1)
}

/// Index of the quote that closes the one at `chars[start]`: a single quote has no escapes (but `$'...'` does),
/// a double quote honours backslashes and skips over `$(...)` and backtick substitutions. `None` if unterminated.
fn quote_end(chars: &[char], start: usize, ansi: bool) -> Option<usize> {
    let quote = chars[start];
    let mut i = start + 1;
    while i < chars.len() {
        let c = chars[i];
        if c == quote {
            return Some(i);
        }
        if c == '\\' && (quote == '"' || ansi) {
            i += 2;
            continue;
        }
        if quote == '"' {
            let skip = match (c, chars.get(i + 1)) {
                ('$', Some('(')) => closing_index(chars, i + 1, '(', ')'),
                ('`', _) => closing_backtick(chars, i),
                _ => None,
            };
            if let Some(close) = skip {
                i = close + 1;
                continue;
            }
        }
        i += 1;
    }
    None
}

/// `$'...'` with a backslash inside: the shell turns `\x72` into `r`, which no text rule can follow.
pub fn escape_quoted_word(text: &str) -> bool {
    regex(&ESCAPE_QUOTED, r"\$'[^']*\\").is_match(text)
}

/// An unquoted, unescaped brace expansion (`{a,b}` or `{1..3}`, `{x..z}`: a body with no whitespace and a
/// comma or a sequence) glued to other text: the char before the `{` or after the `}` is not whitespace and not
/// `;`, `|`, `&`, `<`, `>`, `(` or `)`. A shell expands it into words no rule can follow (`r{m,} -rf /x` is
/// `rm -rf /x`), so a production pane asks. A group alone (`{rm,-rf,/x}`, `ls {a,b}`) is read by the
/// normalised views instead, and `${...}` is a parameter expansion. **Cost, taken on purpose:** an ordinary
/// glued group such as `cp file{,.bak}` or `ls file{1,2}.txt` asks too. Quoted braces (`jq '{a,b}'`,
/// `--query 'Items[].{Id:Id}'`) do not count, except in the quoted argument of a command wrapper
/// ([`mask_quoted_operators`]).
pub fn brace_glued_word(text: &str) -> bool {
    if !text.contains('{') {
        return false;
    }
    let chars: Vec<char> = mask_quoted_operators(text).chars().collect();
    let glue = |c: Option<&char>| {
        c.is_some_and(|c| {
            !c.is_whitespace() && !matches!(c, ';' | '|' | '&' | '<' | '>' | '(' | ')')
        })
    };
    let mut i = 0;
    while i < chars.len() {
        match chars[i] {
            '\\' => i += 1,
            '{' if i == 0 || chars[i - 1] != '$' => {
                if let Some(close) = matching_brace(&chars, i) {
                    let body = &chars[i + 1..close];
                    let before = i.checked_sub(1).and_then(|b| chars.get(b));
                    if is_brace_expansion(body) && (glue(before) || glue(chars.get(close + 1))) {
                        return true;
                    }
                }
            }
            _ => {}
        }
        i += 1;
    }
    false
}

/// The index of the `}` that closes the `{` at `chars[start]` (nested pairs counted, backslashes skipped).
fn matching_brace(chars: &[char], start: usize) -> Option<usize> {
    let (mut depth, mut i) = (0usize, start);
    while i < chars.len() {
        match chars[i] {
            '\\' => i += 1,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    return Some(i);
                }
            }
            _ => {}
        }
        i += 1;
    }
    None
}

/// Would a shell expand a group with this body: no whitespace, and a comma or a sequence (`1..3`, `-2..2`,
/// `a..z`, with an optional `..step`)?
fn is_brace_expansion(body: &[char]) -> bool {
    if body.iter().any(|c| c.is_whitespace()) {
        return false;
    }
    if body.contains(&',') {
        return true;
    }
    let text: String = body.iter().collect();
    let parts: Vec<&str> = text.split("..").collect();
    let integer = |p: &str| {
        let digits = p.strip_prefix(['+', '-']).unwrap_or(p);
        !digits.is_empty() && digits.chars().all(|c| c.is_ascii_digit())
    };
    let letter = |p: &str| p.len() == 1 && p.chars().all(|c| c.is_ascii_alphabetic());
    match parts.as_slice() {
        [a, b] => (integer(a) && integer(b)) || (letter(a) && letter(b)),
        [a, b, step] => ((integer(a) && integer(b)) || (letter(a) && letter(b))) && integer(step),
        _ => false,
    }
}
