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

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn t() -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 11, 26, 10, 0, 0).unwrap()
    }

    fn line(push_id: &str, ts: DateTime<Utc>, outcome: PushOutcome) -> SentLine {
        SentLine {
            ts,
            push_id: push_id.into(),
            kind: "mother".into(),
            host: "kobe".into(),
            title: "Mother · kobe".into(),
            body: "Job 3f9a1c2e asked a question".into(),
            outcome,
        }
    }

    fn delivered(push_id: &str, ts: DateTime<Utc>) -> SentLine {
        line(push_id, ts, PushOutcome::DeliveredToApple)
    }

    #[test]
    fn a_line_older_than_seven_days_is_pruned_when_the_next_one_is_appended() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sent.jsonl");
        let mut log = SentLog::load(&path, t());
        let old = t() - Duration::days(8);
        log.append(delivered("a", old), old);
        assert_eq!(std::fs::read_to_string(&path).unwrap().lines().count(), 1);
        log.append(delivered("a", t()), t());
        let entries = log.entries_for("a", t());
        assert_eq!(entries.len(), 1, "{entries:?}");
        assert_eq!(entries[0].ts, t());
        let on_disk = std::fs::read_to_string(&path).unwrap();
        assert_eq!(
            on_disk.lines().count(),
            1,
            "the old line is gone from the file: {on_disk}"
        );
    }

    #[test]
    fn the_seven_day_boundary_is_exclusive_a_line_exactly_seven_days_old_is_gone() {
        let mut log = SentLog::in_memory();
        let now = t();
        log.append(
            delivered("a", now - RETENTION + Duration::seconds(1)),
            now - RETENTION,
        );
        log.append(delivered("b", now - RETENTION), now - RETENTION);
        // Read at `now`: the line one second inside the window is shown, the one on the edge is not.
        assert_eq!(log.entries_for("a", now).len(), 1);
        assert_eq!(log.entries_for("b", now).len(), 0);
        // And pruning drops the edge line from the store too.
        log.prune(now);
        assert_eq!(
            log.entries_for("b", now - Duration::days(30)).len(),
            0,
            "dropped, not just hidden"
        );
    }

    #[test]
    fn prune_drops_expired_lines_and_rewrites_the_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sent.jsonl");
        let mut log = SentLog::load(&path, t());
        log.append(
            delivered("a", t() - Duration::days(6)),
            t() - Duration::days(6),
        );
        log.append(
            delivered("a", t() - Duration::days(5)),
            t() - Duration::days(5),
        );
        assert_eq!(std::fs::read_to_string(&path).unwrap().lines().count(), 2);
        // Two days later the first is past 7 days.
        log.prune(t() + Duration::days(1) + Duration::seconds(1));
        let on_disk = std::fs::read_to_string(&path).unwrap();
        assert_eq!(on_disk.lines().count(), 1, "{on_disk}");
        assert_eq!(
            log.entries_for("a", t() + Duration::days(1) + Duration::seconds(1))
                .len(),
            1
        );
    }

    #[test]
    fn a_read_hides_what_is_older_than_seven_days_even_before_it_is_pruned() {
        let mut log = SentLog::in_memory();
        log.append(delivered("a", t()), t());
        assert_eq!(log.entries_for("a", t() + Duration::days(6)).len(), 1);
        assert_eq!(log.entries_for("a", t() + Duration::days(7)).len(), 0);
        assert_eq!(log.entries_for("a", t() + Duration::days(8)).len(), 0);
    }

    #[test]
    fn the_log_is_capped_at_max_lines_and_the_oldest_go_first() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sent.jsonl");
        // A file that is already over the cap (as if the cap were raised once, or it was hand-edited).
        let mut text = String::new();
        for i in 0..(MAX_LINES + 5) {
            let l = delivered("a", t() + Duration::seconds(i as i64));
            text.push_str(&serde_json::to_string(&l).unwrap());
            text.push('\n');
        }
        std::fs::write(&path, text).unwrap();
        let now = t() + Duration::seconds((MAX_LINES + 6) as i64);
        let mut log = SentLog::load(&path, now);
        log.append(delivered("a", now), now);
        let entries = log.entries_for("a", now);
        assert_eq!(entries.len(), MAX_LINES, "the cap holds");
        assert_eq!(entries.last().unwrap().ts, now, "the newest is kept");
        assert_eq!(
            entries[0].ts,
            t() + Duration::seconds(6),
            "the 6 oldest were dropped"
        );
        let on_disk = std::fs::read_to_string(&path).unwrap();
        assert_eq!(
            on_disk.lines().count(),
            MAX_LINES,
            "and the file was rewritten to match"
        );
    }

    #[test]
    fn each_device_reads_only_its_own_lines() {
        let mut log = SentLog::in_memory();
        log.append(delivered("a", t()), t());
        log.append(line("b", t(), PushOutcome::Coalesced), t());
        log.append(
            delivered("a", t() + Duration::seconds(1)),
            t() + Duration::seconds(1),
        );
        let a = log.entries_for("a", t() + Duration::seconds(2));
        let b = log.entries_for("b", t() + Duration::seconds(2));
        assert_eq!(a.len(), 2);
        assert!(a.iter().all(|e| e.outcome == PushOutcome::DeliveredToApple));
        assert_eq!(b.len(), 1);
        assert_eq!(b[0].outcome, PushOutcome::Coalesced);
        assert!(log.entries_for("nobody", t()).is_empty());
    }

    #[test]
    fn a_read_returns_the_exact_text_oldest_first_without_the_device_reference() {
        let mut log = SentLog::in_memory();
        log.append(delivered("a", t()), t());
        let entries = log.entries_for("a", t());
        assert_eq!(entries[0].title, "Mother · kobe");
        assert_eq!(entries[0].body, "Job 3f9a1c2e asked a question");
        assert_eq!(entries[0].kind, "mother");
        assert_eq!(entries[0].host, "kobe");
        assert!(!serde_json::to_string(&entries[0])
            .unwrap()
            .contains("push_id"));
    }

    #[test]
    fn forgetting_a_device_removes_its_lines_and_status_and_nobody_elses() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sent.jsonl");
        let mut log = SentLog::load(&path, t());
        log.append(delivered("a", t()), t());
        log.append(line("b", t(), PushOutcome::RelayUnreachable), t());
        assert!(log.status("a").last_ok_at.is_some());
        log.forget("a");
        assert!(log.entries_for("a", t()).is_empty());
        assert_eq!(log.status("a"), DeliveryStatus::default());
        assert_eq!(log.entries_for("b", t()).len(), 1);
        assert!(log.status("b").failing_since.is_some());
        let on_disk = std::fs::read_to_string(&path).unwrap();
        assert_eq!(on_disk.lines().count(), 1, "{on_disk}");
        assert!(!on_disk.contains("\"push_id\":\"a\""));
    }

    #[test]
    fn failing_since_is_the_first_failure_after_a_success_and_a_success_clears_it() {
        let mut log = SentLog::in_memory();
        assert_eq!(log.status("a"), DeliveryStatus::default());
        let at = |m| t() + Duration::minutes(m);
        log.note_status("a", PushOutcome::DeliveredToApple, at(0));
        assert_eq!(log.status("a").last_ok_at, Some(at(0)));
        assert_eq!(log.status("a").failing_since, None);

        log.note_status("a", PushOutcome::RelayUnreachable, at(5));
        log.note_status("a", PushOutcome::RejectedByApple, at(9));
        log.note_status("a", PushOutcome::RelayUnreachable, at(12));
        let s = log.status("a");
        assert_eq!(
            s.failing_since,
            Some(at(5)),
            "the first failure, not the latest"
        );
        assert_eq!(s.last_ok_at, Some(at(0)));

        log.note_status("a", PushOutcome::DeliveredToApple, at(20));
        let s = log.status("a");
        assert_eq!(s.failing_since, None, "cleared by the next success");
        assert_eq!(s.last_ok_at, Some(at(20)));

        // A fresh failure starts a fresh run.
        log.note_status("a", PushOutcome::RelayUnreachable, at(30));
        assert_eq!(log.status("a").failing_since, Some(at(30)));
    }

    #[test]
    fn a_withdrawal_that_reaches_apple_counts_as_a_success() {
        let mut log = SentLog::in_memory();
        log.note_status("a", PushOutcome::RelayUnreachable, t());
        log.note_status("a", PushOutcome::Withdrawn, t() + Duration::minutes(1));
        let s = log.status("a");
        assert_eq!(s.failing_since, None);
        assert_eq!(s.last_ok_at, Some(t() + Duration::minutes(1)));
    }

    #[test]
    fn outcomes_that_are_not_attempts_leave_the_status_alone() {
        let mut log = SentLog::in_memory();
        log.note_status("a", PushOutcome::RelayUnreachable, t());
        for outcome in [
            PushOutcome::HeldQuietHours,
            PushOutcome::Coalesced,
            PushOutcome::SkippedResolvedInGrace,
        ] {
            log.note_status("a", outcome, t() + Duration::minutes(5));
        }
        let s = log.status("a");
        assert_eq!(s.failing_since, Some(t()));
        assert_eq!(s.last_ok_at, None);
    }

    #[test]
    fn appending_a_line_folds_its_outcome_into_the_status_at_the_lines_time() {
        let mut log = SentLog::in_memory();
        log.append(
            line("a", t(), PushOutcome::RelayUnreachable),
            t() + Duration::hours(1),
        );
        assert_eq!(log.status("a").failing_since, Some(t()));
        log.append(
            delivered("a", t() + Duration::minutes(10)),
            t() + Duration::hours(1),
        );
        assert_eq!(log.status("a").failing_since, None);
        assert_eq!(
            log.status("a").last_ok_at,
            Some(t() + Duration::minutes(10))
        );
    }

    #[test]
    fn a_reload_restores_lines_and_rebuilds_the_status_from_them() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sent.jsonl");
        let at = |m| t() + Duration::minutes(m);
        {
            let mut log = SentLog::load(&path, t());
            log.append(delivered("a", at(1)), at(1));
            log.append(line("a", at(2), PushOutcome::RelayUnreachable), at(2));
            log.append(line("a", at(3), PushOutcome::RelayUnreachable), at(3));
            log.append(line("b", at(4), PushOutcome::DeliveredToApple), at(4));
            log.append(line("b", at(5), PushOutcome::Coalesced), at(5));
        }
        let log = SentLog::load(&path, at(10));
        assert_eq!(log.entries_for("a", at(10)).len(), 3);
        assert_eq!(log.entries_for("b", at(10)).len(), 2);
        let a = log.status("a");
        assert_eq!((a.last_ok_at, a.failing_since), (Some(at(1)), Some(at(2))));
        let b = log.status("b");
        assert_eq!((b.last_ok_at, b.failing_since), (Some(at(4)), None));
    }

    #[test]
    fn loading_skips_lines_it_cannot_read_and_drops_expired_ones() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sent.jsonl");
        let old = serde_json::to_string(&delivered("a", t() - Duration::days(9))).unwrap();
        let new = serde_json::to_string(&delivered("a", t() - Duration::days(1))).unwrap();
        std::fs::write(
            &path,
            format!("{old}\nnot json at all\n\n{{\"ts\": 5}}\n{new}\n"),
        )
        .unwrap();
        let log = SentLog::load(&path, t());
        let entries = log.entries_for("a", t());
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].ts, t() - Duration::days(1));
        // The expired line is gone from the file at load, not only hidden from readers.
        let on_disk = std::fs::read_to_string(&path).unwrap();
        assert!(
            !on_disk.contains("2026-11-17"),
            "the 9-day-old line is still in the file: {on_disk}"
        );
        // A missing file is an empty log.
        assert!(SentLog::load(dir.path().join("none.jsonl"), t())
            .entries_for("a", t())
            .is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn the_log_file_is_private_when_appended_and_when_rewritten() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sent.jsonl");
        let mode = |p: &std::path::Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
        let mut log = SentLog::load(&path, t());
        log.append(delivered("a", t()), t());
        assert_eq!(mode(&path), 0o600, "appended");
        log.forget("a");
        assert_eq!(mode(&path), 0o600, "rewritten");
        assert!(
            !dir.path().join("sent.tmp").exists(),
            "no temporary file is left"
        );
    }

    #[test]
    fn appends_are_appended_not_rewritten_while_nothing_expires() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sent.jsonl");
        let mut log = SentLog::load(&path, t());
        for i in 0..3 {
            log.append(
                delivered("a", t() + Duration::seconds(i)),
                t() + Duration::seconds(i),
            );
        }
        let text = std::fs::read_to_string(&path).unwrap();
        let lines: Vec<SentLine> = text
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect();
        assert_eq!(lines.len(), 3);
        assert!(lines.windows(2).all(|w| w[0].ts < w[1].ts), "in order");
    }
}
