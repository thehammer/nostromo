//! Sentry work source (Teri's Sentry tab).
//!
//! Scope: unresolved issues **assigned to the user**, plus **unassigned
//! error/fatal issues last seen within 24 h** (still firing). Two searches on
//! `GET {base}/organizations/{org}/issues/`, unioned by issue id.
//!
//! Auth is the static user token `SENTRY_API_TOKEN` (process environment, then
//! `~/.claude/credentials/.env`, re-read when the file changes). The token only
//! ever travels in the `Authorization` header, and only to a validated Sentry
//! endpoint (`https`, `sentry.io` or `*.sentry.io`, see [`SentryConfig`]): it is
//! never put in a status reason, an item, a detail, a URL or a log line, and
//! redirects are never followed.
//!
//! API facts (Sentry's published docs, "List an Organization's Issues"): the
//! list payload has no `environments` or `tags`, so list rows carry no
//! environment; `statsPeriod` is "the period of time for the query", so the
//! assigned search uses a wide window (an assigned issue that has not fired for
//! days is still assigned) and only the fresh-fires search uses 24 h; the
//! per-issue 24 h count is `stats["24h"]` (requested with `groupStatsPeriod=24h`);
//! the environment of an issue is on its latest event's `tags`.
//!
//! The hub's seam is [`spawn`] and [`detail`]; [`spawn_with`] / [`detail_with`]
//! take an explicit [`SentryConfig`] (tests point it at a fake server).

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use chrono::{DateTime, Utc};
use reqwest::header::{HeaderMap, AUTHORIZATION, RETRY_AFTER};
use serde_json::Value;
use tokio::sync::{watch, Notify};
use tracing::warn;

use super::credentials::{default_env_path, EnvFile};
use super::endpoint::{https_api_base, https_link, is_slug};
use super::hub::SourceUpdate;
use super::untrusted::{one_line, MAX_LINE_CHARS};
use super::model::{
    Link, Priority, SourceState, SourceStatus, WorkDetail, WorkError, WorkItem, WorkSource,
};

const TOKEN_VAR: &str = "SENTRY_API_TOKEN";
const ORG_VAR: &str = "SENTRY_ORG";
const DEFAULT_BASE_URL: &str = "https://sentry.io/api/0";
const API_PATH: &str = "/api/0";
const DEFAULT_ORG: &str = "carefeed";
const SENTRY_JSON_NAME: &str = "~/.claude/credentials/services/sentry.json";
const PAGE_LIMIT: usize = 100;
/// Issues kept per search; more than this is reported as truncation.
pub const MAX_ISSUES_PER_QUERY: usize = 300;
const MAX_FRAMES: usize = 10;
/// The longest a rate-limit hold is honoured for, wherever it came from.
pub const MAX_HOLD: Duration = Duration::from_secs(3600);
/// How long a list counts as fresh: a hold that pushes the next fetch past this
/// makes the source `Stale` instead.
pub const FRESHNESS_WINDOW: Duration = Duration::from_secs(300);
/// The shortest a 429 holds off for: `Retry-After: 0` or a reset already in the
/// past must not turn into a request loop against a server that is pushing back.
const MIN_HOLD: Duration = Duration::from_secs(5);
const DEFAULT_RETRY_AFTER: Duration = Duration::from_secs(60);
const MAX_BACKOFF: Duration = Duration::from_secs(300);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

/// Shown when no token can be found.
pub const NOT_CONFIGURED_REASON: &str = "Sentry: no credentials found. Set SENTRY_API_TOKEN in ~/.claude/credentials/.env, as the sentry skill uses.";

/// What a 403 says: the token works but may lack a scope. Names the variable and the scopes, never a value.
const MISSING_PERMISSION_REASON: &str = "Sentry accepted the token but it is missing a permission. Check SENTRY_API_TOKEN in ~/.claude/credentials/.env (scopes needed: project:read, event:read, org:read).";

const TRUNCATED_REASON: &str =
    "Showing the first 300 issues per search; Sentry has more. Narrow the search in Sentry to see the rest.";

/// A search sent to the issues endpoint. `stats_period` bounds which issues the
/// search matches (by activity in the window).
struct Search {
    query: &'static str,
    stats_period: &'static str,
}

const SEARCHES: [Search; 2] = [
    // Assigned to me stays assigned however quiet the issue is: look far back.
    Search { query: "is:unresolved assigned:me", stats_period: "90d" },
    Search { query: "is:unresolved is:unassigned level:[error,fatal] lastSeen:-24h", stats_period: "24h" },
];

/// The time source, injectable so rate-limit holds can be tested without waiting.
pub type Clock = Arc<dyn Fn() -> DateTime<Utc> + Send + Sync>;

/// Where and how to talk to Sentry.
///
/// The base URL and organization are validated when the config is built: an
/// invalid one is kept as a [`config_error`](Self::config_error) and the source
/// makes no request at all (a typo or hostile edit must never send the token
/// anywhere else or rewrite the request path).
#[derive(Clone)]
pub struct SentryConfig {
    base_url: String,
    org: String,
    config_error: Option<String>,
    /// Where `SENTRY_API_TOKEN` is looked up (environment first, then the file).
    pub env_file: Arc<EnvFile>,
    /// `{ "<project slug>": "<repo dir name>" }`; absent file = no mapping.
    pub repos_path: PathBuf,
    /// Time between fetches (120 s).
    pub poll_interval: Duration,
    /// First retry delay after a failed fetch; doubles per consecutive failure.
    pub backoff_base: Duration,
    pub clock: Clock,
}

impl SentryConfig {
    /// `base_url` must be `https://sentry.io/api/0` or the same on a
    /// `*.sentry.io` host, and `org` a slug (`[a-z0-9_-]+`); otherwise the
    /// config carries an error naming the setting (never its value).
    pub fn new(base_url: String, org: String, env_path: PathBuf, repos_path: PathBuf) -> Self {
        Self::checked(
            &base_url,
            ("the configured base URL", "the configured organization"),
            &org,
            env_path,
            repos_path,
        )
    }

    /// For tests that point the source at a local fake: skips the base URL
    /// host/scheme check (the organization is still validated). Never used by
    /// the daemon, and not even compiled into it.
    #[cfg(any(test, feature = "test-support"))]
    #[doc(hidden)]
    pub fn for_test_server(base_url: String, org: String, env_path: PathBuf, repos_path: PathBuf) -> Self {
        let error = check_org(&org, "the configured organization");
        Self::assemble(base_url.trim_end_matches('/').to_string(), error, &org, env_path, repos_path)
    }

    /// The daemon's configuration: `SENTRY_ORG`, else `sentry.json`
    /// (`organization`, `base_url`), else `carefeed` / `https://sentry.io/api/0`.
    pub fn from_environment() -> Self {
        let home = dirs_next::home_dir().unwrap_or_else(|| PathBuf::from("/tmp"));
        Self::from_sources(
            &home.join(".claude").join("credentials").join("services").join("sentry.json"),
            std::env::var(ORG_VAR).ok(),
            default_env_path(),
            home.join(".nostromo").join("teri").join("sentry-repos.json"),
        )
    }

    /// [`from_environment`](Self::from_environment) with the inputs explicit:
    /// `sentry_json` is read if present, `org_override` is `SENTRY_ORG`'s value.
    /// An invalid setting is an error naming the file or variable, never a
    /// silent fallback to the defaults.
    pub fn from_sources(
        sentry_json: &Path,
        org_override: Option<String>,
        env_path: PathBuf,
        repos_path: PathBuf,
    ) -> Self {
        let meta: Value = std::fs::read_to_string(sentry_json)
            .ok()
            .and_then(|raw| serde_json::from_str(&raw).ok())
            .unwrap_or(Value::Null);
        // Absent or blank = use the default; present but not a string = invalid.
        let setting = |key: &str| match &meta[key] {
            Value::Null => None,
            Value::String(s) => Some(s.trim().to_string()).filter(|s| !s.is_empty()),
            _ => Some(String::new()),
        };
        let env_org = org_override.map(|s| s.trim().to_string()).filter(|s| !s.is_empty());
        let (org, org_label) = match (env_org, setting("organization")) {
            (Some(org), _) => (org, ORG_VAR.to_string()),
            (None, Some(org)) => (org, format!("organization in {SENTRY_JSON_NAME}")),
            (None, None) => (DEFAULT_ORG.to_string(), "the default organization".to_string()),
        };
        let (base, base_label) = match setting("base_url") {
            Some(base) => (base, format!("base_url in {SENTRY_JSON_NAME}")),
            None => (DEFAULT_BASE_URL.to_string(), "the default base URL".to_string()),
        };
        Self::checked(&base, (&base_label, &org_label), &org, env_path, repos_path)
    }

    /// Why the source will not talk to Sentry (a plain-English reason that
    /// names the offending setting, not its value); `None` when usable.
    pub fn config_error(&self) -> Option<&str> {
        self.config_error.as_deref()
    }

    fn checked(
        base_url: &str,
        (base_label, org_label): (&str, &str),
        org: &str,
        env_path: PathBuf,
        repos_path: PathBuf,
    ) -> Self {
        let (base, base_error) = match check_base_url(base_url, base_label) {
            Ok(base) => (base, None),
            Err(error) => (DEFAULT_BASE_URL.to_string(), Some(error)),
        };
        let error = base_error.or_else(|| check_org(org, org_label));
        Self::assemble(base, error, org, env_path, repos_path)
    }

    /// Fields only; every validation has already happened.
    fn assemble(
        base_url: String,
        config_error: Option<String>,
        org: &str,
        env_path: PathBuf,
        repos_path: PathBuf,
    ) -> Self {
        Self {
            base_url,
            org: org.to_string(),
            config_error,
            env_file: Arc::new(EnvFile::new(env_path)),
            repos_path,
            poll_interval: Duration::from_secs(120),
            backoff_base: Duration::from_secs(30),
            clock: Arc::new(Utc::now),
        }
    }

    fn now(&self) -> DateTime<Utc> {
        (self.clock)()
    }
}

/// The canonical API base for `raw`, or the plain-English error naming `label`.
fn check_base_url(raw: &str, label: &str) -> Result<String, String> {
    https_api_base(raw.trim(), is_sentry_host, API_PATH).ok_or_else(|| {
        format!(
            "Sentry: {label} is not an https://sentry.io{API_PATH} address (https, on sentry.io or a *.sentry.io host); not contacting Sentry. Fix it and restart the daemon."
        )
    })
}

/// The error for an organization that is not a slug, naming `label`.
fn check_org(org: &str, label: &str) -> Option<String> {
    (!is_slug(org)).then(|| {
        format!(
            "Sentry: {label} is not a valid organization slug (lowercase letters, digits, - and _); not contacting Sentry. Fix it and restart the daemon."
        )
    })
}

/// `sentry.io` and any subdomain of it (regions such as `de.sentry.io`).
fn is_sentry_host(host: &str) -> bool {
    host == "sentry.io" || host.strip_suffix(".sentry.io").is_some_and(|label| !label.is_empty())
}

/// Start the source. `refresh` is poked by a manual refresh that passed the
/// hub's 15 s debounce; the source fetches immediately when it fires.
pub fn spawn(refresh: Arc<Notify>) -> watch::Receiver<SourceUpdate> {
    spawn_with(SentryConfig::from_environment(), refresh)
}

/// The dormant placeholder for a hub that was not given a Sentry configuration
/// (tests): it reads no credentials and never touches the network.
pub fn spawn_dormant(_refresh: Arc<Notify>) -> watch::Receiver<SourceUpdate> {
    let status = status(SourceState::NotConfigured, Some("Coming soon".into()), None, None, 0);
    // The sender is dropped on purpose: the placeholder never changes.
    watch::channel((status, Vec::new())).1
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

/// Never follows a redirect: the token must only reach the validated host.
fn http_client() -> Option<reqwest::Client> {
    reqwest::Client::builder()
        .timeout(REQUEST_TIMEOUT)
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .ok()
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
    let Some(client) = http_client() else {
        let reason = "Couldn't start the Sentry client".to_string();
        let _ = tx.send((status(SourceState::Error, Some(reason), None, None, 0), Vec::new()));
        return;
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
                    if hold_until.is_none_or(|t| t <= config.now()) { break; }
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
    if let Some(reason) = config.config_error() {
        items.clear();
        *last_ok = None;
        *failures = 0;
        *hold_until = None;
        let update = (status(SourceState::Error, Some(reason.to_string()), None, None, 0), Vec::new());
        return (update, config.poll_interval);
    }
    let Some(token) = lookup_token(&config.env_file).await else {
        items.clear();
        *last_ok = None;
        *failures = 0;
        *hold_until = None;
        let update = (status(SourceState::NotConfigured, Some(NOT_CONFIGURED_REASON.into()), None, None, 0), Vec::new());
        return (update, config.poll_interval);
    };

    let repos = read_repos(&config.repos_path).await;
    let api = Api { client, base: &config.base_url, token: &token, clock: &config.clock };
    let mut hold: Option<DateTime<Utc>> = None;
    let result = fetch_issues(&api, &config.org, &repos, &mut hold).await;
    let now = config.now();
    *hold_until = hold.filter(|t| *t > now);

    let publish = |state, reason, retry_at, items: &Vec<WorkItem>, last_ok| -> SourceUpdate {
        (status(state, reason, last_ok, retry_at, items.len()), vec![(None, items.clone())])
    };
    let hold_wait = |base: Duration, hold_until: &Option<DateTime<Utc>>| {
        hold_until
            .and_then(|t| (t - config.now()).to_std().ok())
            .map_or(base, |h| base.max(h))
    };

    match result {
        Ok(fetched) => {
            *failures = 0;
            *last_ok = Some(now);
            *items = fetched.items;
            let truncated = fetched.truncated.then(|| TRUNCATED_REASON.to_string());
            // A hold that outlasts the freshness window means the list will be
            // out of date before it can be refreshed: say so.
            let held_past_window = hold_until.filter(|t| *t - now > chrono_duration(FRESHNESS_WINDOW));
            let (state, reason, retry_at) = match held_past_window {
                Some(until) => {
                    let why = "Sentry's rate limit is holding off the next refresh".to_string();
                    (SourceState::Stale, Some(truncated.map_or(why.clone(), |t| format!("{why}. {t}"))), Some(until))
                }
                None if items.is_empty() => (SourceState::Empty, None, None),
                None => (SourceState::Fresh, truncated, None),
            };
            (publish(state, reason, retry_at, items, *last_ok), hold_wait(config.poll_interval, hold_until))
        }
        Err(rejected @ (ApiError::Unauthenticated | ApiError::Forbidden)) => {
            items.clear();
            *last_ok = None;
            *failures = 0;
            let reason = if matches!(rejected, ApiError::Forbidden) {
                MISSING_PERMISSION_REASON
            } else {
                "Sentry rejected the token. Check SENTRY_API_TOKEN in ~/.claude/credentials/.env (scopes: project:read, event:read, org:read)."
            };
            (
                (status(SourceState::Unauthenticated, Some(reason.into()), None, None, 0), Vec::new()),
                config.poll_interval,
            )
        }
        Err(ApiError::RateLimited { retry_at }) => {
            let retry_at = retry_at.clamp(now + chrono_duration(MIN_HOLD), now + chrono_duration(MAX_HOLD));
            *hold_until = Some(retry_at);
            let wait = (retry_at - now).to_std().unwrap_or_default();
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
    /// 401: the token is not accepted.
    Unauthenticated,
    /// 403: the token is accepted but may not do this (a missing scope).
    Forbidden,
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
            ApiError::Forbidden => "HTTP 403".into(),
            ApiError::RateLimited { .. } => "HTTP 429".into(),
        }
    }
}

struct Api<'a> {
    client: &'a reqwest::Client,
    /// Validated: `https://<sentry host>/api/0`.
    base: &'a str,
    token: &'a str,
    clock: &'a Clock,
}

impl Api<'_> {
    /// `path` is built from validated pieces only (organization slug, numeric issue id).
    async fn get(
        &self,
        path: &str,
        query: &[(&str, String)],
        hold: &mut Option<DateTime<Utc>>,
    ) -> Result<(Value, HeaderMap), ApiError> {
        let url = format!("{}{}", self.base, path);
        let mut bearer = reqwest::header::HeaderValue::try_from(format!("Bearer {}", self.token))
            .map_err(|_| ApiError::Transport)?;
        bearer.set_sensitive(true);
        let response = self
            .client
            .get(&url)
            .header(AUTHORIZATION, bearer)
            .query(query)
            .send()
            .await
            .map_err(|_| ApiError::Transport)?;
        let now = (self.clock)();
        let status = response.status();
        let headers = response.headers().clone();
        // Every recorded hold is capped: a far-future reset must not park the source.
        let reset = rate_limit_reset(&headers).map(|r| r.min(now + chrono_duration(MAX_HOLD)));
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
            401 => return Err(ApiError::Unauthenticated),
            403 => return Err(ApiError::Forbidden),
            404 => return Err(ApiError::NotFound),
            429 => {
                let after = headers
                    .get(RETRY_AFTER)
                    .and_then(|v| v.to_str().ok())
                    .and_then(|v| v.trim().parse::<u64>().ok())
                    .map(Duration::from_secs);
                let retry_at = match (after, reset) {
                    (Some(after), _) => now + chrono_duration(after.min(MAX_HOLD)),
                    (None, Some(reset)) => reset,
                    (None, None) => now + chrono_duration(DEFAULT_RETRY_AFTER),
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
    if !secs.is_finite() {
        return None;
    }
    // Out of chrono's range (a bogus far-future value) is still "a long way off".
    Some(DateTime::from_timestamp(secs as i64, 0).unwrap_or(if secs > 0.0 { DateTime::<Utc>::MAX_UTC } else { DateTime::<Utc>::MIN_UTC }))
}

/// The `cursor` of the `rel="next"` link when it has results.
fn next_cursor(headers: &HeaderMap) -> Option<String> {
    headers.get_all("link").iter().filter_map(|v| v.to_str().ok()).find_map(next_cursor_in)
}

fn next_cursor_in(link: &str) -> Option<String> {
    link.split('<').skip(1).find_map(|part| {
        let params = part.split_once('>')?.1;
        if !params.contains("rel=\"next\"") || !params.contains("results=\"true\"") {
            return None;
        }
        let rest = params.split_once("cursor=\"")?.1;
        Some(rest.split('"').next()?.to_string())
    })
}

struct Fetched {
    items: Vec<WorkItem>,
    /// A search had more issues than [`MAX_ISSUES_PER_QUERY`].
    truncated: bool,
}

/// Every page of every search, or an error: a failure part-way never yields a
/// partial list.
async fn fetch_issues(
    api: &Api<'_>,
    org: &str,
    repos: &HashMap<String, String>,
    hold: &mut Option<DateTime<Utc>>,
) -> Result<Fetched, ApiError> {
    let path = format!("/organizations/{org}/issues/");
    let mut seen = HashSet::new();
    let mut items = Vec::new();
    let mut truncated = false;
    for search in &SEARCHES {
        let mut cursor: Option<String> = None;
        let mut count = 0usize;
        let mut parsed = 0usize;
        loop {
            // Out of quota (`remaining` 0): do not ask for more until the reset.
            if let Some(reset) = hold.filter(|t| *t > (api.clock)()) {
                return Err(ApiError::RateLimited { retry_at: reset });
            }
            let mut params = vec![
                ("project", "-1".to_string()),
                ("statsPeriod", search.stats_period.to_string()),
                ("groupStatsPeriod", "24h".to_string()),
                ("limit", PAGE_LIMIT.to_string()),
                ("query", search.query.to_string()),
            ];
            if let Some(c) = &cursor {
                params.push(("cursor", c.clone()));
            }
            let (body, headers) = api.get(&path, &params, hold).await?;
            let page = body.as_array().ok_or(ApiError::Malformed)?;
            for issue in page {
                if count >= MAX_ISSUES_PER_QUERY {
                    truncated = true;
                    break;
                }
                count += 1;
                if let Some(item) = to_item(issue, repos) {
                    parsed += 1;
                    if seen.insert(item.id.clone()) {
                        items.push(item);
                    }
                }
            }
            // A page of things that are not issues is a broken response, not "no issues".
            if !page.is_empty() && parsed == 0 {
                return Err(ApiError::Malformed);
            }
            cursor = next_cursor(&headers);
            if cursor.is_none() || page.is_empty() {
                break;
            }
            if count >= MAX_ISSUES_PER_QUERY {
                truncated = true;
                break;
            }
        }
    }
    Ok(Fetched { items, truncated })
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

/// The environment a latest event ran in: the `environment` entry of its
/// `tags` (`[{"key": "environment", "value": "prod"}]`). The issue payloads
/// carry no environment.
fn event_environment(event: &Value) -> Option<String> {
    event["tags"]
        .as_array()?
        .iter()
        .find(|t| t["key"].as_str() == Some("environment"))
        .and_then(|t| text(&t["value"]))
}

/// A Sentry-hosted `https` link, else nothing: a link from a payload is only
/// shown when it points at Sentry.
fn sentry_link(v: &Value) -> Option<String> {
    https_link(v.as_str()?, is_sentry_host)
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
    let title = one_line(&text(&issue["title"]).unwrap_or_else(|| "(untitled issue)".into()), MAX_LINE_CHARS);
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
        environment: None,
        created_at: timestamp(&issue["firstSeen"]),
        updated_at: timestamp(&issue["lastSeen"]),
        due: None,
        url: sentry_link(&issue["permalink"]),
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
    if let Some(reason) = config.config_error() {
        return Err(WorkError::new("not_configured", reason));
    }
    let token = lookup_token(&config.env_file)
        .await
        .ok_or_else(|| WorkError::new("not_configured", NOT_CONFIGURED_REASON))?;
    let client = http_client().ok_or_else(|| WorkError::new("error", "Couldn't start the Sentry client"))?;
    let api = Api { client: &client, base: &config.base_url, token: &token, clock: &config.clock };
    let mut hold = None;

    let issue_path = format!("/organizations/{}/issues/{id}/", config.org);
    let (issue, _) = api.get(&issue_path, &[], &mut hold).await.map_err(|e| detail_error(&e))?;
    // Anything that is not this issue (an error-shaped 200, another issue) is not shown as one.
    if text(&issue["id"]).or_else(|| number(&issue["id"]).map(|n| n.to_string())).as_deref() != Some(id) {
        return Err(detail_error(&ApiError::Malformed));
    }
    // The latest event only adds the stack and environment: the issue is still
    // worth showing without it, but the reader is told why the stack is missing.
    let event = match api.get(&format!("{issue_path}events/latest/"), &[], &mut hold).await {
        Ok((event, _)) => Ok(event),
        Err(rejected @ (ApiError::Unauthenticated | ApiError::Forbidden)) => return Err(detail_error(&rejected)),
        Err(other) => Err(other.describe()),
    };
    Ok(build_detail(item_id, &issue, event.as_ref().map_err(String::as_str)))
}

fn detail_error(e: &ApiError) -> WorkError {
    match e {
        ApiError::NotFound => WorkError::new("unknown_item", "That Sentry issue no longer exists"),
        ApiError::Unauthenticated => WorkError::new(
            "unauthenticated",
            "Sentry rejected the token. Check SENTRY_API_TOKEN in ~/.claude/credentials/.env.",
        ),
        ApiError::Forbidden => WorkError::new("unauthenticated", MISSING_PERMISSION_REASON),
        ApiError::RateLimited { .. } => {
            WorkError::new("rate_limited", "Sentry is rate-limiting requests; try again shortly")
        }
        other => WorkError::new("error", format!("Couldn't load the Sentry issue ({})", other.describe())),
    }
}

/// `event` is the latest event, or why there is none to show. A stack that
/// cannot be shown is said in its own `Stack` field, never in `markdown`, which
/// holds frames only (so a reason cannot pass for one).
fn build_detail(item_id: &str, issue: &Value, event: Result<&Value, &str>) -> WorkDetail {
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
    if let Some(env) = event.ok().and_then(event_environment) {
        fields.push(("Environment".into(), env));
    }
    if let Some(level) = text(&issue["level"]) {
        fields.push(("Level".into(), level));
    }
    let assignee = text(&issue["assignedTo"]["name"]).unwrap_or_else(|| "Unassigned".into());
    fields.push(("Assignee".into(), assignee));
    if let Some(culprit) = text(&issue["culprit"]) {
        fields.push(("Culprit".into(), culprit));
    }

    let stack = match event {
        Ok(event) => stack_markdown(event).ok_or("no exception data"),
        Err(why) => Err(why),
    };
    let markdown = match stack {
        Ok(frames) => frames,
        Err(why) => {
            fields.push(("Stack".into(), format!("unavailable ({why})")));
            String::new()
        }
    };

    let links = sentry_link(&issue["permalink"])
        .map(|url| vec![Link { label: "Open in Sentry".into(), url }])
        .unwrap_or_default();
    WorkDetail {
        item_id: item_id.to_string(),
        title: one_line(&text(&issue["title"]).unwrap_or_else(|| "(untitled issue)".into()), MAX_LINE_CHARS),
        fields,
        markdown,
        files: Vec::new(),
        links,
    }
}

/// The top (innermost) frames of the first exception, one per line:
/// `● file:line in function`, in-app frames marked. `None` when the event has
/// no exception with frames.
fn stack_markdown(event: &Value) -> Option<String> {
    let frames = event["entries"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|e| e["type"].as_str() == Some("exception"))
        .flat_map(|e| e["data"]["values"].as_array().into_iter().flatten())
        .find_map(|v| v["stacktrace"]["frames"].as_array());
    let frames = frames.filter(|f| !f.is_empty())?;
    // Sentry lists frames oldest first: the top of the stack is the end.
    let lines = frames
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
        .join("\n");
    Some(lines)
}
