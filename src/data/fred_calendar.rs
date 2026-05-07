//! Fred calendar data source.
//!
//! Phase 1: shells out to `~/.claude/bin/fred-calendar-pane --json`.
//!
//! Expected JSON shape:
//! ```json
//! {
//!   "events": [
//!     {
//!       "start": "2026-05-07T14:00:00Z",
//!       "end":   "2026-05-07T15:00:00Z",
//!       "title": "Weekly sync",
//!       "status": "accepted",
//!       "is_now": false
//!     }
//!   ],
//!   "next": {
//!     "title": "Weekly sync",
//!     "in_minutes": 45
//!   },
//!   "sweater": "sage"
//! }
//! ```

use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use tokio::sync::{mpsc, watch};
use tracing::{debug, warn};

use crate::{config::Config, data::dirty_file};

// ── Snapshot types ──────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct CalendarEvent {
    pub start: Option<DateTime<Utc>>,
    pub end: Option<DateTime<Utc>>,
    pub title: String,
    pub status: String,
    pub is_now: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct NextEvent {
    pub title: String,
    pub in_minutes: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct CalendarSnapshot {
    pub events: Vec<CalendarEvent>,
    pub next: Option<NextEvent>,
    /// "sage" | "amber" | "red"
    pub sweater: String,
    pub stale: bool,
    pub error: Option<String>,
}

// ── Source ──────────────────────────────────────────────────────────────────

pub struct FredCalendarSource {
    config: Config,
}

impl FredCalendarSource {
    pub fn spawn(config: Config) -> watch::Receiver<Option<CalendarSnapshot>> {
        let (tx, rx) = watch::channel(None);
        let (dirty_tx, mut dirty_rx) = mpsc::unbounded_channel::<()>();

        let dirty_path = config.fred_state_dir().join("calendar.dirty");
        dirty_file::spawn_watcher(dirty_path, dirty_tx);

        let interval = config.calendar_poll_interval();

        tokio::spawn(async move {
            let source = FredCalendarSource { config };
            loop {
                match source.fetch().await {
                    Ok(snap) => {
                        debug!(sweater = %snap.sweater, events = snap.events.len(), "calendar refreshed");
                        let _ = tx.send(Some(snap));
                    }
                    Err(e) => {
                        warn!("calendar fetch failed: {e:#}");
                        let mut snap = tx.borrow().clone().unwrap_or_default();
                        snap.stale = true;
                        snap.error = Some(e.to_string());
                        let _ = tx.send(Some(snap));
                    }
                }

                tokio::select! {
                    _ = tokio::time::sleep(interval) => {}
                    _ = dirty_rx.recv() => {
                        debug!("calendar dirty signal received");
                    }
                }
            }
        });

        rx
    }

    async fn fetch(&self) -> Result<CalendarSnapshot> {
        let bin = self.config.claude_bin_dir().join("fred-calendar-pane");
        let output = tokio::process::Command::new(&bin)
            .arg("--json")
            .env("FRED_HOME", self.config.claude_bin_dir().parent().unwrap_or_else(|| std::path::Path::new(".")))
            .env("FRED_STATE", self.config.fred_state_dir())
            .output()
            .await
            .with_context(|| format!("running {}", bin.display()))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            anyhow::bail!("fred-calendar-pane --json exited non-zero: {stderr}");
        }

        let snap: CalendarSnapshot = serde_json::from_slice(&output.stdout)
            .with_context(|| "parsing fred-calendar-pane --json output")?;
        Ok(snap)
    }
}
