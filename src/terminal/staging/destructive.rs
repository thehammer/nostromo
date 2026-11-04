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
//! ambiguous case asks.
//!
//! Vocabulary used below: a *segment* is a view split at `;`, `|` and `&`; its *words* are split at spaces and
//! tabs; a word's *program* is its last path component, lowercased (`/usr/bin/kubectl` is `kubectl`). A
//! program counts anywhere in a segment, so a leading `sudo`, `env`, `command`, `time`, `nohup`, `exec`, a
//! prefix assignment or option never hides it, and global options between it and its verb do not either.

use std::sync::OnceLock;

use regex::Regex;

use super::text::{
    normalise_for_hazard_words, normalise_for_hazard_words_joined, normalise_for_hazards,
    normalise_for_hazards_joined,
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
    let views = [
        text.to_string(),
        normalise_for_hazards(text),
        normalise_for_hazards_joined(text),
        normalise_for_hazard_words(text),
        normalise_for_hazard_words_joined(text),
    ];
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
            "> file" => any(&truncates_a_file),
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

static DROP: OnceLock<Regex> = OnceLock::new();
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
        .map(|segment| {
            segment
                .split([' ', '\t', '<', '>'])
                .filter(|w| !w.is_empty())
                .map(str::to_string)
                .collect::<Vec<_>>()
        })
        .filter(|words: &Vec<String>| !words.is_empty())
        .collect()
}

/// Every word of the view, split at whitespace and at `;`, `|`, `&`, `<` and `>`.
fn all_words(view: &str) -> Vec<String> {
    view.split(|c: char| c.is_whitespace() || matches!(c, ';' | '|' | '&' | '<' | '>'))
        .filter(|w| !w.is_empty())
        .map(str::to_string)
        .collect()
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
                            || flag
                                .strip_prefix(['s', 'n'])
                                .is_some_and(|signal| is_kill_signal(signal))
                    }))
                || (matches!(w.as_str(), "-s" | "-n" | "--signal")
                    && rest.get(index + 1).is_some_and(|n| is_kill_signal(n)))
        })
    })
}

// ── infrastructure ──────────────────────────────────────────────────────────────────────────────────

/// `terraform`, `tofu`, `terragrunt` or `pulumi` followed later in the segment by `destroy`, `destroy-all`,
/// `-destroy`, `--destroy`, `-replace` or `--replace` (optionally `=value`). `plan -destroy` is read-only but
/// its plan file can be applied unseen, so it asks too. Also (same label) `taint`, `force-unlock`,
/// `workspace … delete` and `state … rm`/`remove`/`push`: each makes the next apply destroy something, or
/// forgets, overwrites or deletes state, or breaks a lock.
fn has_terraform_destroy(view: &str) -> bool {
    segment_words(view).iter().any(|words| {
        after_program(words, &["terraform", "tofu", "terragrunt", "pulumi"]).is_some_and(|rest| {
            let rest: Vec<String> = rest.iter().map(|w| w.to_lowercase()).collect();
            let then = |first: &str, verbs: &[&str]| {
                rest.iter()
                    .position(|w| w == first)
                    .is_some_and(|at| rest[at + 1..].iter().any(|w| verbs.contains(&w.as_str())))
            };
            then("workspace", &["delete"])
                || then("state", &["rm", "remove", "push"])
                || rest.iter().any(|w| {
                    let flag = w.trim_start_matches('-');
                    let name = flag.split('=').next().unwrap_or(flag);
                    matches!(
                        w.as_str(),
                        "destroy" | "destroy-all" | "taint" | "force-unlock"
                    )
                        || (w.starts_with('-') && (name == "destroy" || name == "replace"))
                })
        })
    })
}

/// `aws` followed later in the segment by a word that is exactly `delete-…`, `batch-delete-…`, `terminate-…`,
/// `remove-…`, `deregister-…` or `purge-…`, or exactly `schedule-key-deletion` (kms: the key is gone in 7 to 30
/// days) or `stop-instances`, or `update-service` with `--desired-count` 0 (an ECS service scaled to nothing).
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
                    let zero = |n: &str| !n.is_empty() && n.chars().all(|c| c == '0');
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

/// A `shutdown`, `reboot`, `halt` or `poweroff` program anywhere, `systemctl` followed later in the segment by
/// `stop`, `disable` or `mask`, or `service` followed later by `stop`.
fn has_stop_or_shutdown(view: &str) -> bool {
    all_words(view)
        .iter()
        .any(|w| matches!(program(w).as_str(), "shutdown" | "reboot" | "halt" | "poweroff"))
        || program_then(view, &["systemctl"], &["stop", "disable", "mask"])
        || program_then(view, &["service"], &["stop"])
}
