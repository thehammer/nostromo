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

/// Connect timeout for every GitHub HTTP request (raw `reqwest` and
/// `octocrab` alike), in seconds.
///
/// Short and unforgiving on purpose: a stalled TCP handshake is never
/// legitimate the way a slow body transfer sometimes is, so this doesn't
/// need the headroom [`GITHUB_HTTP_TIMEOUT_SECS`] gives the overall request.
pub const GITHUB_CONNECT_TIMEOUT_SECS: u64 = 5;

/// Overall per-request timeout for every GitHub HTTP request (connect + send
/// + full body read), in seconds.
///
/// Sized to comfortably clear a legitimate large-diff fetch (`MAX_DIFF_BYTES`
/// = 500 KB in `data::perri_pr_native`) even on a slow link, while staying
/// well under `pr_diff_poll_secs` (30s default) so a request that genuinely
/// hangs fails and frees the poll loop before the next cycle would otherwise
/// queue up behind it — see `github_timeout_is_shorter_than_the_poll_interval`
/// in `data::github_client`, which pins that relationship. Without a bound
/// here at all, a stalled connection or a half-delivered body hangs
/// indefinitely (reqwest's default), wedging every consumer of the single
/// watch-channel PR source behind it.
pub const GITHUB_HTTP_TIMEOUT_SECS: u64 = 20;

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

    /// Folder whose children are your code repos (default: `~/Code`).
    ///
    /// Overridden by the `NOSTROMO_CODE_ROOT` environment variable. A leading
    /// `~` is expanded. See [`crate::data::work::repo_docs::code_root`] for the
    /// full resolution order; the macOS app resolves it the same way.
    pub code_root: Option<PathBuf>,

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
    // NOTE: GITHUB_CONNECT_TIMEOUT_SECS / GITHUB_HTTP_TIMEOUT_SECS live just
    // below as plain `const`s, not `Config` fields — they bound one GitHub
    // HTTP attempt and must stay visibly smaller than `pr_diff_poll_secs`
    // above (see `github_timeout_is_shorter_than_the_poll_interval` in
    // `data::github_client`), which a user-configurable field would obscure.
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
    /// Kill switch for the targeted relay-update engine (default: `true`).
    ///
    /// Set `perri_targeted_relay = false` in `~/.config/nostromo/config.toml` to
    /// make every relay event trigger a full queue refresh again — the exact
    /// pre-engine behaviour, at the cost of three org-wide search calls per
    /// event.  Present so the engine can be disabled in the field without a
    /// rebuild if its per-PR verdicts turn out to disagree with the poll's.
    pub perri_targeted_relay: bool,

    /// VIP sender addresses (lowercase); emails from these addresses are
    /// highlighted in the mailbox panel.
    pub vip_senders: Vec<String>,

    // ── W4 curated-agent-views: Jira ticket provider ────────────────────────
    /// Overrides the resolved Atlassian site (e.g. `carefeed.atlassian.net`)
    /// ahead of the environment or the credentials file. See
    /// `crate::data::tickets::jira` for the full resolution order.
    pub jira_site: Option<String>,
    /// Overrides the resolved Atlassian account email ahead of the
    /// environment or the credentials file.
    pub jira_email: Option<String>,
    /// Path to a `.env`-style file carrying `ATLASSIAN_SITE_NAME` /
    /// `ATLASSIAN_USER_EMAIL` / `ATLASSIAN_API_TOKEN`. Default:
    /// `~/.claude/credentials/.env`. The token itself is never read into
    /// this struct — only this path is — so `Config`'s unredacted `Debug`
    /// derive never carries a secret.
    pub jira_credentials_path: Option<PathBuf>,

    // ── Per-agent enable switches ───────────────────────────────────────────
    /// One table per built-in agent, e.g. `[agents.fred] enabled = false`.
    /// A missing table (or missing `enabled` key) means the agent is on;
    /// `mother` cannot be switched off. Unknown keys inside a table are
    /// ignored. Kept as a raw value so a malformed `[agents]` can never fail
    /// the load; [`crate::agents::resolve`] warns and ignores what it cannot
    /// read. See [`crate::agents`].
    pub agents: Option<toml::Value>,

    // ── Fred: multiple mail/calendar accounts ───────────────────────────────
    /// `[[fred_accounts]]` entries (label, provider, optional email and
    /// token_cache). Absent = legacy single Microsoft account. Kept raw, like
    /// `agents`, so a malformed entry can never fail the load; see
    /// [`Config::resolve_fred_accounts`].
    pub fred_accounts: Option<toml::Value>,
    /// Path to the Google OAuth client JSON (Desktop app). The secret lives in
    /// that file, never in `Config` (which derives `Debug`).
    /// Default: `<config dir>/google-oauth-client.json`.
    pub google_oauth_client: Option<PathBuf>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            tcp_addr: None,
            code_root: None,
            agents: None,
            fred_accounts: None,
            google_oauth_client: None,
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
            perri_targeted_relay: true,
            vip_senders: Vec::new(),
            jira_site: None,
            jira_email: None,
            jira_credentials_path: None,
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

    /// The enabled built-in agents from the `[agents.<name>]` tables, plus
    /// warnings (unknown names, `mother` disabled) for the caller to log.
    pub fn resolve_agents(&self) -> (crate::agents::EnabledAgents, Vec<String>) {
        crate::agents::resolve(self.agents.as_ref())
    }

    /// The Fred accounts from `[[fred_accounts]]`, plus warnings (naming the
    /// entry index and the problem, never its values) for the caller to log.
    pub fn resolve_fred_accounts(&self) -> (FredAccounts, Vec<String>) {
        let Some(raw) = self.fred_accounts.as_ref() else {
            return (FredAccounts::Legacy, Vec::new());
        };
        let mut warnings = Vec::new();
        let Some(entries) = raw.as_array() else {
            warnings.push(
                "fred_accounts must be an array of tables ([[fred_accounts]]); ignoring it"
                    .to_owned(),
            );
            return (FredAccounts::Configured(Vec::new()), warnings);
        };
        let home = home_dir();
        let mut accounts: Vec<FredAccount> = Vec::new();
        for (i, entry) in entries.iter().enumerate() {
            let Some(table) = entry.as_table() else {
                warnings.push(format!("fred_accounts[{i}] is not a table; skipped"));
                continue;
            };
            let label = match table.get("label").and_then(|v| v.as_str()) {
                Some(l) if valid_account_label(l) => l.to_owned(),
                Some(_) => {
                    warnings.push(format!(
                        "fred_accounts[{i}]: label must match [a-z0-9][a-z0-9_-]{{0,31}}; skipped"
                    ));
                    continue;
                }
                None => {
                    warnings.push(format!("fred_accounts[{i}]: missing label; skipped"));
                    continue;
                }
            };
            if accounts
                .iter()
                .any(|a| a.label.eq_ignore_ascii_case(&label))
            {
                warnings.push(format!("fred_accounts[{i}]: duplicate label; skipped"));
                continue;
            }
            let provider = match table.get("provider").and_then(|v| v.as_str()) {
                Some("google") => FredProvider::Google,
                Some("microsoft") => FredProvider::Microsoft,
                _ => {
                    warnings.push(format!(
                        "fred_accounts[{i}]: provider must be \"google\" or \"microsoft\"; skipped"
                    ));
                    continue;
                }
            };
            let mut email = table
                .get("email")
                .and_then(|v| v.as_str())
                .map(|e| e.trim().to_lowercase())
                .filter(|e| !e.is_empty());
            let configured_cache = table.get("token_cache").and_then(|v| v.as_str());
            let token_cache = match provider {
                FredProvider::Google => match configured_cache.filter(|c| !c.trim().is_empty()) {
                    Some(c) => expand_tilde(c, &home),
                    None => home
                        .join(".cache")
                        .join("nostromo")
                        .join(format!("google-{label}-token.json")),
                },
                FredProvider::Microsoft => {
                    if accounts
                        .iter()
                        .any(|a| a.provider == FredProvider::Microsoft)
                    {
                        warnings.push(format!(
                            "fred_accounts[{i}]: only one microsoft account is supported; skipped"
                        ));
                        continue;
                    }
                    if email.is_some() || configured_cache.is_some() {
                        warnings.push(format!(
                            "fred_accounts[{i}]: email and token_cache are ignored for microsoft (use graph_token_cache)"
                        ));
                        email = None;
                    }
                    self.graph_token_cache_path()
                }
            };
            accounts.push(FredAccount {
                label,
                provider,
                email,
                token_cache,
            });
        }
        (FredAccounts::Configured(accounts), warnings)
    }

    /// Where the Google OAuth client JSON lives (`~` expanded).
    pub fn google_oauth_client_path(&self) -> PathBuf {
        match self
            .google_oauth_client
            .as_ref()
            .filter(|p| !p.as_os_str().is_empty())
        {
            Some(p) => expand_tilde(&p.to_string_lossy(), &home_dir()),
            None => default_config_path()
                .ok()
                .and_then(|p| p.parent().map(Path::to_path_buf))
                .unwrap_or_else(|| home_dir().join(".config").join("nostromo"))
                .join("google-oauth-client.json"),
        }
    }

    /// Folder whose children are the code repos. Resolution order:
    /// `$NOSTROMO_CODE_ROOT` → `code_root` in `config.toml` → `~/Code`.
    /// A leading `~` is expanded in either source.
    pub fn code_root_dir(&self) -> PathBuf {
        resolve_code_root(
            std::env::var_os("NOSTROMO_CODE_ROOT").as_deref(),
            self.code_root.as_deref(),
            &home_dir(),
        )
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
    /// → `DEFAULT_TCP_ADDR` (`127.0.0.1:47100`, loopback only; the TCP listener has no
    /// authentication, so only set `NOSTROMD_TCP_ADDR` to a LAN address on a network you trust).
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

/// Which backend serves a Fred account.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FredProvider {
    Google,
    Microsoft,
}

/// One resolved `[[fred_accounts]]` entry.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FredAccount {
    pub label: String,
    pub provider: FredProvider,
    /// Lower-cased; the login hint and the expected identity (Google).
    pub email: Option<String>,
    pub token_cache: PathBuf,
}

/// Result of [`Config::resolve_fred_accounts`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FredAccounts {
    /// No `fred_accounts` key: the original single Microsoft code path.
    Legacy,
    Configured(Vec<FredAccount>),
}

/// `^[a-z0-9][a-z0-9_-]{0,31}$`. No `:` so a label can prefix item ids.
fn valid_account_label(label: &str) -> bool {
    let mut chars = label.chars();
    let first_ok = chars
        .next()
        .is_some_and(|c| c.is_ascii_lowercase() || c.is_ascii_digit());
    first_ok
        && label.len() <= 32
        && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
}

fn expand_tilde(path: &str, home: &Path) -> PathBuf {
    match path.strip_prefix("~/") {
        Some(rest) => home.join(rest),
        None if path == "~" => home.to_path_buf(),
        None => PathBuf::from(path),
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

/// Pure core of [`Config::code_root_dir`]: `env` wins over `configured`, which
/// wins over `<home>/Code`. Empty values are ignored; a leading `~` expands to `home`.
pub fn resolve_code_root(
    env: Option<&std::ffi::OsStr>,
    configured: Option<&Path>,
    home: &Path,
) -> PathBuf {
    let chosen = env
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .or_else(|| {
            configured
                .filter(|p| !p.as_os_str().is_empty())
                .map(Path::to_path_buf)
        });
    match chosen {
        Some(p) => match p.strip_prefix("~") {
            Ok(rest) => home.join(rest),
            Err(_) => p,
        },
        None => home.join("Code"),
    }
}

fn home_dir() -> PathBuf {
    std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("."))
}

#[cfg(test)]
mod code_root_tests {
    use super::*;
    use std::ffi::OsStr;

    const HOME: &str = "/Users/me";

    fn resolve(env: Option<&str>, cfg: Option<&str>) -> PathBuf {
        resolve_code_root(env.map(OsStr::new), cfg.map(Path::new), Path::new(HOME))
    }

    #[test]
    fn defaults_to_home_code_so_existing_setups_are_unchanged() {
        assert_eq!(resolve(None, None), PathBuf::from("/Users/me/Code"));
    }

    #[test]
    fn config_overrides_the_default() {
        assert_eq!(resolve(None, Some("/work/src")), PathBuf::from("/work/src"));
    }

    #[test]
    fn env_overrides_config() {
        assert_eq!(
            resolve(Some("/env"), Some("/work/src")),
            PathBuf::from("/env")
        );
    }

    #[test]
    fn empty_values_fall_through() {
        assert_eq!(resolve(Some(""), Some("")), PathBuf::from("/Users/me/Code"));
        assert_eq!(
            resolve(Some(""), Some("/work/src")),
            PathBuf::from("/work/src")
        );
    }

    #[test]
    fn tilde_expands() {
        assert_eq!(
            resolve(None, Some("~/Software Development")),
            PathBuf::from("/Users/me/Software Development")
        );
        assert_eq!(resolve(Some("~"), None), PathBuf::from("/Users/me"));
    }

    #[test]
    fn parses_from_toml() {
        let cfg: Config = toml::from_str("code_root = \"~/Software Development\"").unwrap();
        assert_eq!(cfg.code_root, Some(PathBuf::from("~/Software Development")));
    }
}

#[cfg(test)]
mod agents_tests {
    use super::*;

    fn parse(s: &str) -> Config {
        toml::from_str::<Config>(s).unwrap()
    }

    #[test]
    fn no_agents_table_enables_everything() {
        let (e, w) = parse("").resolve_agents();
        assert_eq!(e, crate::agents::EnabledAgents::all());
        assert!(w.is_empty());
    }

    #[test]
    fn fred_disabled_disables_only_fred() {
        let (e, _) = parse("[agents.fred]\nenabled = false\n").resolve_agents();
        assert!(!e.fred && e.perri && e.teri);
    }

    #[test]
    fn empty_agent_table_keeps_it_enabled() {
        let (e, _) = parse("[agents.perri]\n").resolve_agents();
        assert!(e.perri);
    }

    #[test]
    fn extra_keys_are_ignored() {
        let (e, w) =
            parse("[agents.fred]\nenabled = false\nmail_provider = \"gmail\"\n").resolve_agents();
        assert!(!e.fred);
        assert!(w.is_empty());
    }

    #[test]
    fn mother_disabled_is_ignored_with_a_warning() {
        let (e, w) = parse("[agents.mother]\nenabled = false\n").resolve_agents();
        assert_eq!(e, crate::agents::EnabledAgents::all());
        assert_eq!(w.len(), 1);
        assert!(w[0].contains("mother"));
    }

    #[test]
    fn unknown_agent_is_ignored_with_a_warning() {
        let (e, w) = parse("[agents.bob]\nenabled = false\n").resolve_agents();
        assert_eq!(e, crate::agents::EnabledAgents::all());
        assert_eq!(w.len(), 1);
        assert!(w[0].contains("bob"));
    }

    #[test]
    fn malformed_agents_shapes_never_fail_the_load() {
        for src in [
            "[agents]\nfred = false\n",
            "[agents.fred]\nenabled = \"no\"\n",
            "agents = 3\n",
        ] {
            let cfg = toml::from_str::<Config>(src).expect(src);
            let (e, w) = cfg.resolve_agents();
            assert_eq!(e, crate::agents::EnabledAgents::all(), "{src}");
            assert_eq!(w.len(), 1, "{src}");
        }
    }
}

#[cfg(test)]
mod fred_accounts_tests {
    use super::*;

    fn parse(s: &str) -> Config {
        toml::from_str::<Config>(s).unwrap()
    }

    #[test]
    fn absent_means_legacy() {
        let (a, w) = parse("").resolve_fred_accounts();
        assert_eq!(a, FredAccounts::Legacy);
        assert!(w.is_empty());
    }

    #[test]
    fn two_google_accounts_resolve_in_order_with_default_token_paths() {
        let cfg = parse(
            "[[fred_accounts]]\nlabel = \"personal\"\nprovider = \"google\"\nemail = \" Me@Gmail.com \"\n\
             [[fred_accounts]]\nlabel = \"family\"\nprovider = \"google\"\n",
        );
        let (a, w) = cfg.resolve_fred_accounts();
        assert!(w.is_empty(), "{w:?}");
        let FredAccounts::Configured(list) = a else {
            panic!("expected configured")
        };
        assert_eq!(list.len(), 2);
        assert_eq!(list[0].label, "personal");
        assert_eq!(list[0].email.as_deref(), Some("me@gmail.com"));
        assert!(list[0]
            .token_cache
            .ends_with(".cache/nostromo/google-personal-token.json"));
        assert!(list[1].token_cache.ends_with("google-family-token.json"));
    }

    #[test]
    fn invalid_entries_are_skipped_with_a_warning_that_omits_values() {
        let cfg = parse(
            "[[fred_accounts]]\nlabel = \"Bad:Label\"\nprovider = \"google\"\n\
             [[fred_accounts]]\nlabel = \"ok\"\nprovider = \"google\"\n\
             [[fred_accounts]]\nlabel = \"OK\"\nprovider = \"google\"\n\
             [[fred_accounts]]\nlabel = \"odd\"\nprovider = \"yahoo\"\n\
             [[fred_accounts]]\nlabel = \"work\"\nprovider = \"microsoft\"\n\
             [[fred_accounts]]\nlabel = \"work2\"\nprovider = \"microsoft\"\n",
        );
        let (a, w) = cfg.resolve_fred_accounts();
        let FredAccounts::Configured(list) = a else {
            panic!("expected configured")
        };
        let labels: Vec<&str> = list.iter().map(|a| a.label.as_str()).collect();
        assert_eq!(labels, ["ok", "work"]);
        assert_eq!(w.len(), 4, "{w:?}");
        assert!(w
            .iter()
            .all(|m| !m.contains("Bad:Label") && !m.contains("yahoo")));
        assert!(w[0].contains("fred_accounts[0]"));
    }

    #[test]
    fn non_array_value_is_configured_empty_with_a_warning() {
        let (a, w) = parse("fred_accounts = 3\n").resolve_fred_accounts();
        assert_eq!(a, FredAccounts::Configured(vec![]));
        assert_eq!(w.len(), 1);
    }

    #[test]
    fn tilde_expands_in_token_cache() {
        let cfg = parse("[[fred_accounts]]\nlabel = \"a\"\nprovider = \"google\"\ntoken_cache = \"~/tok.json\"\n");
        let (a, _) = cfg.resolve_fred_accounts();
        let FredAccounts::Configured(list) = a else {
            panic!()
        };
        assert_eq!(list[0].token_cache, home_dir().join("tok.json"));
    }

    #[test]
    fn microsoft_entry_ignores_email_and_token_cache_with_a_warning() {
        let cfg = parse(
            "[[fred_accounts]]\nlabel = \"w\"\nprovider = \"microsoft\"\nemail = \"a@b.c\"\n",
        );
        let (a, w) = cfg.resolve_fred_accounts();
        let FredAccounts::Configured(list) = a else {
            panic!()
        };
        assert_eq!(list[0].email, None);
        assert_eq!(list[0].token_cache, cfg.graph_token_cache_path());
        assert_eq!(w.len(), 1);
    }

    #[test]
    fn malformed_shapes_never_fail_the_load() {
        for src in [
            "fred_accounts = \"x\"\n",
            "[fred_accounts]\nlabel = \"a\"\n",
            "fred_accounts = [1, 2]\n",
            "[[fred_accounts]]\nlabel = 5\n",
        ] {
            let cfg = toml::from_str::<Config>(src).expect(src);
            let (a, w) = cfg.resolve_fred_accounts();
            assert_eq!(a, FredAccounts::Configured(vec![]), "{src}");
            assert!(!w.is_empty(), "{src}");
        }
    }

    #[test]
    fn oauth_client_path_defaults_next_to_the_config_and_expands_tilde() {
        assert!(parse("")
            .google_oauth_client_path()
            .ends_with("google-oauth-client.json"));
        let cfg = parse("google_oauth_client = \"~/c.json\"\n");
        assert_eq!(cfg.google_oauth_client_path(), home_dir().join("c.json"));
    }
}
