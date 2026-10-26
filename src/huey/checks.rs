//! Read-only probes behind `huey.check_project` (A5).
//!
//! A closed set of questions about one project's main worktree. Answers carry
//! found / not found, counts, manifest names and at most 5 repo-relative
//! paths: never line contents, matching text, diffs or file bodies. Git runs
//! with a fixed argv (no shell) and a 5 s timeout.

use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::data::work::untrusted::one_line;
use crate::huey::context::profile::{self, FEATURES};

/// Most paths a `text` probe returns.
pub const MAX_PATHS: usize = 5;
pub const MIN_TERM_CHARS: usize = 3;
pub const MAX_TERM_CHARS: usize = 80;

/// One probe.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Probe {
    /// Is `name` a declared dependency in any manifest?
    Dependency { name: String },
    /// Do any tracked files contain `term` (fixed string)?
    Text { term: String },
    /// Does the project use this Claude Code feature (`hooks`, `mcp`,
    /// `skills`, `plugins`, `agents`, `settings`)?
    ClaudeFeature { feature: String },
    /// How does the project start Claude?
    Invocation,
}

impl Probe {
    pub fn kind(&self) -> &'static str {
        match self {
            Probe::Dependency { .. } => "dependency",
            Probe::Text { .. } => "text",
            Probe::ClaudeFeature { .. } => "claude_feature",
            Probe::Invocation => "invocation",
        }
    }
}

/// A probe's answer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CheckResult {
    /// `c1`, `c2`, … issued by the caller.
    pub id: String,
    pub project: String,
    pub probe: Probe,
    pub found: bool,
    /// One line: what was found, with counts and names, never contents.
    pub detail: String,
    /// Repo-relative paths (manifests for `dependency`, matches for `text`),
    /// at most [`MAX_PATHS`].
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub paths: Vec<String>,
}

impl CheckResult {
    /// The digest line (`[c1] mother: text `X`: not found (…)`), without the
    /// list marker.
    pub fn line(&self) -> String {
        let what = match &self.probe {
            Probe::Dependency { name } => format!("dependency `{}`", one_line(name, 80)),
            Probe::Text { term } => format!("text `{}`", one_line(term, MAX_TERM_CHARS)),
            Probe::ClaudeFeature { feature } => {
                format!("claude feature `{}`", one_line(feature, 40))
            }
            Probe::Invocation => "invocation".to_string(),
        };
        one_line(
            &format!("[{}] {}: {what}: {}", self.id, self.project, self.detail),
            400,
        )
    }
}

/// Why a probe was refused (nothing was run).
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum CheckRefused {
    #[error("term must be {MIN_TERM_CHARS} to {MAX_TERM_CHARS} printable characters on one line")]
    BadTerm,
    #[error("dependency name must be 1 to 214 printable characters on one line")]
    BadName,
    #[error("unknown feature; use one of hooks, mcp, skills, plugins, agents, settings")]
    UnknownFeature,
    #[error("the project's repository could not be read")]
    Unreadable,
}

fn printable_one_line(s: &str) -> bool {
    !s.chars().any(|c| c.is_control() || is_bidi(c))
}

fn is_bidi(c: char) -> bool {
    matches!(c, '\u{200E}' | '\u{200F}' | '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}')
}

/// Validate a `text` probe's term: 3–80 printable characters, no newline.
pub fn validate_term(term: &str) -> Result<(), CheckRefused> {
    let n = term.chars().count();
    if !(MIN_TERM_CHARS..=MAX_TERM_CHARS).contains(&n)
        || !printable_one_line(term)
        || term.trim().is_empty()
    {
        return Err(CheckRefused::BadTerm);
    }
    Ok(())
}

/// Answer `probe` for `project`, whose main worktree is `root`. `id` is the
/// check id the caller issued.
pub fn check(
    id: &str,
    project: &str,
    root: &Path,
    probe: &Probe,
) -> Result<CheckResult, CheckRefused> {
    let result = |found: bool, detail: String, paths: Vec<String>| CheckResult {
        id: id.to_string(),
        project: project.to_string(),
        probe: probe.clone(),
        found,
        detail,
        paths,
    };
    match probe {
        Probe::Dependency { name } => {
            if name.trim().is_empty() || name.chars().count() > 214 || !printable_one_line(name) {
                return Err(CheckRefused::BadName);
            }
            let manifests: Vec<String> = profile::dependencies(root)
                .into_iter()
                .filter(|d| profile::dependency_matches(&d.name, name))
                .map(|d| d.manifest)
                .collect::<std::collections::BTreeSet<_>>()
                .into_iter()
                .collect();
            if manifests.is_empty() {
                let searched = profile::manifest_files(root)
                    .into_iter()
                    .filter(|m| !m.ends_with(".xcodeproj"))
                    .count();
                Ok(result(
                    false,
                    format!("not found ({searched} manifest files searched)"),
                    Vec::new(),
                ))
            } else {
                let shown: Vec<String> = manifests.iter().take(MAX_PATHS).cloned().collect();
                Ok(result(
                    true,
                    format!("found in {}", shown.join(", ")),
                    shown,
                ))
            }
        }
        Probe::Text { term } => {
            validate_term(term)?;
            let files = profile::grep_files(root, term).ok_or(CheckRefused::Unreadable)?;
            if files.is_empty() {
                Ok(result(
                    false,
                    "not found in tracked files".to_string(),
                    Vec::new(),
                ))
            } else {
                let shown: Vec<String> = files
                    .iter()
                    .take(MAX_PATHS)
                    .map(|p| one_line(p, 200))
                    .collect();
                Ok(result(
                    true,
                    format!(
                        "found in {} tracked file{}: {}",
                        files.len(),
                        if files.len() == 1 { "" } else { "s" },
                        shown.join(", ")
                    ),
                    shown,
                ))
            }
        }
        Probe::ClaudeFeature { feature } => {
            let keys: &[&str] = match feature.trim().to_lowercase().as_str() {
                "hooks" => &["hooks"],
                "mcp" => &["mcp_config", "mcp_server"],
                "skills" => &["skills"],
                "plugins" | "plugin" => &["plugin"],
                "agents" => &["agents"],
                "settings" => &["settings"],
                _ => return Err(CheckRefused::UnknownFeature),
            };
            let prof = profile::profile(root);
            let present: Vec<&str> = FEATURES
                .iter()
                .filter(|(k, _)| keys.contains(k) && prof.features.iter().any(|f| f == k))
                .map(|(_, phrase)| *phrase)
                .collect();
            Ok(if present.is_empty() {
                result(false, "not used".to_string(), Vec::new())
            } else {
                result(true, format!("uses {}", present.join(", ")), Vec::new())
            })
        }
        Probe::Invocation => {
            let prof = profile::profile(root);
            Ok(if prof.invocation.is_empty() {
                result(false, "no claude invocation found".to_string(), Vec::new())
            } else {
                result(
                    true,
                    format!("starts claude with {}", prof.invocation.join(", ")),
                    Vec::new(),
                )
            })
        }
    }
}
