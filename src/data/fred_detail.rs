//! Fred mail / calendar detail over Microsoft Graph (read-only).
//!
//! Answers `WorkDetailRequest`s for `mail:<graph id>` and `event:<graph id>`
//! (installed into the `FredDetailService` registry slot). It only ever issues
//! `GET`s: there is no write path to mail or the calendar here.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use async_trait::async_trait;
use chrono::{DateTime, FixedOffset, Local, NaiveDateTime, TimeZone, Utc};
use serde::Deserialize;

use crate::data::graph_client::{failure_reason, GraphClient, GraphHttpError};
use crate::data::work::model::{Link, WorkDetail, WorkError};
use crate::data::work::service::FredDetailService;

/// How long a fetched detail is reused.
const CACHE_TTL: Duration = Duration::from_secs(60);
/// Most body bytes returned.
const MAX_BODY_BYTES: usize = 32 * 1024;

const MAIL_SELECT: &str = "subject,from,toRecipients,ccRecipients,receivedDateTime,body,webLink";
const EVENT_SELECT: &str =
    "subject,organizer,attendees,location,onlineMeeting,start,end,body,webLink";

const PREFER_TEXT: (&str, &str) = ("Prefer", "outlook.body-content-type=\"text\"");
/// Events also ask for UTC so `start`/`end` parse without a zone database.
const PREFER_TEXT_UTC: (&str, &str) =
    ("Prefer", "outlook.body-content-type=\"text\", outlook.timezone=\"UTC\"");

pub struct GraphFredDetail {
    graph: GraphClient,
    /// Zone `When` is shown in; `None` = the Mac's local zone.
    zone: Option<FixedOffset>,
    cache: Mutex<HashMap<String, (Instant, WorkDetail)>>,
}

impl GraphFredDetail {
    pub fn new(graph: GraphClient) -> Self {
        Self { graph, zone: None, cache: Mutex::new(HashMap::new()) }
    }

    /// Like [`new`](Self::new) with a pinned display zone (tests).
    pub fn with_zone(graph: GraphClient, zone: FixedOffset) -> Self {
        Self { zone: Some(zone), ..Self::new(graph) }
    }

    fn cached(&self, item_id: &str) -> Option<WorkDetail> {
        let cache = self.cache.lock().unwrap();
        cache
            .get(item_id)
            .filter(|(at, _)| at.elapsed() < CACHE_TTL)
            .map(|(_, d)| d.clone())
    }

    fn remember(&self, item_id: &str, detail: &WorkDetail) {
        let mut cache = self.cache.lock().unwrap();
        cache.retain(|_, (at, _)| at.elapsed() < CACHE_TTL);
        cache.insert(item_id.to_owned(), (Instant::now(), detail.clone()));
    }

    async fn fetch<T: serde::de::DeserializeOwned>(
        &self,
        url: &str,
        prefer: (&str, &str),
    ) -> Result<T, WorkError> {
        match self.graph.ensure_authed().await {
            Ok(None) => {}
            Ok(Some(_)) => return Err(unauthenticated()),
            Err(e) => return Err(WorkError::new("graph_error", failure_reason("Outlook", &e))),
        }
        self.graph.get_json_with_headers(url, &[prefer]).await.map_err(|e| {
            match e.downcast_ref::<GraphHttpError>().map(|h| h.status.as_u16()) {
                Some(401) => unauthenticated(),
                Some(404) => WorkError::new("not_found", "That item no longer exists in Outlook"),
                _ => WorkError::new("graph_error", failure_reason("Outlook", &e)),
            }
        })
    }

    async fn mail(&self, item_id: &str, graph_id: &str) -> Result<WorkDetail, WorkError> {
        let url = format!("/me/messages/{}?$select={MAIL_SELECT}", encode_segment(graph_id));
        let m: GraphMail = self.fetch(&url, PREFER_TEXT).await?;

        let mut fields = vec![("From".to_owned(), m.from.as_ref().map(person).unwrap_or_default())];
        fields.push(("To".to_owned(), people(&m.to_recipients)));
        if !m.cc_recipients.is_empty() {
            fields.push(("Cc".to_owned(), people(&m.cc_recipients)));
        }
        if let Some(at) = m.received_date_time {
            fields.push(("Received".to_owned(), self.format_time(at)));
        }
        Ok(WorkDetail {
            item_id: item_id.to_owned(),
            title: non_empty(m.subject).unwrap_or_else(|| "(no subject)".to_owned()),
            fields,
            markdown: cap_body(trim_quoted_chain(&body_text(m.body))),
            files: vec![],
            links: open_in_outlook(m.web_link),
        })
    }

    async fn event(&self, item_id: &str, graph_id: &str) -> Result<WorkDetail, WorkError> {
        let url = format!("/me/events/{}?$select={EVENT_SELECT}", encode_segment(graph_id));
        let e: GraphEvent = self.fetch(&url, PREFER_TEXT_UTC).await?;

        let mut fields = Vec::new();
        if let Some(o) = &e.organizer {
            fields.push(("Organiser".to_owned(), person(o)));
        }
        if let (Some(start), Some(end)) = (e.start.as_ref().and_then(utc), e.end.as_ref().and_then(utc)) {
            fields.push(("When".to_owned(), self.format_range(start, end)));
        }
        if let Some(place) = e.location.and_then(|l| non_empty(l.display_name)) {
            fields.push(("Location".to_owned(), place));
        }
        let join_url = e.online_meeting.and_then(|o| non_empty(o.join_url));
        if let Some(url) = &join_url {
            fields.push(("Join link".to_owned(), url.clone()));
        }
        if !e.attendees.is_empty() {
            let list = e
                .attendees
                .iter()
                .map(|a| match &a.status {
                    Some(s) => format!("{} ({})", person_name(&a.email_address), response_words(&s.response)),
                    None => person_name(&a.email_address),
                })
                .collect::<Vec<_>>()
                .join(", ");
            fields.push(("Attendees".to_owned(), list));
        }
        let mut links = open_in_outlook(e.web_link);
        if let Some(url) = join_url {
            links.push(Link { label: "Join meeting".to_owned(), url });
        }
        Ok(WorkDetail {
            item_id: item_id.to_owned(),
            title: non_empty(e.subject).unwrap_or_else(|| "(no title)".to_owned()),
            fields,
            markdown: cap_body(body_text(e.body).replace("\r\n", "\n").trim().to_owned()),
            files: vec![],
            links,
        })
    }

    fn format_time(&self, at: DateTime<Utc>) -> String {
        match self.zone {
            Some(z) => at.with_timezone(&z).format("%a %-d %b %Y, %H:%M").to_string(),
            None => at.with_timezone(&Local).format("%a %-d %b %Y, %H:%M").to_string(),
        }
    }

    fn format_range(&self, start: DateTime<Utc>, end: DateTime<Utc>) -> String {
        let zone = self.zone.unwrap_or_else(|| *Local.from_utc_datetime(&start.naive_utc()).offset());
        let (s, e) = (start.with_timezone(&zone), end.with_timezone(&zone));
        if s.date_naive() == e.date_naive() {
            format!("{}–{}", s.format("%a %-d %b %Y, %H:%M"), e.format("%H:%M"))
        } else {
            format!("{} – {}", s.format("%a %-d %b %Y, %H:%M"), e.format("%a %-d %b %Y, %H:%M"))
        }
    }
}

#[async_trait]
impl FredDetailService for GraphFredDetail {
    async fn detail(&self, item_id: &str) -> Result<WorkDetail, WorkError> {
        let (is_mail, graph_id) = if let Some(id) = item_id.strip_prefix("mail:") {
            (true, id)
        } else if let Some(id) = item_id.strip_prefix("event:") {
            (false, id)
        } else {
            return Err(WorkError::new("not_found", "Not a Fred mail or calendar item"));
        };
        if graph_id.is_empty() {
            return Err(WorkError::new("not_found", "Missing item id"));
        }
        if let Some(hit) = self.cached(item_id) {
            return Ok(hit);
        }
        let detail = if is_mail {
            self.mail(item_id, graph_id).await?
        } else {
            self.event(item_id, graph_id).await?
        };
        self.remember(item_id, &detail);
        Ok(detail)
    }
}

// ── Graph shapes ──────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GraphMail {
    subject: Option<String>,
    from: Option<Recipient>,
    #[serde(default)]
    to_recipients: Vec<Recipient>,
    #[serde(default)]
    cc_recipients: Vec<Recipient>,
    received_date_time: Option<DateTime<Utc>>,
    body: Option<GraphBody>,
    web_link: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GraphEvent {
    subject: Option<String>,
    organizer: Option<Recipient>,
    #[serde(default)]
    attendees: Vec<Attendee>,
    location: Option<GraphLocation>,
    online_meeting: Option<GraphOnlineMeeting>,
    start: Option<GraphTime>,
    end: Option<GraphTime>,
    body: Option<GraphBody>,
    web_link: Option<String>,
}

#[derive(Debug, Deserialize)]
struct Recipient {
    #[serde(rename = "emailAddress")]
    email_address: EmailAddress,
}

#[derive(Debug, Deserialize)]
struct Attendee {
    #[serde(rename = "emailAddress")]
    email_address: EmailAddress,
    status: Option<AttendeeStatus>,
}

#[derive(Debug, Deserialize)]
struct AttendeeStatus {
    response: Option<String>,
}

#[derive(Debug, Deserialize)]
struct EmailAddress {
    name: Option<String>,
    address: Option<String>,
}

#[derive(Debug, Deserialize)]
struct GraphBody {
    content: Option<String>,
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
struct GraphTime {
    date_time: String,
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn unauthenticated() -> WorkError {
    WorkError::new("unauthenticated", "Sign in to Microsoft 365 from the Fred pane first")
}

fn non_empty(s: Option<String>) -> Option<String> {
    s.map(|s| s.trim().to_owned()).filter(|s| !s.is_empty())
}

fn person_name(e: &EmailAddress) -> String {
    non_empty(e.name.clone())
        .or_else(|| non_empty(e.address.clone()))
        .unwrap_or_else(|| "Unknown".to_owned())
}

fn person(r: &Recipient) -> String {
    let e = &r.email_address;
    match (non_empty(e.name.clone()), non_empty(e.address.clone())) {
        (Some(n), Some(a)) if n != a => format!("{n} <{a}>"),
        (Some(n), _) => n,
        (None, Some(a)) => a,
        (None, None) => "Unknown".to_owned(),
    }
}

fn people(rs: &[Recipient]) -> String {
    rs.iter().map(person).collect::<Vec<_>>().join(", ")
}

fn response_words(response: &Option<String>) -> &'static str {
    match response.as_deref() {
        Some("accepted") => "accepted",
        Some("declined") => "declined",
        Some("tentativelyAccepted") => "tentatively accepted",
        Some("organizer") => "organiser",
        _ => "no response",
    }
}

fn body_text(body: Option<GraphBody>) -> String {
    body.and_then(|b| b.content).unwrap_or_default()
}

fn open_in_outlook(web_link: Option<String>) -> Vec<Link> {
    non_empty(web_link)
        .map(|url| vec![Link { label: "Open in Outlook".to_owned(), url }])
        .unwrap_or_default()
}

/// Graph returns `dateTime` without an offset; we asked for UTC.
fn utc(t: &GraphTime) -> Option<DateTime<Utc>> {
    NaiveDateTime::parse_from_str(&t.date_time, "%Y-%m-%dT%H:%M:%S%.f")
        .ok()
        .map(|n| Utc.from_utc_datetime(&n))
}

/// Cut a reply chain: everything from the first line starting `From:` that
/// follows a blank line.
pub fn trim_quoted_chain(text: &str) -> String {
    let text = text.replace("\r\n", "\n");
    let lines: Vec<&str> = text.lines().collect();
    let cut = (1..lines.len())
        .find(|&i| lines[i].trim_start().starts_with("From:") && lines[i - 1].trim().is_empty());
    let kept = match cut {
        Some(i) => &lines[..i],
        None => &lines[..],
    };
    kept.join("\n").trim().to_owned()
}

fn cap_body(mut text: String) -> String {
    if text.len() > MAX_BODY_BYTES {
        let mut end = MAX_BODY_BYTES;
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        text.truncate(end);
        text.push_str("\n\n[…truncated]");
    }
    text
}

/// Percent-encode a Graph id for use as one path segment.
fn encode_segment(id: &str) -> String {
    let mut out = String::with_capacity(id.len());
    for b in id.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}
