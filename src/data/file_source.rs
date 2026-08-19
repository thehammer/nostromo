//! File retrieval for the `nostromo.get_file` pane source (W2 —
//! curated-agent-views): resolve a revision, read a file at it, and refuse
//! loudly rather than render something misleading.
//!
//! ## Revision resolution (D5)
//!
//! - **absent** — the PR under review's head SHA when a PR is loaded, else the
//!   working tree. This is the reading that matches what an agent means when it
//!   says "show me this file" mid-review: the file as the PR has it, not as the
//!   operator's dirty worktree has it.
//! - **`"working"`** — read from disk, relative to the focus's session cwd.
//! - **anything else** — a git revision: `git show <rev>:<path>` in the session
//!   cwd, falling back to the GitHub contents API when git doesn't have the
//!   object. That fallback is the common case, not the exotic one: a PR head
//!   from a fork was very likely never fetched locally.
//!
//! ## Why every failure is a refusal, not a best-effort render
//!
//! "A bad show never destroys what Hammer was reading" is a product criterion,
//! and this module is where it is enforced: every function here fails *before*
//! producing a [`FileContent`], so the caller has nothing to broadcast and the
//! pane keeps whatever it already had. A file view that silently showed the
//! working-tree version because the requested SHA was unreachable would be
//! indistinguishable from a correct answer, which is worse than an error.

use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::ipc::protocol::Emphasis;

/// Every way `nostromo.get_file` can refuse. Each is a distinct stable code so
/// a caller can tell "you asked for a line past EOF" from "that path doesn't
/// exist" without string-matching a message.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileSourceError {
    /// `params` was absent, not an object, or had no usable `path`.
    InvalidParams,
    /// The path does not exist at the resolved revision.
    UnknownPath,
    /// The path resolves outside the focus's session cwd.
    PathEscapesRoot,
    /// The file's bytes are not valid UTF-8 (an image, a binary).
    NotUtf8,
    /// `anchor_line` is 0 or past the last line of the file.
    AnchorBeyondEof,
    /// An emphasis range has `end < start`, `start == 0`, or extends past EOF.
    InvalidEmphasisRange,
    /// The revision could not be resolved by git or by the contents API.
    UnresolvableRevision,
}

impl FileSourceError {
    /// The stable snake_case code for the wire.
    pub fn code(self) -> &'static str {
        match self {
            FileSourceError::InvalidParams => "invalid_params",
            FileSourceError::UnknownPath => "unknown_path",
            FileSourceError::PathEscapesRoot => "path_escapes_root",
            FileSourceError::NotUtf8 => "not_utf8",
            FileSourceError::AnchorBeyondEof => "anchor_beyond_eof",
            FileSourceError::InvalidEmphasisRange => "invalid_emphasis_range",
            FileSourceError::UnresolvableRevision => "unresolvable_revision",
        }
    }
}

/// The literal `revision` value meaning "the on-disk working tree".
pub const WORKING_TREE: &str = "working";

/// A parsed `nostromo.get_file` params object.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct FileRequest {
    /// Repo-relative path, as asked for.
    pub path: String,
    /// `None` means "resolve it for me" — see the module docs.
    pub revision: Option<String>,
    /// Where to scroll on arrival.
    pub anchor_line: Option<u32>,
    /// Inclusive 1-based line ranges to mark.
    pub emphasis: Vec<(u32, u32)>,
}

impl FileRequest {
    /// Parse the tool-supplied `params` object.
    ///
    /// Shape errors are caught here, before any I/O, so a malformed request
    /// costs nothing and — crucially — is refused before the caller has
    /// broadcast anything.
    pub fn from_params(params: &Value) -> Result<Self, FileSourceError> {
        let obj = params.as_object().ok_or(FileSourceError::InvalidParams)?;
        let path = obj
            .get("path")
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .ok_or(FileSourceError::InvalidParams)?
            .to_string();

        let revision = match obj.get("revision") {
            None | Some(Value::Null) => None,
            Some(Value::String(s)) if !s.is_empty() => Some(s.clone()),
            Some(_) => return Err(FileSourceError::InvalidParams),
        };

        let anchor_line = match obj.get("anchor_line") {
            None | Some(Value::Null) => None,
            Some(v) => {
                let n = v.as_u64().ok_or(FileSourceError::InvalidParams)?;
                let n = u32::try_from(n).map_err(|_| FileSourceError::AnchorBeyondEof)?;
                if n == 0 {
                    return Err(FileSourceError::AnchorBeyondEof);
                }
                Some(n)
            }
        };

        let mut emphasis = Vec::new();
        match obj.get("emphasis") {
            None | Some(Value::Null) => {}
            Some(Value::Array(items)) => {
                for item in items {
                    let (start, end) = parse_range(item)?;
                    emphasis.push((start, end));
                }
            }
            Some(_) => return Err(FileSourceError::InvalidParams),
        }

        Ok(FileRequest {
            path,
            revision,
            anchor_line,
            emphasis,
        })
    }

    /// This request's emphasis ranges as wire [`Emphasis`] values.
    pub fn emphasis_wire(&self) -> Vec<Emphasis> {
        self.emphasis
            .iter()
            .map(|(start, end)| Emphasis::LineRange {
                path: None,
                start: *start,
                end: *end,
            })
            .collect()
    }
}

/// Accept either `{ "start": n, "end": m }` or the shorthand `[n, m]`.
fn parse_range(item: &Value) -> Result<(u32, u32), FileSourceError> {
    let (start, end) = match item {
        Value::Object(o) => {
            let s = o
                .get("start")
                .and_then(|v| v.as_u64())
                .ok_or(FileSourceError::InvalidParams)?;
            let e = o
                .get("end")
                .and_then(|v| v.as_u64())
                .ok_or(FileSourceError::InvalidParams)?;
            (s, e)
        }
        Value::Array(a) if a.len() == 2 => {
            let s = a[0].as_u64().ok_or(FileSourceError::InvalidParams)?;
            let e = a[1].as_u64().ok_or(FileSourceError::InvalidParams)?;
            (s, e)
        }
        _ => return Err(FileSourceError::InvalidParams),
    };
    let start = u32::try_from(start).map_err(|_| FileSourceError::InvalidEmphasisRange)?;
    let end = u32::try_from(end).map_err(|_| FileSourceError::InvalidEmphasisRange)?;
    if start == 0 || end < start {
        return Err(FileSourceError::InvalidEmphasisRange);
    }
    Ok((start, end))
}

/// A file read at a resolved revision.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileContent {
    pub path: String,
    /// The revision actually read: a git rev/SHA, or [`WORKING_TREE`].
    pub revision: String,
    pub text: String,
}

/// Resolve `request.revision` to the concrete revision string to read at.
///
/// `head_sha` is the PR-under-review's head SHA, empty when no PR is loaded.
pub fn resolve_revision(request: &FileRequest, head_sha: &str) -> String {
    match &request.revision {
        Some(rev) => rev.clone(),
        None if !head_sha.is_empty() => head_sha.to_string(),
        None => WORKING_TREE.to_string(),
    }
}

/// Join `path` onto `root` and refuse anything that escapes it.
///
/// Containment is checked on the *lexically normalised* path rather than on
/// `canonicalize`, because the file need not exist on disk at all (a
/// git-revision read never touches the working tree) and `canonicalize` fails
/// for a missing path. Normalising `..` away first means `../../etc/passwd`
/// is rejected whether or not it happens to exist.
pub fn resolve_within_root(root: &Path, path: &str) -> Result<PathBuf, FileSourceError> {
    let candidate = Path::new(path);
    if candidate.is_absolute() {
        // An absolute path is only acceptable if it is already inside root.
        let normalised = normalise(candidate);
        return if normalised.starts_with(root) {
            Ok(normalised)
        } else {
            Err(FileSourceError::PathEscapesRoot)
        };
    }
    let normalised = normalise(&root.join(candidate));
    if normalised.starts_with(root) {
        Ok(normalised)
    } else {
        Err(FileSourceError::PathEscapesRoot)
    }
}

/// Lexically resolve `.`/`..` without touching the filesystem.
fn normalise(p: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in p.components() {
        match component {
            std::path::Component::ParentDir => {
                out.pop();
            }
            std::path::Component::CurDir => {}
            other => out.push(other.as_os_str()),
        }
    }
    out
}

/// Validate `anchor_line`/`emphasis` against the file's actual length.
///
/// Separated from reading so the refusal set is one testable function rather
/// than four scattered `if`s in the fetch path.
pub fn validate_against(text: &str, request: &FileRequest) -> Result<(), FileSourceError> {
    let line_count = line_count(text);
    if let Some(anchor) = request.anchor_line {
        if anchor as usize > line_count {
            return Err(FileSourceError::AnchorBeyondEof);
        }
    }
    for (_start, end) in &request.emphasis {
        if *end as usize > line_count {
            return Err(FileSourceError::InvalidEmphasisRange);
        }
    }
    Ok(())
}

/// How many lines `text` renders as: the same count a gutter would number.
///
/// The empty string is one (empty) line, and a trailing newline does not
/// create a phantom final line — matching how every editor numbers a file.
pub fn line_count(text: &str) -> usize {
    let body = text.strip_suffix('\n').unwrap_or(text);
    body.split('\n').count()
}

// ── reads ────────────────────────────────────────────────────────────────────

/// Read the working-tree copy of `path` under `root`.
pub fn read_working_tree(root: &Path, path: &str) -> Result<String, FileSourceError> {
    let full = resolve_within_root(root, path)?;
    let bytes = std::fs::read(&full).map_err(|_| FileSourceError::UnknownPath)?;
    String::from_utf8(bytes).map_err(|_| FileSourceError::NotUtf8)
}

/// Read `path` at git revision `rev`, via `git show <rev>:<path>` in `root`.
///
/// Returns `Ok(None)` — not an error — when git ran but doesn't have the
/// object, which is the signal the caller uses to try the GitHub contents
/// API. A genuinely bad path *inside* a revision git does have is
/// indistinguishable from a missing object at this layer, so it also comes
/// back as `Ok(None)` and is resolved (or refused) one level up.
pub fn read_git_revision(
    root: &Path,
    rev: &str,
    path: &str,
) -> Result<Option<String>, FileSourceError> {
    // Containment still applies: `git show` would happily read `../secrets`
    // out of a parent repo.
    resolve_within_root(root, path)?;
    let spec = format!("{rev}:{path}");
    let output = std::process::Command::new("git")
        .arg("-C")
        .arg(root)
        .arg("show")
        .arg(&spec)
        .output()
        .map_err(|_| FileSourceError::UnresolvableRevision)?;
    if !output.status.success() {
        return Ok(None);
    }
    match String::from_utf8(output.stdout) {
        Ok(text) => Ok(Some(text)),
        Err(_) => Err(FileSourceError::NotUtf8),
    }
}

/// Read `path` at `revision` without touching the network: the working tree
/// when `revision` is [`WORKING_TREE`], else `git show <revision>:<path>`.
///
/// `UnresolvableRevision` here means specifically "git couldn't produce this
/// object", which is the caller's signal to try [`read_from_github`] — not a
/// terminal answer. Kept next to [`read_working_tree`]/[`read_git_revision`]
/// since it is just their dispatch, with no daemon state involved.
pub fn read_at_revision(root: &Path, revision: &str, path: &str) -> Result<String, FileSourceError> {
    if revision == WORKING_TREE {
        return read_working_tree(root, path);
    }
    match read_git_revision(root, revision, path)? {
        Some(text) => Ok(text),
        None => Err(FileSourceError::UnresolvableRevision),
    }
}

/// Last-resort read via the GitHub contents API, against `repo` (`"owner/name"`,
/// the repo of the PR currently under review). The common case, not the exotic
/// one: a PR head from a fork was very likely never fetched locally, so
/// [`read_at_revision`] fails with `UnresolvableRevision` and the caller comes
/// here instead.
pub async fn read_from_github(
    repo: &str,
    revision: &str,
    path: &str,
) -> Result<String, FileSourceError> {
    let mut parts = repo.split('/');
    let (Some(owner), Some(name), None) = (parts.next(), parts.next(), parts.next()) else {
        return Err(FileSourceError::UnresolvableRevision);
    };
    if owner.is_empty() || name.is_empty() {
        return Err(FileSourceError::UnresolvableRevision);
    }
    let client = crate::data::github_client::GithubClient::new(None)
        .map_err(|_| FileSourceError::UnresolvableRevision)?;
    let base = std::env::var("NOSTROMO_GITHUB_API_BASE")
        .unwrap_or_else(|_| crate::data::github_client::GITHUB_API_BASE.to_string());
    match client.file_at_ref(&base, owner, name, path, revision).await {
        Ok(Some(text)) => Ok(text),
        // A 404 from the contents API is the API's way of saying "not at that
        // ref" — which, having already failed locally, is unresolvable.
        Ok(None) => Err(FileSourceError::UnknownPath),
        Err(_) => Err(FileSourceError::UnresolvableRevision),
    }
}

// ── tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // ── FileRequest::from_params — malformed shapes are refused ──────────────

    #[test]
    fn from_params_rejects_a_non_object() {
        assert_eq!(
            FileRequest::from_params(&json!("not an object")).unwrap_err(),
            FileSourceError::InvalidParams
        );
        assert_eq!(
            FileRequest::from_params(&json!([1, 2, 3])).unwrap_err(),
            FileSourceError::InvalidParams
        );
        assert_eq!(
            FileRequest::from_params(&json!(null)).unwrap_err(),
            FileSourceError::InvalidParams
        );
    }

    #[test]
    fn from_params_rejects_a_missing_or_empty_path() {
        assert_eq!(
            FileRequest::from_params(&json!({})).unwrap_err(),
            FileSourceError::InvalidParams
        );
        assert_eq!(
            FileRequest::from_params(&json!({ "path": "" })).unwrap_err(),
            FileSourceError::InvalidParams
        );
        assert_eq!(
            FileRequest::from_params(&json!({ "path": 42 })).unwrap_err(),
            FileSourceError::InvalidParams
        );
    }

    #[test]
    fn from_params_rejects_a_non_string_revision() {
        assert_eq!(
            FileRequest::from_params(&json!({ "path": "a.rs", "revision": 42 })).unwrap_err(),
            FileSourceError::InvalidParams
        );
    }

    #[test]
    fn from_params_rejects_anchor_line_zero_as_beyond_eof() {
        assert_eq!(
            FileRequest::from_params(&json!({ "path": "a.rs", "anchor_line": 0 })).unwrap_err(),
            FileSourceError::AnchorBeyondEof
        );
    }

    #[test]
    fn from_params_rejects_a_non_array_emphasis() {
        assert_eq!(
            FileRequest::from_params(&json!({ "path": "a.rs", "emphasis": "not an array" }))
                .unwrap_err(),
            FileSourceError::InvalidParams
        );
        assert_eq!(
            FileRequest::from_params(&json!({ "path": "a.rs", "emphasis": {} })).unwrap_err(),
            FileSourceError::InvalidParams
        );
    }

    // ── FileRequest::from_params — emphasis accepted in both documented shapes

    #[test]
    fn from_params_accepts_emphasis_as_object_shape() {
        let req = FileRequest::from_params(&json!({
            "path": "a.rs",
            "emphasis": [{ "start": 1, "end": 3 }]
        }))
        .unwrap();
        assert_eq!(req.emphasis, vec![(1, 3)]);
    }

    #[test]
    fn from_params_accepts_emphasis_as_array_shorthand() {
        let req = FileRequest::from_params(&json!({
            "path": "a.rs",
            "emphasis": [[1, 3]]
        }))
        .unwrap();
        assert_eq!(req.emphasis, vec![(1, 3)]);
    }

    // ── FileRequest::from_params — invalid emphasis ranges ────────────────────

    #[test]
    fn from_params_rejects_emphasis_range_with_end_before_start() {
        assert_eq!(
            FileRequest::from_params(&json!({
                "path": "a.rs",
                "emphasis": [{ "start": 5, "end": 3 }]
            }))
            .unwrap_err(),
            FileSourceError::InvalidEmphasisRange
        );
    }

    #[test]
    fn from_params_rejects_emphasis_range_starting_at_zero() {
        assert_eq!(
            FileRequest::from_params(&json!({
                "path": "a.rs",
                "emphasis": [{ "start": 0, "end": 3 }]
            }))
            .unwrap_err(),
            FileSourceError::InvalidEmphasisRange
        );
    }

    // ── resolve_revision ───────────────────────────────────────────────────────

    #[test]
    fn resolve_revision_absent_with_head_sha_resolves_to_head_sha() {
        let req = FileRequest {
            path: "a.rs".into(),
            revision: None,
            anchor_line: None,
            emphasis: vec![],
        };
        assert_eq!(resolve_revision(&req, "abc123"), "abc123");
    }

    #[test]
    fn resolve_revision_absent_with_empty_head_sha_resolves_to_working() {
        let req = FileRequest {
            path: "a.rs".into(),
            revision: None,
            anchor_line: None,
            emphasis: vec![],
        };
        assert_eq!(resolve_revision(&req, ""), WORKING_TREE);
    }

    #[test]
    fn resolve_revision_explicit_revision_is_used_verbatim_even_when_literally_working() {
        let req = FileRequest {
            path: "a.rs".into(),
            revision: Some("deadbeef".into()),
            anchor_line: None,
            emphasis: vec![],
        };
        assert_eq!(resolve_revision(&req, "abc123"), "deadbeef");

        let req_working = FileRequest {
            path: "a.rs".into(),
            revision: Some(WORKING_TREE.into()),
            anchor_line: None,
            emphasis: vec![],
        };
        assert_eq!(resolve_revision(&req_working, "abc123"), WORKING_TREE);
    }

    // ── resolve_within_root ────────────────────────────────────────────────────

    #[test]
    fn resolve_within_root_refuses_dot_dot_escapes() {
        let root = Path::new("/repo/root");
        assert_eq!(
            resolve_within_root(root, "../escape").unwrap_err(),
            FileSourceError::PathEscapesRoot
        );
        assert_eq!(
            resolve_within_root(root, "a/../../escape").unwrap_err(),
            FileSourceError::PathEscapesRoot
        );
    }

    #[test]
    fn resolve_within_root_refuses_an_absolute_path_outside_root() {
        let root = Path::new("/repo/root");
        assert_eq!(
            resolve_within_root(root, "/etc/passwd").unwrap_err(),
            FileSourceError::PathEscapesRoot
        );
    }

    #[test]
    fn resolve_within_root_accepts_a_normal_relative_path() {
        let root = Path::new("/repo/root");
        let resolved = resolve_within_root(root, "src/main.rs").unwrap();
        assert_eq!(resolved, Path::new("/repo/root/src/main.rs"));
    }

    #[test]
    fn resolve_within_root_accepts_an_absolute_path_inside_root() {
        let root = Path::new("/repo/root");
        let resolved = resolve_within_root(root, "/repo/root/src/main.rs").unwrap();
        assert_eq!(resolved, Path::new("/repo/root/src/main.rs"));
    }

    // ── line_count ─────────────────────────────────────────────────────────────

    #[test]
    fn line_count_counts_lines_without_a_phantom_trailing_line() {
        assert_eq!(line_count(""), 1);
        assert_eq!(line_count("a"), 1);
        assert_eq!(line_count("a\nb"), 2);
        assert_eq!(line_count("a\nb\n"), 2);
    }

    // ── validate_against ───────────────────────────────────────────────────────

    #[test]
    fn validate_against_rejects_anchor_past_eof() {
        let req = FileRequest {
            path: "a.rs".into(),
            revision: None,
            anchor_line: Some(3),
            emphasis: vec![],
        };
        assert_eq!(
            validate_against("line1\nline2\n", &req).unwrap_err(),
            FileSourceError::AnchorBeyondEof
        );
    }

    #[test]
    fn validate_against_rejects_emphasis_end_past_eof() {
        let req = FileRequest {
            path: "a.rs".into(),
            revision: None,
            anchor_line: None,
            emphasis: vec![(1, 5)],
        };
        assert_eq!(
            validate_against("line1\nline2\n", &req).unwrap_err(),
            FileSourceError::InvalidEmphasisRange
        );
    }

    #[test]
    fn validate_against_accepts_anchor_exactly_on_last_line() {
        let req = FileRequest {
            path: "a.rs".into(),
            revision: None,
            anchor_line: Some(2),
            emphasis: vec![],
        };
        assert!(validate_against("line1\nline2\n", &req).is_ok());
    }

    // ── read_working_tree ──────────────────────────────────────────────────────

    #[test]
    fn read_working_tree_reads_an_existing_file() {
        let tmp = tempfile::TempDir::new().unwrap();
        std::fs::write(tmp.path().join("hello.txt"), "hello world").unwrap();
        let text = read_working_tree(tmp.path(), "hello.txt").unwrap();
        assert_eq!(text, "hello world");
    }

    #[test]
    fn read_working_tree_missing_file_returns_unknown_path() {
        let tmp = tempfile::TempDir::new().unwrap();
        assert_eq!(
            read_working_tree(tmp.path(), "does/not/exist.rs").unwrap_err(),
            FileSourceError::UnknownPath
        );
    }

    #[test]
    fn read_working_tree_invalid_utf8_returns_not_utf8() {
        let tmp = tempfile::TempDir::new().unwrap();
        std::fs::write(tmp.path().join("binary.bin"), [0xff, 0xfe, 0x00, 0xff]).unwrap();
        assert_eq!(
            read_working_tree(tmp.path(), "binary.bin").unwrap_err(),
            FileSourceError::NotUtf8
        );
    }
}
