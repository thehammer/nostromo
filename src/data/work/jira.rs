//! Jira work source: the user's unresolved assigned issues, for Teri's Jira tab.
//!
//! `JiraWorkSource` polls `assignee = currentUser() AND statusCategory != Done`
//! across all projects (every 120 s, and at once on a manual refresh that
//! passed the hub's debounce) and publishes honest states:
//!
//! - no credentials          -> `not_configured` (names the variables)
//! - invalid site name       -> `not_configured` (names `ATLASSIAN_SITE_NAME`, never its value)
//! - HTTP 401 / 403          -> `unauthenticated` (names the variable, never a value)
//! - HTTP 429                -> `rate_limited` with `retry_at`; the last items stay
//! - network error / 5xx /
//!   a body that is not an
//!   issue list              -> `stale` while there is previous data, else `error`
//! - more than 500 issues, or
//!   issues that could not be
//!   read                    -> `fresh` with the note as `reason` (an informational
//!   banner, no Retry: refetching would return the same capped list) and
//!   `complete: false`
//! - healthy, no issues      -> `empty`
//!
//! `complete` is true only for a healthy list known to be whole (no cut, nothing
//! unreadable). A consumer that treats an item's absence as "done" must require it.
//!
//! Where the credential goes: the site is validated once, in [`JiraWorkSource::credentials`]
//! ([`validate_site`]): `<name>.atlassian.net` or a bare `<name>`. Anything else is
//! "not configured" and no request is made. Redirects are never followed, and
//! every link is rebuilt from the validated host.
//!
//! Holds: a 429's `Retry-After` (clamped to 15 minutes) is honoured, so a manual
//! refresh does not break it (only a changed `.env` does). A 401/403 is held for
//! the 15-minute cap and ends on a changed `.env` or an explicit refresh. Note a
//! 403 is not always "bad token": it can be a missing permission or a CAPTCHA /
//! login challenge, and the state's wording says so. A hold earned by `detail()`
//! binds the poller too: the next poll publishes the matching state without a request.
//!
//! Credentials are re-resolved on every fetch, and a change of the `.env`
//! file's mtime triggers a fetch, so fixing a token recovers without a daemon
//! restart. Secrets are never logged, put in a status or a detail, or echoed in
//! an error: problems are reported by variable *name* and HTTP status only.
//!
//! Never run against real Jira yet: the payload shapes, `nextPageToken` / `isLast`
//! paging, `Retry-After` format and ADF output are modelled on Atlassian's docs
//! and exercised against a mock only.
//!
//! Without a source handed to the hub (`HubDeps::jira == None`, i.e. tests that
//! do not exercise Jira) [`spawn`] publishes the dormant "Coming soon"
//! placeholder, so no test ever reaches a real Jira.

use std::collections::hash_map::DefaultHasher;
use std::collections::HashMap;
use std::hash::{Hash, Hasher};
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
use super::sentry::Clock;
use super::untrusted::{one_line, MAX_LINE_CHARS};
use crate::config::Config;
use crate::data::tickets::jira::adf_to_blocks;
use crate::ipc::protocol::{MdBlock, MdSpan};

const ENV_SITE: &str = "ATLASSIAN_SITE_NAME";
const ENV_EMAIL: &str = "ATLASSIAN_USER_EMAIL";
const ENV_TOKEN: &str = "ATLASSIAN_API_TOKEN";

pub const JQL: &str = "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC";
const LIST_FIELDS: [&str; 8] = [
    "summary",
    "status",
    "priority",
    "updated",
    "created",
    "project",
    "issuetype",
    "duedate",
];
const PAGE_SIZE: usize = 100;
const MAX_ISSUES: usize = 500;
/// Safety stop for a server that keeps promising pages while returning few issues.
const MAX_PAGES: usize = 25;
const POLL_INTERVAL: Duration = Duration::from_secs(120);
const BACKOFF_BASE: Duration = Duration::from_secs(2);
const BACKOFF_CAP: Duration = Duration::from_secs(15 * 60);
const ENV_WATCH_INTERVAL: Duration = Duration::from_secs(5);
/// No hold (Retry-After, auth failure) is ever longer than this.
const MAX_HOLD: Duration = BACKOFF_CAP;
/// Upper bound on any single sleep, so the deadline arithmetic cannot overflow.
const MAX_WAIT: Duration = Duration::from_secs(24 * 60 * 60);
const DETAIL_TTL: Duration = Duration::from_secs(60);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_DESCRIPTION_CHARS: usize = 20_000;
const MAX_COMMENT_CHARS: usize = 5_000;

/// Shown when the credentials are missing (the tab prefixes "Jira: ").
pub const NOT_CONFIGURED_REASON: &str = "no credentials found. Set ATLASSIAN_SITE_NAME, \
ATLASSIAN_USER_EMAIL and ATLASSIAN_API_TOKEN in ~/.claude/credentials/.env, as the agents use.";

/// Shown when the site name is not a valid Atlassian site (the tab prefixes "Jira: ").
/// Names the setting, never its value.
pub const INVALID_SITE_REASON: &str =
    "ATLASSIAN_SITE_NAME (or jira_site in the daemon config) is not \
a valid Atlassian site name such as your-team.atlassian.net. Nothing was sent to Jira.";

/// Start the dormant placeholder (used when the hub is not given a real source).
pub fn spawn(_refresh: Arc<Notify>) -> watch::Receiver<SourceUpdate> {
    let status = status(
        SourceState::NotConfigured,
        Some("Coming soon".into()),
        None,
        None,
        0,
    );
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
        // Callers that know the list is whole say so (see `poll`).
        complete: false,
    }
}

struct Credentials {
    /// Validated: `<label>.atlassian.net`.
    site: String,
    email: String,
    token: String,
}

impl Credentials {
    /// Changes whenever any part changes. Never shown or logged.
    fn fingerprint(&self) -> u64 {
        let mut hasher = DefaultHasher::new();
        (&self.site, &self.email, &self.token).hash(&mut hasher);
        hasher.finish()
    }
}

/// Why no request can be made.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CredentialsProblem {
    Missing,
    InvalidSite,
}

impl CredentialsProblem {
    fn reason(self) -> &'static str {
        match self {
            Self::Missing => NOT_CONFIGURED_REASON,
            Self::InvalidSite => INVALID_SITE_REASON,
        }
    }
}

/// What may end a wait early.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Wake {
    /// A manual refresh or a changed credentials file.
    RefreshOrCredentials,
    /// Only a changed credentials file: a server-imposed `Retry-After` hold.
    CredentialsOnly,
}

/// What a pause was imposed for.
#[derive(Debug, Clone, Copy)]
enum HoldKind {
    RateLimited,
    Rejected(u16),
}

/// A pause on credentialed requests, shared by the poller and `detail` so that
/// clicking through issues cannot hammer a Jira that said to back off. It only
/// applies to the credentials it was earned with.
struct Hold {
    until: Instant,
    credentials: u64,
    kind: HoldKind,
}

/// What the poller looked at before a fetch: a wait ends early only when the
/// credentials file changed AND the credentials it yields are different.
#[derive(Debug, Clone, PartialEq)]
struct Seen {
    mtime: Option<SystemTime>,
    credentials: Result<u64, CredentialsProblem>,
}

/// A successful fetch.
struct Fetched {
    items: Vec<WorkItem>,
    /// Set when the list is incomplete (cut at the cap, or issues unreadable).
    note: Option<String>,
}

/// The poller's memory between fetches.
#[derive(Default)]
struct PollState {
    items: Vec<WorkItem>,
    last_good: Option<DateTime<Utc>>,
    failures: u32,
}

#[derive(Default)]
struct DetailCache {
    /// Fingerprint of the credentials the entries were fetched with.
    credentials: u64,
    entries: HashMap<String, (Instant, WorkDetail)>,
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
    #[cfg(any(test, feature = "test-support"))]
    base_url: Option<String>,
    file_only: bool,
    poll_interval: Duration,
    env_watch_interval: Duration,
    backoff_base: Duration,
    http: reqwest::Client,
    detail_cache: Mutex<DetailCache>,
    hold: Mutex<Option<Hold>>,
    /// What "now" is for `updated_at`, `retry_at` and a `Retry-After` date.
    clock: Clock,
}

impl JiraWorkSource {
    /// A source reading credentials from the environment, then `env_path`.
    pub fn new(env_path: impl Into<PathBuf>) -> Self {
        Self {
            env: EnvFile::new(env_path),
            config_site: None,
            config_email: None,
            #[cfg(any(test, feature = "test-support"))]
            base_url: None,
            file_only: false,
            poll_interval: POLL_INTERVAL,
            env_watch_interval: ENV_WATCH_INTERVAL,
            backoff_base: BACKOFF_BASE,
            // Never follow a redirect: the credential must only reach the validated host.
            // (No `unwrap_or_default`: a default client would follow redirects.)
            http: reqwest::Client::builder()
                .timeout(REQUEST_TIMEOUT)
                .redirect(reqwest::redirect::Policy::none())
                .build()
                .expect("build the Jira HTTP client"),
            detail_cache: Mutex::new(DetailCache::default()),
            hold: Mutex::new(None),
            clock: Arc::new(Utc::now),
        }
    }

    /// From the daemon config (`jira_site`, `jira_email`, `jira_credentials_path`).
    pub fn from_config(config: &Config) -> Self {
        let mut source = Self::new(
            config
                .jira_credentials_path
                .clone()
                .unwrap_or_else(default_env_path),
        );
        source.config_site = config.jira_site.clone().filter(|s| !s.is_empty());
        source.config_email = config.jira_email.clone().filter(|s| !s.is_empty());
        source
    }

    /// Send requests to `base_url` instead of `https://<site>`. Test-only: the
    /// production build cannot route credentialed requests to an arbitrary base.
    #[cfg(any(test, feature = "test-support"))]
    pub fn with_base_url(mut self, base_url: impl Into<String>) -> Self {
        self.base_url = Some(base_url.into().trim_end_matches('/').to_string());
        self
    }

    /// Poll every `interval` instead of every 120 s (tests).
    pub fn with_poll_interval(mut self, interval: Duration) -> Self {
        self.poll_interval = interval;
        self
    }

    /// Look for a changed `.env` file every `interval` instead of every 5 s (tests).
    pub fn with_env_watch_interval(mut self, interval: Duration) -> Self {
        self.env_watch_interval = interval;
        self
    }

    /// First error back-off (doubles per failure, capped at 15 min; tests).
    pub fn with_backoff_base(mut self, base: Duration) -> Self {
        self.backoff_base = base;
        self
    }

    /// Read "now" from `clock` instead of the system clock (tests).
    pub fn with_clock(mut self, clock: Clock) -> Self {
        self.clock = clock;
        self
    }

    fn now(&self) -> DateTime<Utc> {
        (self.clock)()
    }

    /// Ignore the process environment: only the `.env` file counts (tests).
    pub fn file_credentials_only(mut self) -> Self {
        self.file_only = true;
        self
    }

    /// Start polling. `refresh` is poked by a manual refresh that passed the
    /// hub's debounce; the source then fetches immediately.
    pub fn spawn(self: Arc<Self>, refresh: Arc<Notify>) -> watch::Receiver<SourceUpdate> {
        let (tx, rx) = watch::channel((
            status(SourceState::Loading, None, None, None, 0),
            Vec::new(),
        ));
        tokio::spawn(async move { self.run(tx, refresh).await });
        rx
    }

    /// Detail for `jira:<KEY>`: fields, ADF description and the 5 newest comments.
    pub async fn detail(&self, item_id: &str) -> Result<WorkDetail, WorkError> {
        let key = item_id
            .strip_prefix("jira:")
            .filter(|k| valid_key(k))
            .ok_or_else(|| WorkError::new("unknown_item", "That is not a Jira issue key"))?;
        let creds = self.credentials().map_err(|problem| {
            WorkError::new("not_configured", format!("Jira: {}", problem.reason()))
        })?;
        let fingerprint = creds.fingerprint();
        {
            let mut cache = self.detail_cache.lock().unwrap();
            if cache.credentials != fingerprint {
                // The credentials changed: nothing fetched with the old ones is shown.
                cache.entries.clear();
                cache.credentials = fingerprint;
            }
            if let Some((at, cached)) = cache.entries.get(item_id) {
                if at.elapsed() < DETAIL_TTL {
                    return Ok(cached.clone());
                }
            }
        }
        if let Some(refused) = self.hold_error(fingerprint) {
            return Err(refused);
        }
        let (detail, cacheable) =
            self.fetch_detail(&creds, key, item_id)
                .await
                .map_err(|e| match e {
                    FetchError::Rejected(code) => {
                        self.set_hold(fingerprint, HoldKind::Rejected(code), MAX_HOLD);
                        WorkError::new("unauthenticated", rejected_reason(code))
                    }
                    FetchError::RateLimited(retry_after) => {
                        self.set_hold(
                            fingerprint,
                            HoldKind::RateLimited,
                            retry_after.unwrap_or_else(|| self.backoff(1)),
                        );
                        WorkError::new("rate_limited", "Jira is rate-limiting requests")
                    }
                    FetchError::Failed(why) => {
                        WorkError::new("fetch_failed", format!("Couldn't load {key}: {why}"))
                    }
                })?;
        if cacheable {
            let mut cache = self.detail_cache.lock().unwrap();
            if cache.credentials == fingerprint {
                cache.entries.retain(|_, (at, _)| at.elapsed() < DETAIL_TTL);
                cache
                    .entries
                    .insert(item_id.to_string(), (Instant::now(), detail.clone()));
            }
        }
        Ok(detail)
    }

    // ── polling ───────────────────────────────────────────────────────────

    async fn run(self: Arc<Self>, tx: watch::Sender<SourceUpdate>, refresh: Arc<Notify>) {
        let mut state = PollState::default();
        loop {
            let seen = self.seen();
            let (update, delay, wake) = self.poll(&mut state).await;
            if tx.send(update).is_err() {
                return; // the hub is gone
            }
            self.wait(delay, wake, &refresh, &seen).await;
        }
    }

    /// One fetch and the status it earns, with how long to wait before the next.
    async fn poll(&self, st: &mut PollState) -> (SourceUpdate, Duration, Wake) {
        let creds = match self.credentials() {
            Ok(creds) => creds,
            Err(problem) => {
                st.items.clear();
                let update = (
                    status(
                        SourceState::NotConfigured,
                        Some(problem.reason().into()),
                        None,
                        None,
                        0,
                    ),
                    Vec::new(),
                );
                return (update, self.poll_interval, Wake::RefreshOrCredentials);
            }
        };
        // A hold `detail()` earned (429, 401/403) binds the poller too: no request until it ends.
        if let Some((kind, remaining)) = self.active_hold(creds.fingerprint()) {
            return self.held(st, kind, remaining);
        }
        match self.fetch_all(&creds).await {
            Ok(fetched) => {
                st.failures = 0;
                self.clear_hold();
                st.items = fetched.items;
                let now = self.now();
                st.last_good = Some(now);
                // A cut or partly unreadable list is a note on a fresh list, not a failure.
                let state = if st.items.is_empty() {
                    SourceState::Empty
                } else {
                    SourceState::Fresh
                };
                // `complete` only when nothing was cut at the cap or unreadable (that is what the note says).
                let complete = fetched.note.is_none();
                let update = (
                    SourceStatus {
                        complete,
                        ..status(state, fetched.note, Some(now), None, st.items.len())
                    },
                    vec![(None, st.items.clone())],
                );
                (update, self.poll_interval, Wake::RefreshOrCredentials)
            }
            Err(FetchError::Rejected(code)) => {
                st.failures += 1;
                st.items.clear();
                warn!("jira work source: credentials rejected ({code})");
                self.set_hold(creds.fingerprint(), HoldKind::Rejected(code), MAX_HOLD);
                let update = (
                    status(
                        SourceState::Unauthenticated,
                        Some(rejected_reason(code)),
                        None,
                        None,
                        0,
                    ),
                    Vec::new(),
                );
                // A bad token will not fix itself: hold until the file changes or the user asks.
                (update, MAX_HOLD, Wake::RefreshOrCredentials)
            }
            Err(FetchError::RateLimited(retry_after)) => {
                st.failures += 1;
                let hold = retry_after
                    .unwrap_or_else(|| self.backoff(st.failures))
                    .min(MAX_HOLD);
                warn!(
                    "jira work source: rate limited, holding for {}s",
                    hold.as_secs()
                );
                self.set_hold(creds.fingerprint(), HoldKind::RateLimited, hold);
                let update = (
                    status(
                        SourceState::RateLimited,
                        None,
                        st.last_good,
                        retry_at(hold, self.now()),
                        st.items.len(),
                    ),
                    vec![(None, st.items.clone())],
                );
                (update, hold, Wake::CredentialsOnly)
            }
            Err(FetchError::Failed(why)) => {
                st.failures += 1;
                warn!("jira work source: fetch failed: {why}");
                let update = if st.items.is_empty() {
                    (
                        status(
                            SourceState::Error,
                            Some(format!("couldn't reach Jira ({why})")),
                            None,
                            None,
                            0,
                        ),
                        Vec::new(),
                    )
                } else {
                    (
                        status(
                            SourceState::Stale,
                            Some(format!(
                                "couldn't reach Jira ({why}); showing the last good list"
                            )),
                            st.last_good,
                            None,
                            st.items.len(),
                        ),
                        vec![(None, st.items.clone())],
                    )
                };
                (
                    update,
                    self.backoff(st.failures),
                    Wake::RefreshOrCredentials,
                )
            }
        }
    }

    /// What the poller publishes, without a request, while a hold is running.
    fn held(
        &self,
        st: &mut PollState,
        kind: HoldKind,
        remaining: Duration,
    ) -> (SourceUpdate, Duration, Wake) {
        match kind {
            HoldKind::RateLimited => (
                (
                    status(
                        SourceState::RateLimited,
                        None,
                        st.last_good,
                        retry_at(remaining, self.now()),
                        st.items.len(),
                    ),
                    vec![(None, st.items.clone())],
                ),
                remaining,
                Wake::CredentialsOnly,
            ),
            HoldKind::Rejected(code) => {
                st.items.clear();
                (
                    (
                        status(
                            SourceState::Unauthenticated,
                            Some(rejected_reason(code)),
                            None,
                            None,
                            0,
                        ),
                        Vec::new(),
                    ),
                    remaining,
                    Wake::RefreshOrCredentials,
                )
            }
        }
    }

    /// Sleep for `delay`. Changed credentials always end the wait early (merely
    /// touching the file does not); a manual refresh only does when `wake`
    /// allows it. A refresh that arrives during a hold is consumed, not saved.
    async fn wait(&self, delay: Duration, wake: Wake, refresh: &Notify, seen: &Seen) {
        let deadline = tokio::time::Instant::now() + delay.min(MAX_WAIT);
        let tick = self.env_watch_interval.max(Duration::from_millis(10));
        let mut env_check = tokio::time::interval_at(tokio::time::Instant::now() + tick, tick);
        env_check.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            tokio::select! {
                _ = refresh.notified() => {
                    if wake == Wake::RefreshOrCredentials {
                        // An explicit refresh ends a 401/403 hold (a 429 hold is never cut short).
                        self.clear_rejected_hold();
                        return;
                    }
                }
                _ = tokio::time::sleep_until(deadline) => return,
                _ = env_check.tick() => {
                    if self.env.mtime() != seen.mtime && self.seen().credentials != seen.credentials {
                        return;
                    }
                }
            }
        }
    }

    fn seen(&self) -> Seen {
        Seen {
            mtime: self.env.mtime(),
            credentials: self.credentials().map(|c| c.fingerprint()),
        }
    }

    fn set_hold(&self, credentials: u64, kind: HoldKind, duration: Duration) {
        let until = Instant::now() + duration.min(MAX_HOLD);
        *self.hold.lock().unwrap() = Some(Hold {
            until,
            credentials,
            kind,
        });
    }

    fn clear_hold(&self) {
        *self.hold.lock().unwrap() = None;
    }

    fn clear_rejected_hold(&self) {
        let mut guard = self.hold.lock().unwrap();
        if guard
            .as_ref()
            .is_some_and(|h| matches!(h.kind, HoldKind::Rejected(_)))
        {
            *guard = None;
        }
    }

    /// The hold earned with these credentials that is still running, and how long it has left.
    fn active_hold(&self, credentials: u64) -> Option<(HoldKind, Duration)> {
        let guard = self.hold.lock().unwrap();
        let hold = guard.as_ref().filter(|h| h.credentials == credentials)?;
        let remaining = hold
            .until
            .checked_duration_since(Instant::now())
            .filter(|d| !d.is_zero())?;
        Some((hold.kind, remaining))
    }

    /// The refusal `detail` gives, without a request, while a hold earned with
    /// these credentials is running.
    fn hold_error(&self, credentials: u64) -> Option<WorkError> {
        let (kind, _) = self.active_hold(credentials)?;
        Some(match kind {
            HoldKind::RateLimited => {
                WorkError::new("rate_limited", "Jira is rate-limiting requests")
            }
            HoldKind::Rejected(code) => WorkError::new("unauthenticated", rejected_reason(code)),
        })
    }

    fn backoff(&self, failures: u32) -> Duration {
        let factor = 2u32.saturating_pow(failures.saturating_sub(1).min(20));
        self.backoff_base.saturating_mul(factor).min(BACKOFF_CAP)
    }

    // ── credentials ───────────────────────────────────────────────────────

    /// Config override, then process environment, then the `.env` file; blank is
    /// absent. The site is validated here, once: nothing downstream (requests,
    /// links) ever sees an unvalidated host.
    fn credentials(&self) -> Result<Credentials, CredentialsProblem> {
        let var = |name: &str| {
            if self.file_only {
                self.env.file_value(name)
            } else {
                self.env.lookup(name)
            }
        };
        let present = |v: Option<String>| v.filter(|s| !s.trim().is_empty());
        let site = present(self.config_site.clone().or_else(|| var(ENV_SITE)));
        let email = present(self.config_email.clone().or_else(|| var(ENV_EMAIL)));
        let token = present(var(ENV_TOKEN));
        let (Some(site), Some(email), Some(token)) = (site, email, token) else {
            return Err(CredentialsProblem::Missing);
        };
        let site = validate_site(&site).ok_or(CredentialsProblem::InvalidSite)?;
        Ok(Credentials { site, email, token })
    }

    fn base(&self, creds: &Credentials) -> String {
        #[cfg(any(test, feature = "test-support"))]
        if let Some(base) = &self.base_url {
            return base.clone();
        }
        format!("https://{}", creds.site)
    }

    // ── fetching ──────────────────────────────────────────────────────────

    async fn fetch_all(&self, creds: &Credentials) -> Result<Fetched, FetchError> {
        match self.fetch_via_search_jql(creds).await {
            Err(FetchError::Failed(why)) if why == ENDPOINT_GONE => {
                self.fetch_via_legacy_search(creds).await
            }
            other => other,
        }
    }

    /// `POST /search/jql`, following `nextPageToken`. Any page that is not an
    /// issue list, or that is empty while more were promised, fails the whole
    /// fetch: a partial list is never published as complete.
    async fn fetch_via_search_jql(&self, creds: &Credentials) -> Result<Fetched, FetchError> {
        let url = format!("{}/rest/api/3/search/jql", self.base(creds));
        let mut collected = Collected::new(&creds.site);
        let mut token: Option<String> = None;
        for _ in 0..MAX_PAGES {
            let mut body = json!({
                "jql": JQL, "fields": LIST_FIELDS, "maxResults": PAGE_SIZE,
            });
            if let Some(t) = &token {
                body["nextPageToken"] = json!(t);
            }
            let req = self
                .http
                .post(&url)
                .basic_auth(&creds.email, Some(&creds.token))
                .json(&body);
            let page = self.send_json(req, true).await?;
            let issues = issues_of(&page)?;
            let next = page
                .get("nextPageToken")
                .and_then(Value::as_str)
                .filter(|t| !t.is_empty());
            if issues.is_empty() && (token.is_some() || next.is_some()) {
                // We asked for a promised page (or it promises another) and got nothing.
                return Err(FetchError::Failed(
                    "an empty page while more were promised".into(),
                ));
            }
            collected.add(issues);
            match (next, page.get("isLast").and_then(Value::as_bool)) {
                (_, Some(true)) | (None, None) => return collected.finish(false),
                (None, Some(false)) => return Err(FetchError::Failed("paging was cut off".into())),
                (Some(_), _) if collected.is_full() => return collected.finish(true),
                (Some(next), _) => token = Some(next.to_string()),
            }
        }
        collected.finish(true)
    }

    /// `GET /search` with `startAt`, for sites that removed `search/jql`.
    async fn fetch_via_legacy_search(&self, creds: &Credentials) -> Result<Fetched, FetchError> {
        let url = format!("{}/rest/api/3/search", self.base(creds));
        let fields = LIST_FIELDS.join(",");
        let mut collected = Collected::new(&creds.site);
        let mut start = 0usize;
        for _ in 0..MAX_PAGES {
            let req = self
                .http
                .get(&url)
                .basic_auth(&creds.email, Some(&creds.token))
                .query(&[("jql", JQL), ("fields", fields.as_str())])
                .query(&[("startAt", start), ("maxResults", PAGE_SIZE)]);
            let page = self.send_json(req, false).await?;
            let issues = issues_of(&page)?;
            let total = page
                .get("total")
                .and_then(Value::as_u64)
                .ok_or_else(|| FetchError::Failed("unexpected response".into()))?
                as usize;
            collected.add(issues);
            start += issues.len();
            if start >= total {
                return collected.finish(false);
            }
            if issues.is_empty() {
                return Err(FetchError::Failed(
                    "an empty page before the total was reached".into(),
                ));
            }
            if collected.is_full() {
                return collected.finish(true);
            }
        }
        collected.finish(true)
    }

    /// The detail, and whether it is complete enough to cache.
    async fn fetch_detail(
        &self,
        creds: &Credentials,
        key: &str,
        item_id: &str,
    ) -> Result<(WorkDetail, bool), FetchError> {
        let base = self.base(creds);
        let issue_req = self
            .http
            .get(format!("{base}/rest/api/3/issue/{key}"))
            .basic_auth(&creds.email, Some(&creds.token))
            .query(&[(
                "fields",
                "summary,status,priority,assignee,description,duedate,updated",
            )]);
        let issue = self.send_json(issue_req, false).await?;
        if issue.get("errorMessages").is_some()
            || !issue.get("fields").is_some_and(Value::is_object)
        {
            return Err(FetchError::Failed("unexpected response".into()));
        }
        let comments_req = self
            .http
            .get(format!("{base}/rest/api/3/issue/{key}/comment"))
            .basic_auth(&creds.email, Some(&creds.token))
            .query(&[("orderBy", "-created"), ("maxResults", "5")]);
        // Comments are a nicety (the issue still shows without them), but a
        // failure is said out loud: it must not read as "no comments".
        let comments: Result<Vec<Value>, String> = match self.send_json(comments_req, false).await {
            Ok(body) => body
                .get("comments")
                .and_then(Value::as_array)
                .cloned()
                .ok_or_else(|| "unexpected response".to_string()),
            Err(FetchError::Rejected(code)) => Err(format!("HTTP {code}")),
            Err(FetchError::RateLimited(_)) => Err("HTTP 429".to_string()),
            Err(FetchError::Failed(why)) => Err(why),
        };

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
            (
                "Status".to_string(),
                text(&f, &["status", "name"]).unwrap_or_default(),
            ),
            (
                "Priority".to_string(),
                text(&f, &["priority", "name"]).unwrap_or_default(),
            ),
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

        let mut markdown = cap_text(
            blocks_to_markdown(&adf_to_blocks(f.get("description").unwrap_or(&Value::Null))),
            MAX_DESCRIPTION_CHARS,
        );
        let comments_section = match &comments {
            Ok(recent) if recent.is_empty() => None,
            Ok(recent) => {
                let mut section = String::from("## Recent comments\n");
                for c in recent.iter().take(5) {
                    let author =
                        text(c, &["author", "displayName"]).unwrap_or_else(|| "Unknown".into());
                    let when = text(c, &["created"]).unwrap_or_default();
                    let body = cap_text(
                        blocks_to_markdown(&adf_to_blocks(c.get("body").unwrap_or(&Value::Null))),
                        MAX_COMMENT_CHARS,
                    );
                    section.push_str(&format!("\n### {author} · {when}\n\n{body}\n"));
                }
                Some(section)
            }
            Err(why) => Some(format!(
                "## Recent comments\n\n_Comments unavailable ({why})._\n"
            )),
        };
        if let Some(section) = comments_section {
            if !markdown.is_empty() {
                markdown.push_str("\n\n");
            }
            markdown.push_str(&section);
        }
        let detail = WorkDetail {
            item_id: item_id.to_string(),
            title: one_line(&format!("{key} {summary}"), MAX_LINE_CHARS),
            fields,
            markdown,
            files: Vec::new(),
            links: browse_url(&creds.site, key)
                .map(|url| Link {
                    label: format!("Open {key} in Jira"),
                    url,
                })
                .into_iter()
                .collect(),
        };
        Ok((detail, comments.is_ok()))
    }

    /// Send and decode one JSON response, classifying failures. With
    /// `gone_is_endpoint_missing`, 404/410 means "this endpoint doesn't exist here".
    /// Redirects are never followed (the client's policy), so a 3xx is a failure.
    async fn send_json(
        &self,
        req: reqwest::RequestBuilder,
        gone_is_endpoint_missing: bool,
    ) -> Result<Value, FetchError> {
        let resp = req
            .send()
            .await
            .map_err(|e| FetchError::Failed(describe_transport_error(&e)))?;
        let status = resp.status();
        match status.as_u16() {
            401 | 403 => return Err(FetchError::Rejected(status.as_u16())),
            429 => {
                let retry = resp
                    .headers()
                    .get(reqwest::header::RETRY_AFTER)
                    .and_then(|v| v.to_str().ok())
                    .and_then(|raw| parse_retry_after(raw, self.now()));
                return Err(FetchError::RateLimited(retry));
            }
            404 | 410 if gone_is_endpoint_missing => {
                return Err(FetchError::Failed(ENDPOINT_GONE.into()))
            }
            _ => {}
        }
        if !status.is_success() {
            return Err(FetchError::Failed(format!("HTTP {}", status.as_u16())));
        }
        resp.json::<Value>()
            .await
            .map_err(|_| FetchError::Failed("unreadable response".into()))
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

/// What the tab says for a 401 / 403. A 403 is not always "bad token": it can be
/// a missing permission or a CAPTCHA / login challenge. Names variables, never values.
fn rejected_reason(code: u16) -> String {
    if code == 403 {
        format!(
            "Jira refused the request (403). The token may lack permission, or Jira may be asking for \
             a login or CAPTCHA. Check {ENV_TOKEN} in ~/.claude/credentials/.env and sign in to Jira in a browser."
        )
    } else {
        format!(
            "Jira rejected the credentials ({code}). Check {ENV_EMAIL} and {ENV_TOKEN} in ~/.claude/credentials/.env."
        )
    }
}

/// The validated Atlassian host for a configured site, or `None`.
///
/// Accepts `<label>` (expanded to `<label>.atlassian.net`) and
/// `<label>.atlassian.net`, where a label is 1-63 of `[a-z0-9-]` not starting
/// or ending with `-`. One leading `https://` and one trailing `/` are
/// forgiven, case is folded. Everything else (other hosts, userinfo, ports,
/// paths, spaces, non-ASCII) is refused, because the API token is sent to this host.
fn validate_site(raw: &str) -> Option<String> {
    let lowered = raw.trim().to_ascii_lowercase();
    let site = lowered.strip_prefix("https://").unwrap_or(&lowered);
    let site = site.strip_suffix('/').unwrap_or(site);
    let label = site.strip_suffix(".atlassian.net").unwrap_or(site);
    let valid = !label.is_empty()
        && label.len() <= 63
        && !label.starts_with('-')
        && !label.ends_with('-')
        && label
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-');
    valid.then(|| format!("{label}.atlassian.net"))
}

/// `Retry-After`: delta seconds or an HTTP date, clamped to 1 s ..= [`MAX_HOLD`].
/// `None` for anything unusable (negative, garbage), so the caller backs off instead.
fn parse_retry_after(raw: &str, now: DateTime<Utc>) -> Option<Duration> {
    let raw = raw.trim();
    let cap = MAX_HOLD.as_secs();
    if !raw.is_empty() && raw.bytes().all(|b| b.is_ascii_digit()) {
        // More digits than a u64 holds is simply "very long".
        let secs = raw.parse::<u64>().unwrap_or(u64::MAX);
        return Some(Duration::from_secs(secs.clamp(1, cap)));
    }
    let when = DateTime::parse_from_rfc2822(raw).ok()?.with_timezone(&Utc);
    let secs = when.signed_duration_since(now).num_seconds();
    Some(Duration::from_secs(secs.clamp(1, cap as i64) as u64))
}

/// When a hold of `hold` ends.
fn retry_at(hold: Duration, now: DateTime<Utc>) -> Option<DateTime<Utc>> {
    now.checked_add_signed(chrono::Duration::from_std(hold).ok()?)
}

/// `[A-Z][A-Z0-9_]+-<digits>`: the shape of a Jira issue key.
fn valid_key(key: &str) -> bool {
    let Some((project, number)) = key.split_once('-') else {
        return false;
    };
    project.len() >= 2
        && project.starts_with(|c: char| c.is_ascii_uppercase())
        && project
            .bytes()
            .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit() || b == b'_')
        && !number.is_empty()
        && number.len() <= 10
        && number.bytes().all(|b| b.is_ascii_digit())
}

/// The "Open in Jira" link: https, the validated host, nothing else.
fn browse_url(site: &str, key: &str) -> Option<String> {
    let url = format!("https://{site}/browse/{key}");
    let parsed = url::Url::parse(&url).ok()?;
    let plain = parsed.scheme() == "https"
        && parsed.host_str() == Some(site)
        && parsed.username().is_empty()
        && parsed.password().is_none()
        && parsed.port().is_none();
    plain.then_some(url)
}

/// At most `max_chars` characters, ending with a marker when cut. A cut that
/// lands inside a code fence (backticks or tildes) closes it first, so the
/// marker is never part of the code; a cut inside the closing line itself
/// drops the half line, so no stray fence characters are left.
fn cap_text(text: String, max_chars: usize) -> String {
    let Some((cut, _)) = text.char_indices().nth(max_chars) else {
        return text;
    };
    let mut kept = &text[..cut];
    let mut closer = String::new();
    if let Some((fence_char, len)) = open_fence(kept) {
        // A last line of only fence characters, shorter than the opener, is a closing line cut short.
        let last_line_start = kept.rfind('\n').map_or(0, |i| i + 1);
        let last = kept[last_line_start..].trim_start();
        if !last.is_empty() && last.chars().all(|c| c == fence_char) && last.len() < len {
            kept = kept[..last_line_start].trim_end_matches('\n');
        }
        closer = format!("\n{}", fence_char.to_string().repeat(len));
    }
    format!("{kept}{closer}\n\n… (truncated)")
}

/// The code fence still open at the end of `text`, if any: its character
/// (`` ` `` or `~`) and length. A fence closes on a line of the same character,
/// at least as long as the opener, with nothing else on it.
fn open_fence(text: &str) -> Option<(char, usize)> {
    let mut open: Option<(char, usize)> = None;
    for line in text.lines() {
        let line = line.trim_start();
        let Some(first) = line.chars().next().filter(|c| matches!(c, '`' | '~')) else {
            continue;
        };
        let run = line.chars().take_while(|&c| c == first).count();
        if run < 3 {
            continue;
        }
        match open {
            None => open = Some((first, run)),
            Some((c, opener)) if c == first && run >= opener && line[run..].trim().is_empty() => {
                open = None
            }
            Some(_) => {}
        }
    }
    open
}

/// The `issues` array of a search page. An error body, or a body without the
/// array, is a failure: it must never read as "no issues".
fn issues_of(page: &Value) -> Result<&Vec<Value>, FetchError> {
    if page.get("errorMessages").is_some() || page.get("errors").is_some() {
        return Err(FetchError::Failed("Jira reported an error".into()));
    }
    page.get("issues")
        .and_then(Value::as_array)
        .ok_or_else(|| FetchError::Failed("unexpected response".into()))
}

/// Issues gathered across pages: capped at [`MAX_ISSUES`], counting what was dropped.
struct Collected<'a> {
    site: &'a str,
    items: Vec<WorkItem>,
    unreadable: usize,
}

impl<'a> Collected<'a> {
    fn new(site: &'a str) -> Self {
        Self {
            site,
            items: Vec::new(),
            unreadable: 0,
        }
    }

    fn add(&mut self, issues: &[Value]) {
        for issue in issues {
            match to_work_item(issue, self.site) {
                Some(item) => self.items.push(item),
                None => self.unreadable += 1,
            }
        }
    }

    fn is_full(&self) -> bool {
        self.items.len() >= MAX_ISSUES
    }

    /// `more_remain`: Jira promised issues beyond what was fetched.
    fn finish(mut self, more_remain: bool) -> Result<Fetched, FetchError> {
        if self.items.is_empty() && self.unreadable > 0 {
            return Err(FetchError::Failed(
                "none of the issues Jira returned could be read".into(),
            ));
        }
        let cut = more_remain || self.items.len() > MAX_ISSUES;
        self.items.truncate(MAX_ISSUES);
        let mut notes = Vec::new();
        if cut {
            notes.push(format!(
                "showing the first {} issues; Jira has more",
                self.items.len()
            ));
        }
        if self.unreadable > 0 {
            let n = self.unreadable;
            notes.push(format!(
                "{n} issue{} could not be read",
                if n == 1 { "" } else { "s" }
            ));
        }
        Ok(Fetched {
            items: self.items,
            note: (!notes.is_empty()).then(|| notes.join("; ")),
        })
    }
}

fn to_work_item(issue: &Value, site: &str) -> Option<WorkItem> {
    let key = issue
        .get("key")?
        .as_str()
        .filter(|k| valid_key(k))?
        .to_string();
    let f = issue.get("fields").filter(|f| f.is_object())?.clone();
    let text = |path: &[&str]| -> Option<String> {
        path.iter()
            .try_fold(&f, |acc, p| acc.get(p))
            .and_then(Value::as_str)
            .map(str::to_string)
    };
    let summary = one_line(&text(&["summary"]).unwrap_or_default(), MAX_LINE_CHARS);
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
        kind: text(&["issuetype", "name"])
            .unwrap_or_else(|| "issue".into())
            .to_lowercase(),
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
        due: text(&["duedate"])
            .and_then(|d| NaiveDate::parse_from_str(d.get(..10)?, "%Y-%m-%d").ok()),
        url: browse_url(site, &key),
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
    blocks
        .iter()
        .map(block_to_markdown)
        .collect::<Vec<_>>()
        .join("\n\n")
}

fn block_to_markdown(block: &MdBlock) -> String {
    match block {
        MdBlock::Paragraph { spans } => spans_to_markdown(spans),
        MdBlock::Heading { level, spans } => {
            format!(
                "{} {}",
                "#".repeat((*level).clamp(1, 6) as usize),
                spans_to_markdown(spans)
            )
        }
        MdBlock::CodeBlock { lang, text } => {
            format!("```{}\n{text}\n```", lang.as_deref().unwrap_or(""))
        }
        MdBlock::List {
            ordered,
            start,
            items,
        } => items
            .iter()
            .enumerate()
            .map(|(i, blocks)| {
                let marker = if *ordered {
                    format!("{}.", start.unwrap_or(1).saturating_add(i as u64))
                } else {
                    "-".into()
                };
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
                format!(
                    "| {} |",
                    cells
                        .iter()
                        .map(|c| spans_to_markdown(c))
                        .collect::<Vec<_>>()
                        .join(" | ")
                )
            };
            let mut lines = vec![
                row(header),
                format!("|{}", " --- |".repeat(header.len().max(1))),
            ];
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

    /// A fixed "now" for the pure time functions.
    fn now() -> DateTime<Utc> {
        DateTime::parse_from_rfc3339("2026-10-11T12:00:00Z")
            .unwrap()
            .with_timezone(&Utc)
    }

    #[test]
    fn retry_after_accepts_seconds_and_http_dates() {
        assert_eq!(
            parse_retry_after("30", now()),
            Some(Duration::from_secs(30))
        );
        let past = parse_retry_after("Wed, 21 Oct 2015 07:28:00 GMT", now()).unwrap();
        assert_eq!(
            past,
            Duration::from_secs(1),
            "a date in the past still waits a second"
        );
        assert_eq!(parse_retry_after("0", now()), Some(Duration::from_secs(1)));
        assert_eq!(parse_retry_after("soon", now()), None);
    }

    #[test]
    fn retry_after_is_clamped_and_never_overflows() {
        for huge in [
            "18446744073709551615",
            "18446744073709551616",
            "99999999999999999999999999",
            "901",
            "86400",
        ] {
            assert_eq!(parse_retry_after(huge, now()), Some(MAX_HOLD), "{huge}");
        }
        assert_eq!(
            parse_retry_after("Fri, 31 Dec 9999 23:59:59 GMT", now()),
            Some(MAX_HOLD)
        );
        assert_eq!(parse_retry_after("900", now()), Some(MAX_HOLD));
        for unusable in [
            "-5",
            "-0",
            "",
            "  ",
            "1.5",
            "+5",
            "5 s",
            "NaN",
            "Tue, 99 Foo 2026",
        ] {
            assert_eq!(parse_retry_after(unusable, now()), None, "{unusable:?}");
        }
        let hold = retry_at(MAX_HOLD, now()).expect("a 15 minute hold has an end time");
        assert_eq!(hold - now(), chrono::Duration::from_std(MAX_HOLD).unwrap());
    }

    #[test]
    fn backoff_doubles_and_is_capped() {
        let s = JiraWorkSource::new("/nonexistent/.env");
        assert_eq!(s.backoff(1), Duration::from_secs(2));
        assert_eq!(s.backoff(2), Duration::from_secs(4));
        assert_eq!(s.backoff(3), Duration::from_secs(8));
        assert_eq!(s.backoff(40), BACKOFF_CAP);
        assert_eq!(s.backoff(u32::MAX), BACKOFF_CAP);
    }

    #[test]
    fn jira_timestamps_without_a_colon_in_the_offset_parse() {
        assert!(parse_jira_time("2026-10-01T08:00:00.000+0000").is_some());
        assert!(parse_jira_time("2026-10-01T08:00:00Z").is_some());
        assert!(parse_jira_time("yesterday").is_none());
    }

    #[test]
    fn only_atlassian_sites_are_valid_and_a_bare_name_is_expanded() {
        for (given, host) in [
            ("example.atlassian.net", "example.atlassian.net"),
            ("Example.Atlassian.NET", "example.atlassian.net"),
            ("  example.atlassian.net \n", "example.atlassian.net"),
            ("https://example.atlassian.net/", "example.atlassian.net"),
            ("example", "example.atlassian.net"),
            ("my-team-2", "my-team-2.atlassian.net"),
        ] {
            assert_eq!(validate_site(given).as_deref(), Some(host), "{given:?}");
        }
        let too_long = format!("{}.atlassian.net", "a".repeat(64));
        for hostile in [
            "",
            " ",
            "/",
            "https://",
            ".atlassian.net",
            "evil.example",
            "evil.example/",
            "x@evil",
            "a.atlassian.net.evil.example",
            "user:pw@example.atlassian.net",
            "example.atlassian.net:443",
            "example.atlassian.net:8443",
            "exa mple",
            "example.atlassian.net evil.example",
            "exаmple.atlassian.net",
            "example．atlassian．net",
            "-bad",
            "bad-",
            "x.sub.atlassian.net",
            "example.atlassian.net.",
            "http://example.atlassian.net",
            "https://https://example",
            "example.atlassian.net//",
            "//evil.example",
            "evil.example#.atlassian.net",
            "evil.example?.atlassian.net",
            "evil.example\\.atlassian.net",
            "atlassian.net",
            "example.atlassian.net/browse",
            "ex\0ample",
            too_long.as_str(),
        ] {
            assert_eq!(validate_site(hostile), None, "{hostile:?}");
        }
    }

    #[test]
    fn links_are_https_on_the_validated_host_only() {
        assert_eq!(
            browse_url("example.atlassian.net", "AB-12").as_deref(),
            Some("https://example.atlassian.net/browse/AB-12")
        );
        assert_eq!(browse_url("evil.example@x", "AB-12"), None);
        assert_eq!(browse_url("example.atlassian.net:8443", "AB-12"), None);
    }

    #[test]
    fn issue_keys_follow_jiras_shape() {
        for good in ["PROJ-1", "MY_PROJ-12", "A1-7", "AB-1234567890"] {
            assert!(valid_key(good), "{good}");
        }
        for bad in [
            "P-1",
            "_X-1",
            "1AB-2",
            "PROJ-",
            "PROJ-1-2",
            "proj-1",
            "PROJ-abc",
            "PROJ-1/x",
            "",
            "-1",
            "AB-12345678901",
        ] {
            assert!(!valid_key(bad), "{bad}");
        }
    }

    #[test]
    fn long_text_is_cut_on_a_character_boundary_with_a_marker() {
        assert_eq!(cap_text("short".into(), 10), "short");
        assert_eq!(cap_text("exactly10!".into(), 10), "exactly10!");
        let cut = cap_text("é".repeat(50), 10);
        assert!(
            cut.starts_with(&"é".repeat(10)) && cut.ends_with("(truncated)"),
            "{cut}"
        );
    }

    #[test]
    fn unreadable_issues_are_counted_and_the_cap_is_marked() {
        let mut c = Collected::new("example.atlassian.net");
        c.add(&[
            json!({"key": "AB-1", "fields": {}}),
            json!({"key": "../x", "fields": {}}),
            json!({"key": "AB-2"}),
            json!("nope"),
            json!({}),
        ]);
        let f = c.finish(false).unwrap();
        assert_eq!(f.items.len(), 1);
        assert_eq!(f.note.as_deref(), Some("4 issues could not be read"));

        let mut c = Collected::new("example.atlassian.net");
        c.add(&[json!({"key": "../x"})]);
        assert!(
            c.finish(false).is_err(),
            "all unreadable is a failure, not an empty list"
        );

        let mut c = Collected::new("example.atlassian.net");
        let many: Vec<Value> = (1..=MAX_ISSUES + 20)
            .map(|n| json!({"key": format!("AB-{n}"), "fields": {}}))
            .collect();
        c.add(&many);
        let f = c.finish(false).unwrap();
        assert_eq!(f.items.len(), MAX_ISSUES);
        assert!(f.note.unwrap().contains("first 500"));
    }

    // ── holds, in simulated time (no sockets, so the paused clock is safe) ──

    fn quiet_source() -> JiraWorkSource {
        JiraWorkSource::new("/nonexistent/.env").file_credentials_only()
    }

    /// Whether `wait` is still waiting after `after` of simulated time.
    async fn still_waiting(
        wait: &mut (impl std::future::Future<Output = ()> + Unpin),
        after: Duration,
    ) -> bool {
        tokio::time::timeout(after, wait).await.is_err()
    }

    #[tokio::test(start_paused = true)]
    async fn a_manual_refresh_does_not_break_a_retry_after_hold() {
        let src = quiet_source();
        let refresh = Notify::new();
        let seen = src.seen();
        let mut wait = Box::pin(src.wait(MAX_HOLD, Wake::CredentialsOnly, &refresh, &seen));
        refresh.notify_one();
        assert!(
            still_waiting(&mut wait, Duration::from_secs(60)).await,
            "the poke ended the hold"
        );
        refresh.notify_one();
        assert!(
            still_waiting(&mut wait, MAX_HOLD - Duration::from_secs(120)).await,
            "a later poke ended the hold"
        );
        assert!(
            !still_waiting(&mut wait, Duration::from_secs(120)).await,
            "the hold never ended"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn a_poke_ends_an_ordinary_wait_and_is_not_saved_after_a_hold() {
        let src = quiet_source();
        let refresh = Notify::new();
        let seen = src.seen();
        let mut ordinary =
            Box::pin(src.wait(MAX_HOLD, Wake::RefreshOrCredentials, &refresh, &seen));
        assert!(still_waiting(&mut ordinary, Duration::from_secs(10)).await);
        refresh.notify_one();
        assert!(
            !still_waiting(&mut ordinary, Duration::from_secs(1)).await,
            "a poke wakes an ordinary wait"
        );

        // A poke that lands during a hold is consumed by it: the next wait is not cut short.
        let mut hold = Box::pin(src.wait(
            Duration::from_secs(30),
            Wake::CredentialsOnly,
            &refresh,
            &seen,
        ));
        refresh.notify_one();
        assert!(!still_waiting(&mut hold, Duration::from_secs(31)).await);
        let mut next = Box::pin(src.wait(MAX_HOLD, Wake::RefreshOrCredentials, &refresh, &seen));
        assert!(
            still_waiting(&mut next, Duration::from_secs(60)).await,
            "the held poke was replayed"
        );
    }

    fn env_text(token: &str) -> String {
        format!("ATLASSIAN_SITE_NAME=example\nATLASSIAN_USER_EMAIL=a@example.com\nATLASSIAN_API_TOKEN={token}\n")
    }

    fn touch(path: &std::path::Path, secs_ahead: u64) {
        let later = SystemTime::now() + Duration::from_secs(secs_ahead);
        std::fs::File::options()
            .write(true)
            .open(path)
            .unwrap()
            .set_modified(later)
            .unwrap();
    }

    #[tokio::test(start_paused = true)]
    async fn changed_credentials_end_even_a_hold_but_a_touched_file_does_not() {
        let dir = tempfile::tempdir().unwrap();
        let env = dir.path().join(".env");
        std::fs::write(&env, env_text("one")).unwrap();
        let src = JiraWorkSource::new(&env)
            .file_credentials_only()
            .with_env_watch_interval(Duration::from_secs(1));
        let refresh = Notify::new();
        let seen = src.seen();
        let mut wait = Box::pin(src.wait(MAX_HOLD, Wake::CredentialsOnly, &refresh, &seen));
        assert!(
            still_waiting(&mut wait, Duration::from_secs(5)).await,
            "nothing changed yet"
        );

        touch(&env, 60); // same credentials, new mtime (an editor, a backup tool)
        assert!(
            still_waiting(&mut wait, Duration::from_secs(10)).await,
            "a touched file ended the hold"
        );

        std::fs::write(&env, env_text("two")).unwrap();
        touch(&env, 120);
        assert!(
            !still_waiting(&mut wait, Duration::from_secs(5)).await,
            "a new token was not noticed"
        );
    }

    #[test]
    fn a_hold_applies_to_the_credentials_it_was_earned_with_and_detail_honours_it() {
        let src = quiet_source();
        assert!(src.hold_error(7).is_none());
        src.set_hold(7, HoldKind::RateLimited, Duration::from_secs(60));
        assert_eq!(src.hold_error(7).unwrap().code, "rate_limited");
        assert!(src.hold_error(8).is_none(), "new credentials start clean");
        src.set_hold(7, HoldKind::Rejected(403), Duration::from_secs(u64::MAX));
        let refused = src.hold_error(7).unwrap();
        assert_eq!(refused.code, "unauthenticated");
        assert!(
            refused.message.contains("403") && refused.message.contains("permission"),
            "{}",
            refused.message
        );
        src.clear_hold();
        assert!(src.hold_error(7).is_none());
        src.set_hold(7, HoldKind::RateLimited, Duration::ZERO);
        assert!(src.hold_error(7).is_none(), "an expired hold is gone");
    }

    #[tokio::test(start_paused = true)]
    async fn an_absurd_delay_cannot_overflow_the_deadline() {
        let src = quiet_source();
        let refresh = Notify::new();
        let seen = src.seen();
        let mut wait =
            Box::pin(src.wait(Duration::MAX, Wake::RefreshOrCredentials, &refresh, &seen));
        assert!(still_waiting(&mut wait, Duration::from_secs(60)).await);
        refresh.notify_one();
        assert!(!still_waiting(&mut wait, Duration::from_secs(1)).await);
    }

    // ── cap_text never leaves a code fence open ──────────────────────────────

    fn fence_lines(text: &str) -> usize {
        text.lines()
            .filter(|l| l.trim_start().starts_with("```"))
            .count()
    }

    #[test]
    fn a_cut_inside_a_code_fence_closes_the_fence_before_the_marker() {
        let text = format!("intro\n```\n{}", "code line\n".repeat(50));
        let cut = cap_text(text.clone(), 60);
        assert!(
            cut.starts_with(&text[..60]),
            "the first 60 characters are kept: {cut}"
        );
        assert_eq!(fence_lines(&cut) % 2, 0, "the fences are balanced: {cut}");
        assert!(cut.ends_with("… (truncated)"), "{cut}");
        let marker_at = cut.rfind("… (truncated)").unwrap();
        let last_fence_at = cut.rfind("```").unwrap();
        assert!(
            last_fence_at < marker_at,
            "the marker is outside the fence: {cut}"
        );
    }

    #[test]
    fn a_cut_inside_a_fence_with_a_language_closes_it_too() {
        let text = format!("```rust\nfn main() {{}}\n{}", "let x = 1;\n".repeat(20));
        let cut = cap_text(text, 40);
        assert_eq!(fence_lines(&cut) % 2, 0, "{cut}");
        assert!(
            cut.rfind("```").unwrap() < cut.rfind("… (truncated)").unwrap(),
            "{cut}"
        );
    }

    #[test]
    fn a_cut_outside_any_fence_is_unchanged() {
        let cut = cap_text("abcdefghij".repeat(5), 20);
        assert_eq!(cut, format!("{}\n\n… (truncated)", "abcdefghij".repeat(2)));
        assert!(!cut.contains("```"));
    }

    #[test]
    fn a_closed_fence_before_the_cut_leaves_the_text_unchanged() {
        let text = format!("```\ncode\n```\n{}", "plain text ".repeat(30));
        let cut = cap_text(text.clone(), 50);
        assert_eq!(
            cut,
            format!("{}\n\n… (truncated)", &text[..50]),
            "nothing is open, so nothing is added"
        );
        assert_eq!(fence_lines(&cut), 2);
    }

    // ── `~~~` fences, and a cut inside the closing line ──────────────────────

    const MARKER: &str = "\n\n… (truncated)";

    #[test]
    fn a_cut_inside_a_tilde_fence_closes_it_with_tildes_before_the_marker() {
        let text = format!("intro\n~~~\n{}", "code line\n".repeat(50));
        let cut = cap_text(text.clone(), 40);
        assert!(cut.starts_with(&text[..40]), "{cut}");
        assert!(
            cut.ends_with(&format!("\n~~~{MARKER}")),
            "closed with `~~~`, then the marker outside the fence: {cut}"
        );
        assert!(!cut.contains("```"), "no backtick fence is invented: {cut}");
        assert_eq!(open_fence(&cut), None, "balanced: {cut}");
    }

    #[test]
    fn a_tilde_line_does_not_close_a_backtick_fence_and_the_cut_closes_it_with_backticks() {
        let text = format!("```\ncode\n~~~\n{}", "more code\n".repeat(30));
        let cut = cap_text(text.clone(), 40);
        assert!(
            cut.ends_with(&format!("\n```{MARKER}")),
            "still inside the backtick fence, so it is closed with backticks: {cut}"
        );
        assert_eq!(
            cut.lines().filter(|l| l.starts_with("```")).count(),
            2,
            "{cut}"
        );
        assert_eq!(open_fence(&cut), None, "{cut}");
    }

    #[test]
    fn a_backtick_line_does_not_close_a_tilde_fence_and_the_cut_closes_it_with_tildes() {
        let text = format!("~~~\ncode\n```\n{}", "more code\n".repeat(30));
        let cut = cap_text(text, 40);
        assert!(cut.ends_with(&format!("\n~~~{MARKER}")), "{cut}");
        assert_eq!(open_fence(&cut), None, "{cut}");
    }

    #[test]
    fn a_cut_inside_the_closing_fence_line_leaves_no_half_fence_and_a_balanced_result() {
        for (fence, cut_after) in [("```", 2), ("```", 1), ("~~~", 2), ("````", 3), ("~~~~", 1)] {
            let text = format!("{fence}\ncode\n{fence}\nmore text after the block");
            let max = fence.len() + 1 + "code".len() + 1 + cut_after;
            let cut = cap_text(text, max);
            assert_eq!(
                cut,
                format!("{fence}\ncode\n{fence}{MARKER}"),
                "{fence} cut {cut_after} characters into the closing line"
            );
            assert_eq!(open_fence(&cut), None);
            assert!(cut.ends_with("… (truncated)"));
        }
    }

    #[test]
    fn a_cut_just_after_a_complete_closing_fence_is_balanced_without_an_extra_fence() {
        let text = "~~~\ncode\n~~~\nmore text after the block".to_string();
        let cut = cap_text(text, "~~~\ncode\n~~~".chars().count());
        assert_eq!(cut, format!("~~~\ncode\n~~~{MARKER}"));
    }

    #[test]
    fn a_closing_run_longer_than_the_opener_closes_it_and_a_shorter_one_does_not() {
        assert_eq!(open_fence("```\ncode\n`````"), None);
        assert_eq!(open_fence("```\ncode\n``"), Some(('`', 3)));
        assert_eq!(open_fence("~~~\ncode\n~~~~"), None);
        assert_eq!(open_fence("~~~~\ncode\n~~~"), Some(('~', 4)));
        assert_eq!(
            open_fence("```\ncode\n``` after"),
            Some(('`', 3)),
            "a closing line has nothing else on it"
        );
    }
}
