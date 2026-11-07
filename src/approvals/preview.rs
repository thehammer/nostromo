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

use std::collections::BTreeSet;
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
const NETWORK_ROOTS: [&str; 4] = ["/Volumes", "/Network", "/net", "/System/Volumes/Data/mnt"];

/// Is `path` under one of the network / external / automount roots?
pub fn is_network_path(path: &Path) -> bool {
    NETWORK_ROOTS.iter().any(|r| path.starts_with(r))
        || path.starts_with("/System/Volumes/Data/net")
        || path.starts_with("/System/Volumes/Data/home")
}

impl PreviewFs for RealFs {
    fn symlink_metadata(&self, path: &Path) -> io::Result<Meta> {
        use std::os::unix::fs::MetadataExt;
        let m = std::fs::symlink_metadata(path)?;
        let t = m.file_type();
        let kind = if t.is_symlink() {
            EntryKind::Symlink
        } else if t.is_dir() {
            EntryKind::Dir
        } else if t.is_file() {
            EntryKind::File
        } else {
            EntryKind::Other
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
        "Library/Mail",
        "Library/Messages",
        "Library/Safari",
        "Library/Containers",
        "Library/Group Containers",
        "Library/Mobile Documents",
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
    .any(|critical| critical.starts_with(path))
}

/// Walk state shared by every target of one preview.
struct Walker<'a> {
    fs: &'a dyn PreviewFs,
    env: &'a Env,
    tcc: Vec<PathBuf>,
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
    let mut w = Walker {
        fs,
        env,
        tcc: tcc_folders(&env.home),
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
            Operand::Path { path, relative } => {
                let (matches, extra) = expand_glob(&mut w, path);
                more = more.saturating_add(extra);
                for m in matches {
                    if targets.len() >= MAX_TARGETS {
                        more += 1;
                        continue;
                    }
                    let (t, hit_budget) = inspect(&mut w, spec, &m, *relative);
                    partial |= hit_budget;
                    targets.push(t);
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
            Operand::Path { path, relative } => {
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
    if env.cwd.as_deref().is_some_and(|cwd| !path.starts_with(cwd)) {
        t.flags.push(PreviewFlag::OutsideCwd);
    }
    if is_home_critical(path, &env.home) {
        t.flags.push(PreviewFlag::HomeCritical);
    }
}

/// Expand glob components of `path` against the file system. A path with no glob, or a
/// glob with no match, comes back as itself (what `rm` would then report). The second
/// value counts matches left out over [`MAX_GLOB_MATCHES`].
fn expand_glob(w: &mut Walker, path: &Path) -> (Vec<PathBuf>, u32) {
    if !path
        .components()
        .any(|c| has_glob(&c.as_os_str().to_string_lossy()))
    {
        return (vec![path.to_path_buf()], 0);
    }
    let mut frontier = vec![PathBuf::new()];
    let mut extra = 0u32;
    // The part of the operand before its first glob component.
    let literal: PathBuf = path
        .components()
        .take_while(|c| !has_glob(&c.as_os_str().to_string_lossy()))
        .collect();
    for comp in path.components() {
        let name = comp.as_os_str().to_string_lossy().into_owned();
        let mut next = Vec::new();
        for base in &frontier {
            if !has_glob(&name) || matches!(comp, Component::RootDir | Component::Prefix(_)) {
                next.push(base.join(comp));
                continue;
            }
            if w.fs.is_network(base) {
                // Never list a network volume: the literal path stands.
                next.push(base.join(comp));
                continue;
            }
            // A privacy-guarded folder is listed only when the operand itself names a path
            // inside it (the session is working there), never from an outer glob.
            let guarded = w
                .tcc
                .iter()
                .any(|f| base.starts_with(f) && !literal.starts_with(f));
            if guarded {
                next.push(base.join(comp));
                continue;
            }
            let Ok(names) = w.fs.read_dir(base) else {
                continue;
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
            next.extend(hits.into_iter().map(|h| base.join(h)));
        }
        next.sort();
        if next.len() > MAX_GLOB_MATCHES {
            extra += (next.len() - MAX_GLOB_MATCHES) as u32;
            next.truncate(MAX_GLOB_MATCHES);
        }
        frontier = next;
    }
    if frontier.is_empty() {
        return (vec![path.to_path_buf()], 0);
    }
    (frontier, extra)
}

/// One target's line. The bool is true when the walk ran out of budget on it.
fn inspect(
    w: &mut Walker,
    spec: &TargetSpec,
    path: &Path,
    relative: bool,
) -> (PreviewTargetWire, bool) {
    let mut t = base_target(spec, path, relative);
    set_pure_flags(&mut t, path, w.env);
    if w.fs.is_network(path) {
        t.flags.push(PreviewFlag::Network);
        t.flags.push(PreviewFlag::NotCounted);
        return (t, false);
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
            if t.flags.contains(&PreviewFlag::HomeCritical) || w.tcc.iter().any(|f| f == path) {
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
                    } else if w.tcc.iter().any(|f| f == &path) {
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
