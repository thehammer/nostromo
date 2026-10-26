//! `sources.toml`: which news sources Huey reads and which context sources
//! the setup step lists. Re-read on every run, so adding a source needs no
//! code change and no restart.
//!
//! Loading never fails. A bad entry is skipped with a warning that names the
//! source (or its position), never the offending value, and the rest load.

use std::path::Path;

use serde::Deserialize;

use crate::huey::items::SourceClass;

/// How a source is fetched and parsed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SourceKind {
    /// A `CHANGELOG.md` with undated `## <version>` headings, dated through
    /// the npm registry's `time` map.
    NpmChangelog,
    /// A markdown page with dated section headings and bullets.
    MdDatedSections,
    /// An HTML index of links to articles, with no dates.
    HtmlLinkIndex,
    /// GitHub releases of one repository.
    GithubReleases,
    /// An Atom or RSS feed.
    Feed,
    /// The Hacker News front page.
    HnFrontPage,
}

impl SourceKind {
    fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "npm_changelog" => Self::NpmChangelog,
            "md_dated_sections" => Self::MdDatedSections,
            "html_link_index" => Self::HtmlLinkIndex,
            "github_releases" => Self::GithubReleases,
            "feed" => Self::Feed,
            "hn_front_page" => Self::HnFrontPage,
            _ => return None,
        })
    }
}

pub const DEFAULT_GITHUB_API: &str = "https://api.github.com";
pub const DEFAULT_LINK_PREFIX: &str = "/news/";
pub const DEFAULT_HN_TOP: usize = 30;

#[derive(Debug, Clone, PartialEq)]
pub struct SourceConfig {
    /// Lower-case letters, digits, `-` and `_`; it names the state file.
    pub id: String,
    pub name: String,
    pub kind: SourceKind,
    pub class: SourceClass,
    pub enabled: bool,
    /// The page, feed or list this source reads. Empty for `github_releases`.
    pub url: String,
    /// `npm_changelog`: the registry document with the `time` map.
    pub registry_url: Option<String>,
    /// `npm_changelog`: the page a version's anchor is appended to.
    pub link_url: Option<String>,
    /// `github_releases`: `owner/name`.
    pub repo: Option<String>,
    /// `github_releases`: API root, for tests and GitHub Enterprise.
    pub api_base: String,
    /// `html_link_index`: path prefix of an article link.
    pub link_prefix: String,
    /// `hn_front_page`: one story's URL with `{id}` in it.
    pub item_url: Option<String>,
    /// `hn_front_page`: how many top stories to read.
    pub top: usize,
}

/// Which local context sources the setup step lists and Huey may read.
/// Every one defaults to on; turning one off is an edit here.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ContextSwitches {
    pub code_root: bool,
    pub tracker: bool,
    pub prs: bool,
    pub git: bool,
    pub mother: bool,
    pub bishop: bool,
    pub ideas: bool,
    pub todos: bool,
    pub notes: bool,
    pub interests: bool,
}

impl Default for ContextSwitches {
    fn default() -> Self {
        Self {
            code_root: true,
            tracker: true,
            prs: true,
            git: true,
            mother: true,
            bishop: true,
            ideas: true,
            todos: true,
            notes: true,
            interests: true,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct SourcesConfig {
    pub sources: Vec<SourceConfig>,
    pub context: ContextSwitches,
}

impl SourcesConfig {
    pub fn enabled(&self) -> impl Iterator<Item = &SourceConfig> {
        self.sources.iter().filter(|s| s.enabled)
    }

    /// The shipped defaults: what `default_toml()` says.
    pub fn defaults() -> Self {
        load(default_toml()).0
    }
}

#[derive(Deserialize)]
struct RawSource {
    id: Option<String>,
    name: Option<String>,
    kind: Option<String>,
    class: Option<String>,
    enabled: Option<bool>,
    url: Option<String>,
    registry_url: Option<String>,
    link_url: Option<String>,
    repo: Option<String>,
    api_base: Option<String>,
    link_prefix: Option<String>,
    item_url: Option<String>,
    top: Option<i64>,
}

/// Parse `sources.toml` text. Never fails: a file that is not TOML at all
/// gives the defaults and one warning.
pub fn load(text: &str) -> (SourcesConfig, Vec<String>) {
    let mut warnings = Vec::new();
    let doc: toml::Table = match text.parse() {
        Ok(t) => t,
        Err(_) => {
            warnings.push("sources.toml is not valid TOML; using the default sources".to_string());
            let (cfg, _) = load(default_toml());
            return (cfg, warnings);
        }
    };

    let mut sources: Vec<SourceConfig> = Vec::new();
    match doc.get("source") {
        None => {}
        Some(toml::Value::Array(entries)) => {
            for (n, entry) in entries.iter().enumerate() {
                match source_from(entry.clone(), n + 1) {
                    Ok(src) if sources.iter().any(|s| s.id == src.id) => {
                        warnings.push(format!(
                            "source `{}` is listed twice; the first is used",
                            src.id
                        ));
                    }
                    Ok(src) => sources.push(src),
                    Err(w) => warnings.push(w),
                }
            }
        }
        Some(_) => {
            warnings.push("`source` must be a list of [[source]] tables; ignored".to_string())
        }
    }

    let context = match doc.get("context") {
        None => ContextSwitches::default(),
        Some(toml::Value::Table(t)) => context_from(t, &mut warnings),
        Some(_) => {
            warnings.push("`context` must be a table; using the defaults".to_string());
            ContextSwitches::default()
        }
    };
    (SourcesConfig { sources, context }, warnings)
}

/// Read `sources.toml`. A missing file is the defaults with no warning (it
/// is written when setup is confirmed); an unreadable one warns.
pub fn load_file(path: &Path) -> (SourcesConfig, Vec<String>) {
    match std::fs::read_to_string(path) {
        Ok(text) => load(&text),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => (SourcesConfig::defaults(), vec![]),
        Err(_) => (
            SourcesConfig::defaults(),
            vec!["sources.toml could not be read; using the default sources".to_string()],
        ),
    }
}

fn source_from(value: toml::Value, position: usize) -> Result<SourceConfig, String> {
    let raw: RawSource = value
        .try_into()
        .map_err(|_| format!("source #{position} has a value of the wrong type; skipped"))?;
    let id = raw.id.clone().unwrap_or_default();
    let valid_id = !id.is_empty()
        && id.len() <= 64
        && id.starts_with(|c: char| c.is_ascii_lowercase() || c.is_ascii_digit())
        && id
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-' || c == '_');
    if !valid_id {
        return Err(format!(
            "source #{position} needs an `id` of lower-case letters, digits, - and _; skipped"
        ));
    }
    let skip = |why: &str| format!("source `{id}`: {why}; skipped");

    let Some(kind) = raw.kind.as_deref().and_then(SourceKind::parse) else {
        return Err(skip("unknown or missing `kind`"));
    };
    let class = match raw.class.as_deref() {
        None | Some("curated") => SourceClass::Curated,
        Some("first_party") => SourceClass::FirstParty,
        Some("aggregator") => SourceClass::Aggregator,
        Some(_) => return Err(skip("unknown `class`")),
    };
    let http_url = |v: &Option<String>| v.as_deref().is_some_and(is_http_url);
    let need = |ok: bool, key: &str| {
        if ok {
            Ok(())
        } else {
            Err(skip(&format!("`{key}` must be an http(s) URL")))
        }
    };
    match kind {
        SourceKind::GithubReleases => {
            let repo_ok = raw.repo.as_deref().is_some_and(|r| {
                let mut parts = r.split('/');
                let part_ok = |p: Option<&str>| {
                    p.is_some_and(|p| {
                        !p.is_empty()
                            && p.chars()
                                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
                    })
                };
                part_ok(parts.next()) && part_ok(parts.next()) && parts.next().is_none()
            });
            if !repo_ok {
                return Err(skip("`repo` must look like owner/name"));
            }
            if raw.api_base.is_some() {
                need(http_url(&raw.api_base), "api_base")?;
            }
        }
        SourceKind::NpmChangelog => {
            need(http_url(&raw.url), "url")?;
            need(http_url(&raw.registry_url), "registry_url")?;
            need(http_url(&raw.link_url), "link_url")?;
        }
        SourceKind::HnFrontPage => {
            need(http_url(&raw.url), "url")?;
            if raw.item_url.is_some() {
                need(
                    http_url(&raw.item_url)
                        && raw.item_url.as_deref().unwrap_or("").contains("{id}"),
                    "item_url",
                )?;
            }
        }
        SourceKind::MdDatedSections | SourceKind::HtmlLinkIndex | SourceKind::Feed => {
            need(http_url(&raw.url), "url")?;
        }
    }
    let top = match raw.top {
        None => DEFAULT_HN_TOP,
        Some(n) if (1..=100).contains(&n) => n as usize,
        Some(_) => return Err(skip("`top` must be between 1 and 100")),
    };
    Ok(SourceConfig {
        name: raw.name.clone().unwrap_or_else(|| id.clone()),
        id: id.clone(),
        kind,
        class,
        enabled: raw.enabled.unwrap_or(true),
        url: raw.url.unwrap_or_default(),
        registry_url: raw.registry_url,
        link_url: raw.link_url,
        repo: raw.repo,
        api_base: raw
            .api_base
            .map(|b| b.trim_end_matches('/').to_string())
            .unwrap_or_else(|| DEFAULT_GITHUB_API.to_string()),
        link_prefix: raw
            .link_prefix
            .unwrap_or_else(|| DEFAULT_LINK_PREFIX.to_string()),
        item_url: raw.item_url,
        top,
    })
}

fn context_from(table: &toml::Table, warnings: &mut Vec<String>) -> ContextSwitches {
    let mut c = ContextSwitches::default();
    for (key, value) in table {
        let slot = match key.as_str() {
            "code_root" => &mut c.code_root,
            "tracker" => &mut c.tracker,
            "prs" => &mut c.prs,
            "git" => &mut c.git,
            "mother" => &mut c.mother,
            "bishop" => &mut c.bishop,
            "ideas" => &mut c.ideas,
            "todos" => &mut c.todos,
            "notes" => &mut c.notes,
            "interests" => &mut c.interests,
            _ => {
                warnings.push("context has an unknown switch; ignored".to_string());
                continue;
            }
        };
        match value.as_bool() {
            Some(b) => *slot = b,
            None => warnings.push(format!(
                "context.{key} must be true or false; using the default"
            )),
        }
    }
    c
}

fn is_http_url(s: &str) -> bool {
    url::Url::parse(s).is_ok_and(|u| matches!(u.scheme(), "http" | "https"))
}

/// What setup confirm writes to `sources.toml`.
pub fn default_toml() -> &'static str {
    r#"# Huey's news sources. Re-read on every run: edit freely, no restart needed.
# kind: npm_changelog | md_dated_sections | html_link_index | github_releases | feed | hn_front_page
# class: first_party (read in full) | curated | aggregator

[[source]]
id = "claude-code-changelog"
name = "Claude Code changelog"
kind = "npm_changelog"
class = "first_party"
url = "https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md"
registry_url = "https://registry.npmjs.org/@anthropic-ai/claude-code"
link_url = "https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md"

[[source]]
id = "claude-docs-release-notes"
name = "Claude docs release notes"
kind = "md_dated_sections"
class = "first_party"
url = "https://docs.claude.com/en/release-notes/overview.md"

[[source]]
id = "anthropic-news"
name = "Anthropic news"
kind = "html_link_index"
class = "first_party"
url = "https://www.anthropic.com/news"
link_prefix = "/news/"

[[source]]
id = "mcp-spec-releases"
name = "MCP spec releases"
kind = "github_releases"
class = "first_party"
repo = "modelcontextprotocol/modelcontextprotocol"

[[source]]
id = "agent-sdk-python"
name = "Claude Agent SDK (Python)"
kind = "github_releases"
class = "first_party"
repo = "anthropics/claude-agent-sdk-python"

[[source]]
id = "agent-sdk-typescript"
name = "Claude Agent SDK (TypeScript)"
kind = "github_releases"
class = "first_party"
repo = "anthropics/claude-agent-sdk-typescript"

[[source]]
id = "simon-willison"
name = "Simon Willison"
kind = "feed"
class = "curated"
url = "https://simonwillison.net/atom/everything/"

[[source]]
id = "latent-space"
name = "Latent Space"
kind = "feed"
class = "curated"
url = "https://www.latent.space/feed"

[[source]]
id = "hn-front-page"
name = "Hacker News front page"
kind = "hn_front_page"
class = "aggregator"
enabled = false
url = "https://hacker-news.firebaseio.com/v0/topstories.json"

# Local context Huey may read. Set one to false to stop reading it.
[context]
code_root = true
tracker = true
prs = true
git = true
mother = true
bishop = true
ideas = true
todos = true
notes = true
interests = true
"#
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_load_without_warnings_and_hn_is_off() {
        let (cfg, warnings) = load(default_toml());
        assert!(warnings.is_empty(), "{warnings:?}");
        let ids: Vec<&str> = cfg.sources.iter().map(|s| s.id.as_str()).collect();
        assert_eq!(
            ids,
            [
                "claude-code-changelog",
                "claude-docs-release-notes",
                "anthropic-news",
                "mcp-spec-releases",
                "agent-sdk-python",
                "agent-sdk-typescript",
                "simon-willison",
                "latent-space",
                "hn-front-page",
            ]
        );
        let hn = cfg.sources.last().unwrap();
        assert!(!hn.enabled);
        assert_eq!(cfg.enabled().count(), 8);
        assert_eq!(cfg.context, ContextSwitches::default());
    }

    #[test]
    fn a_bad_entry_is_skipped_and_the_rest_load() {
        let text = r#"
[[source]]
id = "weird"
kind = "carrier-pigeon"
url = "https://example.test/x"

[[source]]
id = "../escape"
kind = "feed"
url = "https://example.test/f"

[[source]]
id = "good"
kind = "feed"
url = "https://example.test/f"

[[source]]
id = "no-url"
kind = "feed"

[[source]]
id = "good"
kind = "feed"
url = "https://example.test/other"
"#;
        let (cfg, warnings) = load(text);
        assert_eq!(cfg.sources.len(), 1);
        assert_eq!(cfg.sources[0].id, "good");
        assert_eq!(cfg.sources[0].url, "https://example.test/f");
        assert_eq!(warnings.len(), 4, "{warnings:?}");
        assert!(warnings[0].contains("weird"));
        // A warning names the entry, never a value it held.
        assert!(warnings.iter().all(|w| !w.contains("carrier-pigeon")));
    }

    #[test]
    fn invalid_toml_falls_back_to_the_defaults() {
        let (cfg, warnings) = load("[[source\nnope");
        assert_eq!(cfg, SourcesConfig::defaults());
        assert_eq!(warnings.len(), 1);
    }

    #[test]
    fn a_missing_file_is_the_defaults_without_a_warning() {
        let dir = tempfile::tempdir().unwrap();
        let (cfg, warnings) = load_file(&dir.path().join("sources.toml"));
        assert_eq!(cfg, SourcesConfig::defaults());
        assert!(warnings.is_empty());
    }

    #[test]
    fn github_repo_must_be_owner_slash_name() {
        for repo in ["onlyname", "a/b/c", "a b/c", "/c"] {
            let text =
                format!("[[source]]\nid = \"g\"\nkind = \"github_releases\"\nrepo = \"{repo}\"\n");
            let (cfg, warnings) = load(&text);
            assert!(cfg.sources.is_empty(), "{repo}");
            assert_eq!(warnings.len(), 1);
        }
    }

    #[test]
    fn context_switches_can_be_turned_off() {
        let (cfg, warnings) = load("[context]\nnotes = false\ntodos = \"no\"\nbogus = true\n");
        assert!(!cfg.context.notes);
        assert!(cfg.context.todos);
        assert_eq!(warnings.len(), 2, "{warnings:?}");
    }
}
