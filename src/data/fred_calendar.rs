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

use crate::{
    config::Config,
    data::{dirty_file, graph_client::DeviceFlowPrompt, work::model::SourceState},
};

// ── Snapshot types ──────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct CalendarEvent {
    /// Graph event id. Empty for the legacy bash source.
    #[serde(default)]
    pub id: String,
    pub start: Option<DateTime<Utc>>,
    pub end: Option<DateTime<Utc>>,
    pub title: String,
    pub status: String,
    pub is_now: bool,
    /// Link that opens the event in Outlook on the web.
    #[serde(default)]
    pub web_link: Option<String>,
    #[serde(default)]
    pub location: Option<String>,
    /// Teams (or other) join link.
    #[serde(default)]
    pub online_meeting_url: Option<String>,
    /// Organizer's display name.
    #[serde(default)]
    pub organizer: Option<String>,
    #[serde(default)]
    pub is_cancelled: bool,
    /// Raw Graph `responseStatus.response` ("accepted", "tentativelyAccepted", ...).
    #[serde(default)]
    pub response_status: String,
    /// All-day events are never "now" and never the next meeting.
    #[serde(default)]
    pub is_all_day: bool,
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
    /// When this snapshot was produced (UTC). `None` for snapshots from older
    /// sources / persisted frames that predate the field.
    #[serde(default)]
    pub generated_at: Option<DateTime<Utc>>,
    /// What the user should see: never `fresh`/`empty` when the fetch failed.
    #[serde(default)]
    pub state: SourceState,
    /// Last *successful* fetch (kept across stale snapshots).
    #[serde(default)]
    pub updated_at: Option<DateTime<Utc>>,
    /// The sign-in prompt when Graph auth is pending (same prompt as the mailbox's).
    #[serde(default)]
    pub auth_prompt: Option<DeviceFlowPrompt>,
}

impl CalendarSnapshot {
    /// The snapshot to publish when a fetch failed: the previous good data
    /// (when there is any) marked `stale`, otherwise an `error` snapshot with
    /// no events. Never `fresh`/`empty`.
    pub fn failed(previous: Option<&CalendarSnapshot>, reason: String) -> CalendarSnapshot {
        let has_data = previous.is_some_and(|p| p.updated_at.is_some());
        match previous {
            Some(prev) if has_data => CalendarSnapshot {
                state: SourceState::Stale,
                stale: true,
                error: Some(reason),
                auth_prompt: None,
                ..prev.clone()
            },
            _ => CalendarSnapshot {
                generated_at: Some(Utc::now()),
                sweater: "sage".to_owned(),
                state: SourceState::Error,
                error: Some(reason),
                ..Default::default()
            },
        }
    }

    /// The snapshot to publish while the user must sign in: no data, the
    /// device-flow prompt, and a plain-English reason. Carries no token.
    pub fn unauthenticated(prompt: DeviceFlowPrompt) -> CalendarSnapshot {
        CalendarSnapshot {
            generated_at: Some(Utc::now()),
            sweater: "sage".to_owned(),
            state: SourceState::Unauthenticated,
            error: Some("Sign in to Microsoft 365 to see your calendar".to_owned()),
            auth_prompt: Some(prompt),
            ..Default::default()
        }
    }

    /// Fill `state`/`updated_at` on a snapshot from the legacy bash source.
    fn with_legacy_state(mut self) -> CalendarSnapshot {
        self.state = if self.stale {
            SourceState::Stale
        } else if self.error.is_some() {
            SourceState::Error
        } else if self.events.is_empty() {
            SourceState::Empty
        } else {
            SourceState::Fresh
        };
        if !matches!(self.state, SourceState::Error) {
            self.updated_at = self.updated_at.or(self.generated_at);
        }
        self
    }
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
                        let _ = tx.send(Some(snap.with_legacy_state()));
                    }
                    Err(e) => {
                        warn!("calendar fetch failed: {e:#}");
                        let previous = tx.borrow().clone();
                        let _ = tx.send(Some(CalendarSnapshot::failed(
                            previous.as_ref(),
                            e.to_string(),
                        )));
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
            anyhow::bail!("fred-calendar-pane --json exited non-zero: {stderr}");
        }

        let snap: CalendarSnapshot = serde_json::from_slice(&output.stdout)
            .with_context(|| "parsing fred-calendar-pane --json output")?;
        Ok(snap)
    }
}
