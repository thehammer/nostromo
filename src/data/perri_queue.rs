//! Perri PR queue data source.
//!
//! Phase 1: shells out to `~/.claude/bin/perri-queue-pane --json`.
//!
//! Expected JSON shape:
//! ```json
//! {
//!   "generated_at": "2026-05-07T14:00:00Z",
//!   "items": [
//!     {
//!       "repo": "acme/web-app",
//!       "number": 42,
//!       "title": "feat: add user authentication",
//!       "author": "alice",
//!       "bucket": "requested",
//!       "new_activity": false,
//!       "url": "https://github.com/acme/web-app/pull/42"
//!     }
//!   ],
//!   "stale": false
//! }
//! ```
//!
//! ## Buckets
//! - `requested`    — review explicitly requested from me
//! - `needs_review` — open PR that needs at least one approval
//! - `changes_req`  — I requested changes and the author has since responded
//! - `dependabot`   — dependabot / carefeed-ci authored PRs needing review

use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use tokio::sync::{mpsc, watch};
use tracing::{debug, warn};

use crate::{config::Config, data::dirty_file};

// ── CI state ──────────────────────────────────────────────────────────────────

/// Four-way CI state shared between queue items and PR detail checks.
/// Derived from GitHub check-run `status` + `conclusion` fields (see D1).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum CiState {
    #[default]
    Unknown,
    Pending,
    Success,
    Failure,
}

impl CiState {
    /// Map a GitHub check-run (status, conclusion) onto a `CiState`. See D1.
    pub fn from_check(status: Option<&str>, conclusion: Option<&str>) -> Self {
        match conclusion {
            Some("failure" | "timed_out" | "action_required" | "stale") => CiState::Failure,
            Some("success") => CiState::Success,
            Some("skipped" | "cancelled" | "neutral") => CiState::Unknown,
            Some(_) => CiState::Unknown,
            None => match status {
                Some("queued" | "in_progress" | "waiting" | "pending" | "requested") => {
                    CiState::Pending
                }
                _ => CiState::Unknown,
            },
        }
    }

    /// Roll up many check states into one glyph state. Precedence: Failure >
    /// Pending > Success > Unknown.  Empty input → Unknown.
    pub fn rollup(states: impl IntoIterator<Item = CiState>) -> Self {
        let mut any_success = false;
        let mut any_pending = false;
        for s in states {
            match s {
                CiState::Failure => return CiState::Failure,
                CiState::Pending => any_pending = true,
                CiState::Success => any_success = true,
                CiState::Unknown => {}
            }
        }
        if any_pending {
            CiState::Pending
        } else if any_success {
            CiState::Success
        } else {
            CiState::Unknown
        }
    }

    /// 1-char glyph for the queue column and detail lines.
    pub fn glyph(self) -> &'static str {
        match self {
            CiState::Failure => "✗",
            CiState::Pending => "⟳",
            CiState::Success => "✓",
            CiState::Unknown => "-",
        }
    }
}

// ── Queue items ───────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct PrQueueItem {
    pub repo: String,
    pub number: u64,
    pub title: String,
    pub author: String,
    /// One of: `"requested"`, `"needs_review"`, `"changes_req"`, `"dependabot"`.
    #[serde(default = "default_bucket")]
    pub bucket: String,
    /// For `changes_req` items: whether the author has pushed new commits or
    /// comments since we requested changes.  Always `false` for other buckets.
    #[serde(default)]
    pub new_activity: bool,
    pub url: String,
    /// Rolled-up CI state for this PR (display only; does not affect filtering).
    #[serde(default)]
    pub ci_state: CiState,
    /// HEAD commit SHA of the PR — used by the GUI to validate its detail cache.
    /// Changes on every push (the only event that alters diff/CI). Empty when
    /// the queue source could not resolve the head SHA.
    #[serde(default)]
    pub head_sha: String,
    /// `true` when this PR was authored by a known bot (dependabot, carefeed-ci).
    /// The daemon (`is_bot` in `perri_queue_native.rs`) is the single source of
    /// truth; clients must not infer bot status from the `author` string.
    #[serde(default)]
    pub is_bot: bool,
}

fn default_bucket() -> String {
    "needs_review".to_owned()
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct PrQueueSnapshot {
    pub generated_at: Option<DateTime<Utc>>,
    pub items: Vec<PrQueueItem>,
    pub stale: bool,
    pub error: Option<String>,
}

pub struct PerriQueueSource {
    config: Config,
}

impl PerriQueueSource {
    pub fn spawn(config: Config) -> watch::Receiver<Option<PrQueueSnapshot>> {
        let (tx, rx) = watch::channel(None);
        let (dirty_tx, mut dirty_rx) = mpsc::unbounded_channel::<()>();

        let dirty_path = config.perri_state_dir().join("queue.dirty");
        dirty_file::spawn_watcher(dirty_path, dirty_tx);

        let interval = config.pr_queue_poll_interval();

        tokio::spawn(async move {
            let source = PerriQueueSource { config };
            loop {
                match source.fetch().await {
                    Ok(snap) => {
                        debug!(prs = snap.items.len(), "perri queue refreshed");
                        let _ = tx.send(Some(snap));
                    }
                    Err(e) => {
                        warn!("perri queue fetch failed: {e:#}");
                        let mut snap = tx.borrow().clone().unwrap_or_default();
                        snap.stale = true;
                        snap.error = Some(e.to_string());
                        let _ = tx.send(Some(snap));
                    }
                }

                tokio::select! {
                    _ = tokio::time::sleep(interval) => {}
                    _ = dirty_rx.recv() => {
                        debug!("perri queue dirty signal");
                    }
                }
            }
        });

        rx
    }

    async fn fetch(&self) -> Result<PrQueueSnapshot> {
        let bin = self.config.claude_bin_dir().join("perri-queue-pane");
        let output = tokio::process::Command::new(&bin)
            .arg("--json")
            .env(
                "PERRI_HOME",
                self.config
                    .claude_bin_dir()
                    .parent()
                    .unwrap_or_else(|| std::path::Path::new(".")),
            )
            .env("PERRI_STATE", self.config.perri_state_dir())
            .output()
            .await
            .with_context(|| format!("running {}", bin.display()))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            anyhow::bail!("perri-queue-pane --json exited non-zero: {stderr}");
        }

        let snap: PrQueueSnapshot = serde_json::from_slice(&output.stdout)
            .with_context(|| "parsing perri-queue-pane --json output")?;
        Ok(snap)
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ── PrQueueItem serde round-trips ─────────────────────────────────────────

    #[test]
    fn pr_queue_item_roundtrips_head_sha() {
        let item = PrQueueItem {
            repo: "acme/web".to_owned(),
            number: 42,
            title: "feat: add auth".to_owned(),
            author: "alice".to_owned(),
            bucket: "requested".to_owned(),
            new_activity: false,
            url: "https://github.com/acme/web/pull/42".to_owned(),
            ci_state: CiState::Success,
            head_sha: "abc123def456".to_owned(),
            is_bot: false,
        };

        let json = serde_json::to_string(&item).expect("serialize");
        let decoded: PrQueueItem = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(decoded.head_sha, "abc123def456");
        assert_eq!(decoded.ci_state, CiState::Success);
    }

    #[test]
    fn pr_queue_item_head_sha_defaults_to_empty_when_absent() {
        // JSON without head_sha — should decode to "" via #[serde(default)].
        let json = r#"{
            "repo": "acme/web",
            "number": 1,
            "title": "t",
            "author": "bob",
            "bucket": "needs_review",
            "new_activity": false,
            "url": "https://github.com/acme/web/pull/1"
        }"#;
        let item: PrQueueItem = serde_json::from_str(json).expect("deserialize");
        assert_eq!(item.head_sha, "");
        assert_eq!(item.ci_state, CiState::Unknown);
        assert!(!item.is_bot, "is_bot should default to false when absent");
    }

    #[test]
    fn pr_queue_item_is_bot_roundtrips() {
        let item = PrQueueItem {
            repo: "acme/web".to_owned(),
            number: 7,
            title: "chore: bump deps".to_owned(),
            author: "dependabot[bot]".to_owned(),
            bucket: "dependabot".to_owned(),
            new_activity: false,
            url: "https://github.com/acme/web/pull/7".to_owned(),
            ci_state: CiState::Success,
            head_sha: "deadbeef".to_owned(),
            is_bot: true,
        };
        let json = serde_json::to_string(&item).expect("serialize");
        let decoded: PrQueueItem = serde_json::from_str(&json).expect("deserialize");
        assert!(decoded.is_bot);
        assert_eq!(decoded.bucket, "dependabot");

        // Also verify that a payload explicitly carrying is_bot:false decodes correctly.
        let explicit_false = r#"{
            "repo": "acme/web", "number": 1, "title": "t", "author": "alice",
            "bucket": "requested", "new_activity": false,
            "url": "https://github.com/acme/web/pull/1", "is_bot": false
        }"#;
        let item2: PrQueueItem = serde_json::from_str(explicit_false).expect("deserialize");
        assert!(!item2.is_bot);
    }

    #[test]
    fn pr_queue_item_ci_state_roundtrips_all_variants() {
        for (variant, expected_str) in &[
            (CiState::Unknown, "\"unknown\""),
            (CiState::Pending, "\"pending\""),
            (CiState::Success, "\"success\""),
            (CiState::Failure, "\"failure\""),
        ] {
            let json = serde_json::to_string(variant).expect("serialize");
            assert_eq!(
                &json, expected_str,
                "unexpected serialization for {variant:?}"
            );
            let decoded: CiState = serde_json::from_str(&json).expect("deserialize");
            assert_eq!(decoded, *variant);
        }
    }
}
