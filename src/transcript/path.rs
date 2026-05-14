//! Path helpers for Claude Code JSONL session logs.
//!
//! Claude sanitizes `cwd` by replacing every `/` with `-`, then stores logs at:
//! `~/.claude/projects/<sanitized-cwd>/<session-id>.jsonl`
//!
//! The leading `/` in an absolute path becomes a leading `-`, so
//! `/Users/hammer/Code/nostromo` → `-Users-hammer-Code-nostromo`.

use std::path::{Path, PathBuf};

/// Return the project directory for `cwd` inside `~/.claude/projects/`.
pub fn project_dir(cwd: &Path) -> PathBuf {
    let sanitized = cwd.to_string_lossy().replace('/', "-");
    dirs_next::home_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join(".claude")
        .join("projects")
        .join(sanitized)
}

/// Return the full path to the JSONL log for `(cwd, session_id)`.
pub fn jsonl_path(cwd: &Path, session_id: &str) -> PathBuf {
    project_dir(cwd).join(format!("{session_id}.jsonl"))
}

/// Scan the project directory for `cwd` and return the stem (session id) of
/// the most-recently-modified `*.jsonl` file, if any.
pub fn find_latest_session_id_for_cwd(cwd: &Path) -> Option<String> {
    let dir = project_dir(cwd);
    let entries = std::fs::read_dir(&dir).ok()?;

    let mut candidates: Vec<(std::time::SystemTime, String)> = entries
        .filter_map(|e| {
            let e = e.ok()?;
            let path = e.path();
            if path.extension()?.to_str()? != "jsonl" {
                return None;
            }
            let stem = path.file_stem()?.to_str()?.to_string();
            let mtime = e.metadata().ok()?.modified().ok()?;
            Some((mtime, stem))
        })
        .collect();

    // Most-recently-modified first.
    candidates.sort_by_key(|b| std::cmp::Reverse(b.0));
    candidates.into_iter().next().map(|(_, stem)| stem)
}

// ── tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn jsonl_path_sanitization() {
        let cwd = Path::new("/Users/hammer/Code/nostromo");
        let path = jsonl_path(cwd, "abcd");

        // Must end with the expected suffix.
        let path_str = path.to_string_lossy();
        assert!(
            path_str.ends_with(".claude/projects/-Users-hammer-Code-nostromo/abcd.jsonl"),
            "got: {path_str}"
        );
    }

    #[test]
    fn project_dir_leading_dash() {
        let cwd = Path::new("/tmp");
        let dir = project_dir(cwd);
        let name = dir.file_name().unwrap().to_string_lossy();
        assert_eq!(name, "-tmp");
    }
}
