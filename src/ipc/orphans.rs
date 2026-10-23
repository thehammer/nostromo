//! Children of the daemon that must not outlive it: a ledger of every CLI the
//! daemon spawns, the graceful stop used at shutdown, and the sweep that reaps
//! what a daemon that died without cleaning up left behind.
//!
//! The ledger is a small JSON file in the daemon's state dir (atomic write,
//! mode 0600). It holds, per CLI: pid, process-group id, start time, a
//! boot-unique marker and the program path. A clean exit removes it; a crash,
//! or a shutdown cut short, leaves it for the next start to [`sweep`].
//!
//! The sweep never kills on a pid alone. An entry is acted on only when the
//! pid is alive, still leads the recorded group, started when the record says
//! it did (within [`START_TIME_TOLERANCE_SECS`]) and its command line still
//! names the recorded program. Anything else is dropped without a signal.
//! Command text is never logged, only pids and group ids.

use std::collections::HashSet;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use tracing::{info, warn};

/// Whether every session's CLI leads its own process group, so a group signal
/// reaches the background servers and subagents it started. One switch, so the
/// behaviour can be reverted by flipping it (the ledger and sweep follow it).
pub const SESSIONS_LEAD_OWN_GROUP: bool = true;

/// How long, in total and across all children, a SIGTERM gets before SIGKILL.
pub const SHUTDOWN_GRACE: Duration = Duration::from_secs(3);

/// How far a live process's start time may differ from the recorded one and
/// still count as the same process.
pub const START_TIME_TOLERANCE_SECS: u64 = 5;

/// How long to wait for SIGKILLed children to be reaped.
pub const REAP_WAIT: Duration = Duration::from_millis(500);

const POLL: Duration = Duration::from_millis(20);
const LEDGER_VERSION: u32 = 1;
/// Env var each CLI inherits, so a human can tell which daemon boot owns it.
pub const MARKER_ENV: &str = "NOSTROMO_DAEMON_BOOT";

// ── records ──────────────────────────────────────────────────────────────────

/// One CLI the daemon spawned.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChildRecord {
    pub pid: u32,
    /// The process-group id (the pid itself when the child leads its group).
    pub pgid: u32,
    /// Whether the child was made leader of its own group at spawn.
    pub own_group: bool,
    /// Unix seconds when the child was spawned.
    pub started_at: u64,
    /// The daemon boot that spawned it.
    pub marker: String,
    /// The program that was executed (its command line must still contain it).
    pub program: String,
}

/// The file's content.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LedgerFile {
    pub version: u32,
    /// The daemon that wrote it. A previous daemon that is still alive owns
    /// its children: the sweep leaves them alone.
    pub daemon_pid: u32,
    pub children: Vec<ChildRecord>,
}

/// Where the ledger sits beside a session id store.
pub fn ledger_path_beside(store_path: &Path) -> PathBuf {
    store_path.with_file_name("child-processes.json")
}

/// A fresh boot-unique marker.
fn new_marker() -> String {
    uuid::Uuid::new_v4().simple().to_string()
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

// ── the ledger ───────────────────────────────────────────────────────────────

/// The running daemon's record of the CLIs it has spawned.
pub struct ChildLedger {
    path: PathBuf,
    marker: String,
    entries: Mutex<Vec<ChildRecord>>,
    /// Whether this ledger has written the file: a ledger that never did has
    /// no claim on a file it finds there (another daemon's).
    wrote: AtomicBool,
}

impl ChildLedger {
    /// A ledger writing to `path`. Nothing is written until a child is
    /// recorded, so the previous daemon's file can still be swept first.
    pub fn new(path: PathBuf) -> Self {
        Self {
            path,
            marker: new_marker(),
            entries: Mutex::new(Vec::new()),
            wrote: AtomicBool::new(false),
        }
    }

    /// This boot's marker.
    pub fn marker(&self) -> &str {
        &self.marker
    }

    /// Record a freshly spawned child.
    pub fn record(&self, pid: u32, own_group: bool, program: &Path) {
        let record = ChildRecord {
            pid,
            pgid: if own_group {
                pid
            } else {
                current_pgid_of(pid).unwrap_or(0)
            },
            own_group,
            started_at: unix_now(),
            marker: self.marker.clone(),
            program: program.to_string_lossy().into_owned(),
        };
        let mut entries = self.entries.lock().unwrap_or_else(|e| e.into_inner());
        entries.retain(|r| r.pid != pid);
        entries.push(record);
        self.persist(&entries);
    }

    /// Forget a child that has been stopped.
    pub fn forget(&self, pid: u32) {
        let mut entries = self.entries.lock().unwrap_or_else(|e| e.into_inner());
        let before = entries.len();
        entries.retain(|r| r.pid != pid);
        if entries.len() != before {
            self.persist(&entries);
        }
    }

    /// The daemon is exiting cleanly with nothing left running: remove the file.
    pub fn clear(&self) {
        let mut entries = self.entries.lock().unwrap_or_else(|e| e.into_inner());
        entries.clear();
        if !self.wrote.swap(false, Ordering::SeqCst) {
            return;
        }
        match std::fs::remove_file(&self.path) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => warn!("could not remove the child ledger: {e}"),
        }
    }

    fn persist(&self, entries: &[ChildRecord]) {
        self.wrote.store(true, Ordering::SeqCst);
        let file = LedgerFile {
            version: LEDGER_VERSION,
            daemon_pid: std::process::id(),
            children: entries.to_vec(),
        };
        if let Err(e) = write_ledger_file(&self.path, &file) {
            warn!("could not write the child ledger: {e}");
        }
    }
}

/// Write `file` to `path`: temp file in the same dir (0600), fsync, rename.
pub fn write_ledger_file(path: &Path, file: &LedgerFile) -> std::io::Result<()> {
    use std::os::unix::fs::OpenOptionsExt as _;
    let dir = path.parent().unwrap_or_else(|| Path::new("."));
    std::fs::create_dir_all(dir)?;
    let tmp = path.with_extension(format!("tmp-{}", std::process::id()));
    let bytes = serde_json::to_vec(file).map_err(std::io::Error::other)?;
    let result = (|| {
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&tmp)?;
        f.write_all(&bytes)?;
        f.sync_all()?;
        std::fs::rename(&tmp, path)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    result
}

/// Read a ledger file. Missing, unreadable, corrupt or of another version: `None`.
pub fn read_ledger_file(path: &Path) -> Option<LedgerFile> {
    let bytes = std::fs::read(path).ok()?;
    let file: LedgerFile = serde_json::from_slice(&bytes).ok()?;
    (file.version == LEDGER_VERSION).then_some(file)
}

// ── signals ──────────────────────────────────────────────────────────────────

/// What a signal is aimed at.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Target {
    /// A process group the daemon created (the group id is the leader's pid).
    Group(u32),
    /// A single process.
    Pid(u32),
}

impl Target {
    fn signal(self, sig: libc::c_int) {
        // SAFETY: plain syscalls; a stale id fails with ESRCH. `valid_id`
        // keeps pid 0 / 1 and our own group out of reach of a group signal.
        unsafe {
            match self {
                Target::Group(g) if valid_group(g) => {
                    libc::killpg(g as libc::pid_t, sig);
                }
                Target::Pid(p) if p > 1 => {
                    libc::kill(p as libc::pid_t, sig);
                }
                _ => {}
            }
        }
    }

    /// Whether anything is still there to signal. A zombie counts as there, so
    /// a child the daemon owns must be reaped (`try_wait`) before it is asked.
    pub fn exists(self) -> bool {
        // SAFETY: signal 0 only checks that the target can be signalled.
        let rc = unsafe {
            match self {
                Target::Group(g) if valid_group(g) => libc::killpg(g as libc::pid_t, 0),
                Target::Pid(p) if p > 1 => libc::kill(p as libc::pid_t, 0),
                _ => return false,
            }
        };
        rc == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
    }
}

/// A group id that is safe to hand to `killpg`: not 0/1 and not the daemon's own group.
fn valid_group(g: u32) -> bool {
    // SAFETY: getpgrp has no failure mode.
    g > 1 && g != unsafe { libc::getpgrp() } as u32
}

fn current_pgid_of(pid: u32) -> Option<u32> {
    // SAFETY: plain syscall.
    let g = unsafe { libc::getpgid(pid as libc::pid_t) };
    (g > 0).then_some(g as u32)
}

/// SIGTERM every target, wait up to `grace` in total for all of them to be
/// gone (as judged by `gone`, polled), then SIGKILL the ones still there.
/// `reap` is called on every poll so the caller can `try_wait` its children.
/// Returns the targets that needed SIGKILL.
pub fn terminate(targets: &[Target], grace: Duration, mut reap: impl FnMut()) -> Vec<Target> {
    for t in targets {
        t.signal(libc::SIGTERM);
    }
    let deadline = std::time::Instant::now() + grace;
    loop {
        reap();
        if targets.iter().all(|t| !t.exists()) || std::time::Instant::now() >= deadline {
            break;
        }
        std::thread::sleep(POLL);
    }
    let stragglers: Vec<Target> = targets.iter().copied().filter(|t| t.exists()).collect();
    for t in &stragglers {
        t.signal(libc::SIGKILL);
    }
    let reap_deadline = std::time::Instant::now() + REAP_WAIT;
    while !stragglers.is_empty() && std::time::Instant::now() < reap_deadline {
        reap();
        if stragglers.iter().all(|t| !t.exists()) {
            break;
        }
        std::thread::sleep(POLL);
    }
    stragglers
}

// ── sweep ────────────────────────────────────────────────────────────────────

/// What a sweep did.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct SweepReport {
    /// Pids whose group (or process) was signalled.
    pub terminated: Vec<u32>,
    /// Entries that did not verify (gone, reused, mismatched): dropped, not signalled.
    pub dropped: usize,
    /// The record was left alone because the daemon that wrote it is alive.
    pub previous_daemon_alive: bool,
}

/// Reap what the previous daemon's CLIs left running. Call once at startup,
/// before this daemon records anything. The file is removed afterwards.
pub fn sweep(path: &Path, grace: Duration) -> SweepReport {
    let mut report = SweepReport::default();
    let Some(file) = read_ledger_file(path) else {
        // Missing is the normal case; a corrupt file is no use to anyone.
        let _ = std::fs::remove_file(path);
        return report;
    };
    if file.daemon_pid != std::process::id()
        && file.daemon_pid > 1
        && Target::Pid(file.daemon_pid).exists()
    {
        // The daemon that wrote it is still running (or still shutting down):
        // its children are its own business, and its record stays.
        info!(
            daemon_pid = file.daemon_pid,
            "orphan sweep skipped: the previous daemon is still alive"
        );
        report.previous_daemon_alive = true;
        return report;
    }

    let mut targets = Vec::new();
    let mut seen = HashSet::new();
    for rec in &file.children {
        if !seen.insert(rec.pid) {
            continue;
        }
        match verified_target(rec) {
            Some(t) => {
                info!(
                    pid = rec.pid,
                    pgid = rec.pgid,
                    "orphan sweep: stopping a leftover session process"
                );
                report.terminated.push(rec.pid);
                targets.push(t);
            }
            None => {
                info!(
                    pid = rec.pid,
                    "orphan sweep: record does not match a live process, dropped"
                );
                report.dropped += 1;
            }
        }
    }
    if !targets.is_empty() {
        let killed = terminate(&targets, grace, || {});
        for t in killed {
            match t {
                Target::Group(g) => info!(pgid = g, "orphan sweep: SIGKILL after grace"),
                Target::Pid(p) => info!(pid = p, "orphan sweep: SIGKILL after grace"),
            }
        }
    }
    let _ = std::fs::remove_file(path);
    report
}

/// The target for `rec`, only if the live process is the one that was recorded.
fn verified_target(rec: &ChildRecord) -> Option<Target> {
    if rec.pid <= 1 || rec.pgid <= 1 || rec.program.trim().is_empty() {
        return None;
    }
    let Some(live_pgid) = current_pgid_of(rec.pid) else {
        return leaderless_group(rec);
    };
    if live_pgid != rec.pgid || (rec.own_group && rec.pgid != rec.pid) {
        return None;
    }
    let info = process_info(rec.pid)?;
    if !same_start(rec.started_at, info.elapsed_secs)
        || !command_names_program(&info.command, &rec.program)
    {
        return None;
    }
    Some(if rec.own_group {
        Target::Group(rec.pgid)
    } else {
        Target::Pid(rec.pid)
    })
}

/// The recorded CLI is gone but its group is not (background servers outlived
/// it, e.g. it exited when a dead daemon's pipes closed). The kernel does not
/// hand out a pid that is still in use as a group id, so a group that exists
/// under the recorded leader's id, while that pid does not, is the one the
/// daemon created, provided every member started after the record (no member
/// can predate its group's leader).
fn leaderless_group(rec: &ChildRecord) -> Option<Target> {
    if !rec.own_group || rec.pgid != rec.pid || !valid_group(rec.pgid) {
        return None;
    }
    let target = Target::Group(rec.pgid);
    if !target.exists() {
        return None;
    }
    let members = group_member_elapsed(rec.pgid)?;
    let all_after_record = !members.is_empty()
        && members
            .iter()
            .all(|e| unix_now().saturating_sub(*e) + START_TIME_TOLERANCE_SECS >= rec.started_at);
    all_after_record.then_some(target)
}

fn same_start(recorded: u64, elapsed: u64) -> bool {
    unix_now().saturating_sub(elapsed).abs_diff(recorded) <= START_TIME_TOLERANCE_SECS
}

/// Whether a process command line is the recorded program: it contains the
/// recorded path, or one of its first two words (the program, or an
/// interpreter and its script) has the same file name. The file name alone is
/// enough because a CLI may retitle itself (`claude`); the pid, group and
/// start-time checks are what pin the process down.
fn command_names_program(command: &str, program: &str) -> bool {
    if command.contains(program) {
        return true;
    }
    let Some(name) = Path::new(program)
        .file_name()
        .and_then(|n| n.to_str())
        .filter(|n| !n.is_empty())
    else {
        return false;
    };
    command
        .split_whitespace()
        .take(2)
        .any(|word| Path::new(word).file_name().and_then(|n| n.to_str()) == Some(name))
}

// ── process identity ─────────────────────────────────────────────────────────

struct ProcessInfo {
    elapsed_secs: u64,
    command: String,
}

/// Elapsed time and command line of `pid`, from `ps` (the same flags work on
/// macOS and Linux). `None` when it does not exist or `ps` cannot say.
fn process_info(pid: u32) -> Option<ProcessInfo> {
    let ps = ["/bin/ps", "/usr/bin/ps"]
        .into_iter()
        .find(|p| Path::new(p).exists())?;
    let out = Command::new(ps)
        .args([
            "-ww",
            "-o",
            "etime=",
            "-o",
            "command=",
            "-p",
            &pid.to_string(),
        ])
        .env("LC_ALL", "C")
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    parse_ps_line(&String::from_utf8_lossy(&out.stdout))
}

/// Elapsed seconds of every process in group `pgid`, from one `ps` listing.
fn group_member_elapsed(pgid: u32) -> Option<Vec<u64>> {
    let ps = ["/bin/ps", "/usr/bin/ps"]
        .into_iter()
        .find(|p| Path::new(p).exists())?;
    let out = Command::new(ps)
        .args(["-A", "-o", "pgid=", "-o", "etime="])
        .env("LC_ALL", "C")
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&out.stdout);
    let mut members = Vec::new();
    for line in text.lines() {
        let mut cols = line.split_whitespace();
        let (Some(g), Some(e)) = (cols.next(), cols.next()) else {
            continue;
        };
        if g.parse::<u32>().ok() == Some(pgid) {
            members.push(parse_etime(e)?);
        }
    }
    Some(members)
}

fn parse_ps_line(line: &str) -> Option<ProcessInfo> {
    let line = line.trim_start();
    let (etime, command) = line.split_once(char::is_whitespace)?;
    let command = command.trim();
    if command.is_empty() {
        return None;
    }
    Some(ProcessInfo {
        elapsed_secs: parse_etime(etime)?,
        command: command.to_owned(),
    })
}

/// `[[dd-]hh:]mm:ss`.
fn parse_etime(s: &str) -> Option<u64> {
    let (days, rest) = match s.split_once('-') {
        Some((d, r)) => (d.parse::<u64>().ok()?, r),
        None => (0, s),
    };
    let parts = rest
        .split(':')
        .map(|p| p.parse::<u64>().ok())
        .collect::<Option<Vec<_>>>()?;
    let secs = match parts.as_slice() {
        [m, s] => m * 60 + s,
        [h, m, s] => h * 3600 + m * 60 + s,
        _ => return None,
    };
    Some(days * 86_400 + secs)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn etime_formats() {
        assert_eq!(parse_etime("00:05"), Some(5));
        assert_eq!(parse_etime("12:34"), Some(754));
        assert_eq!(parse_etime("01:02:03"), Some(3723));
        assert_eq!(parse_etime("2-01:02:03"), Some(2 * 86_400 + 3723));
        assert_eq!(parse_etime("garbage"), None);
    }

    #[test]
    fn ps_line_splits_etime_from_command() {
        let info = parse_ps_line("   01:05 /bin/sh /tmp/a b\n").unwrap();
        assert_eq!(info.elapsed_secs, 65);
        assert_eq!(info.command, "/bin/sh /tmp/a b");
        assert!(parse_ps_line("").is_none());
    }

    #[test]
    fn command_matching_by_path_or_file_name() {
        assert!(command_names_program(
            "/usr/local/bin/claude -p --x",
            "/usr/local/bin/claude"
        ));
        assert!(command_names_program(
            "claude --resume",
            "/Users/me/.local/bin/claude"
        ));
        assert!(command_names_program(
            "node /opt/cli/claude --x",
            "/opt/cli/claude"
        ));
        assert!(!command_names_program(
            "vim claude-notes",
            "/Users/me/.local/bin/claude"
        ));
        assert!(!command_names_program(
            "/bin/sh -c claude",
            "/Users/me/.local/bin/claude"
        ));
        assert!(!command_names_program(
            "/bin/sh /tmp/other",
            "/bin/nonexistent-cli"
        ));
    }
}
