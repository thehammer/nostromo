//! A user who never set Teri up (no `~/.teri/teri.db`) must see Teri's calm
//! empty state, not an error banner that leaks their home directory.
//!
//! Lives in `tests/` (not a `#[cfg(test)]` block in `src/views/teri.rs`) so it
//! owns its process: `TeriView::new` reads `~/.nostromo/sessions.toml` and may
//! auto-spawn a PTY from it, so the test points `HOME` at an empty tempdir
//! first, which no other test in this binary can race.

use std::sync::Arc;

use nostromo::data::teri_todos::TeriTodosSnapshot;
use nostromo::mcp::McpSharedState;
use nostromo::pty::InProcessPtyFactory;
use nostromo::views::teri::TeriView;
use nostromo::views::{View, ViewCtx};
use ratatui::{backend::TestBackend, layout::Rect, Terminal};
use serde_json::json;
use tokio::sync::{mpsc, watch};

/// Render the Teri view at 120x40 and return the whole buffer as text.
fn render(snapshot: TeriTodosSnapshot, home: &std::path::Path) -> String {
    std::env::set_var("HOME", home);
    let (_tx, rx) = watch::channel(Some(snapshot));
    let (event_tx, _event_rx) = mpsc::unbounded_channel();
    let (mcp_tx, _mcp_rx) = mpsc::unbounded_channel();
    let mcp_state = Arc::new(McpSharedState::for_test(mcp_tx));
    let ctx = ViewCtx {
        event_tx,
        pty_factory: Arc::new(InProcessPtyFactory::new(Arc::clone(&mcp_state))),
        mcp_state,
    };
    let mut view = TeriView::new(rx, ctx);

    let mut terminal = Terminal::new(TestBackend::new(120, 40)).unwrap();
    terminal
        .draw(|f| view.render(f, Rect::new(0, 0, 120, 40)))
        .unwrap();
    let buf = terminal.backend().buffer().clone();
    (0..buf.area.height)
        .map(|y| {
            (0..buf.area.width)
                .map(|x| buf.cell((x, y)).map(|c| c.symbol().to_string()).unwrap_or_default())
                .collect::<String>()
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn snapshot(error: Option<&str>) -> TeriTodosSnapshot {
    serde_json::from_value(json!({
        "generated_at": "2026-10-09T15:00:00Z",
        "items": [], "stale": false, "error": error, "not_configured": true,
    }))
    .unwrap()
}

fn assert_calm_empty_state(text: &str, home: &std::path::Path) {
    assert!(text.contains("No active todos"), "expected the empty state:\n{text}");
    assert!(!text.contains('⚠'), "no warning banner:\n{text}");
    assert!(!text.to_lowercase().contains("database"), "no database talk:\n{text}");
    assert!(!text.contains('/'), "no path characters:\n{text}");
    assert!(!text.contains(home.to_string_lossy().as_ref()), "no HOME path:\n{text}");
}

// One test, two renders: `HOME` is process-global.
#[tokio::test]
async fn a_user_without_a_teri_database_sees_the_empty_state_not_an_error_banner() {
    let home = tempfile::tempdir().unwrap();

    // What the source publishes for a missing db.
    let text = render(snapshot(None), home.path());
    assert_calm_empty_state(&text, home.path());

    // `not_configured` wins even if an older source also attached a message
    // (the pre-fix source reported "Teri database not found at <path>").
    let legacy = format!("Teri database not found at {}/.teri/teri.db", home.path().display());
    let text = render(snapshot(Some(&legacy)), home.path());
    assert_calm_empty_state(&text, home.path());
}
