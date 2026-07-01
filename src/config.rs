//! Configuration loader.
//!
//! Reads `~/.config/nostromo/config.toml` (or a path override).  All fields
//! are optional — sane defaults are used when absent.

use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

/// Environment variable that overrides the TCP listen address.
pub const TCP_ADDR_ENV: &str = "NOSTROMD_TCP_ADDR";

/// Default TCP listen address when no override is present.
///
/// **Loopback-only by default.**  Phase 0 carries no authentication; binding
/// to `0.0.0.0` would expose PTY-spawn and session-control to any host on the
/// LAN.  To accept connections from iOS / other LAN clients set
/// `tcp_addr = "0.0.0.0:47100"` in `config.toml` or export
/// `NOSTROMD_TCP_ADDR=0.0.0.0:47100`.  The daemon will log a prominent
/// warning whenever the resolved address is non-loopback.
pub const DEFAULT_TCP_ADDR: &str = "127.0.0.1:47100";

/// Top-level config struct.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    /// TCP address to bind the iOS/LAN listener on (default: `0.0.0.0:47100`).
    ///
    /// Overridden by the `NOSTROMD_TCP_ADDR` environment variable.  Set to
    /// `null` in `config.toml` to use the default.  Plaintext only (Phase 0);
    /// TLS is added in Phase 5.
    pub tcp_addr: Option<SocketAddr>,

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
    /// How long (in seconds) to suppress a just-approved PR from the queue.
    ///
    /// Covers the GitHub search-index lag window (typically seconds to low minutes).
    /// After this many seconds the suppression entry expires and the PR reappears
    /// even if the search index never caught up.  Default: 900 (15 min).
    pub pr_approval_suppress_secs: u64,

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

    // ── github-relay subscriber ─────────────────────────────────────────────
    /// WebSocket URL of the github-relay service.
    /// Example: `"wss://github-relay.carefeed.com/subscribe"`
    /// When set (along with `relay_token`), nostromd connects as a subscriber
    /// and triggers an immediate queue refresh on every relevant GitHub event,
    /// reducing the visible PR-queue lag from the poll interval to ~3 seconds.
    pub relay_url: Option<String>,
    /// Bearer token for the github-relay WebSocket endpoint.
    /// Obtain via `https://github-relay.carefeed.com/auth/token` (VPN required).
    pub relay_token: Option<String>,

    /// VIP sender addresses (lowercase); emails from these addresses are
    /// highlighted in the mailbox panel.
    pub vip_senders: Vec<String>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            tcp_addr: None,
            fred_state: None,
            perri_state: None,
            claude_bin: None,
            mailbox_poll_secs: 60,
            calendar_poll_secs: 120,
            pr_queue_poll_secs: 60,
            pr_diff_poll_secs: 30,
            pr_approval_suppress_secs: 900,
            graph_client_id: None,
            graph_tenant: None,
            graph_token_cache: None,
            github_token_path: None,
            relay_url: None,
            relay_token: None,
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
        let cfg: Config = toml::from_str(&raw)
            .with_context(|| format!("parsing config {}", resolved.display()))?;
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

    /// Resolved TCP listen address.
    ///
    /// Resolution order: `NOSTROMD_TCP_ADDR` env var → `config.toml tcp_addr`
    /// → `DEFAULT_TCP_ADDR` (`0.0.0.0:47100`).
    pub fn tcp_listen_addr(&self) -> SocketAddr {
        if let Ok(v) = std::env::var(TCP_ADDR_ENV) {
            if let Ok(addr) = v.parse() {
                return addr;
            }
        }
        self.tcp_addr
            .unwrap_or_else(|| DEFAULT_TCP_ADDR.parse().expect("valid default TCP addr"))
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
        Ok(home_dir()
            .join(".config")
            .join("nostromo")
            .join("config.toml"))
    }
}

fn home_dir() -> PathBuf {
    std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("."))
}
