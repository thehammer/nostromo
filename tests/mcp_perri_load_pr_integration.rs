//! Integration test for `perri.load_pr` via `PerriView::load_pr`.
//!
//! Verifies that calling `load_pr` on a `PerriView`:
//! 1. Writes `current-pr.json` with the correct shape accepted by
//!    `PerriPrNativeSource`.
//! 2. Writes (or touches) `current-pr.dirty` to wake the watcher.
//!
//! Uses a `tempfile::TempDir` for the perri state dir so we don't touch
//! the real `~/.claude/state/perri`.

use std::sync::Arc;

use nostromo::{
    config::Config,
    data::perri_current_pr::{pin_path, BUILTIN_PERRI_TAG},
    data::perri_pr::no_prs,
    mcp::McpSharedState,
    views::perri::PerriView,
};
use tempfile::TempDir;
use tokio::sync::{mpsc, watch};

// ── helpers ───────────────────────────────────────────────────────────────────

/// Build a `PerriView` wired to a temp state dir.
fn make_perri_view(state_dir: &std::path::Path) -> PerriView {
    let (event_tx, _rx) = mpsc::unbounded_channel();
    let mcp_state = Arc::new(McpSharedState::for_test(event_tx.clone()));
    let pty_factory = Arc::new(nostromo::pty::InProcessPtyFactory::new(mcp_state.clone()));

    let ctx = nostromo::views::ViewCtx {
        event_tx,
        pty_factory,
        mcp_state,
    };

    let config = Config {
        perri_state: Some(state_dir.to_owned()),
        ..Config::default()
    };

    let (queue_tx, queue_rx) = watch::channel(None);
    let (pr_tx, pr_rx) = watch::channel(no_prs());
    drop(queue_tx);
    drop(pr_tx);

    let syntect = Arc::new(
        nostromo::ui::widgets::syntect_cache::SyntectCache::load().expect("syntect should load"),
    );

    PerriView::new(queue_rx, pr_rx, config, ctx, syntect)
}

/// Where the TUI's pin lives: it is a single-surface host and writes the
/// built-in Perri focus's pin (W7 — D1/D10).
fn pin_file(state_dir: &std::path::Path) -> std::path::PathBuf {
    pin_path(state_dir, BUILTIN_PERRI_TAG).expect("BUILTIN_PERRI_TAG is a valid tag")
}

// ── tests ─────────────────────────────────────────────────────────────────────

/// load_pr writes current-pr.json with the correct shape.
#[test]
fn load_pr_writes_json_file() {
    let dir = TempDir::new().unwrap();
    let mut view = make_perri_view(dir.path());

    view.load_pr(
        42,
        "thehammer/nostromo".to_string(),
        Some("check auth".to_string()),
    )
    .unwrap();

    let json_path = pin_file(dir.path());
    assert!(json_path.exists(), "current-pr.json should be written");

    let content = std::fs::read_to_string(&json_path).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&content).unwrap();

    assert_eq!(parsed["number"], 42u64);
    assert_eq!(parsed["repo"], "thehammer/nostromo");
    assert_eq!(parsed["highlights"], "check auth");
}

/// load_pr touches the dirty sentinel to wake the watcher.
#[test]
fn load_pr_touches_dirty_sentinel() {
    let dir = TempDir::new().unwrap();
    let mut view = make_perri_view(dir.path());

    view.load_pr(7, "acme/anvil".to_string(), None).unwrap();

    let dirty_path = dir.path().join("current-pr.dirty");
    assert!(dirty_path.exists(), "current-pr.dirty should be written");
}

/// load_pr without highlights writes null for the field.
#[test]
fn load_pr_no_highlights_writes_null() {
    let dir = TempDir::new().unwrap();
    let mut view = make_perri_view(dir.path());

    view.load_pr(1, "acme/widget".to_string(), None).unwrap();

    let json_path = pin_file(dir.path());
    let content = std::fs::read_to_string(&json_path).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&content).unwrap();

    assert!(
        parsed["highlights"].is_null(),
        "highlights should be null when not provided"
    );
    assert_eq!(parsed["repo"], "acme/widget");
}

/// clear_current_pr removes current-pr.json and touches the dirty sentinel.
#[test]
fn clear_current_pr_removes_file_and_touches_dirty() {
    let dir = TempDir::new().unwrap();
    let mut view = make_perri_view(dir.path());

    // First write a PR record.
    view.load_pr(5, "acme/foo".to_string(), None).unwrap();
    assert!(pin_file(dir.path()).exists());

    // Then clear it.
    view.clear_current_pr().unwrap();

    assert!(!pin_file(dir.path()).exists(), "json should be removed");
    assert!(
        dir.path().join("current-pr.dirty").exists(),
        "dirty should still exist"
    );
}

/// clear_current_pr is a no-op when current-pr.json doesn't exist.
#[test]
fn clear_current_pr_noop_when_no_file() {
    let dir = TempDir::new().unwrap();
    let mut view = make_perri_view(dir.path());

    // Should not error even when the file doesn't exist.
    view.clear_current_pr().unwrap();
}

/// The current-pr.json shape is accepted by serde as a CurrentPrPointer.
///
/// This round-trips through the type used by PerriPrNativeSource.
#[test]
fn load_pr_json_shape_matches_current_pr_pointer() {
    use serde::Deserialize;

    #[derive(Deserialize)]
    struct CurrentPrPointer {
        pub number: u64,
        pub repo: String,
    }

    let dir = TempDir::new().unwrap();
    let mut view = make_perri_view(dir.path());

    view.load_pr(100, "owner/repo".to_string(), None).unwrap();

    let content = std::fs::read_to_string(pin_file(dir.path())).unwrap();
    let pointer: CurrentPrPointer = serde_json::from_str(&content)
        .expect("current-pr.json must deserialize as CurrentPrPointer");

    assert_eq!(pointer.number, 100);
    assert_eq!(pointer.repo, "owner/repo");
}

// ── W7: the TUI is one surface, and writes exactly one focus's pin ───────────

/// `PerriView` is a single-surface host with no focus registry, so it writes
/// under the built-in `perri` focus (W7 — D1/D10). What must never happen is
/// that being *implemented* as "write the one current-PR file": the store is
/// sharded now, and a pickup on this host has to leave every other focus's
/// review exactly where it was.
#[test]
fn the_tui_s_pickup_writes_only_the_builtin_perri_pin_and_leaves_other_focuses_alone() {
    use nostromo::data::perri_current_pr::{pin_path, write_pointer};

    let dir = TempDir::new().unwrap();
    // Two focuses that exist only in the daemon's store — the TUI has never
    // heard of them, and must not be able to touch them.
    write_pointer(dir.path(), "operations", 42, "Carefeed/operations", None).unwrap();
    write_pointer(
        dir.path(),
        "cody",
        7,
        "Carefeed/admin-portal",
        Some("keep me"),
    )
    .unwrap();
    let others: Vec<(String, Vec<u8>)> = ["operations", "cody"]
        .iter()
        .map(|tag| {
            let path = pin_path(dir.path(), tag).unwrap();
            ((*tag).to_owned(), std::fs::read(path).unwrap())
        })
        .collect();

    let mut view = make_perri_view(dir.path());
    view.load_pr(4526, "Carefeed/admin-portal".to_string(), None)
        .unwrap();

    assert!(
        pin_file(dir.path()).exists(),
        "the TUI's own surface is the built-in perri focus"
    );
    for (tag, before) in &others {
        assert_eq!(
            std::fs::read(pin_path(dir.path(), tag).unwrap())
                .ok()
                .as_ref(),
            Some(before),
            "focus {tag}'s pin must be byte-identical after a TUI pickup"
        );
    }

    // And the same for a clear, which used to be "delete the current-PR file".
    view.clear_current_pr().unwrap();
    assert!(!pin_file(dir.path()).exists());
    for (tag, before) in &others {
        assert_eq!(
            std::fs::read(pin_path(dir.path(), tag).unwrap())
                .ok()
                .as_ref(),
            Some(before),
            "focus {tag}'s pin must survive a TUI clear too"
        );
    }
}
