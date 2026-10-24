//! The terminal audit trail: `~/.nostromo/audit/terminal.jsonl`.
//!
//! One JSON object per line, appended only by the daemon. The directory is
//! `0700` and the file `0600`. At [`ROTATE_BYTES`] the file is renamed to
//! `terminal-<UTC yyyymmddThhmmss>.jsonl` and at most [`KEEP_ROTATED`] such
//! files are kept. Separate from the approvals audit store
//! (`src/approvals/audit.rs`): different retention and schema.
//!
//! [`AuditEvent`] is a closed, typed enum: no variant has a field that can
//! carry keystrokes, output, a selection or screen text.

use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use chrono::{DateTime, Utc};
use serde::Serialize;

use crate::ipc::protocol::TerminalKind;

/// Rotate the live file once it would grow past this.
pub const ROTATE_BYTES: u64 = 10 * 1024 * 1024;
/// How many rotated files are kept.
pub const KEEP_ROTATED: usize = 12;

const LIVE_STEM: &str = "terminal";
const SUFFIX: &str = ".jsonl";

/// The live file under the user's home: `~/.nostromo/audit/terminal.jsonl`.
pub fn default_path() -> PathBuf {
    dirs_next::home_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join(".nostromo")
        .join("audit")
        .join(format!("{LIVE_STEM}{SUFFIX}"))
}

/// Which way a refused terminal request came in.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum RefusalChannel {
    Mcp,
    Ipc,
    Tcp,
    AppControl,
}

impl RefusalChannel {
    /// The channel named by a `terminal_refusal_report`, if it is one we know.
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "mcp" => Some(Self::Mcp),
            "ipc" => Some(Self::Ipc),
            "tcp" => Some(Self::Tcp),
            "app_control" => Some(Self::AppControl),
            _ => None,
        }
    }
}

/// One audited terminal event (phase-1 events of the design's §D10).
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum AuditEvent {
    Opened {
        terminal_id: String,
        pane_id: String,
        tag: String,
        kind: TerminalKind,
        /// `user` or `focus`.
        requested_by: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        cwd: Option<String>,
    },
    Closed {
        terminal_id: String,
        pane_id: String,
        tag: String,
        kind: TerminalKind,
        /// `exited`, `user_closed`, `daemon_stopped`.
        reason: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        exit_code: Option<i32>,
    },
    Ended {
        terminal_id: String,
        pane_id: String,
        tag: String,
        kind: TerminalKind,
        #[serde(skip_serializing_if = "Option::is_none")]
        exit_code: Option<i32>,
    },
    Restarted {
        terminal_id: String,
        previous_terminal_id: String,
        pane_id: String,
        tag: String,
        kind: TerminalKind,
    },
    Refused {
        channel: RefusalChannel,
        /// The verb: `open`, `attach`, `input`, `resize`, `close`, `restart`, …
        op: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        code: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        terminal_id: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        focus: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        peer_pid: Option<i32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        peer_exe: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        tool: Option<String>,
    },
}

#[derive(Serialize)]
struct Line<'a> {
    ts: String,
    #[serde(flatten)]
    event: &'a AuditEvent,
}

/// The clock stamped on each line. Injectable for tests.
pub type Clock = Arc<dyn Fn() -> DateTime<Utc> + Send + Sync>;

/// Appends [`AuditEvent`]s to one JSONL file. Cheap to clone; clones share
/// the append lock.
#[derive(Clone)]
pub struct AuditLog {
    path: Option<PathBuf>,
    clock: Clock,
    rotate_bytes: u64,
    keep: usize,
    lock: Arc<Mutex<()>>,
}

impl std::fmt::Debug for AuditLog {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AuditLog")
            .field("path", &self.path)
            .finish()
    }
}

impl AuditLog {
    /// A log appending to `path`, creating its directory with mode `0700`.
    pub fn open(path: &Path) -> io::Result<Self> {
        let dir = path
            .parent()
            .ok_or_else(|| io::Error::other("audit path has no directory"))?;
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(dir)?;
        fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
        Ok(Self {
            path: Some(path.to_path_buf()),
            ..Self::disabled()
        })
    }

    /// A log that records nothing (tests and daemons without a home).
    pub fn disabled() -> Self {
        Self {
            path: None,
            clock: Arc::new(Utc::now),
            rotate_bytes: ROTATE_BYTES,
            keep: KEEP_ROTATED,
            lock: Arc::new(Mutex::new(())),
        }
    }

    pub fn with_clock(mut self, clock: Clock) -> Self {
        self.clock = clock;
        self
    }

    pub fn with_rotation(mut self, max_bytes: u64, keep: usize) -> Self {
        self.rotate_bytes = max_bytes;
        self.keep = keep;
        self
    }

    /// The live file, if this log records anything.
    pub fn path(&self) -> Option<&Path> {
        self.path.as_deref()
    }

    /// Append one event as one line, rotating first if the line would push
    /// the live file past the threshold.
    pub fn append(&self, event: &AuditEvent) -> io::Result<()> {
        let Some(path) = &self.path else {
            return Ok(());
        };
        let now = (self.clock)();
        let mut line = serde_json::to_vec(&Line {
            ts: now.to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
            event,
        })
        .map_err(io::Error::other)?;
        line.push(b'\n');

        let _guard = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        let current = fs::symlink_metadata(path).map(|m| m.len()).unwrap_or(0);
        if current > 0 && current + line.len() as u64 > self.rotate_bytes {
            self.rotate(path, now)?;
        }
        // O_NOFOLLOW: a symlink planted at the live path must not redirect it.
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(path)?;
        // The umask can only narrow the mode; this keeps an older file private too.
        file.set_permissions(fs::Permissions::from_mode(0o600))?;
        file.write_all(&line)
    }

    /// Move the live file aside under a timestamped name and drop the oldest
    /// rotated files beyond `keep`.
    fn rotate(&self, path: &Path, now: DateTime<Utc>) -> io::Result<()> {
        let dir = path.parent().unwrap_or_else(|| Path::new("."));
        let stamp = now.format("%Y%m%dT%H%M%S").to_string();
        let mut target = dir.join(format!("{LIVE_STEM}-{stamp}{SUFFIX}"));
        let mut n = 1;
        while target.exists() {
            target = dir.join(format!("{LIVE_STEM}-{stamp}-{n}{SUFFIX}"));
            n += 1;
        }
        fs::rename(path, &target)?;

        let mut rotated: Vec<((String, u32), PathBuf)> = fs::read_dir(dir)?
            .filter_map(|e| e.ok())
            .filter_map(|e| {
                let name = e.file_name().to_string_lossy().into_owned();
                rotated_order(&name).map(|key| (key, e.path()))
            })
            .collect();
        // Oldest first: by stamp, then by collision suffix.
        rotated.sort();
        let excess = rotated.len().saturating_sub(self.keep);
        for (_, old) in rotated.into_iter().take(excess) {
            let _ = fs::remove_file(old);
        }
        Ok(())
    }
}

/// `terminal-<stamp>[-N].jsonl` → `(stamp, N)` (0 without a suffix); `None`
/// for any other file.
fn rotated_order(name: &str) -> Option<(String, u32)> {
    let rest = name
        .strip_prefix(LIVE_STEM)?
        .strip_prefix('-')?
        .strip_suffix(SUFFIX)?;
    let (stamp, n) = match rest.split_once('-') {
        Some((stamp, n)) => (stamp, n.parse().ok()?),
        None => (rest, 0),
    };
    Some((stamp.to_string(), n))
}
