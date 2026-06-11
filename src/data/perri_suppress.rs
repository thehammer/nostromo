//! Approval-suppression store for the Perri PR queue.
//!
//! After Perri approves a PR, GitHub's search index can lag by seconds-to-minutes
//! before the `review:required` bucket stops returning it.  This module hides the
//! just-approved PR on the next broadcast without waiting for the index to catch up.
//!
//! Suppression is **commit-scoped and self-healing**:
//! - A PR is suppressed only when the recorded `head_sha` **exactly matches** the
//!   current head SHA.  If the author pushes new commits the SHA changes and the PR
//!   reappears immediately.
//! - Entries expire after `ttl` (default 15 min), so even if the index never catches
//!   up the PR returns within the TTL window — it is never permanently hidden.
//!
//! ## Files on disk
//!
//! - `<perri_state>/approvals.jsonl` — append-only signal log written by the
//!   `submit-review` skill after each approval.  The daemon renames and processes
//!   this file, moving durable state into `approvals-state.json`.
//! - `<perri_state>/approvals-state.json` — JSON-serialised `SuppressStore` map,
//!   written atomically after every update and loaded on daemon startup.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use serde::{Deserialize, Serialize};
use tracing::{debug, warn};

// ── Entry ─────────────────────────────────────────────────────────────────────

/// One suppression entry: the approved HEAD SHA and when it was recorded.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SuppressEntry {
    /// The HEAD SHA that was approved.
    pub head_sha: String,
    /// Unix epoch seconds — used for TTL comparison.
    pub recorded_at_secs: u64,
}

// ── Signal line (from approvals.jsonl) ────────────────────────────────────────

/// One line of `approvals.jsonl`, as written by the `submit-review` skill.
#[derive(Debug, Deserialize)]
pub struct ApprovalLine {
    pub repo: String,
    pub number: u64,
    pub head_sha: String,
    // `ts` field is present but unused by the daemon — TTL is applied relative
    // to `now_secs` at the time the daemon processes the line, which is correct
    // because the skill and daemon run on the same machine (clock skew ≈ 0).
}

// ── Store ─────────────────────────────────────────────────────────────────────

/// In-memory suppression map with JSON persistence across daemon restarts.
pub struct SuppressStore {
    entries: HashMap<(String, u64), SuppressEntry>,
    ttl: Duration,
    /// Persistence target: `<perri_state>/approvals-state.json`.
    state_path: PathBuf,
}

impl SuppressStore {
    /// Create an empty store (no disk I/O).
    pub fn new(state_path: PathBuf, ttl: Duration) -> Self {
        Self {
            entries: HashMap::new(),
            ttl,
            state_path,
        }
    }

    /// Load from disk, dropping entries that have already expired.
    ///
    /// Returns an empty store (no error) if the file is absent.
    pub fn load(state_path: PathBuf, ttl: Duration) -> Self {
        let mut store = Self::new(state_path.clone(), ttl);

        let bytes = match std::fs::read(&state_path) {
            Ok(b) => b,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return store,
            Err(e) => {
                warn!(
                    "perri suppress: failed to read state file {}: {e:#}",
                    state_path.display()
                );
                return store;
            }
        };

        let raw: HashMap<String, SuppressEntry> = match serde_json::from_slice(&bytes) {
            Ok(m) => m,
            Err(e) => {
                warn!("perri suppress: failed to parse state file: {e:#}");
                return store;
            }
        };

        let now_secs = unix_now_secs();
        let ttl_secs = ttl.as_secs();
        for (key_str, entry) in raw {
            if let Some(key) = parse_key(&key_str) {
                let age = now_secs.saturating_sub(entry.recorded_at_secs);
                if age < ttl_secs {
                    store.entries.insert(key, entry);
                }
            }
        }

        debug!(
            "perri suppress: loaded {} live entries from {}",
            store.entries.len(),
            state_path.display()
        );
        store
    }

    /// Record an approval.  Inserts or overwrites the entry for `(repo, number)`.
    pub fn record(&mut self, repo: &str, number: u64, head_sha: &str, now_secs: u64) {
        self.entries.insert(
            (repo.to_owned(), number),
            SuppressEntry {
                head_sha: head_sha.to_owned(),
                recorded_at_secs: now_secs,
            },
        );
    }

    /// Returns `true` iff the PR should be suppressed from the queue:
    /// - An entry exists for `(repo, number)`.
    /// - Its `head_sha` **exactly matches** `head_sha` (empty string never matches).
    /// - The entry has not exceeded the TTL.
    pub fn is_suppressed(&self, repo: &str, number: u64, head_sha: &str, now_secs: u64) -> bool {
        // Empty SHA never matches — guards against accidentally suppressing PRs
        // whose head SHA couldn't be resolved.  (Empty ≠ empty by this rule.)
        if head_sha.is_empty() {
            return false;
        }
        match self.entries.get(&(repo.to_owned(), number)) {
            Some(entry) => {
                if entry.head_sha != head_sha {
                    return false; // author pushed new commits
                }
                now_secs.saturating_sub(entry.recorded_at_secs) < self.ttl.as_secs()
            }
            None => false,
        }
    }

    /// Remove entries older than the TTL.  Called once per fetch cycle.
    /// Prune expired entries. Returns `true` if any entries were removed
    /// (caller should call `save()` to persist the pruned state to disk).
    pub fn prune(&mut self, now_secs: u64) -> bool {
        let ttl_secs = self.ttl.as_secs();
        let before = self.entries.len();
        self.entries
            .retain(|_, entry| now_secs.saturating_sub(entry.recorded_at_secs) < ttl_secs);
        let pruned = before - self.entries.len();
        if pruned > 0 {
            debug!("perri suppress: pruned {pruned} expired entries");
        }
        pruned > 0
    }

    /// Persist the current map to disk atomically.
    pub fn save(&self) {
        // Serialise with string keys ("owner/repo/number") so the JSON file is
        // human-readable and easy to inspect or manually clear.
        let raw: HashMap<String, &SuppressEntry> = self
            .entries
            .iter()
            .map(|((repo, number), entry)| (format!("{repo}/{number}"), entry))
            .collect();
        match serde_json::to_string(&raw) {
            Ok(json) => {
                if let Err(e) = write_json_atomic(&self.state_path, &json) {
                    warn!("perri suppress: state save failed: {e:#}");
                }
            }
            Err(e) => warn!("perri suppress: state serialize failed: {e:#}"),
        }
    }

    /// Consume new lines from `approvals.jsonl` using a rename-and-process strategy.
    ///
    /// Returns the number of approvals successfully recorded.
    ///
    /// # Race window
    ///
    /// The skill appends one JSON line and then `touch`es `queue.dirty`.  The rename
    /// is POSIX-atomic on the same filesystem, so it grabs everything written up to
    /// that point atomically.  A skill append that races after the rename goes to a
    /// newly-created `approvals.jsonl`; the daemon's next wakeup (from `queue.dirty`
    /// which the skill also touches) will pick it up.  No lines are lost and no
    /// double-processing occurs.
    pub fn consume_approvals_file(&mut self, approvals_path: &Path, now_secs: u64) -> usize {
        if !approvals_path.exists() {
            return 0;
        }

        // Rename to a temp name so concurrent appends by the skill go to a fresh file.
        let tmp = approvals_path.with_extension("jsonl.processing");
        if let Err(e) = std::fs::rename(approvals_path, &tmp) {
            warn!("perri suppress: could not rename approvals file: {e:#}");
            return 0;
        }

        let content = match std::fs::read_to_string(&tmp) {
            Ok(s) => s,
            Err(e) => {
                warn!("perri suppress: could not read approvals temp file: {e:#}");
                let _ = std::fs::remove_file(&tmp);
                return 0;
            }
        };
        let _ = std::fs::remove_file(&tmp);

        let mut count = 0usize;
        for line in content.lines() {
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            match serde_json::from_str::<ApprovalLine>(line) {
                Ok(approval) => {
                    debug!(
                        "perri suppress: recording approval {}/{}@{}",
                        approval.repo, approval.number, approval.head_sha
                    );
                    self.record(&approval.repo, approval.number, &approval.head_sha, now_secs);
                    count += 1;
                }
                Err(e) => warn!("perri suppress: bad approval line {line:?}: {e:#}"),
            }
        }
        count
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Current Unix epoch seconds.
pub fn unix_now_secs() -> u64 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

/// Parse a `"{owner}/{repo}/{number}"` key string into `(repo, number)`.
///
/// The key is produced by `save()` as `format!("{repo}/{number}")` where `repo`
/// is `"owner/name"`, so the full key is `"owner/name/42"`.  `rfind('/')` splits
/// on the last slash, recovering the original repo and number.
fn parse_key(s: &str) -> Option<(String, u64)> {
    let idx = s.rfind('/')?;
    let repo = s[..idx].to_owned();
    let number: u64 = s[idx + 1..].parse().ok()?;
    Some((repo, number))
}

/// Write `json` to `path` atomically via temp-file + rename.
fn write_json_atomic(path: &Path, json: &str) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, json)?;
    std::fs::rename(&tmp, path)
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn make_store(ttl_secs: u64) -> (SuppressStore, tempfile::TempDir) {
        let dir = tempfile::tempdir().unwrap();
        let store = SuppressStore::new(dir.path().join("state.json"), Duration::from_secs(ttl_secs));
        (store, dir) // return dir so it isn't dropped (and the temp dir deleted) prematurely
    }

    fn now() -> u64 {
        unix_now_secs()
    }

    // ── is_suppressed ─────────────────────────────────────────────────────────

    #[test]
    fn not_suppressed_when_no_entry() {
        let (store, _dir) = make_store(900);
        assert!(!store.is_suppressed("acme/repo", 1, "sha-abc", now()));
    }

    #[test]
    fn suppressed_when_sha_matches() {
        let (mut store, _dir) = make_store(900);
        let t = now();
        store.record("acme/repo", 1, "sha-abc", t);
        assert!(store.is_suppressed("acme/repo", 1, "sha-abc", t + 1));
    }

    #[test]
    fn not_suppressed_when_sha_differs() {
        let (mut store, _dir) = make_store(900);
        let t = now();
        store.record("acme/repo", 1, "sha-old", t);
        // Author pushed new commits — different SHA should not be suppressed.
        assert!(!store.is_suppressed("acme/repo", 1, "sha-new", t + 1));
    }

    #[test]
    fn not_suppressed_when_expired() {
        let (mut store, _dir) = make_store(60);
        let t = now();
        // Record an entry with a timestamp 61 seconds in the past (beyond the 60s TTL).
        store.record("acme/repo", 1, "sha-abc", t.saturating_sub(61));
        assert!(!store.is_suppressed("acme/repo", 1, "sha-abc", t));
    }

    #[test]
    fn empty_sha_is_never_suppressed() {
        let (mut store, _dir) = make_store(900);
        let t = now();
        // Even if we somehow record an entry with an empty SHA, empty SHA passed
        // as the current head should never be suppressed.
        store.record("acme/repo", 1, "sha-abc", t);
        assert!(!store.is_suppressed("acme/repo", 1, "", t + 1));
    }

    // ── prune ──────────────────────────────────────────────────────────────────

    #[test]
    fn prune_removes_expired_entries() {
        let (mut store, _dir) = make_store(60);
        let t = now();
        // Entry recorded TTL + 1 seconds ago.
        store.record("acme/repo", 1, "sha-abc", t.saturating_sub(61));
        // Fresh entry well within the TTL.
        store.record("acme/repo", 2, "sha-def", t);

        store.prune(t);

        assert!(
            !store.is_suppressed("acme/repo", 1, "sha-abc", t),
            "expired entry should be pruned"
        );
        assert!(
            store.is_suppressed("acme/repo", 2, "sha-def", t + 1),
            "fresh entry should survive prune"
        );
    }

    // ── save / load round-trip ────────────────────────────────────────────────

    #[test]
    fn save_load_roundtrip_non_expired() {
        let dir = tempfile::tempdir().unwrap();
        let state_path = dir.path().join("state.json");

        let mut store = SuppressStore::new(state_path.clone(), Duration::from_secs(900));
        let t = now();
        store.record("Carefeed/admin-portal", 42, "abc123", t);
        store.save();

        let loaded = SuppressStore::load(state_path, Duration::from_secs(900));
        assert!(loaded.is_suppressed("Carefeed/admin-portal", 42, "abc123", t + 1));
    }

    #[test]
    fn load_drops_expired_entries() {
        let dir = tempfile::tempdir().unwrap();
        let state_path = dir.path().join("state.json");

        let mut store = SuppressStore::new(state_path.clone(), Duration::from_secs(60));
        let t = now();
        // Record an entry already past the TTL.
        store.record("acme/repo", 1, "sha-old", t.saturating_sub(61));
        store.save();

        let loaded = SuppressStore::load(state_path, Duration::from_secs(60));
        assert!(!loaded.is_suppressed("acme/repo", 1, "sha-old", t));
    }

    // ── consume_approvals_file ─────────────────────────────────────────────────

    #[test]
    fn consume_approvals_file_records_entries() {
        let dir = tempfile::tempdir().unwrap();
        let approvals_path = dir.path().join("approvals.jsonl");
        let state_path = dir.path().join("state.json");

        std::fs::write(
            &approvals_path,
            concat!(
                r#"{"repo":"acme/web","number":7,"head_sha":"abc123","ts":"2026-06-07T12:00:00Z"}"#,
                "\n",
                r#"{"repo":"acme/web","number":8,"head_sha":"def456","ts":"2026-06-07T12:01:00Z"}"#,
                "\n",
            ),
        )
        .unwrap();

        let mut store = SuppressStore::new(state_path, Duration::from_secs(900));
        let t = now();
        let count = store.consume_approvals_file(&approvals_path, t);

        assert_eq!(count, 2, "should have consumed 2 approval lines");
        assert!(store.is_suppressed("acme/web", 7, "abc123", t + 1));
        assert!(store.is_suppressed("acme/web", 8, "def456", t + 1));
        // File should be gone after consumption.
        assert!(!approvals_path.exists(), "approvals file should be removed after consumption");
    }

    #[test]
    fn consume_approvals_file_noop_when_absent() {
        let dir = tempfile::tempdir().unwrap();
        let approvals_path = dir.path().join("approvals.jsonl");
        let state_path = dir.path().join("state.json");

        let mut store = SuppressStore::new(state_path, Duration::from_secs(900));
        let count = store.consume_approvals_file(&approvals_path, now());
        assert_eq!(count, 0);
    }
}
