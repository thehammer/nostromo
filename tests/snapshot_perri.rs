//! Golden snapshot tests for the Perri view layout.

use ratatui::{backend::TestBackend, Terminal};

use nostromo::views::View;
use nostromo::{
    data::{
        perri_pr::PrSnapshot,
        perri_queue::{PrQueueItem, PrQueueSnapshot},
    },
};

fn fake_queue() -> PrQueueSnapshot {
    PrQueueSnapshot {
        generated_at: None,
        items: vec![
            PrQueueItem {
                repo: "Carefeed/admin-portal".into(),
                number: 2340,
                title: "feat: backfill MVP referral activity feed".into(),
                author: "cody".into(),
                requested: true,
                url: "https://github.com/Carefeed/admin-portal/pull/2340".into(),
            },
            PrQueueItem {
                repo: "Carefeed/intelligence".into(),
                number: 892,
                title: "fix: streaming criteria flicker".into(),
                author: "marty".into(),
                requested: false,
                url: "https://github.com/Carefeed/intelligence/pull/892".into(),
            },
        ],
        stale: false,
        error: None,
    }
}

fn fake_pr() -> PrSnapshot {
    PrSnapshot {
        pr_number: Some(2340),
        repo: "Carefeed/admin-portal".into(),
        title: "feat: backfill MVP referral activity feed".into(),
        author: "cody".into(),
        url: "https://github.com/Carefeed/admin-portal/pull/2340".into(),
        diff: "+++ b/app/Models/ReferralActivity.php\n@@ -0,0 +1,30 @@\n+class ReferralActivity extends Model".into(),
        stale: false,
        error: None,
    }
}

#[test]
fn perri_layout_renders_without_panic() {
    use nostromo::views::perri::PerriView;
    use tokio::sync::watch;
    use ratatui::layout::Rect;

    let (q_tx, q_rx) = watch::channel(Some(fake_queue()));
    let (pr_tx, pr_rx) = watch::channel(Some(fake_pr()));
    drop(q_tx);
    drop(pr_tx);

    let config = nostromo::config::Config::default();
    let mut view = PerriView::new(q_rx, pr_rx, config);

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
            .map(|x| buffer.cell((x, y)).map(|c| c.symbol().chars().next().unwrap_or(' ')).unwrap_or(' '))
            .collect();
        lines.push(row.trim_end().to_string());
    }
    let snapshot = lines.join("\n");

    insta::assert_snapshot!("perri_layout_first_10_rows", snapshot);
}
