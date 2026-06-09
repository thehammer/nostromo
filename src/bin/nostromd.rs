//! `nostromd` — nostromo IPC daemon
//!
//! Runs as a background process (managed by launchd) and provides shared live
//! state to all TUI instances via a Unix socket:
//!
//! - Tails `~/.claude/activity.jsonl` and fans out `Activity` events.
//! - Polls `mother list --format json` every 2 s and broadcasts `MotherJobs`,
//!   `MotherStatusline`, and `MotherAwaitDetected` events.
//! - Watches the Perri native sources and broadcasts `PerriState` events
//!   whenever the PR queue or current-PR snapshot changes.
//! - Spawns `FredMailboxNativeSource` + `FredCalendarNativeSource` and broadcasts
//!   `FredState` on startup and whenever either watch channel changes.
//! - Owns PTY processes on behalf of TUI clients so they survive TUI restarts.
//! - Removes the socket file on clean exit (SIGTERM / SIGINT).

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use anyhow::{Context, Result};
use tokio::signal::unix::{signal, SignalKind};
use tokio::sync::broadcast;
use tracing::{info, warn};
use tracing_appender::rolling;
use tracing_subscriber::{fmt, prelude::*, EnvFilter};

use nostromo::{
    agent_bus::{tail_activity_jsonl, ActivityEvent},
    config::Config,
    data::{
        fred_calendar::CalendarSnapshot,
        fred_calendar_native::FredCalendarNativeSource,
        fred_mailbox::MailboxSnapshot,
        fred_mailbox_native::FredMailboxNativeSource,
        perri_pr::PrSnapshot,
        perri_pr_native::PerriPrNativeSource,
        perri_queue::PrQueueSnapshot,
        perri_queue_native::PerriQueueNativeSource,
        teri_todos::TeriTodosNativeSource,
    },
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

    // ── Config ────────────────────────────────────────────────────────────────
    let config = Config::load(None).context("loading config")?;

    // ── PTY manager ───────────────────────────────────────────────────────────
    let pty_mgr: Arc<Mutex<PtyManager>> = Arc::new(Mutex::new(PtyManager::new()));

    // ── Session manager (persistent stream-json sessions) ──────────────────────
    let session_mgr: Arc<Mutex<SessionManager>> = Arc::new(Mutex::new(SessionManager::new()));

    // ── IPC server (Unix socket) ──────────────────────────────────────────────
    let socket_path = nostromo::ipc::default_socket_path();
    let server = Server::bind(&socket_path, Arc::clone(&pty_mgr), Arc::clone(&session_mgr))
        .with_context(|| format!("binding IPC socket at {}", socket_path.display()))?;

    // ── IPC server (TCP — iOS / LAN clients) ──────────────────────────────────
    let tcp_addr = config.tcp_listen_addr();
    let tcp_listener = tokio::net::TcpListener::bind(tcp_addr)
        .await
        .with_context(|| format!("binding TCP IPC listener at {tcp_addr}"))?;
    let bound_tcp_addr = tcp_listener.local_addr()?;
    info!(addr = %bound_tcp_addr, "IPC TCP listener bound");

    // Phase 0 carries no authentication.  Warn loudly when the daemon is
    // reachable from off-host so operators understand the risk and can choose
    // to restrict access (firewall / VPN) while auth is not yet implemented.
    if !bound_tcp_addr.ip().is_loopback() {
        warn!(
            addr = %bound_tcp_addr,
            "TCP IPC listener is reachable from the network (non-loopback). \
             Phase 0 has NO authentication — any LAN host can issue PtySpawn \
             and session commands. Restrict with a firewall or set \
             NOSTROMD_TCP_ADDR=127.0.0.1:47100 to disable LAN access."
        );
    }

    server.bind_tcp(tcp_listener, Arc::clone(&pty_mgr), Arc::clone(&session_mgr));

    // ── Session crash-recovery supervisor ──────────────────────────────────────
    {
        let session_mgr = Arc::clone(&session_mgr);
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(2));
            interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                interval.tick().await;
                let mgr = &mut *session_mgr.lock().unwrap();
                mgr.reap_and_recover();
                mgr.emit_pending_summaries();
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

    // ── Perri background sources ──────────────────────────────────────────────
    // These watch dirty-file sentinels and write cache files consumed by the
    // GUI (AppStore.swift).  They run independently of any TUI connection.
    let (perri_queue_rx, _perri_queue_refresh_tx) = PerriQueueNativeSource::spawn(config.clone());
    let (perri_pr_rx, _perri_pr_refresh_tx) = PerriPrNativeSource::spawn(config.clone());

    // ── Perri broadcaster ─────────────────────────────────────────────────────
    // Watches the native Perri sources and broadcasts PerriState whenever either
    // the queue or the current-PR snapshot changes.
    tokio::spawn(run_perri_broadcaster(
        broadcast_tx.clone(),
        perri_queue_rx,
        perri_pr_rx,
    ));

    // ── Fred background sources ───────────────────────────────────────────────
    let fred_mailbox_rx  = FredMailboxNativeSource::spawn(config.clone());
    let fred_calendar_rx = FredCalendarNativeSource::spawn(config.clone());

    // ── Teri todos source + broadcaster ───────────────────────────────────────
    let teri_todos_rx = TeriTodosNativeSource::spawn();
    let btx_teri = broadcast_tx.clone();
    tokio::spawn(run_teri_broadcaster(teri_todos_rx, btx_teri));

    // ── Mother pollers ────────────────────────────────────────────────────────
    let btx_mother = broadcast_tx.clone();
    let (jobs_tx, jobs_rx) = tokio::sync::watch::channel(Vec::<nostromo::mother::MotherJob>::new());
    tokio::spawn(run_mother_pollers(btx_mother, jobs_tx));

    // ── Mother peek poller ────────────────────────────────────────────────────
    let btx_peek = broadcast_tx.clone();
    tokio::spawn(run_peek_poller(btx_peek, jobs_rx));

    // ── Fred broadcaster ──────────────────────────────────────────────────────
    let btx_fred = broadcast_tx.clone();
    tokio::spawn(run_fred_broadcaster(btx_fred, fred_mailbox_rx, fred_calendar_rx));

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

async fn run_mother_pollers(
    tx: broadcast::Sender<ServerMsg>,
    jobs_tx: tokio::sync::watch::Sender<Vec<nostromo::mother::MotherJob>>,
) {
    let tx2 = tx.clone();
    tokio::join!(run_statusline_watcher(tx), run_job_poller(tx2, jobs_tx),);
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

async fn run_job_poller(
    tx: broadcast::Sender<ServerMsg>,
    jobs_tx: tokio::sync::watch::Sender<Vec<nostromo::mother::MotherJob>>,
) {
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
                        let _ = tx.send(ServerMsg::MotherAwaitDetected(Box::new(job.clone())));
                    }

                    if !job.is_awaiting() {
                        seen_awaiting.remove(&job.id);
                    }

                    last_states.insert(job.id.clone(), job.state.clone());
                }

                // Publish live job list to the peek poller.
                let _ = jobs_tx.send(jobs.clone());

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

// ── peek poller ───────────────────────────────────────────────────────────────

/// Polls `mother peek` every 3 seconds for each active (running / awaiting) job
/// and broadcasts `ServerMsg::MotherPeek` snapshots.
///
/// When a job transitions out of active state a final `MotherPeek` with empty
/// todos / tool_trail / last_text is broadcast so clients can clear the display.
async fn run_peek_poller(
    tx: broadcast::Sender<ServerMsg>,
    jobs_rx: tokio::sync::watch::Receiver<Vec<nostromo::mother::MotherJob>>,
) {
    let mut active: HashSet<String> = HashSet::new();

    let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(3));
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    loop {
        interval.tick().await;

        // Snapshot the current job list.
        let jobs = jobs_rx.borrow().clone();

        let currently_active: HashSet<String> = jobs
            .iter()
            .filter(|j| j.state == "running" || j.state == "awaiting")
            .map(|j| j.id.clone())
            .collect();

        // Send a terminal-clear for jobs that just left the active set.
        for id in active.difference(&currently_active) {
            let _ = tx.send(ServerMsg::MotherPeek {
                job_id:     id.clone(),
                todos:      vec![],
                tool_trail: vec![],
                last_text:  String::new(),
            });
        }

        active = currently_active;

        // Peek each active job and broadcast its snapshot.
        for id in &active {
            match mother::peek(id).await {
                Ok(snap) => {
                    let _ = tx.send(ServerMsg::MotherPeek {
                        job_id:     id.clone(),
                        todos:      snap.todos,
                        tool_trail: snap.tool_trail,
                        last_text:  snap.last_text.chars().take(200).collect(),
                    });
                }
                Err(e) => {
                    tracing::debug!(job_id = %id, "peek error: {e:#}");
                }
            }
        }
    }
}

// ── perri broadcaster ─────────────────────────────────────────────────────────

/// Build a `ServerMsg::PerriState` from the current watch-channel snapshots.
///
/// Extracted as a free function so it can be unit-tested without a running daemon.
fn build_perri_state(
    queue_snap: Option<&PrQueueSnapshot>,
    pr_snap: Option<&PrSnapshot>,
) -> ServerMsg {
    ServerMsg::PerriState {
        queue: queue_snap
            .map(|s| s.items.clone())
            .unwrap_or_default(),
        current: pr_snap.cloned().map(Box::new),
    }
}

/// Watch the Perri native sources and broadcast `PerriState` on every change.
///
/// Sends one initial broadcast immediately (so clients that connect after the
/// first fetch still see current state), then loops on `tokio::select!` over
/// both channels.
async fn run_perri_broadcaster(
    tx: broadcast::Sender<ServerMsg>,
    mut queue_rx: tokio::sync::watch::Receiver<Option<PrQueueSnapshot>>,
    mut pr_rx: tokio::sync::watch::Receiver<Option<PrSnapshot>>,
) {
    // Initial broadcast — borrow briefly, clone data, drop borrow before send.
    {
        let queue = queue_rx.borrow().clone();
        let pr    = pr_rx.borrow().clone();
        let _ = tx.send(build_perri_state(queue.as_ref(), pr.as_ref()));
    }

    loop {
        tokio::select! {
            result = queue_rx.changed() => {
                if result.is_err() { break; } // sender dropped — clean exit
                let queue = queue_rx.borrow_and_update().clone();
                let pr    = pr_rx.borrow().clone();
                let _ = tx.send(build_perri_state(queue.as_ref(), pr.as_ref()));
            }
            result = pr_rx.changed() => {
                if result.is_err() { break; }
                let queue = queue_rx.borrow().clone();
                let pr    = pr_rx.borrow_and_update().clone();
                let _ = tx.send(build_perri_state(queue.as_ref(), pr.as_ref()));
            }
        }
    }

    tracing::debug!("perri broadcaster exiting — watch channels closed");
}

// ── Fred broadcaster ─────────────────────────────────────────────────────────

/// Broadcast `FredState` on startup and whenever either Fred source changes.
async fn run_fred_broadcaster(
    tx: broadcast::Sender<ServerMsg>,
    mut mailbox_rx: tokio::sync::watch::Receiver<Option<MailboxSnapshot>>,
    mut calendar_rx: tokio::sync::watch::Receiver<Option<CalendarSnapshot>>,
) {
    // Send an initial frame so a client that connects after the first fetch
    // still gets state. Clone the watch contents while borrowed, drop the
    // borrow before send.
    let _ = tx.send(build_fred_state(&mailbox_rx, &calendar_rx));
    loop {
        tokio::select! {
            r = mailbox_rx.changed() => { if r.is_err() { break; } }
            r = calendar_rx.changed() => { if r.is_err() { break; } }
        }
        // No-receiver send error is non-fatal (Nostromo may be closed).
        let _ = tx.send(build_fred_state(&mailbox_rx, &calendar_rx));
    }
}

/// Build a `FredState` from the current watch contents, substituting
/// `default()` snapshots when a source has not produced data yet.
fn build_fred_state(
    mailbox_rx: &tokio::sync::watch::Receiver<Option<MailboxSnapshot>>,
    calendar_rx: &tokio::sync::watch::Receiver<Option<CalendarSnapshot>>,
) -> ServerMsg {
    let mailbox  = mailbox_rx.borrow().clone().unwrap_or_default();
    let calendar = calendar_rx.borrow().clone().unwrap_or_default();
    ServerMsg::FredState { mailbox, calendar }
}

// ── teri broadcaster ──────────────────────────────────────────────────────────

/// Watch the `TeriTodosNativeSource` channel and broadcast a `TeriState` frame
/// whenever the snapshot changes.  The first emission covers the initial poll.
async fn run_teri_broadcaster(
    mut rx: tokio::sync::watch::Receiver<Option<nostromo::data::teri_todos::TeriTodosSnapshot>>,
    tx: broadcast::Sender<ServerMsg>,
) {
    loop {
        // Emit the current value first (covers the initial snapshot), then wait
        // for the next change before emitting again.
        if let Some(snap) = rx.borrow_and_update().clone() {
            let _ = tx.send(ServerMsg::TeriState { todos: snap });
        }
        if rx.changed().await.is_err() {
            break; // sender dropped — daemon shutting down
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
