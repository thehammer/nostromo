//! Sentry work source (Teri's Sentry tab).
//!
//! Scope: unresolved issues **assigned to the user**, plus **unassigned
//! error/fatal issues last seen within 24 h** (still firing). Two queries on
//! `GET {base}/organizations/{org}/issues/`, unioned by issue id.
//!
//! Auth is the static user token `SENTRY_API_TOKEN` (process environment, then
//! `~/.claude/credentials/.env`, re-read when the file changes). The token only
//! ever travels in the `Authorization` header: it is never put in a status
//! reason, an item, a detail, a URL or a log line.
//!
//! The hub's seam is [`spawn`] and [`detail`]; [`spawn_with`] / [`detail_with`]
//! take an explicit [`SentryConfig`] (tests point it at a fake server).

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use chrono::{DateTime, Utc};
use reqwest::header::{HeaderMap, AUTHORIZATION, RETRY_AFTER};
use serde_json::Value;
use tokio::sync::{watch, Notify};
use tracing::warn;

use super::credentials::{default_env_path, EnvFile};
use super::hub::SourceUpdate;
use super::model::{
    Link, Priority, SourceState, SourceStatus, WorkDetail, WorkError, WorkItem, WorkSource,
};

const TOKEN_VAR: &str = "SENTRY_API_TOKEN";
const DEFAULT_BASE_URL: &str = "https://sentry.io/api/0";
const DEFAULT_ORG: &str = "carefeed";
const PAGE_LIMIT: usize = 100;
const MAX_ISSUES_PER_QUERY: usize = 300;
const MAX_FRAMES: usize = 10;
/// The longest a 429 / rate-limit hold is honoured for.
const MAX_HOLD: Duration = Duration::from_secs(3600);
const DEFAULT_RETRY_AFTER: Duration = Duration::from_secs(60);
const MAX_BACKOFF: Duration = Duration::from_secs(300);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

/// Shown when no token can be found.
pub const NOT_CONFIGURED_REASON: &str = "Sentry: no credentials found. Set SENTRY_API_TOKEN in ~/.claude/credentials/.env, as the sentry skill uses.";

const QUERIES: [&str; 2] = [
    "is:unresolved assigned:me",
    "is:unresolved is:unassigned level:[error,fatal] lastSeen:-24h",
];

/// Where and how to talk to Sentry.
#[derive(Clone)]
pub struct SentryConfig {
    /// API root without a trailing slash (`https://sentry.io/api/0`).
    pub base_url: String,
    pub org: String,
    /// Where `SENTRY_API_TOKEN` is looked up (environment first, then the file).
    pub env_file: Arc<EnvFile>,
    /// `{ "<project slug>": "<repo dir name>" }`; absent file = no mapping.
    pub repos_path: PathBuf,
    /// Time between fetches (120 s).
    pub poll_interval: Duration,
    /// First retry delay after a failed fetch; doubles per consecutive failure.
    pub backoff_base: Duration,
}

impl SentryConfig {
    pub fn new(base_url: String, org: String, env_path: PathBuf, repos_path: PathBuf) -> Self {
        Self {
            base_url: base_url.trim_end_matches('/').to_string(),
            org,
            env_file: Arc::new(EnvFile::new(env_path)),
            repos_path,
            poll_interval: Duration::from_secs(120),
            backoff_base: Duration::from_secs(30),
        }
    }

    /// The daemon's configuration: `SENTRY_ORG`, else `sentry.json`
    /// (`organization`, `base_url`), else `carefeed` / `https://sentry.io/api/0`.
    pub fn from_environment() -> Self {
        let home = dirs_next::home_dir().unwrap_or_else(|| PathBuf::from("/tmp"));
        let meta: Value = std::fs::read_to_string(
            home.join(".claude").join("credentials").join("services").join("sentry.json"),
        )
        .ok()
        .and_then(|raw| serde_json::from_str(&raw).ok())
        .unwrap_or(Value::Null);
        let text = |v: Option<String>| v.map(|s| s.trim().to_string()).filter(|s| !s.is_empty());
        let org = text(std::env::var("SENTRY_ORG").ok())
            .or_else(|| text(meta["organization"].as_str().map(String::from)))
            .unwrap_or_else(|| DEFAULT_ORG.to_string());
        let base = text(meta["base_url"].as_str().map(String::from))
            .unwrap_or_else(|| DEFAULT_BASE_URL.to_string());
        Self::new(
            base,
            org,
            default_env_path(),
            home.join(".nostromo").join("teri").join("sentry-repos.json"),
        )
    }
}

/// Start the source. `refresh` is poked by a manual refresh that passed the
/// hub's 15 s debounce; the source fetches immediately when it fires.
pub fn spawn(refresh: Arc<Notify>) -> watch::Receiver<SourceUpdate> {
    spawn_with(SentryConfig::from_environment(), refresh)
}

/// Detail for one of this source's item ids.
pub async fn detail(item_id: &str) -> Result<WorkDetail, WorkError> {
    detail_with(&SentryConfig::from_environment(), item_id).await
}

pub fn spawn_with(config: SentryConfig, refresh: Arc<Notify>) -> watch::Receiver<SourceUpdate> {
    let (tx, rx) = watch::channel((status(SourceState::Loading, None, None, None, 0), Vec::new()));
    tokio::spawn(run(config, refresh, tx));
    rx
}

// ── fetch loop ────────────────────────────────────────────────────────────────

fn status(
    state: SourceState,
    reason: Option<String>,
    updated_at: Option<DateTime<Utc>>,
    retry_at: Option<DateTime<Utc>>,
    count: usize,
) -> SourceStatus {
    SourceStatus {
        source: WorkSource::Sentry,
        state,
        updated_at,
        reason,
        retry_at,
        count,
        group_errors: Vec::new(),
    }
}

async fn run(config: SentryConfig, refresh: Arc<Notify>, tx: watch::Sender<SourceUpdate>) {
    let client = match reqwest::Client::builder().timeout(REQUEST_TIMEOUT).build() {
        Ok(c) => c,
        Err(_) => return,
    };
    let mut items: Vec<WorkItem> = Vec::new();
    let mut last_ok: Option<DateTime<Utc>> = None;
    let mut failures: u32 = 0;
    let mut hold_until: Option<DateTime<Utc>> = None;

    loop {
        let (update, wait) = fetch_round(&config, &client, &mut items, &mut last_ok, &mut failures, &mut hold_until).await;
        if tx.send(update).is_err() {
            return; // nobody is listening any more
        }
        let wake_at = tokio::time::Instant::now() + wait;
        loop {
            tokio::select! {
                _ = tokio::time::sleep_until(wake_at) => break,
                _ = refresh.notified() => {
                    // A manual refresh never overrides a rate-limit hold.
                    if hold_until.is_none_or(|t| t <= Utc::now()) { break; }
                }
            }
        }
    }
}

/// One fetch. Updates the carried state and returns what to publish and how
/// long to wait before the next fetch.
async fn fetch_round(
    config: &SentryConfig,
    client: &reqwest::Client,
    items: &mut Vec<WorkItem>,
    last_ok: &mut Option<DateTime<Utc>>,
    failures: &mut u32,
    hold_until: &mut Option<DateTime<Utc>>,
) -> (SourceUpdate, Duration) {
    let Some(token) = lookup_token(&config.env_file).await else {
        items.clear();
        *last_ok = None;
        *failures = 0;
        *hold_until = None;
        let update = (status(SourceState::NotConfigured, Some(NOT_CONFIGURED_REASON.into()), None, None, 0), Vec::new());
        return (update, config.poll_interval);
    };

    let repos = read_repos(&config.repos_path).await;
    let api = Api { client, base: &config.base_url, token: &token };
    let mut hold: Option<DateTime<Utc>> = None;
    let result = fetch_issues(&api, &config.org, &repos, &mut hold).await;
    *hold_until = hold.filter(|t| *t > Utc::now());

    let publish = |state, reason, retry_at, items: &Vec<WorkItem>, last_ok| -> SourceUpdate {
        (status(state, reason, last_ok, retry_at, items.len()), vec![(None, items.clone())])
    };
    let hold_wait = |base: Duration, hold_until: &Option<DateTime<Utc>>| {
        hold_until
            .and_then(|t| (t - Utc::now()).to_std().ok())
            .map_or(base, |h| base.max(h))
    };

    match result {
        Ok(fetched) => {
            *failures = 0;
            *last_ok = Some(Utc::now());
            *items = fetched;
            let state = if items.is_empty() { SourceState::Empty } else { SourceState::Fresh };
            (publish(state, None, None, items, *last_ok), hold_wait(config.poll_interval, hold_until))
        }
        Err(ApiError::Unauthenticated) => {
            items.clear();
            *last_ok = None;
            *failures = 0;
            let reason = "Sentry rejected the token. Check SENTRY_API_TOKEN in ~/.claude/credentials/.env (scopes: project:read, event:read, org:read).";
            (
                (status(SourceState::Unauthenticated, Some(reason.into()), None, None, 0), Vec::new()),
                config.poll_interval,
            )
        }
        Err(ApiError::RateLimited { retry_at }) => {
            let retry_at = retry_at.min(Utc::now() + chrono_duration(MAX_HOLD));
            *hold_until = Some(retry_at);
            let wait = (retry_at - Utc::now()).to_std().unwrap_or_default();
            let reason = "Sentry is rate-limiting requests; waiting before the next try".to_string();
            (publish(SourceState::RateLimited, Some(reason), Some(retry_at), items, *last_ok), wait)
        }
        Err(other) => {
            *failures = failures.saturating_add(1);
            let delay = backoff(config.backoff_base, *failures);
            let what = other.describe();
            warn!(failures = *failures, "sentry fetch failed: {what}");
            let (state, reason) = if last_ok.is_some() {
                (SourceState::Stale, format!("Couldn't refresh Sentry ({what}); showing the last results"))
            } else {
                (SourceState::Error, format!("Couldn't load Sentry issues ({what})"))
            };
            (publish(state, Some(reason), None, items, *last_ok), hold_wait(delay, hold_until))
        }
    }
}

fn backoff(base: Duration, failures: u32) -> Duration {
    let shift = failures.saturating_sub(1).min(16);
    base.saturating_mul(1u32 << shift).min(MAX_BACKOFF.max(base))
}

fn chrono_duration(d: Duration) -> chrono::Duration {
    chrono::Duration::from_std(d).unwrap_or(chrono::Duration::hours(1))
}

async fn lookup_token(env: &Arc<EnvFile>) -> Option<String> {
    let env = Arc::clone(env);
    tokio::task::spawn_blocking(move || env.lookup(TOKEN_VAR))
        .await
        .ok()
        .flatten()
        .map(|t| t.trim().to_string())
        .filter(|t| !t.is_empty())
}

async fn read_repos(path: &std::path::Path) -> HashMap<String, String> {
    let Ok(raw) = tokio::fs::read_to_string(path).await else { return HashMap::new() };
    serde_json::from_str(&raw).unwrap_or_default()
}

// ── HTTP ──────────────────────────────────────────────────────────────────────

enum ApiError {
    Unauthenticated,
    NotFound,
    RateLimited { retry_at: DateTime<Utc> },
    Status(u16),
    Transport,
    Malformed,
}

impl ApiError {
    /// Plain English with no URL, body or token.
    fn describe(&self) -> String {
        match self {
            ApiError::Status(code) => format!("HTTP {code}"),
            ApiError::Transport => "Sentry could not be reached".into(),
            ApiError::Malformed => "unexpected response".into(),
            ApiError::NotFound => "HTTP 404".into(),
            ApiError::Unauthenticated => "HTTP 401".into(),
            ApiError::RateLimited { .. } => "HTTP 429".into(),
        }
    }
}

struct Api<'a> {
    client: &'a reqwest::Client,
    base: &'a str,
    token: &'a str,
}

impl Api<'_> {
    async fn get(
        &self,
        path: &str,
        query: &[(&str, String)],
        hold: &mut Option<DateTime<Utc>>,
    ) -> Result<(Value, HeaderMap), ApiError> {
        let url = format!("{}{}", self.base, path);
        let response = self
            .client
            .get(&url)
            .header(AUTHORIZATION, format!("Bearer {}", self.token))
            .query(query)
            .send()
            .await
            .map_err(|_| ApiError::Transport)?;
        let status = response.status();
        let headers = response.headers().clone();
        let reset = rate_limit_reset(&headers);
        if headers
            .get("x-sentry-rate-limit-remaining")
            .and_then(|v| v.to_str().ok())
            .is_some_and(|v| v.trim() == "0")
        {
            if let Some(reset) = reset {
                *hold = Some(hold.map_or(reset, |h| h.max(reset)));
            }
        }
        match status.as_u16() {
            200..=299 => {}
            401 | 403 => return Err(ApiError::Unauthenticated),
            404 => return Err(ApiError::NotFound),
            429 => {
                let after = headers
                    .get(RETRY_AFTER)
                    .and_then(|v| v.to_str().ok())
                    .and_then(|v| v.trim().parse::<u64>().ok())
                    .map(Duration::from_secs);
                let retry_at = match (after, reset) {
                    (Some(after), _) => Utc::now() + chrono_duration(after.min(MAX_HOLD)),
                    (None, Some(reset)) => reset,
                    (None, None) => Utc::now() + chrono_duration(DEFAULT_RETRY_AFTER),
                };
                return Err(ApiError::RateLimited { retry_at });
            }
            code => return Err(ApiError::Status(code)),
        }
        let body = response.json::<Value>().await.map_err(|_| ApiError::Malformed)?;
        Ok((body, headers))
    }
}

fn rate_limit_reset(headers: &HeaderMap) -> Option<DateTime<Utc>> {
    let secs = headers
        .get("x-sentry-rate-limit-reset")?
        .to_str()
        .ok()?
        .trim()
        .parse::<f64>()
        .ok()?;
    DateTime::from_timestamp(secs as i64, 0)
}

/// The `cursor` of the `rel="next"` link when it has results.
fn next_cursor(headers: &HeaderMap) -> Option<String> {
    let link = headers.get("link")?.to_str().ok()?;
    link.split('<').skip(1).find_map(|part| {
        let params = part.split_once('>')?.1;
        if !params.contains("rel=\"next\"") || !params.contains("results=\"true\"") {
            return None;
        }
        let rest = params.split_once("cursor=\"")?.1;
        Some(rest.split('"').next()?.to_string())
    })
}

async fn fetch_issues(
    api: &Api<'_>,
    org: &str,
    repos: &HashMap<String, String>,
    hold: &mut Option<DateTime<Utc>>,
) -> Result<Vec<WorkItem>, ApiError> {
    let path = format!("/organizations/{org}/issues/");
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for query in QUERIES {
        let mut cursor: Option<String> = None;
        let mut count = 0usize;
        loop {
            // Out of quota (`remaining` 0): do not ask for more until the reset.
            if let Some(reset) = hold.filter(|t| *t > Utc::now()) {
                return Err(ApiError::RateLimited { retry_at: reset });
            }
            let mut params = vec![
                ("project", "-1".to_string()),
                ("statsPeriod", "24h".to_string()),
                ("limit", PAGE_LIMIT.to_string()),
                ("query", query.to_string()),
            ];
            if let Some(c) = &cursor {
                params.push(("cursor", c.clone()));
            }
            let (body, headers) = api.get(&path, &params, hold).await?;
            let page = body.as_array().ok_or(ApiError::Malformed)?;
            for issue in page {
                if count >= MAX_ISSUES_PER_QUERY {
                    break;
                }
                count += 1;
                if let Some(item) = to_item(issue, repos) {
                    if seen.insert(item.id.clone()) {
                        out.push(item);
                    }
                }
            }
            cursor = next_cursor(&headers);
            if cursor.is_none() || count >= MAX_ISSUES_PER_QUERY || page.is_empty() {
                break;
            }
        }
    }
    Ok(out)
}

// ── mapping ───────────────────────────────────────────────────────────────────

fn text(v: &Value) -> Option<String> {
    v.as_str().map(str::trim).filter(|s| !s.is_empty()).map(String::from)
}

fn number(v: &Value) -> Option<i64> {
    v.as_i64().or_else(|| v.as_str().and_then(|s| s.trim().parse().ok()))
}

fn timestamp(v: &Value) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(v.as_str()?).ok().map(|d| d.with_timezone(&Utc))
}

fn events_24h(issue: &Value) -> i64 {
    issue["stats"]["24h"]
        .as_array()
        .map(|points| points.iter().filter_map(|p| p.get(1).and_then(number)).sum())
        .unwrap_or(0)
}

fn environment(issue: &Value) -> Option<String> {
    issue["environments"]
        .as_array()
        .and_then(|envs| envs.iter().find_map(text))
        .or_else(|| {
            issue["tags"].as_array().and_then(|tags| {
                tags.iter()
                    .find(|t| t["key"].as_str() == Some("environment"))
                    .and_then(|t| text(&t["value"]))
            })
        })
}

fn priority_for(level: &str) -> Priority {
    let rank = match level {
        "fatal" => 1,
        "error" => 2,
        "warning" => 3,
        _ => 4,
    };
    Priority { label: level.to_string(), rank }
}

fn to_item(issue: &Value, repos: &HashMap<String, String>) -> Option<WorkItem> {
    let id = text(&issue["id"]).or_else(|| number(&issue["id"]).map(|n| n.to_string()))?;
    let title = text(&issue["title"]).unwrap_or_else(|| "(untitled issue)".into());
    let project = text(&issue["project"]["slug"]);
    let short_id = text(&issue["shortId"]);
    let level = text(&issue["level"]);
    let mut metrics = std::collections::BTreeMap::new();
    metrics.insert("events_24h".to_string(), events_24h(issue));
    if let Some(users) = number(&issue["userCount"]) {
        metrics.insert("users".to_string(), users);
    }
    let search_text = [short_id.clone(), Some(title.clone()), text(&issue["culprit"])]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>()
        .join("\n");
    Some(WorkItem {
        id: format!("sentry:{id}"),
        source: WorkSource::Sentry,
        kind: "issue".into(),
        title,
        repo: project.as_ref().and_then(|p| repos.get(p)).cloned(),
        project,
        status: text(&issue["substatus"]).or_else(|| text(&issue["status"])),
        status_category: None,
        priority: level.as_deref().map(priority_for),
        severity: level,
        environment: environment(issue),
        created_at: timestamp(&issue["firstSeen"]),
        updated_at: timestamp(&issue["lastSeen"]),
        due: None,
        url: text(&issue["permalink"]),
        path: None,
        metrics,
        linked: short_id.into_iter().collect(),
        search_text,
        sent: Vec::new(),
    })
}

// ── detail ────────────────────────────────────────────────────────────────────

pub async fn detail_with(config: &SentryConfig, item_id: &str) -> Result<WorkDetail, WorkError> {
    let id = item_id
        .strip_prefix("sentry:")
        .filter(|id| !id.is_empty() && id.chars().all(|c| c.is_ascii_alphanumeric()))
        .ok_or_else(|| WorkError::new("unknown_item", "Unknown Sentry issue"))?;
    let token = lookup_token(&config.env_file)
        .await
        .ok_or_else(|| WorkError::new("not_configured", NOT_CONFIGURED_REASON))?;
    let client = reqwest::Client::builder()
        .timeout(REQUEST_TIMEOUT)
        .build()
        .map_err(|_| WorkError::new("error", "Couldn't start the Sentry client"))?;
    let api = Api { client: &client, base: &config.base_url, token: &token };
    let mut hold = None;

    let (issue, _) = api
        .get(&format!("/issues/{id}/"), &[], &mut hold)
        .await
        .map_err(|e| detail_error(&e))?;
    // The latest event only adds the stack: the issue is still worth showing without it.
    let event = api.get(&format!("/issues/{id}/events/latest/"), &[], &mut hold).await;
    let event = match event {
        Ok((event, _)) => Some(event),
        Err(ApiError::Unauthenticated) => return Err(detail_error(&ApiError::Unauthenticated)),
        Err(_) => None,
    };
    Ok(build_detail(item_id, &issue, event.as_ref()))
}

fn detail_error(e: &ApiError) -> WorkError {
    match e {
        ApiError::NotFound => WorkError::new("unknown_item", "That Sentry issue no longer exists"),
        ApiError::Unauthenticated => WorkError::new(
            "unauthenticated",
            "Sentry rejected the token. Check SENTRY_API_TOKEN in ~/.claude/credentials/.env.",
        ),
        ApiError::RateLimited { .. } => {
            WorkError::new("rate_limited", "Sentry is rate-limiting requests; try again shortly")
        }
        other => WorkError::new("error", format!("Couldn't load the Sentry issue ({})", other.describe())),
    }
}

fn build_detail(item_id: &str, issue: &Value, event: Option<&Value>) -> WorkDetail {
    let when = |v: &Value| timestamp(v).map(|t| t.format("%Y-%m-%d %H:%M UTC").to_string());
    let mut fields: Vec<(String, String)> = Vec::new();
    let total = number(&issue["count"]).unwrap_or(0);
    fields.push(("Events".into(), format!("{total} total, {} in 24 h", events_24h(issue))));
    fields.push(("Users".into(), number(&issue["userCount"]).unwrap_or(0).to_string()));
    if let Some(t) = when(&issue["firstSeen"]) {
        fields.push(("First seen".into(), t));
    }
    if let Some(t) = when(&issue["lastSeen"]) {
        fields.push(("Last seen".into(), t));
    }
    if let Some(env) = environment(issue) {
        fields.push(("Environment".into(), env));
    }
    if let Some(level) = text(&issue["level"]) {
        fields.push(("Level".into(), level));
    }
    let assignee = text(&issue["assignedTo"]["name"])
        .or_else(|| text(&issue["assignee"]["name"]))
        .unwrap_or_else(|| "Unassigned".into());
    fields.push(("Assignee".into(), assignee));
    if let Some(culprit) = text(&issue["culprit"]) {
        fields.push(("Culprit".into(), culprit));
    }

    let links = text(&issue["permalink"])
        .map(|url| vec![Link { label: "Open in Sentry".into(), url }])
        .unwrap_or_default();
    WorkDetail {
        item_id: item_id.to_string(),
        title: text(&issue["title"]).unwrap_or_else(|| "(untitled issue)".into()),
        fields,
        markdown: event.map(stack_markdown).unwrap_or_default(),
        files: Vec::new(),
        links,
    }
}

/// The top (innermost) frames of the first exception, one per line:
/// `● file:line in function`, in-app frames marked.
fn stack_markdown(event: &Value) -> String {
    let frames = event["entries"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|e| e["type"].as_str() == Some("exception"))
        .flat_map(|e| e["data"]["values"].as_array().into_iter().flatten())
        .find_map(|v| v["stacktrace"]["frames"].as_array());
    let Some(frames) = frames else { return String::new() };
    // Sentry lists frames oldest first: the top of the stack is the end.
    frames
        .iter()
        .rev()
        .take(MAX_FRAMES)
        .map(|f| {
            let file = text(&f["filename"])
                .or_else(|| text(&f["module"]))
                .unwrap_or_else(|| "?".into());
            let mut line = file;
            if let Some(n) = number(&f["lineNo"]) {
                line.push_str(&format!(":{n}"));
            }
            if let Some(func) = text(&f["function"]) {
                line.push_str(&format!(" in {func}"));
            }
            let mark = if f["inApp"].as_bool() == Some(true) { "● " } else { "  " };
            format!("{mark}{line}")
        })
        .collect::<Vec<_>>()
        .join("\n")
}
