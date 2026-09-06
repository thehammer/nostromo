//! The `jira` [`TicketProvider`](super::TicketProvider) — v1's only
//! registered provider (W4 — curated-agent-views, D2/D3).
//!
//! Uses Jira Cloud's REST **v3** issue endpoint, whose `description`/comment
//! bodies are ADF (Atlassian Document Format) — a structured JSON document
//! that maps almost one-to-one onto `MdBlock`/`MdSpan` — rather than v2's
//! wiki-markup string, which would need a bespoke parser. See [`adf_to_blocks`].
//!
//! # Credential resolution (D3)
//!
//! `nostromd` runs as a launchd user agent and does not inherit the shell
//! environment, so credentials cannot rely on `~/.claude/credentials/.env`
//! being sourced. Resolution order, mirroring
//! `crate::data::github_client::resolve_token`:
//!
//! 1. `ATLASSIAN_SITE_NAME` / `ATLASSIAN_USER_EMAIL` / `ATLASSIAN_API_TOKEN`
//!    from the process environment, if present.
//! 2. The same three keys parsed out of the credentials file
//!    (`Config::jira_credentials_path`, default `~/.claude/credentials/.env`).
//! 3. `Config::jira_site` / `Config::jira_email` override either of the
//!    first two fields when set.
//!
//! The token is **never** added to `Config` (which derives `Debug` and is
//! not redacted) — it is resolved here and held only on [`JiraProvider`],
//! behind a `Debug` impl that redacts it.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use async_trait::async_trait;
use serde_json::Value;

use super::{Ticket, TicketComment, TicketProvider};
use crate::config::Config;
use crate::ipc::protocol::{MdBlock, MdSpan};

/// Jira Cloud REST v3's issue-fetch base path. Production base URL is
/// `https://{site}`; tests point [`JiraProvider`] at a `wiremock` server
/// instead.
const ISSUE_FIELDS: &str = "summary,status,assignee,description,comment";

// ── credentials ───────────────────────────────────────────────────────────────

/// Resolved Jira credentials. `Debug` redacts `token` — see the module doc's
/// "never logged" requirement.
#[derive(Clone)]
pub struct JiraCredentials {
    pub site: String,
    pub email: String,
    token: String,
}

impl JiraCredentials {
    /// Test seam so other modules' tests (`apply_layout`/`refresh_pane`) can
    /// construct credentials without reaching into a private field directly.
    #[cfg(test)]
    pub(crate) fn for_test(site: &str, email: &str, token: &str) -> Self {
        Self { site: site.to_string(), email: email.to_string(), token: token.to_string() }
    }
}

impl std::fmt::Debug for JiraCredentials {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("JiraCredentials")
            .field("site", &self.site)
            .field("email", &self.email)
            .field("token", &"<redacted>")
            .finish()
    }
}

/// The three environment/credentials-file variable names this provider
/// resolves — named once so the unconfigured message and the resolver can't
/// disagree about what they're called.
const ENV_SITE: &str = "ATLASSIAN_SITE_NAME";
const ENV_EMAIL: &str = "ATLASSIAN_USER_EMAIL";
const ENV_TOKEN: &str = "ATLASSIAN_API_TOKEN";

/// Default credentials file, mirroring `~/.claude/credentials/.env` (shared
/// with the shell tooling in `~/.claude/layers/carefeed/lib/services/jira.sh`,
/// though that script speaks v2 — not a constraint here, see the W4 plan's D2).
pub fn default_credentials_path() -> PathBuf {
    dirs_next::home_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join(".claude")
        .join("credentials")
        .join(".env")
}

/// Resolve credentials per the module doc's three-source precedence.
/// `Ok(None)` (not an error) when any of the three fields can't be
/// resolved from any source — the caller turns that into
/// `provider_unconfigured`, not a hard failure.
pub fn resolve_credentials(config: &Config) -> Option<JiraCredentials> {
    let path = config
        .jira_credentials_path
        .clone()
        .unwrap_or_else(default_credentials_path);
    let file_vars = read_env_file(&path);

    let env_var = |k: &str| std::env::var(k).ok().filter(|s| !s.is_empty());
    // Same "blank is absent" rule as `env_var` above — a half-filled-in
    // credentials file (a key present with an empty value, e.g.
    // `ATLASSIAN_API_TOKEN=`) must resolve to "not configured" and surface
    // the actionable `provider_unconfigured` message, not silently proceed
    // with an empty token/site/email and fail as an opaque 401 instead.
    let file_var = |k: &str| file_vars.get(k).cloned().filter(|s| !s.is_empty());

    let site = config
        .jira_site
        .clone()
        .filter(|s| !s.is_empty())
        .or_else(|| env_var(ENV_SITE))
        .or_else(|| file_var(ENV_SITE));
    let email = config
        .jira_email
        .clone()
        .filter(|s| !s.is_empty())
        .or_else(|| env_var(ENV_EMAIL))
        .or_else(|| file_var(ENV_EMAIL));
    let token = env_var(ENV_TOKEN).or_else(|| file_var(ENV_TOKEN));

    match (site, email, token) {
        (Some(site), Some(email), Some(token)) => Some(JiraCredentials { site, email, token }),
        _ => None,
    }
}

/// The actionable `provider_unconfigured` message: names the credential file
/// and all three variable names.
fn unconfigured_message(credentials_path: &Path) -> String {
    format!(
        "Jira provider is not configured: could not resolve {ENV_SITE}, {ENV_EMAIL}, and \
         {ENV_TOKEN} from the environment or from {}. Set them in the environment, add them to \
         that file, or set jira_site/jira_email in ~/.config/nostromo/config.toml.",
        credentials_path.display()
    )
}

/// Parse `KEY=VALUE` lines from a `.env`-style file. Missing/unreadable file
/// returns an empty map rather than an error — the caller (`resolve_credentials`)
/// treats "no file" and "file present but incomplete" identically.
fn read_env_file(path: &Path) -> HashMap<String, String> {
    let mut map = HashMap::new();
    let Ok(contents) = std::fs::read_to_string(path) else {
        return map;
    };
    for line in contents.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((k, v)) = line.split_once('=') else {
            continue;
        };
        let k = k.trim().to_string();
        let mut v = v.trim().to_string();
        if v.len() >= 2
            && ((v.starts_with('"') && v.ends_with('"'))
                || (v.starts_with('\'') && v.ends_with('\'')))
        {
            v = v[1..v.len() - 1].to_string();
        }
        map.insert(k, v);
    }
    map
}

// ── provider ─────────────────────────────────────────────────────────────────

/// The `jira` provider. Constructed once at daemon startup
/// (`src/bin/nostromd.rs`); credentials are resolved then and held for the
/// process lifetime — a changed credentials file needs a daemon restart to
/// take effect, same as every other native data source's config.
pub struct JiraProvider {
    credentials: Option<JiraCredentials>,
    unconfigured_message: String,
    base_url: String,
    http: reqwest::Client,
}

impl JiraProvider {
    /// Build the production provider, resolving credentials from `config`
    /// (environment → credentials file → `config.toml` override, per the
    /// module doc).
    pub fn new(config: &Config) -> Self {
        let credentials_path = config
            .jira_credentials_path
            .clone()
            .unwrap_or_else(default_credentials_path);
        let credentials = resolve_credentials(config);
        let base_url = credentials
            .as_ref()
            .map(|c| format!("https://{}", c.site))
            .unwrap_or_default();
        Self {
            credentials,
            unconfigured_message: unconfigured_message(&credentials_path),
            base_url,
            http: reqwest::Client::new(),
        }
    }

    /// Test seam: an explicit credentials + base URL, bypassing config/env/
    /// file resolution entirely — every `jira.rs` test builds its provider
    /// this way, pointed at a `wiremock::MockServer::uri()`. `pub(crate)`
    /// (not module-private) so `apply_layout`/`refresh_pane`'s own tests can
    /// build a registry with a mock-backed `jira` provider too.
    #[cfg(test)]
    pub(crate) fn for_test(credentials: Option<JiraCredentials>, base_url: String) -> Self {
        Self {
            credentials,
            unconfigured_message: unconfigured_message(&default_credentials_path()),
            base_url,
            http: reqwest::Client::new(),
        }
    }

    fn ticket_from_json(&self, key: &str, body: &Value) -> Ticket {
        let fields = body.get("fields").cloned().unwrap_or(Value::Null);
        let summary = fields
            .get("summary")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let status = fields
            .get("status")
            .and_then(|s| s.get("name"))
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let assignee = fields
            .get("assignee")
            .and_then(|a| a.get("displayName"))
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());

        let description_blocks = adf_to_blocks(fields.get("description").unwrap_or(&Value::Null));
        let aliases = super::config::load();
        let sections = super::derive_sections(description_blocks, &aliases);

        let comments_json = fields
            .get("comment")
            .and_then(|c| c.get("comments"))
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default();
        let comments: Vec<TicketComment> = comments_json
            .iter()
            .enumerate()
            .map(|(i, c)| {
                let author = c
                    .get("author")
                    .and_then(|a| a.get("displayName"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                // Jira Cloud's REST API sends `created` as
                // "2024-01-01T00:00:00.000+0000" — a numeric offset with NO
                // colon, which `parse_from_rfc3339` rejects outright (RFC
                // 3339 requires "+00:00"). Try RFC 3339 first anyway (covers
                // wiremock fixtures and any future Jira response shape that
                // does include the colon), then fall back to the format
                // Jira actually sends. Only if *both* fail do we give up —
                // and even then, fabricating "now" would present a comment
                // as freshly written when its real age is simply unknown to
                // us; falling back to the epoch (the same "honest unknown"
                // convention the Swift-side decoder already uses for this
                // exact field) makes that failure visible instead of
                // plausible-looking.
                let created_at = c
                    .get("created")
                    .and_then(|v| v.as_str())
                    .and_then(|s| {
                        chrono::DateTime::parse_from_rfc3339(s)
                            .or_else(|_| chrono::DateTime::parse_from_str(s, "%Y-%m-%dT%H:%M:%S%.f%z"))
                            .ok()
                    })
                    .map(|dt| dt.with_timezone(&chrono::Utc))
                    .unwrap_or_else(|| {
                        chrono::DateTime::from_timestamp(0, 0).expect("epoch is always valid")
                    });
                let blocks = adf_to_blocks(c.get("body").unwrap_or(&Value::Null));
                TicketComment { index: (i + 1) as u32, author, created_at, blocks }
            })
            .collect();

        let site = self.credentials.as_ref().map(|c| c.site.clone()).unwrap_or_default();
        Ticket {
            provider: "jira".to_string(),
            key: key.to_string(),
            summary,
            status,
            assignee,
            url: format!("https://{site}/browse/{key}"),
            sections,
            comments,
        }
    }
}

#[async_trait]
impl TicketProvider for JiraProvider {
    fn name(&self) -> &'static str {
        "jira"
    }

    fn is_configured(&self) -> bool {
        self.credentials.is_some()
    }

    fn unconfigured_message(&self) -> String {
        self.unconfigured_message.clone()
    }

    async fn fetch(&self, key: &str) -> Result<Ticket, super::TicketError> {
        let creds = self.credentials.as_ref().ok_or_else(|| {
            super::TicketError::ProviderUnconfigured { message: self.unconfigured_message.clone() }
        })?;

        // `key` is spliced unescaped into the request path below. A real
        // Jira issue key is always `<PROJECT>-<number>` (letters/digits for
        // the project prefix, a dash, then digits) — reject anything else
        // before it can reach the request, rather than let a `/`, `?`, `#`,
        // or `..` in an agent-supplied key redirect this authenticated
        // request to a different path or query on the same Jira tenant.
        // `UnknownTicket` (not a new error variant): a key that can never be
        // a real issue key can never resolve to a real ticket either.
        let valid_key = {
            let mut parts = key.splitn(2, '-');
            match (parts.next(), parts.next()) {
                (Some(project), Some(number)) => {
                    !project.is_empty()
                        && !number.is_empty()
                        && project.chars().all(|c| c.is_ascii_alphanumeric())
                        && number.chars().all(|c| c.is_ascii_digit())
                }
                _ => false,
            }
        };
        if !valid_key {
            return Err(super::TicketError::UnknownTicket);
        }

        let url = format!("{}/rest/api/3/issue/{key}", self.base_url);
        let resp = self
            .http
            .get(&url)
            .basic_auth(&creds.email, Some(&creds.token))
            .query(&[("fields", ISSUE_FIELDS)])
            .send()
            .await
            .map_err(|e| super::TicketError::FetchFailed(format!("jira request failed: {e}")))?;

        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Err(super::TicketError::UnknownTicket);
        }
        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            return Err(super::TicketError::FetchFailed(format!(
                "jira responded {status}: {body}"
            )));
        }

        let body: Value = resp
            .json()
            .await
            .map_err(|e| super::TicketError::FetchFailed(format!("parsing jira response: {e}")))?;
        Ok(self.ticket_from_json(key, &body))
    }
}

// ── ADF → MdBlock mapper (D2) ─────────────────────────────────────────────────

/// Convert an ADF document (or `Value::Null` — no description) into blocks.
/// Pure — no network, no `self`.
pub fn adf_to_blocks(doc: &Value) -> Vec<MdBlock> {
    children(doc).iter().map(node_to_block).collect()
}

fn children(node: &Value) -> Vec<Value> {
    node.get("content")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default()
}

fn node_type(node: &Value) -> &str {
    node.get("type").and_then(|v| v.as_str()).unwrap_or("")
}

fn node_to_block(node: &Value) -> MdBlock {
    match node_type(node) {
        "paragraph" => MdBlock::Paragraph { spans: inline_spans(node) },
        "heading" => {
            let level = node
                .get("attrs")
                .and_then(|a| a.get("level"))
                .and_then(|v| v.as_u64())
                .unwrap_or(1) as u8;
            MdBlock::Heading { level, spans: inline_spans(node) }
        }
        "codeBlock" => {
            let lang = node
                .get("attrs")
                .and_then(|a| a.get("language"))
                .and_then(|v| v.as_str())
                .map(|s| s.to_string());
            MdBlock::CodeBlock { lang, text: code_text(node) }
        }
        "bulletList" => MdBlock::List { ordered: false, start: None, items: list_items(node) },
        "orderedList" => {
            let start = node.get("attrs").and_then(|a| a.get("order")).and_then(|v| v.as_u64());
            MdBlock::List { ordered: true, start, items: list_items(node) }
        }
        "blockquote" => MdBlock::Quote { blocks: child_blocks(node) },
        "rule" => MdBlock::Rule,
        "table" => table_block(node),
        // Unknown node type — never dropped: fold its recursively-extracted
        // text into a plain paragraph rather than silently omitting part of
        // the ticket (D2/module doc).
        _ => MdBlock::Paragraph { spans: vec![MdSpan::Text { text: extract_text(node) }] },
    }
}

fn child_blocks(node: &Value) -> Vec<MdBlock> {
    children(node).iter().map(node_to_block).collect()
}

fn list_items(node: &Value) -> Vec<Vec<MdBlock>> {
    children(node).iter().map(child_blocks).collect()
}

fn code_text(node: &Value) -> String {
    children(node)
        .iter()
        .filter_map(|n| n.get("text").and_then(|v| v.as_str()).map(|s| s.to_string()))
        .collect::<Vec<_>>()
        .join("")
}

fn table_block(node: &Value) -> MdBlock {
    let mut header = Vec::new();
    let mut rows = Vec::new();
    for row in children(node) {
        let cells = children(&row);
        let is_header_row =
            !cells.is_empty() && cells.iter().all(|c| node_type(c) == "tableHeader");
        let row_spans: Vec<Vec<MdSpan>> = cells.iter().map(cell_spans).collect();
        if is_header_row && header.is_empty() {
            header = row_spans;
        } else {
            rows.push(row_spans);
        }
    }
    MdBlock::Table { header, rows }
}

fn cell_spans(cell: &Value) -> Vec<MdSpan> {
    children(cell).iter().flat_map(inline_spans).collect()
}

/// Extract this block node's own inline content as spans (its immediate
/// `content` array of inline nodes — text/marks — not child blocks).
fn inline_spans(node: &Value) -> Vec<MdSpan> {
    children(node).iter().map(text_node_to_span).collect()
}

/// Nesting order for a `text` node's marks, outermost first:
/// `strong` > `emph` > `strike` > `code`/`link`/plain text. `code` and
/// `link` are mutually exclusive with each other in practice and are applied
/// before the styling marks wrap them.
fn text_node_to_span(node: &Value) -> MdSpan {
    if node_type(node) != "text" {
        // An inline node type this mapper doesn't recognise — fold its text
        // in rather than drop it (same rule as `node_to_block`'s fallback).
        return MdSpan::Text { text: extract_text(node) };
    }

    let text = node.get("text").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let marks = node.get("marks").and_then(|v| v.as_array()).cloned().unwrap_or_default();
    let mark_types: Vec<&str> =
        marks.iter().filter_map(|m| m.get("type").and_then(|t| t.as_str())).collect();

    let mut span = if mark_types.contains(&"code") {
        MdSpan::Code { text: text.clone() }
    } else if let Some(link_mark) = marks.iter().find(|m| m.get("type").and_then(|t| t.as_str()) == Some("link"))
    {
        let url = link_mark
            .get("attrs")
            .and_then(|a| a.get("href"))
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        MdSpan::Link { spans: vec![MdSpan::Text { text: text.clone() }], url }
    } else {
        MdSpan::Text { text: text.clone() }
    };

    if mark_types.contains(&"strike") {
        span = MdSpan::Strike { spans: vec![span] };
    }
    if mark_types.contains(&"em") {
        span = MdSpan::Emph { spans: vec![span] };
    }
    if mark_types.contains(&"strong") {
        span = MdSpan::Strong { spans: vec![span] };
    }
    span
}

/// Recursively join every `text` leaf under `node`, depth-first, space
/// separated — the fallback for a block/inline node type this mapper
/// doesn't recognise.
fn extract_text(node: &Value) -> String {
    if node_type(node) == "text" {
        return node.get("text").and_then(|v| v.as_str()).unwrap_or("").to_string();
    }
    children(node)
        .iter()
        .map(extract_text)
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

// ── tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::data::tickets::TicketError;
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    /// The three credential env vars are global process state; tests that set
    /// them must be serialized against each other (and clean up on exit) or
    /// they can interfere with one another when the test binary runs them
    /// concurrently on separate threads.
    static ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    fn clear_env_vars() {
        std::env::remove_var(ENV_SITE);
        std::env::remove_var(ENV_EMAIL);
        std::env::remove_var(ENV_TOKEN);
    }

    /// A `Config` pointed at a credentials file path that is guaranteed not
    /// to exist, so `resolve_credentials`'s file layer is reliably empty
    /// regardless of what happens to live in the real
    /// `~/.claude/credentials/.env` on the machine running the test.
    fn config_with_no_credentials_file(tmp: &std::path::Path) -> Config {
        Config {
            jira_credentials_path: Some(tmp.join("does-not-exist.env")),
            ..Config::default()
        }
    }

    // ── credential resolution (pure, no network) ─────────────────────────────

    // 1. Environment variables alone resolve credentials.
    #[test]
    fn resolve_credentials_from_environment_variables_alone() {
        let _guard = ENV_LOCK.lock().unwrap();
        clear_env_vars();
        std::env::set_var(ENV_SITE, "acme.atlassian.net");
        std::env::set_var(ENV_EMAIL, "hammer@acme.com");
        std::env::set_var(ENV_TOKEN, "tok-from-env");

        let tmp = tempfile::tempdir().unwrap();
        let config = config_with_no_credentials_file(tmp.path());
        let creds =
            resolve_credentials(&config).expect("env vars alone must resolve credentials");
        assert_eq!(creds.site, "acme.atlassian.net");
        assert_eq!(creds.email, "hammer@acme.com");
        assert_eq!(creds.token, "tok-from-env");

        clear_env_vars();
    }

    // 2. A credentials file resolves when the environment is empty.
    #[test]
    fn resolve_credentials_from_a_credentials_file_when_environment_is_empty() {
        let _guard = ENV_LOCK.lock().unwrap();
        clear_env_vars();

        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join(".env");
        std::fs::write(
            &path,
            "ATLASSIAN_SITE_NAME=file.atlassian.net\n\
             ATLASSIAN_USER_EMAIL=file@acme.com\n\
             ATLASSIAN_API_TOKEN=tok-from-file\n",
        )
        .unwrap();

        let config = Config { jira_credentials_path: Some(path), ..Config::default() };
        let creds =
            resolve_credentials(&config).expect("file-sourced credentials must resolve");
        assert_eq!(creds.site, "file.atlassian.net");
        assert_eq!(creds.email, "file@acme.com");
        assert_eq!(creds.token, "tok-from-file");
    }

    /// A credentials file with a key present but blank (a half-filled-in
    /// template, e.g. `ATLASSIAN_API_TOKEN=`) must resolve the same as a
    /// missing key — `provider_unconfigured`, not `Some("")` silently
    /// carried through to a real HTTP call.
    #[test]
    fn a_blank_value_in_the_credentials_file_is_treated_as_absent_not_present() {
        let _guard = ENV_LOCK.lock().unwrap();
        clear_env_vars();

        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join(".env");
        std::fs::write(
            &path,
            "ATLASSIAN_SITE_NAME=file.atlassian.net\n\
             ATLASSIAN_USER_EMAIL=file@acme.com\n\
             ATLASSIAN_API_TOKEN=\n",
        )
        .unwrap();

        let config = Config { jira_credentials_path: Some(path), ..Config::default() };
        assert!(
            resolve_credentials(&config).is_none(),
            "a blank token value must resolve to unconfigured, not Some(\"\")"
        );
    }

    // 3. Config::jira_site/jira_email override env/file for those two fields;
    //    the token is never overridable via config.toml (it has no field for
    //    it at all).
    #[test]
    fn config_jira_site_and_email_override_environment_but_never_the_token() {
        let _guard = ENV_LOCK.lock().unwrap();
        clear_env_vars();
        std::env::set_var(ENV_SITE, "env-site.atlassian.net");
        std::env::set_var(ENV_EMAIL, "env-email@acme.com");
        std::env::set_var(ENV_TOKEN, "tok-from-env");

        let tmp = tempfile::tempdir().unwrap();
        let config = Config {
            jira_site: Some("config-site.atlassian.net".into()),
            jira_email: Some("config-email@acme.com".into()),
            jira_credentials_path: Some(tmp.path().join("does-not-exist.env")),
            ..Config::default()
        };
        let creds = resolve_credentials(&config).unwrap();
        assert_eq!(
            creds.site, "config-site.atlassian.net",
            "config.jira_site must override the environment"
        );
        assert_eq!(
            creds.email, "config-email@acme.com",
            "config.jira_email must override the environment"
        );
        assert_eq!(
            creds.token, "tok-from-env",
            "the token has no config.toml override — it can only come from env/file"
        );

        clear_env_vars();
    }

    // 4. Any of the three missing (all sources) resolves to None; the
    //    constructed provider is unconfigured and its message is actionable.
    #[test]
    fn missing_any_credential_field_from_every_source_leaves_the_provider_unconfigured() {
        let _guard = ENV_LOCK.lock().unwrap();
        clear_env_vars();

        let tmp = tempfile::tempdir().unwrap();
        let cred_path = tmp.path().join("does-not-exist.env");
        let config =
            Config { jira_credentials_path: Some(cred_path.clone()), ..Config::default() };

        assert!(resolve_credentials(&config).is_none());

        let provider = JiraProvider::new(&config);
        assert!(!provider.is_configured());
        let msg = provider.unconfigured_message();
        assert!(
            msg.contains(&cred_path.display().to_string()),
            "the unconfigured message must name the credentials path, got: {msg}"
        );
        assert!(msg.contains(ENV_SITE), "must name {ENV_SITE}, got: {msg}");
        assert!(msg.contains(ENV_EMAIL), "must name {ENV_EMAIL}, got: {msg}");
        assert!(msg.contains(ENV_TOKEN), "must name {ENV_TOKEN}, got: {msg}");
    }

    // 5. JiraCredentials's Debug output never contains the token.
    #[test]
    fn jira_credentials_debug_output_never_contains_the_token() {
        let creds = JiraCredentials::for_test(
            "acme.atlassian.net",
            "hammer@acme.com",
            "super-secret-token-xyz",
        );
        let debug = format!("{creds:?}");
        assert!(
            !debug.contains("super-secret-token-xyz"),
            "Debug output must never leak the token, got: {debug}"
        );
        assert!(debug.contains("acme.atlassian.net"));
        assert!(debug.contains("hammer@acme.com"));
    }

    // ── ADF → MdBlock mapping (pure, no network) ─────────────────────────────

    // 6. One of each mapped node type round-trips to the expected MdBlock.
    #[test]
    fn adf_document_with_one_of_each_mapped_node_type_produces_the_expected_blocks() {
        let doc = serde_json::json!({
            "type": "doc",
            "content": [
                { "type": "paragraph", "content": [{ "type": "text", "text": "hello" }] },
                {
                    "type": "heading", "attrs": { "level": 2 },
                    "content": [{ "type": "text", "text": "AC" }]
                },
                {
                    "type": "codeBlock", "attrs": { "language": "rust" },
                    "content": [{ "type": "text", "text": "fn f() {}" }]
                },
                {
                    "type": "bulletList",
                    "content": [{
                        "type": "listItem",
                        "content": [{ "type": "paragraph", "content": [{ "type": "text", "text": "item1" }] }]
                    }]
                },
                {
                    "type": "orderedList", "attrs": { "order": 3 },
                    "content": [{
                        "type": "listItem",
                        "content": [{ "type": "paragraph", "content": [{ "type": "text", "text": "item" }] }]
                    }]
                },
                {
                    "type": "blockquote",
                    "content": [{ "type": "paragraph", "content": [{ "type": "text", "text": "quoted" }] }]
                },
                { "type": "rule" },
                {
                    "type": "table",
                    "content": [
                        {
                            "type": "tableRow",
                            "content": [{
                                "type": "tableHeader",
                                "content": [{ "type": "paragraph", "content": [{ "type": "text", "text": "Col1" }] }]
                            }]
                        },
                        {
                            "type": "tableRow",
                            "content": [{
                                "type": "tableCell",
                                "content": [{ "type": "paragraph", "content": [{ "type": "text", "text": "Val1" }] }]
                            }]
                        }
                    ]
                }
            ]
        });

        let blocks = adf_to_blocks(&doc);
        assert_eq!(
            blocks,
            vec![
                MdBlock::Paragraph { spans: vec![MdSpan::Text { text: "hello".into() }] },
                MdBlock::Heading { level: 2, spans: vec![MdSpan::Text { text: "AC".into() }] },
                MdBlock::CodeBlock { lang: Some("rust".into()), text: "fn f() {}".into() },
                MdBlock::List {
                    ordered: false,
                    start: None,
                    items: vec![vec![MdBlock::Paragraph {
                        spans: vec![MdSpan::Text { text: "item1".into() }]
                    }]],
                },
                MdBlock::List {
                    ordered: true,
                    start: Some(3),
                    items: vec![vec![MdBlock::Paragraph {
                        spans: vec![MdSpan::Text { text: "item".into() }]
                    }]],
                },
                MdBlock::Quote {
                    blocks: vec![MdBlock::Paragraph {
                        spans: vec![MdSpan::Text { text: "quoted".into() }]
                    }],
                },
                MdBlock::Rule,
                MdBlock::Table {
                    header: vec![vec![MdSpan::Text { text: "Col1".into() }]],
                    rows: vec![vec![vec![MdSpan::Text { text: "Val1".into() }]]],
                },
            ]
        );
    }

    // 7. Each mark maps to the corresponding MdSpan, including documented
    //    nesting order for a run with multiple marks.
    #[test]
    fn text_node_marks_map_to_the_corresponding_mdspan_variant() {
        let strong = serde_json::json!({ "type": "text", "text": "b", "marks": [{ "type": "strong" }] });
        assert_eq!(
            text_node_to_span(&strong),
            MdSpan::Strong { spans: vec![MdSpan::Text { text: "b".into() }] }
        );

        let em = serde_json::json!({ "type": "text", "text": "i", "marks": [{ "type": "em" }] });
        assert_eq!(
            text_node_to_span(&em),
            MdSpan::Emph { spans: vec![MdSpan::Text { text: "i".into() }] }
        );

        let code = serde_json::json!({ "type": "text", "text": "c", "marks": [{ "type": "code" }] });
        assert_eq!(text_node_to_span(&code), MdSpan::Code { text: "c".into() });

        let strike = serde_json::json!({ "type": "text", "text": "s", "marks": [{ "type": "strike" }] });
        assert_eq!(
            text_node_to_span(&strike),
            MdSpan::Strike { spans: vec![MdSpan::Text { text: "s".into() }] }
        );

        let link = serde_json::json!({
            "type": "text", "text": "l",
            "marks": [{ "type": "link", "attrs": { "href": "https://example.com" } }]
        });
        assert_eq!(
            text_node_to_span(&link),
            MdSpan::Link {
                spans: vec![MdSpan::Text { text: "l".into() }],
                url: "https://example.com".into()
            }
        );
    }

    #[test]
    fn text_node_with_multiple_marks_nests_strong_outermost_then_emph_then_strike() {
        // Marks listed out of nesting order in the input — the mapper's
        // output order must not depend on the marks array's own order.
        let node = serde_json::json!({
            "type": "text", "text": "x",
            "marks": [{ "type": "strike" }, { "type": "em" }, { "type": "strong" }]
        });
        let span = text_node_to_span(&node);
        assert_eq!(
            span,
            MdSpan::Strong {
                spans: vec![MdSpan::Emph {
                    spans: vec![MdSpan::Strike { spans: vec![MdSpan::Text { text: "x".into() }] }]
                }]
            }
        );
    }

    // 8. An unrecognised node type (block-level and inline) folds in its
    //    recursively-extracted text rather than being dropped.
    #[test]
    fn an_unrecognised_block_level_node_type_becomes_a_paragraph_carrying_its_extracted_text() {
        let node = serde_json::json!({
            "type": "mediaSingle",
            "content": [{ "type": "text", "text": "caption" }]
        });
        assert_eq!(
            node_to_block(&node),
            MdBlock::Paragraph { spans: vec![MdSpan::Text { text: "caption".into() }] }
        );
    }

    #[test]
    fn an_unrecognised_inline_node_type_becomes_a_text_span_carrying_its_extracted_text() {
        let emoji = serde_json::json!({
            "type": "emoji",
            "content": [{ "type": "text", "text": "smile" }]
        });
        let para = serde_json::json!({ "type": "paragraph", "content": [emoji] });
        assert_eq!(
            node_to_block(&para),
            MdBlock::Paragraph { spans: vec![MdSpan::Text { text: "smile".into() }] }
        );
    }

    // ── provider behavior (wiremock — no real Atlassian access) ──────────────

    fn jira_creds() -> JiraCredentials {
        JiraCredentials::for_test("acme.atlassian.net", "hammer@acme.com", "tok")
    }

    // 9. Happy path.
    #[tokio::test]
    async fn happy_path_fetch_produces_the_expected_summary_status_assignee_sections_and_comments()
    {
        let server = MockServer::start().await;
        let body = serde_json::json!({
            "fields": {
                "summary": "Fix the thing",
                "status": { "name": "In Progress" },
                "assignee": { "displayName": "Alice" },
                "description": {
                    "type": "doc",
                    "content": [
                        { "type": "paragraph", "content": [{ "type": "text", "text": "Body text." }] },
                        { "type": "heading", "attrs": { "level": 2 }, "content": [{ "type": "text", "text": "AC" }] },
                        { "type": "paragraph", "content": [{ "type": "text", "text": "Must work." }] }
                    ]
                },
                "comment": {
                    "comments": [{
                        "author": { "displayName": "Bob" },
                        "created": "2024-01-01T00:00:00.000+0000",
                        "body": {
                            "type": "doc",
                            "content": [{ "type": "paragraph", "content": [{ "type": "text", "text": "a comment" }] }]
                        }
                    }]
                }
            }
        });

        Mock::given(method("GET"))
            .and(path("/rest/api/3/issue/TEST-1"))
            .respond_with(ResponseTemplate::new(200).set_body_json(body))
            .mount(&server)
            .await;

        let provider = JiraProvider::for_test(Some(jira_creds()), server.uri());
        let ticket = provider.fetch("TEST-1").await.expect("happy path fetch must succeed");

        assert_eq!(ticket.provider, "jira");
        assert_eq!(ticket.key, "TEST-1");
        assert_eq!(ticket.summary, "Fix the thing");
        assert_eq!(ticket.status, "In Progress");
        assert_eq!(ticket.assignee, Some("Alice".to_string()));
        assert_eq!(ticket.sections.len(), 2, "one description section plus one AC section");
        assert_eq!(ticket.sections[0].name, "description");
        assert_eq!(ticket.sections[1].name, "acceptance_criteria");
        assert_eq!(ticket.comments.len(), 1);
        assert_eq!(ticket.comments[0].author, "Bob");
        assert_eq!(ticket.comments[0].index, 1);
        // Jira's actual wire format for `created` — a numeric offset with no
        // colon ("+0000", not "+00:00") — is not valid RFC 3339 and must not
        // silently fall through to "now": that would show every comment as
        // freshly written regardless of its real age. Assert the exact
        // parsed instant, not just "some non-default value".
        assert_eq!(
            ticket.comments[0].created_at,
            chrono::DateTime::parse_from_rfc3339("2024-01-01T00:00:00Z")
                .unwrap()
                .with_timezone(&chrono::Utc)
        );
    }

    /// A `created` timestamp in neither Jira's real shape nor RFC 3339 (e.g.
    /// a future API version, or a malformed response) must not be presented
    /// as if the comment were written "now" — that reads as a genuine
    /// timestamp when it is actually unknown. Falls back to the epoch, the
    /// same "honest unknown" convention the Swift-side decoder already uses
    /// for this exact field.
    #[tokio::test]
    async fn an_unparseable_comment_created_timestamp_falls_back_to_the_epoch_not_now() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/rest/api/3/issue/PROJ-1"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "fields": {
                    "summary": "S", "status": {"name": "Open"}, "assignee": null,
                    "description": null,
                    "comment": {"comments": [{
                        "author": {"displayName": "Bob"},
                        "created": "not-a-timestamp",
                        "body": {"type": "doc", "content": []},
                    }]},
                }
            })))
            .mount(&server)
            .await;
        let provider = JiraProvider::for_test(Some(jira_creds()), server.uri());
        let ticket = provider.fetch("PROJ-1").await.expect("fetch must succeed despite the bad timestamp");
        assert_eq!(
            ticket.comments[0].created_at,
            chrono::DateTime::from_timestamp(0, 0).unwrap()
        );
    }

    // 10. 404 -> UnknownTicket.
    #[tokio::test]
    async fn a_404_response_maps_to_unknown_ticket() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/rest/api/3/issue/MISSING-1"))
            .respond_with(ResponseTemplate::new(404))
            .mount(&server)
            .await;

        let provider = JiraProvider::for_test(Some(jira_creds()), server.uri());
        let err = provider.fetch("MISSING-1").await.unwrap_err();
        assert_eq!(err, TicketError::UnknownTicket);
    }

    /// `key` is spliced unescaped into the request path — a key shaped like
    /// `../other-endpoint` or containing `?`/`#` must never reach the
    /// request at all (it would redirect this authenticated call to a
    /// different path/query on the same Jira tenant), and must not be
    /// treated as "maybe a real ticket, let's ask Jira": rejected as
    /// `UnknownTicket` before any HTTP call, same as a key Jira itself would
    /// 404 on. No mock is registered for any path, so if the invalid key
    /// *did* reach the network, `received_requests()` would show it.
    #[tokio::test]
    async fn a_key_with_a_path_separator_is_rejected_before_any_request_is_made() {
        let server = MockServer::start().await;
        let provider = JiraProvider::for_test(Some(jira_creds()), server.uri());

        for bad_key in ["../secrets", "TEST-1/../other", "TEST-1?x=1", "TEST-1#frag", "not-a-key", ""]
        {
            let err = provider.fetch(bad_key).await.unwrap_err();
            assert_eq!(err, TicketError::UnknownTicket, "key {bad_key:?} must be rejected");
        }

        let requests = server.received_requests().await.unwrap_or_default();
        assert!(
            requests.is_empty(),
            "an invalid key must never reach the network, but got: {requests:?}"
        );
    }

    // 11. 401 -> FetchFailed, not treated as unconfigured.
    #[tokio::test]
    async fn a_401_response_maps_to_fetch_failed_not_provider_unconfigured() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/rest/api/3/issue/TEST-1"))
            .respond_with(ResponseTemplate::new(401).set_body_string("unauthorized"))
            .mount(&server)
            .await;

        let provider = JiraProvider::for_test(Some(jira_creds()), server.uri());
        let err = provider.fetch("TEST-1").await.unwrap_err();
        assert!(
            matches!(err, TicketError::FetchFailed(_)),
            "a 401 must be a distinct fetch_failed, not the credential-absent unconfigured case, \
             got: {err:?}"
        );
    }

    // 12. An unconfigured provider refuses without making any HTTP call.
    #[tokio::test]
    async fn an_unconfigured_provider_refuses_without_making_any_http_call() {
        let server = MockServer::start().await;
        // Deliberately no Mock registered — proves the assertion below, not
        // just that no matching mock existed.
        let provider = JiraProvider::for_test(None, server.uri());
        assert!(!provider.is_configured());

        let err = provider.fetch("TEST-1").await.unwrap_err();
        assert!(matches!(err, TicketError::ProviderUnconfigured { .. }));
        assert_eq!(
            server.received_requests().await.unwrap().len(),
            0,
            "an unconfigured provider must never make an HTTP call"
        );
    }
}
