//! A `CHANGELOG.md` whose `## <version>` headings carry no dates, dated
//! through the npm registry's `time` map (`kind = "npm_changelog"`).
//!
//! One version is one item with its whole entry as text: the best news is a
//! single "Added" line deep inside one. A version npm does not know yet (or
//! an npm outage) leaves the item undated, so it falls back to first-seen.

use std::collections::HashMap;
use std::sync::LazyLock;

use chrono::{DateTime, Utc};
use regex::Regex;
use serde::Deserialize;
use tracing::debug;

use super::config::SourceConfig;
use super::http::FetchError;
use super::{AdapterCtx, Draft, Fetch};
use crate::huey::items::NewsItem;

static VERSION: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\d+\.\d+(\.\d+)?([-+][0-9A-Za-z.\-]+)?$").unwrap());

#[derive(Deserialize)]
struct Registry {
    #[serde(default)]
    time: HashMap<String, String>,
}

/// One `## <version>` section of the changelog.
#[derive(Debug, PartialEq)]
pub struct Entry {
    pub version: String,
    /// The heading text, from which GitHub builds the anchor.
    pub heading: String,
    pub body: String,
}

pub(crate) async fn fetch(
    src: &SourceConfig,
    ctx: &AdapterCtx<'_>,
) -> Result<Option<Fetch>, FetchError> {
    // Both documents are small enough to read in full every time; the
    // validators of one would say nothing about the other.
    let registry_url = src.registry_url.as_deref().unwrap_or_default();
    let (changelog, registry) = tokio::join!(
        ctx.http
            .get_body(&src.url, Some("text/plain, text/markdown, */*;q=0.5")),
        ctx.http
            .get_json::<Registry>(registry_url, Some("application/json"), "registry"),
    );
    let changelog = changelog?;
    let times = match registry {
        Ok(r) => r.time,
        Err(_) => {
            debug!(source = %src.id, "huey: npm registry unavailable; versions undated");
            HashMap::new()
        }
    };
    let items = parse(src, &String::from_utf8_lossy(&changelog), &times, ctx.now)?;
    Ok(Some(Fetch {
        items,
        etag: None,
        last_modified: None,
    }))
}

pub fn parse(
    src: &SourceConfig,
    changelog: &str,
    times: &HashMap<String, String>,
    now: DateTime<Utc>,
) -> Result<Vec<NewsItem>, FetchError> {
    let entries = parse_entries(changelog);
    if entries.is_empty() {
        return Err(FetchError::parse("changelog"));
    }
    let link_base = src.link_url.as_deref().unwrap_or(&src.url);
    Ok(entries
        .into_iter()
        .filter_map(|e| {
            let published_at = times
                .get(&e.version)
                .and_then(|t| DateTime::parse_from_rfc3339(t).ok())
                .map(|t| t.with_timezone(&Utc));
            Draft {
                title: format!("{} {}", src.name, e.version),
                url: format!("{link_base}#{}", github_anchor(&e.heading)),
                key: e.version,
                published_at,
                outbound_links: crate::huey::items::extract_urls(&e.body, 20),
                text: e.body,
            }
            .into_item(src, now)
        })
        .collect())
}

/// The version sections, in file order. Headings inside code fences are not
/// headings; a `##` that is not a version ends the previous section and its
/// own text is skipped; a repeated version keeps its first section.
pub fn parse_entries(changelog: &str) -> Vec<Entry> {
    let mut entries: Vec<Entry> = Vec::new();
    let mut current: Option<(String, String, Vec<&str>)> = None;
    let mut in_fence = false;
    let mut flush = |current: &mut Option<(String, String, Vec<&str>)>| {
        if let Some((version, heading, lines)) = current.take() {
            if !entries.iter().any(|e| e.version == version) {
                entries.push(Entry {
                    version,
                    heading,
                    body: lines.join("\n").trim().to_string(),
                });
            }
        }
    };
    for line in changelog.lines() {
        let trimmed = line.trim_start();
        if trimmed.starts_with("```") || trimmed.starts_with("~~~") {
            in_fence = !in_fence;
        } else if !in_fence {
            if let Some(heading) = line.strip_prefix("## ") {
                flush(&mut current);
                let heading = heading.trim();
                current = heading
                    .split_whitespace()
                    .next()
                    .map(|t| t.trim_matches(|c: char| c == '[' || c == ']'))
                    .map(|t| t.strip_prefix('v').unwrap_or(t))
                    .filter(|t| VERSION.is_match(t))
                    .map(|t| (t.to_string(), heading.to_string(), Vec::new()));
                continue;
            }
        }
        if let Some((_, _, lines)) = current.as_mut() {
            lines.push(line);
        }
    }
    flush(&mut current);
    entries
}

/// GitHub's heading anchor: lower-case, punctuation dropped (hyphens and
/// underscores kept), spaces to hyphens. `2.1.310` becomes `21310`.
pub fn github_anchor(heading: &str) -> String {
    heading
        .to_lowercase()
        .chars()
        .filter(|c| c.is_alphanumeric() || matches!(c, '-' | '_' | ' '))
        .map(|c| if c == ' ' { '-' } else { c })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn anchors_follow_githubs_form() {
        assert_eq!(github_anchor("2.1.310"), "21310");
        assert_eq!(github_anchor("[2.1.310]"), "21310");
        assert_eq!(github_anchor("2.1.310 (Oct 23)"), "21310-oct-23");
    }

    #[test]
    fn sections_split_on_version_headings_outside_code_fences() {
        let md = "# Changelog\n\n## 2.0.1\n\n- Added x\n```\n## 9.9.9\n```\n\n## Unreleased\n\n- nope\n\n## v2.0.0\n- Fixed y\n\n## 2.0.1\n- dup\n";
        let entries = parse_entries(md);
        let versions: Vec<_> = entries.iter().map(|e| e.version.as_str()).collect();
        assert_eq!(versions, ["2.0.1", "2.0.0"]);
        assert!(entries[0].body.contains("## 9.9.9"));
        assert!(entries[0].body.contains("Added x"));
        assert!(!entries[0].body.contains("nope"));
        assert_eq!(entries[1].body, "- Fixed y");
    }

    #[test]
    fn a_file_with_no_version_headings_does_not_parse() {
        assert!(parse_entries("<html>not a changelog</html>").is_empty());
    }
}
