//! Golden snapshot tests for the Fred view layout.
//!
//! Uses `insta` to capture rendered widget output.  Run with:
//!   cargo test snapshot_fred -- --nocapture
//!
//! To update snapshots after an intentional layout change:
//!   cargo insta review   (or: INSTA_UPDATE=always cargo test)

use ratatui::{backend::TestBackend, Terminal};

use nostromo::views::View;
use nostromo::{
    data::{
        fred_calendar::{CalendarEvent, CalendarSnapshot, NextEvent},
        fred_mailbox::{MailboxItem, MailboxSnapshot},
    },
};

/// Build a minimal Fred mailbox snapshot for testing.
fn fake_mailbox() -> MailboxSnapshot {
    MailboxSnapshot {
        generated_at: None,
        unread_count: 2,
        items: vec![
            MailboxItem {
                from: "Alice Smith".into(),
                subject: "Weekly sync".into(),
                received_at: None,
                vip: false,
                is_invite: false,
                is_read: false,
            },
            MailboxItem {
                from: "Bob Jones".into(),
                subject: "Re: Q2 planning".into(),
                received_at: None,
                vip: true,
                is_invite: false,
                is_read: true,
            },
        ],
        stale: false,
        error: None,
        auth_prompt: None,
    }
}

/// Build a minimal Fred calendar snapshot for testing.
fn fake_calendar() -> CalendarSnapshot {
    CalendarSnapshot {
        events: vec![CalendarEvent {
            start: None,
            end: None,
            title: "Weekly sync".into(),
            status: "accepted".into(),
            is_now: true,
        }],
        next: Some(NextEvent {
            title: "1:1 with manager".into(),
            in_minutes: 45,
        }),
        sweater: "sage".into(),
        stale: false,
        error: None,
    }
}

#[test]
fn fred_layout_renders_without_panic() {
    // Verify the Fred layout renders without crashing at 120x40.
    // Snapshot the rendered buffer.
    use nostromo::views::fred::FredView;
    use nostromo::views::ViewCtx;
    use tokio::sync::{mpsc, watch};
    use ratatui::layout::Rect;

    let (mb_tx, mb_rx) = watch::channel(Some(fake_mailbox()));
    let (cal_tx, cal_rx) = watch::channel(Some(fake_calendar()));
    drop(mb_tx);
    drop(cal_tx);

    let config = nostromo::config::Config::default();
    let (event_tx, _event_rx) = mpsc::unbounded_channel();
    let ctx = ViewCtx { event_tx };
    let mut view = FredView::new(mb_rx, cal_rx, config, ctx);

    let backend = TestBackend::new(120, 40);
    let mut terminal = Terminal::new(backend).unwrap();

    terminal
        .draw(|f| {
            view.render(f, Rect::new(0, 0, 120, 40));
        })
        .unwrap();

    let buffer = terminal.backend().buffer().clone();
    // Build a simple text snapshot of the buffer's first few rows
    let mut lines: Vec<String> = Vec::new();
    for y in 0..buffer.area.height.min(10) {
        let row: String = (0..buffer.area.width)
            .map(|x| buffer.cell((x, y)).map(|c| c.symbol().chars().next().unwrap_or(' ')).unwrap_or(' '))
            .collect();
        lines.push(row.trim_end().to_string());
    }
    let snapshot = lines.join("\n");

    insta::assert_snapshot!("fred_layout_first_10_rows", snapshot);
}
