//! Configuration loader.
//!
//! Reads `~/.config/nostromo/config.toml` (or a path override).  All fields
//! are optional — sane defaults are used when absent.

use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

/// Top-level config struct.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    /// Path to the fred state directory (default: `$HOME/.claude/state/fred`).
    pub fred_state: Option<PathBuf>,
    /// Path to the perri state directory (default: `$HOME/.claude/state/perri`).
    pub perri_state: Option<PathBuf>,
    /// Path to the claude bin directory (default: `$HOME/.claude/bin`).
    pub claude_bin: Option<PathBuf>,
    /// Mailbox poll interval in seconds (default: 60).
    pub mailbox_poll_secs: u64,
    /// Calendar poll interval in seconds (default: 120).
    pub calendar_poll_secs: u64,
    /// PR queue poll interval in seconds (default: 60).
    pub pr_queue_poll_secs: u64,
    /// PR diff poll interval in seconds (default: 30).
    pub pr_diff_poll_secs: u64,

    // ── Phase 4: Microsoft Graph (native mailbox/calendar) ──────────────────

    /// Azure AD application (client) ID for Microsoft Graph OAuth2 device flow.
    pub graph_client_id: Option<String>,
    /// Azure AD tenant ID (default: `"common"` for multi-tenant / personal accounts).
    pub graph_tenant: Option<String>,
    /// Path where the Graph OAuth2 token is cached.
    /// Default: `$HOME/.cache/nostromo/graph-token.json`.
    pub graph_token_cache: Option<PathBuf>,

    // ── Phase 4: GitHub (native PR queue/diff) ──────────────────────────────

    /// Path to the gh CLI `hosts.yml` used to resolve a GitHub token when
    /// `GITHUB_TOKEN` is not set.  Default: `$HOME/.config/gh/hosts.yml`.
    pub github_token_path: Option<PathBuf>,

    /// VIP sender addresses (lowercase); emails from these addresses are
    /// highlighted in the mailbox panel.
    pub vip_senders: Vec<String>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            fred_state: None,
            perri_state: None,
            claude_bin: None,
            mailbox_poll_secs: 60,
            calendar_poll_secs: 120,
            pr_queue_poll_secs: 60,
            pr_diff_poll_secs: 30,
            graph_client_id: None,
            graph_tenant: None,
            graph_token_cache: None,
            github_token_path: None,
            vip_senders: Vec::new(),
        }
    }
}

impl Config {
    /// Load config from `path` (if given) or from the default location.
    /// Missing file is fine — returns defaults.
    pub fn load(path: Option<&Path>) -> Result<Self> {
        let resolved = match path {
            Some(p) => p.to_path_buf(),
            None => default_config_path()?,
        };

        if !resolved.exists() {
            return Ok(Self::default());
        }

        let raw = std::fs::read_to_string(&resolved)
            .with_context(|| format!("reading config {}", resolved.display()))?;
        let cfg: Config =
            toml::from_str(&raw).with_context(|| format!("parsing config {}", resolved.display()))?;
        Ok(cfg)
    }

    /// Resolved fred state directory.
    pub fn fred_state_dir(&self) -> PathBuf {
        self.fred_state
            .clone()
            .unwrap_or_else(|| home_dir().join(".claude").join("state").join("fred"))
    }

    /// Resolved perri state directory.
    pub fn perri_state_dir(&self) -> PathBuf {
        self.perri_state
            .clone()
            .unwrap_or_else(|| home_dir().join(".claude").join("state").join("perri"))
    }

    /// Resolved claude bin directory.
    pub fn claude_bin_dir(&self) -> PathBuf {
        self.claude_bin
            .clone()
            .unwrap_or_else(|| home_dir().join(".claude").join("bin"))
    }

    /// Resolved Graph OAuth2 token cache path.
    pub fn graph_token_cache_path(&self) -> PathBuf {
        self.graph_token_cache.clone().unwrap_or_else(|| {
            home_dir()
                .join(".cache")
                .join("nostromo")
                .join("graph-token.json")
        })
    }

    pub fn mailbox_poll_interval(&self) -> Duration {
        Duration::from_secs(self.mailbox_poll_secs)
    }

    pub fn calendar_poll_interval(&self) -> Duration {
        Duration::from_secs(self.calendar_poll_secs)
    }

    pub fn pr_queue_poll_interval(&self) -> Duration {
        Duration::from_secs(self.pr_queue_poll_secs)
    }

    pub fn pr_diff_poll_interval(&self) -> Duration {
        Duration::from_secs(self.pr_diff_poll_secs)
    }
}

fn default_config_path() -> Result<PathBuf> {
    if let Some(proj) = directories::ProjectDirs::from("", "", "nostromo") {
        Ok(proj.config_dir().join("config.toml"))
    } else {
        Ok(home_dir().join(".config").join("nostromo").join("config.toml"))
    }
}

fn home_dir() -> PathBuf {
    std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("."))
}
