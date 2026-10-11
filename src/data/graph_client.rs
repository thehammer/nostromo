//! Microsoft Graph API client with OAuth2 device-flow auth.
//!
//! # Auth lifecycle
//! On first use (or after token expiry + failed refresh) `ensure_authed` first
//! tries shelling out to `m365 util accesstoken get` (cli-microsoft365) if that
//! binary is on PATH — this reuses an existing browser-authenticated session and
//! avoids Conditional Access restrictions on the device-code flow.  If `m365`
//! is unavailable or fails, the classic device-code flow is started instead and
//! a `DeviceFlowPrompt` is returned for the TUI to render.
//!
//! The resulting token is cached to `~/.cache/nostromo/graph-token.json`
//! (mode 0600, parent dir 0700).
//!
//! # Delta queries
//! `delta()` fetches changes since the last call by persisting the
//! `@odata.deltaLink` returned by Graph to a per-query file.  On the first
//! call (or if the file is missing) it uses the supplied `initial_path`.

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{bail, Context, Result};
use chrono::{DateTime, Duration as ChronoDuration, Utc};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use tokio::sync::Mutex;
use tracing::{debug, info, warn};

const GRAPH_BASE: &str = "https://graph.microsoft.com/v1.0";
const LOGIN_BASE: &str = "https://login.microsoftonline.com";
/// Graph's minimum device-code polling interval.
const MIN_DEVICE_POLL: std::time::Duration = std::time::Duration::from_secs(5);
const SCOPES: &str = "Mail.Read Calendars.Read offline_access";

// ── Public types ─────────────────────────────────────────────────────────────

/// Rendered in the Fred mailbox panel when auth is required.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceFlowPrompt {
    pub verification_uri: String,
    pub user_code: String,
    pub expires_at: DateTime<Utc>,
}

/// Where the client talks to and how it signs in. `Default` is production;
/// tests point the bases at a mock server and switch the `m365` CLI off.
#[derive(Debug, Clone)]
pub struct GraphOptions {
    /// Base for Graph API paths (replaces `https://graph.microsoft.com/v1.0`).
    pub graph_base: String,
    /// Base for the OAuth endpoints (replaces `https://login.microsoftonline.com`).
    pub login_base: String,
    /// Borrow a token from the `m365` CLI before starting the device flow.
    pub use_m365_cli: bool,
    /// Floor for the device-code polling interval.
    pub min_device_poll: std::time::Duration,
}

impl Default for GraphOptions {
    fn default() -> Self {
        Self {
            graph_base: GRAPH_BASE.to_owned(),
            login_base: LOGIN_BASE.to_owned(),
            use_m365_cli: true,
            min_device_poll: MIN_DEVICE_POLL,
        }
    }
}

/// A non-success HTTP answer from Graph. Typed so callers can turn it into a
/// plain-English reason (`downcast_ref` works through `anyhow` context).
#[derive(Debug)]
pub struct GraphHttpError {
    pub status: reqwest::StatusCode,
    pub url: String,
    pub body: String,
    /// The server's `Retry-After` (already capped), when it sent a usable one.
    pub retry_after: Option<std::time::Duration>,
}

impl GraphHttpError {
    /// Graph is throttling us: a 429, or a 503 that says when to come back.
    pub fn is_throttle(&self) -> bool {
        self.status == reqwest::StatusCode::TOO_MANY_REQUESTS
            || (self.status == reqwest::StatusCode::SERVICE_UNAVAILABLE && self.retry_after.is_some())
    }
}

impl std::fmt::Display for GraphHttpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Graph GET {} -> {}: {}", self.url, self.status, self.body)
    }
}

impl std::error::Error for GraphHttpError {}

/// Longest we will ever stay quiet because of a `Retry-After` (contract §9
/// caps backoff at 15 minutes).
pub const MAX_RETRY_AFTER: std::time::Duration = std::time::Duration::from_secs(15 * 60);

/// Parse an HTTP `Retry-After` value: whole seconds or an HTTP-date, measured
/// from `now`, capped at [`MAX_RETRY_AFTER`]. A date in the past is zero.
/// `None` when the value is neither.
pub fn parse_retry_after(value: &str, now: DateTime<Utc>) -> Option<std::time::Duration> {
    let value = value.trim();
    let wait = if let Ok(secs) = value.parse::<u64>() {
        std::time::Duration::from_secs(secs)
    } else {
        let when = DateTime::parse_from_rfc2822(value).ok()?.with_timezone(&Utc);
        (when - now).to_std().unwrap_or(std::time::Duration::ZERO)
    };
    Some(wait.min(MAX_RETRY_AFTER))
}

/// `Some(retry_after)` when `e` is Graph throttling us (429, or 503 with a
/// `Retry-After`); `None` for any other failure.
pub fn throttle_of(e: &anyhow::Error) -> Option<Option<std::time::Duration>> {
    let http = e.downcast_ref::<GraphHttpError>()?;
    http.is_throttle().then_some(http.retry_after)
}

/// Consecutive-throttle counter for one polling loop. Success resets it.
/// The wait after a throttle is the server's `Retry-After` when there is one,
/// otherwise exponential backoff: 2 s, 4 s, 8 s … capped at 15 min, plus up
/// to 25 % jitter.
#[derive(Debug, Default)]
pub struct ThrottleBackoff {
    consecutive: u32,
}

const BACKOFF_BASE: std::time::Duration = std::time::Duration::from_secs(2);

impl ThrottleBackoff {
    /// A fetch succeeded: the next throttle starts again at the first step.
    pub fn succeeded(&mut self) {
        self.consecutive = 0;
    }

    /// `e` is how a fetch failed. When it is a throttle, how long to stay
    /// quiet; otherwise `None` (and the backoff is left alone).
    pub fn throttled(&mut self, e: &anyhow::Error) -> Option<std::time::Duration> {
        let retry_after = throttle_of(e)?;
        let step = BACKOFF_BASE
            .saturating_mul(1u32.checked_shl(self.consecutive).unwrap_or(u32::MAX))
            .min(MAX_RETRY_AFTER);
        self.consecutive = self.consecutive.saturating_add(1);
        Some(match retry_after {
            Some(wait) => wait,
            None => (step + step.mul_f64(jitter() * 0.25)).min(MAX_RETRY_AFTER),
        })
    }
}

/// A cheap value in `[0, 1)`; spreads out retries, not security sensitive.
fn jitter() -> f64 {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    f64::from(nanos % 1000) / 1000.0
}

/// A short plain-English reason for a failed Graph fetch, safe to show in the
/// UI and MCP results: no URLs, response bodies or tokens.
pub fn failure_reason(what: &str, e: &anyhow::Error) -> String {
    if let Some(http) = e.downcast_ref::<GraphHttpError>() {
        let code = http.status.as_u16();
        return match code {
            401 => format!("{what}: Microsoft rejected the sign-in (401); sign-in will be retried"),
            403 => format!("{what}: Microsoft denied access (403)"),
            429 => format!("{what}: Microsoft is rate limiting requests (429)"),
            500..=599 => format!("{what}: Microsoft Graph is unavailable ({code})"),
            _ => format!("{what}: Microsoft Graph returned {code}"),
        };
    }
    if e.chain().any(|c| c.downcast_ref::<reqwest::Error>().is_some_and(|r| r.is_connect() || r.is_timeout())) {
        return format!("{what}: could not reach Microsoft Graph");
    }
    format!("{what}: unexpected response from Microsoft Graph")
}

// ── Internal types ────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
struct TokenState {
    access_token: String,
    refresh_token: Option<String>,
    #[serde(with = "chrono::serde::ts_seconds")]
    expires_at: DateTime<Utc>,
}

impl TokenState {
    fn is_expired(&self) -> bool {
        Utc::now() >= self.expires_at - ChronoDuration::seconds(60)
    }
}

#[derive(Deserialize)]
struct DeviceCodeResponse {
    device_code: String,
    user_code: String,
    verification_uri: String,
    expires_in: u64,
    interval: u64,
}

#[derive(Deserialize)]
struct TokenResponse {
    access_token: Option<String>,
    refresh_token: Option<String>,
    expires_in: Option<u64>,
    error: Option<String>,
}

// ── GraphClient ───────────────────────────────────────────────────────────────

#[derive(Clone)]
pub struct GraphClient {
    http: reqwest::Client,
    token: Arc<Mutex<Option<TokenState>>>,
    cache_path: PathBuf,
    client_id: String,
    tenant: String,
    /// True while a device-flow poll task is in flight. Prevents spawning
    /// multiple concurrent poll tasks (each with its own device code) when
    /// `ensure_authed` is called repeatedly while sign-in is pending.
    device_flow_active: Arc<Mutex<bool>>,
    /// The prompt of the device flow in flight (cleared when it ends), so every
    /// caller sharing this client shows the same code instead of starting its own.
    pending_prompt: Arc<Mutex<Option<DeviceFlowPrompt>>>,
    opts: GraphOptions,
}

impl GraphClient {
    /// Create a new client, loading any cached token from `cache_path`.
    pub async fn new(client_id: String, tenant: String, cache_path: PathBuf) -> Result<Self> {
        Self::with_options(client_id, tenant, cache_path, GraphOptions::default()).await
    }

    /// The process-wide client for `(client_id, tenant, cache_path)`. The Fred
    /// mailbox and calendar sources both call this so they share one token and
    /// one device flow (two clients would issue two sign-in codes).
    pub async fn shared(client_id: String, tenant: String, cache_path: PathBuf) -> Result<Self> {
        type Key = (String, String, PathBuf);
        static REGISTRY: std::sync::OnceLock<std::sync::Mutex<std::collections::HashMap<Key, GraphClient>>> =
            std::sync::OnceLock::new();
        let registry = REGISTRY.get_or_init(Default::default);
        let key = (client_id.clone(), tenant.clone(), cache_path.clone());
        if let Some(existing) = registry.lock().expect("graph registry").get(&key) {
            return Ok(existing.clone());
        }
        let client = Self::new(client_id, tenant, cache_path).await?;
        Ok(registry
            .lock()
            .expect("graph registry")
            .entry(key)
            .or_insert(client)
            .clone())
    }

    /// Create a client with explicit endpoints/sign-in options.
    pub async fn with_options(
        client_id: String,
        tenant: String,
        cache_path: PathBuf,
        opts: GraphOptions,
    ) -> Result<Self> {
        let http = reqwest::Client::builder()
            .user_agent(concat!("nostromo/", env!("CARGO_PKG_VERSION")))
            .build()
            .context("building reqwest client")?;

        let token = load_cached_token(&cache_path);

        Ok(Self {
            http,
            token: Arc::new(Mutex::new(token)),
            cache_path,
            client_id,
            tenant,
            device_flow_active: Arc::new(Mutex::new(false)),
            pending_prompt: Arc::new(Mutex::new(None)),
            opts,
        })
    }

    /// The sign-in prompt of the device flow in flight, if any.
    pub async fn pending_prompt(&self) -> Option<DeviceFlowPrompt> {
        self.pending_prompt.lock().await.clone()
    }

    /// Ensure the client is authenticated.
    ///
    /// Returns `None` when a valid token is present.
    /// Returns `Some(DeviceFlowPrompt)` when interactive sign-in is needed; a
    /// background task will complete the flow and update the token.
    pub async fn ensure_authed(&self) -> Result<Option<DeviceFlowPrompt>> {
        let mut guard = self.token.lock().await;

        // Check if we already have a valid token.
        if let Some(ref tok) = *guard {
            if !tok.is_expired() {
                return Ok(None);
            }
            // Try refreshing.
            if let Some(ref rt) = tok.refresh_token.clone() {
                match self.do_refresh(rt).await {
                    Ok(new_tok) => {
                        persist_token(&self.cache_path, &new_tok)?;
                        *guard = Some(new_tok);
                        return Ok(None);
                    }
                    Err(e) => {
                        warn!("token refresh failed, falling through to device flow: {e:#}");
                    }
                }
            }
        }

        // No valid token — try m365 CLI first, fall back to device flow.
        drop(guard); // release lock before async I/O

        if self.opts.use_m365_cli {
            if let Some(tok) = try_m365_token().await {
                info!("graph token acquired via m365 CLI");
                persist_token(&self.cache_path, &tok)?;
                *self.token.lock().await = Some(tok);
                return Ok(None);
            }
        }

        // Held across the start so two sources sharing this client cannot
        // both begin a device flow (two sign-in codes).
        let mut active = self.device_flow_active.lock().await;
        if *active {
            drop(active);
            // Sign-in still pending: keep showing its prompt (the token is
            // stored before the prompt is cleared, so `None` here means the
            // flow just completed).
            return Ok(self.pending_prompt().await);
        }
        let prompt = self.start_device_flow().await?;
        *active = true;
        Ok(Some(prompt))
    }

    /// Fetch a JSON resource from Graph (full URL or path under GRAPH_BASE).
    ///
    /// A 401 gets one refresh-and-retry. The first answer and the retried one
    /// go through the same status check, so a failed retry can never be read
    /// as data.
    pub async fn get_json<T: DeserializeOwned>(&self, url: &str) -> Result<T> {
        self.get_json_with_headers(url, &[]).await
    }

    /// [`get_json`](Self::get_json) with extra request headers (e.g. Graph's
    /// `Prefer: outlook.body-content-type="text"`).
    pub async fn get_json_with_headers<T: DeserializeOwned>(
        &self,
        url: &str,
        headers: &[(&str, &str)],
    ) -> Result<T> {
        let url = self.absolute_url(url);
        let mut resp = self.authenticated_get(&url, headers).await?;

        if resp.status() == reqwest::StatusCode::UNAUTHORIZED {
            // If the token cannot be refreshed it is no good any more: forget
            // it so the next `ensure_authed` borrows a new one or starts the
            // device flow.
            if let Err(e) = self.refresh_once().await {
                *self.token.lock().await = None;
                return Err(e.context(GraphHttpError {
                    status: reqwest::StatusCode::UNAUTHORIZED,
                    url,
                    body: String::new(),
                    retry_after: None,
                }));
            }
            resp = self.authenticated_get(&url, headers).await?;
        }

        let resp = ensure_success(resp, &url).await?;
        resp.json::<T>().await.context("deserialising Graph JSON")
    }

    /// Fetch a delta page set.
    ///
    /// Uses the persisted delta link if present; falls back to `initial_path`.
    /// Follows `@odata.nextLink` pagination, persists `@odata.deltaLink`, and
    /// returns `(items, delta_link)`.
    pub async fn delta<T: DeserializeOwned>(
        &self,
        initial_path: &str,
        delta_link_file: &Path,
    ) -> Result<(Vec<T>, String)> {
        let start_url = if delta_link_file.exists() {
            tokio::fs::read_to_string(delta_link_file)
                .await
                .unwrap_or_else(|_| self.absolute_url(initial_path))
                .trim()
                .to_owned()
        } else {
            self.absolute_url(initial_path)
        };

        let mut items: Vec<T> = Vec::new();
        let mut next_url: Option<String> = Some(start_url);
        let mut delta_link = String::new();

        while let Some(url) = next_url.take() {
            let page: serde_json::Value = self
                .get_json(&url)
                .await
                .with_context(|| format!("delta fetch {url}"))?;

            for item in page_values(&page, &url)? {
                match serde_json::from_value::<T>(item.clone()) {
                    Ok(t) => items.push(t),
                    Err(e) => warn!("skipping delta item, deserialise error: {e}"),
                }
            }

            // Prefer deltaLink (end of set) over nextLink (more pages).
            if let Some(dl) = page.get("@odata.deltaLink").and_then(|v| v.as_str()) {
                delta_link = dl.to_owned();
            } else if let Some(nl) = page.get("@odata.nextLink").and_then(|v| v.as_str()) {
                next_url = Some(nl.to_owned());
            }
        }

        // Persist the delta link for next call.
        if !delta_link.is_empty() {
            if let Some(parent) = delta_link_file.parent() {
                let _ = tokio::fs::create_dir_all(parent).await;
            }
            let _ = tokio::fs::write(delta_link_file, &delta_link).await;
        }

        Ok((items, delta_link))
    }

    /// Fetch all pages of a collection endpoint (no delta tracking).
    ///
    /// Follows `@odata.nextLink` pagination and returns every item.
    /// Use this for endpoints where you want the full current state on every
    /// call rather than incremental changes (e.g. `calendarView`).
    pub async fn get_paged<T: DeserializeOwned>(&self, initial_path: &str) -> Result<Vec<T>> {
        let mut items: Vec<T> = Vec::new();
        let mut next_url: Option<String> = Some(self.absolute_url(initial_path));

        while let Some(url) = next_url.take() {
            let page: serde_json::Value = self
                .get_json(&url)
                .await
                .with_context(|| format!("paged fetch {url}"))?;

            for item in page_values(&page, &url)? {
                match serde_json::from_value::<T>(item.clone()) {
                    Ok(t) => items.push(t),
                    Err(e) => warn!("skipping paged item, deserialise error: {e}"),
                }
            }

            next_url = page
                .get("@odata.nextLink")
                .and_then(|v| v.as_str())
                .map(|s| s.to_owned());
        }

        Ok(items)
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    async fn authenticated_get(
        &self,
        url: &str,
        headers: &[(&str, &str)],
    ) -> Result<reqwest::Response> {
        let token = {
            let guard = self.token.lock().await;
            guard
                .as_ref()
                .map(|t| t.access_token.clone())
                .unwrap_or_default()
        };

        let mut req = self.http.get(url).bearer_auth(&token);
        for (name, value) in headers {
            req = req.header(*name, *value);
        }
        req.send()
            .await
            .with_context(|| format!("GET {url}"))
    }

    async fn refresh_once(&self) -> Result<()> {
        let refresh_token = {
            let guard = self.token.lock().await;
            guard
                .as_ref()
                .and_then(|t| t.refresh_token.clone())
                .ok_or_else(|| anyhow::anyhow!("no refresh token available"))?
        };

        let new_tok = self.do_refresh(&refresh_token).await?;
        persist_token(&self.cache_path, &new_tok)?;
        *self.token.lock().await = Some(new_tok);
        Ok(())
    }

    async fn do_refresh(&self, refresh_token: &str) -> Result<TokenState> {
        let url = format!("{}/{}/oauth2/v2.0/token", self.opts.login_base, self.tenant);
        let params = [
            ("client_id", self.client_id.as_str()),
            ("grant_type", "refresh_token"),
            ("refresh_token", refresh_token),
            ("scope", SCOPES),
        ];

        let resp: TokenResponse = self
            .http
            .post(&url)
            .form(&params)
            .send()
            .await
            .context("refresh token request")?
            .json()
            .await
            .context("parsing refresh response")?;

        if let Some(err) = resp.error {
            bail!("token refresh error: {err}");
        }

        let access_token = resp
            .access_token
            .ok_or_else(|| anyhow::anyhow!("no access_token in refresh response"))?;
        let expires_in = resp.expires_in.unwrap_or(3600);
        let expires_at = Utc::now() + ChronoDuration::seconds(expires_in as i64);

        Ok(TokenState {
            access_token,
            refresh_token: resp.refresh_token,
            expires_at,
        })
    }

    async fn start_device_flow(&self) -> Result<DeviceFlowPrompt> {
        let url = format!("{}/{}/oauth2/v2.0/devicecode", self.opts.login_base, self.tenant);
        let params = [("client_id", self.client_id.as_str()), ("scope", SCOPES)];

        let dc: DeviceCodeResponse = self
            .http
            .post(&url)
            .form(&params)
            .send()
            .await
            .context("device code request")?
            .json()
            .await
            .context("parsing device code response")?;

        let expires_at = Utc::now() + ChronoDuration::seconds(dc.expires_in as i64);
        let prompt = DeviceFlowPrompt {
            verification_uri: dc.verification_uri.clone(),
            user_code: dc.user_code.clone(),
            expires_at,
        };

        *self.pending_prompt.lock().await = Some(prompt.clone());

        // Spawn background poll task.
        let client = self.clone();
        let device_code = dc.device_code.clone();
        let poll_interval = std::time::Duration::from_secs(dc.interval).max(self.opts.min_device_poll);
        tokio::spawn(async move {
            client.poll_device_code(&device_code, poll_interval, expires_at).await;
        });

        Ok(prompt)
    }

    async fn poll_device_code(
        &self,
        device_code: &str,
        interval: std::time::Duration,
        deadline: DateTime<Utc>,
    ) {
        let url = format!("{}/{}/oauth2/v2.0/token", self.opts.login_base, self.tenant);
        let params = [
            ("client_id", self.client_id.as_str()),
            ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
            ("device_code", device_code),
        ];

        loop {
            tokio::time::sleep(interval).await;
            if Utc::now() > deadline {
                warn!("device flow expired before sign-in completed");
                break;
            }

            let resp: TokenResponse = match self
                .http
                .post(&url)
                .form(&params)
                .send()
                .await
            {
                // Azure answers "still pending" / "expired" with HTTP 400 and a
                // JSON `error` body, so the body (not the status) decides.
                Ok(r) => match r.json().await {
                    Ok(v) => v,
                    Err(e) => {
                        warn!("device poll JSON error: {e}");
                        continue;
                    }
                },
                Err(e) => {
                    warn!("device poll request error: {e}");
                    continue;
                }
            };

            match resp.error.as_deref() {
                Some("authorization_pending") => continue,
                Some("slow_down") => {
                    tokio::time::sleep(std::time::Duration::from_secs(5)).await;
                    continue;
                }
                Some(other) => {
                    warn!("device flow terminal error: {other}");
                    break;
                }
                None => {}
            }

            if let Some(access_token) = resp.access_token {
                let expires_in = resp.expires_in.unwrap_or(3600);
                let tok = TokenState {
                    access_token,
                    refresh_token: resp.refresh_token,
                    expires_at: Utc::now() + ChronoDuration::seconds(expires_in as i64),
                };

                match persist_token(&self.cache_path, &tok) {
                    Ok(_) => info!("graph token persisted to {}", self.cache_path.display()),
                    Err(e) => warn!("could not persist graph token: {e:#}"),
                }
                *self.token.lock().await = Some(tok);
                break;
            }
        }
        // The token (on success) is already stored: clear the prompt only now.
        *self.pending_prompt.lock().await = None;
        *self.device_flow_active.lock().await = false;
    }
}

// ── m365 CLI token acquisition ────────────────────────────────────────────────

/// Try to get a Graph access token by shelling out to the `m365` CLI.
///
/// Runs: `m365 util accesstoken get --resource https://graph.microsoft.com`
/// Returns `None` if m365 is not installed, not authenticated, or returns an error.
async fn try_m365_token() -> Option<TokenState> {
    let output = tokio::process::Command::new("m365")
        .args([
            "util",
            "accesstoken",
            "get",
            "--resource",
            "https://graph.microsoft.com",
        ])
        .output()
        .await
        .ok()?;

    if !output.status.success() {
        debug!("m365 accesstoken get failed (exit {})", output.status);
        return None;
    }

    // The command outputs a raw JWT string (may be wrapped in quotes or have
    // trailing whitespace/newlines).
    let raw = String::from_utf8(output.stdout).ok()?;
    let token_str = raw.trim().trim_matches('"').to_owned();

    if token_str.is_empty() {
        return None;
    }

    // Decode the JWT payload (middle segment) to read the `exp` claim.
    let expires_at =
        jwt_expiry(&token_str).unwrap_or_else(|| Utc::now() + ChronoDuration::seconds(45 * 60));

    Some(TokenState {
        access_token: token_str,
        refresh_token: None, // m365 handles its own refresh
        expires_at,
    })
}

/// Parse the `exp` Unix timestamp out of a JWT payload without a crypto library.
fn jwt_expiry(token: &str) -> Option<DateTime<Utc>> {
    use base64::Engine;
    let payload_b64 = token.split('.').nth(1)?;
    // JWT uses base64url without padding.
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload_b64)
        .ok()?;
    let json: serde_json::Value = serde_json::from_slice(&bytes).ok()?;
    let exp = json.get("exp")?.as_i64()?;
    DateTime::from_timestamp(exp, 0)
}

// ── Token persistence ─────────────────────────────────────────────────────────

fn load_cached_token(path: &Path) -> Option<TokenState> {
    let data = std::fs::read_to_string(path).ok()?;
    let tok: TokenState = serde_json::from_str(&data)
        .map_err(|e| warn!("ignoring malformed token cache: {e}"))
        .ok()?;
    Some(tok)
}

fn persist_token(path: &Path, tok: &TokenState) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("creating token cache dir {}", parent.display()))?;
        // Set directory permissions to 0700.
        std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700))
            .with_context(|| format!("setting permissions on {}", parent.display()))?;
    }

    let data = serde_json::to_string_pretty(tok).context("serialising token")?;

    // Write to a temp file then rename for atomicity.
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, &data).with_context(|| format!("writing token to {}", tmp.display()))?;
    std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600))
        .with_context(|| format!("setting permissions on {}", tmp.display()))?;
    std::fs::rename(&tmp, path)
        .with_context(|| format!("renaming token file to {}", path.display()))?;

    debug!("graph token cached at {}", path.display());
    Ok(())
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Pass a successful response through; turn anything else into a typed
/// `GraphHttpError` carrying the server's `Retry-After`.
async fn ensure_success(resp: reqwest::Response, url: &str) -> Result<reqwest::Response> {
    let status = resp.status();
    if status.is_success() {
        return Ok(resp);
    }
    let retry_after = resp
        .headers()
        .get(reqwest::header::RETRY_AFTER)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| parse_retry_after(v, Utc::now()));
    let body = resp.text().await.unwrap_or_default();
    Err(GraphHttpError { status, url: url.to_owned(), body, retry_after }.into())
}

/// The `value` array of a collection page. A page without one (including a
/// 200 whose body is an error object) is an error, never an empty page.
fn page_values<'a>(page: &'a serde_json::Value, url: &str) -> Result<&'a Vec<serde_json::Value>> {
    page.get("value")
        .and_then(|v| v.as_array())
        .with_context(|| format!("Graph page has no `value` array: {url}"))
}

impl GraphClient {
    fn absolute_url(&self, path_or_url: &str) -> String {
        if path_or_url.starts_with("http") {
            path_or_url.to_owned()
        } else {
            format!("{}{path_or_url}", self.opts.graph_base)
        }
    }
}

#[cfg(test)]
mod tests {
    /// Contract §9 (least privilege): the daemon only ever reads from Graph.
    /// The only non-GET requests in this file are the OAuth token / device-code
    /// POSTs; nothing here may PUT, PATCH or DELETE, and every `.post(` must be
    /// aimed at an `oauth2/v2.0` endpoint.
    #[test]
    fn graph_client_only_issues_get_requests_to_graph_and_posts_only_to_oauth() {
        let src = include_str!("graph_client.rs");
        let code = src.split("#[cfg(test)]").next().expect("source before tests");
        for verb in [".put(", ".patch(", ".delete(", ".request("] {
            assert!(!code.contains(verb), "graph_client.rs must not use {verb}");
        }
        let lines: Vec<&str> = code.lines().collect();
        let mut posts = 0;
        for (i, line) in lines.iter().enumerate() {
            if line.contains(".post(") {
                posts += 1;
                let context = lines[i.saturating_sub(20)..i].join("\n");
                assert!(
                    context.contains("oauth2/v2.0"),
                    "POST at line {} is not aimed at an OAuth endpoint",
                    i + 1
                );
            }
        }
        assert!(posts >= 1, "expected the OAuth POSTs to be found");
        assert!(code.contains(".get(url)"), "Graph reads must use GET");
    }
}
