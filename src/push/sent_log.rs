//! The sent-notifications log (W13): every attempt for 7 days, kept on the
//! operator's machines (never in the relay), and the per-device delivery status
//! the app's "not delivered since" banner reads.

use std::collections::{BTreeMap, VecDeque};
use std::io::Write;
use std::path::PathBuf;

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use tracing::warn;

use crate::push::devices::write_private_atomic;
use crate::push::wire::{PushOutcome, PushSentEntry};

/// How long a line is kept.
pub const RETENTION: Duration = Duration::days(7);
/// A hard ceiling on lines kept, so a flood cannot grow the log without bound;
/// the oldest go first.
pub const MAX_LINES: usize = 20_000;

/// One line of `sent.jsonl`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SentLine {
    pub ts: DateTime<Utc>,
    pub push_id: String,
    pub kind: String,
    pub host: String,
    pub title: String,
    pub body: String,
    pub outcome: PushOutcome,
}

/// Whether notifications are getting through to one device.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct DeliveryStatus {
    pub last_ok_at: Option<DateTime<Utc>>,
    /// Set by the first failure after a success; cleared by the next success.
    pub failing_since: Option<DateTime<Utc>>,
}

#[derive(Debug)]
pub struct SentLog {
    path: Option<PathBuf>,
    lines: VecDeque<SentLine>,
    status: BTreeMap<String, DeliveryStatus>,
}

impl SentLog {
    /// A log that lives only in memory (tests).
    pub fn in_memory() -> Self {
        Self {
            path: None,
            lines: VecDeque::new(),
            status: BTreeMap::new(),
        }
    }

    /// The log at `path`, without lines older than 7 days.
    pub fn load(path: impl Into<PathBuf>, now: DateTime<Utc>) -> Self {
        let path = path.into();
        let lines: VecDeque<SentLine> = std::fs::read_to_string(&path)
            .unwrap_or_default()
            .lines()
            .filter_map(|l| serde_json::from_str(l).ok())
            .collect();
        let mut log = Self {
            path: Some(path),
            lines,
            status: BTreeMap::new(),
        };
        for line in log.lines.clone() {
            log.note_status(&line.push_id, line.outcome, line.ts);
        }
        log.prune(now);
        log
    }

    /// Add a line (pruning first), and fold its outcome into the device's status.
    pub fn append(&mut self, line: SentLine, now: DateTime<Utc>) {
        self.note_status(&line.push_id, line.outcome, line.ts);
        let pruned = self.drop_expired(now);
        let json = serde_json::to_string(&line);
        self.lines.push_back(line);
        let capped = self.lines.len() > MAX_LINES;
        while self.lines.len() > MAX_LINES {
            self.lines.pop_front();
        }
        if pruned || capped {
            self.rewrite();
        } else if let (Some(path), Ok(json)) = (&self.path, json) {
            if let Err(e) = append_line(path, &json) {
                warn!("push sent log: {e:#}");
            }
        }
    }

    /// Fold the outcome of a send that is not logged (a badge-only push).
    pub fn note_status(&mut self, push_id: &str, outcome: PushOutcome, at: DateTime<Utc>) {
        let status = self.status.entry(push_id.to_string()).or_default();
        match outcome {
            PushOutcome::DeliveredToApple | PushOutcome::Withdrawn => {
                status.last_ok_at = Some(at);
                status.failing_since = None;
            }
            PushOutcome::RejectedByApple | PushOutcome::RelayUnreachable => {
                status.failing_since.get_or_insert(at);
            }
            PushOutcome::HeldQuietHours
            | PushOutcome::Coalesced
            | PushOutcome::SkippedResolvedInGrace => {}
        }
    }

    /// Remove lines older than 7 days (hourly, and on every append).
    pub fn prune(&mut self, now: DateTime<Utc>) {
        if self.drop_expired(now) {
            self.rewrite();
        }
    }

    /// A device's own lines, oldest first. Never another device's.
    pub fn entries_for(&self, push_id: &str, now: DateTime<Utc>) -> Vec<PushSentEntry> {
        self.lines
            .iter()
            .filter(|l| l.push_id == push_id && l.ts > now - RETENTION)
            .map(|l| PushSentEntry {
                ts: l.ts,
                kind: l.kind.clone(),
                host: l.host.clone(),
                title: l.title.clone(),
                body: l.body.clone(),
                outcome: l.outcome,
            })
            .collect()
    }

    pub fn status(&self, push_id: &str) -> DeliveryStatus {
        self.status.get(push_id).copied().unwrap_or_default()
    }

    /// Forget a device (it was revoked): its lines and its status.
    pub fn forget(&mut self, push_id: &str) {
        self.status.remove(push_id);
        let before = self.lines.len();
        self.lines.retain(|l| l.push_id != push_id);
        if self.lines.len() != before {
            self.rewrite();
        }
    }

    fn drop_expired(&mut self, now: DateTime<Utc>) -> bool {
        let cutoff = now - RETENTION;
        let before = self.lines.len();
        self.lines.retain(|l| l.ts > cutoff);
        self.lines.len() != before
    }

    fn rewrite(&self) {
        let Some(path) = &self.path else { return };
        let mut out = Vec::new();
        for line in &self.lines {
            if let Ok(json) = serde_json::to_string(line) {
                out.extend_from_slice(json.as_bytes());
                out.push(b'\n');
            }
        }
        if let Err(e) = write_private_atomic(path, &out) {
            warn!("push sent log: {e:#}");
        }
    }
}

fn append_line(path: &PathBuf, json: &str) -> anyhow::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut options = std::fs::OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(path)?;
    writeln!(file, "{json}")?;
    Ok(())
}
