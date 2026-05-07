//! Top-level application: view registry, global event loop, tick scheduling.

use std::process::Stdio;

use anyhow::Result;
use crossterm::event::{KeyCode, KeyModifiers};
use ratatui::{backend::CrosstermBackend, Terminal};
use tokio::sync::mpsc;
use tracing::{debug, info};

use crate::{
    ViewArg,
    config::Config,
    data::{fred_calendar::FredCalendarSource, fred_mailbox::FredMailboxSource,
           perri_pr::PerriPrSource, perri_queue::PerriQueueSource},
    event::{self, AppEvent},
    ui,
    views::{self, BoxedView},
};

/// Run the application until the user quits.
#[tokio::main]
pub async fn run(
    initial_view: ViewArg,
    config: Config,
    terminal: &mut Terminal<CrosstermBackend<std::io::Stdout>>,
) -> Result<()> {
    let mailbox_rx = FredMailboxSource::spawn(config.clone());
    let calendar_rx = FredCalendarSource::spawn(config.clone());
    let queue_rx = PerriQueueSource::spawn(config.clone());
    let pr_rx = PerriPrSource::spawn(config.clone());

    let mut views: Vec<BoxedView> = vec![
        Box::new(views::fred::FredView::new(mailbox_rx, calendar_rx, config.clone())),
        Box::new(views::perri::PerriView::new(queue_rx, pr_rx, config.clone())),
        Box::new(views::agent_generic::GenericView::new("claudia", "Claudia")),
        Box::new(views::agent_generic::GenericView::new("cody", "Cody")),
        Box::new(views::agent_generic::GenericView::new("kennedy", "Kennedy")),
        Box::new(views::agent_generic::GenericView::new("mother", "Mother")),
    ];

    let mut active: usize = match initial_view {
        ViewArg::Fred => 0,
        ViewArg::Perri => 1,
        ViewArg::All => 0,
    };

    let (tx, mut rx) = mpsc::unbounded_channel::<AppEvent>();
    event::spawn(tx.clone());

    info!("event loop starting");

    loop {
        // Collect titles before the mutable borrow of views[active].
        let titles: Vec<String> = views.iter().map(|v| v.title().to_string()).collect();
        let title_refs: Vec<&str> = titles.iter().map(|s| s.as_str()).collect();

        {
            let v = &mut views[active];
            terminal.draw(|f| {
                ui::render(f, &mut **v, active, &title_refs);
            })?;
        }

        let ev = match rx.recv().await {
            Some(e) => e,
            None => break,
        };

        debug!(?ev, "event");

        match &ev {
            AppEvent::Key(k) => match k.code {
                KeyCode::Char('q') => break,
                KeyCode::Char('c') if k.modifiers.contains(KeyModifiers::CONTROL) => break,

                KeyCode::Tab => {
                    active = (active + 1) % views.len();
                    continue;
                }
                KeyCode::BackTab => {
                    active = active.checked_sub(1).unwrap_or(views.len() - 1);
                    continue;
                }

                KeyCode::Enter => {
                    let agent_id = views[active].id().to_owned();
                    drop(rx);
                    launch_agent_repl(terminal, &agent_id, tx.clone()).await?;
                    let (new_tx, new_rx) = mpsc::unbounded_channel::<AppEvent>();
                    event::spawn(new_tx);
                    rx = new_rx;
                    continue;
                }

                _ => {}
            },

            AppEvent::Mouse(m) => {
                use crossterm::event::MouseEventKind;
                if matches!(m.kind, MouseEventKind::Down(_)) && m.row == 0 {
                    let idx = (m.column as usize) / 12;
                    if idx < views.len() {
                        active = idx;
                    }
                }
                continue;
            }

            AppEvent::Tick => {
                views[active].on_tick();
            }

            _ => {}
        }

        views[active].on_event(&ev);
    }

    info!("event loop exiting");
    Ok(())
}

async fn launch_agent_repl(
    terminal: &mut Terminal<CrosstermBackend<std::io::Stdout>>,
    agent_id: &str,
    _tx: mpsc::UnboundedSender<AppEvent>,
) -> Result<()> {
    use crossterm::{
        execute,
        terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
    };
    use std::io;

    disable_raw_mode()?;
    execute!(io::stdout(), LeaveAlternateScreen)?;

    let status = tokio::process::Command::new("claude")
        .args(["--agent", agent_id])
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status()
        .await;

    if let Err(e) = &status {
        eprintln!("\nFailed to launch claude --agent {agent_id}: {e}");
        eprintln!("Press Enter to return to nostromo.");
        let _ = std::io::stdin().lines().next();
    }

    enable_raw_mode()?;
    execute!(io::stdout(), EnterAlternateScreen)?;
    terminal.clear()?;

    Ok(())
}
