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
//!       "requested": true,
//!       "url": "https://github.com/acme/web-app/pull/42"
//!     }
//!   ],
//!   "stale": false
//! }
//! ```

use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use tokio::sync::{mpsc, watch};
use tracing::{debug, warn};

use crate::{config::Config, data::dirty_file};

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct PrQueueItem {
    pub repo: String,
    pub number: u64,
    pub title: String,
    pub author: String,
    pub requested: bool,
    pub url: String,
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
            .env("PERRI_HOME", self.config.claude_bin_dir().parent().unwrap_or_else(|| std::path::Path::new(".")))
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
