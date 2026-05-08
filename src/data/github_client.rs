//! GitHub API client backed by `octocrab`.
//!
//! # Token resolution order
//! 1. `GITHUB_TOKEN` environment variable.
//! 2. `oauth_token` field under `github.com` in `~/.config/gh/hosts.yml`.
//!
//! If neither is found, construction fails with an actionable error message
//! instructing the user to run `gh auth login`.

use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use octocrab::Octocrab;
use serde::Deserialize;
use tracing::debug;

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
        let token = resolve_token(hosts_yml_path)?;
        debug!("github token resolved");

        let octocrab = Octocrab::builder()
            .personal_token(token.clone())
            .build()
            .context("building octocrab client")?;

        let http = reqwest::Client::builder()
            .user_agent(concat!("nostromo/", env!("CARGO_PKG_VERSION")))
            .build()
            .context("building reqwest client for github")?;

        Ok(Self { octocrab, http, token })
    }

    /// The resolved personal access token (used for raw Bearer requests).
    pub fn token(&self) -> &str {
        &self.token
    }
}

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
    let data = std::fs::read_to_string(path)
        .with_context(|| format!("reading {}", path.display()))?;

    // serde_yaml parses the whole document.  The structure is:
    // github.com:
    //   oauth_token: ghp_xxx
    let map: serde_yaml::Mapping = serde_yaml::from_str(&data)
        .with_context(|| format!("parsing {}", path.display()))?;

    for (key, value) in &map {
        let host = key
            .as_str()
            .unwrap_or_default();
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
