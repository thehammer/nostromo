//! Jira work source: the user's unresolved assigned issues, for Teri's Jira tab.
//!
//! `JiraWorkSource` polls `assignee = currentUser() AND statusCategory != Done`
//! across all projects (every 120 s, and at once on a manual refresh that
//! passed the hub's debounce) and publishes honest states:
//!
//! - no credentials          -> `not_configured` (names the variables)
//! - HTTP 401 / 403          -> `unauthenticated` (names the variable, never a value)
//! - HTTP 429                -> `rate_limited` with `retry_at`; the last items stay
//! - network error / 5xx     -> `stale` while there is previous data, else `error`
//! - healthy, no issues      -> `empty`
//!
//! Credentials are re-resolved on every fetch, and a change of the `.env`
//! file's mtime triggers a fetch, so fixing a token recovers without a daemon
//! restart. Secrets are never logged, put in a status or a detail, or echoed in
//! an error: problems are reported by variable *name* and HTTP status only.
//!
//! Without a source handed to the hub (`HubDeps::jira == None`, i.e. tests that
//! do not exercise Jira) [`spawn`] publishes the dormant "Coming soon"
//! placeholder, so no test ever reaches a real Jira.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};

use chrono::{DateTime, NaiveDate, Utc};
use serde_json::{json, Value};
use tokio::sync::{watch, Notify};
use tracing::warn;

use super::credentials::{default_env_path, EnvFile};
use super::hub::SourceUpdate;
use super::model::{
    Link, Priority, SourceState, SourceStatus, WorkDetail, WorkError, WorkItem, WorkSource,
};
use crate::config::Config;
use crate::data::tickets::jira::adf_to_blocks;
use crate::ipc::protocol::{MdBlock, MdSpan};

const ENV_SITE: &str = "ATLASSIAN_SITE_NAME";
const ENV_EMAIL: &str = "ATLASSIAN_USER_EMAIL";
const ENV_TOKEN: &str = "ATLASSIAN_API_TOKEN";

pub const JQL: &str = "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC";
const LIST_FIELDS: [&str; 8] =
    ["summary", "status", "priority", "updated", "created", "project", "issuetype", "duedate"];
const PAGE_SIZE: usize = 100;
const MAX_ISSUES: usize = 500;
const POLL_INTERVAL: Duration = Duration::from_secs(120);
const BACKOFF_BASE: Duration = Duration::from_secs(2);
const BACKOFF_CAP: Duration = Duration::from_secs(15 * 60);
const ENV_WATCH_INTERVAL: Duration = Duration::from_secs(5);
const DETAIL_TTL: Duration = Duration::from_secs(60);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

/// Shown when the credentials are missing (the tab prefixes "Jira: ").
pub const NOT_CONFIGURED_REASON: &str = "no credentials found. Set ATLASSIAN_SITE_NAME, \
ATLASSIAN_USER_EMAIL and ATLASSIAN_API_TOKEN in ~/.claude/credentials/.env, as the agents use.";

/// Start the dormant placeholder (used when the hub is not given a real source).
pub fn spawn(_refresh: Arc<Notify>) -> watch::Receiver<SourceUpdate> {
    let status = status(SourceState::NotConfigured, Some("Coming soon".into()), None, None, 0);
    // The sender is dropped on purpose: the placeholder never changes.
    watch::channel((status, Vec::new())).1
}

fn status(
    state: SourceState,
    reason: Option<String>,
    updated_at: Option<DateTime<Utc>>,
    retry_at: Option<DateTime<Utc>>,
    count: usize,
) -> SourceStatus {
    SourceStatus {
        source: WorkSource::Jira,
        state,
        updated_at,
        reason,
        retry_at,
        count,
        group_errors: Vec::new(),
    }
}

struct Credentials {
    site: String,
    email: String,
    token: String,
}

/// Why a fetch failed. Carries no secret.
#[derive(Debug)]
enum FetchError {
    /// 401 / 403.
    Rejected(u16),
    /// 429, with the server's `Retry-After` when it sent a usable one.
    RateLimited(Option<Duration>),
    /// Anything else: timeout, connection failure, 5xx, unparsable body.
    Failed(String),
}

pub struct JiraWorkSource {
    env: EnvFile,
    config_site: Option<String>,
    config_email: Option<String>,
    base_url: Option<String>,
    file_only: bool,
    poll_interval: Duration,
    backoff_base: Duration,
    http: reqwest::Client,
    detail_cache: Mutex<HashMap<String, (Instant, WorkDetail)>>,
}

impl JiraWorkSource {
    /// A source reading credentials from the environment, then `env_path`.
    pub fn new(env_path: impl Into<PathBuf>) -> Self {
        Self {
            env: EnvFile::new(env_path),
            config_site: None,
            config_email: None,
            base_url: None,
            file_only: false,
            poll_interval: POLL_INTERVAL,
            backoff_base: BACKOFF_BASE,
            http: reqwest::Client::builder()
                .timeout(REQUEST_TIMEOUT)
                .build()
                .unwrap_or_default(),
            detail_cache: Mutex::new(HashMap::new()),
        }
    }

    /// From the daemon config (`jira_site`, `jira_email`, `jira_credentials_path`).
    pub fn from_config(config: &Config) -> Self {
        let mut source =
            Self::new(config.jira_credentials_path.clone().unwrap_or_else(default_env_path));
        source.config_site = config.jira_site.clone().filter(|s| !s.is_empty());
        source.config_email = config.jira_email.clone().filter(|s| !s.is_empty());
        source
    }

    /// Send requests to `base_url` instead of `https://<site>` (tests).
    pub fn with_base_url(mut self, base_url: impl Into<String>) -> Self {
        self.base_url = Some(base_url.into().trim_end_matches('/').to_string());
        self
    }

    /// Poll every `interval` instead of every 120 s (tests).
    pub fn with_poll_interval(mut self, interval: Duration) -> Self {
        self.poll_interval = interval;
        self
    }

    /// First error back-off (doubles per failure, capped at 15 min; tests).
    pub fn with_backoff_base(mut self, base: Duration) -> Self {
        self.backoff_base = base;
        self
    }

    /// Ignore the process environment: only the `.env` file counts (tests).
    pub fn file_credentials_only(mut self) -> Self {
        self.file_only = true;
        self
    }

    /// Start polling. `refresh` is poked by a manual refresh that passed the
    /// hub's debounce; the source then fetches immediately.
    pub fn spawn(self: Arc<Self>, refresh: Arc<Notify>) -> watch::Receiver<SourceUpdate> {
        let (tx, rx) =
            watch::channel((status(SourceState::Loading, None, None, None, 0), Vec::new()));
        tokio::spawn(async move { self.run(tx, refresh).await });
        rx
    }

    /// Detail for `jira:<KEY>`: fields, ADF description and the 5 newest comments.
    pub async fn detail(&self, item_id: &str) -> Result<WorkDetail, WorkError> {
        let key = item_id
            .strip_prefix("jira:")
            .filter(|k| valid_key(k))
            .ok_or_else(|| WorkError::new("unknown_item", "That is not a Jira issue key"))?;
        if let Some((at, cached)) = self.detail_cache.lock().unwrap().get(item_id) {
            if at.elapsed() < DETAIL_TTL {
                return Ok(cached.clone());
            }
        }
        let creds = self
            .credentials()
            .ok_or_else(|| WorkError::new("not_configured", format!("Jira: {NOT_CONFIGURED_REASON}")))?;
        let detail = self.fetch_detail(&creds, key, item_id).await.map_err(|e| match e {
            FetchError::Rejected(code) => WorkError::new(
                "unauthenticated",
                format!("Jira rejected the token ({code}). Check {ENV_TOKEN}."),
            ),
            FetchError::RateLimited(_) => WorkError::new("rate_limited", "Jira is rate-limiting requests"),
            FetchError::Failed(why) => WorkError::new("fetch_failed", format!("Couldn't load {key}: {why}")),
        })?;
        self.detail_cache.lock().unwrap().insert(item_id.to_string(), (Instant::now(), detail.clone()));
        Ok(detail)
    }

    // ── polling ───────────────────────────────────────────────────────────

    async fn run(self: Arc<Self>, tx: watch::Sender<SourceUpdate>, refresh: Arc<Notify>) {
        let mut items: Vec<WorkItem> = Vec::new();
        let mut last_good: Option<DateTime<Utc>> = None;
        let mut failures: u32 = 0;
        loop {
            let seen_mtime = self.env.mtime();
            let (update, delay) = match self.credentials() {
                None => {
                    items.clear();
                    (
                        (status(SourceState::NotConfigured, Some(NOT_CONFIGURED_REASON.into()), None, None, 0), Vec::new()),
                        self.poll_interval,
                    )
                }
                Some(creds) => match self.fetch_all(&creds).await {
                    Ok(fetched) => {
                        failures = 0;
                        items = fetched;
                        let now = Utc::now();
                        last_good = Some(now);
                        let state = if items.is_empty() { SourceState::Empty } else { SourceState::Fresh };
                        (
                            (status(state, None, Some(now), None, items.len()), vec![(None, items.clone())]),
                            self.poll_interval,
                        )
                    }
                    Err(FetchError::Rejected(code)) => {
                        failures += 1;
                        items.clear();
                        warn!("jira work source: credentials rejected ({code})");
                        (
                            (
                                status(
                                    SourceState::Unauthenticated,
                                    Some(format!(
                                        "Jira rejected the token ({code}). Check {ENV_TOKEN} in ~/.claude/credentials/.env."
                                    )),
                                    None,
                                    None,
                                    0,
                                ),
                                Vec::new(),
                            ),
                            self.backoff(failures),
                        )
                    }
                    Err(FetchError::RateLimited(retry_after)) => {
                        failures += 1;
                        let delay = retry_after.unwrap_or_else(|| self.backoff(failures));
                        warn!("jira work source: rate limited, retrying in {}s", delay.as_secs());
                        let retry_at = Utc::now() + chrono::Duration::from_std(delay).unwrap_or_default();
                        (
                            (
                                status(SourceState::RateLimited, None, last_good, Some(retry_at), items.len()),
                                vec![(None, items.clone())],
                            ),
                            delay,
                        )
                    }
                    Err(FetchError::Failed(why)) => {
                        failures += 1;
                        warn!("jira work source: fetch failed: {why}");
                        let update = if items.is_empty() {
                            (status(SourceState::Error, Some(format!("couldn't reach Jira ({why})")), None, None, 0), Vec::new())
                        } else {
                            (
                                status(
                                    SourceState::Stale,
                                    Some(format!("couldn't reach Jira ({why}); showing the last good list")),
                                    last_good,
                                    None,
                                    items.len(),
                                ),
                                vec![(None, items.clone())],
                            )
                        };
                        (update, self.backoff(failures))
                    }
                },
            };
            if tx.send(update).is_err() {
                return; // the hub is gone
            }
            self.wait(delay, &refresh, seen_mtime).await;
        }
    }

    /// Sleep for `delay`, but wake early on a manual refresh or when the
    /// credentials file changed.
    async fn wait(&self, delay: Duration, refresh: &Notify, seen_mtime: Option<SystemTime>) {
        let deadline = tokio::time::Instant::now() + delay;
        loop {
            let tick = ENV_WATCH_INTERVAL.min(delay.max(Duration::from_millis(10)));
            tokio::select! {
                _ = refresh.notified() => return,
                _ = tokio::time::sleep_until(deadline) => return,
                _ = tokio::time::sleep(tick) => {
                    if self.env.mtime() != seen_mtime {
                        return;
                    }
                }
            }
        }
    }

    fn backoff(&self, failures: u32) -> Duration {
        let factor = 2u32.saturating_pow(failures.saturating_sub(1).min(20));
        self.backoff_base.saturating_mul(factor).min(BACKOFF_CAP)
    }

    // ── credentials ───────────────────────────────────────────────────────

    /// Config override, then process environment, then the `.env` file; blank is absent.
    fn credentials(&self) -> Option<Credentials> {
        let var = |name: &str| {
            if self.file_only {
                self.env.file_value(name)
            } else {
                self.env.lookup(name)
            }
        };
        let site = self.config_site.clone().or_else(|| var(ENV_SITE))?;
        let email = self.config_email.clone().or_else(|| var(ENV_EMAIL))?;
        let token = var(ENV_TOKEN)?;
        let site = site
            .trim()
            .trim_start_matches("https://")
            .trim_start_matches("http://")
            .trim_end_matches('/')
            .to_string();
        if site.is_empty() || email.trim().is_empty() || token.trim().is_empty() {
            return None;
        }
        Some(Credentials { site, email, token })
    }

    fn base(&self, creds: &Credentials) -> String {
        self.base_url.clone().unwrap_or_else(|| format!("https://{}", creds.site))
    }

    // ── fetching ──────────────────────────────────────────────────────────

    async fn fetch_all(&self, creds: &Credentials) -> Result<Vec<WorkItem>, FetchError> {
        match self.fetch_via_search_jql(creds).await {
            Err(FetchError::Failed(why)) if why == ENDPOINT_GONE => self.fetch_via_legacy_search(creds).await,
            other => other,
        }
    }

    async fn fetch_via_search_jql(&self, creds: &Credentials) -> Result<Vec<WorkItem>, FetchError> {
        let url = format!("{}/rest/api/3/search/jql", self.base(creds));
        let mut items = Vec::new();
        let mut token: Option<String> = None;
        loop {
            let mut body = json!({
                "jql": JQL, "fields": LIST_FIELDS, "maxResults": PAGE_SIZE,
            });
            if let Some(t) = &token {
                body["nextPageToken"] = json!(t);
            }
            let req = self.http.post(&url).basic_auth(&creds.email, Some(&creds.token)).json(&body);
            let page = self.send_json(req, true).await?;
            append_issues(&mut items, &page, &creds.site);
            token = page.get("nextPageToken").and_then(Value::as_str).map(str::to_string);
            let last = page.get("isLast").and_then(Value::as_bool).unwrap_or(false);
            if token.is_none() || last || items.len() >= MAX_ISSUES || page_len(&page) == 0 {
                break;
            }
        }
        items.truncate(MAX_ISSUES);
        Ok(items)
    }

    async fn fetch_via_legacy_search(&self, creds: &Credentials) -> Result<Vec<WorkItem>, FetchError> {
        let url = format!("{}/rest/api/3/search", self.base(creds));
        let fields = LIST_FIELDS.join(",");
        let mut items = Vec::new();
        let mut start = 0usize;
        loop {
            let req = self
                .http
                .get(&url)
                .basic_auth(&creds.email, Some(&creds.token))
                .query(&[("jql", JQL), ("fields", fields.as_str())])
                .query(&[("startAt", start), ("maxResults", PAGE_SIZE)]);
            let page = self.send_json(req, false).await?;
            let got = page_len(&page);
            append_issues(&mut items, &page, &creds.site);
            start += got;
            let total = page.get("total").and_then(Value::as_u64).unwrap_or(0) as usize;
            if got == 0 || start >= total || items.len() >= MAX_ISSUES {
                break;
            }
        }
        items.truncate(MAX_ISSUES);
        Ok(items)
    }

    async fn fetch_detail(
        &self,
        creds: &Credentials,
        key: &str,
        item_id: &str,
    ) -> Result<WorkDetail, FetchError> {
        let base = self.base(creds);
        let issue_req = self
            .http
            .get(format!("{base}/rest/api/3/issue/{key}"))
            .basic_auth(&creds.email, Some(&creds.token))
            .query(&[
                ("fields", "summary,status,priority,assignee,description,duedate,updated"),
                ("expand", "renderedFields"),
            ]);
        let issue = self.send_json(issue_req, false).await?;
        let comments_req = self
            .http
            .get(format!("{base}/rest/api/3/issue/{key}/comment"))
            .basic_auth(&creds.email, Some(&creds.token))
            .query(&[("orderBy", "-created"), ("maxResults", "5")]);
        // Comments are a nicety: the issue still shows without them.
        let comments = self.send_json(comments_req, false).await.unwrap_or(Value::Null);

        let f = issue.get("fields").cloned().unwrap_or(Value::Null);
        let text = |v: &Value, path: &[&str]| -> Option<String> {
            path.iter()
                .try_fold(v, |acc, p| acc.get(p))
                .and_then(Value::as_str)
                .map(str::to_string)
        };
        let summary = text(&f, &["summary"]).unwrap_or_default();
        let mut fields = vec![
            ("Summary".to_string(), summary.clone()),
            ("Status".to_string(), text(&f, &["status", "name"]).unwrap_or_default()),
            ("Priority".to_string(), text(&f, &["priority", "name"]).unwrap_or_default()),
            (
                "Assignee".to_string(),
                text(&f, &["assignee", "displayName"]).unwrap_or_else(|| "Unassigned".into()),
            ),
        ];
        if let Some(due) = text(&f, &["duedate"]) {
            fields.push(("Due".to_string(), due));
        }
        if let Some(updated) = text(&f, &["updated"]) {
            fields.push(("Updated".to_string(), updated));
        }

        let mut markdown = blocks_to_markdown(&adf_to_blocks(f.get("description").unwrap_or(&Value::Null)));
        let recent = comments.get("comments").and_then(Value::as_array).cloned().unwrap_or_default();
        if !recent.is_empty() {
            if !markdown.is_empty() {
                markdown.push_str("\n\n");
            }
            markdown.push_str("## Recent comments\n");
            for c in recent.iter().take(5) {
                let author = text(c, &["author", "displayName"]).unwrap_or_else(|| "Unknown".into());
                let when = text(c, &["created"]).unwrap_or_default();
                let body = blocks_to_markdown(&adf_to_blocks(c.get("body").unwrap_or(&Value::Null)));
                markdown.push_str(&format!("\n### {author} · {when}\n\n{body}\n"));
            }
        }
        Ok(WorkDetail {
            item_id: item_id.to_string(),
            title: format!("{key} {summary}"),
            fields,
            markdown,
            files: Vec::new(),
            links: vec![Link {
                label: format!("Open {key} in Jira"),
                url: browse_url(&creds.site, key),
            }],
        })
    }

    /// Send and decode one JSON response, classifying failures. With
    /// `gone_is_endpoint_missing`, 404/410 means "this endpoint doesn't exist here".
    async fn send_json(&self, req: reqwest::RequestBuilder, gone_is_endpoint_missing: bool) -> Result<Value, FetchError> {
        let resp = req.send().await.map_err(|e| FetchError::Failed(describe_transport_error(&e)))?;
        let status = resp.status();
        match status.as_u16() {
            401 | 403 => return Err(FetchError::Rejected(status.as_u16())),
            429 => {
                let retry = resp
                    .headers()
                    .get(reqwest::header::RETRY_AFTER)
                    .and_then(|v| v.to_str().ok())
                    .and_then(parse_retry_after);
                return Err(FetchError::RateLimited(retry));
            }
            404 | 410 if gone_is_endpoint_missing => return Err(FetchError::Failed(ENDPOINT_GONE.into())),
            _ => {}
        }
        if !status.is_success() {
            return Err(FetchError::Failed(format!("HTTP {}", status.as_u16())));
        }
        resp.json::<Value>().await.map_err(|_| FetchError::Failed("unreadable response".into()))
    }
}

/// Internal marker: the `search/jql` endpoint answered 404/410.
const ENDPOINT_GONE: &str = "search/jql endpoint missing";

fn describe_transport_error(e: &reqwest::Error) -> String {
    if e.is_timeout() {
        "timed out".into()
    } else if e.is_connect() {
        "connection failed".into()
    } else {
        "network error".into()
    }
}

/// `Retry-After`: delta seconds or an HTTP date. At least one second.
fn parse_retry_after(raw: &str) -> Option<Duration> {
    let raw = raw.trim();
    if let Ok(secs) = raw.parse::<u64>() {
        return Some(Duration::from_secs(secs.max(1)));
    }
    let when = DateTime::parse_from_rfc2822(raw).ok()?.with_timezone(&Utc);
    let secs = (when - Utc::now()).num_seconds().max(1);
    Some(Duration::from_secs(secs as u64))
}

fn valid_key(key: &str) -> bool {
    match key.split_once('-') {
        Some((project, number)) => {
            !project.is_empty()
                && !number.is_empty()
                && project.chars().all(|c| c.is_ascii_alphanumeric())
                && number.chars().all(|c| c.is_ascii_digit())
        }
        None => false,
    }
}

fn browse_url(site: &str, key: &str) -> String {
    format!("https://{site}/browse/{key}")
}

fn page_len(page: &Value) -> usize {
    page.get("issues").and_then(Value::as_array).map_or(0, Vec::len)
}

fn append_issues(items: &mut Vec<WorkItem>, page: &Value, site: &str) {
    if let Some(issues) = page.get("issues").and_then(Value::as_array) {
        items.extend(issues.iter().filter_map(|i| to_work_item(i, site)));
    }
}

fn to_work_item(issue: &Value, site: &str) -> Option<WorkItem> {
    let key = issue.get("key")?.as_str()?.to_string();
    let f = issue.get("fields").cloned().unwrap_or(Value::Null);
    let text = |path: &[&str]| -> Option<String> {
        path.iter().try_fold(&f, |acc, p| acc.get(p)).and_then(Value::as_str).map(str::to_string)
    };
    let summary = text(&["summary"]).unwrap_or_default();
    let category = match text(&["status", "statusCategory", "key"]).as_deref() {
        Some("indeterminate") => "in_progress",
        Some("new") => "to_do",
        _ => "other",
    };
    let priority = text(&["priority", "name"]).map(|label| {
        let rank = match label.as_str() {
            "Highest" => 1,
            "High" => 2,
            "Medium" => 3,
            "Low" => 4,
            "Lowest" => 5,
            _ => 9,
        };
        Priority { label, rank }
    });
    Some(WorkItem {
        id: format!("jira:{key}"),
        source: WorkSource::Jira,
        kind: text(&["issuetype", "name"]).unwrap_or_else(|| "issue".into()).to_lowercase(),
        title: summary.clone(),
        repo: None,
        project: text(&["project", "key"]),
        status: text(&["status", "name"]),
        status_category: Some(category.into()),
        priority,
        severity: None,
        environment: None,
        created_at: text(&["created"]).as_deref().and_then(parse_jira_time),
        updated_at: text(&["updated"]).as_deref().and_then(parse_jira_time),
        due: text(&["duedate"]).and_then(|d| NaiveDate::parse_from_str(d.get(..10)?, "%Y-%m-%d").ok()),
        url: Some(browse_url(site, &key)),
        path: None,
        metrics: Default::default(),
        linked: Vec::new(),
        search_text: format!("{key} {summary}"),
        sent: Vec::new(),
    })
}

/// Jira sends `2026-10-01T08:00:00.000+0000` (no colon in the offset).
fn parse_jira_time(raw: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(raw)
        .or_else(|_| DateTime::parse_from_str(raw, "%Y-%m-%dT%H:%M:%S%.f%z"))
        .ok()
        .map(|dt| dt.with_timezone(&Utc))
}

// ── ADF blocks -> markdown ────────────────────────────────────────────────

fn blocks_to_markdown(blocks: &[MdBlock]) -> String {
    blocks.iter().map(block_to_markdown).collect::<Vec<_>>().join("\n\n")
}

fn block_to_markdown(block: &MdBlock) -> String {
    match block {
        MdBlock::Paragraph { spans } => spans_to_markdown(spans),
        MdBlock::Heading { level, spans } => {
            format!("{} {}", "#".repeat((*level).clamp(1, 6) as usize), spans_to_markdown(spans))
        }
        MdBlock::CodeBlock { lang, text } => {
            format!("```{}\n{text}\n```", lang.as_deref().unwrap_or(""))
        }
        MdBlock::List { ordered, start, items } => items
            .iter()
            .enumerate()
            .map(|(i, blocks)| {
                let marker = if *ordered { format!("{}.", start.unwrap_or(1) + i as u64) } else { "-".into() };
                let body = blocks_to_markdown(blocks).replace('\n', "\n  ");
                format!("{marker} {body}")
            })
            .collect::<Vec<_>>()
            .join("\n"),
        MdBlock::Quote { blocks } => blocks_to_markdown(blocks)
            .lines()
            .map(|l| format!("> {l}"))
            .collect::<Vec<_>>()
            .join("\n"),
        MdBlock::Table { header, rows } => {
            let row = |cells: &Vec<Vec<MdSpan>>| {
                format!("| {} |", cells.iter().map(|c| spans_to_markdown(c)).collect::<Vec<_>>().join(" | "))
            };
            let mut lines = vec![row(header), format!("|{}", " --- |".repeat(header.len().max(1)))];
            lines.extend(rows.iter().map(row));
            lines.join("\n")
        }
        MdBlock::Rule => "---".into(),
    }
}

fn spans_to_markdown(spans: &[MdSpan]) -> String {
    spans
        .iter()
        .map(|s| match s {
            MdSpan::Text { text } => text.clone(),
            MdSpan::Code { text } => format!("`{text}`"),
            MdSpan::Emph { spans } => format!("*{}*", spans_to_markdown(spans)),
            MdSpan::Strong { spans } => format!("**{}**", spans_to_markdown(spans)),
            MdSpan::Strike { spans } => format!("~~{}~~", spans_to_markdown(spans)),
            MdSpan::Link { spans, url } => format!("[{}]({url})", spans_to_markdown(spans)),
            MdSpan::Image { alt, url } => format!("![{alt}]({url})"),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn retry_after_accepts_seconds_and_http_dates() {
        assert_eq!(parse_retry_after("30"), Some(Duration::from_secs(30)));
        let past = parse_retry_after("Wed, 21 Oct 2015 07:28:00 GMT").unwrap();
        assert_eq!(past, Duration::from_secs(1), "a date in the past still waits a second");
        assert_eq!(parse_retry_after("soon"), None);
    }

    #[test]
    fn backoff_doubles_and_is_capped() {
        let s = JiraWorkSource::new("/nonexistent/.env");
        assert_eq!(s.backoff(1), Duration::from_secs(2));
        assert_eq!(s.backoff(2), Duration::from_secs(4));
        assert_eq!(s.backoff(3), Duration::from_secs(8));
        assert_eq!(s.backoff(40), BACKOFF_CAP);
    }

    #[test]
    fn jira_timestamps_without_a_colon_in_the_offset_parse() {
        assert!(parse_jira_time("2026-10-01T08:00:00.000+0000").is_some());
        assert!(parse_jira_time("2026-10-01T08:00:00Z").is_some());
        assert!(parse_jira_time("yesterday").is_none());
    }
}
