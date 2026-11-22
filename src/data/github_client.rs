//! GitHub API client backed by `octocrab`.
//!
//! # Token resolution order
//! 1. `GITHUB_TOKEN` environment variable.
//! 2. `GH_TOKEN` environment variable (the one the `gh` CLI itself honours).
//! 3. `oauth_token` field under `github.com` in `~/.config/gh/hosts.yml`.
//! 4. `gh auth token --hostname github.com`. Modern `gh` keeps the token in
//!    the macOS keychain, so `hosts.yml` has no `oauth_token` at all and this
//!    is the only way to reach it.
//!
//! If none is found, construction fails with an actionable error message
//! instructing the user to run `gh auth login`.
//!
//! # How `gh` is run
//! The daemon runs under launchd with almost no `PATH`, and a `PATH` search
//! would let a planted binary run, so `gh` is found by absolute path, like the
//! AWS CLI: `$NOSTROMO_GH_CLI`, then `/opt/homebrew/bin/gh`,
//! `/usr/local/bin/gh`, `/usr/bin/gh`; it must be a regular executable file.
//! It runs with a fixed argv, no shell, stdin null, stderr discarded, an
//! environment cleared down to what `gh` needs to find its config and
//! keychain (`HOME`, `USER`, `GH_CONFIG_DIR`, `XDG_CONFIG_HOME`; never a
//! token), a 5 second hard timeout and a capped stdout, which must be one
//! printable-ASCII word of plausible length. Anything else is "no token".
//!
//! A token from `gh` is cached in memory for [`GH_TOKEN_TTL`], a failure for
//! [`GH_FAILURE_TTL`], so the many `GithubClient::new` callers never run `gh`
//! per call. The token is never logged or put in an error.

use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

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
        let url = contents_url(base_url, owner, repo, path)?;
        let resp = self
            .http
            .get(url.clone())
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

/// The contents-API URL for `path` in `owner/repo`, built segment by segment so
/// nothing in `owner`, `repo` or `path` can change what the request IS: each
/// is percent-encoded as one path segment, so a `?`, `#`, `%`, space or `/`
/// inside a segment cannot start a query, fragment or new segment, and a
/// `..` is a literal (encoded) segment name rather than a climb. This request
/// carries the daemon's GitHub bearer token, so "which endpoint does it hit"
/// must not depend on agent-supplied text. Callers validate the path first
/// (`file_source::validate_remote_path`); this is the second layer.
fn contents_url(base_url: &str, owner: &str, repo: &str, path: &str) -> Result<reqwest::Url> {
    let mut url = reqwest::Url::parse(base_url).context("parsing the GitHub API base URL")?;
    url.path_segments_mut()
        .map_err(|_| anyhow::anyhow!("GitHub API base URL cannot carry a path"))?
        .pop_if_empty()
        .extend(["repos", owner, repo, "contents"])
        .extend(path.split('/'));
    Ok(url)
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

/// The environment variable that names the `gh` CLI.
pub const GH_CLI_ENV: &str = "NOSTROMO_GH_CLI";
/// Where `gh` is looked for when nothing names it. Never a `PATH` search.
const DEFAULT_GH_CLIS: [&str; 3] = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"];
/// The only variables of the daemon's environment `gh` runs with: enough to
/// find its config and the keychain. No `GITHUB_TOKEN`/`GH_TOKEN`.
const GH_INHERITED_ENV: [&str; 4] = ["HOME", "USER", "GH_CONFIG_DIR", "XDG_CONFIG_HOME"];
/// How long `gh auth token` may take before it is killed.
const GH_TIMEOUT: Duration = Duration::from_secs(5);
/// The most of `gh`'s stdout that is read; more than this is not a token.
const GH_STDOUT_CAP: usize = 512;
/// A token from `gh` is reused for this long.
pub const GH_TOKEN_TTL: Duration = Duration::from_secs(5 * 60);
/// A failed `gh` lookup is not repeated for this long.
pub const GH_FAILURE_TTL: Duration = Duration::from_secs(30);

struct GhCacheEntry {
    candidates: Vec<PathBuf>,
    at: Instant,
    token: Option<String>,
}

// `GhCacheEntry` holds a token and derives nothing (no `Debug`), on purpose.
static GH_CACHE: Mutex<Option<GhCacheEntry>> = Mutex::new(None);

fn resolve_token(hosts_yml_path: Option<&Path>) -> Result<String> {
    // 1. Environment variables.
    for var in ["GITHUB_TOKEN", "GH_TOKEN"] {
        if let Ok(t) = std::env::var(var) {
            if !t.is_empty() {
                return Ok(t);
            }
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

    // 3. The gh CLI itself (the token is in the keychain).
    if let Some(token) = gh_cli_token_cached(&gh_candidates(std::env::var_os(GH_CLI_ENV))) {
        return Ok(token);
    }

    bail!(
        "No GitHub token found.\n\
         Set the GITHUB_TOKEN environment variable or run `gh auth login`.\n\
         Looked for gh config at: {} (the gh CLI was tried too)",
        path.display()
    )
}

/// `$NOSTROMO_GH_CLI` (when set), then the usual absolute places.
fn gh_candidates(env: Option<std::ffi::OsString>) -> Vec<PathBuf> {
    env.map(PathBuf::from)
        .filter(|p| !p.as_os_str().is_empty())
        .into_iter()
        .chain(DEFAULT_GH_CLIS.iter().map(PathBuf::from))
        .collect()
}

fn is_executable_file(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    path.is_absolute()
        && std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

fn gh_cli_token_cached(candidates: &[PathBuf]) -> Option<String> {
    gh_cli_token_cached_with(candidates, GH_TIMEOUT)
}

fn gh_cli_token_cached_with(candidates: &[PathBuf], timeout: Duration) -> Option<String> {
    let mut cache = GH_CACHE.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(e) = cache.as_ref() {
        let ttl = if e.token.is_some() {
            GH_TOKEN_TTL
        } else {
            GH_FAILURE_TTL
        };
        if e.candidates == candidates && e.at.elapsed() < ttl {
            return e.token.clone();
        }
    }
    // Held across the run on purpose: concurrent callers wait for one `gh`
    // instead of each starting their own.
    let token = gh_cli_token(candidates, timeout);
    *cache = Some(GhCacheEntry {
        candidates: candidates.to_vec(),
        at: Instant::now(),
        token: token.clone(),
    });
    token
}

/// Run `gh auth token --hostname github.com` from the first executable
/// candidate. `None` for every failure; nothing from `gh` is ever logged,
/// since its output may be a token.
fn gh_cli_token(candidates: &[PathBuf], timeout: Duration) -> Option<String> {
    let exe = candidates.iter().find(|p| is_executable_file(p))?;
    let mut cmd = Command::new(exe);
    cmd.args(["auth", "token", "--hostname", "github.com"])
        .env_clear()
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    for var in GH_INHERITED_ENV {
        if let Some(v) = std::env::var_os(var) {
            cmd.env(var, v);
        }
    }
    let mut child = cmd.spawn().ok()?;
    let stdout = child.stdout.take()?;
    // Reads one byte past the cap, then drops the pipe, so a chatty `gh`
    // gets EPIPE rather than blocking.
    let reader = std::thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = stdout.take(GH_STDOUT_CAP as u64 + 1).read_to_end(&mut buf);
        buf
    });

    let deadline = Instant::now() + timeout;
    let status = loop {
        match child.try_wait() {
            Ok(Some(s)) => break Some(s),
            Ok(None) if Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(10));
            }
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                break None;
            }
        }
    };
    let out = reader.join().ok()?;
    match status {
        Some(s) if s.success() => validate_gh_token(&out),
        _ => {
            debug!("gh auth token gave no token (failed or timed out)");
            None
        }
    }
}

/// One printable-ASCII word of plausible length, once trimmed; else `None`.
fn validate_gh_token(raw: &[u8]) -> Option<String> {
    if raw.len() > GH_STDOUT_CAP {
        return None;
    }
    let s = std::str::from_utf8(raw).ok()?.trim();
    let plausible = (20..=255).contains(&s.len());
    (plausible && s.bytes().all(|b| b.is_ascii_graphic())).then(|| s.to_string())
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
    // ── contents URL construction (security review, 2026-10-06) ──────────────

    #[test]
    fn contents_url_builds_the_ordinary_shape() {
        let u = contents_url(
            "https://api.github.com",
            "Carefeed",
            "referral-monitor",
            "docs/a.md",
        )
        .unwrap();
        assert_eq!(
            u.as_str(),
            "https://api.github.com/repos/Carefeed/referral-monitor/contents/docs/a.md"
        );
    }

    #[test]
    fn contents_url_cannot_be_retargeted_by_the_path() {
        // `?` and `#` stay inside the path as encoded characters: no query, no fragment.
        let u = contents_url("https://api.github.com", "o", "r", "a?ref=evil#x").unwrap();
        assert_eq!(
            u.query(),
            None,
            "a `?` in the path must not start a query: {u}"
        );
        assert_eq!(
            u.fragment(),
            None,
            "a `#` in the path must not start a fragment: {u}"
        );
        assert!(u.path().starts_with("/repos/o/r/contents/"));
        // Spaces and a pre-encoded `..` are encoded, never interpreted.
        let u = contents_url("https://api.github.com", "o", "r", "a b/%2e%2e/c").unwrap();
        assert!(u.path().starts_with("/repos/o/r/contents/"), "{u}");
        assert!(!u.path().contains(' '), "{u}");
    }

    #[test]
    fn contents_url_cannot_climb_out_with_dot_segments_in_the_path_or_repo() {
        for (owner, repo, path) in [
            ("o", "r", "../../../user"),
            ("..", "x", "a.md"),
            ("o", "..", "a.md"),
        ] {
            let u = contents_url("https://api.github.com", owner, repo, path).unwrap();
            assert!(
                u.path().starts_with("/repos/") && u.path().contains("/contents/"),
                "{owner}/{repo}:{path} climbed out of /repos/../contents/: {u}"
            );
        }
    }

    #[test]
    fn contents_url_tolerates_a_trailing_slash_on_the_base() {
        let u = contents_url("http://127.0.0.1:1234/", "o", "r", "a.md").unwrap();
        assert_eq!(u.as_str(), "http://127.0.0.1:1234/repos/o/r/contents/a.md");
    }

    use super::*;
    use std::os::unix::fs::PermissionsExt;

    // ── token resolution (gh keychain fix) ───────────────────────────────────

    const FAKE_TOKEN: &str = "gho_fakeTokenFromGhCli0123456789abcdef";
    const SECRET_STDERR: &str = "STDERR_SECRET_must_not_leak";

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    /// Holds the env lock and sets the three token-related variables for one
    /// test; restores them (and clears the gh cache) on drop.
    struct Env {
        _guard: std::sync::MutexGuard<'static, ()>,
        saved: Vec<(&'static str, Option<std::ffi::OsString>)>,
    }

    impl Env {
        fn new(github: Option<&str>, gh: Option<&str>, cli: Option<&Path>) -> Self {
            let guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
            let vars = [
                ("GITHUB_TOKEN", github.map(Into::into)),
                ("GH_TOKEN", gh.map(Into::into)),
                (GH_CLI_ENV, cli.map(|p| p.as_os_str().to_owned())),
            ];
            let mut saved = Vec::new();
            for (k, v) in vars {
                saved.push((k, std::env::var_os(k)));
                match v {
                    Some(v) => std::env::set_var(k, v),
                    None => std::env::remove_var(k),
                }
            }
            *GH_CACHE.lock().unwrap_or_else(|e| e.into_inner()) = None;
            Self {
                _guard: guard,
                saved,
            }
        }
    }

    impl Drop for Env {
        fn drop(&mut self) {
            for (k, v) in self.saved.drain(..) {
                match v {
                    Some(v) => std::env::set_var(k, v),
                    None => std::env::remove_var(k),
                }
            }
            *GH_CACHE.lock().unwrap_or_else(|e| e.into_inner()) = None;
        }
    }

    /// A fake `gh` (mode 0755) with the given shell body.
    fn fake_gh(dir: &Path, body: &str) -> PathBuf {
        let p = dir.join("gh");
        std::fs::write(&p, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
        p
    }

    fn hosts(dir: &Path, content: &str) -> PathBuf {
        let p = dir.join("hosts.yml");
        std::fs::write(&p, content).unwrap();
        p
    }

    const KEYRING_HOSTS: &str = "github.com:\n  git_protocol: https\n  user: tester\n";

    #[test]
    fn gh_token_env_works_and_beats_hosts_and_gh() {
        let dir = tempfile::tempdir().unwrap();
        let gh = fake_gh(dir.path(), &format!("echo {FAKE_TOKEN}"));
        let h = hosts(dir.path(), "github.com:\n  oauth_token: from_hosts\n");
        let _e = Env::new(None, Some("from_gh_env"), Some(&gh));
        assert_eq!(resolve_token(Some(&h)).unwrap(), "from_gh_env");
    }

    #[test]
    fn hosts_oauth_token_wins_over_gh_cli() {
        let dir = tempfile::tempdir().unwrap();
        let gh = fake_gh(dir.path(), &format!("echo {FAKE_TOKEN}"));
        let h = hosts(dir.path(), "github.com:\n  oauth_token: from_hosts\n");
        let _e = Env::new(None, None, Some(&gh));
        assert_eq!(resolve_token(Some(&h)).unwrap(), "from_hosts");
    }

    #[test]
    fn gh_cli_is_used_when_hosts_has_no_oauth_token() {
        let dir = tempfile::tempdir().unwrap();
        // Prints the token with a trailing newline and spaces; also checks
        // the argv and that the daemon's tokens are not passed along.
        let gh = fake_gh(
            dir.path(),
            &format!(
                "[ \"$*\" = \"auth token --hostname github.com\" ] || exit 3\n\
                 [ -z \"$GITHUB_TOKEN$GH_TOKEN\" ] || exit 4\n\
                 echo '  {FAKE_TOKEN}  '"
            ),
        );
        let h = hosts(dir.path(), KEYRING_HOSTS);
        let _e = Env::new(None, None, Some(&gh));
        assert_eq!(resolve_token(Some(&h)).unwrap(), FAKE_TOKEN);
    }

    #[test]
    fn gh_cli_is_used_when_hosts_file_is_missing() {
        let dir = tempfile::tempdir().unwrap();
        let gh = fake_gh(dir.path(), &format!("echo {FAKE_TOKEN}"));
        let _e = Env::new(None, None, Some(&gh));
        let missing = dir.path().join("nope.yml");
        assert_eq!(resolve_token(Some(&missing)).unwrap(), FAKE_TOKEN);
    }

    #[test]
    fn gh_cli_failures_fall_through_to_the_error_without_leaking() {
        let big = "x".repeat(GH_STDOUT_CAP + 100);
        let bodies = [
            format!("echo {FAKE_TOKEN}; echo {SECRET_STDERR} >&2; exit 1"),
            format!("echo {SECRET_STDERR} >&2"),
            format!("printf '%s\\n%s\\n' {FAKE_TOKEN} {FAKE_TOKEN}"),
            format!("echo '{FAKE_TOKEN} {FAKE_TOKEN}'"),
            "echo '   '".to_string(),
            format!("echo {big}"),
            "echo short".to_string(),
            format!("printf '{FAKE_TOKEN}\\001'"),
            format!("printf '{FAKE_TOKEN}\\303\\251'"),
        ];
        for body in bodies {
            let dir = tempfile::tempdir().unwrap();
            let gh = fake_gh(dir.path(), &body);
            let h = hosts(dir.path(), KEYRING_HOSTS);
            let _e = Env::new(None, None, Some(&gh));
            let err = resolve_token(Some(&h)).unwrap_err().to_string();
            assert!(err.contains("No GitHub token found"), "{body}: {err}");
            assert!(err.contains("gh CLI"), "{err}");
            assert!(!err.contains(FAKE_TOKEN), "{body}: token leaked: {err}");
            assert!(!err.contains(SECRET_STDERR), "stderr leaked: {err}");
        }
    }

    #[test]
    fn a_hanging_gh_is_killed_at_the_timeout() {
        let dir = tempfile::tempdir().unwrap();
        let gh = fake_gh(dir.path(), "exec sleep 30");
        let started = Instant::now();
        let got = gh_cli_token(&[gh], Duration::from_millis(300));
        assert_eq!(got, None);
        assert!(started.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn gh_is_not_run_per_call_and_a_failure_is_remembered() {
        let dir = tempfile::tempdir().unwrap();
        let counter = dir.path().join("count");
        let ok = fake_gh(
            dir.path(),
            &format!("echo x >> {}\necho {FAKE_TOKEN}", counter.display()),
        );
        let _e = Env::new(None, None, Some(&ok));
        let h = hosts(dir.path(), KEYRING_HOSTS);
        for _ in 0..5 {
            assert_eq!(resolve_token(Some(&h)).unwrap(), FAKE_TOKEN);
        }
        assert_eq!(
            std::fs::read_to_string(&counter).unwrap().lines().count(),
            1
        );

        // A failing gh is also run once, not once per call.
        let dir2 = tempfile::tempdir().unwrap();
        let counter2 = dir2.path().join("count");
        let bad = fake_gh(
            dir2.path(),
            &format!("echo x >> {}\nexit 1", counter2.display()),
        );
        std::env::set_var(GH_CLI_ENV, &bad);
        for _ in 0..5 {
            assert!(resolve_token(Some(&h)).is_err());
        }
        assert_eq!(
            std::fs::read_to_string(&counter2).unwrap().lines().count(),
            1
        );
    }

    #[test]
    fn no_path_lookup_a_gh_on_path_is_never_run() {
        let dir = tempfile::tempdir().unwrap();
        let marker = dir.path().join("ran");
        fake_gh(
            dir.path(),
            &format!("touch {}\necho {FAKE_TOKEN}", marker.display()),
        );
        let h = hosts(dir.path(), KEYRING_HOSTS);
        let _e = Env::new(None, None, None);
        let old_path = std::env::var_os("PATH");
        std::env::set_var("PATH", dir.path());
        let _ = resolve_token(Some(&h));
        match old_path {
            Some(p) => std::env::set_var("PATH", p),
            None => std::env::remove_var("PATH"),
        }
        assert!(!marker.exists(), "a gh found on PATH was run");
        for c in gh_candidates(None) {
            assert!(c.is_absolute());
        }
    }

    #[test]
    fn a_non_executable_or_relative_override_is_not_run() {
        let dir = tempfile::tempdir().unwrap();
        let gh = fake_gh(dir.path(), &format!("echo {FAKE_TOKEN}"));
        std::fs::set_permissions(&gh, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(!is_executable_file(&gh));
        assert!(!is_executable_file(Path::new("gh")));
        assert!(!is_executable_file(dir.path()));
    }

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
