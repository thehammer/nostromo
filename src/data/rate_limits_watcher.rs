//! File-system watcher for Claude rate-limit and budget-posture files.
//!
//! Watches two on-disk files:
//! - `/tmp/.claude-rate-limits`         → `AppEvent::RateLimitsChanged`
//! - `~/.claude/budget-posture.json`    → `AppEvent::PostureChanged`
//!
//! Modelled on the `mother_poll` notify-watcher pattern.

use std::path::PathBuf;

use tokio::sync::mpsc;
use tracing::{debug, warn};

use crate::{
    data::rate_limits::{BudgetPosture, RateLimits},
    event::AppEvent,
};

/// Spawn background watchers for both rate-limit files.
///
/// Emits initial values on startup (if the files exist) then re-reads on every
/// file-change event.
pub fn spawn(tx: mpsc::UnboundedSender<AppEvent>) {
    spawn_rate_limits_watcher(tx.clone());
    spawn_posture_watcher(tx);
}

// ── rate-limits watcher ───────────────────────────────────────────────────────

fn spawn_rate_limits_watcher(tx: mpsc::UnboundedSender<AppEvent>) {
    tokio::spawn(async move {
        if let Err(e) = run_rate_limits_watcher(tx).await {
            warn!("rate-limits watcher exited with error: {e:#}");
        }
    });
}

async fn run_rate_limits_watcher(tx: mpsc::UnboundedSender<AppEvent>) -> anyhow::Result<()> {
    let path = PathBuf::from("/tmp/.claude-rate-limits");

    let (notify_tx, mut notify_rx) = tokio::sync::mpsc::channel::<()>(16);

    use notify::{RecursiveMode, Watcher};

    let watch_dir = path
        .parent()
        .unwrap_or_else(|| std::path::Path::new("/tmp"))
        .to_path_buf();

    let target = path.clone();
    let mut watcher =
        notify::recommended_watcher(move |res: notify::Result<notify::Event>| match res {
            Ok(ev) => {
                if ev.paths.iter().any(|p| p == &target) {
                    let _ = notify_tx.blocking_send(());
                }
            }
            Err(e) => warn!("rate-limits notify error: {e}"),
        })?;

    watcher.watch(&watch_dir, RecursiveMode::NonRecursive)?;
    debug!(path = %path.display(), "rate-limits watcher started");

    // Emit once on startup.
    if let Some(rl) = RateLimits::load() {
        let _ = tx.send(AppEvent::RateLimitsChanged(rl));
    }

    while notify_rx.recv().await.is_some() {
        if let Some(rl) = RateLimits::load() {
            if tx.send(AppEvent::RateLimitsChanged(rl)).is_err() {
                break;
            }
        }
    }

    Ok(())
}

// ── posture watcher ───────────────────────────────────────────────────────────

fn spawn_posture_watcher(tx: mpsc::UnboundedSender<AppEvent>) {
    tokio::spawn(async move {
        if let Err(e) = run_posture_watcher(tx).await {
            warn!("posture watcher exited with error: {e:#}");
        }
    });
}

async fn run_posture_watcher(tx: mpsc::UnboundedSender<AppEvent>) -> anyhow::Result<()> {
    let home = dirs_next::home_dir().unwrap_or_else(|| PathBuf::from("/tmp"));
    let path = home.join(".claude").join("budget-posture.json");

    let (notify_tx, mut notify_rx) = tokio::sync::mpsc::channel::<()>(16);

    use notify::{RecursiveMode, Watcher};

    let watch_dir = path
        .parent()
        .unwrap_or_else(|| std::path::Path::new("/tmp"))
        .to_path_buf();

    let target = path.clone();
    let mut watcher =
        notify::recommended_watcher(move |res: notify::Result<notify::Event>| match res {
            Ok(ev) => {
                if ev.paths.iter().any(|p| p == &target) {
                    let _ = notify_tx.blocking_send(());
                }
            }
            Err(e) => warn!("posture notify error: {e}"),
        })?;

    // Only watch if the parent directory exists; create it otherwise to avoid error.
    if watch_dir.exists() {
        watcher.watch(&watch_dir, RecursiveMode::NonRecursive)?;
    }
    debug!(path = %path.display(), "posture watcher started");

    // Emit once on startup.
    if let Some(p) = BudgetPosture::load() {
        let _ = tx.send(AppEvent::PostureChanged(p));
    }

    while notify_rx.recv().await.is_some() {
        if let Some(p) = BudgetPosture::load() {
            if tx.send(AppEvent::PostureChanged(p)).is_err() {
                break;
            }
        }
    }

    Ok(())
}
