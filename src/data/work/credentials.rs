//! Credential lookup shared by the work sources (Jira, Sentry).
//!
//! Resolution order for a variable: the process environment first, then the
//! shell-style `.env` file at `~/.claude/credentials/.env`. The file is
//! re-read when its mtime changes, so fixing a rejected token recovers without
//! a daemon restart. Values are never logged or returned in errors: callers
//! report problems by variable *name*.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::SystemTime;

/// Default credentials file (`~/.claude/credentials/.env`).
pub fn default_env_path() -> PathBuf {
    dirs_next::home_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join(".claude")
        .join("credentials")
        .join(".env")
}

/// A `.env` file that reloads itself when its mtime changes.
pub struct EnvFile {
    path: PathBuf,
    cached: Mutex<Cached>,
}

#[derive(Default)]
struct Cached {
    loaded: bool,
    mtime: Option<SystemTime>,
    vars: HashMap<String, String>,
}

impl EnvFile {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into(), cached: Mutex::new(Cached::default()) }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// The file's current mtime (`None` when it does not exist).
    pub fn mtime(&self) -> Option<SystemTime> {
        std::fs::metadata(&self.path).and_then(|m| m.modified()).ok()
    }

    /// Value of `name`: a non-empty process environment variable wins, then a
    /// non-empty value from the file. A blank value counts as absent.
    pub fn lookup(&self, name: &str) -> Option<String> {
        if let Some(v) = std::env::var(name).ok().filter(|s| !s.is_empty()) {
            return Some(v);
        }
        self.file_value(name)
    }

    /// Like [`lookup`](Self::lookup) but only consults the file.
    pub fn file_value(&self, name: &str) -> Option<String> {
        let mtime = self.mtime();
        let mut cached = self.cached.lock().unwrap();
        if !cached.loaded || cached.mtime != mtime {
            cached.vars = read_env_file(&self.path);
            cached.mtime = mtime;
            cached.loaded = true;
        }
        cached.vars.get(name).cloned().filter(|s| !s.is_empty())
    }
}

const JIRA_SITE_VAR: &str = "ATLASSIAN_SITE_NAME";

/// Where the Jira site (host name such as `example.atlassian.net`) for links
/// comes from: the configured override, then the environment, then the
/// credentials file at the configured path.
pub struct JiraSite {
    configured: Option<String>,
    file: EnvFile,
}

impl JiraSite {
    /// `configured` is `Config::jira_site`; `env_path` the credentials file.
    pub fn new(configured: Option<String>, env_path: impl Into<PathBuf>) -> Self {
        Self { configured, file: EnvFile::new(env_path) }
    }

    /// From the daemon config (`jira_site`, `jira_credentials_path`).
    pub fn from_config(config: &crate::config::Config) -> Self {
        Self::new(
            config.jira_site.clone(),
            config.jira_credentials_path.clone().unwrap_or_else(default_env_path),
        )
    }

    /// The site, if any. Reads a file: call from a blocking context.
    pub fn lookup(&self) -> Option<String> {
        let usable = |v: Option<String>| v.map(|s| s.trim().to_string()).filter(|s| !s.is_empty());
        usable(self.configured.clone())
            .or_else(|| usable(std::env::var(JIRA_SITE_VAR).ok()))
            .or_else(|| usable(self.file.file_value(JIRA_SITE_VAR)))
    }
}

impl Default for JiraSite {
    fn default() -> Self {
        Self::new(None, default_env_path())
    }
}

/// Expand `${NAME}` references in `value`, the way the shell that normally
/// sources this file would: from variables defined earlier in the same file
/// (`seen`), then from the process environment, else empty.
///
/// Only the braced form is expanded — a bare `$` (an API token may legitimately
/// contain one) is left alone. The shared `~/.claude/credentials/.env` writes
/// `ATLASSIAN_USER_EMAIL=${ATLASSIAN_EMAIL}`; taking that literally made the
/// daemon log in to Jira as the string `${ATLASSIAN_EMAIL}`, which Jira answers
/// as an anonymous request (404), surfaced as `unknown_ticket` for every real
/// key. An unresolvable reference expands to empty, so `resolve_credentials`
/// reports the provider as unconfigured instead of sending a bogus login.
pub fn expand_braced_refs(value: &str, seen: &HashMap<String, String>) -> String {
    let mut out = String::with_capacity(value.len());
    let mut rest = value;
    while let Some(start) = rest.find("${") {
        out.push_str(&rest[..start]);
        let after = &rest[start + 2..];
        match after.find('}') {
            Some(end) => {
                let name = &after[..end];
                let resolved = seen
                    .get(name)
                    .cloned()
                    .or_else(|| std::env::var(name).ok())
                    .unwrap_or_default();
                out.push_str(&resolved);
                rest = &after[end + 1..];
            }
            None => {
                // Unterminated `${` — not a reference; keep it verbatim.
                out.push_str(&rest[start..]);
                rest = "";
            }
        }
    }
    out.push_str(rest);
    out
}

/// Parse `KEY=VALUE` lines from a `.env`-style file. Missing/unreadable file
/// returns an empty map rather than an error — the caller (`resolve_credentials`)
/// treats "no file" and "file present but incomplete" identically.
pub fn read_env_file(path: &Path) -> HashMap<String, String> {
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
        // Shell semantics: single quotes are literal; double quotes and bare
        // values expand `${NAME}` references.
        let mut expand = true;
        if v.len() >= 2 {
            if v.starts_with('\'') && v.ends_with('\'') {
                v = v[1..v.len() - 1].to_string();
                expand = false;
            } else if v.starts_with('"') && v.ends_with('"') {
                v = v[1..v.len() - 1].to_string();
            }
        }
        if expand {
            v = expand_braced_refs(&v, &map);
        }
        map.insert(k, v);
    }
    map
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn braced_refs_expand_from_earlier_lines_and_bare_dollars_stay() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(".env");
        std::fs::write(
            &path,
            "A=alpha\nB=${A}-x\nC='${A}'\nD=pa$$word\n# comment\nE=\"q ${A}\"\n",
        )
        .unwrap();
        let vars = read_env_file(&path);
        assert_eq!(vars["B"], "alpha-x");
        assert_eq!(vars["C"], "${A}", "single quotes are literal");
        assert_eq!(vars["D"], "pa$$word");
        assert_eq!(vars["E"], "q alpha");
    }

    #[test]
    fn lookup_reads_the_file_and_reloads_when_the_mtime_changes() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(".env");
        std::fs::write(&path, "NOSTROMO_TEST_CRED_A=from-file\nNOSTROMO_TEST_CRED_B=\n").unwrap();
        let env = EnvFile::new(&path);
        assert_eq!(env.lookup("NOSTROMO_TEST_CRED_A").as_deref(), Some("from-file"));
        assert_eq!(env.lookup("NOSTROMO_TEST_CRED_B"), None, "blank is absent");
        assert_eq!(env.lookup("NOSTROMO_TEST_CRED_MISSING"), None);

        std::fs::write(&path, "NOSTROMO_TEST_CRED_A=updated\n").unwrap();
        let later = SystemTime::now() + std::time::Duration::from_secs(5);
        std::fs::File::options().write(true).open(&path).unwrap().set_modified(later).unwrap();
        assert_eq!(env.lookup("NOSTROMO_TEST_CRED_A").as_deref(), Some("updated"));
    }

    #[test]
    fn a_missing_file_resolves_nothing() {
        let env = EnvFile::new("/nonexistent/nostromo/.env");
        assert_eq!(env.lookup("NOSTROMO_TEST_CRED_NOPE"), None);
    }

    // ── JiraSite ──────────────────────────────────────────────────────────────
    // Only the case that does not depend on the process environment lives
    // here: the jira tests in `data::tickets::jira` set ATLASSIAN_SITE_NAME
    // under a lock of their own, so anything that reads or clears it would
    // race them. The env/file/blank/missing cases are in
    // `tests/jira_site_lookup.rs` (a process of its own).

    #[test]
    fn a_configured_jira_site_wins_over_the_credentials_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(".env");
        std::fs::write(&path, "ATLASSIAN_SITE_NAME=file.atlassian.net\n").unwrap();
        let site = JiraSite::new(Some("override.atlassian.net".into()), path);
        assert_eq!(site.lookup().as_deref(), Some("override.atlassian.net"));
    }
}
