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
use std::io::{self, BufRead, BufReader, Read, Write};
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

/// A line longer than this in an audit file is skipped by readers without being held
/// in memory: no entry is this long (a request's input is capped well below it).
const MAX_ENTRY_LINE_BYTES: usize = 32 * 1024 * 1024;

/// `input` as the audit log records it: every string with invisible and bidi
/// characters shown as `⟨U+202E⟩` (a newline or tab stays) and cut at
/// [`MAX_RECORDED_STRING_BYTES`]. Object keys are left as they are.
pub fn sanitize_recorded(input: &Value) -> Value {
    match input {
        Value::String(s) => Value::String(sanitize_string(s)),
        Value::Array(items) => Value::Array(items.iter().map(sanitize_recorded).collect()),
        Value::Object(map) => Value::Object(
            map.iter()
                .map(|(k, v)| (k.clone(), sanitize_recorded(v)))
                .collect(),
        ),
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
        /// For a report of a refused synthetic input: how it arrived
        /// (`app_control`, `accessibility`, `unknown`).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        channel: Option<String>,
        /// For such a report: which control it was aimed at.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        control: Option<String>,
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
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(dir)?;
        // An existing directory is tightened too: the log holds full tool inputs.
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;
        Ok(Self {
            dir: dir.to_path_buf(),
        })
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// The file an entry stamped `ts` goes to.
    pub fn file_for(&self, ts: DateTime<Utc>) -> PathBuf {
        self.dir.join(format!(
            "{FILE_PREFIX}{}{FILE_SUFFIX}",
            ts.format("%Y-%m-%d")
        ))
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
    pub fn read(
        &self,
        range: Range<DateTime<Utc>>,
        filter: &AuditFilter,
    ) -> io::Result<Vec<Entry>> {
        let mut out = Vec::new();
        self.for_each(range, filter, |e| out.push(e))?;
        out.sort_by_key(|e| e.ts);
        Ok(out)
    }

    /// Call `f` for each entry [`Self::read`] would return, file by file and line by
    /// line (a file is never read whole), in file order rather than sorted. Lines
    /// that are not an entry (not UTF-8, not JSON, over [`MAX_ENTRY_LINE_BYTES`]) are skipped.
    pub fn for_each(
        &self,
        range: Range<DateTime<Utc>>,
        filter: &AuditFilter,
        mut f: impl FnMut(Entry),
    ) -> io::Result<()> {
        let mut files: Vec<(NaiveDate, PathBuf)> = self.daily_files()?;
        files.sort();
        let (first, last) = (range.start.date_naive(), range.end.date_naive());
        for (date, path) in files {
            if date < first || date > last {
                continue;
            }
            for_each_line(&path, |line| {
                let Ok(entry) = serde_json::from_slice::<Entry>(line) else {
                    return;
                };
                if range.contains(&entry.ts)
                    && filter
                        .tag
                        .as_ref()
                        .is_none_or(|t| entry.tag.as_ref() == Some(t))
                    && filter
                        .event
                        .as_ref()
                        .is_none_or(|k| entry.event.kind() == k)
                {
                    f(entry);
                }
            })?;
        }
        Ok(())
    }

    /// Delete the daily files dated more than [`RETENTION_DAYS`] days before
    /// `now`. A file that cannot be deleted does not stop the rest: every one is
    /// tried, and the first error is returned after the last. `Ok` is how many were deleted.
    pub fn sweep(&self, now: DateTime<Utc>) -> io::Result<usize> {
        let cutoff = now.date_naive() - chrono::Duration::days(RETENTION_DAYS);
        let mut deleted = 0;
        let mut first_error = None;
        for (date, path) in self.daily_files()? {
            if date < cutoff {
                match std::fs::remove_file(&path) {
                    Ok(()) => deleted += 1,
                    Err(e) => {
                        tracing::warn!("could not delete {}: {e}", path.display());
                        first_error.get_or_insert(e);
                    }
                }
            }
        }
        match first_error {
            Some(e) => Err(e),
            None => Ok(deleted),
        }
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

// ── the read-only query layer (AP5) ─────────────────────────────────────────

/// The most rows one page returns.
pub const MAX_PAGE_ROWS: usize = 500;
/// An outcome comes at most the approval timeout plus the watchdog grace after its request.
const OUTCOME_LOOKAHEAD_MS: i64 = 60 * 60 * 1000;
/// Longest row summary, in characters.
const MAX_SUMMARY_CHARS: usize = 200;

/// The outcome filter groups the Approvals window offers.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OutcomeFilter {
    Allowed,
    Denied,
    /// Timed out, no app, withdrawn, cancelled, restarted: nobody answered.
    TimedOut,
    GuardBlocked,
    Refused,
    Rules,
}

impl OutcomeFilter {
    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "allowed" => Self::Allowed,
            "denied" => Self::Denied,
            "timed_out" => Self::TimedOut,
            "guard_blocked" => Self::GuardBlocked,
            "refused" => Self::Refused,
            "rules" => Self::Rules,
            _ => return None,
        })
    }

    fn matches(self, kind: RowKind, outcome: Option<&str>) -> bool {
        match self {
            Self::Refused => kind == RowKind::Refusal,
            Self::Rules => kind == RowKind::Rule,
            Self::GuardBlocked => kind == RowKind::GuardBlocked || outcome == Some("guard_blocked"),
            Self::Allowed => {
                kind == RowKind::Request
                    && outcome.is_some_and(|o| o.starts_with("allowed_") || o == "answered")
            }
            Self::Denied => {
                kind == RowKind::Request
                    && matches!(
                        outcome,
                        Some("denied" | "denied_and_stopped" | "deny_write_failed")
                    )
            }
            Self::TimedOut => {
                kind == RowKind::Request
                    && matches!(
                        outcome,
                        Some(
                            "timed_out"
                                | "no_app"
                                | "approval_unavailable"
                                | "restart"
                                | "restart_crash"
                                | "withdrawn"
                                | "cancelled"
                                | "request_unparseable"
                                | "invalid_request"
                                | "too_large"
                        )
                    )
            }
        }
    }
}

/// What kind of row this is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RowKind {
    Request,
    Refusal,
    GuardBlocked,
    Rule,
    /// An event kind this build does not know: shown generically.
    Other,
}

/// One query of the log. Newest first.
#[derive(Debug, Clone, Default)]
pub struct LogQuery {
    pub tag: Option<String>,
    pub outcome: Option<OutcomeFilter>,
    pub since: Option<DateTime<Utc>>,
    /// Clamped to `1..=`[`MAX_PAGE_ROWS`].
    pub limit: usize,
    pub cursor: Option<String>,
}

/// Why a query failed.
#[derive(Debug)]
pub enum LogError {
    BadCursor,
    Io(io::Error),
}

impl From<io::Error> for LogError {
    fn from(e: io::Error) -> Self {
        Self::Io(e)
    }
}

impl std::fmt::Display for LogError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::BadCursor => f.write_str("malformed cursor"),
            Self::Io(e) => write!(f, "{e}"),
        }
    }
}

impl std::error::Error for LogError {}

/// One row of the log: a request merged with its outcome, or one standalone entry.
/// It holds no full input; see [`AuditLog::entry_detail`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LogRow {
    pub row_id: String,
    pub kind: RowKind,
    pub ts: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tag: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_use_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
    pub entry_ids: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subagent: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_name: Option<String>,
    pub summary: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub outcome: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub by_window: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub latency_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub refusal_code: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rule_label: Option<String>,
}

impl LogRow {
    /// The cursor that makes the next query start just after this row.
    pub fn cursor(&self) -> String {
        encode_cursor(self.ts.timestamp_millis(), &self.row_id)
    }

    fn sort_key(&self) -> (i64, &str) {
        (self.ts.timestamp_millis(), self.row_id.as_str())
    }
}

/// A page of rows, newest first.
#[derive(Debug, Clone, PartialEq)]
pub struct LogPage {
    pub rows: Vec<LogRow>,
    pub next_cursor: Option<String>,
}

/// What a query scan cost, for tests that hold it to its bound.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ScanStats {
    /// The most rows held at once while scanning (before any trim).
    pub peak_rows_held: usize,
}

/// One entry in full, as the Approvals window expands it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LogDetail {
    pub id: String,
    pub kind: RowKind,
    pub event: String,
    pub ts: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tag: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_name: Option<String>,
    /// The full input exactly as recorded.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub display_text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub flags: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub options: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cli_request: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub outcome: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub by_window: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub latency_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rule: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub refusal_code: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub peer: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub channel: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub control: Option<String>,
}

/// An opaque cursor: base64 of `ts_ms` and `row_id`.
pub fn encode_cursor(ts_ms: i64, row_id: &str) -> String {
    use base64::Engine as _;
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(format!("{ts_ms}:{row_id}"))
}

fn decode_cursor(cursor: &str) -> Result<(i64, String), LogError> {
    use base64::Engine as _;
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(cursor)
        .map_err(|_| LogError::BadCursor)?;
    let text = String::from_utf8(bytes).map_err(|_| LogError::BadCursor)?;
    let (ts, id) = text.split_once(':').ok_or(LogError::BadCursor)?;
    Ok((ts.parse().map_err(|_| LogError::BadCursor)?, id.to_owned()))
}

/// One audit line in the lenient shape the query layer reads: any event kind parses.
#[derive(Debug, Deserialize)]
struct RawEntry {
    id: String,
    ts: DateTime<Utc>,
    event: String,
    #[serde(default)]
    request_id: Option<String>,
    #[serde(default)]
    tag: Option<String>,
    #[serde(default)]
    session_id: Option<String>,
    #[serde(default)]
    tool_use_id: Option<String>,
    #[serde(default)]
    agent: Option<String>,
    #[serde(default)]
    subagent: Option<Value>,
    #[serde(default)]
    tool_name: Option<String>,
    #[serde(default)]
    input: Option<Value>,
    #[serde(default)]
    display_text: Option<String>,
    #[serde(default)]
    reason: Option<Value>,
    #[serde(default)]
    flags: Option<Value>,
    #[serde(default)]
    options: Option<Value>,
    #[serde(default)]
    cli_request: Option<Value>,
    #[serde(default)]
    outcome: Option<String>,
    #[serde(default)]
    by_window: Option<String>,
    #[serde(default)]
    latency_ms: Option<u64>,
    #[serde(default)]
    rule: Option<Value>,
    #[serde(default)]
    detail: Option<String>,
    #[serde(default)]
    refusal_code: Option<String>,
    #[serde(default)]
    peer: Option<Value>,
    #[serde(default)]
    channel: Option<String>,
    #[serde(default)]
    control: Option<String>,
}

/// The cheap first-pass shape: just what an outcome needs.
#[derive(Debug, Deserialize)]
struct Probe {
    id: String,
    ts: DateTime<Utc>,
    event: String,
    #[serde(default)]
    request_id: Option<String>,
    #[serde(default)]
    outcome: Option<String>,
    #[serde(default)]
    by_window: Option<String>,
    #[serde(default)]
    latency_ms: Option<u64>,
}

#[derive(Debug, Clone)]
struct OutcomeInfo {
    entry_id: String,
    ts: DateTime<Utc>,
    outcome: String,
    by_window: Option<String>,
    latency_ms: Option<u64>,
}

impl RawEntry {
    fn row_kind(&self) -> RowKind {
        match self.event.as_str() {
            "request" | "outcome" => RowKind::Request,
            "refusal" => RowKind::Refusal,
            "guard_blocked" => RowKind::GuardBlocked,
            "session_rule_granted" | "session_rule_revoked" | "rule_written" | "rule_removed" => {
                RowKind::Rule
            }
            _ => RowKind::Other,
        }
    }

    fn base_row(&self, row_id: String) -> LogRow {
        LogRow {
            row_id,
            kind: self.row_kind(),
            ts: self.ts,
            tag: self.tag.clone(),
            session_id: self.session_id.clone(),
            tool_use_id: self.tool_use_id.clone(),
            request_id: self.request_id.clone(),
            entry_ids: vec![self.id.clone()],
            agent: self.agent.clone(),
            subagent: self.subagent.clone(),
            tool_name: self.tool_name.clone(),
            summary: String::new(),
            outcome: None,
            by_window: None,
            latency_ms: None,
            refusal_code: None,
            rule_label: None,
        }
    }

    /// The row for a non-outcome entry (an outcome is merged or becomes an orphan row).
    fn to_row(&self) -> LogRow {
        match self.event.as_str() {
            "request" => {
                let mut row =
                    self.base_row(self.request_id.clone().unwrap_or_else(|| self.id.clone()));
                row.summary = self
                    .display_text
                    .as_deref()
                    .map(one_line)
                    .filter(|s| !s.is_empty())
                    .or_else(|| self.input.as_ref().map(summarize_input))
                    .unwrap_or_default();
                row
            }
            "guard_blocked" => {
                let mut row = self.base_row(self.id.clone());
                row.summary = self.input.as_ref().map(summarize_input).unwrap_or_default();
                row.outcome = Some("guard_blocked".to_owned());
                row.rule_label = Some(match self.detail.as_deref().map(one_line) {
                    Some(d) if !d.is_empty() => format!("{} ({d})", self.rule_id()),
                    _ => self.rule_id(),
                });
                row
            }
            "refusal" => {
                let mut row = self.base_row(self.id.clone());
                row.refusal_code = self.refusal_code.clone();
                let mut parts = vec![self.refusal_code.clone().unwrap_or_default()];
                parts.extend(self.channel.clone());
                parts.extend(self.control.clone());
                row.summary = one_line(&parts.join(" · "));
                row
            }
            "session_rule_granted" | "session_rule_revoked" | "rule_written" | "rule_removed" => {
                let mut row = self.base_row(self.id.clone());
                let label = self
                    .rule
                    .as_ref()
                    .and_then(|r| r.get("rule_text"))
                    .and_then(Value::as_str)
                    .map(one_line);
                row.rule_label = label.clone();
                row.summary = format!(
                    "{}{}",
                    self.event.replace('_', " "),
                    label.map(|l| format!(": {l}")).unwrap_or_default()
                );
                row.summary = cap_chars(&row.summary);
                row
            }
            _ => {
                let mut row = self.base_row(self.id.clone());
                row.summary = cap_chars(&one_line(&self.event));
                row
            }
        }
    }

    /// An outcome with no request in the log.
    fn to_orphan_row(&self) -> LogRow {
        let mut row = self.base_row(self.id.clone());
        row.summary = "(request not in the log)".to_owned();
        row.outcome = self.outcome.clone();
        row.by_window = self.by_window.clone();
        row.latency_ms = self.latency_ms;
        row
    }

    /// `rule` of a guard block is its rule id (a string), kept in `GuardBlocked::rule`
    /// which this lenient shape reads from `rule`.
    fn rule_id(&self) -> String {
        match &self.rule {
            Some(Value::String(s)) => one_line(s),
            Some(other) => one_line(&other.to_string()),
            None => String::new(),
        }
    }

    fn detail(&self) -> LogDetail {
        LogDetail {
            id: self.id.clone(),
            kind: self.row_kind(),
            event: self.event.clone(),
            ts: self.ts,
            tag: self.tag.clone(),
            request_id: self.request_id.clone(),
            tool_name: self.tool_name.clone(),
            input: self.input.clone(),
            display_text: self.display_text.clone(),
            reason: self.reason.clone(),
            flags: self.flags.clone(),
            options: self.options.clone(),
            cli_request: self.cli_request.clone(),
            outcome: self.outcome.clone(),
            by_window: self.by_window.clone(),
            latency_ms: self.latency_ms,
            rule: self.rule.clone(),
            detail: self.detail.clone(),
            refusal_code: self.refusal_code.clone(),
            peer: self.peer.clone(),
            channel: self.channel.clone(),
            control: self.control.clone(),
        }
    }
}

fn one_line(s: &str) -> String {
    cap_chars(&sanitize_string(s).replace(['\n', '\r', '\t'], " "))
}

fn cap_chars(s: &str) -> String {
    if s.chars().count() <= MAX_SUMMARY_CHARS {
        return s.to_owned();
    }
    let mut out: String = s.chars().take(MAX_SUMMARY_CHARS - 1).collect();
    out.push('\u{2026}');
    out
}

/// A one-line summary of a tool input: its command, path or url, else compact JSON.
fn summarize_input(input: &Value) -> String {
    const KEYS: [&str; 8] = [
        "command",
        "file_path",
        "path",
        "url",
        "pattern",
        "query",
        "description",
        "prompt",
    ];
    if let Value::String(s) = input {
        return one_line(s);
    }
    for key in KEYS {
        if let Some(Value::String(s)) = input.get(key) {
            return one_line(s);
        }
    }
    one_line(&input.to_string())
}

impl AuditLog {
    /// One page of the log, newest first (see the module's design notes in
    /// [`LogQuery`]). Read-only: nothing here writes or deletes.
    ///
    /// A request and its outcome (same `request_id`) are one row stamped with the
    /// request's time, even across a UTC day boundary: the outcome is looked for in
    /// the files up to an hour after the request. Every other entry is a row of its
    /// own, including an event kind this build does not know.
    pub fn query(&self, q: &LogQuery, now: DateTime<Utc>) -> Result<LogPage, LogError> {
        self.query_with_stats(q, now).map(|(page, _)| page)
    }

    /// [`Self::query`], also reporting what the scan held ([`ScanStats`]).
    pub fn query_with_stats(
        &self,
        q: &LogQuery,
        now: DateTime<Utc>,
    ) -> Result<(LogPage, ScanStats), LogError> {
        let limit = q.limit.clamp(1, MAX_PAGE_ROWS);
        let cursor = q.cursor.as_deref().map(decode_cursor).transpose()?;
        let retention_cutoff = now.date_naive() - chrono::Duration::days(RETENTION_DAYS);
        let scan_floor = q
            .since
            .map(|s| (s - chrono::Duration::milliseconds(OUTCOME_LOOKAHEAD_MS)).date_naive());
        let newest = cursor.as_ref().and_then(|(ts_ms, _)| {
            DateTime::<Utc>::from_timestamp_millis(ts_ms.saturating_add(OUTCOME_LOOKAHEAD_MS))
                .map(|t| t.date_naive())
        });

        let mut files = self.daily_files()?;
        files.sort_by_key(|f| std::cmp::Reverse(f.0));
        files.retain(|(d, _)| {
            *d >= retention_cutoff
                && scan_floor.is_none_or(|f| *d >= f)
                && newest.is_none_or(|n| *d <= n)
        });

        let want = limit + 1;
        let mut outcomes: std::collections::HashMap<String, OutcomeInfo> = Default::default();
        let mut orphans_no_request: Vec<OutcomeInfo> = Vec::new();
        let mut orphan_raws: std::collections::HashMap<String, RawEntry> = Default::default();
        let mut seen_requests: std::collections::HashSet<String> = Default::default();
        let mut rows: Vec<LogRow> = Vec::new();
        let mut stopped_at: Option<NaiveDate> = None;
        let mut stats = ScanStats::default();

        let accepts = |row: &LogRow| -> bool {
            q.since.is_none_or(|s| row.ts >= s)
                && q.tag.as_ref().is_none_or(|t| row.tag.as_ref() == Some(t))
                && q.outcome
                    .is_none_or(|f| f.matches(row.kind, row.outcome.as_deref()))
                && cursor
                    .as_ref()
                    .is_none_or(|(ts, id)| row.sort_key() < (*ts, id.as_str()))
        };

        for (date, path) in &files {
            // This file's request ids: an outcome follows its request in the file, so one
            // whose request is already in hand is merged and dropped, and only outcomes
            // still waiting for a request (an older file's) are carried on.
            let mut seen_here: std::collections::HashSet<String> = Default::default();
            // Pass 1: this file's outcomes. A line that never says "outcome" is not one,
            // so most lines are skipped without a parse.
            for_each_line(path, |line| {
                if !contains_bytes(line, b"outcome") {
                    return;
                }
                let Ok(p) = serde_json::from_slice::<Probe>(line) else {
                    return;
                };
                if p.event != "outcome" {
                    return;
                }
                let info = OutcomeInfo {
                    entry_id: p.id,
                    ts: p.ts,
                    outcome: p.outcome.unwrap_or_default(),
                    by_window: p.by_window,
                    latency_ms: p.latency_ms,
                };
                match p.request_id {
                    Some(rid) => {
                        let newer = outcomes.get(&rid).is_none_or(|o| o.ts <= info.ts);
                        if newer {
                            outcomes.insert(rid, info);
                        }
                    }
                    None => orphans_no_request.push(info),
                }
            })?;
            // Pass 2: the rows, trimmed to the newest few as they come.
            for_each_line(path, |line| {
                let Ok(raw) = serde_json::from_slice::<RawEntry>(line) else {
                    return;
                };
                match raw.event.as_str() {
                    "outcome" => {
                        // Kept (light) so an unmatched one can become a row at the end.
                        if let Some(rid) = &raw.request_id {
                            if !seen_here.contains(rid)
                                && outcomes.get(rid).is_some_and(|o| o.entry_id == raw.id)
                            {
                                orphan_raws.insert(rid.clone(), raw);
                            }
                        }
                    }
                    "request" => {
                        let mut row = raw.to_row();
                        if let Some(rid) = &raw.request_id {
                            seen_here.insert(rid.clone());
                            orphan_raws.remove(rid);
                            if let Some(o) = outcomes.remove(rid) {
                                row.entry_ids.push(o.entry_id);
                                row.outcome = Some(o.outcome);
                                row.by_window = o.by_window;
                                row.latency_ms = o.latency_ms;
                            }
                        }
                        if accepts(&row) {
                            rows.push(row);
                        }
                    }
                    _ => {
                        let row = raw.to_row();
                        if accepts(&row) {
                            rows.push(row);
                        }
                    }
                }
                stats.peak_rows_held = stats.peak_rows_held.max(rows.len());
                if rows.len() > want * 2 {
                    trim_rows(&mut rows, want);
                }
            })?;
            // What no request claimed is the only outcome still worth carrying.
            outcomes.retain(|rid, _| orphan_raws.contains_key(rid));
            if rows.len() > want * 2 {
                trim_rows(&mut rows, want);
            }

            // Enough certain rows (at or after this file's first instant)? Then stop.
            let boundary = date
                .and_hms_opt(0, 0, 0)
                .map(|t| t.and_utc().timestamp_millis())
                .unwrap_or(i64::MIN);
            let certain = rows
                .iter()
                .filter(|r| r.ts.timestamp_millis() >= boundary)
                .count();
            if certain >= want {
                stopped_at = Some(*date);
                break;
            }
        }

        // An unmatched outcome is an orphan row, unless its request may sit in the
        // previous day's file (when we stopped early): look there for it first.
        if let Some(date) = stopped_at {
            let pending: std::collections::HashSet<&String> = orphan_raws
                .keys()
                .filter(|rid| !seen_requests.contains(*rid))
                .collect();
            if !pending.is_empty() {
                let prev = date - chrono::Duration::days(1);
                if let Some((_, path)) = self.daily_files()?.into_iter().find(|(d, _)| *d == prev) {
                    let pending_ids: std::collections::HashSet<String> =
                        pending.into_iter().cloned().collect();
                    let mut found = Vec::new();
                    for_each_line(&path, |line| {
                        if let Ok(p) = serde_json::from_slice::<Probe>(line) {
                            if p.event == "request" {
                                if let Some(rid) = p.request_id {
                                    if pending_ids.contains(&rid) {
                                        found.push(rid);
                                    }
                                }
                            }
                        }
                    })?;
                    seen_requests.extend(found);
                }
            }
        }
        for (rid, raw) in &orphan_raws {
            if !seen_requests.contains(rid) {
                let o = &outcomes[rid];
                let mut row = raw.to_orphan_row();
                row.outcome = Some(o.outcome.clone());
                if accepts(&row) {
                    rows.push(row);
                }
            }
        }
        // Outcomes without a request id (`request_unparseable`) are always rows of their own.
        for o in &orphans_no_request {
            let row = LogRow {
                row_id: o.entry_id.clone(),
                kind: RowKind::Request,
                ts: o.ts,
                tag: None,
                session_id: None,
                tool_use_id: None,
                request_id: None,
                entry_ids: vec![o.entry_id.clone()],
                agent: None,
                subagent: None,
                tool_name: None,
                summary: "(no request recorded)".to_owned(),
                outcome: Some(o.outcome.clone()),
                by_window: o.by_window.clone(),
                latency_ms: o.latency_ms,
                refusal_code: None,
                rule_label: None,
            };
            if accepts(&row) {
                rows.push(row);
            }
        }

        trim_rows(&mut rows, want);
        let has_more = rows.len() > limit;
        rows.drain(limit.min(rows.len())..);
        let next_cursor = if has_more {
            rows.last().map(LogRow::cursor)
        } else {
            None
        };
        Ok((LogPage { rows, next_cursor }, stats))
    }

    /// One entry in full. `id` is a `request_id` (the request's own entry) or an entry
    /// `id`. Searches back at most [`RETENTION_DAYS`].
    pub fn entry_detail(&self, id: &str, now: DateTime<Utc>) -> io::Result<Option<LogDetail>> {
        self.entry_detail_near(id, None, now)
    }

    /// [`Self::entry_detail`], searching only the day files within a day of `near` (the time
    /// of the row the caller holds) when given: a lookup for an id that does not exist then
    /// reads three files, not up to [`RETENTION_DAYS`].
    pub fn entry_detail_near(
        &self,
        id: &str,
        near: Option<DateTime<Utc>>,
        now: DateTime<Utc>,
    ) -> io::Result<Option<LogDetail>> {
        let cutoff = now.date_naive() - chrono::Duration::days(RETENTION_DAYS);
        let mut files = self.daily_files()?;
        if let Some(near) = near {
            let day = near.date_naive();
            files.retain(|(d, _)| (*d - day).num_days().abs() <= 1);
        }
        files.sort_by_key(|f| std::cmp::Reverse(f.0));
        let mut by_entry: Option<RawEntry> = None;
        let mut by_request: Option<RawEntry> = None;
        let mut outcome: Option<RawEntry> = None;
        for (date, path) in files {
            if date < cutoff {
                continue;
            }
            for_each_line(&path, |line| {
                let Ok(raw) = serde_json::from_slice::<RawEntry>(line) else {
                    return;
                };
                if raw.id == id {
                    by_entry = Some(raw);
                } else if raw.request_id.as_deref() == Some(id) {
                    match raw.event.as_str() {
                        "request" => by_request = Some(raw),
                        "outcome" if outcome.as_ref().is_none_or(|o| o.ts <= raw.ts) => {
                            outcome = Some(raw);
                        }
                        _ => {}
                    }
                }
            })?;
            if by_entry.is_some() {
                break;
            }
        }
        let Some(raw) = by_entry.or(by_request) else {
            return Ok(None);
        };
        let mut detail = raw.detail();
        if raw.event == "request" {
            if let Some(o) = outcome {
                detail.outcome = o.outcome;
                detail.latency_ms = o.latency_ms;
                detail.by_window = o.by_window;
            }
        }
        Ok(Some(detail))
    }
}

fn contains_bytes(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|w| w == needle)
}

/// Sort `rows` newest first and keep the first `keep`.
fn trim_rows(rows: &mut Vec<LogRow>, keep: usize) {
    rows.sort_by(|a, b| b.sort_key().cmp(&a.sort_key()));
    rows.dedup_by(|a, b| a.row_id == b.row_id);
    rows.drain(keep.min(rows.len())..);
}

/// Call `f` with each line of the file at `path` (without its newline), never holding
/// more than [`MAX_ENTRY_LINE_BYTES`] of one line.
fn for_each_line(path: &Path, mut f: impl FnMut(&[u8])) -> io::Result<()> {
    let mut reader = BufReader::new(File::open(path)?);
    let mut line = Vec::new();
    loop {
        line.clear();
        let read = (&mut reader)
            .take(MAX_ENTRY_LINE_BYTES as u64 + 1)
            .read_until(b'\n', &mut line)?;
        if read == 0 {
            return Ok(());
        }
        if line.last() == Some(&b'\n') {
            line.pop();
            f(&line);
        } else if line.len() > MAX_ENTRY_LINE_BYTES {
            // Too long to be an entry: skip the rest of it.
            let mut rest = Vec::new();
            loop {
                rest.clear();
                let n = (&mut reader).take(1 << 20).read_until(b'\n', &mut rest)?;
                if n == 0 || rest.last() == Some(&b'\n') {
                    break;
                }
            }
        } else {
            f(&line); // the last line, without a newline
        }
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
