//! nostromo — AI agent TUI
//!
//! Entry point: parse args, initialise terminal, run the main event loop,
//! restore terminal on exit or panic.

use std::io;
use std::panic;
use std::path::PathBuf;

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
use nostromo::{app, config::Config, ViewArg};

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
    let result = app::run(args.view, config, &mut terminal);

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
