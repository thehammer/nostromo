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
const SCOPES: &str = "Mail.Read Calendars.Read offline_access";

// ── Public types ─────────────────────────────────────────────────────────────

/// Rendered in the Fred mailbox panel when auth is required.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceFlowPrompt {
    pub verification_uri: String,
    pub user_code: String,
    pub expires_at: DateTime<Utc>,
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
}

impl GraphClient {
    /// Create a new client, loading any cached token from `cache_path`.
    pub async fn new(client_id: String, tenant: String, cache_path: PathBuf) -> Result<Self> {
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
        })
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

        if let Some(tok) = try_m365_token().await {
            info!("graph token acquired via m365 CLI");
            persist_token(&self.cache_path, &tok)?;
            *self.token.lock().await = Some(tok);
            return Ok(None);
        }

        {
            let active = self.device_flow_active.lock().await;
            if *active {
                return Ok(None);
            }
        }
        let prompt = self.start_device_flow().await?;
        Ok(Some(prompt))
    }

    /// Fetch a JSON resource from Graph (full URL or path under GRAPH_BASE).
    pub async fn get_json<T: DeserializeOwned>(&self, url: &str) -> Result<T> {
        let url = absolute_url(url);
        let resp = self.authenticated_get(&url).await?;

        if resp.status() == reqwest::StatusCode::UNAUTHORIZED {
            // Attempt a single refresh-and-retry.
            self.refresh_once().await?;
            let resp2 = self.authenticated_get(&url).await?;
            return resp2
                .json::<T>()
                .await
                .context("deserialising Graph JSON after refresh");
        }

        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            bail!("Graph GET {url} -> {status}: {body}");
        }

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
                .unwrap_or_else(|_| absolute_url(initial_path))
                .trim()
                .to_owned()
        } else {
            absolute_url(initial_path)
        };

        let mut items: Vec<T> = Vec::new();
        let mut next_url: Option<String> = Some(start_url);
        let mut delta_link = String::new();

        while let Some(url) = next_url.take() {
            let page: serde_json::Value = self
                .get_json(&url)
                .await
                .with_context(|| format!("delta fetch {url}"))?;

            if let Some(arr) = page.get("value").and_then(|v| v.as_array()) {
                for item in arr {
                    match serde_json::from_value::<T>(item.clone()) {
                        Ok(t) => items.push(t),
                        Err(e) => warn!("skipping delta item, deserialise error: {e}"),
                    }
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
        let mut next_url: Option<String> = Some(absolute_url(initial_path));

        while let Some(url) = next_url.take() {
            let page: serde_json::Value = self
                .get_json(&url)
                .await
                .with_context(|| format!("paged fetch {url}"))?;

            if let Some(arr) = page.get("value").and_then(|v| v.as_array()) {
                for item in arr {
                    match serde_json::from_value::<T>(item.clone()) {
                        Ok(t) => items.push(t),
                        Err(e) => warn!("skipping paged item, deserialise error: {e}"),
                    }
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

    async fn authenticated_get(&self, url: &str) -> Result<reqwest::Response> {
        let token = {
            let guard = self.token.lock().await;
            guard
                .as_ref()
                .map(|t| t.access_token.clone())
                .unwrap_or_default()
        };

        self.http
            .get(url)
            .bearer_auth(&token)
            .send()
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
        let url = format!("{LOGIN_BASE}/{}/oauth2/v2.0/token", self.tenant);
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
        let url = format!("{LOGIN_BASE}/{}/oauth2/v2.0/devicecode", self.tenant);
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

        *self.device_flow_active.lock().await = true;

        // Spawn background poll task.
        let client = self.clone();
        let device_code = dc.device_code.clone();
        let poll_interval = dc.interval.max(5);
        tokio::spawn(async move {
            client.poll_device_code(&device_code, poll_interval).await;
        });

        Ok(prompt)
    }

    async fn poll_device_code(&self, device_code: &str, interval_secs: u64) {
        let url = format!("{LOGIN_BASE}/{}/oauth2/v2.0/token", self.tenant);
        let params = [
            ("client_id", self.client_id.as_str()),
            ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
            ("device_code", device_code),
        ];

        loop {
            tokio::time::sleep(std::time::Duration::from_secs(interval_secs)).await;

            let resp: TokenResponse = match self
                .http
                .post(&url)
                .form(&params)
                .send()
                .await
                .and_then(|r| r.error_for_status())
            {
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

fn absolute_url(path_or_url: &str) -> String {
    if path_or_url.starts_with("http") {
        path_or_url.to_owned()
    } else {
        format!("{GRAPH_BASE}{path_or_url}")
    }
}
