//! The "inert mention" exemption: a command that only *mentions* a production
//! shell marker, as data.
//!
//! `git commit -m "fix ecs_connect"`, `grep -rn ecs_connect docs`, `echo
//! "tmux send-keys is how the guard works"` and a here-doc written to `notes.md`
//! are not remote shells, and the text scans would block them. This is the one
//! place that says when a command's text is only data.
//!
//! The exemption has been a source of holes, so it is **strict**: a false
//! positive costs a rewrite of the command; a hole costs a production shell.
//! A command is inert only when
//!
//! 1. **every** simple command the tokenizer found (in every pipeline, list,
//!    group and subshell) is a known program, called by bare name, whose
//!    arguments are data, with only the flags on that program's allow-list
//!    (any other flag, and every abbreviation of one, is rejected: see
//!    `Flags`); and
//! 2. every argument is a plain literal: no `$` anywhere in the text (not
//!    `$VAR`, `$(`, `${`, `$((`, `$'…'`, `$"…"`), no backtick, no `<(` / `>(`,
//!    no backslash-newline, no unquoted brace or (for the programs with flags)
//!    glob character, no comment, nothing the tokenizer could not parse, and
//!    no unquoted here-doc body with any of those. The one place `$` may
//!    appear is the body of a here-doc whose delimiter is quoted (`<<'EOF'`):
//!    there it is data.
//!
//! A command word that is a marker, a shell, `eval`, `source`, `xargs`, `env`,
//! `sudo`, `command`, `exec`, a path, an expansion or anything unlisted is
//! never inert.
//!
//! Anything the exemption doesn't cover keeps being blocked. The workaround is
//! to write the text with an editor tool instead of Bash, or to split the
//! mention.

use super::shell::{self, ShellParse, SimpleCommand, Word};

/// Is every part of `raw` (parsed as `parsed`) a program whose arguments are
/// literal data? Then no text scan applies: nothing in it runs a marker.
///
/// `parsed` is the parse of `raw` with line continuations removed; a `raw` that
/// has one is never inert (so the two have the same offsets whenever this
/// returns true).
pub fn is_inert_mention(raw: &str, parsed: &ShellParse) -> bool {
    if parsed.unparsed || parsed.expanding_heredoc || parsed.commands.is_empty() {
        return false;
    }
    if raw.contains("\\\n") || !literal_text(raw, parsed) {
        return false;
    }
    parsed.commands.iter().all(|c| inert_command(raw, c))
}

/// Does the text, other than the bodies of quoted-delimiter here-docs (data),
/// hold anything but literal characters?
fn literal_text(raw: &str, parsed: &ShellParse) -> bool {
    // `${…}`, `$(( ))` and `$[ ]` run commands the tokenizer skips, and a bare
    // `$` can start `$'…'`, `$"…"` or `$\<newline>(`: no `$` at all. `/dev/tcp`
    // and friends are a redirect to something that is not a file.
    const NOT_LITERAL: &[&str] = &[
        "$", "`", "<(", ">(", "/dev/tcp", "/dev/udp", "/dev/fd", "/proc/",
    ];
    let mut rest = raw;
    let mut offset = 0;
    let mut bodies: Vec<_> = parsed
        .heredocs
        .iter()
        .filter(|h| h.quoted)
        .map(|h| h.body_span.clone())
        .collect();
    bodies.sort_by_key(|r| r.start);
    let mut checked = String::new();
    for body in bodies {
        let (Some(before), Some(after)) = (raw.get(offset..body.start), raw.get(body.end..)) else {
            return false;
        };
        checked.push_str(before);
        checked.push('\n');
        offset = body.end;
        rest = after;
    }
    checked.push_str(rest);
    !NOT_LITERAL.iter().any(|m| checked.contains(m))
}

/// The flags a program may be given. Anything else that starts with `-` makes
/// the command not inert, and long flags match exactly (no abbreviations: `ag`
/// and git take any unambiguous prefix of a long flag, GNU `getopt_long`
/// programs too, so `--pag` is `--pager`).
///
/// A flag is listed under `value` only if it always takes a value: the next
/// word is then data and is not checked, so a wrong entry would hide a flag.
struct Flags {
    /// Short flags without a value, as a string of letters (`"nil"`).
    short: &'static str,
    /// Short flags with a value (attached or the next word).
    short_value: &'static str,
    /// Long flags without a required value (`--stat`, `--color[=when]`).
    long: &'static [&'static str],
    /// Long flags with a value (`--grep=x`, `--grep x`).
    long_value: &'static [&'static str],
    /// `-5` style numeric flags.
    digits: bool,
}

const GIT_HISTORY: Flags = Flags {
    short: "pswbiau",
    short_value: "nSGU",
    long: &[
        "stat",
        "shortstat",
        "numstat",
        "name-only",
        "name-status",
        "oneline",
        "no-color",
        "color",
        "cached",
        "staged",
        "patch",
        "no-patch",
        "graph",
        "decorate",
        "abbrev-commit",
        "no-merges",
        "merges",
        "all",
        "first-parent",
        "reverse",
        "follow",
        "summary",
        "raw",
        "no-ext-diff",
        "no-textconv",
        "ignore-all-space",
        "ignore-space-change",
        "word-diff",
        "check",
        "full-index",
        "binary",
        "topo-order",
        "date-order",
        "pretty",
        "format",
        "date",
        "abbrev",
        "diff-filter",
        "regexp-ignore-case",
        "fixed-strings",
        "extended-regexp",
        "all-match",
        "invert-grep",
        "left-right",
        "boundary",
        "source",
        "no-abbrev-commit",
        "stat-width",
    ],
    long_value: &[
        "grep",
        "author",
        "committer",
        "since",
        "until",
        "after",
        "before",
        "max-count",
        "skip",
    ],
    digits: true,
};

const GIT_GREP: Flags = Flags {
    short: "nivwlLchHIaEFPqoWpr",
    short_value: "eABC",
    long: &[
        "cached",
        "untracked",
        "no-index",
        "full-name",
        "heading",
        "break",
        "count",
        "line-number",
        "ignore-case",
        "word-regexp",
        "invert-match",
        "files-with-matches",
        "files-without-match",
        "name-only",
        "text",
        "fixed-strings",
        "extended-regexp",
        "perl-regexp",
        "basic-regexp",
        "and",
        "or",
        "not",
        "show-function",
        "function-context",
        "no-color",
        "color",
        "only-matching",
        "quiet",
        "recursive",
        "no-recurse-submodules",
        "recurse-submodules",
    ],
    long_value: &[],
    digits: true,
};

const GIT_COMMIT: Flags = Flags {
    short: "asqnv",
    short_value: "mF",
    long: &[
        "all",
        "amend",
        "no-edit",
        "allow-empty",
        "allow-empty-message",
        "no-verify",
        "signoff",
        "quiet",
        "verbose",
        "dry-run",
    ],
    long_value: &["message", "author", "date", "file"],
    digits: false,
};

const GIT_ADD: Flags = Flags {
    short: "AunvfN",
    short_value: "",
    long: &[
        "all",
        "update",
        "dry-run",
        "verbose",
        "force",
        "intent-to-add",
        "ignore-errors",
    ],
    long_value: &[],
    digits: false,
};

const GIT_STATUS: Flags = Flags {
    short: "sbv",
    short_value: "",
    long: &[
        "short",
        "branch",
        "porcelain",
        "long",
        "verbose",
        "untracked-files",
        "ignored",
    ],
    long_value: &[],
    digits: false,
};

const GIT_TAG: Flags = Flags {
    short: "alfd",
    short_value: "mF",
    long: &["annotate", "list", "force", "delete"],
    long_value: &["message", "file"],
    digits: false,
};

const GIT_NOTES: Flags = Flags {
    short: "f",
    short_value: "mF",
    long: &["force"],
    long_value: &["message", "file"],
    digits: false,
};

const GREP: Flags = Flags {
    short: "nivwxlLcrRhHoqsEFPGaIUTbV",
    short_value: "eABCmdD",
    long: &[
        "recursive",
        "dereference-recursive",
        "ignore-case",
        "no-ignore-case",
        "invert-match",
        "word-regexp",
        "line-regexp",
        "count",
        "files-with-matches",
        "files-without-match",
        "line-number",
        "no-filename",
        "with-filename",
        "only-matching",
        "quiet",
        "silent",
        "no-messages",
        "extended-regexp",
        "fixed-strings",
        "perl-regexp",
        "basic-regexp",
        "text",
        "color",
        "colour",
        "null",
        "initial-tab",
        "byte-offset",
    ],
    long_value: &[
        "include",
        "exclude",
        "exclude-dir",
        "binary-files",
        "max-count",
        "context",
        "after-context",
        "before-context",
        "regexp",
    ],
    digits: true,
};

/// Not `-z` / `--search-zip` (they run decompressors), `--pre`, `--pre-glob`,
/// `--hostname-bin`, `--type-add` and the rest.
const RG: Flags = Flags {
    short: "nNilLwFSscvHIuUoqaPx",
    short_value: "egtTABCmrd",
    long: &[
        "files",
        "no-heading",
        "heading",
        "hidden",
        "no-ignore",
        "ignore-case",
        "smart-case",
        "case-sensitive",
        "line-number",
        "no-line-number",
        "word-regexp",
        "fixed-strings",
        "count",
        "count-matches",
        "files-with-matches",
        "files-without-match",
        "invert-match",
        "only-matching",
        "multiline",
        "pcre2",
        "text",
        "follow",
        "stats",
        "no-messages",
        "color",
        "line-regexp",
        "with-filename",
        "no-filename",
        "quiet",
        "unrestricted",
        "column",
        "vimgrep",
        "json",
        "trim",
        "no-config",
    ],
    long_value: &[
        "engine",
        "glob",
        "type",
        "type-not",
        "max-count",
        "max-depth",
        "context",
        "after-context",
        "before-context",
        "regexp",
        "replace",
    ],
    digits: false,
};

/// `ag` is only exempt as `ag -n/-i/-l/-w/-Q <literal> <paths>`: no long flags
/// (`--pager` runs a command, and abbreviations of it work).
const AG: Flags = Flags {
    short: "nilwQ",
    short_value: "",
    long: &[],
    long_value: &[],
    digits: false,
};

const SORT: Flags = Flags {
    short: "nrufbhVdiMcCsz",
    short_value: "kt",
    long: &[
        "numeric-sort",
        "reverse",
        "unique",
        "ignore-case",
        "version-sort",
        "human-numeric-sort",
        "stable",
    ],
    long_value: &[],
    digits: false,
};

const UNIQ: Flags = Flags {
    short: "cduiD",
    short_value: "fsw",
    long: &["count", "repeated", "unique", "ignore-case"],
    long_value: &[],
    digits: false,
};

/// `ls` takes short flags and no flag runs anything, but it is held to the
/// same rule as the others: short letters only.
const LS: Flags = Flags {
    short: "1aAbBcCdFgGhHiIklLmnNopqQrRsStuUvxXZ",
    short_value: "",
    long: &[],
    long_value: &[],
    digits: false,
};

/// Is every flag in `args` on the list? Flag-like words end at a bare `--`.
fn flags_allowed(args: &[&str], spec: &Flags) -> bool {
    let mut i = 0;
    while i < args.len() {
        let arg = args[i];
        i += 1;
        if arg == "--" {
            return true;
        }
        if let Some(long) = arg.strip_prefix("--") {
            let (name, has_value) = match long.split_once('=') {
                Some((name, _)) => (name, true),
                None => (long, false),
            };
            if spec.long_value.contains(&name) {
                if !has_value {
                    i += 1;
                }
            } else if !spec.long.contains(&name) {
                return false;
            }
        } else if let Some(cluster) = arg.strip_prefix('-').filter(|c| !c.is_empty()) {
            if spec.digits && cluster.bytes().all(|b| b.is_ascii_digit()) {
                continue;
            }
            for (at, c) in cluster.char_indices() {
                if spec.short.contains(c) {
                    continue;
                }
                if spec.short_value.contains(c) {
                    // The rest of the cluster is the value, or the next word is.
                    if at + c.len_utf8() == cluster.len() {
                        i += 1;
                    }
                    break;
                }
                return false;
            }
        }
    }
    true
}

/// The characters of `word` as written that are outside quotes and not escaped.
fn unquoted(word: &str) -> String {
    let mut out = String::new();
    let mut chars = word.chars();
    let (mut single, mut double) = (false, false);
    while let Some(c) = chars.next() {
        match c {
            '\\' if !single => {
                chars.next();
            }
            '\'' if !double => single = !single,
            '"' if !single => double = !double,
            _ if single || double => {}
            _ => out.push(c),
        }
    }
    out
}

/// A word that is not a plain literal: a brace expansion (it can build a flag),
/// a glob in a word that takes flags (a file called `--pre=…` is a flag), a
/// comment, or something the tokenizer marked dynamic.
fn not_plain(raw: &str, word: &Word, takes_flags: bool, group_word: bool) -> bool {
    if word.dynamic {
        return true;
    }
    if group_word {
        return false;
    }
    let Some(written) = raw.get(word.span.clone()) else {
        return true;
    };
    let outside = unquoted(written);
    outside.contains(['{', '}', '#']) || (takes_flags && outside.contains(['*', '?', '[']))
}

fn inert_command(raw: &str, cmd: &SimpleCommand) -> bool {
    // A command from a `-c` / `eval` payload or a here-doc fed to a shell has
    // words that are offsets into another text.
    if cmd.depth > 0 {
        return false;
    }
    let mut words = cmd.words.as_slice();
    // `{ cmd; }`: the group's keyword words are not commands, and `}` alone is the close.
    let opens_group = words.first().is_some_and(|w| w.text == "{");
    if opens_group {
        words = &words[1..];
    }
    let Some(first) = words.first() else {
        return false;
    };
    if first.text == "}" && words.len() == 1 {
        return true;
    }
    // An assignment first (`PATH=/tmp/x git …`), an expansion or a path (`./git`) is no known program.
    if first.dynamic || first.text.contains('/') || shell::is_assignment(&first.text) {
        return false;
    }
    let args = &words[1..];
    let texts: Vec<&str> = args.iter().map(|w| w.text.as_str()).collect();
    let name = first.text.as_str();
    let takes_flags = matches!(
        name,
        "git" | "grep" | "egrep" | "fgrep" | "rg" | "ag" | "sort" | "uniq"
    );
    if not_plain(raw, first, false, false)
        || args
            .iter()
            .any(|w| not_plain(raw, w, takes_flags, w.text == "}"))
    {
        return false;
    }
    match name {
        "echo" | "cat" | "tee" | "wc" | "head" | "tail" | "cd" | "pwd" | "true" | "false"
        | "test" | "[" => true,
        // `printf -v 'a[…]'` assigns a variable (and evaluates its subscript): no options.
        "printf" => texts
            .first()
            .is_none_or(|t| !t.starts_with('-') || *t == "--"),
        "grep" | "egrep" | "fgrep" => flags_allowed(&texts, &GREP),
        "rg" => flags_allowed(&texts, &RG),
        "ag" => flags_allowed(&texts, &AG),
        "sort" => flags_allowed(&texts, &SORT),
        "uniq" => flags_allowed(&texts, &UNIQ),
        "ls" => flags_allowed(&texts, &LS),
        "git" => git_inert(&texts),
        "gh" => matches!(texts.as_slice(), ["pr", "create" | "comment", ..]),
        _ => false,
    }
}

/// `git <subcommand> …` for the subcommands whose arguments are data (messages,
/// patterns, paths, refs), with only the flags on that subcommand's list.
/// No global option is allowed but `--no-pager`, `-P` and `--no-optional-locks`:
/// `-c`, `-C <dir>`, `--exec-path` and friends make the repository's config (a
/// pager, an alias, an fsmonitor) the program that runs.
fn git_inert(args: &[&str]) -> bool {
    let mut i = 0;
    while matches!(
        args.get(i),
        Some(&("--no-pager" | "-P" | "--no-optional-locks"))
    ) {
        i += 1;
    }
    let Some(sub) = args.get(i) else { return false };
    let rest = &args[i + 1..];
    match *sub {
        "commit" => flags_allowed(rest, &GIT_COMMIT),
        "add" => flags_allowed(rest, &GIT_ADD),
        "status" => flags_allowed(rest, &GIT_STATUS),
        "tag" => flags_allowed(rest, &GIT_TAG),
        "log" | "show" | "diff" => flags_allowed(rest, &GIT_HISTORY),
        "grep" => flags_allowed(rest, &GIT_GREP),
        // `edit` opens an editor and `merge` runs the merge strategy.
        "notes" => {
            matches!(
                rest.first(),
                Some(&("add" | "append" | "show" | "list" | "remove"))
            ) && flags_allowed(&rest[1..], &GIT_NOTES)
        }
        _ => false,
    }
}
