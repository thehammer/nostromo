//! The only HTTP Huey's fetchers do: bounded GETs.
//!
//! Every request is a GET with the fixed User-Agent, a per-request timeout
//! and a body cap. A GitHub token is sent to `api.github.com` and nowhere
//! else. Failure reasons are plain words: no URLs, no response text.

use std::time::Duration;

use serde::de::DeserializeOwned;

/// Limits from the plan (T1).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HttpLimits {
    /// One source, all its requests together.
    pub per_source: Duration,
    /// The whole fetch.
    pub overall: Duration,
    /// Largest response body accepted, in bytes.
    pub body_cap: usize,
}

impl Default for HttpLimits {
    fn default() -> Self {
        Self {
            per_source: Duration::from_secs(30),
            overall: Duration::from_secs(90),
            body_cap: 8 * 1024 * 1024,
        }
    }
}

/// Why a fetch failed, in words fit for the report footer.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum FetchError {
    #[error("timed out")]
    Timeout,
    #[error("HTTP {0}")]
    Status(u16),
    #[error("response too large")]
    TooLarge,
    #[error("could not connect")]
    Network,
    /// A body that did not parse. The text is a fixed phrase such as
    /// "could not parse feed", never part of the body.
    #[error("{0}")]
    Parse(String),
}

impl FetchError {
    pub fn parse(what: &str) -> Self {
        Self::Parse(format!("could not parse {what}"))
    }
}

/// Validators from an earlier response, sent back so an unchanged document
/// costs one small reply.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Conditional {
    pub etag: Option<String>,
    pub last_modified: Option<String>,
}

impl Conditional {
    pub fn is_empty(&self) -> bool {
        self.etag.is_none() && self.last_modified.is_none()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Body {
    pub bytes: Vec<u8>,
    pub etag: Option<String>,
    pub last_modified: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Response {
    /// 304: the document has not changed since the validators were issued.
    NotModified,
    Body(Body),
}

#[derive(Clone)]
pub struct HttpClient {
    client: reqwest::Client,
    limits: HttpLimits,
    github_token: Option<String>,
}

impl std::fmt::Debug for HttpClient {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("HttpClient")
            .field("limits", &self.limits)
            .field("github_token", &self.github_token.is_some())
            .finish()
    }
}

impl HttpClient {
    pub fn new(limits: HttpLimits, github_token: Option<String>) -> Self {
        let client = reqwest::Client::builder()
            .user_agent(user_agent())
            .timeout(limits.per_source)
            .connect_timeout(limits.per_source.min(Duration::from_secs(10)))
            .redirect(reqwest::redirect::Policy::limited(5))
            .build()
            .expect("reqwest client with static settings builds");
        Self {
            client,
            limits,
            github_token,
        }
    }

    /// Default limits, and the GitHub token the rest of Nostromo uses when
    /// one resolves (unauthenticated otherwise).
    pub fn production() -> Self {
        let token = crate::data::github_client::GithubClient::new(None)
            .ok()
            .map(|c| c.token().to_string());
        Self::new(HttpLimits::default(), token)
    }

    pub fn limits(&self) -> HttpLimits {
        self.limits
    }

    /// GET `url`. With validators, an unchanged document is
    /// [`Response::NotModified`].
    pub async fn get(
        &self,
        url: &str,
        accept: Option<&str>,
        conditional: Option<&Conditional>,
    ) -> Result<Response, FetchError> {
        let mut req = self.client.get(url);
        if let Some(accept) = accept {
            req = req.header(reqwest::header::ACCEPT, accept);
        }
        if let Some(c) = conditional {
            if let Some(etag) = &c.etag {
                req = req.header(reqwest::header::IF_NONE_MATCH, etag);
            }
            if let Some(lm) = &c.last_modified {
                req = req.header(reqwest::header::IF_MODIFIED_SINCE, lm);
            }
        }
        if is_github_api(url) {
            req = req.header("X-GitHub-Api-Version", "2022-11-28");
            if let Some(token) = &self.github_token {
                req = req.bearer_auth(token);
            }
        }
        let mut resp = req.send().await.map_err(classify)?;
        let status = resp.status();
        if status == reqwest::StatusCode::NOT_MODIFIED && conditional.is_some_and(|c| !c.is_empty())
        {
            return Ok(Response::NotModified);
        }
        if !status.is_success() {
            return Err(FetchError::Status(status.as_u16()));
        }
        let header = |name: reqwest::header::HeaderName| {
            resp.headers()
                .get(name)
                .and_then(|v| v.to_str().ok())
                .map(str::to_string)
        };
        let etag = header(reqwest::header::ETAG);
        let last_modified = header(reqwest::header::LAST_MODIFIED);
        let cap = self.limits.body_cap;
        if resp.content_length().is_some_and(|n| n > cap as u64) {
            return Err(FetchError::TooLarge);
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = resp.chunk().await.map_err(classify)? {
            if bytes.len() + chunk.len() > cap {
                return Err(FetchError::TooLarge);
            }
            bytes.extend_from_slice(&chunk);
        }
        Ok(Response::Body(Body {
            bytes,
            etag,
            last_modified,
        }))
    }

    /// GET a document that is always read in full (no validators).
    pub async fn get_body(&self, url: &str, accept: Option<&str>) -> Result<Vec<u8>, FetchError> {
        match self.get(url, accept, None).await? {
            Response::Body(b) => Ok(b.bytes),
            // Unreachable without validators; a server that sends 304 anyway is a failure.
            Response::NotModified => Err(FetchError::Status(304)),
        }
    }

    pub async fn get_json<T: DeserializeOwned>(
        &self,
        url: &str,
        accept: Option<&str>,
        what: &str,
    ) -> Result<T, FetchError> {
        let bytes = self.get_body(url, accept).await?;
        serde_json::from_slice(&bytes).map_err(|_| FetchError::parse(what))
    }
}

pub fn user_agent() -> String {
    format!(
        "Nostromo-Huey/{} (+https://github.com/thehammer/nostromo)",
        env!("CARGO_PKG_VERSION")
    )
}

fn is_github_api(url: &str) -> bool {
    url::Url::parse(url)
        .ok()
        .and_then(|u| {
            u.host_str()
                .map(|h| h.eq_ignore_ascii_case("api.github.com"))
        })
        .unwrap_or(false)
}

fn classify(e: reqwest::Error) -> FetchError {
    if e.is_timeout() {
        FetchError::Timeout
    } else {
        FetchError::Network
    }
}
