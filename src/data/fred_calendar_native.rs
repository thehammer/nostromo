//! Fred calendar native data source — uses Microsoft Graph `calendarView`.
//!
//! Replaces `fred-calendar-pane --json` with a native Rust poller.
//!
//! Sweater thresholds (minutes-to-next-event):
//!   red   = < 5 min
//!   amber = 5–15 min
//!   sage  = > 15 min, or no upcoming event

use std::time::Duration;

use chrono::{DateTime, Duration as ChronoDuration, NaiveDate, TimeZone, Utc};
use serde::Deserialize;
use tokio::sync::{mpsc, watch};
use tracing::{debug, warn};

use crate::{
    config::Config,
    data::{
        dirty_file,
        fred_calendar::{CalendarEvent, CalendarSnapshot, NextEvent},
        fred_mailbox_native::{shared_graph_client, FredTiming},
        graph_client::{failure_reason, GraphClient},
        work::model::SourceState,
    },
};

// ── Graph event shape ─────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GraphEvent {
    id: Option<String>,
    subject: Option<String>,
    start: Option<GraphDateTimeTimeZone>,
    end: Option<GraphDateTimeTimeZone>,
    response_status: Option<GraphResponseStatus>,
    is_cancelled: Option<bool>,
    is_all_day: Option<bool>,
    web_link: Option<String>,
    location: Option<GraphLocation>,
    online_meeting: Option<GraphOnlineMeeting>,
    organizer: Option<GraphOrganizer>,
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

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GraphLocation {
    display_name: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GraphOnlineMeeting {
    join_url: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GraphOrganizer {
    email_address: Option<GraphOrganizerAddress>,
}

#[derive(Debug, Deserialize)]
struct GraphOrganizerAddress {
    name: Option<String>,
}

/// While there is nothing to show (signed out, errored) look again this soon,
/// so data appears within seconds of sign-in rather than a full poll later.
const RETRY_WHILE_EMPTY: Duration = Duration::from_secs(5);

// ── Source ────────────────────────────────────────────────────────────────────

pub struct FredCalendarNativeSource {
    timing: FredTiming,
}

impl FredCalendarNativeSource {
    /// Production entry point: reuses the process-wide Graph client (the same
    /// one the mailbox source uses), so sign-in happens once.
    pub fn spawn(config: Config) -> watch::Receiver<Option<CalendarSnapshot>> {
        let (tx, rx) = watch::channel(None);
        let (dirty_tx, mut dirty_rx) = mpsc::unbounded_channel::<()>();

        let dirty_path = config.fred_state_dir().join("calendar.dirty");
        dirty_file::spawn_watcher(dirty_path, dirty_tx);

        tokio::spawn(async move {
            let graph = match shared_graph_client(&config).await {
                Ok(g) => g,
                Err(unavailable) => {
                    let snapshot = CalendarSnapshot::from(unavailable);
                    warn!("calendar graph client unavailable: {:?}", snapshot.error);
                    let _ = tx.send(Some(snapshot));
                    return;
                }
            };
            let source = FredCalendarNativeSource { timing: FredTiming::default() };
            source.run(graph, tx, &mut dirty_rx).await;
        });

        rx
    }

    /// Poll with an explicit (usually shared) Graph client and timing.
    pub fn spawn_with(
        graph: GraphClient,
        config: Config,
        timing: FredTiming,
    ) -> watch::Receiver<Option<CalendarSnapshot>> {
        let (tx, rx) = watch::channel(None);
        let (dirty_tx, mut dirty_rx) = mpsc::unbounded_channel::<()>();

        let dirty_path = config.fred_state_dir().join("calendar.dirty");
        dirty_file::spawn_watcher(dirty_path, dirty_tx);

        tokio::spawn(async move {
            let source = FredCalendarNativeSource { timing };
            source.run(graph, tx, &mut dirty_rx).await;
        });

        rx
    }

    async fn run(
        &self,
        graph: GraphClient,
        tx: watch::Sender<Option<CalendarSnapshot>>,
        dirty_rx: &mut mpsc::UnboundedReceiver<()>,
    ) {
        loop {
            let previous = tx.borrow().clone();
            let next = self.refresh(&graph, previous.as_ref()).await;
            let nothing_to_show = matches!(
                next.state,
                SourceState::Unauthenticated | SourceState::Error | SourceState::Loading
            );
            let _ = tx.send(Some(next));

            let wait = if nothing_to_show {
                self.timing.calendar_poll.min(RETRY_WHILE_EMPTY)
            } else {
                self.timing.calendar_poll
            };
            tokio::select! {
                _ = tokio::time::sleep(wait) => {}
                _ = dirty_rx.recv() => {
                    debug!("calendar dirty signal received");
                }
            }
        }
    }

    /// One poll cycle. Always yields the snapshot to publish: fresh events,
    /// the sign-in prompt, or the previous events marked stale / an error.
    async fn refresh(
        &self,
        graph: &GraphClient,
        previous: Option<&CalendarSnapshot>,
    ) -> CalendarSnapshot {
        // The mailbox and calendar share one client, so a pending sign-in is
        // the same prompt for both.
        match graph.ensure_authed().await {
            Ok(Some(prompt)) => return CalendarSnapshot::unauthenticated(prompt),
            Ok(None) => {}
            Err(e) => {
                warn!("graph ensure_authed error: {e:#}");
                return CalendarSnapshot::failed(
                    previous,
                    failure_reason("Calendar sign-in failed", &e),
                );
            }
        }

        let (window_start, window_end) = self.today_window_now();
        let path = calendar_view_path(window_start, window_end);
        match graph.get_paged::<GraphEvent>(&path).await {
            Ok(events) => {
                debug!(count = events.len(), "calendar fetch received");
                build_snapshot(events, Utc::now(), (window_start, window_end))
            }
            Err(e) => {
                warn!("calendar fetch failed: {e:#}");
                CalendarSnapshot::failed(previous, failure_reason("Calendar fetch failed", &e))
            }
        }
    }

    fn today_window_now(&self) -> (DateTime<Utc>, DateTime<Utc>) {
        let now = Utc::now();
        match self.timing.day_offset {
            Some(offset) => today_window(now, &offset),
            None => today_window(now, &chrono::Local),
        }
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// `[start, end)` of the calendar day containing `now` in `tz`, as UTC instants
/// (local midnight to the next local midnight — 23 or 25 hours on DST days).
pub fn today_window<Tz: TimeZone>(now: DateTime<Utc>, tz: &Tz) -> (DateTime<Utc>, DateTime<Utc>) {
    let today = now.with_timezone(tz).date_naive();
    let tomorrow = today.succ_opt().unwrap_or(today);
    (local_midnight(today, tz, now), local_midnight(tomorrow, tz, now + ChronoDuration::hours(24)))
}

/// Midnight starting `date` in `tz`. A zone where midnight does not exist (a
/// DST jump at 00:00) starts the day at the first valid instant after it.
fn local_midnight<Tz: TimeZone>(date: NaiveDate, tz: &Tz, fallback: DateTime<Utc>) -> DateTime<Utc> {
    for hour in 0..4 {
        let Some(naive) = date.and_hms_opt(hour, 0, 0) else { continue };
        if let Some(local) = tz.from_local_datetime(&naive).earliest() {
            return local.with_timezone(&Utc);
        }
    }
    fallback
}

fn calendar_view_path(start: DateTime<Utc>, end: DateTime<Utc>) -> String {
    // Plain calendarView (not delta) returns expanded instances with correct dates.
    format!(
        "/me/calendarView?startDateTime={}&endDateTime={}&$select=id,subject,start,end,responseStatus,isCancelled,webLink,location,onlineMeeting,organizer,isAllDay&$top=50",
        start.format("%Y-%m-%dT%H:%M:%SZ"),
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

fn non_empty(s: Option<String>) -> Option<String> {
    s.filter(|v| !v.trim().is_empty())
}

fn build_snapshot(
    raw_events: Vec<GraphEvent>,
    now: DateTime<Utc>,
    window: (DateTime<Utc>, DateTime<Utc>),
) -> CalendarSnapshot {
    let mut events: Vec<CalendarEvent> = raw_events
        .into_iter()
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
            let start_at = start?;
            let is_all_day = ev.is_all_day == Some(true);

            // Defensive: calendarView is already today-only, but drop anything
            // that does not overlap today's window. (All-day events carry
            // midnight-to-midnight times in the event's own zone: trust Graph.)
            if !is_all_day {
                let end_at = end.unwrap_or(start_at);
                if end_at <= window.0 || start_at >= window.1 {
                    return None;
                }
            }

            // calendarView returns expanded instances; subjects are always present.
            // Use "(no title)" as a safe fallback for the rare null case.
            let raw_title = ev.subject.clone().unwrap_or_default();
            let raw_title = if raw_title.trim().is_empty() {
                "(no title)".to_owned()
            } else {
                raw_title
            };

            // Normalize Graph's "Canceled: Foo" title prefix → strip prefix, force status.
            let (title, forced_cancelled) = match raw_title.strip_prefix("Canceled: ") {
                Some(rest) => (rest.to_owned(), true),
                None => (raw_title, false),
            };

            let response = ev
                .response_status
                .as_ref()
                .and_then(|r| r.response.clone())
                .unwrap_or_default();

            let is_cancelled = forced_cancelled || ev.is_cancelled == Some(true);
            let status = if is_cancelled { "cancelled".to_owned() } else { response.clone() };

            let is_now = !is_all_day
                && status != "cancelled"
                && status != "declined"
                && start_at <= now
                && end.is_some_and(|e| e > now);

            Some(CalendarEvent {
                id: ev.id.unwrap_or_default(),
                start,
                end,
                title,
                status,
                is_now,
                web_link: non_empty(ev.web_link),
                location: non_empty(ev.location.and_then(|l| l.display_name)),
                online_meeting_url: non_empty(ev.online_meeting.and_then(|m| m.join_url)),
                organizer: non_empty(
                    ev.organizer
                        .and_then(|o| o.email_address)
                        .and_then(|a| a.name),
                ),
                is_cancelled,
                response_status: response,
                is_all_day,
            })
        })
        .collect();

    // Sort by start time ascending (then end, so the order is deterministic).
    events.sort_by_key(|ev| (ev.start, ev.end));

    // Find next upcoming event — skip cancelled/declined/all-day.
    let next = events.iter().find(|ev| {
        ev.start.is_some_and(|s| s > now)
            && ev.status != "cancelled"
            && ev.status != "declined"
            && !ev.is_all_day
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

    let state = if events.is_empty() { SourceState::Empty } else { SourceState::Fresh };
    CalendarSnapshot {
        events,
        next: next_event,
        sweater,
        stale: false,
        error: None,
        generated_at: Some(now),
        state,
        updated_at: Some(now),
        auth_prompt: None,
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
