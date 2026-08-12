//! Writer side of the `current-pr.json` / `current-pr.dirty` file contract.
//!
//! The reader side lives in
//! [`crate::data::perri_pr_native::CurrentPrPointer`] /
//! `PerriPrNativeSource::fetch`. Both `PerriView::load_pr`/`clear_current_pr`
//! (TUI) and the daemon-hosted `perri.load_pr`/`perri.clear_current_pr` MCP
//! handlers write through this module instead of duplicating the file shape,
//! so the two hosts can never drift on what "the current PR" means on disk.

use std::path::Path;

use serde_json::json;

/// Validate a `"owner/repo"` slug: non-empty, exactly one `/`, both halves
/// non-empty, and restricted to `[A-Za-z0-9._-]` so it can never be
/// misinterpreted as a path/shell fragment once it ends up in a GitHub API
/// URL or a cache filename.
pub fn validate_repo_slug(repo: &str) -> Result<(), String> {
    let mut parts = repo.split('/');
    let (owner, name) = match (parts.next(), parts.next(), parts.next()) {
        (Some(o), Some(n), None) if !o.is_empty() && !n.is_empty() => (o, n),
        _ => {
            return Err(format!(
                "invalid_repo: {repo:?} must be in \"owner/repo\" form"
            ));
        }
    };
    let is_valid_char = |c: char| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-');
    if !owner.chars().all(is_valid_char) || !name.chars().all(is_valid_char) {
        return Err(format!(
            "invalid_repo: {repo:?} contains characters outside [A-Za-z0-9._-]"
        ));
    }
    Ok(())
}

/// Write `<state_dir>/current-pr.json` and touch `current-pr.dirty`.
///
/// Matches the shape `PerriPrNativeSource`/`CurrentPrPointer` expects:
/// `{ number, repo, highlights }` — `highlights` serializes as `null` when
/// absent.
pub fn write_pointer(
    state_dir: &Path,
    number: u64,
    repo: &str,
    highlights: Option<&str>,
) -> Result<(), String> {
    validate_repo_slug(repo)?;

    std::fs::create_dir_all(state_dir).map_err(|e| format!("io_error: {e}"))?;

    let pointer = json!({
        "number": number,
        "repo": repo,
        "highlights": highlights,
    });
    let text =
        serde_json::to_string_pretty(&pointer).map_err(|e| format!("serialization_failed: {e}"))?;

    let json_path = state_dir.join("current-pr.json");
    std::fs::write(&json_path, text.as_bytes()).map_err(|e| format!("io_error: {e}"))?;

    touch_current_pr_dirty(state_dir)
}

/// Remove `current-pr.json` (a no-op when it doesn't exist) and touch
/// `current-pr.dirty` so the watcher picks up the cleared state.
pub fn clear_pointer(state_dir: &Path) -> Result<(), String> {
    let json_path = state_dir.join("current-pr.json");
    if json_path.exists() {
        std::fs::remove_file(&json_path).map_err(|e| format!("io_error: {e}"))?;
    }
    touch_current_pr_dirty(state_dir)
}

/// Touch `current-pr.dirty` to wake `PerriPrNativeSource`'s watcher.
fn touch_current_pr_dirty(state_dir: &Path) -> Result<(), String> {
    std::fs::create_dir_all(state_dir).map_err(|e| format!("io_error: {e}"))?;
    let dirty_path = state_dir.join("current-pr.dirty");
    std::fs::write(&dirty_path, b"").map_err(|e| format!("io_error: {e}"))
}

/// Touch `queue.dirty` to wake `PerriQueueNativeSource`'s watcher.
pub fn touch_queue_dirty(state_dir: &Path) -> Result<(), String> {
    std::fs::create_dir_all(state_dir).map_err(|e| format!("io_error: {e}"))?;
    let dirty_path = state_dir.join("queue.dirty");
    std::fs::write(&dirty_path, b"").map_err(|e| format!("io_error: {e}"))
}

// ── tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::data::perri_pr_native::CurrentPrPointer;
    use tempfile::TempDir;

    #[test]
    fn write_pointer_produces_current_pr_pointer_compatible_json() {
        let dir = TempDir::new().unwrap();
        write_pointer(dir.path(), 42, "acme/widget", Some("check auth")).unwrap();

        let content = std::fs::read_to_string(dir.path().join("current-pr.json")).unwrap();
        let pointer: CurrentPrPointer =
            serde_json::from_str(&content).expect("must deserialize as CurrentPrPointer");
        assert_eq!(pointer.number, 42);
        assert_eq!(pointer.repo, "acme/widget");
    }

    #[test]
    fn write_pointer_without_highlights_writes_null() {
        let dir = TempDir::new().unwrap();
        write_pointer(dir.path(), 7, "acme/anvil", None).unwrap();

        let content = std::fs::read_to_string(dir.path().join("current-pr.json")).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&content).unwrap();
        assert!(parsed["highlights"].is_null());
    }

    #[test]
    fn write_pointer_touches_dirty_sentinel() {
        let dir = TempDir::new().unwrap();
        write_pointer(dir.path(), 1, "acme/widget", None).unwrap();
        assert!(dir.path().join("current-pr.dirty").exists());
    }

    #[test]
    fn clear_pointer_on_missing_file_is_a_noop() {
        let dir = TempDir::new().unwrap();
        // No current-pr.json exists yet.
        clear_pointer(dir.path()).expect("clearing an absent pointer must not error");
        assert!(dir.path().join("current-pr.dirty").exists());
    }

    #[test]
    fn clear_pointer_removes_existing_file_and_touches_dirty() {
        let dir = TempDir::new().unwrap();
        write_pointer(dir.path(), 5, "acme/foo", None).unwrap();
        assert!(dir.path().join("current-pr.json").exists());

        clear_pointer(dir.path()).unwrap();
        assert!(!dir.path().join("current-pr.json").exists());
        assert!(dir.path().join("current-pr.dirty").exists());
    }

    #[test]
    fn touch_queue_dirty_creates_sentinel() {
        let dir = TempDir::new().unwrap();
        touch_queue_dirty(dir.path()).unwrap();
        assert!(dir.path().join("queue.dirty").exists());
    }

    #[test]
    fn validate_repo_slug_accepts_well_formed_slugs() {
        assert!(validate_repo_slug("acme/widget").is_ok());
        assert!(validate_repo_slug("acme-corp/widget.rs_v2").is_ok());
    }

    #[test]
    fn validate_repo_slug_rejects_missing_slash() {
        assert!(validate_repo_slug("acmewidget").is_err());
    }

    #[test]
    fn validate_repo_slug_rejects_extra_slash() {
        assert!(validate_repo_slug("acme/widget/extra").is_err());
    }

    #[test]
    fn validate_repo_slug_rejects_empty_halves() {
        assert!(validate_repo_slug("/widget").is_err());
        assert!(validate_repo_slug("acme/").is_err());
        assert!(validate_repo_slug("/").is_err());
        assert!(validate_repo_slug("").is_err());
    }

    #[test]
    fn validate_repo_slug_rejects_unsafe_characters() {
        assert!(validate_repo_slug("org/repo;rm -rf /").is_err());
        assert!(validate_repo_slug("org/repo whitespace").is_err());
    }

    #[test]
    fn write_pointer_rejects_unsafe_repo_and_writes_no_file() {
        let dir = TempDir::new().unwrap();
        let result = write_pointer(dir.path(), 1, "org/repo;rm -rf /", None);
        assert!(result.is_err());
        assert!(!dir.path().join("current-pr.json").exists());
    }
}
