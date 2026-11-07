//! The consequence preview (AP7): what an `rm` / `rmdir` / `mv` in a held command
//! would touch, shown under the command on the card.
//!
//! **Strictly read-only.** This module never runs the agent's command, any part of it, or
//! any "dry run", and never starts a process. It reads metadata only
//! (`symlink_metadata`, `read_dir`), never follows a symlink, never crosses a device and
//! never resolves a path through the file system. A source-scan test pins that.
//!
//! - [`targets`] is pure: it reads a [`ShellParse`] and says which operands of which
//!   commands would be touched, resolved to absolute paths when that can be done without
//!   guessing, else "can't resolve".
//! - [`walk`] does the file-system reads, through the [`PreviewFs`] trait so tests can
//!   inject slowness, `EACCES`, other devices and macOS-only paths. It is bounded by an
//!   entry count and a time budget.

use std::collections::{BTreeSet, HashMap};
use std::ffi::OsString;
use std::io;
use std::path::{Component, Path, PathBuf};
use std::time::{Duration, Instant};

use super::audit::sanitize_string;
use super::expand::glob_match;
use super::shell::{ShellParse, SimpleCommand};
use super::wire::{
    ApprovalPreviewWire, PreviewCommand, PreviewFlag, PreviewKind, PreviewState, PreviewTargetWire,
};

/// Most targets a preview lists; the rest are only counted (`more`).
pub const MAX_TARGETS: usize = 64;
/// Most matches one glob operand expands to.
pub const MAX_GLOB_MATCHES: usize = 1_000;
/// Most entries one preview counts before it stops and says "at least".
pub const MAX_ENTRIES: usize = 100_000;
/// Longest text of one preview field, in bytes (a line stays well under 1 KiB).
const MAX_FIELD_BYTES: usize = 300;

/// One operand of an `rm` / `rmdir` / `mv`, before any file-system read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TargetSpec {
    pub command: PreviewCommand,
    pub operand: Operand,
    /// For `mv`: the destination, as written (resolved when it can be).
    pub dest: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Operand {
    /// An absolute path (maybe with glob characters in a component).
    Path {
        path: PathBuf,
        /// It was written relative and joined to the session's start folder.
        relative: bool,
        /// It was written with a trailing slash (which makes `rm` follow a symlink).
        trailing_slash: bool,
    },
    CantResolve {
        text: String,
        why: String,
    },
}

/// Which operands, of which commands, the command line would touch. No I/O.
///
/// `cmd` is the text `parse` came from (it tells a quoted glob from a bare one).
pub fn targets(cmd: &str, parse: &ShellParse, cwd: Option<&Path>, home: &Path) -> Vec<TargetSpec> {
    let mut out = Vec::new();
    let mut after_cd = false;
    for command in &parse.commands {
        let name = command_name(command);
        if let Some(kind) = name.as_deref().and_then(preview_command) {
            operands(cmd, parse, command, kind, after_cd, cwd, home, &mut out);
        } else if let Some(name) = name.as_deref() {
            if let Some(spec) = wrapped_removal(name, command) {
                out.push(spec);
            }
        }
        if name
            .as_deref()
            .is_some_and(|n| changes_directory(n, command))
        {
            after_cd = true;
        }
    }
    out
}

fn command_name(command: &SimpleCommand) -> Option<String> {
    let word = command.words.first()?;
    if word.dynamic {
        return None;
    }
    let base = word.text.rsplit('/').next().unwrap_or(&word.text);
    Some(base.to_lowercase())
}

/// Commands that run another command given as one of their words.
const WRAPPERS: [&str; 18] = [
    "sudo",
    "doas",
    "env",
    "nice",
    "ionice",
    "nohup",
    "timeout",
    "xargs",
    "command",
    "builtin",
    "exec",
    "time",
    "stdbuf",
    "setsid",
    "caffeinate",
    "watch",
    "parallel",
    "chroot",
];

/// Programs that only read or print their words, or whose `-c` payload the parser already
/// looks into: a word `rm` after them is not a removal run through them.
const NOT_RUNNERS: [&str; 12] = [
    "echo", "printf", "grep", "egrep", "fgrep", "which", "type", "ls", "cat", "bash", "sh", "zsh",
];

/// Programs whose quoted arguments are text (a commit message, a search pattern), not a
/// command line, unless a flag says otherwise (see [`runs_a_command`]). A bare `rm` word
/// after them (`git rm x`) is still flagged.
const DATA_PROGRAMS: [&str; 2] = ["git", "gh"];

/// Flags of those programs whose next word is free text (a message, a pattern). Only a
/// quoted word right after one of these is skipped; any other quoted word is still scanned.
const DATA_FLAGS: [&str; 8] = [
    "-m",
    "-am",
    "--message",
    "--body",
    "-b",
    "--title",
    "-t",
    "--grep",
];

/// A word with more than one token in it: a quoted sentence or command line.
fn is_quoted_payload(text: &str) -> bool {
    text.contains(|c: char| c.is_whitespace() || ";&|()'\"`".contains(c))
}

/// Do the words of a [`DATA_PROGRAMS`] program carry something it will run (`git rebase
/// --exec`, `-c alias.x=!...`, `--tree-filter`, `config`, `--extcmd`)?
fn runs_a_command(words: &[super::shell::Word]) -> bool {
    words.iter().any(|w| {
        let t = w.text.to_lowercase();
        w.dynamic
            || t == "config"
            || t == "-x"
            || t == "-u"
            || t == "-o"
            || t.starts_with("-c")
            || [
                "exec", "filter", "extcmd", "alias", "cmd", "command", "hook", "editor",
            ]
            .iter()
            .any(|m| t.contains(m))
    })
}

fn word_base(word: &super::shell::Word) -> Option<String> {
    if word.dynamic {
        return None;
    }
    Some(
        word.text
            .rsplit('/')
            .next()
            .unwrap_or(&word.text)
            .to_lowercase(),
    )
}

/// An `rm` / `rmdir` / `mv` run through a wrapper, or `find -delete` / `-exec rm`: its
/// operands are not previewed, so the card says it can't resolve them.
fn wrapped_removal(name: &str, command: &SimpleCommand) -> Option<TargetSpec> {
    let words = &command.words[1..];
    let (kind, text, via) = if let Some((word, kind)) = WRAPPERS
        .contains(&name)
        .then(|| {
            words
                .iter()
                .find_map(|w| Some((w, preview_command(&word_base(w)?)?)))
        })
        .flatten()
    {
        (kind, word.text.clone(), name.to_string())
    } else if name == "find" {
        let exec = words.windows(2).find_map(|pair| {
            let flag = pair[0].text.as_str();
            if !matches!(flag, "-exec" | "-execdir" | "-ok" | "-okdir") {
                return None;
            }
            preview_command(&word_base(&pair[1])?)
        });
        if let Some(kind) = exec {
            (kind, "find".to_string(), "find -exec".to_string())
        } else if words.iter().any(|w| !w.dynamic && w.text == "-delete") {
            (
                PreviewCommand::Rm,
                "find".to_string(),
                "find -delete".to_string(),
            )
        } else {
            return None;
        }
    } else {
        // Any other program the preview does not analyse, with `rm` / `rmdir` / `mv` as a
        // word (or inside a word, as in `sh -c "rm -rf x"`): it may remove things.
        if NOT_RUNNERS.contains(&name) {
            return None;
        }
        let data_only = DATA_PROGRAMS.contains(&name) && !runs_a_command(words);
        let (kind, word) = words.iter().enumerate().find_map(|(i, w)| {
            let is_message = data_only
                && is_quoted_payload(&w.text)
                && i > 0
                && DATA_FLAGS.contains(&words[i - 1].text.as_str());
            if w.dynamic || is_message {
                return None;
            }
            w.text
                .split(|c: char| c.is_whitespace() || ";&|()'\"`!=".contains(c))
                .find_map(|tok| {
                    let base = tok.rsplit('/').next().unwrap_or(tok);
                    let base = base.trim_start_matches('\\').to_lowercase();
                    Some((preview_command(&base)?, w))
                })
        })?;
        (kind, word.text.clone(), name.to_string())
    };
    Some(TargetSpec {
        command: kind,
        operand: Operand::CantResolve {
            text,
            why: format!("runs via {via}"),
        },
        dest: None,
    })
}

fn preview_command(name: &str) -> Option<PreviewCommand> {
    match name {
        "rm" => Some(PreviewCommand::Rm),
        "rmdir" => Some(PreviewCommand::Rmdir),
        "mv" => Some(PreviewCommand::Mv),
        _ => None,
    }
}

/// Does this command change (or run something in) another working directory?
fn changes_directory(name: &str, command: &SimpleCommand) -> bool {
    match name {
        // Anything that can change the directory or HOME/PWD for what follows: after it,
        // a relative or `~` operand is not trustworthy.
        "cd" | "pushd" | "popd" | "chdir" | "builtin" | "command" | "export" | "unset"
        | "source" | "." | "exec" => true,
        "env" | "git" => command
            .words
            .iter()
            .skip(1)
            .any(|w| w.text.starts_with("-C") || w.text == "--chdir"),
        _ => false,
    }
}

fn allowed_flags(kind: PreviewCommand) -> &'static str {
    match kind {
        PreviewCommand::Rm => "rRfidvPWx",
        PreviewCommand::Rmdir => "pv",
        PreviewCommand::Mv => "finvh",
    }
}

#[allow(clippy::too_many_arguments)]
fn operands(
    cmd: &str,
    parse: &ShellParse,
    command: &SimpleCommand,
    kind: PreviewCommand,
    after_cd: bool,
    cwd: Option<&Path>,
    home: &Path,
    out: &mut Vec<TargetSpec>,
) {
    let mut flags_ok = true;
    let mut ended_flags = false;
    let mut words = Vec::new();
    for word in command.words.iter().skip(1) {
        if !ended_flags && word.text == "--" && !word.dynamic {
            ended_flags = true;
        } else if !ended_flags && word.text.len() > 1 && word.text.starts_with('-') {
            let known = !word.dynamic
                && !word.text.starts_with("--")
                && word.text[1..]
                    .chars()
                    .all(|c| allowed_flags(kind).contains(c));
            flags_ok &= known;
        } else {
            words.push(word);
        }
    }
    let unparsed = parse.unparsed || parse.expanding_heredoc;
    let resolve = |word: &super::shell::Word| -> Operand {
        if unparsed {
            return cant(word, "could not parse the command");
        }
        if !flags_ok {
            return cant(word, "unknown flag");
        }
        resolve_word(cmd, command, word, after_cd, cwd, home)
    };
    if kind == PreviewCommand::Mv {
        let Some((dest, sources)) = words.split_last() else {
            return;
        };
        let dest_text = match resolve(dest) {
            Operand::Path { path, .. } => path.to_string_lossy().into_owned(),
            Operand::CantResolve { text, .. } => text,
        };
        for word in sources {
            out.push(TargetSpec {
                command: kind,
                operand: resolve(word),
                dest: Some(dest_text.clone()),
            });
        }
        return;
    }
    for word in words {
        out.push(TargetSpec {
            command: kind,
            operand: resolve(word),
            dest: None,
        });
    }
}

fn cant(word: &super::shell::Word, why: &str) -> Operand {
    Operand::CantResolve {
        text: word.text.clone(),
        why: why.into(),
    }
}

fn resolve_word(
    cmd: &str,
    command: &SimpleCommand,
    word: &super::shell::Word,
    after_cd: bool,
    cwd: Option<&Path>,
    home: &Path,
) -> Operand {
    let text = word.text.as_str();
    if word.dynamic {
        return cant(word, "uses a variable or substitution");
    }
    if text.is_empty() {
        return cant(word, "empty operand");
    }
    if text.contains('{') && text.contains('}') {
        return cant(word, "brace expansion");
    }
    if text.starts_with('~') && text != "~" && !text.starts_with("~/") {
        return cant(word, "another user's home");
    }
    if text.split('/').any(|c| c == "..") {
        return cant(word, "contains ..");
    }
    if has_glob(text) {
        // Quote information is gone after quote removal: a quoted glob is a literal name,
        // a bare one expands. Do not guess which this was.
        if command.depth > 0 {
            return cant(word, "glob inside a nested command");
        }
        match cmd.get(word.span.clone()) {
            Some(src) if !src.contains(['\'', '"', '\\']) => {}
            _ => return cant(word, "quoted glob"),
        }
    }
    let (base, relative) = if text == "~" {
        (home.to_path_buf(), false)
    } else if let Some(rest) = text.strip_prefix("~/") {
        (home.join(rest), false)
    } else if text.starts_with('/') {
        (PathBuf::from(text), false)
    } else if after_cd {
        return cant(word, "after a cd");
    } else if let Some(cwd) = cwd {
        (cwd.join(text), true)
    } else {
        return cant(word, "no working directory known");
    };
    Operand::Path {
        path: lexical(&base),
        relative,
        trailing_slash: text.len() > 1 && text.ends_with('/'),
    }
}

fn has_glob(text: &str) -> bool {
    text.contains(['*', '?', '['])
}

/// Drop `.` components and a trailing slash. (`..` was refused earlier.)
fn lexical(path: &Path) -> PathBuf {
    path.components()
        .filter(|c| !matches!(c, Component::CurDir))
        .collect()
}

// ---------------------------------------------------------------------------------------
// The walk
// ---------------------------------------------------------------------------------------

/// What an entry is, from `symlink_metadata`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EntryKind {
    File,
    Dir,
    Symlink,
    Other,
}

/// The few metadata fields the walk uses.
#[derive(Debug, Clone, Copy)]
pub struct Meta {
    pub kind: EntryKind,
    pub len: u64,
    /// The device the entry lives on.
    pub dev: u64,
}

/// The file-system reads the walk may make. Metadata and directory listings only.
pub trait PreviewFs: Send + Sync {
    /// Metadata of the entry itself (a symlink is not followed).
    fn symlink_metadata(&self, path: &Path) -> io::Result<Meta>;
    /// The names in a directory.
    fn read_dir(&self, path: &Path) -> io::Result<Box<dyn Iterator<Item = io::Result<OsString>>>>;
    /// Is `path` on a network or external volume (never touched)?
    fn is_network(&self, path: &Path) -> bool;
}

/// The real file system.
pub struct RealFs;

/// Roots whose contents are network, external or automounted volumes.
const NETWORK_ROOTS: [&str; 5] = [
    "/Volumes",
    "/Network",
    "/net",
    "/home",
    "/System/Volumes/Data/mnt",
];

/// Is `path` under one of the network / external / automount roots?
pub fn is_network_path(path: &Path) -> bool {
    let folded = key(path);
    let raw = PathBuf::from(path.to_string_lossy().to_lowercase());
    NETWORK_ROOTS
        .iter()
        .any(|r| path.starts_with(r) || folded.starts_with(r.to_lowercase()))
        || ["/system/volumes/data/net", "/system/volumes/data/home"]
            .iter()
            .any(|r| raw.starts_with(r))
}

/// A path as the file system sees it for comparison: case-folded (APFS is case
/// insensitive), with the `/System/Volumes/Data` firmlink and the `/private/{var,tmp,etc}`
/// aliases removed. Only for comparing, never for reading.
fn key(path: &Path) -> PathBuf {
    let mut comps: Vec<String> = path
        .components()
        .filter_map(|c| match c {
            Component::Normal(s) => Some(s.to_string_lossy().to_lowercase()),
            _ => None,
        })
        .collect();
    if comps.len() >= 3 && comps[..3] == ["system", "volumes", "data"] {
        comps.drain(..3);
    }
    if comps.len() >= 2
        && comps[0] == "private"
        && ["var", "tmp", "etc"].contains(&comps[1].as_str())
    {
        comps.remove(0);
    }
    let mut out = PathBuf::from("/");
    out.extend(comps);
    out
}

/// `path` is `base` or inside it, by [`key`].
fn within(path: &Path, base: &Path) -> bool {
    key(path).starts_with(key(base))
}

impl PreviewFs for RealFs {
    fn symlink_metadata(&self, path: &Path) -> io::Result<Meta> {
        use std::os::unix::fs::MetadataExt;
        let m = std::fs::symlink_metadata(path)?;
        let kind = match m.mode() & 0o170_000 {
            0o120_000 => EntryKind::Symlink,
            0o040_000 => EntryKind::Dir,
            0o100_000 => EntryKind::File,
            _ => EntryKind::Other,
        };
        Ok(Meta {
            kind,
            len: m.len(),
            dev: m.dev(),
        })
    }

    fn read_dir(&self, path: &Path) -> io::Result<Box<dyn Iterator<Item = io::Result<OsString>>>> {
        let rd = std::fs::read_dir(path)?;
        Ok(Box::new(rd.map(|e| e.map(|e| e.file_name()))))
    }

    fn is_network(&self, path: &Path) -> bool {
        is_network_path(path)
    }
}

/// Where the session runs, for the flags.
#[derive(Debug, Clone)]
pub struct Env {
    pub cwd: Option<PathBuf>,
    pub home: PathBuf,
}

/// How much a walk may do.
#[derive(Debug, Clone, Copy)]
pub struct Budget {
    pub max_entries: usize,
    pub time: Duration,
}

impl Budget {
    /// The quick pass the broker waits for.
    pub const QUICK: Budget = Budget {
        max_entries: MAX_ENTRIES,
        time: Duration::from_millis(50),
    };
    /// The full pass, on its own thread.
    pub const FULL: Budget = Budget {
        max_entries: MAX_ENTRIES,
        time: Duration::from_secs(1),
    };
}

/// Folders a macOS privacy prompt guards: never descended into from an outer target.
fn tcc_folders(home: &Path) -> Vec<PathBuf> {
    [
        "Desktop",
        "Documents",
        "Downloads",
        "Library/Application Support/AddressBook",
        "Library/Calendars",
        "Library/Cookies",
        "Library/Mail",
        "Library/Messages",
        "Library/Safari",
        "Library/Containers",
        "Library/Group Containers",
        "Library/Mobile Documents",
        "Movies",
        "Music",
        "Pictures/Photos Library.photoslibrary",
    ]
    .iter()
    .map(|p| home.join(p))
    .collect()
}

fn is_home_critical(path: &Path, home: &Path) -> bool {
    // The path is one of these, or an ancestor of one (`/`, `/Users`, `~`).
    [
        PathBuf::from("/"),
        home.to_path_buf(),
        home.join("Library"),
        home.join(".ssh"),
        home.join(".claude"),
    ]
    .iter()
    .any(|critical| within(critical, path))
}

/// Walk state shared by every target of one preview.
struct Walker<'a> {
    fs: &'a dyn PreviewFs,
    env: &'a Env,
    tcc: Vec<PathBuf>,
    /// [`key`] of each of `tcc`, computed once.
    tcc_keys: Vec<PathBuf>,
    /// Folders already checked for being a link (each is stat'd at most once per walk).
    links: HashMap<PathBuf, bool>,
    deadline: Instant,
    max_entries: usize,
    entries: usize,
    /// A budget ran out.
    spent: bool,
}

impl Walker<'_> {
    /// Count one entry; false (and `spent`) once a budget is gone.
    fn tick(&mut self) -> bool {
        if self.spent {
            return false;
        }
        self.entries += 1;
        if self.entries > self.max_entries || Instant::now() >= self.deadline {
            self.spent = true;
            return false;
        }
        true
    }
}

/// Look at every target, read-only, within `budget`.
pub fn walk(
    specs: &[TargetSpec],
    budget: Budget,
    fs: &dyn PreviewFs,
    env: &Env,
) -> ApprovalPreviewWire {
    let tcc = tcc_folders(&env.home);
    let mut w = Walker {
        fs,
        env,
        tcc_keys: tcc.iter().map(|f| key(f)).collect(),
        tcc,
        links: HashMap::new(),
        deadline: Instant::now() + budget.time,
        max_entries: budget.max_entries,
        entries: 0,
        spent: false,
    };
    let mut targets: Vec<PreviewTargetWire> = Vec::new();
    let mut more = 0u32;
    let mut partial = false;
    for spec in specs {
        match &spec.operand {
            Operand::CantResolve { text, why } => {
                if targets.len() < MAX_TARGETS {
                    targets.push(cant_target(spec, text, why));
                } else {
                    more += 1;
                }
            }
            Operand::Path {
                path,
                relative,
                trailing_slash,
            } => {
                let (matches, extra) = expand_glob(&mut w, path);
                more = more.saturating_add(extra);
                for m in matches {
                    if targets.len() >= MAX_TARGETS {
                        more += 1;
                        continue;
                    }
                    match m {
                        Expanded::Cant(p, why) => {
                            targets.push(cant_target(spec, &p.to_string_lossy(), why));
                        }
                        Expanded::Path(p) => {
                            let (t, hit_budget) =
                                inspect(&mut w, spec, &p, path, *relative, *trailing_slash);
                            partial |= hit_budget;
                            targets.push(t);
                        }
                    }
                }
            }
        }
    }
    ApprovalPreviewWire {
        state: if partial || w.spent {
            PreviewState::Partial
        } else {
            PreviewState::Complete
        },
        targets,
        more,
    }
}

/// The preview with no file-system reads: targets, can't-resolve lines and the pure flags.
/// What the card shows while the counts are still being taken.
pub fn counting(specs: &[TargetSpec], env: &Env) -> ApprovalPreviewWire {
    let mut targets = Vec::new();
    let mut more = 0u32;
    for spec in specs {
        if targets.len() >= MAX_TARGETS {
            more += 1;
            continue;
        }
        targets.push(match &spec.operand {
            Operand::CantResolve { text, why } => cant_target(spec, text, why),
            Operand::Path { path, relative, .. } => {
                let mut t = base_target(spec, path, *relative);
                set_pure_flags(&mut t, path, env);
                t
            }
        });
    }
    ApprovalPreviewWire {
        state: PreviewState::Counting,
        targets,
        more,
    }
}

/// The preview a request gets when no walk may run: every target flagged `busy`.
pub fn busy(specs: &[TargetSpec], env: &Env) -> ApprovalPreviewWire {
    let mut p = counting(specs, env);
    p.state = PreviewState::Complete;
    for t in p.targets.iter_mut().filter(|t| t.path.is_some()) {
        t.flags.push(PreviewFlag::NotCounted);
        t.flags.push(PreviewFlag::Busy);
    }
    p
}

/// A preview that says nothing but that it was left out.
pub fn omitted() -> ApprovalPreviewWire {
    ApprovalPreviewWire {
        state: PreviewState::Omitted,
        targets: Vec::new(),
        more: 0,
    }
}

fn field(s: &str) -> String {
    let mut s = sanitize_string(s);
    if s.len() > MAX_FIELD_BYTES {
        let mut cut = MAX_FIELD_BYTES;
        while !s.is_char_boundary(cut) {
            cut -= 1;
        }
        s.truncate(cut);
        s.push('…');
    }
    s
}

fn cant_target(spec: &TargetSpec, text: &str, why: &str) -> PreviewTargetWire {
    PreviewTargetWire {
        command: spec.command,
        path: None,
        cant_resolve: Some(field(text)),
        why: Some(field(why)),
        relative: false,
        exists: None,
        kind: None,
        dirs: None,
        files: None,
        bytes: None,
        at_least: false,
        flags: Vec::new(),
        dest: spec.dest.as_deref().map(field),
    }
}

fn base_target(spec: &TargetSpec, path: &Path, relative: bool) -> PreviewTargetWire {
    PreviewTargetWire {
        command: spec.command,
        path: Some(field(&path.to_string_lossy())),
        cant_resolve: None,
        why: None,
        relative,
        exists: None,
        kind: None,
        dirs: None,
        files: None,
        bytes: None,
        at_least: false,
        flags: Vec::new(),
        dest: spec.dest.as_deref().map(field),
    }
}

fn set_pure_flags(t: &mut PreviewTargetWire, path: &Path, env: &Env) {
    if env.cwd.as_deref().is_some_and(|cwd| !within(path, cwd)) {
        t.flags.push(PreviewFlag::OutsideCwd);
    }
    if is_home_critical(path, &env.home) {
        t.flags.push(PreviewFlag::HomeCritical);
    }
}

/// One result of expanding a glob operand.
enum Expanded {
    Path(PathBuf),
    /// Not looked at: it would need a read inside a protected folder, or a listing failed.
    Cant(PathBuf, &'static str),
}

/// Expand glob components of `path` against the file system. A path with no glob comes
/// back as itself. A glob with no match comes back as itself only when every listing
/// succeeded (what `rm` would then report); a glob that needs a protected, unreadable or
/// unfinished listing becomes "can't resolve", never a path that gets looked at. The
/// second value counts matches left out over [`MAX_GLOB_MATCHES`].
fn expand_glob(w: &mut Walker, path: &Path) -> (Vec<Expanded>, u32) {
    if !path
        .components()
        .any(|c| has_glob(&c.as_os_str().to_string_lossy()))
    {
        return (vec![Expanded::Path(path.to_path_buf())], 0);
    }
    let mut frontier: Vec<Expanded> = vec![Expanded::Path(PathBuf::new())];
    let mut extra = 0u32;
    // The part of the operand before its first glob component.
    let literal: PathBuf = path
        .components()
        .take_while(|c| !has_glob(&c.as_os_str().to_string_lossy()))
        .collect();
    for comp in path.components() {
        let name = comp.as_os_str().to_string_lossy().into_owned();
        let mut next = Vec::new();
        for item in frontier {
            let base = match item {
                Expanded::Path(base) => base,
                Expanded::Cant(base, why) => {
                    next.push(Expanded::Cant(base.join(comp), why));
                    continue;
                }
            };
            if !has_glob(&name) || matches!(comp, Component::RootDir | Component::Prefix(_)) {
                next.push(Expanded::Path(base.join(comp)));
                continue;
            }
            if w.fs.is_network(&base) {
                // Never list a network volume: the literal path stands (it is not read).
                next.push(Expanded::Path(base.join(comp)));
                continue;
            }
            // A privacy-guarded folder is listed only when the operand itself names a path
            // inside it (the session is working there), never from an outer glob.
            let base_key = key(&base);
            let guarded = w
                .tcc
                .iter()
                .zip(&w.tcc_keys)
                .any(|(f, fk)| base_key.starts_with(fk) && !may_enter(w, f, &literal));
            if guarded {
                next.push(Expanded::Cant(
                    base.join(comp),
                    "not counted: protected folder",
                ));
                continue;
            }
            let names = match w.fs.read_dir(&base) {
                Ok(names) => names,
                // The folder is not there: nothing matches.
                Err(e) if e.kind() == io::ErrorKind::NotFound => continue,
                Err(_) => {
                    next.push(Expanded::Cant(base.join(comp), "could not list the folder"));
                    continue;
                }
            };
            let mut hits: BTreeSet<OsString> = BTreeSet::new();
            for entry in names {
                if !w.tick() {
                    break;
                }
                let Ok(entry) = entry else { continue };
                let shown = entry.to_string_lossy();
                if shown.starts_with('.') && !name.starts_with('.') {
                    continue;
                }
                if glob_match(&name, &shown) {
                    hits.insert(entry);
                }
            }
            next.extend(hits.into_iter().map(|h| Expanded::Path(base.join(h))));
        }
        next.sort_by(|a, b| expanded_path(a).cmp(expanded_path(b)));
        if next.len() > MAX_GLOB_MATCHES {
            extra += (next.len() - MAX_GLOB_MATCHES) as u32;
            next.truncate(MAX_GLOB_MATCHES);
        }
        frontier = next;
    }
    if frontier.is_empty() {
        if w.spent {
            return (
                vec![Expanded::Cant(
                    path.to_path_buf(),
                    "listing stopped (too big or too slow)",
                )],
                0,
            );
        }
        return (vec![Expanded::Path(path.to_path_buf())], 0);
    }
    (frontier, extra)
}

/// May the walk go inside the protected folder `f` for an operand whose literal prefix is
/// `literal`? Only when the operand names a path inside it itself and the session's start
/// folder is inside it too (the session is working there).
fn may_enter(w: &Walker, f: &Path, literal: &Path) -> bool {
    within(literal, f) && w.env.cwd.as_deref().is_some_and(|cwd| within(cwd, f))
}

fn expanded_path(e: &Expanded) -> &Path {
    match e {
        Expanded::Path(p) | Expanded::Cant(p, _) => p,
    }
}

/// Is any folder above `path` a symlink? Looks at the folders only, each by
/// `symlink_metadata` (once per walk, and each look counts against the walk's budget),
/// never at a protected folder, and at most [`MAX_ANCESTORS`] of them. `None` when the
/// budget ran out before the answer was known.
fn through_a_link(w: &mut Walker, path: &Path) -> Option<bool> {
    let mut ancestor = path.parent();
    for _ in 0..MAX_ANCESTORS {
        let Some(dir) = ancestor else { break };
        if dir.parent().is_none() {
            break;
        }
        let is_link = match w.links.get(dir) {
            Some(known) => *known,
            None => {
                // `/var`, `/tmp` and `/etc` are the system's own links into `/private`.
                let system = ["/var", "/tmp", "/etc"].iter().any(|s| dir == Path::new(s));
                let is_link = if system || w.tcc_keys.contains(&key(dir)) {
                    false
                } else if !w.tick() {
                    return None;
                } else {
                    matches!(
                        w.fs.symlink_metadata(dir),
                        Ok(Meta {
                            kind: EntryKind::Symlink,
                            ..
                        })
                    )
                };
                w.links.insert(dir.to_path_buf(), is_link);
                is_link
            }
        };
        if is_link {
            return Some(true);
        }
        ancestor = dir.parent();
    }
    Some(false)
}

/// Most folders above one target that are checked for being links.
const MAX_ANCESTORS: usize = 64;

/// One target's line. The bool is true when the walk ran out of budget on it.
fn inspect(
    w: &mut Walker,
    spec: &TargetSpec,
    path: &Path,
    operand: &Path,
    relative: bool,
    trailing_slash: bool,
) -> (PreviewTargetWire, bool) {
    // Inside a protected folder (not the folder itself) the target is never stat'd unless
    // the operand and the session both are there.
    let literal: PathBuf = operand
        .components()
        .take_while(|c| !has_glob(&c.as_os_str().to_string_lossy()))
        .collect();
    let path_key = key(path);
    if w.tcc
        .iter()
        .zip(&w.tcc_keys)
        .any(|(f, fk)| path_key != *fk && path_key.starts_with(fk) && !may_enter(w, f, &literal))
    {
        let cant = cant_target(
            spec,
            &path.to_string_lossy(),
            "protected folder (not counted)",
        );
        return (cant, false);
    }
    let mut t = base_target(spec, path, relative);
    set_pure_flags(&mut t, path, w.env);
    if w.fs.is_network(path) {
        t.flags.push(PreviewFlag::Network);
        t.flags.push(PreviewFlag::NotCounted);
        return (t, false);
    }
    match through_a_link(w, path) {
        Some(false) => {}
        Some(true) => {
            let cant = cant_target(spec, &path.to_string_lossy(), "path goes through a link");
            return (cant, false);
        }
        None => {
            t.flags.push(PreviewFlag::NotCounted);
            return (t, true);
        }
    }
    let meta = match w.fs.symlink_metadata(path) {
        Ok(m) => m,
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            t.exists = Some(false);
            return (t, false);
        }
        Err(_) => {
            t.flags.push(PreviewFlag::Unreadable);
            return (t, false);
        }
    };
    if trailing_slash && meta.kind == EntryKind::Symlink {
        let cant = cant_target(
            spec,
            &path.to_string_lossy(),
            "a trailing slash follows the link",
        );
        return (cant, false);
    }
    t.exists = Some(true);
    t.kind = Some(match meta.kind {
        EntryKind::File => PreviewKind::File,
        EntryKind::Dir => PreviewKind::Dir,
        EntryKind::Symlink => PreviewKind::Symlink,
        EntryKind::Other => PreviewKind::Other,
    });
    match meta.kind {
        EntryKind::Symlink => t.flags.push(PreviewFlag::Symlink),
        EntryKind::File | EntryKind::Other => {
            t.files = Some(1);
            t.bytes = Some(meta.len);
        }
        EntryKind::Dir => {
            // A home-critical folder is flagged, not counted: the flag is the message.
            // A TCC-guarded folder that is itself the target is not opened either.
            if t.flags.contains(&PreviewFlag::HomeCritical) || w.tcc_keys.contains(&path_key) {
                t.flags.push(PreviewFlag::NotCounted);
                return (t, false);
            }
            if w.spent {
                t.flags.push(PreviewFlag::NotCounted);
                return (t, true);
            }
            let tally = count_dir(w, path, meta.dev);
            t.dirs = Some(tally.dirs);
            t.files = Some(tally.files);
            t.bytes = Some(tally.bytes);
            t.at_least = w.spent;
            for flag in tally.flags {
                if !t.flags.contains(&flag) {
                    t.flags.push(flag);
                }
            }
            return (t, w.spent);
        }
    }
    (t, false)
}

#[derive(Default)]
struct Tally {
    dirs: u64,
    files: u64,
    bytes: u64,
    flags: Vec<PreviewFlag>,
}

/// Count what is inside the directory `root` (not `root` itself), never following a
/// symlink and never leaving the device `dev`.
fn count_dir(w: &mut Walker, root: &Path, dev: u64) -> Tally {
    let mut tally = Tally::default();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let names = match w.fs.read_dir(&dir) {
            Ok(n) => n,
            Err(_) => {
                tally.flags.push(PreviewFlag::Unreadable);
                continue;
            }
        };
        for name in names {
            if !w.tick() {
                return tally;
            }
            let Ok(name) = name else {
                tally.flags.push(PreviewFlag::Unreadable);
                continue;
            };
            let path = dir.join(name);
            let meta = match w.fs.symlink_metadata(&path) {
                Ok(m) => m,
                Err(_) => {
                    tally.flags.push(PreviewFlag::Unreadable);
                    continue;
                }
            };
            match meta.kind {
                EntryKind::Dir => {
                    tally.dirs += 1;
                    if meta.dev != dev {
                        tally.flags.push(PreviewFlag::OtherVolume);
                    } else if w.fs.is_network(&path) {
                        tally.flags.push(PreviewFlag::Network);
                        tally.flags.push(PreviewFlag::NotCounted);
                    } else if w.tcc_keys.contains(&key(&path)) {
                        tally.flags.push(PreviewFlag::NotCounted);
                    } else {
                        stack.push(path);
                    }
                }
                EntryKind::Symlink | EntryKind::File | EntryKind::Other => {
                    tally.files += 1;
                    if meta.kind != EntryKind::Symlink {
                        tally.bytes += meta.len;
                    }
                }
            }
        }
    }
    tally
}

#[cfg(test)]
mod tests;
