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
