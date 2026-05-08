//! Top-level application: view registry, global event loop, tick scheduling.

use std::sync::Arc;

use anyhow::Result;
use crossterm::event::{KeyCode, KeyModifiers};
use ratatui::{backend::CrosstermBackend, Terminal};
use tokio::sync::mpsc;
use tracing::{debug, info};

use crate::{
    ViewArg,
    agent_bus::AgentBus,
    config::Config,
    data::{fred_calendar::FredCalendarSource, fred_mailbox::FredMailboxSource,
           perri_pr::PerriPrSource, perri_queue::PerriQueueSource},
    event::{self, AppEvent},
    ui,
    ui::widgets::syntect_cache::SyntectCache,
    views::{self, BoxedView, ViewCtx},
};

/// Run the application until the user quits.
#[tokio::main]
pub async fn run(
    initial_view: ViewArg,
    config: Config,
    terminal: &mut Terminal<CrosstermBackend<std::io::Stdout>>,
    syntect: Arc<SyntectCache>,
    bus: Arc<AgentBus>,
) -> Result<()> {
    let mailbox_rx = FredMailboxSource::spawn(config.clone());
    let calendar_rx = FredCalendarSource::spawn(config.clone());
    let queue_rx = PerriQueueSource::spawn(config.clone());
    let pr_rx = PerriPrSource::spawn(config.clone());

    // Create the event channel before views so they can send AgentUpdate.
    let (tx, mut rx) = mpsc::unbounded_channel::<AppEvent>();
    event::spawn(tx.clone());

    let fred_ctx = ViewCtx { event_tx: tx.clone() };
    let perri_ctx = ViewCtx { event_tx: tx.clone() };

    let mut views: Vec<BoxedView> = vec![
        Box::new(views::fred::FredView::new(mailbox_rx, calendar_rx, config.clone(), fred_ctx)),
        Box::new(views::perri::PerriView::new(queue_rx, pr_rx, config.clone(), perri_ctx, Arc::clone(&syntect))),
        Box::new(views::agent_generic::GenericView::new("claudia", "Claudia", ViewCtx { event_tx: tx.clone() })),
        Box::new(views::agent_generic::GenericView::new("cody",    "Cody",    ViewCtx { event_tx: tx.clone() })),
        Box::new(views::agent_generic::GenericView::new("kennedy", "Kennedy", ViewCtx { event_tx: tx.clone() })),
        Box::new(views::agent_generic::GenericView::new("mother",  "Mother",  ViewCtx { event_tx: tx.clone() })),
    ];

    let mut active: usize = match initial_view {
        ViewArg::Fred => 0,
        ViewArg::Perri => 1,
        ViewArg::All => 0,
    };

    info!("event loop starting");

    loop {
        // Collect titles before the mutable borrow of views[active].
        let titles: Vec<String> = views.iter().map(|v| v.title().to_string()).collect();
        let title_refs: Vec<&str> = titles.iter().map(|s| s.as_str()).collect();

        // Snapshot recent bus events for the status bar.
        let recent = bus.recent_snapshot();

        {
            let v = &mut views[active];
            terminal.draw(|f| {
                ui::render(f, &mut **v, active, &title_refs, recent.as_slice());
            })?;
        }

        let ev = match rx.recv().await {
            Some(e) => e,
            None => break,
        };

        debug!(?ev, "event");

        // Resize: propagate to the active view.
        if let AppEvent::Resize(cols, rows) = &ev {
            terminal.resize(ratatui::layout::Rect::new(0, 0, *cols, *rows))?;
            let area = ratatui::layout::Rect::new(0, 0, *cols, *rows);
            views[active].on_resize(area);
            continue;
        }

        // AgentUpdate: just redraw — already handled by the loop top.
        if matches!(ev, AppEvent::AgentUpdate { .. }) {
            continue;
        }

        match &ev {
            AppEvent::Key(k) => {
                // Global: always quit on Ctrl-C.
                if k.code == KeyCode::Char('c') && k.modifiers.contains(KeyModifiers::CONTROL) {
                    break;
                }

                // Global tab switching (unless PTY focused — tabs pass through to PTY).
                if !views[active].pty_focus() {
                    match k.code {
                        KeyCode::Char('q') => break,

                        KeyCode::Tab => {
                            active = (active + 1) % views.len();
                            continue;
                        }
                        KeyCode::BackTab => {
                            active = active.checked_sub(1).unwrap_or(views.len() - 1);
                            continue;
                        }
                        _ => {}
                    }
                }

                // Dispatch key to the active view.
                views[active].on_event(&ev);
            }

            AppEvent::Mouse(m) => {
                use crossterm::event::MouseEventKind;
                if matches!(m.kind, MouseEventKind::Down(_)) && m.row == 0 {
                    let idx = (m.column as usize) / 12;
                    if idx < views.len() {
                        active = idx;
                    }
                }
            }

            AppEvent::Tick => {
                views[active].on_tick();
            }

            _ => {
                views[active].on_event(&ev);
            }
        }
    }

    info!("event loop exiting");
    Ok(())
}
