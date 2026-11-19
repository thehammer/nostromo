//! Perri's verdicts on a PR's head commit, kept so the Overview can tell
//! whether the commit about to be merged is the one Perri approved.
//!
//! `<state_root>/perri-verdicts.json`, mode 0600, written atomically. One record
//! per `repo + number + head_sha` (the full 40-hex head commit): the newest
//! verdict for a head wins. At most [`MAX_RECORDS`] records are kept, the newest
//! ones. A new push is a new head, so a verdict recorded for the old head never
//! applies to it.
//!
//! A record holds the verdict, a time, who recorded it and an optional short
//! plain-text note. The note is data: it is never rendered as markup, never put
//! on the board row and never logged. Nothing in this module logs a repo,
//! number, SHA, name or note.
//!
//! The file is read leniently: unknown fields are ignored, a record that does
//! not validate is dropped, and a file that does not parse starts the store
//! empty (the bytes are kept as a backup, see `load_json_checked`).

use std::path::PathBuf;
use std::sync::Mutex;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use super::snapshot::valid_repo;
use crate::mother::origin::{load_json_checked, write_private};

pub const MAX_RECORDS: usize = 500;
/// The longest `by` kept (characters).
pub const MAX_BY: usize = 80;
/// The longest `note` kept (characters). The MCP tool refuses a longer one.
pub const MAX_NOTE: usize = 200;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Verdict {
    Approved,
    ChangesRequested,
    Comment,
}

impl Verdict {
    pub fn parse(s: &str) -> Option<Verdict> {
        match s {
            "approved" => Some(Verdict::Approved),
            "changes_requested" => Some(Verdict::ChangesRequested),
            "comment" => Some(Verdict::Comment),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Verdict::Approved => "approved",
            Verdict::ChangesRequested => "changes_requested",
            Verdict::Comment => "comment",
        }
    }
}

/// A full head commit: 40 lowercase hex digits.
pub fn is_full_sha(s: &str) -> bool {
    s.len() == 40 && s.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// The first 8 hex digits of a full head commit; `None` for anything else.
pub fn short_sha(full: &str) -> Option<String> {
    is_full_sha(full).then(|| full[..8].to_owned())
}

/// `s` without control characters, at most `max` characters.
pub fn plain_text(s: &str, max: usize) -> String {
    s.chars().filter(|c| !c.is_control()).take(max).collect()
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VerdictRecord {
    /// `owner/name`, lowercased.
    pub repo: String,
    pub number: u64,
    /// The full head commit the verdict is for.
    pub head_sha: String,
    pub verdict: Verdict,
    pub at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub by: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

impl VerdictRecord {
    /// A record, or `None` when `repo`, `number` or `head_sha` is not valid.
    /// `by` and `note` are stripped of control characters and cut to their
    /// limits; an empty one is dropped.
    pub fn new(
        repo: &str,
        number: u64,
        head_sha: &str,
        verdict: Verdict,
        at: DateTime<Utc>,
        by: Option<&str>,
        note: Option<&str>,
    ) -> Option<VerdictRecord> {
        if !valid_repo(repo) || number == 0 || !is_full_sha(head_sha) {
            return None;
        }
        let clean = |s: Option<&str>, max| {
            s.map(|s| plain_text(s, max).trim().to_owned())
                .filter(|s| !s.is_empty())
        };
        Some(VerdictRecord {
            repo: repo.to_ascii_lowercase(),
            number,
            head_sha: head_sha.to_owned(),
            verdict,
            at,
            by: clean(by, MAX_BY),
            note: clean(note, MAX_NOTE),
        })
    }

    fn is_for(&self, repo: &str, number: u64) -> bool {
        self.number == number && self.repo.eq_ignore_ascii_case(repo)
    }
}

#[derive(Default, Serialize, Deserialize)]
struct File {
    /// Each record is validated on its own, so one bad entry costs only itself.
    #[serde(default)]
    records: Vec<serde_json::Value>,
}

/// Perri's verdicts. Cheap to share behind an `Arc`.
pub struct VerdictStore {
    path: Option<PathBuf>,
    /// Oldest first: a new record goes last, so the front is what is dropped.
    records: Mutex<Vec<VerdictRecord>>,
}

impl VerdictStore {
    /// A store that is never written to disk.
    pub fn in_memory() -> Self {
        VerdictStore {
            path: None,
            records: Mutex::new(Vec::new()),
        }
    }

    /// The store under `state_root`. A missing file starts empty; a corrupt one
    /// starts empty too, and is not an error.
    pub fn open(state_root: &std::path::Path) -> Self {
        let path = state_root.join("perri-verdicts.json");
        let (file, _) = load_json_checked::<File>(&path);
        let mut records: Vec<VerdictRecord> = file
            .records
            .into_iter()
            .filter_map(|v| serde_json::from_value::<VerdictRecord>(v).ok())
            .filter_map(|r| {
                // The file is not trusted: the same checks a new record gets.
                VerdictRecord::new(
                    &r.repo,
                    r.number,
                    &r.head_sha,
                    r.verdict,
                    r.at,
                    r.by.as_deref(),
                    r.note.as_deref(),
                )
            })
            .collect();
        // Oldest first (stable), then one per head (the later one wins), then the newest N.
        records.sort_by_key(|r| r.at);
        let mut kept: Vec<VerdictRecord> = Vec::with_capacity(records.len());
        for r in records {
            kept.retain(|k| !same_head(k, &r));
            kept.push(r);
        }
        if kept.len() > MAX_RECORDS {
            kept.drain(..kept.len() - MAX_RECORDS);
        }
        VerdictStore {
            path: Some(path),
            records: Mutex::new(kept),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Vec<VerdictRecord>> {
        self.records.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Record `rec`, replacing any earlier verdict for the same head.
    pub fn record(&self, rec: VerdictRecord) {
        let mut g = self.lock();
        g.retain(|k| !same_head(k, &rec));
        g.push(rec);
        if g.len() > MAX_RECORDS {
            let extra = g.len() - MAX_RECORDS;
            g.drain(..extra);
        }
        if let Some(path) = &self.path {
            let file = File {
                records: g
                    .iter()
                    .filter_map(|r| serde_json::to_value(r).ok())
                    .collect(),
            };
            if write_private(path, &file).is_err() {
                tracing::warn!("perri verdicts could not be written");
            }
        }
    }

    /// The verdict for exactly this head, if any.
    pub fn for_head(&self, repo: &str, number: u64, head_sha: &str) -> Option<VerdictRecord> {
        self.lock()
            .iter()
            .find(|r| r.is_for(repo, number) && r.head_sha == head_sha)
            .cloned()
    }

    /// The newest verdict for the PR, whatever head it is for.
    pub fn newest(&self, repo: &str, number: u64) -> Option<VerdictRecord> {
        self.lock()
            .iter()
            .rev()
            .find(|r| r.is_for(repo, number))
            .cloned()
    }

    pub fn len(&self) -> usize {
        self.lock().len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

fn same_head(a: &VerdictRecord, b: &VerdictRecord) -> bool {
    a.number == b.number && a.repo == b.repo && a.head_sha == b.head_sha
}

#[cfg(test)]
mod tests {
    use super::*;

    const SHA_A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const SHA_B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    fn at(n: i64) -> DateTime<Utc> {
        DateTime::from_timestamp(1_800_000_000 + n, 0).unwrap()
    }

    fn rec(repo: &str, number: u64, sha: &str, v: Verdict, n: i64) -> VerdictRecord {
        VerdictRecord::new(repo, number, sha, v, at(n), Some("perri"), None).unwrap()
    }

    #[test]
    fn a_record_needs_a_valid_repo_number_and_full_sha() {
        let ok = |repo: &str, n: u64, sha: &str| {
            VerdictRecord::new(repo, n, sha, Verdict::Approved, at(0), None, None).is_some()
        };
        let upper = SHA_A.to_uppercase();
        let not_hex = format!("{}g", &SHA_A[..39]);
        assert!(ok("Acme/Web", 1, SHA_A));
        assert!(!ok("acme", 1, SHA_A));
        assert!(!ok("acme/web", 0, SHA_A));
        assert!(!ok("acme/web", 1, "aaaaaaaa"));
        assert!(!ok("acme/web", 1, &upper));
        assert!(!ok("acme/web", 1, &not_hex));
    }

    #[test]
    fn text_fields_lose_control_characters_and_are_cut() {
        let r = VerdictRecord::new(
            "acme/web",
            1,
            SHA_A,
            Verdict::Comment,
            at(0),
            Some(&format!("{}\u{1b}[31m", "x".repeat(200))),
            Some("a\nb\u{0}c"),
        )
        .unwrap();
        assert_eq!(r.by.as_deref().map(|s| s.chars().count()), Some(MAX_BY));
        assert!(!r.by.unwrap().contains('\u{1b}'));
        assert_eq!(r.note.as_deref(), Some("abc"));
    }

    #[test]
    fn the_newest_verdict_for_a_head_wins_and_other_heads_are_kept() {
        let s = VerdictStore::in_memory();
        s.record(rec("acme/web", 1, SHA_A, Verdict::ChangesRequested, 0));
        s.record(rec("acme/web", 1, SHA_A, Verdict::Approved, 1));
        s.record(rec("acme/web", 1, SHA_B, Verdict::Comment, 2));
        assert_eq!(s.len(), 2);
        assert_eq!(
            s.for_head("ACME/web", 1, SHA_A).unwrap().verdict,
            Verdict::Approved
        );
        assert_eq!(s.newest("acme/web", 1).unwrap().head_sha, SHA_B);
        assert!(s.for_head("acme/web", 2, SHA_A).is_none());
    }

    #[test]
    fn at_most_500_records_are_kept_the_newest() {
        let s = VerdictStore::in_memory();
        for n in 0..(MAX_RECORDS as u64 + 20) {
            s.record(rec("acme/web", n + 1, SHA_A, Verdict::Approved, n as i64));
        }
        assert_eq!(s.len(), MAX_RECORDS);
        assert!(s.newest("acme/web", 1).is_none());
        assert!(s.newest("acme/web", MAX_RECORDS as u64 + 20).is_some());
    }

    #[test]
    fn records_survive_a_reload_in_a_private_file() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        VerdictStore::open(dir.path()).record(rec("acme/web", 7, SHA_A, Verdict::Approved, 0));
        let path = dir.path().join("perri-verdicts.json");
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let again = VerdictStore::open(dir.path());
        assert_eq!(
            again.for_head("acme/web", 7, SHA_A).unwrap().verdict,
            Verdict::Approved
        );
    }

    #[test]
    fn a_corrupt_file_starts_empty_and_garbage_records_and_fields_are_ignored() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("perri-verdicts.json");
        std::fs::write(&path, "{ not json").unwrap();
        let s = VerdictStore::open(dir.path());
        assert!(s.is_empty());
        s.record(rec("acme/web", 1, SHA_A, Verdict::Approved, 0));
        assert_eq!(VerdictStore::open(dir.path()).len(), 1);

        std::fs::write(
            &path,
            serde_json::json!({
                "future": true,
                "records": [
                    {"repo": "acme/web", "number": 1, "head_sha": SHA_A, "verdict": "approved",
                     "at": "2026-11-19T10:00:00Z", "mystery": [1, 2]},
                    {"repo": "acme/web", "number": 2, "head_sha": "short", "verdict": "approved",
                     "at": "2026-11-19T10:00:00Z"},
                    {"repo": "acme/web", "number": 3, "head_sha": SHA_A, "verdict": "merge_it",
                     "at": "2026-11-19T10:00:00Z"},
                    "garbage", 7, null
                ]
            })
            .to_string(),
        )
        .unwrap();
        let s = VerdictStore::open(dir.path());
        assert_eq!(s.len(), 1);
        assert!(s.for_head("acme/web", 1, SHA_A).is_some());
    }

    #[test]
    fn a_file_with_too_many_records_is_cut_to_the_newest_on_load() {
        let dir = tempfile::tempdir().unwrap();
        let records: Vec<_> = (0..(MAX_RECORDS as u64 + 5))
            .map(|n| rec("acme/web", n + 1, SHA_A, Verdict::Approved, n as i64))
            .collect();
        std::fs::write(
            dir.path().join("perri-verdicts.json"),
            serde_json::json!({ "records": records }).to_string(),
        )
        .unwrap();
        let s = VerdictStore::open(dir.path());
        assert_eq!(s.len(), MAX_RECORDS);
        assert!(s.newest("acme/web", 5).is_none());
        assert!(s.newest("acme/web", 6).is_some());
    }
}
