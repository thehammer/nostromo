//! Fred mailbox data source.
//!
//! Phase 1: shells out to `~/.claude/bin/fred-mailbox-pane --json` and parses
//! the structured output into `MailboxSnapshot`.
//!
//! Expected JSON shape (emitted by the bash `--json` flag):
//! ```json
//! {
//!   "generated_at": "2026-05-07T14:02:00Z",
//!   "unread_count": 3,
//!   "items": [
//!     {
//!       "from": "Alice Smith <alice@example.com>",
//!       "subject": "Weekly sync",
//!       "received_at": "2026-05-07T13:55:00Z",
//!       "vip": false,
//!       "is_invite": false
//!     }
//!   ]
//! }
//! ```


use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use tokio::sync::{mpsc, watch};
use tracing::{debug, warn};

pub use crate::data::graph_client::DeviceFlowPrompt;

use crate::{
    config::Config,
    data::dirty_file,
};

// ── Snapshot types ──────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct MailboxItem {
    pub from: String,
    pub subject: String,
    pub received_at: Option<DateTime<Utc>>,
    pub vip: bool,
    pub is_invite: bool,
    pub is_read: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct MailboxSnapshot {
    pub generated_at: Option<DateTime<Utc>>,
    pub unread_count: usize,
    pub items: Vec<MailboxItem>,
    /// True when data comes from cache / last successful fetch.
    pub stale: bool,
    /// Error message if last fetch failed.
    pub error: Option<String>,
    /// Present when Graph auth is required (device-flow prompt for the TUI).
    /// `serde(default)` keeps the bash source's JSON (which omits this field)
    /// backwards-compatible.
    #[serde(default)]
    pub auth_prompt: Option<DeviceFlowPrompt>,
}

// ── Source ──────────────────────────────────────────────────────────────────

pub struct FredMailboxSource {
    config: Config,
}

impl FredMailboxSource {
    /// Spawn the background polling task and return the watch receiver.
    pub fn spawn(config: Config) -> watch::Receiver<Option<MailboxSnapshot>> {
        let (tx, rx) = watch::channel(None);
        let (dirty_tx, mut dirty_rx) = mpsc::unbounded_channel::<()>();

        // Watch the dirty sentinel file.
        let dirty_path = config.fred_state_dir().join("mailbox.dirty");
        dirty_file::spawn_watcher(dirty_path, dirty_tx);

        let interval = config.mailbox_poll_interval();

        tokio::spawn(async move {
            let source = FredMailboxSource { config };
            loop {
                match source.fetch().await {
                    Ok(snap) => {
                        debug!(unread = snap.unread_count, "mailbox refreshed");
                        let _ = tx.send(Some(snap));
                    }
                    Err(e) => {
                        warn!("mailbox fetch failed: {e:#}");
                        // Send a stale snapshot with the error annotated.
                        let mut snap = tx.borrow().clone().unwrap_or_default();
                        snap.stale = true;
                        snap.error = Some(e.to_string());
                        let _ = tx.send(Some(snap));
                    }
                }

                // Wait for either the interval or a dirty signal.
                tokio::select! {
                    _ = tokio::time::sleep(interval) => {}
                    _ = dirty_rx.recv() => {
                        debug!("mailbox dirty signal received");
                    }
                }
            }
        });

        rx
    }

    async fn fetch(&self) -> Result<MailboxSnapshot> {
        let bin = self.config.claude_bin_dir().join("fred-mailbox-pane");
        let output = tokio::process::Command::new(&bin)
            .arg("--json")
            .env("FRED_HOME", self.config.claude_bin_dir().parent().unwrap_or_else(|| std::path::Path::new(".")))
            .env("FRED_STATE", self.config.fred_state_dir())
            .output()
            .await
            .with_context(|| format!("running {}", bin.display()))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            anyhow::bail!("fred-mailbox-pane --json exited non-zero: {stderr}");
        }

        let snap: MailboxSnapshot = serde_json::from_slice(&output.stdout)
            .with_context(|| "parsing fred-mailbox-pane --json output")?;
        Ok(snap)
    }
}
