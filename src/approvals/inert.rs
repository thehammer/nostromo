//! The "inert mention" exemption: a command that only *mentions* a production
//! shell marker, as data.
//!
//! `git commit -m "fix ecs_connect"`, `grep -rn ecs_connect docs`, `echo
//! "tmux send-keys is how the guard works"` and a here-doc written to `notes.md`
//! are not remote shells, and the text scans would block them. This is the one
//! place that says when a command's text is only data.
//!
//! A command is inert only when **every** simple command the tokenizer found
//! (in every pipeline and list, and inside `$( )`, backticks, subshells and
//! payloads) is a known program whose arguments are data, and nothing the
//! tokenizer can't see could run text. A command word that is a marker, a
//! shell, `eval`, `source`, `xargs`, `env`, `sudo`, `command`, `exec`, a path, an
//! expansion or anything unlisted is never inert, nor is a process
//! substitution, a `/dev/tcp` redirect, an unparsed construct or an unquoted
//! here-doc that runs a `$( )`.
//!
//! Anything the exemption doesn't cover keeps being blocked. The workaround is
//! to write the text with an editor tool instead of Bash, or to split the
//! mention.

use super::shell::{self, ShellParse, SimpleCommand};

/// Is every part of `raw` (parsed as `parsed`) a program whose arguments are
/// data? Then no text scan applies: nothing in it runs a marker.
pub fn is_inert_mention(raw: &str, parsed: &ShellParse) -> bool {
    if parsed.unparsed || parsed.expanding_heredoc || parsed.commands.is_empty() {
        return false;
    }
    // `${x:-$(…)}`, `$(( a[$(…)] ))` and `$[ ]` run commands the tokenizer
    // skips over: a command with them is never exempt. `/dev/tcp` and friends
    // are a redirect to something that is not a file.
    const NOT_FILES: &[&str] = &["${", "$((", "$[", "/dev/tcp", "/dev/udp", "/dev/fd", "/proc/"];
    if NOT_FILES.iter().any(|m| raw.contains(m)) {
        return false;
    }
    parsed.commands.iter().all(inert_command)
}

fn inert_command(cmd: &SimpleCommand) -> bool {
    let words = &cmd.words;
    let Some(first) = words.first() else { return false };
    // An assignment first (`PATH=/tmp/x git …`), an expansion or a path (`./git`) is no known program.
    if first.dynamic || first.text.contains('/') || shell::is_assignment(&first.text) {
        return false;
    }
    let args = &words[1..];
    // A process substitution runs commands.
    if words.iter().any(|w| w.text.starts_with("<(") || w.text.starts_with(">(")) {
        return false;
    }
    let texts: Vec<&str> = args.iter().map(|w| w.text.as_str()).collect();
    match first.text.as_str() {
        "echo" | "printf" | "cat" | "tee" | "wc" | "head" | "tail" | "grep" | "egrep" | "fgrep" => true,
        // `--pre <cmd>` runs a command on each file; `--hostname-bin` runs one too.
        "rg" => !texts.iter().any(|t| t.starts_with("--pre") || t.starts_with("--hostname-bin")),
        // `--pager <cmd>` runs a command.
        "ag" => !texts.iter().any(|t| t.starts_with("--pager")),
        "sed" => sed_prints_lines(&texts),
        "awk" => awk_reads_files(&texts),
        "git" => git_inert(&texts),
        "gh" => matches!(texts.as_slice(), ["pr", "create" | "comment", ..]),
        _ => false,
    }
}

/// `sed -n '<address>p' file…`: the one form of `sed` that only prints lines.
/// (`e`, `w` and `s///e` can run commands or write files.)
fn sed_prints_lines(args: &[&str]) -> bool {
    let [flag, script, files @ ..] = args else { return false };
    if *flag != "-n" || files.iter().any(|f| f.starts_with('-')) {
        return false;
    }
    let address = r"(?:\d+|\$|/[^/;\\]*/)";
    let re = regex::Regex::new(&format!(r"^(?:{address}(?:,{address})?)?p$")).expect("a valid pattern");
    re.is_match(script)
}

/// `awk '<program>' file…` with a program that can't run a command (`system`,
/// a `|` pipe, `getline`) or load another one (`-f`, `-i`, `-l`, `-e`).
fn awk_reads_files(args: &[&str]) -> bool {
    let program_loads_code = |a: &&str| {
        ["-f", "--file", "-i", "--include", "-l", "--load", "-e", "--source"].iter().any(|o| a.starts_with(o))
    };
    if args.iter().any(program_loads_code) {
        return false;
    }
    // The program is the first word that isn't an option or an option's value.
    let mut i = 0;
    while i < args.len() && args[i].starts_with('-') {
        i += if matches!(args[i], "-F" | "-v") { 2 } else { 1 };
    }
    let Some(program) = args.get(i) else { return false };
    let lower = program.to_ascii_lowercase();
    !(lower.contains("system") || lower.contains('|') || lower.contains("getline"))
}

/// `git <subcommand> …` for the subcommands whose arguments are data (messages,
/// patterns, paths, refs), without the options that run a program.
fn git_inert(args: &[&str]) -> bool {
    const SUBCOMMANDS: &[&str] = &[
        "commit", "log", "grep", "diff", "show", "add", "status", "tag", "notes", "push", "pull", "fetch", "branch",
        "checkout", "switch", "stash", "merge",
    ];
    // Global options that run nothing: `-C <dir>`, `--no-pager`, `-P`.
    let mut i = 0;
    while i < args.len() {
        match args[i] {
            "-C" => i += 2,
            "--no-pager" | "-P" | "--no-optional-locks" => i += 1,
            _ => break,
        }
    }
    let Some(sub) = args.get(i) else { return false };
    if !SUBCOMMANDS.contains(sub) {
        return false;
    }
    !args[i + 1..].iter().any(|a| {
        ["--exec", "--receive-pack", "--upload-pack", "--open-files-in-pager", "--ext-diff", "--textconv", "--pager"]
            .iter()
            .any(|o| a.starts_with(o))
            || (a.starts_with("-O") && !a.starts_with("--"))
    })
}
