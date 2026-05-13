//! Golden snapshot tests for the Perri view layout.

use std::sync::Arc;

use ratatui::{backend::TestBackend, Terminal};

use nostromo::views::View;
use nostromo::{
    data::{
        perri_pr::PrSnapshot,
        perri_queue::{PrQueueItem, PrQueueSnapshot},
    },
    ui::widgets::syntect_cache::SyntectCache,
};

fn fake_queue() -> PrQueueSnapshot {
    PrQueueSnapshot {
        generated_at: None,
        items: vec![
            PrQueueItem {
                repo: "acme/web-app".into(),
                number: 42,
                title: "feat: add user authentication".into(),
                author: "cody".into(),
                bucket: "requested".to_owned(),
                new_activity: false,
                url: "https://github.com/acme/web-app/pull/42".into(),
            },
            PrQueueItem {
                repo: "acme/api".into(),
                number: 892,
                title: "fix: cache invalidation bug".into(),
                author: "marty".into(),
                bucket: "needs_review".to_owned(),
                new_activity: false,
                url: "https://github.com/acme/api/pull/17".into(),
            },
        ],
        stale: false,
        error: None,
    }
}

fn fake_pr() -> PrSnapshot {
    PrSnapshot {
        pr_number: Some(42),
        repo: "acme/web-app".into(),
        title: "feat: add user authentication".into(),
        author: "cody".into(),
        url: "https://github.com/acme/web-app/pull/42".into(),
        diff:
            "+++ b/src/auth/login.rs\n@@ -0,0 +1,10 @@\n+pub fn authenticate(token: &str) -> bool {"
                .into(),
        stale: false,
        error: None,
    }
}

#[test]
fn perri_layout_renders_without_panic() {
    use nostromo::views::perri::PerriView;
    use nostromo::views::ViewCtx;
    use ratatui::layout::Rect;
    use tokio::sync::{mpsc, watch};

    let (q_tx, q_rx) = watch::channel(Some(fake_queue()));
    let (pr_tx, pr_rx) = watch::channel(Some(fake_pr()));
    drop(q_tx);
    drop(pr_tx);

    let config = nostromo::config::Config::default();
    use nostromo::pty::InProcessPtyFactory;
    let (event_tx, _event_rx) = mpsc::unbounded_channel();
    let ctx = ViewCtx {
        event_tx,
        pty_factory: Arc::new(InProcessPtyFactory),
    };
    let syntect = Arc::new(SyntectCache::load().expect("syntect load"));
    let mut view = PerriView::new(q_rx, pr_rx, config, ctx, syntect);

    let backend = TestBackend::new(160, 50);
    let mut terminal = Terminal::new(backend).unwrap();

    terminal
        .draw(|f| {
            view.render(f, Rect::new(0, 0, 160, 50));
        })
        .unwrap();

    let buffer = terminal.backend().buffer().clone();
    let mut lines: Vec<String> = Vec::new();
    for y in 0..buffer.area.height.min(10) {
        let row: String = (0..buffer.area.width)
            .map(|x| {
                buffer
                    .cell((x, y))
                    .map(|c| c.symbol().chars().next().unwrap_or(' '))
                    .unwrap_or(' ')
            })
            .collect();
        lines.push(row.trim_end().to_string());
    }
    let snapshot = lines.join("\n");

    insta::assert_snapshot!("perri_layout_first_10_rows", snapshot);
}
