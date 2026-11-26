//! The relay's handler (W13): validates a notification from the Nostromo
//! primary, sends it to APNs, and keeps a seven-day delivery record.
//!
//! The relay is **stateless about content**. It stores no device registry and no
//! title, body, host, reference or repository: one DynamoDB item per attempt,
//! `{push_id, ts, kind, outcome, expires_at}`, and a rate counter. It logs only
//! the kind, a 6-hex prefix of the anonymous device reference and the APNs
//! status. The request schema is closed (`deny_unknown_fields`), so a field the
//! primary never sends cannot be smuggled through.

pub mod apns;
#[cfg(feature = "aws")]
pub mod aws;
pub mod model;

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use serde::Serialize;
use subtle::ConstantTimeEq;
use tokio::sync::Mutex;

pub use apns::ApnsCredentials;
use model::{PushRequest, Record};

/// A delivery record is kept, and returned, for this long.
pub const RECORD_TTL_SECS: i64 = 7 * 24 * 3600;
/// Safety ceiling per anonymous device reference: this many pushes per window.
/// Product-level rate shaping is the daemon's job.
pub const RATE_LIMIT: u32 = 60;
pub const RATE_WINDOW_SECS: i64 = 600;
/// The daemon bearer is re-read from Secrets Manager at most this often, so a
/// rotated token takes effect without a redeploy.
pub const TOKEN_CACHE_SECS: i64 = 300;
/// The APNs key is read, and the provider JWT signed, at most this often
/// (Apple requires a fresh token every 20 to 60 minutes).
pub const APNS_CACHE_SECS: i64 = 50 * 60;

/// Where delivery records and the rate counter live.
#[async_trait]
pub trait Store: Send + Sync {
    async fn put_record(&self, record: &Record) -> Result<(), String>;
    /// Every record held for `push_id` (the handler filters by age: a table's TTL
    /// deletion is lazy).
    async fn records(&self, push_id: &str) -> Result<Vec<Record>, String>;
    /// Count one push in the window and return the new count; the counter item
    /// expires at `expires_at`.
    async fn bump_rate(&self, push_id: &str, window: i64, expires_at: i64) -> Result<u32, String>;
}

/// Where the two secrets live.
#[async_trait]
pub trait Secrets: Send + Sync {
    async fn daemon_token(&self) -> Result<String, String>;
    async fn apns(&self) -> Result<ApnsCredentials, String>;
}

/// Seconds since the Unix epoch; injected so tests control the time.
pub trait Clock: Send + Sync {
    fn now(&self) -> i64;
}

pub struct SystemClock;

impl Clock for SystemClock {
    fn now(&self) -> i64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_secs() as i64)
    }
}

/// An HTTP request, as the handler needs it.
#[derive(Debug, Clone, Default)]
pub struct Request {
    pub method: String,
    pub path: String,
    pub query: BTreeMap<String, String>,
    /// The `Authorization` header, if any.
    pub authorization: Option<String>,
    pub body: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Response {
    pub status: u16,
    /// A JSON document.
    pub body: String,
}

impl Response {
    fn json(status: u16, value: &impl Serialize) -> Self {
        Self {
            status,
            body: serde_json::to_string(value).unwrap_or_else(|_| "{}".to_string()),
        }
    }

    fn error(status: u16, code: &str) -> Self {
        Self::json(status, &serde_json::json!({ "error": code }))
    }
}

#[derive(Default)]
struct Cache {
    token: Option<(String, i64)>,
    apns: Option<(ApnsCredentials, i64)>,
    jwt: Option<(String, i64)>,
}

pub struct Relay {
    store: Arc<dyn Store>,
    secrets: Arc<dyn Secrets>,
    clock: Arc<dyn Clock>,
    http: reqwest::Client,
    /// Replaces both APNs hosts (tests).
    apns_base: Option<String>,
    cache: Mutex<Cache>,
}

impl Relay {
    pub fn new(store: Arc<dyn Store>, secrets: Arc<dyn Secrets>, clock: Arc<dyn Clock>) -> Self {
        Self {
            store,
            secrets,
            clock,
            http: reqwest::Client::builder()
                .timeout(Duration::from_secs(10))
                .build()
                .unwrap_or_default(),
            apns_base: None,
            cache: Mutex::default(),
        }
    }

    /// Send to `base` instead of Apple's hosts (a test's stub).
    pub fn with_apns_base(mut self, base: impl Into<String>) -> Self {
        self.apns_base = Some(base.into());
        self
    }

    pub async fn handle(&self, req: Request) -> Response {
        match (req.method.as_str(), req.path.as_str()) {
            ("POST", "/push") => self.push(req).await,
            ("GET", "/records") => self.records(req).await,
            (_, "/push" | "/records") => Response::error(405, "method_not_allowed"),
            _ => Response::error(404, "not_found"),
        }
    }

    async fn authorized(&self, req: &Request) -> Result<bool, Response> {
        let Some(presented) = req
            .authorization
            .as_deref()
            .and_then(|h| h.strip_prefix("Bearer "))
        else {
            return Ok(false);
        };
        let now = self.clock.now();
        let mut cache = self.cache.lock().await;
        let token = match &cache.token {
            Some((t, at)) if now - at < TOKEN_CACHE_SECS => t.clone(),
            _ => {
                let fresh = self.secrets.daemon_token().await.map_err(|_| {
                    tracing::error!("daemon token unavailable");
                    Response::error(503, "unavailable")
                })?;
                cache.token = Some((fresh.clone(), now));
                fresh
            }
        };
        Ok(!token.is_empty() && presented.as_bytes().ct_eq(token.as_bytes()).into())
    }

    async fn push(&self, req: Request) -> Response {
        match self.authorized(&req).await {
            Ok(true) => {}
            Ok(false) => return Response::error(401, "unauthorized"),
            Err(r) => return r,
        }
        // The error says that the request was refused, never what was in it.
        let Ok(push) = serde_json::from_slice::<PushRequest>(&req.body) else {
            return Response::error(400, "invalid_request");
        };
        if push.validate().is_err() {
            return Response::error(400, "invalid_request");
        }
        let now = self.clock.now();

        let window = now / RATE_WINDOW_SECS;
        match self
            .store
            .bump_rate(&push.push_id, window, (window + 2) * RATE_WINDOW_SECS)
            .await
        {
            Ok(n) if n > RATE_LIMIT => {
                tracing::warn!(push = prefix(&push.push_id), "rate ceiling reached");
                return Response::error(429, "rate_limited");
            }
            Ok(_) => {}
            Err(_) => return Response::error(503, "unavailable"),
        }

        let jwt = match self.provider_token(now).await {
            Ok(t) => t,
            Err(_) => return Response::error(503, "unavailable"),
        };
        let topic = match self.apns_topic().await {
            Ok(t) => t,
            Err(_) => return Response::error(503, "unavailable"),
        };
        let kind = push.record_kind();
        let sent = apns::send(&self.http, self.apns_base.as_deref(), &jwt, &topic, &push).await;

        let (outcome, apns_status, apns_reason, status) = match sent {
            Ok(r) if r.status == 200 => ("accepted", r.status, r.reason, 200),
            Ok(r) => ("rejected", r.status, r.reason, 200),
            Err(_) => ("error", 0, None, 502),
        };
        tracing::info!(
            kind,
            push = prefix(&push.push_id),
            apns_status,
            "notification handled"
        );
        let record = Record {
            push_id: push.push_id.clone(),
            ts: now,
            kind: kind.to_string(),
            outcome: outcome.to_string(),
            expires_at: now + RECORD_TTL_SECS,
        };
        if self.store.put_record(&record).await.is_err() {
            tracing::error!(push = prefix(&push.push_id), "delivery record not written");
        }
        if status == 502 {
            return Response::error(502, "apns_unreachable");
        }
        Response::json(
            200,
            &serde_json::json!({ "apns_status": apns_status, "apns_reason": apns_reason }),
        )
    }

    async fn records(&self, req: Request) -> Response {
        match self.authorized(&req).await {
            Ok(true) => {}
            Ok(false) => return Response::error(401, "unauthorized"),
            Err(r) => return r,
        }
        let Some(push_id) = req.query.get("push_id").filter(|p| model::is_push_id(p)) else {
            return Response::error(400, "invalid_request");
        };
        let now = self.clock.now();
        let mut records = match self.store.records(push_id).await {
            Ok(r) => r,
            Err(_) => return Response::error(503, "unavailable"),
        };
        // TTL deletion is lazy: the read enforces "nothing older than 7 days".
        records.retain(|r| r.push_id == *push_id && r.ts > now - RECORD_TTL_SECS);
        records.sort_by_key(|r| r.ts);
        Response::json(200, &serde_json::json!({ "records": records }))
    }

    /// The provider JWT, signed at most every [`APNS_CACHE_SECS`].
    async fn provider_token(&self, now: i64) -> Result<String, String> {
        let mut cache = self.cache.lock().await;
        if let Some((jwt, at)) = &cache.jwt {
            if now - at < APNS_CACHE_SECS {
                return Ok(jwt.clone());
            }
        }
        let creds = self.apns_credentials(&mut cache, now).await?;
        let jwt = apns::provider_token(&creds, now)?;
        cache.jwt = Some((jwt.clone(), now));
        Ok(jwt)
    }

    async fn apns_topic(&self) -> Result<String, String> {
        let now = self.clock.now();
        let mut cache = self.cache.lock().await;
        Ok(self.apns_credentials(&mut cache, now).await?.topic)
    }

    async fn apns_credentials(
        &self,
        cache: &mut Cache,
        now: i64,
    ) -> Result<ApnsCredentials, String> {
        if let Some((creds, at)) = &cache.apns {
            if now - at < APNS_CACHE_SECS {
                return Ok(creds.clone());
            }
        }
        let fresh = self.secrets.apns().await.map_err(|e| {
            tracing::error!("APNs credentials unavailable");
            e
        })?;
        cache.apns = Some((fresh.clone(), now));
        Ok(fresh)
    }
}

/// The first six characters of the anonymous device reference: all a log line
/// may say about a device.
fn prefix(push_id: &str) -> &str {
    push_id.get(..6).unwrap_or("")
}
