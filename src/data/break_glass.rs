//! Break-glass sentinel watcher.
//!
//! Watches `$HOME/.nostromo/` for `break-glass.json`.  When the file appears,
//! parses it and emits a `BreakGlassDetected` event into the app channel.
//!
//! See `docs/break-glass.md` for the sentinel convention.

use std::path::PathBuf;

use anyhow::Result;
use chrono::{DateTime, Utc};
use serde::Deserialize;
use tokio::sync::mpsc;
use tracing::{debug, warn};

use crate::event::AppEvent;

/// Contents of `$HOME/.nostromo/break-glass.json`.
#[derive(Debug, Clone, Deserialize)]
pub struct BreakGlassRequest {
    pub action: String,
    pub summary: String,
    pub requested_at: DateTime<Utc>,
}

/// Path to the sentinel file.
pub fn sentinel_path() -> PathBuf {
    dirs_next::home_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join(".nostromo")
        .join("break-glass.json")
}

/// Path to the response file written by nostromo on approve/deny.
pub fn response_path() -> PathBuf {
    dirs_next::home_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join(".nostromo")
        .join("break-glass.response")
}

/// Try to read and parse the sentinel file.  Returns `None` if absent or malformed.
pub fn try_read_sentinel() -> Option<BreakGlassRequest> {
    let path = sentinel_path();
    let content = std::fs::read_to_string(&path).ok()?;
    match serde_json::from_str::<BreakGlassRequest>(&content) {
        Ok(req) => Some(req),
        Err(e) => {
            warn!("break-glass.json malformed: {e}");
            None
        }
    }
}

/// Write `approved` or `denied` to the response file and remove the sentinel.
pub fn respond(approved: bool) -> Result<()> {
    let word = if approved { "approved" } else { "denied" };
    let resp = response_path();
    if let Some(parent) = resp.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(&resp, word)?;
    let sentinel = sentinel_path();
    if sentinel.exists() {
        std::fs::remove_file(&sentinel)?;
    }
    Ok(())
}

/// Spawn a background task that watches `$HOME/.nostromo/` for the sentinel
/// file and emits `AppEvent::BreakGlassDetected` when it appears.
pub fn spawn(tx: mpsc::UnboundedSender<AppEvent>) {
    tokio::spawn(async move {
        if let Err(e) = run_watcher(tx).await {
            warn!("break-glass watcher error: {e:#}");
        }
    });
}

async fn run_watcher(tx: mpsc::UnboundedSender<AppEvent>) -> Result<()> {
    let dir = dirs_next::home_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join(".nostromo");
    std::fs::create_dir_all(&dir)?;

    let (notify_tx, mut notify_rx) = tokio::sync::mpsc::channel::<()>(8);

    use notify::{RecursiveMode, Watcher};
    let mut watcher =
        notify::recommended_watcher(move |res: notify::Result<notify::Event>| match res {
            Ok(_) => {
                let _ = notify_tx.blocking_send(());
            }
            Err(e) => warn!("break-glass notify error: {e}"),
        })?;
    watcher.watch(&dir, RecursiveMode::NonRecursive)?;

    debug!(dir = %dir.display(), "break-glass watcher started");

    // Check immediately in case the file was there before we started.
    if let Some(req) = try_read_sentinel() {
        let _ = tx.send(AppEvent::BreakGlassDetected(req));
    }

    while notify_rx.recv().await.is_some() {
        if let Some(req) = try_read_sentinel() {
            if tx.send(AppEvent::BreakGlassDetected(req)).is_err() {
                break;
            }
        }
    }

    Ok(())
}
