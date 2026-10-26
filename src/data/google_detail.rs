//! Fred mail / calendar detail over Gmail and Google Calendar (read-only).
//!
//! Answers `WorkDetailRequest`s for `mail:<gmail id>` and `event:<event id>`
//! of ONE account (the [`FredDetailRouter`](crate::data::fred_accounts::FredDetailRouter)
//! strips the account label first). Only ever issues `GET`s.
//!
//! Privacy: nothing here is logged; errors carry status codes only.

use std::collections::HashMap;
use std::sync::{Arc, LazyLock, Mutex};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use chrono::{DateTime, Duration as ChronoDuration, FixedOffset, NaiveDate, TimeZone, Utc};
use regex::Regex;
use serde::Deserialize;

use crate::data::{
    fred_detail::{
        cap_body, clean_fields, join_capped, non_empty, one_line, parse_https, trim_quoted_chain,
        TimeFormat,
    },
    google_client::{encode_segment, failure_reason, with_query, GoogleClient, GoogleHttpError},
    google_mailbox::web_link,
    work::model::{Link, WorkDetail, WorkError},
    work::service::FredDetailService,
};

/// How long a fetched detail is reused.
const CACHE_TTL: Duration = Duration::from_secs(60);
/// Longest title in characters.
const MAX_TITLE_CHARS: usize = 300;
/// Deepest MIME nesting and most parts looked at when finding the body.
const MAX_PART_DEPTH: usize = 10;
const MAX_PARTS: usize = 50;

pub struct GoogleFredDetail {
    client: GoogleClient,
    time: TimeFormat,
    cache: Mutex<HashMap<String, (Instant, WorkDetail)>>,
}

impl GoogleFredDetail {
    pub fn new(client: GoogleClient) -> Self {
        Self::with_time(client, TimeFormat::local())
    }

    /// Like [`new`](Self::new) with a pinned display zone (tests).
    pub fn with_zone(client: GoogleClient, zone: FixedOffset) -> Self {
        Self::with_time(
            client,
            TimeFormat {
                offset_at: Arc::new(move |_| zone),
            },
        )
    }

    fn with_time(client: GoogleClient, time: TimeFormat) -> Self {
        Self {
            client,
            time,
            cache: Mutex::new(HashMap::new()),
        }
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

    fn unauthenticated(&self) -> WorkError {
        WorkError::new(
            "unauthenticated",
            format!(
                "Sign in to Google ({}) from the Fred pane first",
                self.client.label()
            ),
        )
    }

    async fn fetch<T: serde::de::DeserializeOwned>(&self, url: &str) -> Result<T, WorkError> {
        match self.client.ensure_authed().await {
            Ok(None) => {}
            Ok(Some(_)) => return Err(self.unauthenticated()),
            Err(e) => return Err(WorkError::new("google_error", failure_reason("Google", &e))),
        }
        self.client.get_json(url).await.map_err(|e| {
            match e
                .downcast_ref::<GoogleHttpError>()
                .map(|h| h.status.as_u16())
            {
                Some(401) => self.unauthenticated(),
                Some(404) => WorkError::new("not_found", "That item no longer exists in Google"),
                _ => WorkError::new("google_error", failure_reason("Google", &e)),
            }
        })
    }

    async fn mail(&self, item_id: &str, id: &str) -> Result<WorkDetail, WorkError> {
        let url = self.client.gmail_url(&with_query(
            &format!("/users/me/messages/{}", encode_segment(id)),
            &[("format", "full")],
        ));
        let m: GmailFull = self.fetch(&url).await?;
        let payload = m.payload.unwrap_or_default();
        let header = |name: &str| {
            payload
                .headers
                .iter()
                .find(|h| h.name.eq_ignore_ascii_case(name))
                .map(|h| h.value.clone())
        };

        let mut fields = vec![("From".to_owned(), header("From").unwrap_or_default())];
        fields.push(("To".to_owned(), header("To").unwrap_or_default()));
        if let Some(cc) = header("Cc").filter(|c| !c.trim().is_empty()) {
            fields.push(("Cc".to_owned(), cc));
        }
        if let Some(at) = m.internal_date.as_ref().and_then(internal_date) {
            fields.push(("Received".to_owned(), self.time.format_time(at)));
        }

        let mut links = Vec::new();
        if let Some(thread) = non_empty(m.thread_id) {
            let email = self.client.stored_email().await;
            let link = web_link(email.as_deref(), &thread);
            if is_google_web_link(&link) {
                links.push(Link {
                    label: "Open in Gmail".to_owned(),
                    url: link,
                });
            }
        }

        Ok(WorkDetail {
            item_id: item_id.to_owned(),
            title: one_line(
                &non_empty(header("Subject")).unwrap_or_else(|| "(no subject)".to_owned()),
                MAX_TITLE_CHARS,
            ),
            fields: clean_fields(fields),
            markdown: cap_body(cut_on_wrote(&trim_quoted_chain(&message_body(&payload)))),
            files: vec![],
            links,
        })
    }

    async fn event(&self, item_id: &str, id: &str) -> Result<WorkDetail, WorkError> {
        let url = self
            .client
            .calendar_url(&format!("/calendars/primary/events/{}", encode_segment(id)));
        let e: GEvent = self.fetch(&url).await?;

        let mut fields = Vec::new();
        if e.status.as_deref() == Some("cancelled") {
            fields.push(("Status".to_owned(), "Cancelled".to_owned()));
        }
        if let Some(o) = &e.organizer {
            fields.push(("Organiser".to_owned(), person(&o.display_name, &o.email)));
        }
        if let Some(when) = self.when(&e) {
            fields.push(("When".to_owned(), when));
        }
        if let Some(place) = non_empty(e.location.clone()) {
            fields.push(("Location".to_owned(), place));
        }
        let join_url = join_url(&e);
        if let Some(url) = &join_url {
            fields.push(("Join link".to_owned(), url.clone()));
        }
        if !e.attendees.is_empty() {
            let names: Vec<String> = e
                .attendees
                .iter()
                .map(|a| {
                    format!(
                        "{} ({})",
                        person_name(&a.display_name, &a.email),
                        response_words(a)
                    )
                })
                .collect();
            fields.push(("Attendees".to_owned(), join_capped(&names)));
        }

        let mut links = Vec::new();
        if let Some(link) = non_empty(e.html_link.clone()).filter(|l| is_google_web_link(l)) {
            links.push(Link {
                label: "Open in Google Calendar".to_owned(),
                url: link,
            });
        }
        if let Some(url) = join_url.filter(|u| parse_https(u).is_some()) {
            links.push(Link {
                label: "Join meeting".to_owned(),
                url,
            });
        }
        let description = e
            .description
            .as_deref()
            .map(html_to_text)
            .unwrap_or_default();
        Ok(WorkDetail {
            item_id: item_id.to_owned(),
            title: one_line(
                &non_empty(e.summary).unwrap_or_else(|| "(no title)".to_owned()),
                MAX_TITLE_CHARS,
            ),
            fields: clean_fields(fields),
            markdown: cap_body(description.replace("\r\n", "\n").trim().to_owned()),
            files: vec![],
            links,
        })
    }

    fn when(&self, e: &GEvent) -> Option<String> {
        let (start, end) = (e.start.as_ref()?, e.end.as_ref()?);
        if let Some(first) = start.date.as_deref() {
            let first = NaiveDate::parse_from_str(first, "%Y-%m-%d").ok()?;
            // Like Graph, the end date is exclusive and nothing is zone-converted.
            let last = end
                .date
                .as_deref()
                .and_then(|d| NaiveDate::parse_from_str(d, "%Y-%m-%d").ok())
                .filter(|d| *d > first)
                .map_or(first, |d| d - ChronoDuration::days(1));
            let day = |d: NaiveDate| d.format("%a %-d %b %Y").to_string();
            return Some(if last == first {
                format!("{} (all day)", day(first))
            } else {
                format!("{} – {} (all day)", day(first), day(last))
            });
        }
        let parse = |t: &RawTime| {
            t.date_time
                .as_deref()
                .and_then(|d| DateTime::parse_from_rfc3339(d).ok())
                .map(|d| d.with_timezone(&Utc))
        };
        Some(self.time.format_range(parse(start)?, parse(end)?))
    }
}

#[async_trait]
impl FredDetailService for GoogleFredDetail {
    async fn detail(&self, item_id: &str) -> Result<WorkDetail, WorkError> {
        let (is_mail, id) = if let Some(id) = item_id.strip_prefix("mail:") {
            (true, id)
        } else if let Some(id) = item_id.strip_prefix("event:") {
            (false, id)
        } else {
            return Err(WorkError::new(
                "not_found",
                "Not a Fred mail or calendar item",
            ));
        };
        // Empty and all-dot ids (`.`, `..`) would normalise to a parent endpoint.
        if id.is_empty() || id.chars().all(|c| c == '.') {
            return Err(WorkError::new("not_found", "Missing item id"));
        }
        if let Some(hit) = self.cached(item_id) {
            return Ok(hit);
        }
        let detail = if is_mail {
            self.mail(item_id, id).await?
        } else {
            self.event(item_id, id).await?
        };
        self.remember(item_id, &detail);
        Ok(detail)
    }
}

// ── Link safety ───────────────────────────────────────────────────────────────

/// True for an `https` link, with no userinfo and no port, on exactly
/// `mail.google.com` or `calendar.google.com`, or `www.google.com` under
/// `/calendar/`. The Mac opens it on click, so a hostile link must not pass.
pub fn is_google_web_link(link: &str) -> bool {
    let Some(url) = parse_https(link) else {
        return false;
    };
    if !url.username().is_empty() || url.password().is_some() || url.port().is_some() {
        return false;
    }
    match url.host_str() {
        Some("mail.google.com") | Some("calendar.google.com") => true,
        Some("www.google.com") => url.path().starts_with("/calendar/"),
        _ => false,
    }
}

// ── Gmail shapes ──────────────────────────────────────────────────────────────

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GmailFull {
    thread_id: Option<String>,
    internal_date: Option<serde_json::Value>,
    payload: Option<Part>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct Part {
    mime_type: Option<String>,
    #[serde(default)]
    headers: Vec<Header>,
    body: Option<PartBody>,
    #[serde(default)]
    parts: Vec<Part>,
}

#[derive(Deserialize)]
struct Header {
    name: String,
    #[serde(default)]
    value: String,
}

#[derive(Deserialize)]
struct PartBody {
    data: Option<String>,
}

fn internal_date(v: &serde_json::Value) -> Option<DateTime<Utc>> {
    let ms = match v {
        serde_json::Value::String(s) => s.parse::<i64>().ok()?,
        serde_json::Value::Number(n) => n.as_i64()?,
        _ => return None,
    };
    Utc.timestamp_millis_opt(ms).single()
}

/// The readable body: the first `text/plain` part, else `text/html` as text.
fn message_body(payload: &Part) -> String {
    #[derive(Default)]
    struct Found {
        plain: Option<String>,
        html: Option<String>,
        seen: usize,
    }
    fn walk(part: &Part, depth: usize, found: &mut Found) {
        if depth > MAX_PART_DEPTH || found.seen >= MAX_PARTS || found.plain.is_some() {
            return;
        }
        found.seen += 1;
        let data = part
            .body
            .as_ref()
            .and_then(|b| b.data.as_deref())
            .and_then(decode_body);
        match (part.mime_type.as_deref(), data) {
            (Some("text/plain"), Some(text)) => found.plain = Some(text),
            (Some("text/html"), Some(text)) if found.html.is_none() => found.html = Some(text),
            _ => {}
        }
        for child in &part.parts {
            walk(child, depth + 1, found);
        }
    }
    let mut found = Found::default();
    walk(payload, 0, &mut found);
    match (found.plain, found.html) {
        (Some(p), _) => p,
        (None, Some(h)) => html_to_text(&h),
        _ => String::new(),
    }
}

/// base64url, tolerating padding.
fn decode_body(data: &str) -> Option<String> {
    let bytes = URL_SAFE_NO_PAD.decode(data.trim_end_matches('=')).ok()?;
    Some(String::from_utf8_lossy(&bytes).into_owned())
}

static SCRIPT_STYLE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?is)<(script|style)\b.*?</(script|style)\s*>").unwrap());
static BREAKS: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)<br\s*/?>|</p\s*>|</div\s*>").unwrap());
static TAGS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?s)<[^>]*>").unwrap());
static ON_WROTE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^On .+ wrote:$").unwrap());

/// HTML reduced to text: script/style dropped, block ends become newlines,
/// tags stripped, common entities decoded.
pub(crate) fn html_to_text(html: &str) -> String {
    let t = SCRIPT_STYLE.replace_all(html, "");
    let t = BREAKS.replace_all(&t, "\n");
    let t = TAGS.replace_all(&t, "");
    t.replace("&nbsp;", " ")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&amp;", "&")
        .trim()
        .to_owned()
}

/// Cut at the first `On … wrote:` line that follows a blank line.
fn cut_on_wrote(text: &str) -> String {
    let lines: Vec<&str> = text.lines().collect();
    let cut = (1..lines.len())
        .find(|&i| ON_WROTE.is_match(lines[i].trim()) && lines[i - 1].trim().is_empty());
    match cut {
        Some(i) => lines[..i].join("\n").trim().to_owned(),
        None => text.trim().to_owned(),
    }
}

// ── Calendar shapes ───────────────────────────────────────────────────────────

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GEvent {
    summary: Option<String>,
    description: Option<String>,
    location: Option<String>,
    status: Option<String>,
    html_link: Option<String>,
    hangout_link: Option<String>,
    organizer: Option<RawPerson>,
    #[serde(default)]
    attendees: Vec<RawAttendee>,
    start: Option<RawTime>,
    end: Option<RawTime>,
    conference_data: Option<ConferenceData>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawPerson {
    email: Option<String>,
    display_name: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawAttendee {
    email: Option<String>,
    display_name: Option<String>,
    response_status: Option<String>,
    organizer: Option<bool>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawTime {
    date_time: Option<String>,
    date: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ConferenceData {
    #[serde(default)]
    entry_points: Vec<EntryPoint>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct EntryPoint {
    entry_point_type: Option<String>,
    uri: Option<String>,
}

fn join_url(e: &GEvent) -> Option<String> {
    non_empty(e.hangout_link.clone()).or_else(|| {
        e.conference_data
            .as_ref()?
            .entry_points
            .iter()
            .find(|p| p.entry_point_type.as_deref() == Some("video"))
            .and_then(|p| non_empty(p.uri.clone()))
    })
}

fn person_name(name: &Option<String>, email: &Option<String>) -> String {
    non_empty(name.clone())
        .or_else(|| non_empty(email.clone()))
        .unwrap_or_else(|| "Unknown".to_owned())
}

fn person(name: &Option<String>, email: &Option<String>) -> String {
    match (non_empty(name.clone()), non_empty(email.clone())) {
        (Some(n), Some(a)) if n != a => format!("{n} <{a}>"),
        (Some(n), _) => n,
        (None, Some(a)) => a,
        (None, None) => "Unknown".to_owned(),
    }
}

fn response_words(a: &RawAttendee) -> &'static str {
    if a.organizer == Some(true) {
        return "organiser";
    }
    match a.response_status.as_deref() {
        Some("accepted") => "accepted",
        Some("declined") => "declined",
        Some("tentative") => "tentatively accepted",
        _ => "no response",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn link_allowlist() {
        for ok in [
            "https://mail.google.com/mail/?authuser=a%40gmail.com#all/abc",
            "https://calendar.google.com/calendar/event?eid=x",
            "https://www.google.com/calendar/event?eid=x",
        ] {
            assert!(is_google_web_link(ok), "{ok}");
        }
        for bad in [
            "https://www.google.com/search?q=x",
            "https://mail.google.com.evil.com/",
            "http://mail.google.com/",
            "https://user@mail.google.com/",
            "https://mail.google.com:8443/",
            "javascript:alert(1)",
        ] {
            assert!(!is_google_web_link(bad), "{bad}");
        }
    }

    #[test]
    fn html_reduces_to_text() {
        let t = html_to_text(
            "<style>p{}</style><p>Hi &amp; bye</p><script>x()</script><div>a&nbsp;b<br>c</div>",
        );
        assert_eq!(t, "Hi & bye\na b\nc");
    }

    #[test]
    fn on_wrote_cuts_after_blank_line() {
        assert_eq!(
            cut_on_wrote("Thanks\n\nOn Mon, 5 Oct 2026, A <a@b.c> wrote:\n> old"),
            "Thanks"
        );
        assert_eq!(cut_on_wrote("On Mon A wrote:\nx"), "On Mon A wrote:\nx");
    }
}
