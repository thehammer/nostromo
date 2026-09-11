//! GitHub API client backed by `octocrab`.
//!
//! # Token resolution order
//! 1. `GITHUB_TOKEN` environment variable.
//! 2. `oauth_token` field under `github.com` in `~/.config/gh/hosts.yml`.
//!
//! If neither is found, construction fails with an actionable error message
//! instructing the user to run `gh auth login`.

use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{bail, Context, Result};
use octocrab::Octocrab;
use serde::Deserialize;
use tracing::debug;

use crate::config::{GITHUB_CONNECT_TIMEOUT_SECS, GITHUB_HTTP_TIMEOUT_SECS};

// ── Hosts.yml shape ───────────────────────────────────────────────────────────

#[derive(Deserialize)]
struct GhHostEntry {
    oauth_token: Option<String>,
}

// ── GithubClient ──────────────────────────────────────────────────────────────

/// Wrapper around `octocrab` and a bare `reqwest::Client` (for raw diff/ETag requests).
#[derive(Clone)]
pub struct GithubClient {
    pub octocrab: Octocrab,
    pub http: reqwest::Client,
    pub token: String,
}

impl GithubClient {
    /// Build a new client, resolving the GitHub token from environment or gh CLI config.
    pub fn new(hosts_yml_path: Option<&Path>) -> Result<Self> {
        Self::build(hosts_yml_path, None)
    }

    /// Test-only constructor: same as [`Self::new`], but points `octocrab`
    /// at `base_uri` (a local `wiremock` server) instead of the real GitHub
    /// API. Pair with `perri_queue_native::API_BASE_OVERRIDE` (set to the
    /// same `base_uri`) to also redirect the raw `http`-based fetches
    /// (`fetch_diff` and friends), so a whole `PerriPrNativeSource` cycle can
    /// be driven against a mock server deterministically.
    #[cfg(test)]
    pub(crate) fn new_for_test(hosts_yml_path: Option<&Path>, base_uri: &str) -> Result<Self> {
        Self::build(hosts_yml_path, Some(base_uri))
    }

    fn build(hosts_yml_path: Option<&Path>, octocrab_base_uri: Option<&str>) -> Result<Self> {
        let token = resolve_token(hosts_yml_path)?;
        debug!("github token resolved");

        // D2: bound octocrab's own HTTP layer the same way `http` is bounded
        // below — a raw `reqwest::Client` timeout only protects the raw
        // diff/ETag requests that go through `client.http` directly; the PR
        // metadata/CI/conversation calls go through `client.octocrab`
        // instead, and without this they'd stay unbounded even after D1.
        // `octocrab`'s `timeout` feature (on by default) exposes connect/
        // read/write separately rather than one overall duration; using the
        // same two constants for all three keeps one bounded-request budget
        // instead of a second, differently-tuned one to reason about.
        let mut octocrab_builder = Octocrab::builder()
            .personal_token(token.clone())
            .set_connect_timeout(Some(Duration::from_secs(GITHUB_CONNECT_TIMEOUT_SECS)))
            .set_read_timeout(Some(Duration::from_secs(GITHUB_HTTP_TIMEOUT_SECS)))
            .set_write_timeout(Some(Duration::from_secs(GITHUB_HTTP_TIMEOUT_SECS)));
        if let Some(base) = octocrab_base_uri {
            octocrab_builder = octocrab_builder
                .base_uri(base)
                .context("setting octocrab base_uri")?;
        }
        let octocrab = octocrab_builder
            .build()
            .context("building octocrab client")?;

        let http = github_http_client_builder()
            .build()
            .context("building reqwest client for github")?;

        Ok(Self {
            octocrab,
            http,
            token,
        })
    }

    /// The resolved personal access token (used for raw Bearer requests).
    pub fn token(&self) -> &str {
        &self.token
    }

    /// Fetch one file's raw contents at `git_ref` via the contents API.
    ///
    /// Uses `Accept: application/vnd.github.raw` so the response body *is* the
    /// file, with no base64 envelope to decode and no 1MB JSON-shape cliff to
    /// fall off. `base_url` exists so tests can point this at a `wiremock`
    /// server; production callers pass [`GITHUB_API_BASE`].
    ///
    /// `Ok(None)` means the API answered 404 — the ref or the path genuinely
    /// isn't there, which is a refusal and not a transport failure. Any other
    /// non-success status is an `Err`, because "GitHub is rate-limiting us" and
    /// "that file doesn't exist" must not render as the same thing.
    pub async fn file_at_ref(
        &self,
        base_url: &str,
        owner: &str,
        repo: &str,
        path: &str,
        git_ref: &str,
    ) -> Result<Option<String>> {
        let url = format!("{base_url}/repos/{owner}/{repo}/contents/{path}");
        let resp = self
            .http
            .get(&url)
            .query(&[("ref", git_ref)])
            .header(reqwest::header::ACCEPT, "application/vnd.github.raw")
            .header(
                reqwest::header::AUTHORIZATION,
                format!("Bearer {}", self.token),
            )
            .header("X-GitHub-Api-Version", "2022-11-28")
            .send()
            .await
            .context("fetching file contents")?;

        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(None);
        }
        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            bail!("contents fetch {url} -> {status}: {body}");
        }
        resp.text().await.context("reading contents body").map(Some)
    }
}

/// Builds the `reqwest::ClientBuilder` behind [`GithubClient::http`] — split
/// out from [`GithubClient::build`] so a test can inspect the builder's
/// `Debug` output (which prints `connect_timeout`/`timeout` fields only when
/// set — see `reqwest::ClientBuilder`'s `Debug` impl) without needing a
/// getter `reqwest::Client` doesn't expose post-build.
///
/// D1 — the core fix: `reqwest`'s defaults are unbounded on both connect and
/// overall duration, so a stalled connection or a half-delivered body (most
/// likely on `perri_pr_native::fetch_diff`, which pulls up to 500 KB of raw
/// diff) used to hang forever. `.connect_timeout` is short and unforgiving —
/// a stalled TCP handshake is never legitimate — while `.timeout` is
/// generous enough to clear a legitimate large-diff fetch on a slow link.
/// Both durations, and the reasoning for their specific values, live on
/// `GITHUB_CONNECT_TIMEOUT_SECS`/`GITHUB_HTTP_TIMEOUT_SECS` in `config.rs`,
/// beside `pr_diff_poll_secs` — the overall timeout must stay under that
/// poll interval or a hung request outlives the cycle meant to supersede it
/// (pinned by `github_timeout_is_shorter_than_the_poll_interval` below).
fn github_http_client_builder() -> reqwest::ClientBuilder {
    reqwest::Client::builder()
        .user_agent(concat!("nostromo/", env!("CARGO_PKG_VERSION")))
        .connect_timeout(Duration::from_secs(GITHUB_CONNECT_TIMEOUT_SECS))
        .timeout(Duration::from_secs(GITHUB_HTTP_TIMEOUT_SECS))
}

/// The production GitHub API base. A constant rather than a hard-coded literal
/// inside [`GithubClient::file_at_ref`] so the same code path is exercised by
/// tests pointed at a local mock server.
pub const GITHUB_API_BASE: &str = "https://api.github.com";

// ── Token resolution ──────────────────────────────────────────────────────────

fn resolve_token(hosts_yml_path: Option<&Path>) -> Result<String> {
    // 1. Environment variable.
    if let Ok(t) = std::env::var("GITHUB_TOKEN") {
        if !t.is_empty() {
            return Ok(t);
        }
    }

    // 2. gh CLI hosts.yml.
    let path = hosts_yml_path
        .map(Path::to_path_buf)
        .unwrap_or_else(default_hosts_yml);

    if path.exists() {
        if let Some(token) = parse_hosts_yml(&path)? {
            return Ok(token);
        }
    }

    bail!(
        "No GitHub token found.\n\
         Set the GITHUB_TOKEN environment variable or run `gh auth login`.\n\
         Looked for gh config at: {}",
        path.display()
    )
}

fn parse_hosts_yml(path: &Path) -> Result<Option<String>> {
    let data =
        std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;

    // serde_yaml parses the whole document.  The structure is:
    // github.com:
    //   oauth_token: ghp_xxx
    let map: serde_yaml::Mapping =
        serde_yaml::from_str(&data).with_context(|| format!("parsing {}", path.display()))?;

    for (key, value) in &map {
        let host = key.as_str().unwrap_or_default();
        if host == "github.com" {
            let entry: GhHostEntry = serde_yaml::from_value(value.clone())
                .with_context(|| "parsing github.com entry in hosts.yml")?;
            return Ok(entry.oauth_token);
        }
    }

    Ok(None)
}

fn default_hosts_yml() -> PathBuf {
    std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("."))
        .join(".config")
        .join("gh")
        .join("hosts.yml")
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// `reqwest::Client` exposes no public getter for `connect_timeout`/
    /// `timeout` post-`.build()`, and `reqwest::ClientBuilder`'s `Debug` impl
    /// only prints those fields when they've actually been set (confirmed by
    /// reading reqwest 0.12.28's `src/async_impl/client.rs`,
    /// `Config::fmt_fields`) — so string-matching the builder's `Debug`
    /// output is the only introspection available for "are the timeouts
    /// configured at all", and is the intended way to test it.
    ///
    /// Fails against the pre-fix `github_http_client_builder` (which only
    /// sets `user_agent`); passes once `.connect_timeout(...)` and
    /// `.timeout(...)` are added using `GITHUB_CONNECT_TIMEOUT_SECS` /
    /// `GITHUB_HTTP_TIMEOUT_SECS`.
    #[test]
    fn github_http_client_builder_debug_output_carries_connect_and_overall_timeouts() {
        let debug = format!("{:?}", github_http_client_builder());
        assert!(
            debug.contains("connect_timeout"),
            "builder Debug output must show a configured connect_timeout, got: {debug}"
        );
        assert!(
            debug.contains("timeout"),
            "builder Debug output must show a configured overall request timeout, got: {debug}"
        );
    }

    /// Pins the relationship documented on `GITHUB_HTTP_TIMEOUT_SECS` in
    /// `config.rs`: the per-request GitHub timeout must stay comfortably
    /// below the diff-poll interval, or a request that genuinely hangs would
    /// still be in flight when the next poll cycle would otherwise supersede
    /// it — defeating the point of bounding it at all.
    #[test]
    fn github_timeout_is_shorter_than_the_poll_interval() {
        let poll_secs = crate::config::Config::default().pr_diff_poll_secs;
        assert!(
            crate::config::GITHUB_HTTP_TIMEOUT_SECS < poll_secs,
            "GITHUB_HTTP_TIMEOUT_SECS ({}) must stay below pr_diff_poll_secs ({poll_secs}), \
             or a hung request outlives the poll cycle meant to supersede it",
            crate::config::GITHUB_HTTP_TIMEOUT_SECS,
        );
    }

    // No dedicated unit test for octocrab's connect/read/write timeouts (D2
    // — `OctocrabBuilder::set_connect_timeout`/`set_read_timeout`/
    // `set_write_timeout`). Unlike `reqwest::ClientBuilder`, `Octocrab`/its
    // internal `tower` service expose no public post-build introspection to
    // string-match against, so a unit test here would have nothing to assert
    // on. Coverage instead comes from `data::perri_pr_native`'s
    // `a_stalled_diff_fetch_...` end-to-end test, which drives a real
    // PR-metadata fetch through `client.octocrab` against a mock server
    // inside a hard-bounded `tokio::time::timeout` — if octocrab's own
    // timeout were never wired up, that metadata fetch (not just the raw
    // diff fetch) would be a second way for the whole test to hang.
}
