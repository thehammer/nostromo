//! Fred calendar native data source — uses Microsoft Graph `calendarView`.
//!
//! Replaces `fred-calendar-pane --json` with a native Rust poller.
//!
//! Sweater thresholds (minutes-to-next-event):
//!   red   = < 5 min
//!   amber = 5–15 min
//!   sage  = > 15 min, or no upcoming event

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
    subject: Option<String>,
    start: Option<GraphDateTimeTimeZone>,
    end: Option<GraphDateTimeTimeZone>,
    response_status: Option<GraphResponseStatus>,
    is_cancelled: Option<bool>,
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

        loop {
            match graph.ensure_authed().await {
                Ok(Some(_prompt)) => {
                    // Calendar waits for mailbox auth prompt to drive sign-in.
                }
                Ok(None) => {
                    let path = calendar_view_path();
                    match graph.get_paged::<GraphEvent>(&path).await {
                        Ok(events) => {
                            debug!(count = events.len(), "calendar fetch received");
                            let snap = build_snapshot(events);
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
                }
                Err(e) => warn!("graph ensure_authed error: {e:#}"),
            }

            tokio::select! {
                _ = tokio::time::sleep(std::time::Duration::from_secs(30)) => {}
                _ = dirty_rx.recv() => {
                    debug!("calendar dirty signal received");
                }
            }
        }
    }

    async fn build_graph_client(&self) -> Result<GraphClient> {
        let client_id = self.config.graph_client_id.clone().ok_or_else(|| {
            anyhow::anyhow!(
                "graph_client_id not configured. \
                     Add to ~/.config/nostromo/config.toml:\n  \
                     graph_client_id = \"<your-azure-app-id>\"\n\n\
                     Or use --bash-fallback flag to use legacy bash sources."
            )
        })?;

        if client_id.trim().is_empty() {
            return Err(anyhow::anyhow!(
                "graph_client_id is empty. \
                 Set a valid Azure AD application ID in ~/.config/nostromo/config.toml:\n  \
                 graph_client_id = \"<your-azure-app-id>\"\n\n\
                 Or use --bash-fallback flag to use legacy bash sources."
            ));
        }

        let tenant = self
            .config
            .graph_tenant
            .clone()
            .unwrap_or_else(|| "common".to_owned());
        let cache_path = self.config.graph_token_cache_path();
        GraphClient::new(client_id, tenant, cache_path).await
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn calendar_view_path() -> String {
    // Start at midnight local time today so events earlier in the day are included.
    // Uses plain calendarView (not delta) to get expanded instances with correct dates.
    let today_local = chrono::Local::now().date_naive();
    let start_local = today_local.and_hms_opt(0, 0, 0).expect("midnight is valid");
    let start_utc: DateTime<Utc> =
        chrono::TimeZone::from_local_datetime(&chrono::Local, &start_local)
            .single()
            .unwrap_or_else(|| Utc::now().with_timezone(&chrono::Local))
            .with_timezone(&Utc);
    let end_utc = start_utc + ChronoDuration::hours(24);
    format!(
        "/me/calendarView?startDateTime={}&endDateTime={}&$select=subject,start,end,responseStatus,isCancelled&$top=50",
        start_utc.format("%Y-%m-%dT%H:%M:%SZ"),
        end_utc.format("%Y-%m-%dT%H:%M:%SZ"),
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

fn build_snapshot(raw_events: Vec<GraphEvent>) -> CalendarSnapshot {
    let now = Utc::now();

    // calendarView already returns only events within today's window — no date
    // filtering needed here.  Just parse and convert every returned event.
    let mut events: Vec<CalendarEvent> = raw_events
        .iter()
        .filter_map(|ev| {
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

            // Skip events with no parseable start time.
            start?;

            // calendarView returns expanded instances; subjects are always present.
            // Use "(no title)" as a safe fallback for the rare null case.
            let raw_title = ev.subject.clone().unwrap_or_default();
            let raw_title = if raw_title.trim().is_empty() {
                "(no title)".to_owned()
            } else {
                raw_title
            };

            // Normalize Graph's "Canceled: Foo" title prefix → strip prefix, force status.
            let (title, forced_cancelled) = if raw_title.starts_with("Canceled: ") {
                (
                    raw_title
                        .strip_prefix("Canceled: ")
                        .unwrap_or(&raw_title)
                        .to_owned(),
                    true,
                )
            } else {
                (raw_title, false)
            };

            let response = ev
                .response_status
                .as_ref()
                .and_then(|r| r.response.clone())
                .unwrap_or_default();

            let status = if forced_cancelled || ev.is_cancelled == Some(true) {
                "cancelled".to_owned()
            } else {
                response
            };

            let is_now =
                start.map(|s| s <= now).unwrap_or(false) && end.map(|e| e > now).unwrap_or(false);

            Some(CalendarEvent {
                start,
                end,
                title,
                status,
                is_now,
            })
        })
        .collect();

    // Sort by start time ascending.
    events.sort_by_key(|ev| ev.start);

    // Find next upcoming event — skip cancelled/declined.
    let next = events.iter().find(|ev| {
        ev.start.map(|s| s > now).unwrap_or(false)
            && ev.status != "cancelled"
            && ev.status != "declined"
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
