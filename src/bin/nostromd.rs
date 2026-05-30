//! `nostromd` — nostromo IPC daemon
//!
//! Runs as a background process (managed by launchd) and provides shared live
//! state to all TUI instances via a Unix socket:
//!
//! - Tails `~/.claude/activity.jsonl` and fans out `Activity` events.
//! - Polls `mother list --format json` every 2 s and broadcasts `MotherJobs`,
//!   `MotherStatusline`, and `MotherAwaitDetected` events.
//! - Owns PTY processes on behalf of TUI clients so they survive TUI restarts.
//! - Removes the socket file on clean exit (SIGTERM / SIGINT).

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use anyhow::{Context, Result};
use tokio::signal::unix::{signal, SignalKind};
use tokio::sync::broadcast;
use tracing::info;
use tracing_appender::rolling;
use tracing_subscriber::{fmt, prelude::*, EnvFilter};

use nostromo::{
    agent_bus::{tail_activity_jsonl, ActivityEvent},
    ipc::{protocol::ServerMsg, PtyManager, Server, SessionManager},
    mother::{self, statusline_cache_path, MotherStatus},
};

#[tokio::main]
async fn main() -> Result<()> {
    // ── Logging ───────────────────────────────────────────────────────────────
    let log_dir = daemon_log_dir();
    std::fs::create_dir_all(&log_dir)
        .with_context(|| format!("creating daemon log dir {}", log_dir.display()))?;

    let file_appender = rolling::daily(&log_dir, "nostromd.log");
    let (non_blocking, _guard) = tracing_appender::non_blocking(file_appender);

    let file_layer = fmt::layer()
        .with_writer(non_blocking)
        .with_ansi(false)
        .json();

    tracing_subscriber::registry()
        .with(EnvFilter::from_default_env().add_directive(tracing::Level::INFO.into()))
        .with(file_layer)
        .init();

    info!(pid = std::process::id(), "nostromd starting");

    // ── PTY manager ───────────────────────────────────────────────────────────
    let pty_mgr: Arc<Mutex<PtyManager>> = Arc::new(Mutex::new(PtyManager::new()));

    // ── Session manager (persistent stream-json sessions) ──────────────────────
    let session_mgr: Arc<Mutex<SessionManager>> = Arc::new(Mutex::new(SessionManager::new()));

    // ── IPC server ────────────────────────────────────────────────────────────
    let socket_path = nostromo::ipc::default_socket_path();
    let server = Server::bind(&socket_path, Arc::clone(&pty_mgr), Arc::clone(&session_mgr))
        .with_context(|| format!("binding IPC socket at {}", socket_path.display()))?;

    // ── Session crash-recovery supervisor ──────────────────────────────────────
    {
        let session_mgr = Arc::clone(&session_mgr);
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(2));
            interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                interval.tick().await;
                session_mgr.lock().unwrap().reap_and_recover();
            }
        });
    }

    let broadcast_tx = server.tx.clone();

    // ── Activity tailer ───────────────────────────────────────────────────────
    let activity_path = dirs_next::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".claude")
        .join("activity.jsonl");

    let btx_activity = broadcast_tx.clone();
    tokio::spawn(async move {
        let on_event = move |ev: ActivityEvent| {
            let _ = btx_activity.send(ServerMsg::Activity(ev));
        };
        if let Err(e) = tail_activity_jsonl(activity_path, on_event).await {
            tracing::warn!("activity tailer exited: {e:#}");
        }
    });

    // ── Mother pollers ────────────────────────────────────────────────────────
    let btx_mother = broadcast_tx.clone();
    tokio::spawn(run_mother_pollers(btx_mother));

    // ── SIGTERM / SIGINT ──────────────────────────────────────────────────────
    let mut sigterm = signal(SignalKind::terminate())?;
    let mut sigint = signal(SignalKind::interrupt())?;

    tokio::select! {
        _ = sigterm.recv() => info!("received SIGTERM"),
        _ = sigint.recv()  => info!("received SIGINT"),
    }

    info!("nostromd shutting down; killing all PTYs and sessions");

    // Kill all child processes cleanly before exiting.
    {
        let mut mgr = pty_mgr.lock().unwrap();
        mgr.kill_all_on_shutdown();
    }
    {
        let mut mgr = session_mgr.lock().unwrap();
        mgr.kill_all_on_shutdown();
    }

    // `server` drop impl removes the socket file.
    drop(server);
    Ok(())
}

// ── mother pollers ────────────────────────────────────────────────────────────

async fn run_mother_pollers(tx: broadcast::Sender<ServerMsg>) {
    let tx2 = tx.clone();
    tokio::join!(run_statusline_watcher(tx), run_job_poller(tx2),);
}

async fn run_statusline_watcher(tx: broadcast::Sender<ServerMsg>) {
    let path: PathBuf = statusline_cache_path();

    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }

    let (notify_tx, mut notify_rx) = tokio::sync::mpsc::channel::<()>(16);

    use notify::{RecursiveMode, Watcher};

    let watch_dir = path
        .parent()
        .unwrap_or_else(|| std::path::Path::new("/tmp"))
        .to_path_buf();

    let cache_path_clone = path.clone();
    let watcher_result =
        notify::recommended_watcher(move |res: notify::Result<notify::Event>| match res {
            Ok(ev) => {
                if ev.paths.iter().any(|p| p == &cache_path_clone) {
                    let _ = notify_tx.blocking_send(());
                }
            }
            Err(e) => tracing::warn!("statusline notify error: {e}"),
        });

    let mut watcher = match watcher_result {
        Ok(w) => w,
        Err(e) => {
            tracing::warn!("could not create statusline watcher: {e}");
            return;
        }
    };

    if let Err(e) = watcher.watch(&watch_dir, RecursiveMode::NonRecursive) {
        tracing::warn!("could not watch statusline dir: {e}");
        return;
    }

    let _ = tx.send(ServerMsg::MotherStatusline(MotherStatus::load()));

    while notify_rx.recv().await.is_some() {
        let _ = tx.send(ServerMsg::MotherStatusline(MotherStatus::load()));
    }
}

async fn run_job_poller(tx: broadcast::Sender<ServerMsg>) {
    let mut seen_awaiting: HashSet<String> = HashSet::new();
    let mut last_states: HashMap<String, String> = HashMap::new();

    let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(2));
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    loop {
        interval.tick().await;

        match mother::list_jobs().await {
            Ok(jobs) => {
                tracing::debug!(count = jobs.len(), "mother poll ok");
                for job in &jobs {
                    let prev_state = last_states
                        .get(&job.id)
                        .map(|s| s.as_str())
                        .unwrap_or("unknown");

                    if job.is_awaiting()
                        && !seen_awaiting.contains(&job.id)
                        && (prev_state != "awaiting" || !last_states.contains_key(&job.id))
                    {
                        seen_awaiting.insert(job.id.clone());
                        let _ = tx.send(ServerMsg::MotherAwaitDetected(job.clone()));
                    }

                    if !job.is_awaiting() {
                        seen_awaiting.remove(&job.id);
                    }

                    last_states.insert(job.id.clone(), job.state.clone());
                }

                match tx.send(ServerMsg::MotherJobs { jobs }) {
                    Ok(n) => tracing::debug!(receivers = n, "MotherJobs broadcast sent"),
                    Err(_) => {
                        // No current subscribers — Nostromo may be closed. Keep
                        // polling so the data is ready when a client reconnects.
                        tracing::debug!("MotherJobs broadcast: no receivers, continuing");
                    }
                }
            }
            Err(e) => {
                tracing::warn!("mother list_jobs error: {e:#}");
            }
        }
    }
}

// ── helpers ───────────────────────────────────────────────────────────────────

fn daemon_log_dir() -> PathBuf {
    dirs_next::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".cache")
        .join("nostromd")
        .join("log")
}
