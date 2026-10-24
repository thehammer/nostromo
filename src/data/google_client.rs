//! Google (Gmail + Calendar) API client with desktop loopback + PKCE OAuth.
//!
//! # Auth lifecycle
//! Google's device-code flow does not allow Gmail or Calendar scopes, so each
//! account signs in once through the desktop loopback flow: the client binds a
//! listener on `127.0.0.1:<random port>`, hands the UI an auth URL
//! ([`DeviceFlowPrompt`] with `kind = "browser"`), and the browser's redirect
//! lands on that listener. The code is exchanged (PKCE S256 + client secret)
//! and the token is written to the account's token file (mode 0600, parent
//! directory 0700). The `nostromo-google-auth` CLI runs the same flow.
//!
//! The listener only works on the machine running the daemon.
//!
//! # Read only
//! Scopes are `gmail.readonly` and `calendar.readonly`. The only non-GET
//! requests in this file are the OAuth token POSTs.
//!
//! # Privacy
//! Logs carry counts, labels, states and status codes only. Never subjects,
//! senders, ids, emails, auth URLs, codes, tokens or response bodies.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use chrono::{DateTime, Duration as ChronoDuration, Utc};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{watch, Mutex};
use tracing::{debug, info, warn};

use crate::config::FredAccount;
use crate::data::graph_client::DeviceFlowPrompt;
use crate::data::http_backoff::parse_retry_after;
use crate::data::token_store;

pub const AUTH_URL: &str = "https://accounts.google.com/o/oauth2/v2/auth";
pub const TOKEN_URL: &str = "https://oauth2.googleapis.com/token";
pub const GMAIL_BASE: &str = "https://gmail.googleapis.com/gmail/v1";
pub const CALENDAR_BASE: &str = "https://www.googleapis.com/calendar/v3";
pub const SCOPES: &str =
    "https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/calendar.readonly";
pub const LOOPBACK_TTL: Duration = Duration::from_secs(10 * 60);

const CALLBACK_PATH: &str = "/oauth2/callback";
/// Longest request head the loopback listener reads.
const MAX_REQUEST_HEAD: usize = 8 * 1024;
/// How long one loopback connection may take to send its request line.
const CONNECTION_READ_TIMEOUT: Duration = Duration::from_secs(5);

// ── OAuth client file ─────────────────────────────────────────────────────────

/// The Google OAuth client (Desktop app) from the downloaded JSON file. The
/// secret lives in that file, not in `Config` (which derives `Debug`).
#[derive(Clone)]
pub struct GoogleOAuthClient {
    pub client_id: String,
    pub client_secret: String,
}

impl std::fmt::Debug for GoogleOAuthClient {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("GoogleOAuthClient")
            .field("client_id", &self.client_id)
            .field("client_secret", &"<redacted>")
            .finish()
    }
}

impl GoogleOAuthClient {
    pub fn new(client_id: impl Into<String>, client_secret: impl Into<String>) -> Self {
        Self { client_id: client_id.into(), client_secret: client_secret.into() }
    }

    /// Load Google's downloaded `{"installed": {...}}` JSON. The error never
    /// carries the file's contents.
    pub fn load(path: &Path) -> Result<Self> {
        let data = std::fs::read_to_string(path)
            .with_context(|| format!("reading Google OAuth client file {}", path.display()))?;
        Self::from_json(&data)
    }

    pub fn from_json(data: &str) -> Result<Self> {
        #[derive(Deserialize)]
        struct Inner {
            client_id: String,
            client_secret: String,
        }
        #[derive(Deserialize)]
        struct File {
            installed: Option<Inner>,
            web: Option<serde_json::Value>,
        }
        let file: File = serde_json::from_str(data)
            .map_err(|e| anyhow!("not a Google OAuth client file ({:?})", e.classify()))?;
        match file {
            File { installed: Some(i), .. } if !i.client_id.is_empty() && !i.client_secret.is_empty() => {
                Ok(Self { client_id: i.client_id, client_secret: i.client_secret })
            }
            File { installed: None, web: Some(_) } => bail!("use a Desktop app client, not a Web application client"),
            _ => bail!("no installed client_id/client_secret in the Google OAuth client file"),
        }
    }
}

// ── Options ───────────────────────────────────────────────────────────────────

/// Where the client talks to. `Default` is production; tests point the URLs at
/// a mock server.
#[derive(Debug, Clone)]
pub struct GoogleOptions {
    pub auth_url: String,
    pub token_url: String,
    pub gmail_base: String,
    pub calendar_base: String,
    pub loopback_ttl: Duration,
    /// Open the sign-in URL in the browser (macOS `open`). The daemon never
    /// does; only the CLI.
    pub open_browser: bool,
}

impl Default for GoogleOptions {
    fn default() -> Self {
        Self {
            auth_url: AUTH_URL.to_owned(),
            token_url: TOKEN_URL.to_owned(),
            gmail_base: GMAIL_BASE.to_owned(),
            calendar_base: CALENDAR_BASE.to_owned(),
            loopback_ttl: LOOPBACK_TTL,
            open_browser: false,
        }
    }
}

// ── Errors ────────────────────────────────────────────────────────────────────

/// A non-success HTTP answer from Google. Typed so callers can turn it into a
/// plain-English reason (`downcast_ref` works through `anyhow` context). The
/// response body is not kept.
#[derive(Debug)]
pub struct GoogleHttpError {
    pub status: reqwest::StatusCode,
    /// Request path without the query string.
    pub path: String,
    /// `error.errors[0].reason` or `error.status` from the body.
    pub reason: Option<String>,
    /// The server's `Retry-After` (already capped), when it sent a usable one.
    pub retry_after: Option<Duration>,
}

impl GoogleHttpError {
    /// Google is throttling us: 429, a rate-limit 403, or a 503 that says when
    /// to come back.
    pub fn is_throttle(&self) -> bool {
        self.status == reqwest::StatusCode::TOO_MANY_REQUESTS
            || (self.status == reqwest::StatusCode::FORBIDDEN
                && matches!(self.reason.as_deref(), Some("rateLimitExceeded" | "userRateLimitExceeded")))
            || (self.status == reqwest::StatusCode::SERVICE_UNAVAILABLE && self.retry_after.is_some())
    }
}

impl std::fmt::Display for GoogleHttpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Google GET {} -> {}", self.path, self.status.as_u16())?;
        if let Some(reason) = &self.reason {
            write!(f, " ({reason})")?;
        }
        Ok(())
    }
}

impl std::error::Error for GoogleHttpError {}

/// The refresh token was rejected (revoked, expired, password changed).
#[derive(Debug)]
struct InvalidGrant;

impl std::fmt::Display for InvalidGrant {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Google rejected the refresh token (invalid_grant)")
    }
}

impl std::error::Error for InvalidGrant {}

/// A short plain-English reason for a failed Google fetch, safe to show in the
/// UI and MCP results: no URLs, response bodies or tokens.
pub fn failure_reason(what: &str, e: &anyhow::Error) -> String {
    if let Some(http) = e.downcast_ref::<GoogleHttpError>() {
        let code = http.status.as_u16();
        if http.is_throttle() {
            return format!("{what}: Google is rate limiting requests ({code})");
        }
        return match code {
            401 => format!("{what}: Google rejected the sign-in (401); sign-in will be retried"),
            403 => format!("{what}: Google denied access (403)"),
            500..=599 => format!("{what}: Google is unavailable ({code})"),
            _ => format!("{what}: unexpected response from Google"),
        };
    }
    if e.chain().any(|c| c.downcast_ref::<reqwest::Error>().is_some_and(|r| r.is_connect() || r.is_timeout())) {
        return format!("{what}: could not reach Google");
    }
    format!("{what}: unexpected response from Google")
}

// ── Token state ───────────────────────────────────────────────────────────────

#[derive(Clone, Serialize, Deserialize)]
struct GoogleToken {
    access_token: String,
    refresh_token: Option<String>,
    #[serde(with = "chrono::serde::ts_seconds")]
    expires_at: DateTime<Utc>,
    #[serde(default)]
    email: Option<String>,
}

impl std::fmt::Debug for GoogleToken {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("GoogleToken")
            .field("access_token", &"<redacted>")
            .field("refresh_token", &self.refresh_token.as_ref().map(|_| "<redacted>"))
            .field("expires_at", &self.expires_at)
            .field("email", &self.email)
            .finish()
    }
}

impl GoogleToken {
    fn is_expired(&self) -> bool {
        Utc::now() >= self.expires_at - ChronoDuration::seconds(60)
    }
}

#[derive(Deserialize)]
struct TokenResponse {
    access_token: Option<String>,
    refresh_token: Option<String>,
    expires_in: Option<u64>,
    error: Option<String>,
}

/// How a loopback flow ended: the signed-in email, or a plain-English reason.
type FlowOutcome = Result<String, String>;

struct PendingLoopback {
    /// The flow's `state` value, so a finished flow only clears its own entry.
    state: String,
    prompt: DeviceFlowPrompt,
    outcome: watch::Receiver<Option<FlowOutcome>>,
    handle: tokio::task::JoinHandle<()>,
}

// ── GoogleClient ──────────────────────────────────────────────────────────────

#[derive(Clone)]
pub struct GoogleClient {
    http: reqwest::Client,
    label: String,
    oauth: Arc<GoogleOAuthClient>,
    expected_email: Option<String>,
    token: Arc<Mutex<Option<GoogleToken>>>,
    /// A refresh token Google rejected: not retried until the file changes.
    rejected_refresh: Arc<std::sync::Mutex<Option<String>>>,
    cache_path: PathBuf,
    pending: Arc<Mutex<Option<PendingLoopback>>>,
    opts: GoogleOptions,
}

impl GoogleClient {
    /// A client for one account, loading any cached token from `cache_path`.
    pub fn with_options(
        label: String,
        expected_email: Option<String>,
        oauth: GoogleOAuthClient,
        cache_path: PathBuf,
        opts: GoogleOptions,
    ) -> Result<Self> {
        let http = reqwest::Client::builder()
            .user_agent(concat!("nostromo/", env!("CARGO_PKG_VERSION")))
            .timeout(Duration::from_secs(30))
            .build()
            .context("building reqwest client")?;
        let expected_email = expected_email.map(|e| e.to_lowercase());
        // Same identity rule as a later disk pick-up (`identity_ok`): another
        // account's token file is never used.
        let token = token_store::load::<GoogleToken>(&cache_path)
            .filter(|t| email_matches(expected_email.as_deref(), t.email.as_deref()));
        Ok(Self {
            http,
            label,
            oauth: Arc::new(oauth),
            expected_email,
            token: Arc::new(Mutex::new(token)),
            rejected_refresh: Arc::new(std::sync::Mutex::new(None)),
            cache_path,
            pending: Arc::new(Mutex::new(None)),
            opts,
        })
    }

    /// The process-wide client for `(label, token file)`. The mailbox and
    /// calendar sources of one account both call this so they share one token
    /// and one sign-in.
    pub fn shared(account: &FredAccount, oauth: GoogleOAuthClient, opts: GoogleOptions) -> Result<Self> {
        type Key = (String, PathBuf);
        static REGISTRY: std::sync::OnceLock<std::sync::Mutex<HashMap<Key, GoogleClient>>> =
            std::sync::OnceLock::new();
        let registry = REGISTRY.get_or_init(Default::default);
        let key = (account.label.clone(), account.token_cache.clone());
        if let Some(existing) = registry.lock().expect("google registry").get(&key) {
            return Ok(existing.clone());
        }
        let client = Self::with_options(
            account.label.clone(),
            account.email.clone(),
            oauth,
            account.token_cache.clone(),
            opts,
        )?;
        Ok(registry
            .lock()
            .expect("google registry")
            .entry(key)
            .or_insert(client)
            .clone())
    }

    pub fn label(&self) -> &str {
        &self.label
    }

    /// The email recorded in the stored token (set at sign-in), if any.
    pub async fn stored_email(&self) -> Option<String> {
        self.token.lock().await.as_ref().and_then(|t| t.email.clone())
    }

    /// `{gmail_base}{path}`; `path` may carry an already-encoded query.
    pub fn gmail_url(&self, path: &str) -> String {
        format!("{}{path}", self.opts.gmail_base)
    }

    /// `{calendar_base}{path}`; `path` may carry an already-encoded query.
    pub fn calendar_url(&self, path: &str) -> String {
        format!("{}{path}", self.opts.calendar_base)
    }

    /// Ensure the client is authenticated.
    ///
    /// `None` when a usable token is present (refreshing it if needed).
    /// `Some(prompt)` when the user must open the sign-in URL; a background
    /// listener completes the flow and stores the token.
    pub async fn ensure_authed(&self) -> Result<Option<DeviceFlowPrompt>> {
        // Held throughout so two sources sharing this client cannot both
        // refresh, or both start a loopback flow.
        let mut guard = self.token.lock().await;

        if let Some(tok) = guard.clone() {
            if !tok.is_expired() {
                return Ok(None);
            }
            match self.refresh_token(&tok).await? {
                Some(new_tok) => {
                    self.store(&mut guard, new_tok);
                    return Ok(None);
                }
                None => *guard = None,
            }
        }

        // The CLI may have written the token file since we last looked.
        if let Some(tok) = token_store::load::<GoogleToken>(&self.cache_path)
            .filter(|t| self.identity_ok(t) && !self.is_rejected(t))
        {
            let picked_up = if tok.is_expired() {
                match self.refresh_token(&tok).await? {
                    Some(fresh) => {
                        self.store(&mut guard, fresh);
                        true
                    }
                    None => false,
                }
            } else {
                *guard = Some(tok);
                true
            };
            if picked_up {
                if let Some(p) = self.pending.lock().await.take() {
                    p.handle.abort();
                }
                return Ok(None);
            }
        }

        let mut pending = self.pending.lock().await;
        if let Some(p) = pending.as_ref() {
            if p.prompt.expires_at > Utc::now() && !p.handle.is_finished() {
                return Ok(Some(p.prompt.clone()));
            }
        }
        Ok(Some(self.replace_pending(&mut pending).await?))
    }

    /// Start a loopback sign-in and return its prompt (no browser is opened
    /// unless `open_browser` is set). Pair with [`wait_loopback`](Self::wait_loopback).
    pub async fn start_loopback(&self) -> Result<DeviceFlowPrompt> {
        let mut pending = self.pending.lock().await;
        self.replace_pending(&mut pending).await
    }

    /// Wait for the loopback flow in flight to end. `Ok(email)` on success,
    /// otherwise a plain-English reason.
    pub async fn wait_loopback(&self) -> Result<String> {
        let mut outcome = {
            let pending = self.pending.lock().await;
            pending.as_ref().map(|p| p.outcome.clone()).context("no sign-in in progress")?
        };
        loop {
            if let Some(result) = outcome.borrow().clone() {
                return result.map_err(|reason| anyhow!(reason));
            }
            if outcome.changed().await.is_err() {
                bail!("sign-in ended without a result");
            }
        }
    }

    /// Start the flow, hand the prompt to `on_prompt` (the CLI prints the URL),
    /// then wait until it ends.
    pub async fn run_loopback_until_done(&self, on_prompt: impl FnOnce(&DeviceFlowPrompt)) -> Result<String> {
        let prompt = self.start_loopback().await?;
        on_prompt(&prompt);
        self.wait_loopback().await
    }

    /// Fetch a JSON resource from Google (a full URL, see
    /// [`gmail_url`](Self::gmail_url) / [`calendar_url`](Self::calendar_url)).
    ///
    /// A 401 gets one refresh-and-retry; if that refresh fails the token is
    /// forgotten and a 401 [`GoogleHttpError`] is returned. Both answers go
    /// through the same status check, so a failed retry is never read as data.
    pub async fn get_json<T: DeserializeOwned>(&self, url: &str) -> Result<T> {
        let mut resp = self.authenticated_get(url).await?;

        if resp.status() == reqwest::StatusCode::UNAUTHORIZED {
            if let Err(e) = self.refresh_once().await {
                *self.token.lock().await = None;
                return Err(e.context(GoogleHttpError {
                    status: reqwest::StatusCode::UNAUTHORIZED,
                    path: url_path(url),
                    reason: None,
                    retry_after: None,
                }));
            }
            resp = self.authenticated_get(url).await?;
        }

        let resp = ensure_success(resp, url).await?;
        parse_json(&resp.bytes().await.context("reading Google response")?)
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    /// Abort any flow in `pending`, start a new one and record it. Returns its prompt.
    async fn replace_pending(&self, pending: &mut Option<PendingLoopback>) -> Result<DeviceFlowPrompt> {
        if let Some(old) = pending.take() {
            old.handle.abort();
        }
        let started = self.begin_loopback().await?;
        let prompt = started.prompt.clone();
        *pending = Some(started);
        Ok(prompt)
    }

    /// Persist (best effort) and set the in-memory token.
    fn store(&self, slot: &mut Option<GoogleToken>, tok: GoogleToken) {
        if let Err(e) = token_store::persist(&self.cache_path, &tok) {
            warn!("could not persist google token for '{}': {e:#}", self.label);
        }
        *slot = Some(tok);
    }

    fn identity_ok(&self, tok: &GoogleToken) -> bool {
        email_matches(self.expected_email.as_deref(), tok.email.as_deref())
    }

    /// Google already rejected this token's refresh token.
    fn is_rejected(&self, tok: &GoogleToken) -> bool {
        tok.refresh_token.is_some()
            && *self.rejected_refresh.lock().expect("rejected refresh") == tok.refresh_token
    }

    /// Refresh `tok`. `Ok(None)` when Google rejected the refresh token
    /// (`invalid_grant`) or it already did: sign-in is needed. `Err` is
    /// transient.
    async fn refresh_token(&self, tok: &GoogleToken) -> Result<Option<GoogleToken>> {
        let Some(rt) = tok.refresh_token.as_deref() else { return Ok(None) };
        if self.rejected_refresh.lock().expect("rejected refresh").as_deref() == Some(rt) {
            return Ok(None);
        }
        match self.do_refresh(rt, tok.email.clone()).await {
            Ok(new_tok) => Ok(Some(new_tok)),
            Err(e) if e.downcast_ref::<InvalidGrant>().is_some() => {
                warn!("google refresh token for '{}' was rejected; sign-in needed", self.label);
                *self.rejected_refresh.lock().expect("rejected refresh") = Some(rt.to_owned());
                Ok(None)
            }
            Err(e) => Err(e),
        }
    }

    async fn authenticated_get(&self, url: &str) -> Result<reqwest::Response> {
        let token = self.token.lock().await.as_ref().map(|t| t.access_token.clone()).unwrap_or_default();
        self.get_with_token(url, &token).await
    }

    async fn get_with_token(&self, url: &str, access_token: &str) -> Result<reqwest::Response> {
        self.http
            .get(url)
            .bearer_auth(access_token)
            .send()
            .await
            .context("Google GET request failed")
    }

    async fn refresh_once(&self) -> Result<()> {
        let (refresh_token, email) = {
            let guard = self.token.lock().await;
            let tok = guard.as_ref().context("no token to refresh")?;
            (tok.refresh_token.clone().context("no refresh token available")?, tok.email.clone())
        };
        let new_tok = match self.do_refresh(&refresh_token, email).await {
            Ok(tok) => tok,
            Err(e) => {
                if e.downcast_ref::<InvalidGrant>().is_some() {
                    *self.rejected_refresh.lock().expect("rejected refresh") = Some(refresh_token);
                }
                return Err(e);
            }
        };
        let mut guard = self.token.lock().await;
        self.store(&mut guard, new_tok);
        Ok(())
    }

    async fn do_refresh(&self, refresh_token: &str, email: Option<String>) -> Result<GoogleToken> {
        let params = [
            ("client_id", self.oauth.client_id.as_str()),
            ("client_secret", self.oauth.client_secret.as_str()),
            ("refresh_token", refresh_token),
            ("grant_type", "refresh_token"),
        ];
        let resp = self.post_token(&params).await?;
        // Google usually omits `refresh_token` from refresh responses: keep
        // the one we have (and the recorded email).
        Ok(GoogleToken {
            access_token: required_access_token(&resp)?,
            expires_at: expiry(&resp),
            refresh_token: resp.refresh_token.or_else(|| Some(refresh_token.to_owned())),
            email,
        })
    }

    /// POST to the token endpoint. The JSON body decides (Google answers
    /// `invalid_grant` with HTTP 400 and an `error` field).
    async fn post_token(&self, params: &[(&str, &str)]) -> Result<TokenResponse> {
        let bytes = self
            .http
            .post(&self.opts.token_url)
            .form(params)
            .send()
            .await
            .context("Google token request failed")?
            .bytes()
            .await
            .context("reading Google token response")?;
        let resp: TokenResponse = parse_json(&bytes)?;
        match resp.error.as_deref() {
            Some("invalid_grant") => Err(InvalidGrant.into()),
            Some(code) => bail!("Google token endpoint error ({code})"),
            None => Ok(resp),
        }
    }

    // ── Loopback flow ─────────────────────────────────────────────────────────

    async fn begin_loopback(&self) -> Result<PendingLoopback> {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.context("binding loopback listener")?;
        let port = listener.local_addr().context("loopback listener address")?.port();
        let redirect_uri = format!("http://127.0.0.1:{port}{CALLBACK_PATH}");

        let (challenge, verifier) = oauth2::PkceCodeChallenge::new_random_sha256();
        let state = oauth2::CsrfToken::new_random().secret().to_owned();

        let mut url = url::Url::parse(&self.opts.auth_url).context("parsing Google auth URL")?;
        {
            let mut q = url.query_pairs_mut();
            q.append_pair("client_id", &self.oauth.client_id)
                .append_pair("redirect_uri", &redirect_uri)
                .append_pair("response_type", "code")
                .append_pair("scope", SCOPES)
                .append_pair("code_challenge", challenge.as_str())
                .append_pair("code_challenge_method", "S256")
                .append_pair("state", &state)
                .append_pair("access_type", "offline")
                .append_pair("prompt", "consent");
            if let Some(email) = &self.expected_email {
                q.append_pair("login_hint", email);
            }
        }

        let expires_at = Utc::now() + ChronoDuration::from_std(self.opts.loopback_ttl).unwrap_or_default();
        let prompt = DeviceFlowPrompt {
            verification_uri: url.to_string(),
            user_code: String::new(),
            expires_at,
            kind: "browser".to_owned(),
            account: Some(self.label.clone()),
            provider: Some("google".to_owned()),
        };

        if self.opts.open_browser {
            open_in_browser(prompt.verification_uri.as_str());
        }

        let (tx, rx) = watch::channel(None);
        let flow = Flow {
            state: state.clone(),
            verifier: verifier.secret().to_owned(),
            redirect_uri,
            deadline: tokio::time::Instant::now() + self.opts.loopback_ttl,
        };
        let client = self.clone();
        let handle = tokio::spawn(async move {
            let outcome = client.run_listener(listener, &flow).await;
            // The token (on success) is stored; only now publish the result and
            // clear our pending entry (a newer flow's entry is left alone).
            let _ = tx.send(Some(outcome));
            let mut pending = client.pending.lock().await;
            if pending.as_ref().is_some_and(|p| p.state == flow.state) {
                pending.take();
            }
        });
        info!("google sign-in listener started for '{}' on port {port}", self.label);
        Ok(PendingLoopback { state, prompt, outcome: rx, handle })
    }

    async fn run_listener(&self, listener: TcpListener, flow: &Flow) -> FlowOutcome {
        loop {
            let accepted = match tokio::time::timeout_at(flow.deadline, listener.accept()).await {
                Ok(Ok((stream, _))) => stream,
                Ok(Err(e)) => {
                    debug!("loopback accept failed: {:?}", e.kind());
                    continue;
                }
                Err(_) => return Err("The sign-in link expired".to_owned()),
            };
            if let Some(outcome) = self.handle_connection(accepted, flow).await {
                return outcome;
            }
        }
    }

    /// Answer one loopback connection. `Some(outcome)` ends the flow.
    async fn handle_connection(&self, mut stream: TcpStream, flow: &Flow) -> Option<FlowOutcome> {
        let Some(head) = read_request_head(&mut stream).await else {
            respond(&mut stream, 400, "Bad request", "Bad request.").await;
            return None;
        };
        let request_line = head.lines().next().unwrap_or("");
        let mut parts = request_line.split(' ');
        let (method, target, version) = (parts.next(), parts.next(), parts.next());
        let (Some("GET"), Some(target), Some(version)) = (method, target, version) else {
            respond(&mut stream, 404, "Not found", "Not found.").await;
            return None;
        };
        let (path, query) = target.split_once('?').unwrap_or((target, ""));
        if !version.starts_with("HTTP/1.") || path != CALLBACK_PATH {
            respond(&mut stream, 404, "Not found", "Not found.").await;
            return None;
        }

        let params: HashMap<String, String> = url::form_urlencoded::parse(query.as_bytes()).into_owned().collect();
        if params.get("state") != Some(&flow.state) {
            // A stray or forged hit: refuse it and keep waiting for the real one.
            respond(&mut stream, 400, "Bad request", "This sign-in link does not match. Please use the link from Nostromo.").await;
            return None;
        }
        if params.contains_key("error") {
            respond(&mut stream, 200, "OK", "Sign-in was cancelled. You can close this tab.").await;
            return Some(Err("Sign-in was cancelled".to_owned()));
        }
        let Some(code) = params.get("code") else {
            respond(&mut stream, 400, "Bad request", "Missing sign-in code.").await;
            return None;
        };

        match self.complete_sign_in(code, flow).await {
            Ok(email) => {
                let page = format!("Nostromo: {} is signed in. You can close this tab.", self.label);
                respond(&mut stream, 200, "OK", &page).await;
                Some(Ok(email))
            }
            Err(reason) => {
                respond(&mut stream, 200, "OK", &reason).await;
                Some(Err(reason))
            }
        }
    }

    /// Exchange the code, verify the account, then store the token. The error
    /// is a plain-English reason shown in the browser and the UI.
    async fn complete_sign_in(&self, code: &str, flow: &Flow) -> Result<String, String> {
        let params = [
            ("code", code),
            ("client_id", self.oauth.client_id.as_str()),
            ("client_secret", self.oauth.client_secret.as_str()),
            ("code_verifier", flow.verifier.as_str()),
            ("redirect_uri", flow.redirect_uri.as_str()),
            ("grant_type", "authorization_code"),
        ];
        let resp = self.post_token(&params).await.map_err(|e| {
            warn!("google code exchange failed for '{}'", self.label);
            debug!("code exchange error chain length {}", e.chain().count());
            "Google did not accept the sign-in. Please try again.".to_owned()
        })?;
        let access_token = required_access_token(&resp).map_err(|_| "Google did not return a token.".to_owned())?;

        // Learn who signed in before anything is persisted.
        let email = self.fetch_profile_email(&access_token).await.map_err(|e| {
            warn!("google profile lookup failed for '{}': {}", self.label, failure_reason("profile", &e));
            "Could not confirm which Google account signed in.".to_owned()
        })?;
        if let Some(want) = &self.expected_email {
            if !want.eq_ignore_ascii_case(&email) {
                warn!("google sign-in for '{}' used a different account than configured", self.label);
                return Err(format!("Signed in as the wrong Google account for '{}'", self.label));
            }
        }

        let tok = GoogleToken {
            access_token,
            refresh_token: resp.refresh_token.clone(),
            expires_at: expiry(&resp),
            email: Some(email.clone()),
        };
        if tok.refresh_token.is_none() {
            warn!("google returned no refresh token for '{}'", self.label);
        }
        *self.rejected_refresh.lock().expect("rejected refresh") = None;
        let mut guard = self.token.lock().await;
        self.store(&mut guard, tok);
        Ok(email)
    }

    async fn fetch_profile_email(&self, access_token: &str) -> Result<String> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Profile {
            email_address: String,
        }
        let url = self.gmail_url("/users/me/profile");
        let resp = ensure_success(self.get_with_token(&url, access_token).await?, &url).await?;
        let profile: Profile = parse_json(&resp.bytes().await.context("reading Google profile")?)?;
        Ok(profile.email_address)
    }
}

/// One loopback flow's secrets and deadline.
struct Flow {
    state: String,
    verifier: String,
    redirect_uri: String,
    deadline: tokio::time::Instant,
}

// ── Free helpers ──────────────────────────────────────────────────────────────

/// Append `pairs` (URL-encoded) to `path` as a query string.
pub fn with_query(path: &str, pairs: &[(&str, &str)]) -> String {
    let mut ser = url::form_urlencoded::Serializer::new(String::new());
    for (k, v) in pairs {
        ser.append_pair(k, v);
    }
    let sep = if path.contains('?') { '&' } else { '?' };
    format!("{path}{sep}{}", ser.finish())
}

/// Percent-encode one URL path segment (message and event ids).
pub fn encode_segment(segment: &str) -> String {
    url::form_urlencoded::byte_serialize(segment.as_bytes()).collect::<String>().replace('+', "%20")
}

/// A token file is only used when its recorded email (if both are known)
/// matches the configured one.
fn email_matches(expected: Option<&str>, recorded: Option<&str>) -> bool {
    match (expected, recorded) {
        (Some(want), Some(have)) => want.eq_ignore_ascii_case(have),
        _ => true,
    }
}

fn url_path(url: &str) -> String {
    url::Url::parse(url).map(|u| u.path().to_owned()).unwrap_or_default()
}

fn parse_json<T: DeserializeOwned>(bytes: &[u8]) -> Result<T> {
    serde_json::from_slice(bytes).map_err(|e| {
        anyhow!("Google JSON did not parse ({:?} at line {} column {})", e.classify(), e.line(), e.column())
    })
}

fn required_access_token(resp: &TokenResponse) -> Result<String> {
    resp.access_token.clone().context("no access_token in Google token response")
}

fn expiry(resp: &TokenResponse) -> DateTime<Utc> {
    Utc::now() + ChronoDuration::seconds(resp.expires_in.unwrap_or(3600) as i64)
}

/// Pass a successful response through; turn anything else into a typed
/// [`GoogleHttpError`] (the body is read for its reason code and dropped).
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
    let body = resp.bytes().await.unwrap_or_default();
    Err(GoogleHttpError { status, path: url_path(url), reason: error_reason(&body), retry_after }.into())
}

/// `error.errors[0].reason` or `error.status` from a Google error body.
fn error_reason(body: &[u8]) -> Option<String> {
    let v: serde_json::Value = serde_json::from_slice(body).ok()?;
    let error = v.get("error")?;
    error
        .pointer("/errors/0/reason")
        .or_else(|| error.get("status"))
        .and_then(|r| r.as_str())
        .map(str::to_owned)
}

async fn read_request_head(stream: &mut TcpStream) -> Option<String> {
    let read = async {
        let mut buf = Vec::with_capacity(1024);
        let mut chunk = [0u8; 1024];
        while buf.len() < MAX_REQUEST_HEAD && !buf.windows(4).any(|w| w == b"\r\n\r\n") {
            let n = stream.read(&mut chunk).await.ok()?;
            if n == 0 {
                break;
            }
            buf.extend_from_slice(&chunk[..n]);
        }
        buf.truncate(MAX_REQUEST_HEAD);
        Some(String::from_utf8_lossy(&buf).into_owned())
    };
    tokio::time::timeout(CONNECTION_READ_TIMEOUT, read).await.ok().flatten()
}

/// Write a small static HTML page and close. `message` must be a fixed string
/// or built from validated values; it never echoes request values.
async fn respond(stream: &mut TcpStream, status: u16, status_text: &str, message: &str) {
    let body = format!(
        "<!doctype html><html><head><meta charset=\"utf-8\"><title>Nostromo</title></head><body><p>{message}</p></body></html>"
    );
    let response = format!(
        "HTTP/1.1 {status} {status_text}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.write_all(response.as_bytes()).await;
    let _ = stream.shutdown().await;
}

#[cfg(target_os = "macos")]
fn open_in_browser(url: &str) {
    if let Err(e) = std::process::Command::new("open").arg(url).spawn() {
        warn!("could not open the browser: {:?}", e.kind());
    }
}

#[cfg(not(target_os = "macos"))]
fn open_in_browser(_url: &str) {}

#[cfg(test)]
mod tests {
    use super::*;

    /// Least privilege: the daemon only ever reads from Google. The only
    /// non-GET requests are the OAuth token POSTs.
    #[test]
    fn google_client_only_issues_get_requests_and_posts_only_to_the_token_endpoint() {
        let src = include_str!("google_client.rs");
        let code = src.split("#[cfg(test)]").next().expect("source before tests");
        for verb in [".put(", ".patch(", ".delete(", ".request("] {
            assert!(!code.contains(verb), "google_client.rs must not use {verb}");
        }
        let lines: Vec<&str> = code.lines().collect();
        let mut posts = 0;
        for (i, line) in lines.iter().enumerate() {
            if line.contains(".post(") {
                posts += 1;
                let context = lines[i.saturating_sub(20)..=i].join("\n");
                assert!(context.contains("token_url"), "POST at line {} is not aimed at the token URL", i + 1);
            }
        }
        assert!(posts >= 1, "expected the token POST to be found");
    }

    #[test]
    fn oauth_client_file_parses_installed_and_rejects_web() {
        let ok = GoogleOAuthClient::from_json(r#"{"installed":{"client_id":"id","client_secret":"sec"}}"#).unwrap();
        assert_eq!(ok.client_id, "id");
        assert!(!format!("{ok:?}").contains("sec\""));
        let web = GoogleOAuthClient::from_json(r#"{"web":{"client_id":"id","client_secret":"sec"}}"#).unwrap_err();
        assert!(web.to_string().contains("Desktop app"));
        assert!(GoogleOAuthClient::from_json("{}").is_err());
    }

    #[test]
    fn with_query_encodes_and_chains() {
        assert_eq!(with_query("/a", &[("q", "x y")]), "/a?q=x+y");
        assert_eq!(with_query("/a?b=1", &[("c", "&")]), "/a?b=1&c=%26");
    }

    #[test]
    fn encode_segment_escapes_slashes_and_spaces() {
        assert_eq!(encode_segment("a/b c"), "a%2Fb%20c");
    }
}
