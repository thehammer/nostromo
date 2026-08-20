//! Perri current-PR data source.
//!
//! Phase 1: shells out to `~/.claude/bin/perri-diff-pane --json`.
//!
//! Expected JSON shape:
//! ```json
//! {
//!   "pr_number": 234,
//!   "repo": "acme/web-app",
//!   "title": "feat: add user authentication",
//!   "author": "alice",
//!   "url": "https://github.com/acme/web-app/pull/42",
//!   "diff": "...",
//!   "stale": false
//! }
//! ```

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use tokio::sync::{mpsc, watch};
use tracing::{debug, warn};

use crate::{config::Config, data::dirty_file, data::perri_queue::CiState};

/// A single CI check-run result attached to a PR snapshot.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct CiCheck {
    pub name: String,
    pub state: CiState,
    /// For failing checks: the truncated failure-log tail (see D3).
    /// `None` for passing / pending / unknown checks.
    pub detail: Option<String>,
}

/// What kind of GitHub thread a [`PrThread`] came from (W3 —
/// curated-agent-views).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum PrThreadKind {
    /// A top-level issue comment on the PR's "Conversation" tab.
    #[default]
    Issue,
    /// A whole-PR review (approve/request-changes/comment) with a body.
    Review,
    /// An inline review comment thread anchored to a file/line.
    Inline,
}

/// One raw (still-markdown) comment within a [`PrThread`] (W3 —
/// curated-agent-views).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PrComment {
    pub id: String,
    pub author: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
    /// Raw markdown, converted to `MdBlock`s only in the source's `fetch`
    /// (D2 — a cache written by an older binary stays readable, and a change
    /// to the block model needs no cache migration).
    pub body: String,
}

/// One comment thread on a PR — a single issue comment, a whole-PR review, or
/// an inline review-comment thread assembled by walking `in_reply_to_id` to
/// its root (W3 — curated-agent-views).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PrThread {
    pub id: String,
    pub kind: PrThreadKind,
    /// Inline threads only.
    #[serde(default)]
    pub path: Option<String>,
    /// Inline threads only, new-side line number.
    #[serde(default)]
    pub line: Option<u32>,
    #[serde(default)]
    pub diff_hunk: Option<String>,
    /// GitHub's REST API does not expose inline-thread resolution status
    /// (that's a GraphQL-only `reviewThreads.isResolved` field); this stays
    /// `false` until a resolver is added.
    #[serde(default)]
    pub resolved: bool,
    /// Chronological.
    pub comments: Vec<PrComment>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct PrSnapshot {
    pub pr_number: Option<u64>,
    pub repo: String,
    pub title: String,
    pub author: String,
    pub url: String,
    /// Raw diff text (may be large; phase 2 adds syntax highlighting).
    pub diff: String,
    pub stale: bool,
    pub error: Option<String>,
    /// The PR description, raw markdown (W3 — curated-agent-views).
    #[serde(default)]
    pub body: String,
    /// Comment/review threads (W3 — curated-agent-views).
    #[serde(default)]
    pub threads: Vec<PrThread>,
    /// Set when the PR fetch itself succeeded but fetching the conversation
    /// (issue comments / review comments / reviews) failed. `threads` then
    /// carries whatever was retrieved before the failure — never blanked, and
    /// never presented as if it were a complete conversation (W3 —
    /// curated-agent-views).
    #[serde(default)]
    pub conversation_error: Option<String>,
    /// When this snapshot was last fetched successfully. `None` when the
    /// source has never produced good data (see `PaneFreshness`/D6 — a `None`
    /// combined with `stale: true` means "badly stale immediately").
    #[serde(default)]
    pub generated_at: Option<chrono::DateTime<chrono::Utc>>,
    /// Per-check CI results (empty when unknown / not yet fetched).
    #[serde(default)]
    pub ci_checks: Vec<CiCheck>,
    /// PR additions from the GitHub API.
    #[serde(default)]
    pub additions: u64,
    /// PR deletions from the GitHub API.
    #[serde(default)]
    pub deletions: u64,
    /// Number of files changed in this PR.
    #[serde(default)]
    pub changed_files: u64,
    /// HEAD SHA this snapshot was fetched at — lets the GUI match cache to queue.
    #[serde(default)]
    pub head_sha: String,
    /// True when the diff exceeded the render threshold; `diff` is blanked.
    #[serde(default)]
    pub diff_too_large: bool,
}

pub struct PerriPrSource {
    config: Config,
}

impl PerriPrSource {
    pub fn spawn(config: Config) -> watch::Receiver<Option<PrSnapshot>> {
        let (tx, rx) = watch::channel(None);
        let (dirty_tx, mut dirty_rx) = mpsc::unbounded_channel::<()>();

        let dirty_path = config.perri_state_dir().join("current-pr.dirty");
        dirty_file::spawn_watcher(dirty_path, dirty_tx);

        let interval = config.pr_diff_poll_interval();

        tokio::spawn(async move {
            let source = PerriPrSource { config };
            loop {
                match source.fetch().await {
                    Ok(snap) => {
                        debug!(pr = ?snap.pr_number, "perri diff refreshed");
                        let _ = tx.send(Some(snap));
                    }
                    Err(e) => {
                        warn!("perri diff fetch failed: {e:#}");
                        let mut snap = tx.borrow().clone().unwrap_or_default();
                        snap.stale = true;
                        snap.error = Some(e.to_string());
                        let _ = tx.send(Some(snap));
                    }
                }

                tokio::select! {
                    _ = tokio::time::sleep(interval) => {}
                    _ = dirty_rx.recv() => {
                        debug!("perri diff dirty signal");
                    }
                }
            }
        });

        rx
    }

    async fn fetch(&self) -> Result<PrSnapshot> {
        let bin = self.config.claude_bin_dir().join("perri-diff-pane");
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
            anyhow::bail!("perri-diff-pane --json exited non-zero: {stderr}");
        }

        let snap: PrSnapshot = serde_json::from_slice(&output.stdout)
            .with_context(|| "parsing perri-diff-pane --json output")?;
        Ok(snap)
    }
}

// ── tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ── 1. cache compatibility (W3 — curated-agent-views) ────────────────────

    #[test]
    fn a_pr_snapshot_json_literal_missing_the_conversation_fields_still_deserializes() {
        // Exactly the shape a `pr-cache/*.json` written by a pre-W3 binary
        // would carry: no `body`, no `threads`, no `conversation_error` at
        // all. Every new field must be `#[serde(default)]` or an old cache
        // file (and every hand-written `PrSnapshot` JSON literal in the test
        // helpers across the codebase) breaks on the next daemon version.
        let json = serde_json::json!({
            "pr_number": 42,
            "repo": "acme/web",
            "title": "Add widget",
            "author": "alice",
            "url": "https://example.com/42",
            "diff": "",
            "stale": false,
            "error": null
        });
        let snap: PrSnapshot = serde_json::from_value(json).expect(
            "a pre-W3 PrSnapshot JSON literal (no body/threads/conversation_error) must still deserialize",
        );
        assert_eq!(snap.body, "", "missing body must default to an empty string");
        assert!(snap.threads.is_empty(), "missing threads must default to an empty vec");
        assert_eq!(
            snap.conversation_error, None,
            "missing conversation_error must default to None"
        );
    }

    #[test]
    fn a_pr_snapshot_json_literal_carrying_conversation_fields_round_trips_them() {
        let json = serde_json::json!({
            "pr_number": 42,
            "repo": "acme/web",
            "title": "Add widget",
            "author": "alice",
            "url": "https://example.com/42",
            "diff": "",
            "stale": false,
            "error": null,
            "body": "PR description",
            "threads": [{
                "id": "issue-1",
                "kind": "issue",
                "resolved": false,
                "comments": [{
                    "id": "1",
                    "author": "alice",
                    "created_at": "2024-01-01T00:00:00Z",
                    "body": "a comment"
                }]
            }],
            "conversation_error": "conversation fetch partially failed: reviews"
        });
        let snap: PrSnapshot = serde_json::from_value(json).unwrap();
        assert_eq!(snap.body, "PR description");
        assert_eq!(snap.threads.len(), 1);
        assert_eq!(snap.threads[0].kind, PrThreadKind::Issue);
        assert_eq!(
            snap.conversation_error,
            Some("conversation fetch partially failed: reviews".to_string())
        );
    }
}
