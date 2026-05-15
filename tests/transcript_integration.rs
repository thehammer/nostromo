//! Integration tests for `TranscriptPane` — bring-up, visibility toggle,
//! and key-handling without a full view context.

use std::io::Write;
use std::time::Duration;

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use nostromo::transcript::TranscriptPane;
use tempfile::tempdir;

/// Build a minimal JSONL user-message record for a given session id.
fn user_line(sid: &str) -> String {
    format!(
        r#"{{"parentUuid":null,"isSidechain":false,"type":"user","message":{{"role":"user","content":"hello"}},"uuid":"u-001","timestamp":"2026-05-14T10:00:00.000Z","sessionId":"{sid}"}}"#
    )
}

/// Ensure the reader file exists under the path TranscriptReader expects.
///
/// The reader uses `$HOME/.claude/projects/<sanitized_cwd>/<sid>.jsonl`.
/// We override HOME to point at our tempdir.
fn write_session_file(home: &std::path::Path, cwd: &std::path::Path, sid: &str) {
    let sanitized = cwd.to_string_lossy().replace('/', "-");
    let project_dir = home
        .join(".claude")
        .join("projects")
        .join(&sanitized);
    std::fs::create_dir_all(&project_dir).unwrap();
    let log_path = project_dir.join(format!("{sid}.jsonl"));
    let mut f = std::fs::File::create(&log_path).unwrap();
    writeln!(f, "{}", user_line(sid)).unwrap();
    f.flush().unwrap();
}

// ── toggle_visible ─────────────────────────────────────────────────────────────

#[test]
fn pane_starts_invisible() {
    let pane = TranscriptPane::new();
    assert!(!pane.is_visible());
}

#[tokio::test]
async fn toggle_visible_makes_pane_visible() {
    let dir = tempdir().unwrap();
    std::env::set_var("HOME", dir.path());
    let sid = "test-toggle-sid";
    write_session_file(dir.path(), dir.path(), sid);

    let mut pane = TranscriptPane::new();
    pane.set_session_context(dir.path().to_path_buf(), sid.to_string());
    pane.toggle_visible();

    assert!(pane.is_visible());
}

#[tokio::test]
async fn toggle_visible_twice_hides_again() {
    let dir = tempdir().unwrap();
    std::env::set_var("HOME", dir.path());
    let sid = "test-toggle2-sid";
    write_session_file(dir.path(), dir.path(), sid);

    let mut pane = TranscriptPane::new();
    pane.set_session_context(dir.path().to_path_buf(), sid.to_string());
    pane.toggle_visible();
    assert!(pane.is_visible());
    pane.toggle_visible();
    assert!(!pane.is_visible());
}

// ── key handling ──────────────────────────────────────────────────────────────

fn key(code: KeyCode) -> KeyEvent {
    KeyEvent::new(code, KeyModifiers::NONE)
}

/// Navigation keys (j, k, g, G, Enter) should be consumed by `on_key`.
#[test]
fn on_key_nav_keys_consumed() {
    let mut pane = TranscriptPane::new();
    // Even with no snapshot loaded, nav keys should return true (consumed).
    for code in [
        KeyCode::Char('j'),
        KeyCode::Char('k'),
        KeyCode::Char('g'),
        KeyCode::Char('G'),
        KeyCode::Enter,
        KeyCode::PageUp,
        KeyCode::PageDown,
    ] {
        assert!(pane.on_key(&key(code)), "expected {code:?} to be consumed");
    }
}

/// Non-nav keys (e.g., 'a') should NOT be consumed.
#[test]
fn on_key_non_nav_not_consumed() {
    let mut pane = TranscriptPane::new();
    assert!(!pane.on_key(&key(KeyCode::Char('a'))));
    assert!(!pane.on_key(&key(KeyCode::Char('q'))));
    assert!(!pane.on_key(&key(KeyCode::Esc)));
}

// ── bring_up is idempotent ────────────────────────────────────────────────────

#[test]
fn bring_up_without_session_context_is_safe() {
    let mut pane = TranscriptPane::new();
    // Should not panic even with no session context set.
    pane.bring_up();
    assert!(!pane.is_visible());
}

// ── live tail integration ─────────────────────────────────────────────────────

#[tokio::test]
async fn pane_bring_up_with_live_file_starts_reader() {
    let dir = tempdir().unwrap();
    std::env::set_var("HOME", dir.path());
    let sid = "test-live-sid";
    write_session_file(dir.path(), dir.path(), sid);

    let mut pane = TranscriptPane::new();
    pane.set_session_context(dir.path().to_path_buf(), sid.to_string());
    pane.toggle_visible();

    assert!(pane.is_visible());

    // Give the reader a moment to start up and read the file.
    tokio::time::sleep(Duration::from_millis(200)).await;

    // The pane should have a reader running (visible and reader started).
    // We can't directly inspect the reader, but we can confirm no panic occurred
    // and the pane is still visible.
    assert!(pane.is_visible());
}
