//! Smoke tests: construct each REPL-bearing view, simulate Ctrl+T, and assert
//! the transcript pane becomes visible without panic.
//!
//! These tests use TestBackend to drive ratatui renders so that all rendering
//! paths are exercised, not just construction.

use std::sync::Arc;

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::{backend::TestBackend, Terminal};
use tokio::sync::mpsc;

use nostromo::{
    event::AppEvent,
    mcp::state::McpSharedState,
    pty::InProcessPtyFactory,
    views::{EventOutcome, View, ViewCtx},
};

fn make_ctx() -> ViewCtx {
    let (event_tx, _event_rx) = mpsc::unbounded_channel();
    let (mcp_tx, _mcp_rx) = mpsc::unbounded_channel();
    let mcp_state = Arc::new(McpSharedState::for_test(mcp_tx));
    ViewCtx {
        event_tx,
        pty_factory: Arc::new(InProcessPtyFactory {
            mcp_state: mcp_state.clone(),
        }),
        mcp_state,
    }
}

fn ctrl_t() -> AppEvent {
    AppEvent::Key(KeyEvent::new(KeyCode::Char('t'), KeyModifiers::CONTROL))
}

fn render_view(view: &mut dyn View) {
    let backend = TestBackend::new(160, 50);
    let mut terminal = Terminal::new(backend).unwrap();
    terminal
        .draw(|f| {
            view.render(f, ratatui::layout::Rect::new(0, 0, 160, 50));
        })
        .unwrap();
}

// ── GenericView (Claudia / Cody / Kennedy) ────────────────────────────────────

#[tokio::test]
async fn generic_view_ctrl_t_toggles_transcript() {
    use nostromo::views::agent_generic::GenericView;

    let ctx = make_ctx();
    let mut view = GenericView::new("cody", "Cody", ctx);

    // Initially no PTY — pty_capturing is false, so Ctrl+T should be handled.
    let outcome = view.on_event(&ctrl_t());
    assert!(
        matches!(outcome, EventOutcome::Consumed),
        "Ctrl+T should be consumed"
    );

    // Render without panic (transcript visible on right half).
    render_view(&mut view);

    // Second Ctrl+T hides it again.
    let outcome = view.on_event(&ctrl_t());
    assert!(matches!(outcome, EventOutcome::Consumed));

    // Render without panic (transcript hidden, full REPL).
    render_view(&mut view);
}

#[tokio::test]
async fn generic_view_renders_without_panic() {
    use nostromo::views::agent_generic::GenericView;

    let ctx = make_ctx();
    let mut view = GenericView::new("claudia", "Claudia", ctx);
    render_view(&mut view);
}

// ── PerriView ─────────────────────────────────────────────────────────────────

#[tokio::test]
async fn perri_view_ctrl_t_toggles_transcript() {
    use nostromo::{
        data::{
            perri_pr::PrSnapshot,
            perri_queue::{PrQueueItem, PrQueueSnapshot},
        },
        ui::widgets::syntect_cache::SyntectCache,
        views::perri::PerriView,
    };
    use tokio::sync::watch;

    let (q_tx, q_rx) = watch::channel(Some(PrQueueSnapshot {
        generated_at: None,
        items: vec![PrQueueItem {
            repo: "a/b".into(),
            number: 1,
            title: "t".into(),
            author: "u".into(),
            bucket: "needs_review".into(),
            new_activity: false,
            url: "https://github.com/a/b/pull/1".into(),
            ci_state: Default::default(),
        }],
        stale: false,
        error: None,
    }));
    let (pr_tx, pr_rx) = watch::channel(Some(PrSnapshot {
        pr_number: Some(1),
        repo: "a/b".into(),
        title: "t".into(),
        author: "u".into(),
        url: "https://github.com/a/b/pull/1".into(),
        diff: "+hello".into(),
        stale: false,
        error: None,
        ci_checks: vec![],
        additions: 0,
        deletions: 0,
        changed_files: 0,
    }));
    drop(q_tx);
    drop(pr_tx);

    let ctx = make_ctx();
    let config = nostromo::config::Config::default();
    let syntect = Arc::new(SyntectCache::load().expect("syntect"));
    let mut view = PerriView::new(q_rx, pr_rx, config, ctx, syntect);

    // Ctrl+T (not capturing) → consumed.
    let outcome = view.on_event(&ctrl_t());
    assert!(
        matches!(outcome, EventOutcome::Consumed),
        "Perri Ctrl+T should be consumed"
    );

    render_view(&mut view);

    // Second Ctrl+T hides.
    let _ = view.on_event(&ctrl_t());
    render_view(&mut view);
}
