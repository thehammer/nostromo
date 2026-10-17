//! The approvals audit store (design contract §7): append-only JSONL.
//!
//! - Directory mode 0700; daily files `audit-YYYY-MM-DD.jsonl` (UTC date of
//!   the entry's `ts`), mode 0600.
//! - One JSON object per line, appended under `flock(LOCK_EX)` with a single
//!   `write_all` plus `sync_data`. The `nostromo-guard` hook process and the
//!   daemon both append.
//! - No API deletes or edits a single entry. [`AuditLog::sweep`] deletes whole
//!   files older than [`RETENTION_DAYS`].

use std::fs::{File, OpenOptions};
use std::io::{self, Write};
use std::ops::Range;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};

use chrono::{DateTime, NaiveDate, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Entry format version.
pub const ENTRY_VERSION: u32 = 1;

/// Files dated more than this many days before `now` are deleted by `sweep`.
pub const RETENTION_DAYS: i64 = 90;

/// Longest string (bytes) the audit log records from a blocked tool input; longer ones
/// are cut at a character boundary and end with a `[truncated …]` note.
pub const MAX_RECORDED_STRING_BYTES: usize = 16 * 1024;

/// `input` as the audit log records it: every string with invisible and bidi
/// characters shown as `⟨U+202E⟩` (a newline or tab stays) and cut at
/// [`MAX_RECORDED_STRING_BYTES`]. Object keys are left as they are.
pub fn sanitize_recorded(input: &Value) -> Value {
    match input {
        Value::String(s) => Value::String(sanitize_string(s)),
        Value::Array(items) => Value::Array(items.iter().map(sanitize_recorded).collect()),
        Value::Object(map) => Value::Object(map.iter().map(|(k, v)| (k.clone(), sanitize_recorded(v))).collect()),
        other => other.clone(),
    }
}

/// One string as [`sanitize_recorded`] records it.
pub fn sanitize_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len().min(MAX_RECORDED_STRING_BYTES + 16));
    let mut cut = false;
    for c in s.chars() {
        let shown = if crate::data::work::is_invisible(c) && !matches!(c, '\n' | '\t') {
            format!("\u{27E8}U+{:04X}\u{27E9}", c as u32)
        } else {
            c.to_string()
        };
        if out.len() + shown.len() > MAX_RECORDED_STRING_BYTES {
            cut = true;
            break;
        }
        out.push_str(&shown);
    }
    if cut {
        out.push_str("\u{2026}[truncated]");
    }
    out
}

/// One audit line.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Entry {
    pub v: u32,
    pub id: String,
    pub ts: DateTime<Utc>,
    #[serde(flatten)]
    pub event: Event,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tag: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_use_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subagent: Option<Value>,
}

impl Entry {
    /// A fresh v1 entry: new UUID id, `ts = now`, no identity fields.
    pub fn new(event: Event, now: DateTime<Utc>) -> Self {
        Self {
            v: ENTRY_VERSION,
            id: uuid::Uuid::new_v4().to_string(),
            ts: now,
            event,
            request_id: None,
            tag: None,
            session_id: None,
            tool_use_id: None,
            agent: None,
            subagent: None,
        }
    }
}

/// What happened. Serialized as `"event": "<snake_case>"` beside the
/// variant's fields. Only `GuardBlocked` is written in AP0g; the other shapes
/// are fixed now so the file format doesn't churn.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum Event {
    Request {
        tool_name: String,
        input: Value,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        display_text: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reason: Option<Value>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        flags: Option<Value>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        options: Option<Value>,
        /// The CLI's `request` object, exactly as received (every field it sent).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cli_request: Option<Value>,
    },
    Outcome {
        outcome: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        rule: Option<Value>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        by_window: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        latency_ms: Option<u64>,
        /// The watchdog ended the request: the normal path had not answered in time.
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        watchdog: bool,
    },
    Refusal {
        refusal_code: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        peer: Option<Value>,
    },
    GuardBlocked {
        tool_name: String,
        /// The full tool input, exactly as received.
        input: Value,
        /// The guard rule id that matched.
        rule: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        detail: Option<String>,
    },
    SessionRuleGranted {
        rule: Value,
    },
    SessionRuleRevoked {
        rule: Value,
    },
    RuleWritten {
        rule: Value,
    },
    RuleRemoved {
        rule: Value,
    },
}

impl Event {
    /// The `event` tag string, e.g. `"guard_blocked"`.
    pub fn kind(&self) -> &'static str {
        match self {
            Event::Request { .. } => "request",
            Event::Outcome { .. } => "outcome",
            Event::Refusal { .. } => "refusal",
            Event::GuardBlocked { .. } => "guard_blocked",
            Event::SessionRuleGranted { .. } => "session_rule_granted",
            Event::SessionRuleRevoked { .. } => "session_rule_revoked",
            Event::RuleWritten { .. } => "rule_written",
            Event::RuleRemoved { .. } => "rule_removed",
        }
    }
}

/// Which entries [`AuditLog::read`] returns. Empty fields match everything.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AuditFilter {
    /// Only this focus tag.
    pub tag: Option<String>,
    /// Only this event kind (an [`Event::kind`] string).
    pub event: Option<String>,
}

/// The audit store rooted at one directory.
#[derive(Debug, Clone)]
pub struct AuditLog {
    dir: PathBuf,
}

impl AuditLog {
    /// Open (creating with mode 0700 if needed) the store at `dir`.
    pub fn open(dir: &Path) -> io::Result<Self> {
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
        // An existing directory is tightened too: the log holds full tool inputs.
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;
        Ok(Self { dir: dir.to_path_buf() })
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// The file an entry stamped `ts` goes to.
    pub fn file_for(&self, ts: DateTime<Utc>) -> PathBuf {
        self.dir.join(format!("{FILE_PREFIX}{}{FILE_SUFFIX}", ts.format("%Y-%m-%d")))
    }

    /// Append one entry as one line (flock, one write, sync).
    pub fn append(&self, entry: &Entry) -> io::Result<()> {
        let mut line = serde_json::to_vec(entry).map_err(io::Error::other)?;
        line.push(b'\n');
        // O_NOFOLLOW: a symlink planted at today's file must not carry the entry somewhere else.
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(self.file_for(entry.ts))?;
        // The umask can only narrow the mode; this keeps a pre-existing file private too.
        file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
        let _lock = FileLock::exclusive(&file)?;
        (&file).write_all(&line)?;
        file.sync_data()
    }

    /// Entries with `range.start <= ts < range.end` matching `filter`, oldest
    /// first. Lines that don't parse are skipped.
    pub fn read(&self, range: Range<DateTime<Utc>>, filter: &AuditFilter) -> io::Result<Vec<Entry>> {
        let mut files: Vec<(NaiveDate, PathBuf)> = self.daily_files()?;
        files.sort();
        let (first, last) = (range.start.date_naive(), range.end.date_naive());
        let mut out = Vec::new();
        for (date, path) in files {
            if date < first || date > last {
                continue;
            }
            let text = std::fs::read_to_string(&path)?;
            out.extend(
                text.lines()
                    .filter_map(|l| serde_json::from_str::<Entry>(l).ok())
                    .filter(|e| range.contains(&e.ts))
                    .filter(|e| filter.tag.as_ref().is_none_or(|t| e.tag.as_ref() == Some(t)))
                    .filter(|e| filter.event.as_ref().is_none_or(|k| e.event.kind() == k)),
            );
        }
        out.sort_by_key(|e| e.ts);
        Ok(out)
    }

    /// Delete the daily files dated more than [`RETENTION_DAYS`] days before
    /// `now`. Returns how many were deleted.
    pub fn sweep(&self, now: DateTime<Utc>) -> io::Result<usize> {
        let cutoff = now.date_naive() - chrono::Duration::days(RETENTION_DAYS);
        let mut deleted = 0;
        for (date, path) in self.daily_files()? {
            if date < cutoff {
                std::fs::remove_file(path)?;
                deleted += 1;
            }
        }
        Ok(deleted)
    }

    /// Every `audit-YYYY-MM-DD.jsonl` in the directory, with its date.
    fn daily_files(&self) -> io::Result<Vec<(NaiveDate, PathBuf)>> {
        let mut out = Vec::new();
        for entry in std::fs::read_dir(&self.dir)? {
            let path = entry?.path();
            let date = path
                .file_name()
                .and_then(|n| n.to_str())
                .and_then(|n| n.strip_prefix(FILE_PREFIX)?.strip_suffix(FILE_SUFFIX))
                .and_then(|d| NaiveDate::parse_from_str(d, "%Y-%m-%d").ok());
            if let Some(date) = date {
                out.push((date, path));
            }
        }
        Ok(out)
    }
}

const FILE_PREFIX: &str = "audit-";
const FILE_SUFFIX: &str = ".jsonl";

/// An exclusive `flock` held until drop.
struct FileLock<'a>(&'a File);

impl<'a> FileLock<'a> {
    fn exclusive(file: &'a File) -> io::Result<Self> {
        loop {
            // SAFETY: flock(2) on a descriptor we own for the lock's lifetime.
            if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } == 0 {
                return Ok(Self(file));
            }
            let err = io::Error::last_os_error();
            if err.kind() != io::ErrorKind::Interrupted {
                return Err(err);
            }
        }
    }
}

impl Drop for FileLock<'_> {
    fn drop(&mut self) {
        // SAFETY: as above.
        unsafe {
            libc::flock(self.0.as_raw_fd(), libc::LOCK_UN);
        }
    }
}
