//! "How it runs": deterministic facts about a project, read from manifests,
//! the `.claude` layout and `git grep` counts, rendered to one line of at
//! most 300 chars (A9). Cached in `state/profiles/<project>.json` by HEAD sha.
//!
//! Nothing here keeps file contents: manifests yield dependency names and a
//! description, `git grep` yields file counts and `CLAUDE_CODE_*` names only.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use super::projects::{git, head_sha};
use crate::data::work::untrusted::one_line;

/// Longest rendered "how it runs" line.
pub const MAX_LINE_CHARS: usize = 300;
/// Most `CLAUDE_CODE_*` names kept.
const MAX_ENV_NAMES: usize = 5;
/// How deep below the project root manifests are looked for.
const MANIFEST_DEPTH: usize = 2;
const SKIP_DIRS: &[&str] = &[
    "node_modules",
    "target",
    "vendor",
    "build",
    "dist",
    "Pods",
    "DerivedData",
];

/// Package names that are an Anthropic SDK (compared after [`normalize`]).
const ANTHROPIC_SDKS: &[&str] = &[
    "anthropic",
    "@anthropic-ai/sdk",
    "@anthropic-ai/claude-agent-sdk",
    "claude-agent-sdk",
    "github.com/anthropics/anthropic-sdk-go",
];

/// Packages that make a project an MCP server.
const MCP_SERVER_PACKAGES: &[&str] = &[
    "rmcp",
    "mcp",
    "fastmcp",
    "@modelcontextprotocol/sdk",
    "github.com/mark3labs/mcp-go",
    "github.com/modelcontextprotocol/go-sdk",
];

/// The ways of starting Claude that are counted, in render order.
pub const INVOCATIONS: &[&str] = &[
    "claude -p",
    "--print",
    "--output-format stream-json",
    "--agent",
    "--resume",
];

/// Claude Code features, by the key the `claude_feature` probe answers with.
pub const FEATURES: &[(&str, &str)] = &[
    ("hooks", "hooks"),
    ("mcp_config", "an MCP config"),
    ("mcp_server", "an MCP server"),
    ("skills", "skills"),
    ("plugin", "a plugin"),
    ("agents", "agents"),
    ("settings", "project settings"),
];

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Profile {
    /// HEAD sha the profile was built at (`None` for a repo with no commits).
    pub head: Option<String>,
    /// Languages from manifests, in a fixed order.
    pub languages: Vec<String>,
    /// Repo-relative manifest paths found, sorted.
    pub manifests: Vec<String>,
    /// Anthropic SDK package names it depends on, sorted.
    pub sdks: Vec<String>,
    /// Entries of [`INVOCATIONS`] found in tracked files, in that order.
    pub invocation: Vec<String>,
    /// Keys of [`FEATURES`] present, in that order.
    pub features: Vec<String>,
    /// Distinct `CLAUDE_CODE_*` names referenced, sorted, at most 5.
    pub env_names: Vec<String>,
}

impl Profile {
    pub fn uses_anthropic_sdk(&self) -> bool {
        !self.sdks.is_empty()
    }

    /// The one-line render (at most [`MAX_LINE_CHARS`]).
    pub fn line(&self) -> String {
        let mut parts = Vec::new();
        parts.push(if self.languages.is_empty() {
            "language not detected".to_string()
        } else {
            self.languages.join(" + ")
        });
        if self.invocation.is_empty() {
            parts.push("no claude invocation found".to_string());
        } else {
            let forms: Vec<&str> = self
                .invocation
                .iter()
                .map(|f| if f == "claude -p" { "-p" } else { f.as_str() })
                .collect();
            parts.push(format!("starts claude with {}", and_list(&forms)));
        }
        let features: Vec<&str> = FEATURES
            .iter()
            .filter(|(key, _)| self.features.iter().any(|f| f == key))
            .map(|(_, phrase)| *phrase)
            .collect();
        if !features.is_empty() {
            parts.push(format!("relies on {}", features.join(", ")));
        }
        parts.push(if self.sdks.is_empty() {
            "does not use an Anthropic SDK".to_string()
        } else {
            format!("uses an Anthropic SDK ({})", self.sdks.join(", "))
        });
        if !self.env_names.is_empty() {
            parts.push(format!("env: {}", self.env_names.join(", ")));
        }
        one_line(&parts.join("; "), MAX_LINE_CHARS)
    }
}

fn and_list(items: &[&str]) -> String {
    match items {
        [] => String::new(),
        [one] => (*one).to_string(),
        [init @ .., last] => format!("{} and {}", init.join(", "), last),
    }
}

/// A package name as compared: lower-case, `_` as `-`.
pub fn normalize(name: &str) -> String {
    name.trim().to_lowercase().replace('_', "-")
}

/// One dependency declared in a manifest.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct Dependency {
    /// Normalised package name.
    pub name: String,
    /// Repo-relative manifest path.
    pub manifest: String,
}

/// Does dependency `dep` answer a probe for `query`? Exact, or the last
/// segment of a scoped or path-like name (`@scope/x`, `github.com/o/x`).
pub fn dependency_matches(dep: &str, query: &str) -> bool {
    let (dep, query) = (normalize(dep), normalize(query));
    !query.is_empty() && (dep == query || dep.rsplit('/').next() == Some(query.as_str()))
}

/// Every manifest file under `root` (depth ≤ 2), repo-relative, sorted.
pub fn manifest_files(root: &Path) -> Vec<String> {
    let mut out = Vec::new();
    walk_manifests(root, root, 0, &mut out);
    out.sort();
    out
}

fn is_manifest(name: &str) -> bool {
    matches!(
        name,
        "Cargo.toml"
            | "Cargo.lock"
            | "package.json"
            | "pyproject.toml"
            | "composer.json"
            | "Package.swift"
            | "go.mod"
            | "Gemfile"
    ) || (name.starts_with("requirements") && name.ends_with(".txt"))
}

fn walk_manifests(root: &Path, dir: &Path, depth: usize, out: &mut Vec<String>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    let mut entries: Vec<_> = entries.filter_map(Result::ok).collect();
    entries.sort_by_key(|e| e.file_name());
    for entry in entries {
        let name = entry.file_name().to_string_lossy().into_owned();
        let Ok(kind) = entry.file_type() else {
            continue;
        };
        let path = entry.path();
        let rel = || {
            path.strip_prefix(root)
                .unwrap_or(&path)
                .to_string_lossy()
                .into_owned()
        };
        let manifest = (kind.is_file() && is_manifest(&name))
            || (kind.is_dir() && name.ends_with(".xcodeproj"));
        if manifest {
            out.push(rel());
        } else if kind.is_dir()
            && depth < MANIFEST_DEPTH
            && !name.starts_with('.')
            && !SKIP_DIRS.contains(&name.as_str())
        {
            walk_manifests(root, &path, depth + 1, out);
        }
    }
}

/// Every dependency declared in the manifests under `root`, deduplicated,
/// sorted by name then manifest.
pub fn dependencies(root: &Path) -> Vec<Dependency> {
    let mut set = BTreeSet::new();
    for manifest in manifest_files(root) {
        let path = root.join(&manifest);
        let Ok(text) = std::fs::read_to_string(&path) else {
            continue;
        };
        let file = Path::new(&manifest)
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        for name in names_in_manifest(&file, &text) {
            set.insert(Dependency {
                name: normalize(&name),
                manifest: manifest.clone(),
            });
        }
    }
    set.into_iter().collect()
}

fn names_in_manifest(file: &str, text: &str) -> Vec<String> {
    match file {
        "Cargo.toml" => cargo_toml_names(text),
        "Cargo.lock" => toml_array_names(text, "package"),
        "package.json" => json_keys(
            text,
            &[
                "dependencies",
                "devDependencies",
                "peerDependencies",
                "optionalDependencies",
            ],
        ),
        "composer.json" => json_keys(text, &["require", "require-dev"]),
        "pyproject.toml" => pyproject_names(text),
        "Package.swift" => swift_package_names(text),
        "go.mod" => go_mod_names(text),
        "Gemfile" => gemfile_names(text),
        f if f.starts_with("requirements") => text.lines().filter_map(pep508_name).collect(),
        _ => Vec::new(),
    }
}

fn cargo_toml_names(text: &str) -> Vec<String> {
    let Ok(value) = text.parse::<toml::Table>() else {
        return Vec::new();
    };
    let mut out = Vec::new();
    let mut tables: Vec<&toml::Table> = vec![&value];
    if let Some(ws) = value.get("workspace").and_then(toml::Value::as_table) {
        tables.push(ws);
    }
    if let Some(targets) = value.get("target").and_then(toml::Value::as_table) {
        tables.extend(targets.values().filter_map(toml::Value::as_table));
    }
    for table in tables {
        for key in ["dependencies", "dev-dependencies", "build-dependencies"] {
            if let Some(deps) = table.get(key).and_then(toml::Value::as_table) {
                for (name, spec) in deps {
                    // `alias = { package = "real-name" }` depends on the real name.
                    let real = spec
                        .get("package")
                        .and_then(toml::Value::as_str)
                        .unwrap_or(name);
                    out.push(real.to_string());
                }
            }
        }
    }
    out
}

fn toml_array_names(text: &str, array: &str) -> Vec<String> {
    let Ok(value) = text.parse::<toml::Table>() else {
        return Vec::new();
    };
    value
        .get(array)
        .and_then(toml::Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|p| p.get("name").and_then(toml::Value::as_str))
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default()
}

fn json_keys(text: &str, keys: &[&str]) -> Vec<String> {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(text) else {
        return Vec::new();
    };
    keys.iter()
        .filter_map(|k| value.get(*k).and_then(serde_json::Value::as_object))
        .flat_map(|obj| obj.keys().cloned())
        .collect()
}

fn pyproject_names(text: &str) -> Vec<String> {
    let Ok(value) = text.parse::<toml::Table>() else {
        return Vec::new();
    };
    let mut out = Vec::new();
    if let Some(project) = value.get("project") {
        if let Some(deps) = project.get("dependencies").and_then(toml::Value::as_array) {
            out.extend(deps.iter().filter_map(|d| d.as_str().and_then(pep508_name)));
        }
        if let Some(groups) = project
            .get("optional-dependencies")
            .and_then(toml::Value::as_table)
        {
            for deps in groups.values().filter_map(toml::Value::as_array) {
                out.extend(deps.iter().filter_map(|d| d.as_str().and_then(pep508_name)));
            }
        }
    }
    if let Some(poetry) = value
        .get("tool")
        .and_then(|t| t.get("poetry"))
        .and_then(toml::Value::as_table)
    {
        for key in ["dependencies", "dev-dependencies"] {
            if let Some(deps) = poetry.get(key).and_then(toml::Value::as_table) {
                out.extend(deps.keys().filter(|k| *k != "python").cloned());
            }
        }
    }
    out
}

/// The distribution name of a PEP 508 requirement line (`anthropic>=0.30`).
fn pep508_name(line: &str) -> Option<String> {
    let line = line.split('#').next()?.trim();
    if line.is_empty() || line.starts_with('-') {
        return None;
    }
    let end = line
        .find(|c: char| !(c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.')))
        .unwrap_or(line.len());
    let name = &line[..end];
    (!name.is_empty()).then(|| name.to_string())
}

fn swift_package_names(text: &str) -> Vec<String> {
    // `.package(url: "https://github.com/org/name.git", …)` → `name`.
    let re = regex::Regex::new(r#"\.package\s*\(\s*(?:name:\s*"[^"]*"\s*,\s*)?url:\s*"([^"]+)""#)
        .expect("valid regex");
    re.captures_iter(text)
        .filter_map(|c| {
            let url = c.get(1)?.as_str().trim_end_matches('/');
            let last = url.rsplit('/').next()?;
            Some(last.trim_end_matches(".git").to_string())
        })
        .collect()
}

fn go_mod_names(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut in_block = false;
    for line in text.lines() {
        let line = line.split("//").next().unwrap_or("").trim();
        if in_block {
            if line == ")" {
                in_block = false;
            } else if let Some(module) = line.split_whitespace().next() {
                out.push(module.to_string());
            }
        } else if line == "require (" {
            in_block = true;
        } else if let Some(rest) = line.strip_prefix("require ") {
            if let Some(module) = rest.split_whitespace().next() {
                out.push(module.to_string());
            }
        }
    }
    out
}

fn gemfile_names(text: &str) -> Vec<String> {
    let re = regex::Regex::new(r#"^\s*gem\s+["']([^"']+)["']"#).expect("valid regex");
    text.lines()
        .filter_map(|l| re.captures(l).map(|c| c[1].to_string()))
        .collect()
}

fn languages(root: &Path, manifests: &[String]) -> Vec<String> {
    let has = |name: &str| {
        manifests.iter().any(|m| {
            Path::new(m)
                .file_name()
                .is_some_and(|n| n.to_string_lossy() == name)
        })
    };
    let mut out = Vec::new();
    if has("Cargo.toml") {
        out.push("Rust");
    }
    if has("Package.swift") || manifests.iter().any(|m| m.ends_with(".xcodeproj")) {
        out.push("Swift");
    }
    if has("go.mod") {
        out.push("Go");
    }
    if has("pyproject.toml")
        || manifests.iter().any(|m| {
            m.rsplit('/')
                .next()
                .is_some_and(|f| f.starts_with("requirements"))
        })
    {
        out.push("Python");
    }
    if has("package.json") {
        out.push(if root.join("tsconfig.json").exists() {
            "TypeScript"
        } else {
            "JavaScript"
        });
    }
    if has("composer.json") {
        out.push("PHP");
    }
    if has("Gemfile") {
        out.push("Ruby");
    }
    if out.is_empty() && has_shell_scripts(root) {
        out.push("Shell");
    }
    out.into_iter().map(str::to_string).collect()
}

fn has_shell_scripts(root: &Path) -> bool {
    [root.to_path_buf(), root.join("bin"), root.join("scripts")]
        .iter()
        .filter_map(|d| std::fs::read_dir(d).ok())
        .flatten()
        .filter_map(Result::ok)
        .any(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            name.ends_with(".sh") || name.ends_with(".bash") || name.ends_with(".zsh")
        })
}

fn features(root: &Path, deps: &[Dependency]) -> Vec<String> {
    let claude = root.join(".claude");
    let settings: Vec<PathBuf> = std::fs::read_dir(&claude)
        .map(|rd| {
            rd.filter_map(Result::ok)
                .map(|e| e.path())
                .filter(|p| {
                    p.file_name().is_some_and(|n| {
                        let n = n.to_string_lossy();
                        n.starts_with("settings") && n.ends_with(".json")
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    let has_hooks = settings.iter().any(|p| {
        std::fs::read_to_string(p)
            .ok()
            .and_then(|t| serde_json::from_str::<serde_json::Value>(&t).ok())
            .and_then(|v| v.get("hooks").cloned())
            .is_some_and(|h| h.as_object().is_some_and(|o| !o.is_empty()))
    });
    let mcp_server = deps
        .iter()
        .any(|d| MCP_SERVER_PACKAGES.iter().any(|p| normalize(p) == d.name));
    let present = |key: &str| match key {
        "hooks" => has_hooks,
        "mcp_config" => root.join(".mcp.json").is_file(),
        "mcp_server" => mcp_server,
        "skills" => claude.join("skills").is_dir(),
        "plugin" => root.join(".claude-plugin").join("plugin.json").is_file(),
        "agents" => claude.join("agents").is_dir(),
        "settings" => !settings.is_empty(),
        _ => false,
    };
    FEATURES
        .iter()
        .filter(|(key, _)| present(key))
        .map(|(key, _)| (*key).to_string())
        .collect()
}

/// Number of tracked files at HEAD containing `term` (fixed string), and the
/// first repo-relative paths. `None` when git could not answer.
pub(crate) fn grep_files(root: &Path, term: &str) -> Option<Vec<String>> {
    let out = git(root, &["grep", "-F", "-l", "-I", "-e", term, "HEAD", "--"])?;
    match out.code {
        0 => Some(
            String::from_utf8_lossy(&out.stdout)
                .lines()
                .map(|l| l.strip_prefix("HEAD:").unwrap_or(l).to_string())
                .collect(),
        ),
        1 => Some(Vec::new()),
        _ => None,
    }
}

fn env_names(root: &Path) -> Vec<String> {
    let Some(out) = git(
        root,
        &[
            "grep",
            "-I",
            "-h",
            "-o",
            "-E",
            "-e",
            "CLAUDE_CODE_[A-Z0-9_]+",
            "HEAD",
            "--",
        ],
    ) else {
        return Vec::new();
    };
    if out.code != 0 {
        return Vec::new();
    }
    let names: BTreeSet<String> = String::from_utf8_lossy(&out.stdout)
        .lines()
        .map(|l| l.rsplit(':').next().unwrap_or(l).trim().to_string())
        .filter(|n| n.starts_with("CLAUDE_CODE_") && n.len() <= 64)
        .collect();
    names.into_iter().take(MAX_ENV_NAMES).collect()
}

/// Build the profile of the project at `root` (its main worktree).
pub fn profile(root: &Path) -> Profile {
    let head = head_sha(root);
    let manifests = manifest_files(root);
    let deps = dependencies(root);
    let sdk_names: Vec<String> = ANTHROPIC_SDKS.iter().map(|s| normalize(s)).collect();
    let sdks: BTreeSet<String> = deps
        .iter()
        .filter(|d| sdk_names.contains(&d.name))
        .map(|d| d.name.clone())
        .collect();
    let invocation = if head.is_some() {
        INVOCATIONS
            .iter()
            .filter(|form| grep_files(root, form).is_some_and(|files| !files.is_empty()))
            .map(|f| (*f).to_string())
            .collect()
    } else {
        Vec::new()
    };
    let env_names = if head.is_some() {
        env_names(root)
    } else {
        Vec::new()
    };
    Profile {
        head,
        languages: languages(root, &manifests),
        features: features(root, &deps),
        sdks: sdks.into_iter().collect(),
        manifests,
        invocation,
        env_names,
    }
}

/// [`profile`], reusing `<cache_dir>/<project>.json` when it was built at the
/// current HEAD, and refreshing it otherwise. With no cache dir (the setup
/// scan, which writes nothing) it always builds.
pub fn profile_cached(root: &Path, project: &str, cache_dir: Option<&Path>) -> Profile {
    let Some(dir) = cache_dir else {
        return profile(root);
    };
    let file = dir.join(format!("{project}.json"));
    let head = head_sha(root);
    if head.is_some() {
        if let Some(cached) = std::fs::read(&file)
            .ok()
            .and_then(|b| serde_json::from_slice::<Profile>(&b).ok())
            .filter(|p| p.head == head)
        {
            return cached;
        }
    }
    let fresh = profile(root);
    if fresh.head.is_some() {
        if let Ok(bytes) = serde_json::to_vec_pretty(&fresh) {
            if let Err(e) = crate::huey::setup::write_atomic(&file, &bytes) {
                tracing::warn!(kind = ?e.kind(), "huey: could not cache a project profile");
            }
        }
    }
    fresh
}

/// A one-line description of the project for the draft interests file: the
/// root manifest's `description`, else the README's first sentence; at most
/// 160 chars.
pub fn description(root: &Path) -> Option<String> {
    const MAX: usize = 160;
    let from_toml = |file: &str, path: &[&str]| -> Option<String> {
        let text = std::fs::read_to_string(root.join(file)).ok()?;
        let table = toml::Value::Table(text.parse::<toml::Table>().ok()?);
        let mut cur = &table;
        for key in path {
            cur = cur.get(*key)?;
        }
        cur.as_str().map(str::to_string)
    };
    let from_json = |file: &str| -> Option<String> {
        let text = std::fs::read_to_string(root.join(file)).ok()?;
        let v: serde_json::Value = serde_json::from_str(&text).ok()?;
        v.get("description")?.as_str().map(str::to_string)
    };
    let found = from_toml("Cargo.toml", &["package", "description"])
        .or_else(|| from_json("package.json"))
        .or_else(|| from_toml("pyproject.toml", &["project", "description"]))
        .or_else(|| from_json("composer.json"))
        .or_else(|| readme_first_sentence(root));
    found.map(|d| one_line(&d, MAX)).filter(|d| !d.is_empty())
}

fn readme_first_sentence(root: &Path) -> Option<String> {
    let text = ["README.md", "README", "readme.md", "README.markdown"]
        .iter()
        .find_map(|f| std::fs::read_to_string(root.join(f)).ok())?;
    let mut paragraph = String::new();
    for line in text.lines() {
        let t = line.trim();
        let skip = t.starts_with('#')
            || t.starts_with("![")
            || t.starts_with("[![")
            || t.starts_with('<')
            || t.starts_with("```")
            || t.starts_with('>')
            || t.starts_with("---");
        if t.is_empty() || skip {
            if !paragraph.is_empty() {
                break;
            }
            continue;
        }
        if !paragraph.is_empty() {
            paragraph.push(' ');
        }
        paragraph.push_str(t);
    }
    if paragraph.is_empty() {
        return None;
    }
    let sentence = match paragraph.find(". ") {
        Some(i) => &paragraph[..=i],
        None => paragraph.as_str(),
    };
    Some(sentence.to_string())
}
