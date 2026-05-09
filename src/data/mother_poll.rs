//! Background poller for Mother's job queue and statusline cache.
//!
//! Spawns two concurrent watchers:
//! 1. `notify` watcher on the statusline cache file → `MotherStatusline` events.
//! 2. 2-second interval polling `mother list --format json` → `MotherJobs` +
//!    `AwaitDetected` events when a job transitions into `awaiting`.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

use tokio::sync::mpsc;
use tracing::{debug, warn};

use crate::{
    event::AppEvent,
    mother::{self, statusline_cache_path, MotherStatus},
};

/// Spawn both the statusline watcher and the job-list poller.
pub fn spawn(tx: mpsc::UnboundedSender<AppEvent>) {
    spawn_statusline_watcher(tx.clone());
    spawn_job_poller(tx);
}

// ── statusline watcher ────────────────────────────────────────────────────────

fn spawn_statusline_watcher(tx: mpsc::UnboundedSender<AppEvent>) {
    tokio::spawn(async move {
        if let Err(e) = run_statusline_watcher(tx).await {
            warn!("statusline watcher exited with error: {e:#}");
        }
    });
}

async fn run_statusline_watcher(tx: mpsc::UnboundedSender<AppEvent>) -> anyhow::Result<()> {
    let path: PathBuf = statusline_cache_path();

    // Ensure the file exists so notify can watch it.
    if !path.exists() {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        // Don't create the file — mother owns it. Just skip watching until it appears.
    }

    let (notify_tx, mut notify_rx) = tokio::sync::mpsc::channel::<()>(16);

    use notify::{RecursiveMode, Watcher};

    // Watch the parent directory so we catch file creation events.
    let watch_dir = path
        .parent()
        .unwrap_or_else(|| std::path::Path::new("/tmp"))
        .to_path_buf();

    let cache_path_clone = path.clone();
    let mut watcher =
        notify::recommended_watcher(move |res: notify::Result<notify::Event>| match res {
            Ok(ev) => {
                // Only care about events touching our specific cache file.
                let relevant = ev.paths.iter().any(|p| p == &cache_path_clone);
                if relevant {
                    let _ = notify_tx.blocking_send(());
                }
            }
            Err(e) => warn!("statusline notify error: {e}"),
        })?;

    watcher.watch(&watch_dir, RecursiveMode::NonRecursive)?;
    debug!(path = %path.display(), "statusline watcher started");

    // Emit once immediately.
    let _ = tx.send(AppEvent::MotherStatusline(MotherStatus::load()));

    while notify_rx.recv().await.is_some() {
        let status = MotherStatus::load();
        if tx.send(AppEvent::MotherStatusline(status)).is_err() {
            break;
        }
    }

    Ok(())
}

// ── job-list poller ───────────────────────────────────────────────────────────

fn spawn_job_poller(tx: mpsc::UnboundedSender<AppEvent>) {
    tokio::spawn(async move {
        // Track which job IDs we've already seen in `awaiting` so we only fire
        // `AwaitDetected` once per transition.
        let mut seen_awaiting: HashSet<String> = HashSet::new();
        // Track last known states to detect transitions.
        let mut last_states: HashMap<String, String> = HashMap::new();

        let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(2));
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

        loop {
            interval.tick().await;

            match mother::list_jobs().await {
                Ok(jobs) => {
                    // Detect new `awaiting` transitions.
                    for job in &jobs {
                        let prev_state = last_states
                            .get(&job.id)
                            .map(|s| s.as_str())
                            .unwrap_or("unknown");

                        if job.is_awaiting() && !seen_awaiting.contains(&job.id) {
                            // Only fire if state actually changed (or first time we see it).
                            if prev_state != "awaiting" || !last_states.contains_key(&job.id) {
                                seen_awaiting.insert(job.id.clone());
                                let _ = tx.send(AppEvent::AwaitDetected(Box::new(job.clone())));
                            }
                        }

                        // When a job leaves `awaiting`, remove it from the seen set
                        // so a future re-entry fires again.
                        if !job.is_awaiting() {
                            seen_awaiting.remove(&job.id);
                        }

                        last_states.insert(job.id.clone(), job.state.clone());
                    }

                    if tx.send(AppEvent::MotherJobs(jobs)).is_err() {
                        break;
                    }
                }
                Err(e) => {
                    debug!("mother list_jobs error: {e:#}");
                }
            }
        }
    });
}
