//! Fred calendar source for one Google account.
//!
//! Each poll is one windowed `events.list` for today on the primary calendar,
//! the same shape as the Graph source's `calendarView` read. Calendar's
//! `syncToken` is not used: the API refuses it together with `timeMin`/`timeMax`
//! and `orderBy`, and an unbounded sync of a calendar with recurring events
//! expanded is large.
//!
//! Privacy: logs carry counts, labels and states only.

use std::time::Duration;

use anyhow::{bail, Result};
use chrono::{DateTime, Duration as ChronoDuration, NaiveDate, Utc};
use serde::Deserialize;
use tokio::sync::{mpsc, watch};
use tracing::{debug, warn};

use crate::data::{
    fred_calendar::{next_and_sweater, CalendarEvent, CalendarSnapshot},
    fred_calendar_native::today_window,
    fred_mailbox_native::FredTiming,
    google_client::{failure_reason, with_query, GoogleClient},
    http_backoff::ThrottleBackoff,
    work::model::SourceState,
};

/// While there is nothing to show (signed out, errored) look again this soon.
const RETRY_WHILE_EMPTY: Duration = Duration::from_secs(5);

// ── Google event shape ────────────────────────────────────────────────────────

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct EventsPage {
    items: Option<Vec<RawEvent>>,
    next_page_token: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawEvent {
    id: Option<String>,
    summary: Option<String>,
    status: Option<String>,
    event_type: Option<String>,
    start: Option<RawTime>,
    end: Option<RawTime>,
    html_link: Option<String>,
    location: Option<String>,
    hangout_link: Option<String>,
    conference_data: Option<RawConference>,
    organizer: Option<RawPerson>,
    #[serde(default)]
    attendees: Vec<RawPerson>,
    #[serde(rename = "iCalUID")]
    ical_uid: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawTime {
    date_time: Option<String>,
    date: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawConference {
    #[serde(default)]
    entry_points: Vec<RawEntryPoint>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawEntryPoint {
    entry_point_type: Option<String>,
    uri: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawPerson {
    display_name: Option<String>,
    email: Option<String>,
    #[serde(rename = "self")]
    is_self: Option<bool>,
    response_status: Option<String>,
}

// ── Source ────────────────────────────────────────────────────────────────────

pub struct GoogleCalendarSource {
    label: String,
    timing: FredTiming,
}

impl GoogleCalendarSource {
    /// Poll one Google calendar. Wakes early on `dirty_rx`.
    pub fn spawn_with_dirty(
        client: GoogleClient,
        label: String,
        timing: FredTiming,
        mut dirty_rx: mpsc::UnboundedReceiver<()>,
    ) -> watch::Receiver<Option<CalendarSnapshot>> {
        let (tx, rx) = watch::channel(None);
        tokio::spawn(async move {
            let source = GoogleCalendarSource { label, timing };
            source.run(client, tx, &mut dirty_rx).await;
        });
        rx
    }

    async fn run(
        &self,
        client: GoogleClient,
        tx: watch::Sender<Option<CalendarSnapshot>>,
        dirty_rx: &mut mpsc::UnboundedReceiver<()>,
    ) {
        let mut backoff = ThrottleBackoff::default();
        loop {
            let previous = tx.borrow().clone();
            let (next, throttled_for) =
                self.refresh(&client, &mut backoff, previous.as_ref()).await;
            let nothing_to_show = matches!(
                next.state,
                SourceState::Unauthenticated | SourceState::Error | SourceState::Loading
            );
            let _ = tx.send(Some(next));

            if let Some(quiet) = throttled_for {
                tokio::time::sleep(quiet).await;
                while dirty_rx.try_recv().is_ok() {}
                continue;
            }

            let wait = if nothing_to_show {
                self.timing.calendar_poll.min(RETRY_WHILE_EMPTY)
            } else {
                self.timing.calendar_poll
            };
            tokio::select! {
                _ = tokio::time::sleep(wait) => {}
                _ = dirty_rx.recv() => {
                    debug!("google calendar '{}' dirty signal received", self.label);
                }
            }
        }
    }

    async fn refresh(
        &self,
        client: &GoogleClient,
        backoff: &mut ThrottleBackoff,
        previous: Option<&CalendarSnapshot>,
    ) -> (CalendarSnapshot, Option<Duration>) {
        let poll = self.timing.calendar_poll;
        let label = self.label.as_str();
        let failure = |backoff: &mut ThrottleBackoff, what: &str, e: &anyhow::Error| {
            let reason = failure_reason(what, e);
            warn!("google calendar '{label}': {reason}");
            match backoff.throttled(e) {
                Some(wait) => {
                    let wait = wait.max(poll);
                    let retry_at = Utc::now() + ChronoDuration::from_std(wait).unwrap_or_default();
                    (
                        CalendarSnapshot::rate_limited(previous, reason, retry_at),
                        Some(wait),
                    )
                }
                None => (CalendarSnapshot::failed(previous, reason), None),
            }
        };

        // The mailbox and calendar of one account share a client, so a pending
        // sign-in is the same prompt for both.
        match client.ensure_authed().await {
            Ok(Some(prompt)) => {
                let reason = format!("Sign in to Google ({label}) to see your calendar");
                return (CalendarSnapshot::unauthenticated_with(prompt, reason), None);
            }
            Ok(None) => {}
            Err(e) => return failure(backoff, "Calendar sign-in failed", &e),
        }

        let window = self.today_window_now();
        match fetch_events(client, window).await {
            Ok(events) => {
                debug!("google calendar '{label}' fetched {} events", events.len());
                backoff.succeeded();
                (build_snapshot(events, Utc::now()), None)
            }
            Err(e) => failure(backoff, "Calendar fetch failed", &e),
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

/// Every event overlapping `window` on the primary calendar, following pages.
/// A page without an `items` array is an error, never an empty day.
async fn fetch_events(
    client: &GoogleClient,
    window: (DateTime<Utc>, DateTime<Utc>),
) -> Result<Vec<RawEvent>> {
    let time_min = window.0.format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let time_max = window.1.format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let mut events = Vec::new();
    let mut page_token: Option<String> = None;
    loop {
        let mut params: Vec<(&str, &str)> = vec![
            ("timeMin", &time_min),
            ("timeMax", &time_max),
            ("singleEvents", "true"),
            ("orderBy", "startTime"),
            ("maxResults", "50"),
        ];
        if let Some(t) = &page_token {
            params.push(("pageToken", t));
        }
        let url = client.calendar_url(&with_query("/calendars/primary/events", &params));
        let page: EventsPage = client.get_json(&url).await?;
        let Some(items) = page.items else {
            bail!("calendar page has no items array")
        };
        events.extend(items);
        match page.next_page_token {
            Some(t) => page_token = Some(t),
            None => return Ok(events),
        }
    }
}

// ── Mapping ───────────────────────────────────────────────────────────────────

fn non_empty(s: Option<String>) -> Option<String> {
    s.filter(|v| !v.trim().is_empty())
}

/// `(instant, is_all_day)` of a Google start/end. All-day dates become midnight
/// UTC of that date (no zone conversion), like the Graph source.
fn parse_time(t: &RawTime) -> Option<(DateTime<Utc>, bool)> {
    if let Some(dt) = t.date_time.as_deref() {
        return DateTime::parse_from_rfc3339(dt)
            .ok()
            .map(|d| (d.with_timezone(&Utc), false));
    }
    let date = NaiveDate::parse_from_str(t.date.as_deref()?, "%Y-%m-%d").ok()?;
    Some((date.and_hms_opt(0, 0, 0)?.and_utc(), true))
}

/// The user's response in Graph's vocabulary.
fn response_status(ev: &RawEvent) -> String {
    if ev.organizer.as_ref().and_then(|o| o.is_self) == Some(true) || ev.attendees.is_empty() {
        return "organizer".to_owned();
    }
    let mine = ev.attendees.iter().find(|a| a.is_self == Some(true));
    match mine.and_then(|a| a.response_status.as_deref()) {
        Some("accepted") => "accepted",
        Some("declined") => "declined",
        Some("tentative") => "tentativelyAccepted",
        Some("needsAction") => "notResponded",
        _ => "",
    }
    .to_owned()
}

fn online_meeting_url(ev: &RawEvent) -> Option<String> {
    non_empty(ev.hangout_link.clone()).or_else(|| {
        ev.conference_data
            .as_ref()?
            .entry_points
            .iter()
            .find_map(|p| {
                (p.entry_point_type.as_deref() == Some("video"))
                    .then(|| non_empty(p.uri.clone()))
                    .flatten()
            })
    })
}

fn build_snapshot(raw_events: Vec<RawEvent>, now: DateTime<Utc>) -> CalendarSnapshot {
    let mut events: Vec<CalendarEvent> = raw_events
        .into_iter()
        .filter(|ev| ev.event_type.as_deref() != Some("workingLocation"))
        .filter_map(|ev| {
            let (start_at, is_all_day) = ev.start.as_ref().and_then(parse_time)?;
            let end = ev.end.as_ref().and_then(parse_time).map(|(e, _)| e);

            let title = non_empty(ev.summary.clone()).unwrap_or_else(|| "(no title)".to_owned());
            let response = response_status(&ev);
            let is_cancelled = ev.status.as_deref() == Some("cancelled");
            let status = if is_cancelled {
                "cancelled".to_owned()
            } else {
                response.clone()
            };
            let is_now = !is_all_day
                && status != "cancelled"
                && status != "declined"
                && start_at <= now
                && end.is_some_and(|e| e > now);

            let organizer = ev.organizer.as_ref().and_then(|o| {
                non_empty(o.display_name.clone()).or_else(|| non_empty(o.email.clone()))
            });

            Some(CalendarEvent {
                id: ev.id.clone().unwrap_or_default(),
                start: Some(start_at),
                end,
                title,
                status,
                is_now,
                web_link: non_empty(ev.html_link.clone()),
                location: non_empty(ev.location.clone()),
                online_meeting_url: online_meeting_url(&ev),
                organizer,
                is_cancelled,
                response_status: response,
                is_all_day,
                account: None,
                dedupe_key: non_empty(ev.ical_uid.clone()),
            })
        })
        .collect();

    events.sort_by_key(|ev| (ev.start, ev.end));
    let (next, sweater) = next_and_sweater(&events, now);

    let state = if events.is_empty() {
        SourceState::Empty
    } else {
        SourceState::Fresh
    };
    CalendarSnapshot {
        events,
        next,
        sweater,
        stale: false,
        error: None,
        generated_at: Some(now),
        state,
        updated_at: Some(now),
        auth_prompt: None,
        retry_at: None,
        accounts: Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(json: &str) -> RawEvent {
        serde_json::from_str(json).unwrap()
    }

    #[test]
    fn all_day_dates_are_midnight_utc() {
        let t = RawTime {
            date_time: None,
            date: Some("2026-10-10".into()),
        };
        let (at, all_day) = parse_time(&t).unwrap();
        assert!(all_day);
        assert_eq!(at.to_rfc3339(), "2026-10-10T00:00:00+00:00");
    }

    #[test]
    fn timed_events_with_an_offset_parse_to_utc() {
        let t = RawTime {
            date_time: Some("2026-10-10T09:00:00-04:00".into()),
            date: None,
        };
        assert_eq!(
            parse_time(&t).unwrap().0.to_rfc3339(),
            "2026-10-10T13:00:00+00:00"
        );
    }

    #[test]
    fn response_follows_the_self_attendee_in_graph_words() {
        let ev = event(
            r#"{"organizer":{"email":"o@x.com"},"attendees":[{"email":"me@x.com","self":true,"responseStatus":"tentative"}]}"#,
        );
        assert_eq!(response_status(&ev), "tentativelyAccepted");
        assert_eq!(
            response_status(&event(
                r#"{"organizer":{"self":true},"attendees":[{"self":true}]}"#
            )),
            "organizer"
        );
        assert_eq!(response_status(&event("{}")), "organizer");
    }
}
