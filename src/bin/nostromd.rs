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

use std::collections::{BTreeSet, HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use anyhow::{Context, Result};
use nostromo::mdns;
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
        perri_pr::{PrSnapshot, PrSnapshots},
        perri_pr_native::PerriPrNativeSource,
        perri_queue::PrQueueSnapshot,
        perri_queue_native::PerriQueueNativeSource,
        teri_todos::TeriTodosNativeSource,
        tickets::TicketProvider,
    },
    ipc::{
        decisions::DecisionRegistry, pane_registry::PaneRegistry, protocol::ServerMsg, PtyManager,
        Server, SessionManager,
    },
    mcp::{
        daemon_socket_path, write_bridge_mcp_config, DaemonMcpBackend, McpServer, McpSharedState,
    },
    mother::{self, statusline_cache_path, MotherStatus},
};

#[tokio::main]
async fn main() -> Result<()> {
    // ── Logging ───────────────────────────────────────────────────────────────
    let log_dir = daemon_log_dir();
    std::fs::create_dir_all(&log_dir)
        .with_context(|| format!("creating daemon log dir {}", log_dir.display()))?;

    prune_old_logs(&log_dir, 3);
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
    // Seed the session-id reverse index from the on-disk store so activity
    // events from sessions spawned by a *previous* daemon process (this one
    // predates a fresh process's in-memory index) still attribute correctly
    // from the first event, not just after this process spawns/restarts them.
    session_mgr.lock().unwrap().seed_reverse_index();

    // ── Pane registry (agent-authored layout) ──────────────────────────────────
    // Single source of truth for every focus's pane tree. Persisted to disk so
    // an assembled layout survives a daemon restart.
    let pane_registry: Arc<Mutex<PaneRegistry>> = Arc::new(Mutex::new(PaneRegistry::new()));

    // ── Decision registry (W6 decision modals) ─────────────────────────────────
    // Shared between the IPC server (routes ClientMsg::DecisionAnswer, tracks
    // Topic::Decision subscribers) and the daemon-hosted MCP backend
    // (nostromo.ask_decision creates requests and blocks on their answer).
    let decisions: Arc<Mutex<DecisionRegistry>> = Arc::new(Mutex::new(DecisionRegistry::new()));
    {
        let mut mgr = session_mgr.lock().unwrap();
        mgr.configure_decisions(Arc::clone(&decisions));
    }

    // ── IPC server (Unix socket) ──────────────────────────────────────────────
    let socket_path = nostromo::ipc::default_socket_path();
    let server = Server::bind(
        &socket_path,
        Arc::clone(&pty_mgr),
        Arc::clone(&session_mgr),
        config.perri_state_dir(),
        Arc::clone(&decisions),
    )
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

    server.bind_tcp(
        tcp_listener,
        Arc::clone(&pty_mgr),
        Arc::clone(&session_mgr),
        config.perri_state_dir(),
        Arc::clone(&decisions),
    );

    // ── mDNS / Bonjour advertising ────────────────────────────────────────────
    // Advertise nostromd on the LAN so iOS clients can discover it without a
    // hardcoded IP.  Failure is non-fatal: some sandboxed or enterprise
    // environments block multicast.  The guard MUST outlive the select! below.
    let _mdns_guard = match mdns::advertise(bound_tcp_addr.port()) {
        Ok(guard) => {
            info!(
                port = bound_tcp_addr.port(),
                "mDNS advertising started (_nostromo._tcp.local.)"
            );
            Some(guard)
        }
        Err(e) => {
            warn!("mDNS advertising unavailable (non-fatal): {e:#}");
            None
        }
    };

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
    // Every DecisionRegistry resolution path (answer/timeout/cancel_tag) can
    // now announce a ServerMsg::DecisionResolved so every presenting window —
    // not just the one the operator actually used — learns a request is done
    // (multi-window decision-sheet fix). Must happen here, after `server.tx`
    // exists, not in the registry-construction block above.
    decisions
        .lock()
        .unwrap()
        .configure_broadcast(broadcast_tx.clone());

    // ── Daemon-hosted MCP server (agent-driven pane layout) ─────────────────────
    // ── Perri background sources (spawned early so MCP state gets live receivers) ─
    let (perri_queue_rx, perri_queue_refresh_tx, perri_queue_relay_tx) =
        PerriQueueNativeSource::spawn(config.clone());
    // W7 — D8 backstop. The PR source serves a pin only while its focus still
    // exists, so a missed eviction cannot resurrect one. `None` until a client
    // has actually pushed a registry: an empty registry means "nobody has told
    // us yet", and treating it as "no focus exists" would blank every focus's
    // PR for the window between daemon start and the first push.
    let live_focuses: nostromo::data::perri_pr_native::LiveFocuses = {
        let session_mgr = Arc::clone(&session_mgr);
        Arc::new(move || session_mgr.lock().unwrap().live_focus_tags())
    };
    let (perri_pr_rx, perri_pr_refresh_tx) =
        PerriPrNativeSource::spawn(config.clone(), Some(live_focuses));
    let perri_queue_rx_for_mcp = perri_queue_rx.clone();
    let perri_pr_rx_for_mcp = perri_pr_rx.clone();
    let perri_pr_refresh_tx_for_mcp = perri_pr_refresh_tx.clone();

    // ── Mother jobs channel (spawned early so MCP state gets live receiver) ─────
    let (jobs_tx, jobs_rx) = tokio::sync::watch::channel(Vec::<nostromo::mother::MotherJob>::new());
    let jobs_rx_for_mcp = jobs_rx.clone();

    // Hosts the layout/introspection/focus tool surface inside nostromd so that
    // daemon-hosted agent sessions can assemble their own pane workspaces. Pane
    // mutations are applied to `pane_registry` and broadcast as `FocusLayout` /
    // `PaneContent` / `FocusCreated` to all clients. Bind failure is non-fatal —
    // the daemon keeps running without the layout surface.
    let mcp_socket = daemon_socket_path();
    let _mcp_server: Option<McpServer> = match write_bridge_mcp_config() {
        Some(mcp_config) => {
            {
                let mut mgr = session_mgr.lock().unwrap();
                mgr.configure_mcp_bridge(
                    Arc::clone(&pane_registry),
                    mcp_socket.clone(),
                    mcp_config,
                );
            }
            // ── ticket provider registry (W4 — curated-agent-views) ─────────────
            // `jira` is always registered; whether it's actually *configured*
            // (credentials resolved) is logged once so a deployment missing
            // ATLASSIAN_* can tell why `ticket` shows are refused, without
            // ever logging the token itself.
            let jira_provider = Arc::new(nostromo::data::tickets::jira::JiraProvider::new(&config));
            info!(
                configured = jira_provider.is_configured(),
                "jira ticket provider"
            );
            let mut ticket_registry = nostromo::data::tickets::TicketRegistry::new();
            ticket_registry.register(jira_provider);
            let tickets = nostromo::mcp::TicketRegistryState {
                registry: Arc::new(ticket_registry),
                cache: Arc::new(nostromo::data::tickets::TicketCache::new(
                    std::time::Duration::from_secs(60),
                )),
            };

            let backend = DaemonMcpBackend {
                pane_registry: Arc::clone(&pane_registry),
                session_mgr: Arc::clone(&session_mgr),
                broadcast_tx: broadcast_tx.clone(),
                perri: nostromo::mcp::PerriDaemonState {
                    state_dir: Some(config.perri_state_dir()),
                    pr_refresh_tx: Some(perri_pr_refresh_tx_for_mcp.clone()),
                    queue_refresh_tx: Some(perri_queue_refresh_tx.clone()),
                    ..Default::default()
                },
                decisions: Arc::clone(&decisions),
                tickets,
            };
            let state = McpSharedState::for_daemon_with_sources(
                backend,
                perri_queue_rx_for_mcp,
                perri_pr_rx_for_mcp,
                jobs_rx_for_mcp,
            );

            // ── Pane-source liveness (live-pane-sources) ────────────────────────
            // D8: a (re)connecting client is never left staring at an
            // assembled-but-empty workspace — server.rs replays this alongside
            // the existing FocusLayout replay.
            {
                let mut mgr = session_mgr.lock().unwrap();
                mgr.configure_pane_content_provider(Arc::new(
                    nostromo::mcp::pane_sources::McpPaneContentProvider(state.clone()),
                ));
            }
            // D3: repaint every already-bound pane once, immediately — a
            // restarted daemon brings a persisted binding back to life without
            // waiting for the next source change or a client re-running
            // apply_layout.
            nostromo::mcp::pane_sources::repaint_bound_panes(&state);
            // D7: keep every bound pane's content live in the background, with
            // no agent/tool-call involved.
            tokio::spawn(nostromo::mcp::pane_sources::run_pane_source_broadcaster(
                state.clone(),
                state.perri_queue_rx.clone(),
                state.perri_pr_rx.clone(),
            ));

            match McpServer::bind(mcp_socket.clone(), state).await {
                Ok(srv) => {
                    info!(socket = %mcp_socket.display(), "daemon MCP server listening");
                    Some(srv)
                }
                Err(e) => {
                    warn!("daemon MCP server unavailable (non-fatal): {e:#}");
                    None
                }
            }
        }
        None => {
            warn!("could not write MCP bridge config; daemon MCP server disabled");
            None
        }
    };

    // ── Activity tailer ───────────────────────────────────────────────────────
    let activity_path = dirs_next::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".claude")
        .join("activity.jsonl");

    let btx_activity = broadcast_tx.clone();
    let session_mgr_for_activity = Arc::clone(&session_mgr);
    tokio::spawn(async move {
        let on_event = move |ev: ActivityEvent| {
            // Resolve attribution, assign `seq`, and defensively re-scrub —
            // all inside `SessionManager::ingest_activity_event` — before
            // broadcasting, so every subscriber sees the same finalized event
            // the daemon's own snapshot/health responses are built from.
            let finalized = session_mgr_for_activity
                .lock()
                .unwrap()
                .ingest_activity_event(ev);
            let _ = btx_activity.send(ServerMsg::Activity(finalized));
        };
        if let Err(e) = tail_activity_jsonl(activity_path, on_event).await {
            tracing::warn!("activity tailer exited: {e:#}");
        }
    });

    // ── github-relay subscriber ───────────────────────────────────────────────
    // Connects to the relay WebSocket and triggers an immediate queue refresh
    // on every relevant GitHub event, reducing PR-queue lag from the poll
    // interval (~60s) to ~3s. No-ops if relay_url/relay_token are not set.
    nostromo::data::relay_client::spawn(config.clone(), perri_queue_relay_tx);

    // ── Perri broadcaster ─────────────────────────────────────────────────────
    // (Sources were spawned earlier so the MCP state could get live receivers.)
    tokio::spawn(run_perri_broadcaster(
        broadcast_tx.clone(),
        Arc::clone(&session_mgr),
        perri_queue_rx,
        perri_pr_rx,
    ));

    // ── Fred background sources ───────────────────────────────────────────────
    let fred_mailbox_rx = FredMailboxNativeSource::spawn(config.clone());
    let fred_calendar_rx = FredCalendarNativeSource::spawn(config.clone());

    // ── Teri todos source + broadcaster ───────────────────────────────────────
    let teri_todos_rx = TeriTodosNativeSource::spawn();
    let btx_teri = broadcast_tx.clone();
    tokio::spawn(run_teri_broadcaster(teri_todos_rx, btx_teri));

    // ── Mother pollers ────────────────────────────────────────────────────────
    // (jobs_tx/jobs_rx were created earlier so the MCP state could get a live receiver.)
    let btx_mother = broadcast_tx.clone();
    tokio::spawn(run_mother_pollers(btx_mother, jobs_tx));

    // ── Mother peek poller ────────────────────────────────────────────────────
    let btx_peek = broadcast_tx.clone();
    tokio::spawn(run_peek_poller(btx_peek, jobs_rx));

    // ── Fred broadcaster ──────────────────────────────────────────────────────
    let btx_fred = broadcast_tx.clone();
    tokio::spawn(run_fred_broadcaster(
        btx_fred,
        fred_mailbox_rx,
        fred_calendar_rx,
    ));

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
                job_id: id.clone(),
                todos: vec![],
                tool_trail: vec![],
                last_text: String::new(),
            });
        }

        active = currently_active;

        // Peek each active job and broadcast its snapshot.
        for id in &active {
            match mother::peek(id).await {
                Ok(snap) => {
                    let _ = tx.send(ServerMsg::MotherPeek {
                        job_id: id.clone(),
                        todos: snap.todos,
                        tool_trail: snap.tool_trail,
                        last_text: snap.last_text.chars().take(200).collect(),
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

/// Build one focus's `ServerMsg::PerriState`.
///
/// Extracted as a free function so it can be unit-tested without a running daemon.
fn build_perri_state(
    tag: &str,
    queue_snap: Option<&PrQueueSnapshot>,
    pr_snap: Option<&PrSnapshot>,
) -> ServerMsg {
    ServerMsg::PerriState {
        tag: tag.to_owned(),
        queue: queue_snap.map(|s| s.items.clone()).unwrap_or_default(),
        current: pr_snap.cloned().map(Box::new),
    }
}

/// Every focus a `PerriState` frame could be addressed to: those with a PR
/// under review, plus every focus the daemon knows about, so a focus with no
/// PR is told *that* rather than being left with whatever it last heard.
fn perri_state_tags(session_mgr: &Arc<Mutex<SessionManager>>, prs: &PrSnapshots) -> Vec<String> {
    let mut tags: BTreeSet<String> = prs.keys().cloned().collect();
    if let Ok(mgr) = session_mgr.lock() {
        tags.extend(mgr.focus_registry().into_iter().map(|f| f.tag));
    }
    // The `queue` half of every `PerriState` frame is fleet-wide (D9), but
    // after W7 it can only travel *on* a per-focus frame. With no focus to
    // address — before a client has pushed a registry, or briefly after one
    // pushes an empty list on reconnect — the fleet would otherwise stop
    // hearing about the queue entirely until the next non-empty push.
    //
    // The built-in `perri` focus exists in every deployment and cannot be
    // removed (`FocusStore.remove` refuses it), so addressing it here is the
    // honest floor rather than an invented recipient.
    if tags.is_empty() {
        tags.insert(nostromo::data::perri_current_pr::BUILTIN_PERRI_TAG.to_owned());
    }
    tags.into_iter().collect()
}

/// Watch the Perri native sources and broadcast `PerriState` per focus (W7 — D7).
///
/// Sends one initial broadcast immediately (so clients that connect after the
/// first fetch still see current state), then loops on `tokio::select!` over
/// both channels.
///
/// A queue change re-sends every focus — the queue is fleet-wide (D9). A PR
/// change re-sends only the focuses whose PR actually moved, because with N
/// focuses pinned, one pickup otherwise puts N copies of a possibly-500 KB
/// snapshot on the wire.
async fn run_perri_broadcaster(
    tx: broadcast::Sender<ServerMsg>,
    session_mgr: Arc<Mutex<SessionManager>>,
    mut queue_rx: tokio::sync::watch::Receiver<Option<PrQueueSnapshot>>,
    mut pr_rx: tokio::sync::watch::Receiver<PrSnapshots>,
) {
    fn broadcast(
        tx: &broadcast::Sender<ServerMsg>,
        tags: &[String],
        queue: Option<&PrQueueSnapshot>,
        prs: &PrSnapshots,
    ) {
        for tag in tags {
            let _ = tx.send(build_perri_state(tag, queue, prs.get(tag).map(|s| &**s)));
        }
    }

    let mut previous: PrSnapshots = pr_rx.borrow().clone();

    // Initial broadcast — borrow briefly, clone data, drop borrow before send.
    {
        let queue = queue_rx.borrow().clone();
        let tags = perri_state_tags(&session_mgr, &previous);
        broadcast(&tx, &tags, queue.as_ref(), &previous);
    }

    loop {
        tokio::select! {
            result = queue_rx.changed() => {
                if result.is_err() { break; } // sender dropped — clean exit
                let queue = queue_rx.borrow_and_update().clone();
                let prs   = pr_rx.borrow().clone();
                let tags  = perri_state_tags(&session_mgr, &prs);
                broadcast(&tx, &tags, queue.as_ref(), &prs);
            }
            result = pr_rx.changed() => {
                if result.is_err() { break; }
                let queue = queue_rx.borrow().clone();
                let prs   = pr_rx.borrow_and_update().clone();
                let changed: Vec<String> = {
                    let mut v: Vec<String> =
                        nostromo::data::perri_pr::changed_tags(&previous, &prs)
                            .into_iter()
                            .collect();
                    v.sort();
                    v
                };
                previous = prs.clone();
                broadcast(&tx, &changed, queue.as_ref(), &prs);
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
    let mailbox = mailbox_rx.borrow().clone().unwrap_or_default();
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

/// Delete log files in `dir` whose modification time is older than `keep_days` days.
/// Silent on any I/O error — log pruning is best-effort.
fn prune_old_logs(dir: &std::path::Path, keep_days: u64) {
    let cutoff = std::time::SystemTime::now()
        .checked_sub(std::time::Duration::from_secs(keep_days * 86_400))
        .unwrap_or(std::time::SystemTime::UNIX_EPOCH);
    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            if let Ok(meta) = entry.metadata() {
                if meta.is_file() {
                    if let Ok(modified) = meta.modified() {
                        if modified < cutoff {
                            let _ = std::fs::remove_file(entry.path());
                        }
                    }
                }
            }
        }
    }
}

fn daemon_log_dir() -> PathBuf {
    dirs_next::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".cache")
        .join("nostromd")
        .join("log")
}
