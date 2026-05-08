//! nostromo — AI agent TUI
//!
//! Entry point: parse args, initialise terminal, run the main event loop,
//! restore terminal on exit or panic.

use std::io;
use std::panic;
use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{Context, Result};
use clap::Parser;
use crossterm::{
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use directories::ProjectDirs;
use ratatui::{backend::CrosstermBackend, Terminal};
use tracing::info;
use tracing_appender::rolling;
use tracing_subscriber::{fmt, prelude::*, EnvFilter};

// All application logic lives in the library crate.
use nostromo::{agent_bus::AgentBus, app, config::Config, ui::widgets::syntect_cache::SyntectCache, ViewArg};

#[derive(Parser, Debug)]
#[command(
    name = "nostromo",
    about = "AI agent TUI — unified dashboard for fred, perri, cody, claudia, and mother",
    version
)]
struct Args {
    /// Which view to open on launch
    #[arg(long, default_value = "all")]
    view: ViewArg,

    /// Override config file path
    #[arg(long)]
    config: Option<PathBuf>,

    /// Use the legacy bash data sources instead of native Rust clients.
    /// Requires fred-mailbox-pane, fred-calendar-pane, perri-queue-pane, and
    /// perri-diff-pane to be installed in the claude bin directory.
    #[arg(long)]
    bash_fallback: bool,
}

fn main() -> Result<()> {
    let args = Args::parse();

    // ------------------------------------------------------------------
    // Logging — write to ~/.cache/nostromo/log/nostromo.log
    // ------------------------------------------------------------------
    let log_dir = log_directory()?;
    std::fs::create_dir_all(&log_dir)
        .with_context(|| format!("creating log dir {}", log_dir.display()))?;

    let file_appender = rolling::daily(&log_dir, "nostromo.log");
    let (non_blocking, _guard) = tracing_appender::non_blocking(file_appender);

    let file_layer = fmt::layer()
        .with_writer(non_blocking)
        .with_ansi(false)
        .json();

    tracing_subscriber::registry()
        .with(EnvFilter::from_default_env().add_directive(tracing::Level::DEBUG.into()))
        .with(file_layer)
        .init();

    info!(version = env!("CARGO_PKG_VERSION"), view = ?args.view, "nostromo starting");

    // ------------------------------------------------------------------
    // Syntect cache — built once, shared across all diff views
    // ------------------------------------------------------------------
    let syntect = Arc::new(
        SyntectCache::load().context("loading syntect syntax/theme cache")?,
    );

    // ------------------------------------------------------------------
    // Agent bus — tails ~/.claude/activity.jsonl
    // ------------------------------------------------------------------
    let bus = Arc::new(AgentBus::new());
    let activity_path = dirs_next::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".claude")
        .join("activity.jsonl");
    Arc::clone(&bus).start_tail(activity_path);

    // ------------------------------------------------------------------
    // Terminal setup
    // ------------------------------------------------------------------
    let mut stdout = io::stdout();
    enable_raw_mode().context("enabling raw mode")?;
    execute!(stdout, EnterAlternateScreen).context("entering alternate screen")?;

    // Panic hook: restore terminal before dumping the panic message so the
    // user's shell isn't left in an unusable state.
    let original_hook = panic::take_hook();
    panic::set_hook(Box::new(move |info| {
        let _ = disable_raw_mode();
        let _ = execute!(io::stdout(), LeaveAlternateScreen);
        original_hook(info);
    }));

    let backend = CrosstermBackend::new(io::stdout());
    let mut terminal = Terminal::new(backend).context("creating terminal")?;
    terminal.clear()?;

    // ------------------------------------------------------------------
    // Load config
    // ------------------------------------------------------------------
    let config = Config::load(args.config.as_deref())?;

    // ------------------------------------------------------------------
    // Run
    // ------------------------------------------------------------------
    let result = app::run(args.view, args.bash_fallback, config, &mut terminal, syntect, bus);

    // ------------------------------------------------------------------
    // Terminal teardown (always, even if run() errored)
    // ------------------------------------------------------------------
    disable_raw_mode().ok();
    execute!(terminal.backend_mut(), LeaveAlternateScreen).ok();
    terminal.show_cursor().ok();

    result
}

fn log_directory() -> Result<PathBuf> {
    if let Some(proj) = ProjectDirs::from("", "", "nostromo") {
        Ok(proj.cache_dir().join("log"))
    } else {
        Ok(dirs_next::home_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join(".cache")
            .join("nostromo")
            .join("log"))
    }
}
