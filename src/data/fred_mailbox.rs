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
    data::{dirty_file, work::model::SourceState},
};

// ── Snapshot types ──────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct MailboxItem {
    /// Graph message id (stable across polls). Empty for the legacy bash source.
    #[serde(default)]
    pub id: String,
    pub from: String,
    pub subject: String,
    pub received_at: Option<DateTime<Utc>>,
    pub vip: bool,
    pub is_invite: bool,
    pub is_read: bool,
    /// Link that opens the message in Outlook on the web.
    #[serde(default)]
    pub web_link: Option<String>,
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
    /// What the user should see: never `fresh`/`empty` when the fetch failed.
    #[serde(default)]
    pub state: SourceState,
    /// Last *successful* fetch (kept across stale snapshots).
    #[serde(default)]
    pub updated_at: Option<DateTime<Utc>>,
    /// When `state` is `rate_limited`: the earliest time the daemon will ask
    /// Graph again.
    #[serde(default)]
    pub retry_at: Option<DateTime<Utc>>,
}

impl MailboxSnapshot {
    /// The snapshot to publish when a fetch failed: the previous good data
    /// (when there is any) marked `stale`, otherwise an `error` snapshot with
    /// no items. Never `fresh`/`empty`.
    pub fn failed(previous: Option<&MailboxSnapshot>, reason: String) -> MailboxSnapshot {
        let has_data = previous.is_some_and(|p| p.updated_at.is_some());
        match previous {
            Some(prev) if has_data => MailboxSnapshot {
                state: SourceState::Stale,
                stale: true,
                error: Some(reason),
                auth_prompt: None,
                retry_at: None,
                ..prev.clone()
            },
            _ => MailboxSnapshot {
                generated_at: Some(Utc::now()),
                state: SourceState::Error,
                stale: false,
                error: Some(reason),
                ..Default::default()
            },
        }
    }

    /// The snapshot to publish when Graph is throttling us: like `failed`
    /// (previous good data kept, marked `stale`; never `fresh`/`empty`) but in
    /// the `rate_limited` state with the time we will ask again.
    pub fn rate_limited(previous: Option<&MailboxSnapshot>, reason: String, retry_at: DateTime<Utc>) -> MailboxSnapshot {
        MailboxSnapshot {
            state: SourceState::RateLimited,
            retry_at: Some(retry_at),
            ..Self::failed(previous, reason)
        }
    }

    /// The snapshot to publish while the user must sign in: no data, the
    /// device-flow prompt, and a plain-English reason. Carries no token.
    pub fn unauthenticated(prompt: DeviceFlowPrompt) -> MailboxSnapshot {
        MailboxSnapshot {
            generated_at: Some(Utc::now()),
            state: SourceState::Unauthenticated,
            error: Some("Sign in to Microsoft 365 to see your mail".to_owned()),
            auth_prompt: Some(prompt),
            ..Default::default()
        }
    }

    /// Fill `state`/`updated_at` on a snapshot from the legacy bash source,
    /// which knows nothing about them.
    fn with_legacy_state(mut self) -> MailboxSnapshot {
        self.state = if self.auth_prompt.is_some() {
            SourceState::Unauthenticated
        } else if self.stale {
            SourceState::Stale
        } else if self.error.is_some() {
            SourceState::Error
        } else if self.items.is_empty() && self.unread_count == 0 {
            SourceState::Empty
        } else {
            SourceState::Fresh
        };
        if !matches!(self.state, SourceState::Error | SourceState::Unauthenticated) {
            self.updated_at = self.updated_at.or(self.generated_at);
        }
        self
    }
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
                        let _ = tx.send(Some(snap.with_legacy_state()));
                    }
                    Err(e) => {
                        warn!("mailbox fetch failed: {e:#}");
                        // Previous data marked stale, or an error with no data.
                        let previous = tx.borrow().clone();
                        let _ = tx.send(Some(MailboxSnapshot::failed(
                            previous.as_ref(),
                            e.to_string(),
                        )));
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
            .env(
                "FRED_HOME",
                self.config
                    .claude_bin_dir()
                    .parent()
                    .unwrap_or_else(|| std::path::Path::new(".")),
            )
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
