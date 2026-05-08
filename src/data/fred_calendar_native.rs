//! Fred calendar native data source — uses Microsoft Graph `calendarView/delta`.
//!
//! Replaces `fred-calendar-pane --json` with a native Rust poller.
//!
//! Sweater thresholds (minutes-to-next-event):
//!   red   = < 5 min
//!   amber = 5–15 min
//!   sage  = > 15 min, or no upcoming event

use std::collections::HashMap;
use std::path::PathBuf;

use anyhow::Result;
use chrono::{DateTime, Duration as ChronoDuration, Utc};
use serde::Deserialize;
use tokio::sync::{mpsc, watch};
use tracing::{debug, warn};

use crate::{
    config::Config,
    data::{
        dirty_file,
        fred_calendar::{CalendarEvent, CalendarSnapshot, NextEvent},
        graph_client::GraphClient,
    },
};

// ── Graph event shape ─────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GraphEvent {
    id: String,
    subject: Option<String>,
    start: Option<GraphDateTimeTimeZone>,
    end: Option<GraphDateTimeTimeZone>,
    response_status: Option<GraphResponseStatus>,
    #[serde(rename = "@removed")]
    removed: Option<serde_json::Value>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GraphDateTimeTimeZone {
    date_time: Option<String>,
}

#[derive(Debug, Deserialize)]
struct GraphResponseStatus {
    response: Option<String>,
}

// ── Source ────────────────────────────────────────────────────────────────────

pub struct FredCalendarNativeSource {
    config: Config,
}

impl FredCalendarNativeSource {
    pub fn spawn(config: Config) -> watch::Receiver<Option<CalendarSnapshot>> {
        let (tx, rx) = watch::channel(None);
        let (dirty_tx, mut dirty_rx) = mpsc::unbounded_channel::<()>();

        let dirty_path = config.fred_state_dir().join("calendar.dirty");
        dirty_file::spawn_watcher(dirty_path, dirty_tx);

        tokio::spawn(async move {
            let source = FredCalendarNativeSource { config };
            source.run(tx, &mut dirty_rx).await;
        });

        rx
    }

    async fn run(
        &self,
        tx: watch::Sender<Option<CalendarSnapshot>>,
        dirty_rx: &mut mpsc::UnboundedReceiver<()>,
    ) {
        let graph = match self.build_graph_client().await {
            Ok(g) => g,
            Err(e) => {
                warn!("failed to build graph client for calendar: {e:#}");
                let _ = tx.send(Some(CalendarSnapshot {
                    error: Some(format!("Graph client init failed: {e:#}")),
                    stale: true,
                    sweater: "sage".to_owned(),
                    ..Default::default()
                }));
                return;
            }
        };

        let delta_file = self.delta_cache_dir().join("calendar.delta");
        let mut store: HashMap<String, GraphEvent> = HashMap::new();

        loop {
            match graph.ensure_authed().await {
                Ok(Some(_prompt)) => {
                    // Calendar waits for mailbox auth prompt to drive sign-in.
                }
                Ok(None) => {
                    let initial_path = calendar_delta_path();
                    match graph
                        .delta::<GraphEvent>(&initial_path, &delta_file)
                        .await
                    {
                        Ok((events, _dl)) => {
                            debug!(count = events.len(), "calendar delta received");
                            for ev in events {
                                if ev.removed.is_some() {
                                    store.remove(&ev.id);
                                } else {
                                    store.insert(ev.id.clone(), ev);
                                }
                            }
                            let snap = build_snapshot(&store);
                            debug!(sweater = %snap.sweater, events = snap.events.len(), "calendar refreshed");
                            let _ = tx.send(Some(snap));
                        }
                        Err(e) => {
                            warn!("calendar delta failed: {e:#}");
                            let mut snap = tx.borrow().clone().unwrap_or_default();
                            snap.stale = true;
                            snap.error = Some(e.to_string());
                            let _ = tx.send(Some(snap));
                        }
                    }
                }
                Err(e) => warn!("graph ensure_authed error: {e:#}"),
            }

            tokio::select! {
                _ = tokio::time::sleep(std::time::Duration::from_secs(5)) => {}
                _ = dirty_rx.recv() => {
                    debug!("calendar dirty signal received");
                }
            }
        }
    }

    async fn build_graph_client(&self) -> Result<GraphClient> {
        let client_id = self.config.graph_client_id.clone().unwrap_or_default();
        let tenant = self
            .config
            .graph_tenant
            .clone()
            .unwrap_or_else(|| "common".to_owned());
        let cache_path = self.config.graph_token_cache_path();
        GraphClient::new(client_id, tenant, cache_path).await
    }

    fn delta_cache_dir(&self) -> PathBuf {
        home_dir().join(".cache").join("nostromo")
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn calendar_delta_path() -> String {
    let now = Utc::now();
    let end = now + ChronoDuration::hours(24);
    format!(
        "/me/calendarView/delta?startDateTime={}&endDateTime={}",
        now.format("%Y-%m-%dT%H:%M:%SZ"),
        end.format("%Y-%m-%dT%H:%M:%SZ"),
    )
}

fn parse_graph_dt(s: &str) -> Option<DateTime<Utc>> {
    // Graph returns ISO 8601; strip trailing fractional seconds and ensure UTC suffix.
    let clean = s.trim_end_matches('Z').split('.').next().unwrap_or(s);
    let with_z = format!("{clean}Z");
    DateTime::parse_from_rfc3339(&with_z)
        .ok()
        .map(|dt| dt.with_timezone(&Utc))
}

fn build_snapshot(store: &HashMap<String, GraphEvent>) -> CalendarSnapshot {
    let now = Utc::now();

    let mut events: Vec<CalendarEvent> = store
        .values()
        .map(|ev| {
            let start = ev
                .start
                .as_ref()
                .and_then(|d| d.date_time.as_deref())
                .and_then(parse_graph_dt);
            let end = ev
                .end
                .as_ref()
                .and_then(|d| d.date_time.as_deref())
                .and_then(parse_graph_dt);
            let title = ev.subject.clone().unwrap_or_default();
            let status = ev
                .response_status
                .as_ref()
                .and_then(|r| r.response.clone())
                .unwrap_or_default();
            let is_now = start.map(|s| s <= now).unwrap_or(false)
                && end.map(|e| e > now).unwrap_or(false);

            CalendarEvent {
                start,
                end,
                title,
                status,
                is_now,
            }
        })
        .collect();

    // Sort by start time ascending.
    events.sort_by_key(|ev| ev.start);

    // Find next upcoming event.
    let next = events.iter().find(|ev| {
        ev.start
            .map(|s| s > now)
            .unwrap_or(false)
    });

    let (next_event, sweater) = match next {
        Some(ev) => {
            let mins = ev
                .start
                .map(|s| (s - now).num_minutes())
                .unwrap_or(i64::MAX);
            let sweater = sweater_for_minutes(mins);
            let ne = NextEvent {
                title: ev.title.clone(),
                in_minutes: mins,
            };
            (Some(ne), sweater)
        }
        None => (None, "sage".to_owned()),
    };

    CalendarSnapshot {
        events,
        next: next_event,
        sweater,
        stale: false,
        error: None,
    }
}

fn sweater_for_minutes(mins: i64) -> String {
    if mins < 5 {
        "red".to_owned()
    } else if mins <= 15 {
        "amber".to_owned()
    } else {
        "sage".to_owned()
    }
}

fn home_dir() -> PathBuf {
    std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("."))
}
