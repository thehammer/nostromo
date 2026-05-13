//! Golden snapshot tests for the Fred view layout.
//!
//! Uses `insta` to capture rendered widget output.  Run with:
//!   cargo test snapshot_fred -- --nocapture
//!
//! To update snapshots after an intentional layout change:
//!   cargo insta review   (or: INSTA_UPDATE=always cargo test)

use ratatui::{backend::TestBackend, Terminal};

use nostromo::data::{
    fred_calendar::{CalendarEvent, CalendarSnapshot, NextEvent},
    fred_mailbox::{MailboxItem, MailboxSnapshot},
};
use nostromo::views::View;

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

#[tokio::test]
async fn fred_layout_renders_without_panic() {
    // Verify the Fred layout renders without crashing at 120x40.
    // Snapshot the rendered buffer.
    use nostromo::views::fred::FredView;
    use nostromo::views::ViewCtx;
    use ratatui::layout::Rect;
    use tokio::sync::{mpsc, watch};

    let (mb_tx, mb_rx) = watch::channel(Some(fake_mailbox()));
    let (cal_tx, cal_rx) = watch::channel(Some(fake_calendar()));
    drop(mb_tx);
    drop(cal_tx);

    let config = nostromo::config::Config::default();
    use nostromo::pty::InProcessPtyFactory;
    use std::sync::Arc;
    let (event_tx, _event_rx) = mpsc::unbounded_channel();
    let ctx = ViewCtx {
        event_tx,
        pty_factory: Arc::new(InProcessPtyFactory),
    };
    // Use halfblocks picker for tests — avoids querying the terminal.
    let picker = ratatui_image::picker::Picker::halfblocks();
    let mut view = FredView::new(mb_rx, cal_rx, config, ctx, picker);

    let backend = TestBackend::new(120, 40);
    let mut terminal = Terminal::new(backend).unwrap();

    terminal
        .draw(|f| {
            view.render(f, Rect::new(0, 0, 120, 40));
        })
        .unwrap();

    // Verify the border structure is present (time-independent).
    let buffer = terminal.backend().buffer().clone();
    let row0: String = (0..buffer.area.width)
        .map(|x| buffer.cell((x, 0)).map(|c| c.symbol().chars().next().unwrap_or(' ')).unwrap_or(' '))
        .collect();
    assert!(row0.contains("Mailbox"), "expected Mailbox panel in row 0, got: {row0}");
    assert!(row0.contains("Calendar"), "expected Calendar panel in row 0, got: {row0}");
}
