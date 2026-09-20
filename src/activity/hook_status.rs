//! Detects whether the `nostromo-activity-hook` producer is registered in the
//! operator's Claude Code `settings.json`.
//!
//! Read-only: this module never writes `settings.json` — that's `nostromo
//! doctor --fix`'s job (in the `bin/nostromo-doctor` Python script, since
//! `doctor` predates this wedge and lives outside this crate). This module
//! only answers "is it installed", for `ActivityHealth::hook_installed`.

use std::path::{Path, PathBuf};

/// Default path to the operator's Claude Code settings file (`~/.claude/settings.json`).
pub fn default_settings_path() -> PathBuf {
    dirs_next::home_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join(".claude")
        .join("settings.json")
}

/// The binary name a hook command must reference to count as "installed".
const HOOK_BIN_NAME: &str = "nostromo-activity-hook";

/// `true` if `settings_path` has at least one `PostToolUse` hook entry whose
/// command names [`HOOK_BIN_NAME`]. Any I/O or parse failure (missing file,
/// malformed JSON, unexpected shape) is treated as "not installed" — never
/// panics, never a false positive.
pub fn hook_installed(settings_path: &Path) -> bool {
    let Ok(bytes) = std::fs::read(settings_path) else {
        return false;
    };
    let Ok(value) = serde_json::from_slice::<serde_json::Value>(&bytes) else {
        return false;
    };
    let installed = post_tool_use_commands(&value).any(|cmd| cmd.contains(HOOK_BIN_NAME));
    installed
}

/// Every command string under `hooks.PostToolUse[*].hooks[*].command`,
/// tolerating any of the shape variations Claude Code's hook config allows
/// (a matcher-scoped list of hook entries).
fn post_tool_use_commands(settings: &serde_json::Value) -> impl Iterator<Item = &str> {
    settings
        .get("hooks")
        .and_then(|h| h.get("PostToolUse"))
        .and_then(|v| v.as_array())
        .into_iter()
        .flatten()
        .filter_map(|matcher_entry| matcher_entry.get("hooks"))
        .filter_map(|hooks| hooks.as_array())
        .flatten()
        .filter_map(|hook| hook.get("command"))
        .filter_map(|c| c.as_str())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_settings(dir: &tempfile::TempDir, json: &str) -> PathBuf {
        let path = dir.path().join("settings.json");
        std::fs::write(&path, json).unwrap();
        path
    }

    // ── 1. installed ───────────────────────────────────────────────────────────

    #[test]
    fn a_post_tool_use_entry_naming_the_hook_binary_is_detected_as_installed() {
        let dir = tempfile::tempdir().unwrap();
        let path = write_settings(
            &dir,
            r#"{
                "hooks": {
                    "PostToolUse": [
                        {
                            "matcher": "*",
                            "hooks": [
                                {"type": "command", "command": "/Users/hammer/.local/bin/nostromo-activity-hook"}
                            ]
                        }
                    ]
                }
            }"#,
        );
        assert!(hook_installed(&path));
    }

    // ── 2. not installed ───────────────────────────────────────────────────────

    #[test]
    fn a_missing_settings_file_is_not_installed() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("does-not-exist.json");
        assert!(!hook_installed(&path));
    }

    #[test]
    fn malformed_json_is_not_installed() {
        let dir = tempfile::tempdir().unwrap();
        let path = write_settings(&dir, "{not valid json");
        assert!(!hook_installed(&path));
    }

    #[test]
    fn settings_with_unrelated_hooks_only_is_not_installed() {
        let dir = tempfile::tempdir().unwrap();
        let path = write_settings(
            &dir,
            r#"{
                "hooks": {
                    "PostToolUse": [
                        {"matcher": "*", "hooks": [{"type": "command", "command": "/usr/bin/some-other-hook"}]}
                    ]
                }
            }"#,
        );
        assert!(!hook_installed(&path));
    }

    #[test]
    fn settings_with_no_hooks_key_at_all_is_not_installed() {
        let dir = tempfile::tempdir().unwrap();
        let path = write_settings(&dir, r#"{"other": "stuff"}"#);
        assert!(!hook_installed(&path));
    }
}
