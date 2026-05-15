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
    let (pr_tx, pr_rx) = watch::channel(None);
    drop(queue_tx);
    drop(pr_tx);

    let syntect = Arc::new(
        nostromo::ui::widgets::syntect_cache::SyntectCache::load()
            .expect("syntect should load"),
    );

    PerriView::new(queue_rx, pr_rx, config, ctx, syntect)
}

// ── tests ─────────────────────────────────────────────────────────────────────

/// load_pr writes current-pr.json with the correct shape.
#[test]
fn load_pr_writes_json_file() {
    let dir = TempDir::new().unwrap();
    let mut view = make_perri_view(dir.path());

    view.load_pr(42, "thehammer/nostromo".to_string(), Some("check auth".to_string())).unwrap();

    let json_path = dir.path().join("current-pr.json");
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

    let json_path = dir.path().join("current-pr.json");
    let content = std::fs::read_to_string(&json_path).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&content).unwrap();

    assert!(parsed["highlights"].is_null(), "highlights should be null when not provided");
    assert_eq!(parsed["repo"], "acme/widget");
}

/// clear_current_pr removes current-pr.json and touches the dirty sentinel.
#[test]
fn clear_current_pr_removes_file_and_touches_dirty() {
    let dir = TempDir::new().unwrap();
    let mut view = make_perri_view(dir.path());

    // First write a PR record.
    view.load_pr(5, "acme/foo".to_string(), None).unwrap();
    assert!(dir.path().join("current-pr.json").exists());

    // Then clear it.
    view.clear_current_pr().unwrap();

    assert!(!dir.path().join("current-pr.json").exists(), "json should be removed");
    assert!(dir.path().join("current-pr.dirty").exists(), "dirty should still exist");
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

    let content = std::fs::read_to_string(dir.path().join("current-pr.json")).unwrap();
    let pointer: CurrentPrPointer = serde_json::from_str(&content)
        .expect("current-pr.json must deserialize as CurrentPrPointer");

    assert_eq!(pointer.number, 100);
    assert_eq!(pointer.repo, "owner/repo");
}
