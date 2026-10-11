//! Fred mail / calendar detail over Microsoft Graph (read-only).
//!
//! Answers `WorkDetailRequest`s for `mail:<graph id>` and `event:<graph id>`
//! (installed into the `FredDetailService` registry slot). It only ever issues
//! `GET`s: there is no write path to mail or the calendar here.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use chrono::{DateTime, Duration as ChronoDuration, FixedOffset, Local, NaiveDate, NaiveDateTime, TimeZone, Utc};
use serde::Deserialize;
use url::Url;

use crate::data::graph_client::{failure_reason, GraphClient, GraphHttpError};
use crate::data::work::model::{Link, WorkDetail, WorkError};
use crate::data::work::service::FredDetailService;

/// How long a fetched detail is reused.
const CACHE_TTL: Duration = Duration::from_secs(60);
/// Most body bytes returned.
const MAX_BODY_BYTES: usize = 32 * 1024;

const MAIL_SELECT: &str = "subject,from,toRecipients,ccRecipients,receivedDateTime,body,webLink";
const EVENT_SELECT: &str =
    "subject,organizer,attendees,location,onlineMeeting,start,end,isAllDay,isCancelled,body,webLink";

/// Longest header value (From, To, Location, Attendees, ...) in characters.
const MAX_FIELD_CHARS: usize = 1000;
/// Longest title in characters.
const MAX_TITLE_CHARS: usize = 300;
/// Most people listed in one To / Cc / Attendees value; the rest are counted.
const MAX_LISTED_PEOPLE: usize = 50;

/// Hosts (and their subdomains) Microsoft serves Outlook web links from.
const OUTLOOK_HOSTS: [&str; 5] = [
    "outlook.office.com",
    "outlook.office365.com",
    "outlook.live.com",
    "outlook.office365.us",
    "outlook.office365.de",
];

const PREFER_TEXT: (&str, &str) = ("Prefer", "outlook.body-content-type=\"text\"");
/// Events also ask for UTC so `start`/`end` parse without a zone database.
const PREFER_TEXT_UTC: (&str, &str) =
    ("Prefer", "outlook.body-content-type=\"text\", outlook.timezone=\"UTC\"");

/// UTC offset in force at an instant (DST-aware, so a range that crosses a
/// transition shows each end correctly).
type OffsetFn = Arc<dyn Fn(DateTime<Utc>) -> FixedOffset + Send + Sync>;

pub struct GraphFredDetail {
    graph: GraphClient,
    /// Offset times are shown in; production uses the Mac's local zone.
    offset_at: OffsetFn,
    cache: Mutex<HashMap<String, (Instant, WorkDetail)>>,
}

impl GraphFredDetail {
    pub fn new(graph: GraphClient) -> Self {
        Self::with_offset_fn(graph, Arc::new(|at| *at.with_timezone(&Local).offset()))
    }

    /// Like [`new`](Self::new) with a pinned display zone (tests).
    pub fn with_zone(graph: GraphClient, zone: FixedOffset) -> Self {
        Self::with_offset_fn(graph, Arc::new(move |_| zone))
    }

    /// Like [`new`](Self::new) with a per-instant offset, e.g. a DST rule (tests).
    pub fn with_offset_fn(graph: GraphClient, offset_at: OffsetFn) -> Self {
        Self { graph, offset_at, cache: Mutex::new(HashMap::new()) }
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
            title: one_line(&non_empty(m.subject).unwrap_or_else(|| "(no subject)".to_owned()), MAX_TITLE_CHARS),
            fields: clean_fields(fields),
            markdown: cap_body(trim_quoted_chain(&body_text(m.body))),
            files: vec![],
            links: open_in_outlook(m.web_link),
        })
    }

    async fn event(&self, item_id: &str, graph_id: &str) -> Result<WorkDetail, WorkError> {
        let url = format!("/me/events/{}?$select={EVENT_SELECT}", encode_segment(graph_id));
        let e: GraphEvent = self.fetch(&url, PREFER_TEXT_UTC).await?;

        let mut fields = Vec::new();
        if e.is_cancelled == Some(true) {
            fields.push(("Status".to_owned(), "Cancelled".to_owned()));
        }
        if let Some(o) = &e.organizer {
            fields.push(("Organiser".to_owned(), person(o)));
        }
        if let (Some(start), Some(end)) = (e.start.as_ref(), e.end.as_ref()) {
            let when = if e.is_all_day == Some(true) {
                all_day_range(start, end)
            } else {
                utc(start).zip(utc(end)).map(|(s, e)| self.format_range(s, e))
            };
            if let Some(when) = when {
                fields.push(("When".to_owned(), when));
            }
        }
        if let Some(place) = e.location.and_then(|l| non_empty(l.display_name)) {
            fields.push(("Location".to_owned(), place));
        }
        let join_url = e.online_meeting.and_then(|o| non_empty(o.join_url));
        if let Some(url) = &join_url {
            fields.push(("Join link".to_owned(), url.clone()));
        }
        if !e.attendees.is_empty() {
            let names: Vec<String> = e
                .attendees
                .iter()
                .map(|a| match &a.status {
                    Some(s) => format!("{} ({})", person_name(&a.email_address), response_words(&s.response)),
                    None => person_name(&a.email_address),
                })
                .collect();
            fields.push(("Attendees".to_owned(), join_capped(&names)));
        }
        let mut links = open_in_outlook(e.web_link);
        if let Some(url) = join_url.filter(|u| is_https_with_host(u)) {
            links.push(Link { label: "Join meeting".to_owned(), url });
        }
        Ok(WorkDetail {
            item_id: item_id.to_owned(),
            title: one_line(&non_empty(e.subject).unwrap_or_else(|| "(no title)".to_owned()), MAX_TITLE_CHARS),
            fields: clean_fields(fields),
            markdown: cap_body(body_text(e.body).replace("\r\n", "\n").trim().to_owned()),
            files: vec![],
            links,
        })
    }

    fn format_time(&self, at: DateTime<Utc>) -> String {
        at.with_timezone(&(self.offset_at)(at)).format("%a %-d %b %Y, %H:%M").to_string()
    }

    fn format_range(&self, start: DateTime<Utc>, end: DateTime<Utc>) -> String {
        let (s, e) = (start.with_timezone(&(self.offset_at)(start)), end.with_timezone(&(self.offset_at)(end)));
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
    is_all_day: Option<bool>,
    is_cancelled: Option<bool>,
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
    join_capped(&rs.iter().map(person).collect::<Vec<_>>())
}

/// Comma-join `items`, listing at most [`MAX_LISTED_PEOPLE`] ("..., and N more").
fn join_capped(items: &[String]) -> String {
    let mut listed = items.iter().take(MAX_LISTED_PEOPLE).cloned().collect::<Vec<_>>().join(", ");
    if items.len() > MAX_LISTED_PEOPLE {
        listed.push_str(&format!(", and {} more", items.len() - MAX_LISTED_PEOPLE));
    }
    listed
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

/// The "Open in Outlook" link, only when it is a real Outlook web link: the Mac
/// opens it on click, so a hostile `webLink` (`file:`, `javascript:`, a lookalike
/// host) must never reach it.
fn open_in_outlook(web_link: Option<String>) -> Vec<Link> {
    non_empty(web_link)
        .filter(|url| is_outlook_web_link(url))
        .map(|url| vec![Link { label: "Open in Outlook".to_owned(), url }])
        .unwrap_or_default()
}

/// True for an `https` link, with no userinfo and no non-default port, whose
/// host is (a subdomain of) one of Microsoft's Outlook web hosts.
pub fn is_outlook_web_link(link: &str) -> bool {
    let Some(url) = parse_https(link) else { return false };
    if !url.username().is_empty() || url.password().is_some() || url.port().is_some() {
        return false;
    }
    let Some(host) = url.host_str() else { return false };
    OUTLOOK_HOSTS
        .iter()
        .any(|h| host == *h || host.strip_suffix(h).is_some_and(|rest| rest.ends_with('.')))
}

fn is_https_with_host(link: &str) -> bool {
    parse_https(link).is_some()
}

fn parse_https(link: &str) -> Option<Url> {
    if link.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return None;
    }
    // The URL parser forgives `https:///host` (empty authority); a browser-bound link must not rely on that.
    if link.split_once("://").is_some_and(|(_, rest)| rest.starts_with(['/', '\\'])) {
        return None;
    }
    Url::parse(link).ok().filter(|u| u.scheme() == "https" && u.host_str().is_some_and(|h| !h.is_empty()))
}

/// Collapse every run of whitespace and control characters (newlines included)
/// to one space and cap the result at `max` characters (ending in `…` when cut).
/// Header values are written by other people: they must stay on one line.
fn one_line(s: &str, max: usize) -> String {
    let mut out = String::with_capacity(s.len().min(max * 4));
    let mut pending_space = false;
    for c in s.chars() {
        if c.is_whitespace() || c.is_control() || matches!(c, '\u{2028}' | '\u{2029}') {
            pending_space = !out.is_empty();
        } else {
            if pending_space {
                out.push(' ');
                pending_space = false;
            }
            out.push(c);
        }
    }
    if out.chars().count() > max {
        out = out.chars().take(max.saturating_sub(1)).collect::<String>().trim_end().to_owned();
        out.push('…');
    }
    out
}

fn clean_fields(fields: Vec<(String, String)>) -> Vec<(String, String)> {
    fields.into_iter().map(|(label, value)| (label, one_line(&value, MAX_FIELD_CHARS))).collect()
}

/// "Fri 9 Oct 2026 (all day)" or "Fri 9 Oct 2026 – Sun 11 Oct 2026 (all day)".
/// All-day events are dates, not instants: Graph's end is the next midnight
/// (exclusive) and nothing is converted between zones.
fn all_day_range(start: &GraphTime, end: &GraphTime) -> Option<String> {
    let first = naive(start)?.date();
    let last = naive(end).map(|n| n.date()).filter(|d| *d > first).map_or(first, |d| d - ChronoDuration::days(1));
    let day = |d: NaiveDate| d.format("%a %-d %b %Y").to_string();
    Some(if last == first {
        format!("{} (all day)", day(first))
    } else {
        format!("{} – {} (all day)", day(first), day(last))
    })
}

/// Graph returns `dateTime` without an offset; we asked for UTC.
fn utc(t: &GraphTime) -> Option<DateTime<Utc>> {
    naive(t).map(|n| Utc.from_utc_datetime(&n))
}

fn naive(t: &GraphTime) -> Option<NaiveDateTime> {
    NaiveDateTime::parse_from_str(&t.date_time, "%Y-%m-%dT%H:%M:%S%.f").ok()
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
